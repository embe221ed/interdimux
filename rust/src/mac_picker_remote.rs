//! Discover and refresh Rex host catalogs independently of the local picker.

use crate::dirs::{bounded_command_output, BoundedCommand};
use crate::rex;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

#[path = "mac_picker_connection.rs"]
mod connection;
use connection::Connections;

const HOST_WORKERS: usize = 4;
const METADATA_BATCH_SIZE: usize = 4;
// Bound both the bootstrap reply and the session IDs passed as a CLI argument.
const LAYOUT_BATCH_SIZE: usize = 32;
const OUTPUT_LIMIT: usize = 4 * 1024 * 1024;
const REFRESH_TIMEOUT: Duration = Duration::from_secs(8);
const ACTIVATE_TIMEOUT: Duration = Duration::from_secs(12);
const TUNNEL_PROBE_TIMEOUT: Duration = Duration::from_secs(2);

const SNAPSHOT: &str = r#"
local status, status_error = rex.call("server.status", {})
if not status then error(status_error, 0) end
local listed, list_error = rex.call("session.list", {})
if not listed then error(list_error, 0) end
return { host_id = status.host_id, sessions = listed.sessions or {} }
"#;
const LAYOUTS: &str = include_str!("rex_remote_layouts.lua");
const METADATA: &str = include_str!("rex_remote_metadata.lua");

// The Rex Mac scripting dictionary exposes each connected host and its
// host-scoped session objects. Always address the exact local app process.
const SHOW_SESSION: &str = include_str!("rex_show_session.js");
const FOCUS_REMOTE: &str = include_str!("rex_focus_remote.lua");

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RemoteSessionInfo {
    pub host: String,
    pub host_id: String,
    pub session_id: String,
    pub label: String,
    pub tunnel: Option<PathBuf>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RemoteSession {
    pub info: RemoteSessionInfo,
    pub stale: bool,
    pub windows: Vec<RemoteWindow>,
    pub layout_stale: bool,
}

impl RemoteSessionInfo {
    pub fn row_id(&self) -> String {
        session_row_id(&self.host_id, &self.session_id)
    }

    fn endpoint(&self) -> &str {
        self.tunnel.as_deref().filter(|path| is_ssh_tunnel(path))
            .and_then(Path::to_str).unwrap_or(&self.host)
    }
}

pub(super) fn session_row_id(host_id: &str, session_id: &str) -> String {
    format!("remote:{host_id}:{session_id}")
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RemoteWindow {
    pub window_id: String,
    pub label: String,
    pub active: bool,
    pub panes: Vec<RemotePane>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RemotePane {
    pub block_id: String,
    pub label: String,
    pub title: String,
    pub cwd: String,
    pub focused: bool,
    pub is_terminal: bool,
    pub runtime: Option<RemotePaneRuntime>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RemotePaneRuntime {
    pub command: String,
    pub title: String,
    pub cwd: String,
}

// Include the declaration and endpoints in the cache key. An edited label
// must not inherit the old endpoint's rows while the new endpoint is pending.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct Host {
    label: String,
    id: String,
    host_id: String,
    endpoints: Vec<String>,
}

impl Host {
    fn uses_ssh(&self) -> bool {
        self.endpoints
            .iter()
            .any(|endpoint| endpoint.starts_with("ssh://"))
    }
}

struct HostList {
    hosts: Vec<Host>,
    complete: bool,
}

type RuntimeBySession = BTreeMap<String, BTreeMap<String, RemotePaneRuntime>>;

enum Update {
    Hosts(HostList),
    Sessions(Host, Option<Vec<RemoteSession>>),
    AppSessions(Vec<(Host, Vec<RemoteSession>)>),
    SessionsReady,
    Layouts(LayoutJob, BTreeMap<String, Vec<RemoteWindow>>),
    Metadata(LayoutJob, RuntimeBySession),
    DiscoveryFailed,
}

#[derive(Clone)]
struct LayoutJob {
    host: Host,
    aliases: Vec<Host>,
    host_id: String,
    tunnel: Option<PathBuf>,
}

impl LayoutJob {
    fn endpoint(&self) -> &str {
        self.tunnel
            .as_deref()
            .and_then(Path::to_str)
            .unwrap_or(&self.host.label)
    }

    fn applies_to(&self, session: &RemoteSession) -> bool {
        !session.stale && session.info.host_id == self.host_id && session.info.tunnel == self.tunnel
    }

    /// Deliver independent cache updates for registrations verified by the
    /// same tunnel reply. The common single-registration route moves its data.
    fn publish<T: Clone>(
        &self,
        sender: &Sender<Update>,
        data: T,
        update: fn(LayoutJob, T) -> Update,
    ) -> bool {
        let route = |host: &Host| LayoutJob {
            host: host.clone(),
            aliases: Vec::new(),
            host_id: self.host_id.clone(),
            tunnel: self.tunnel.clone(),
        };
        for alias in &self.aliases {
            if sender.send(update(route(alias), data.clone())).is_err() {
                return false;
            }
        }
        sender.send(update(route(&self.host), data)).is_ok()
    }
}

struct MetadataJob {
    route: LayoutJob,
    panes: Vec<MetadataPane>,
}

struct MetadataPane {
    session_id: String,
    block_id: String,
    focused: bool,
}

struct Worker {
    receiver: Receiver<Update>,
    explicit: bool,
    discovering_sessions: bool,
    answered_before_app: Option<HashSet<String>>,
    native_catalog: Option<NativeCatalog>,
    cancelled: Arc<AtomicBool>,
    thread: JoinHandle<()>,
}

struct NativeCatalog {
    token: u64,
    app: LocalApp,
    declarations: Vec<Host>,
    offered: bool,
}

#[derive(Default)]
pub(super) struct RemoteCatalog {
    sessions: BTreeMap<Host, Vec<RemoteSession>>,
    worker: Option<Worker>,
    complete_inventory: bool,
    connections: Connections,
    tried_app_catalog: bool,
    next_catalog_token: u64,
}

impl RemoteCatalog {
    pub fn refresh(&mut self, local_host_id: Option<String>, app: Option<&LocalApp>, explicit: bool,
                   native_catalog: bool) {
        // Opens share all work. A deliberate refresh needs a fresh inventory,
        // and repeated refreshes can share that inventory while it is pending.
        if self.worker.as_ref().is_some_and(|w| !explicit || (w.explicit && w.discovering_sessions)) {
            return;
        }
        let retiring = self.worker.take().map(|worker| {
            worker.cancelled.store(true, Ordering::Relaxed);
            worker.thread
        });
        let (sender, receiver) = mpsc::channel();
        let cancelled = Arc::new(AtomicBool::new(false));
        let worker_cancelled = cancelled.clone();
        let connections = self.connections.clone();
        let mut cold_app = app.filter(|_| !self.tried_app_catalog && self.sessions.values().all(Vec::is_empty)).cloned();
        let use_app = cold_app.is_some();
        let native_catalog = if native_catalog {
            self.next_catalog_token.checked_add(1).and_then(|token| {
                let app = cold_app.take()?;
                self.next_catalog_token = token;
                Some(NativeCatalog { token, app, declarations: Vec::new(), offered: false })
            })
        } else { None };
        if let Ok(thread) = thread::Builder::new()
            .name("imux-rex-hosts".into())
            .spawn(move || {
                // Only the replacement worker waits for the old children. The
                // picker can render immediately and only reads the new receiver.
                if let Some(thread) = retiring {
                    let _ = thread.join();
                }
                if !worker_cancelled.load(Ordering::Relaxed) {
                    run_refresh(sender, local_host_id.as_deref(), &worker_cancelled, &connections, cold_app);
                }
            })
        {
            self.tried_app_catalog |= use_app;
            self.worker = Some(Worker {
                receiver,
                explicit,
                answered_before_app: use_app.then(HashSet::new),
                native_catalog,
                discovering_sessions: true,
                cancelled,
                thread,
            });
        }
    }

    pub fn take_catalog_offer(&mut self, app: Option<&LocalApp>) -> Option<Value> {
        let worker = self.worker.as_mut()?;
        let request = worker.native_catalog.as_mut()?;
        let answered = worker.answered_before_app.as_ref()?;
        if request.offered || app != Some(&request.app)
            || !request.declarations.iter().any(|h| !answered.contains(&h.label))
        {
            return None;
        }
        request.offered = true;
        request.app.check_process().ok()?;
        Some(json!({"token":request.token,"pid":request.app.pid,"birth":request.app.birth}))
    }

    pub fn accept_catalog(&mut self, token: u64, records: &Value, app: Option<&LocalApp>,
                          local_host_id: Option<&str>) -> bool {
        let Some(worker) = self.worker.as_mut() else { return false };
        if !worker.native_catalog.as_ref().is_some_and(|request|
            request.offered && request.token == token && app == Some(&request.app)) {
            return false;
        }
        let request = worker.native_catalog.take().unwrap();
        if request.app.check_process().is_err() || !records.is_array() {
            return false;
        }
        self.apply(Update::AppSessions(app_session_rows(&request.declarations, records, local_host_id)))
    }

    pub fn pending(&self) -> bool {
        self.worker.is_some()
    }

    pub fn discovering_sessions(&self) -> bool {
        self.worker.as_ref().is_some_and(|worker| worker.discovering_sessions)
    }

    /// Apply every result that is ready now. SSH is never waited on here.
    pub fn poll(&mut self) -> bool {
        let mut changed = false;
        while let Some(worker) = &self.worker {
            match worker.receiver.try_recv() {
                Ok(update) => changed |= self.apply(update),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    self.worker = None;
                    break;
                }
            }
        }
        changed
    }

    fn apply(&mut self, update: Update) -> bool {
        if let Update::Sessions(host, _) = &update {
            if let Some(answered) = self.worker.as_mut().and_then(|w| w.answered_before_app.as_mut()) {
                answered.insert(host.label.clone());
            }
        }
        match update {
            Update::AppSessions(hosts) => {
                let Some(answered) = self.worker.as_mut().filter(|w| w.discovering_sessions)
                    .and_then(|w| w.answered_before_app.take()) else { return false };
                let mut changed = false;
                for (host, rows) in hosts {
                    if let Some(cached) = self.sessions.get_mut(&host) {
                        if cached.is_empty() && !answered.contains(&host.label) && !rows.is_empty() {
                            *cached = rows;
                            changed = true;
                        }
                    }
                }
                changed
            }
            Update::SessionsReady => {
                if let Some(worker) = &mut self.worker {
                    worker.discovering_sessions = false;
                    worker.native_catalog = None;
                }
                false
            }
            Update::Hosts(list) => {
                if let Some(request) = self.worker.as_mut().and_then(|w| w.native_catalog.as_mut()) {
                    request.declarations = list.hosts.iter().filter(|h| !h.host_id.is_empty()).cloned().collect();
                }
                self.complete_inventory = list.complete;
                let listed: BTreeMap<_, _> = list
                    .hosts
                    .iter()
                    .map(|host| (host.label.as_str(), host))
                    .collect();
                let mut changed = false;
                self.sessions
                    .retain(|host, sessions| match listed.get(host.label.as_str()) {
                        Some(current) if *current == host => true,
                        None if !list.complete => {
                            changed |= mark_stale(sessions.iter_mut());
                            true
                        }
                        _ => {
                            changed |= !sessions.is_empty();
                            false
                        }
                    });
                // Retain the registration even for a new, empty, or offline
                // host so its name cannot resolve a same-ID session elsewhere.
                for host in list.hosts {
                    self.sessions.entry(host).or_default();
                }
                changed
            }
            Update::Sessions(host, Some(mut sessions)) => {
                let previous = self.sessions.entry(host).or_default();
                if previous.len() == sessions.len() && previous.iter().zip(&sessions)
                    .all(|(old, new)| !old.stale && old.info == new.info) {
                    return false;
                }
                // Session inventory does not change the cached layout. Move
                // it across a rename, reordering, or reconnection by identity.
                let mut cached: BTreeMap<_, _> = previous.drain(..).map(|old| {
                    ((old.info.host_id, old.info.session_id), (old.windows, old.stale, old.layout_stale))
                }).collect();
                for session in &mut sessions {
                    if let Some((windows, stale, layout_stale)) =
                        cached.remove(&(session.info.host_id.clone(), session.info.session_id.clone())) {
                        session.layout_stale = layout_stale || (stale && !windows.is_empty());
                        session.windows = windows;
                    }
                }
                *previous = sessions;
                true
            }
            Update::Sessions(host, None) => {
                self.complete_inventory = false;
                mark_stale(self.sessions.get_mut(&host).into_iter().flatten())
            }
            Update::Layouts(job, mut layouts) => {
                let mut changed = false;
                for session in self.sessions.get_mut(&job.host).into_iter().flatten() {
                    if !job.applies_to(session) {
                        continue;
                    }
                    if let Some(mut windows) = layouts.remove(&session.info.session_id) {
                        retain_runtime(&session.windows, &mut windows);
                        changed |= session.layout_stale || session.windows != windows;
                        session.windows = windows;
                        session.layout_stale = false;
                    } else if !session.layout_stale && !session.windows.is_empty() {
                        session.layout_stale = true;
                        changed = true;
                    }
                }
                changed
            }
            Update::Metadata(job, mut runtime) => {
                let mut changed = false;
                for session in self.sessions.get_mut(&job.host).into_iter().flatten() {
                    if !job.applies_to(session) {
                        continue;
                    }
                    let Some(mut blocks) = runtime.remove(&session.info.session_id) else {
                        continue;
                    };
                    for pane in session
                        .windows
                        .iter_mut()
                        .flat_map(|window| &mut window.panes)
                        .filter(|pane| pane.is_terminal)
                    {
                        if let Some(details) = blocks.remove(&pane.block_id) {
                            changed |= pane.runtime.as_ref() != Some(&details);
                            pane.runtime = Some(details);
                        }
                    }
                }
                changed
            }
            Update::DiscoveryFailed => {
                self.complete_inventory = false;
                mark_stale(self.sessions.values_mut().flatten())
            }
        }
    }

    pub fn sessions(&self) -> impl Iterator<Item = &RemoteSession> {
        let all = self.sessions.values().flatten();
        let mut seen = HashSet::new();
        all.clone()
            .filter(|row| !row.stale)
            .chain(all.filter(|row| row.stale))
            .filter(move |row| seen.insert((&row.info.host_id, &row.info.session_id)))
    }

    pub fn origin_session(&self, server: &str, session_id: &str) -> Option<&RemoteSessionInfo> {
        let mut registered = None;
        for (host, sessions) in &self.sessions {
            if server.eq_ignore_ascii_case(&host.label) || server.eq_ignore_ascii_case(&host.host_id)
                || sessions.first().is_some_and(|s| server.eq_ignore_ascii_case(&s.info.host_id))
            {
                registered = Some(sessions.first().map_or(host.host_id.as_str(), |s| s.info.host_id.as_str()));
                if let Some(row) = sessions.iter().find(|s| s.info.session_id == session_id) {
                    return Some(&row.info);
                }
            }
        }
        if let Some(id) = registered {
            // Another declaration of the same Rex host can supply its rows.
            return self.sessions.values().flatten()
                .find(|row| row.info.host_id == id && row.info.session_id == session_id)
                .map(|row| &row.info);
        }
        // An app-private name can be recovered from a globally unique session
        // ID. A partial inventory cannot establish uniqueness.
        if self.discovering_sessions() || !self.complete_inventory {
            return None;
        }
        let mut matches = self.sessions().filter(|row| row.info.session_id == session_id);
        let first = matches.next()?;
        matches.next().is_none().then_some(&first.info)
    }
}

fn retain_runtime(previous: &[RemoteWindow], windows: &mut [RemoteWindow]) {
    let runtime: BTreeMap<_, _> = previous
        .iter()
        .flat_map(|window| &window.panes)
        .filter_map(|pane| Some((pane.block_id.as_str(), pane.runtime.as_ref()?)))
        .collect();
    for pane in windows
        .iter_mut()
        .flat_map(|window| &mut window.panes)
        .filter(|pane| pane.is_terminal)
    {
        pane.runtime = runtime
            .get(pane.block_id.as_str())
            .map(|details| (*details).clone());
    }
}

fn mark_stale<'a>(sessions: impl Iterator<Item = &'a mut RemoteSession>) -> bool {
    let mut changed = false;
    for session in sessions {
        changed |= !session.stale;
        session.stale = true;
    }
    changed
}

impl Drop for RemoteCatalog {
    fn drop(&mut self) {
        if let Some(worker) = self.worker.take() {
            worker.cancelled.store(true, Ordering::Relaxed);
            let _ = worker.thread.join();
        }
    }
}

fn run_refresh(sender: Sender<Update>, local_host_id: Option<&str>, cancelled: &AtomicBool,
               connections: &Connections, cold_app: Option<LocalApp>) {
    let work = rex::resolve_binary().and_then(|binary| {
        let data = request(
            &binary,
            None,
            &["hosts", "list", "--json"],
            REFRESH_TIMEOUT,
            || cancelled.load(Ordering::Relaxed),
        )?;
        host_list(&data, local_host_id).map(|list| (binary, list))
    });
    let Ok((binary, list)) = work else {
        let _ = sender.send(Update::DiscoveryFailed);
        return;
    };
    let hosts = list.hosts.clone();
    if sender.send(Update::Hosts(list)).is_err() {
        return;
    }
    let layout_workers = hosts.len().min(HOST_WORKERS);
    let (layout_sender, layout_receiver) = mpsc::channel();
    let layout_receiver = Mutex::new(layout_receiver);
    let (metadata_sender, metadata_receiver) = mpsc::channel();
    let metadata_receiver = Mutex::new(metadata_receiver);
    // The session jobs have their own bounded worker pool. Once one host has
    // published its sessions, its layout can start without delaying the next
    // host's session discovery or waiting for an unrelated SSH connection.
    let sessions_ready = AtomicBool::new(false);
    thread::scope(|scope| {
        if let Some(app) = cold_app.filter(|_| hosts.iter().any(|h| !h.host_id.is_empty())) {
            let declarations = hosts.clone();
            let sender = &sender;
            let ready = &sessions_ready;
            let _ = thread::Builder::new().name("imux-rex-app-sessions".into()).spawn_scoped(scope, move || {
                let stop = || cancelled.load(Ordering::Relaxed) || ready.load(Ordering::Relaxed);
                if let Some(records) = app.cached_sessions(stop) {
                    let _ = sender.send(Update::AppSessions(app_session_rows(&declarations, &records["hosts"], local_host_id)));
                }
            });
        }
        for _ in 0..layout_workers {
            let metadata_sender = metadata_sender.clone();
            let layout_receiver = &layout_receiver;
            let metadata_receiver = &metadata_receiver;
            let binary = &binary;
            let sender = &sender;
            let _ = thread::Builder::new().spawn_scoped(scope, move || loop {
                let next = layout_receiver.lock().unwrap().recv();
                let Ok((job, sessions)) = next else { break };
                if cancelled.load(Ordering::Relaxed) {
                    break;
                }
                if let Some(metadata) = collect_layout(binary, sender, job, sessions, cancelled, connections) {
                    let _ = metadata_sender.send(metadata);
                }
            });
            let _ = thread::Builder::new().spawn_scoped(scope, move || loop {
                let next = metadata_receiver.lock().unwrap().recv();
                let Ok(job) = next else { break };
                if cancelled.load(Ordering::Relaxed) {
                    break;
                }
                collect_metadata(binary, sender, job, cancelled);
            });
        }
        drop(metadata_sender);
        refresh_sessions(
            &binary,
            hosts,
            local_host_id,
            cancelled,
            ssh_tunnels,
            |host, aliases, sessions| {
                if let Some(layout) = publish_sessions(&sender, host, aliases, sessions) {
                    let _ = layout_sender.send(layout);
                }
            },
        );
        sessions_ready.store(true, Ordering::Relaxed);
        let _ = sender.send(Update::SessionsReady);
        drop(layout_sender);
    });
}

fn publish_sessions(
    sender: &Sender<Update>,
    host: Host,
    aliases: Vec<Host>,
    sessions: Option<Vec<RemoteSession>>,
) -> Option<(LayoutJob, Vec<String>)> {
    // Queue each alias's inventory before layout or metadata can arrive.
    if let Some(rows) = &sessions {
        for alias in &aliases {
            let mut aliased = rows.clone();
            for row in &mut aliased {
                row.info.host.clone_from(&alias.label);
            }
            sender
                .send(Update::Sessions(alias.clone(), Some(aliased)))
                .ok()?;
        }
    }
    let layout = sessions.as_ref().and_then(|rows| {
        let first = rows.first()?;
        let route = LayoutJob {
            host: host.clone(),
            aliases,
            host_id: first.info.host_id.clone(),
            tunnel: first.info.tunnel.clone(),
        };
        let ids = rows.iter().map(|row| row.info.session_id.clone()).collect();
        Some((route, ids))
    });
    sender.send(Update::Sessions(host, sessions)).ok()?;
    layout
}

// A session-only bootstrap returns identity and the inventory in one RPC.
// Passing a JSON empty array avoids attaching this short-lived CLI to any
// session (an empty Lua table would be encoded as an object).
fn session_inventory(
    binary: &Path,
    endpoint: &str,
    timeout: Duration,
    cancelled: impl Fn() -> bool,
) -> Result<Value, String> {
    let start = Instant::now();
    let result = request(
        binary,
        Some(endpoint),
        &[
            "api",
            "call",
            "session.bootstrap",
            r#"{"event_scope":"session","attach_session_ids":[]}"#,
        ],
        timeout,
        &cancelled,
    );
    let mut bootstrap = match result {
        Ok(value) => value,
        Err(error)
            if error.contains("code=method_not_found")
                || error.contains("unknown field \"attach_session_ids\"") =>
        {
            let remaining = timeout.saturating_sub(start.elapsed());
            if remaining.is_zero() || cancelled() {
                return Err(error);
            }
            return request(
                binary,
                Some(endpoint),
                &["do", "-e", SNAPSHOT],
                remaining,
                cancelled,
            );
        }
        Err(error) => return Err(error),
    };
    let host_id = bootstrap
        .pointer_mut("/server_status/host_id")
        .ok_or("Rex bootstrap omitted its host ID")?
        .take();
    let mut list = bootstrap
        .get_mut("attach_all")
        .ok_or("Rex bootstrap omitted the session list")?
        .take();
    let sessions = list
        .get_mut("sessions")
        .ok_or("Rex bootstrap omitted the session list")?;
    if sessions.is_null() {
        *sessions = Value::Array(Vec::new());
    }
    list["host_id"] = host_id;
    Ok(list)
}

fn refresh_sessions(
    binary: &Path,
    hosts: Vec<Host>,
    local_host_id: Option<&str>,
    cancelled: &AtomicBool,
    list_tunnels: impl FnOnce() -> Vec<PathBuf>,
    publish: impl Fn(Host, Vec<Host>, Option<Vec<RemoteSession>>) + Sync,
) {
    let collect_host = |host: Host| {
        let sessions = session_inventory(binary, &host.label, REFRESH_TIMEOUT, || {
            cancelled.load(Ordering::Relaxed)
        })
        .and_then(|data| read_sessions(&host, &data, local_host_id));
        publish(host, Vec::new(), sessions.ok());
    };
    let via_tunnel = |host: &Host| host.uses_ssh() && !host.host_id.is_empty();
    let sockets = if hosts.iter().any(via_tunnel) {
        list_tunnels()
    } else {
        Vec::new()
    };
    if sockets.is_empty() {
        collect_in_parallel(hosts, HOST_WORKERS, cancelled, collect_host);
        return;
    }
    let (tunneled, direct): (Vec<_>, Vec<_>) = hosts.into_iter().partition(via_tunnel);
    // A stale forward can take its entire probe timeout. Hosts which don't
    // need an SSH tunnel should publish while that probe is still running.
    let direct_workers = direct.len().min(HOST_WORKERS / 2);
    let tunnel_workers = HOST_WORKERS - direct_workers;
    thread::scope(|scope| {
        if direct_workers > 0 {
            scope.spawn(|| collect_in_parallel(direct, direct_workers, cancelled, &collect_host));
        }
        let resolved = Mutex::new(HashSet::new());
        let all_resolved = AtomicBool::new(false);
        collect_in_parallel(sockets, tunnel_workers, cancelled, |socket| {
            let stop = || cancelled.load(Ordering::Relaxed) || all_resolved.load(Ordering::Relaxed);
            if stop() {
                return;
            }
            let Some(endpoint) = socket.to_str() else {
                return;
            };
            let Ok(data) = session_inventory(binary, endpoint, TUNNEL_PROBE_TIMEOUT, stop) else {
                return;
            };
            let host_id = string(&data["host_id"]);
            if host_id.is_empty() {
                return;
            }
            let mut matching = tunneled.iter().filter(|host| host.host_id == host_id);
            let Some(host) = matching.next() else { return };
            let Ok(mut sessions) = read_sessions(host, &data, local_host_id) else {
                return;
            };
            for session in &mut sessions {
                session.info.tunnel = Some(socket.clone());
            }
            let mut seen = resolved.lock().unwrap();
            if !seen.insert(host.label.clone()) {
                return;
            }
            // A single verified response satisfies every matching SSH declaration.
            let aliases: Vec<_> = matching.cloned().collect();
            seen.extend(aliases.iter().map(|alias| alias.label.clone()));
            if seen.len() == tunneled.len() {
                all_resolved.store(true, Ordering::Relaxed);
            }
            drop(seen);
            publish(host.clone(), aliases, Some(sessions));
        });
        let resolved = resolved.into_inner().unwrap();
        let remaining = tunneled
            .into_iter()
            .filter(|host| !resolved.contains(&host.label))
            .collect();
        collect_in_parallel(remaining, tunnel_workers, cancelled, collect_host);
    });
}

fn collect_layout(
    binary: &Path,
    sender: &Sender<Update>,
    job: LayoutJob,
    session_ids: Vec<String>,
    cancelled: &AtomicBool,
    connections: &Connections,
) -> Option<MetadataJob> {
    let deadline = Instant::now() + REFRESH_TIMEOUT;
    let mut layouts = BTreeMap::new();
    for ids in session_ids.chunks(LAYOUT_BATCH_SIZE) {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() || cancelled.load(Ordering::Relaxed) {
            break;
        }
        let args = json!({"host_id":job.host_id, "session_ids":ids}).to_string();
        let data = connections.layout(binary, &job, &args, deadline, cancelled)
            .unwrap_or_else(|| request(
                binary, Some(job.endpoint()), &["do", "-e", LAYOUTS, "--args", &args],
                remaining, || cancelled.load(Ordering::Relaxed),
            ));
        let Ok(data) = data else {
            break;
        };
        if data["host_id"] != job.host_id {
            break;
        }
        layouts.extend(read_layouts(&job.host_id, &data));
    }
    let panes = metadata_panes(&layouts);
    if !job.publish(sender, layouts, Update::Layouts) {
        return None;
    }
    (!panes.is_empty()).then_some(MetadataJob { route: job, panes })
}

fn metadata_panes(layouts: &BTreeMap<String, Vec<RemoteWindow>>) -> Vec<MetadataPane> {
    let mut panes = Vec::new();
    for (session_id, windows) in layouts {
        for pane in windows
            .iter()
            .flat_map(|window| &window.panes)
            .filter(|pane| pane.is_terminal)
        {
            panes.push(MetadataPane {
                session_id: session_id.clone(),
                block_id: pane.block_id.clone(),
                focused: pane.focused,
            });
        }
    }
    // Names from focused panes can also name their tabs, so fetch them first.
    panes.sort_by_key(|pane| !pane.focused);
    panes
}

fn collect_metadata(
    binary: &Path,
    sender: &Sender<Update>,
    job: MetadataJob,
    cancelled: &AtomicBool,
) {
    let mut connection: Option<BoundedCommand> = None;
    let stopped = || cancelled.load(Ordering::Relaxed);
    for (i, batch) in job.panes.chunks(METADATA_BATCH_SIZE).enumerate() {
        if stopped() {
            break;
        }
        let panes = Value::Array(batch
            .iter()
            .map(|pane| json!({"session_id": pane.session_id, "block_id": pane.block_id}))
            .collect());
        let deadline = Instant::now() + REFRESH_TIMEOUT;
        let streamed = if let Some(process) = &mut connection {
            let line = format!("{panes}\n");
            process.exchange_line(line.as_bytes(), deadline, stopped)
                .and_then(Result::ok).and_then(|bytes| serde_json::from_slice(&bytes).ok())
        } else if i == 0 && job.panes.len() > METADATA_BATCH_SIZE {
            let args = json!({"host_id": job.route.host_id, "panes": panes, "more": true}).to_string();
            let mut cli = command(binary, Some(job.route.endpoint()));
            cli.args(["do", "-e", METADATA, "--args", &args]);
            let Ok(mut process) = BoundedCommand::interactive(cli, deadline, OUTPUT_LIMIT) else { break };
            let first = process.first_line(stopped).ok()
                .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
            if first.as_ref().is_some_and(|r| r["imux_metadata_stream"] == true) {
                connection = Some(process);
            }
            first
        } else {
            None
        };
        // Single batches and older CLIs use a one-shot read. A broken stream
        // can retry this read against a freshly verified host in the same budget.
        let data = streamed.or_else(|| {
            connection = None;
            let remaining = deadline.saturating_duration_since(Instant::now());
            if stopped() || remaining.is_zero() { return None; }
            let args = json!({"host_id": job.route.host_id, "panes": panes}).to_string();
            request(binary, Some(job.route.endpoint()), &["do", "-e", METADATA, "--args", &args],
                    remaining, stopped).ok()
        });
        let Some(data) = data else { break };
        if data["host_id"].as_str() != Some(job.route.host_id.as_str()) {
            break;
        }
        let runtime = read_metadata(batch, &data["metadata"]);
        if !runtime.is_empty() && !job.route.publish(sender, runtime, Update::Metadata) {
            break;
        }
    }
}

fn read_metadata(batch: &[MetadataPane], metadata: &Value) -> RuntimeBySession {
    let mut runtime = RuntimeBySession::new();
    for pane in batch {
        let Some(data) = metadata
            .get(&pane.block_id)
            .filter(|value| value.is_object())
        else {
            continue;
        };
        let (command, cwd) = rex::terminal_process_metadata(data);
        let title = if rex::title_owned_by_foreground(data) {
            string(&data["title"]).trim().to_owned()
        } else {
            String::new()
        };
        runtime.entry(pane.session_id.clone()).or_default().insert(
            pane.block_id.clone(),
            RemotePaneRuntime {
                command,
                title,
                cwd,
            },
        );
    }
    runtime
}

fn collect_in_parallel<T: Send>(
    jobs: Vec<T>,
    max_workers: usize,
    cancelled: &AtomicBool,
    collect: impl Fn(T) + Sync,
) {
    let workers = jobs.len().min(max_workers);
    let jobs = Mutex::new(jobs.into_iter());
    thread::scope(|scope| {
        for _ in 0..workers {
            let _ = thread::Builder::new().spawn_scoped(scope, || {
                while !cancelled.load(Ordering::Relaxed) {
                    let next = jobs.lock().unwrap().next();
                    let Some(job) = next else { break };
                    collect(job);
                }
            });
        }
    });
}

#[cfg(target_os = "macos")]
fn ssh_tunnels() -> Vec<PathBuf> {
    let Some(home) = std::env::var_os("HOME").filter(|home| !home.is_empty()) else {
        return Vec::new();
    };
    let directory = PathBuf::from(home).join("Library/Application Support/rex/ssh");
    std::fs::read_dir(directory)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| is_ssh_tunnel(path))
        .collect()
}

#[cfg(not(target_os = "macos"))]
fn ssh_tunnels() -> Vec<PathBuf> {
    Vec::new()
}

#[cfg(target_os = "macos")]
fn is_ssh_tunnel(path: &Path) -> bool {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    extern "C" {
        fn getuid() -> u32;
    }

    // Rex's private forwarding directory also contains askpass sockets.
    // Accept only its forwarding filenames and user-owned private sockets.
    path.is_absolute()
        && path
            .extension()
            .is_some_and(|extension| extension == "sock")
        && path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .is_some_and(|stem| {
                stem.len() == 16 && stem.bytes().all(|byte| byte.is_ascii_hexdigit())
            })
        && std::fs::symlink_metadata(path).is_ok_and(|metadata| {
            metadata.file_type().is_socket()
                && metadata.uid() == unsafe { getuid() }
                && metadata.mode() & 0o077 == 0
        })
}

#[cfg(not(target_os = "macos"))]
fn is_ssh_tunnel(_: &Path) -> bool {
    false
}

fn string(value: &Value) -> &str {
    value.as_str().unwrap_or("")
}

fn host_list(value: &Value, local_host_id: Option<&str>) -> Result<HostList, String> {
    let entries = value["hosts"]
        .as_array()
        .or_else(|| value.as_array())
        .ok_or("Rex host list is missing its hosts array")?;
    let mut labels = HashSet::new();
    let mut hosts = Vec::new();
    for entry in entries {
        let entry = entry.get("host").unwrap_or(entry);
        let label = string(&entry["label"]);
        let host_id = string(&entry["host_id"]);
        if label.is_empty() || local_host_id == Some(host_id) || !labels.insert(label.to_owned()) {
            continue;
        }
        let endpoints = entry["endpoints"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .chain(entry["endpoint"].as_str())
            .map(str::to_owned)
            .collect();
        hosts.push(Host {
            label: label.to_owned(),
            id: string(&entry["id"]).to_owned(),
            host_id: host_id.to_owned(),
            endpoints,
        });
    }
    // A disconnected home can return cached registrations. They are usable,
    // but their absence doesn't prove that a previously known host was removed.
    let complete = value["home"]["reached"] != false;
    Ok(HostList { hosts, complete })
}

// The Mac app exposes session roots immediately. Only use entries that match
// a unique connected registry record and a current, physically identified CLI
// declaration. The normal server inventory still owns removals and layouts.
fn app_session_rows(hosts: &[Host], records: &Value, local_host_id: Option<&str>) -> Vec<(Host, Vec<RemoteSession>)> {
    let mut by_label = BTreeMap::new();
    for row in records.as_array().into_iter().flatten() {
        if let Some(label) = row["label"].as_str() {
            by_label.entry(label).and_modify(|entry| *entry = None).or_insert(Some(row));
        }
    }
    hosts.iter().filter(|host| !host.host_id.is_empty()).filter_map(|host| {
        let record = (*by_label.get(host.label.as_str())?)?;
        let rows = read_sessions(host, record, local_host_id).ok()?;
        (!rows.is_empty()).then(|| (host.clone(), rows))
    }).collect()
}

fn read_sessions(
    host: &Host,
    value: &Value,
    local_host_id: Option<&str>,
) -> Result<Vec<RemoteSession>, String> {
    let host_id = string(&value["host_id"]);
    if host_id.is_empty() {
        return Err("Rex server did not report a host ID".into());
    }
    if local_host_id == Some(host_id) {
        return Ok(Vec::new());
    }
    if !host.host_id.is_empty() && host.host_id != host_id {
        return Err("Rex host identity changed".into());
    }
    let sessions = match &value["sessions"] {
        Value::Array(sessions) => sessions,
        // Rex serializes an empty table returned by rex do as an object.
        Value::Object(sessions) if sessions.is_empty() => return Ok(Vec::new()),
        _ => return Err("Rex session list is missing its sessions array".into()),
    };
    Ok(sessions
        .iter()
        .filter_map(|session| {
            let session_id = string(&session["session_id"]);
            if !session_id.starts_with("session:") {
                return None;
            }
            let label = string(&session["label"]);
            Some(RemoteSession {
                info: RemoteSessionInfo {
                    host: host.label.clone(),
                    host_id: host_id.to_owned(),
                    session_id: session_id.to_owned(),
                    label: if label.is_empty() { session_id } else { label }.to_owned(),
                    tunnel: None,
                },
                stale: false,
                windows: Vec::new(),
                layout_stale: false,
            })
        })
        .collect())
}

fn read_layouts(host_id: &str, data: &Value) -> BTreeMap<String, Vec<RemoteWindow>> {
    if data["host_id"].as_str() != Some(host_id) {
        return BTreeMap::new();
    }
    data["layouts"]
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(session, windows)| Some((session.clone(), read_session_layout(windows)?)))
        .collect()
}

fn layout_array(value: &Value) -> Option<&[Value]> {
    match value {
        Value::Array(values) => Some(values),
        // An empty Lua table appears as an object in the CLI response.
        Value::Object(values) if values.is_empty() => Some(&[]),
        _ => None,
    }
}

fn read_session_layout(windows: &Value) -> Option<Vec<RemoteWindow>> {
    let mut window_ids = HashSet::new();
    let mut block_ids = HashSet::new();
    layout_array(windows)?
        .iter()
        .map(|window| {
            let window_id = string(&window["window_id"]);
            if !window_id.starts_with("window:") || !window_ids.insert(window_id) {
                return None;
            }
            let label = string(&window["label"]).to_owned();
            let mut panes = Vec::new();
            for pane in layout_array(&window["panes"])? {
                let block_id = string(&pane["block_id"]);
                if !block_id.starts_with("block:") || !block_ids.insert(block_id) {
                    return None;
                }
                let label = string(&pane["label"]);
                panes.push(RemotePane {
                    block_id: block_id.into(),
                    label: label.into(),
                    title: string(&pane["title"]).into(),
                    cwd: string(&pane["cwd"]).into(),
                    focused: pane["focused"] == true,
                    is_terminal: pane["terminal"] == true,
                    runtime: None,
                });
            }
            if !panes.iter().any(|pane| pane.focused) {
                if let Some(first) = panes.first_mut() {
                    first.focused = true;
                }
            }
            Some(RemoteWindow {
                window_id: window_id.into(),
                label,
                active: window["active"] == true,
                panes,
            })
        })
        .collect()
}

#[derive(Clone, PartialEq, Eq)]
pub(super) struct LocalApp {
    pid: u32,
    birth: String,
}

impl LocalApp {
    pub fn from_client(client: &Value) -> Option<Self> {
        let pid = u32::try_from(client["principal"]["pid"].as_u64()?).ok()?;
        Some(Self {
            pid,
            birth: crate::worker_identity::get(pid)?,
        })
    }

    fn cached_sessions(&self, cancelled: impl Fn() -> bool) -> Option<Value> {
        let mut command = Command::new(bundled_picker()?);
        self.check_process().ok()?;
        command.arg("--remote-session-catalog").arg(self.pid.to_string()).arg(&self.birth);
        let output = bounded_command_output(command, Duration::from_secs(2), OUTPUT_LIMIT, cancelled).ok()?;
        if !output.status.success() { return None; }
        serde_json::from_slice(&output.stdout).ok()
    }

    fn check_process(&self) -> Result<(), String> {
        if crate::worker_identity::get(self.pid).as_ref() != Some(&self.birth) {
            return Err("The original Rex app closed. Reopen the picker from the intended app.".into());
        }
        Ok(())
    }

    pub fn reveal_request(&self, id: u64, session: &RemoteSessionInfo) -> Result<Value, String> {
        self.check_process()?;
        Ok(json!({"id":id, "type":"reveal_remote", "pid":self.pid, "birth":self.birth,
            "host":session.host, "host_id":session.host_id, "session_id":session.session_id}))
    }
}

pub(super) fn reveal_after_remote_check(session: &RemoteSessionInfo, app: &LocalApp) -> Result<(), String> {
    let binary = rex::resolve_binary()?;
    let inventory = session_inventory(&binary, session.endpoint(), REFRESH_TIMEOUT, || false)
        .map_err(|error| format!("{}: {error}", session.host))?;
    if inventory["host_id"] != session.host_id {
        return Err("The Rex host changed. Refresh the picker before switching.".into());
    }
    if !inventory["sessions"].as_array().is_some_and(|sessions| {
        sessions.iter().any(|entry| entry["session_id"] == session.session_id)
    }) {
        return Err("The selected Rex session no longer exists. Refresh the picker.".into());
    }
    show_session(app, &session.host, &session.session_id, None).map(|_| ())
}

pub(super) fn activate(
    session: &RemoteSessionInfo,
    window_id: Option<&str>,
    block_id: Option<&str>,
    app: Option<&LocalApp>,
    catalog: &RemoteCatalog,
) -> Result<(), String> {
    let app =
        app.ok_or("Reopen the picker from a running local Rex app to switch remote sessions.")?;
    if block_id.is_some() && window_id.is_none() {
        return Err("A remote Rex pane must identify its tab.".into());
    }
    if window_id.is_none() {
        return match show_session(app, &session.host, &session.session_id, Some(&session.host_id))? {
            Reveal::Shown => Ok(()),
            Reveal::NeedsRemoteCheck => reveal_after_remote_check(session, app),
        };
    }
    let binary = rex::resolve_binary()?;
    let endpoint = session.endpoint();

    // rex do interprets Lua locally while its RPCs use the chosen server.
    // Keep that connection across the local reveal and exact focus. The
    // callback rechecks the originating process's birth immediately before show.
    let helper = std::env::current_exe()
        .map_err(|e| format!("Cannot locate the picker helper: {e}"))?;
    let helper = helper.to_str().ok_or("The picker helper path is not valid UTF-8.")?;
    let args = json!({
        "host_id": session.host_id,
        "session_id": session.session_id,
        "window_id": window_id,
        "block_id": block_id,
        "reveal": [helper, "macos-serve", "--show-session", app.pid.to_string(),
            app.birth, session.host, session.session_id],
    })
    .to_string();
    let warm = catalog.sessions.keys().find(|host| host.label == session.host)
        .and_then(|host| catalog.connections.activate(&binary, host, &session.host_id, endpoint, &args));
    let reply = warm.unwrap_or_else(|| request(
        &binary, Some(endpoint), &["do", "-e", FOCUS_REMOTE, "--args", &args],
        REFRESH_TIMEOUT + ACTIVATE_TIMEOUT, || false,
    )).map_err(|error| format!("{}: {error}", session.host))?;
    if reply["focused"] != true {
        return Err("Rex did not acknowledge the selected tab or pane.".into());
    }
    Ok(())
}

pub(super) fn reveal_from_cli(
    pid: &str,
    birth: &str,
    host: &str,
    session: &str,
) -> Result<(), String> {
    let pid = pid.parse().map_err(|_| "Invalid Rex app process ID")?;
    let app = LocalApp { pid, birth: birth.to_owned() };
    show_session(&app, host, session, None).map(|_| ())
}

enum Reveal {
    Shown,
    NeedsRemoteCheck,
}

fn bundled_picker() -> Option<PathBuf> {
    let helper = std::env::current_exe().ok()?;
    let contents = helper.parent()?.parent()?;
    helper.ends_with("Contents/Helpers/imux").then(|| contents.join("MacOS/InterdimuxPicker"))
}

fn show_session(app: &LocalApp, host: &str, session_id: &str, physical_id: Option<&str>) -> Result<Reveal, String> {
    let mut command = if let Some(picker) = bundled_picker() {
        let mut command = Command::new(picker);
        command.arg("--show-remote-session").arg(app.pid.to_string()).arg(&app.birth);
        command
    } else {
        // Standalone macos-serve builds have no bundled AppKit executable.
        if physical_id.is_some() {
            return Ok(Reveal::NeedsRemoteCheck);
        }
        let mut command = Command::new("/usr/bin/osascript");
        command.args(["-l", "JavaScript", "-e", SHOW_SESSION, "--"]).arg(app.pid.to_string());
        command
    };
    app.check_process()?;
    command.arg(host).arg(session_id);
    if let Some(id) = physical_id {
        command.arg(id);
    }
    let output = bounded_command_output(command, ACTIVATE_TIMEOUT, OUTPUT_LIMIT, || false)
        .map_err(|error| format!("Cannot show the session in the local Rex app: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
    }
    let reply: Value = serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("Invalid response from Rex automation: {error}"))?;
    // Only this explicit pre-Show result can start a second attempt. A timeout
    // or an error from Show may mean the app already switched sessions.
    if physical_id.is_some() && reply == json!({"needs_remote_check": true}) {
        return Ok(Reveal::NeedsRemoteCheck);
    }
    if reply["shown"] != true {
        return Err(reply["error"]
            .as_str()
            .unwrap_or("Rex did not show the selected session.")
            .into());
    }
    Ok(Reveal::Shown)
}

fn request(
    binary: &Path,
    host: Option<&str>,
    args: &[&str],
    timeout: Duration,
    cancelled: impl Fn() -> bool,
) -> Result<Value, String> {
    let mut command = command(binary, host);
    command.args(args);
    let output = bounded_command_output(command, timeout, OUTPUT_LIMIT, cancelled)
        .map_err(|error| format!("Rex CLI: {error}"))?;
    parse_reply(output)
}

fn command(binary: &Path, host: Option<&str>) -> Command {
    let mut command = Command::new(binary);
    for key in [
        "REX_SESSION",
        "REX_BLOCK",
        "REX_CLIENT",
        "REX_WINDOW",
        "REX_SERVER",
    ] {
        command.env_remove(key);
    }
    command.env("SSH_ASKPASS_REQUIRE", "never");
    command.args(["--autostart=false", "--color=never", "--timeout=5s"]);
    if let Some(host) = host {
        command.arg(format!("--server={host}"));
    }
    command
}

fn parse_reply(output: Output) -> Result<Value, String> {
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr);
        return Err(if detail.trim().is_empty() {
            format!("Rex CLI exited with {}", output.status)
        } else {
            detail.trim().to_owned()
        });
    }
    serde_json::from_slice(&output.stdout).map_err(|e| format!("Invalid Rex reply: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn metadata_batches_share_one_connection_and_release_it_on_cancellation() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!("imux-meta-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        let cli = root.join("rex");
        fs::write(&cli, r#"#!/bin/sh
root=${0%/*}
mode=${4#--server=}
echo "$$" >> "$root/$mode.pids"
respond() {
    case "$1" in
        *\"block:8\"*) block=8 ;;
        *\"block:4\"*) block=4 ;;
        *\"block:0\"*) block=0 ;;
        *) exit 2 ;;
    esac
    printf '{"host_id":"%s",%s"metadata":{"block:%s":{"child":{"name":"term"}}}}\n' "$2" "$3" "$block"
}
case "$9" in
    *'"more":true'*) ;;
    *) respond "$9" remote ""; exit ;;
esac
if [ "$mode" = legacy ]; then respond "$9" remote ""; exit; fi
respond "$9" remote '"imux_metadata_stream":true,'
while IFS= read -r batch; do
    case "$mode" in
        broken) exit 1 ;;
        changed) respond "$batch" replacement ""; exit ;;
        stalled) echo ready > "$root/stalled"; exec sleep 30 ;;
    esac
    respond "$batch" remote ""
done
"#).unwrap();
        fs::set_permissions(&cli, fs::Permissions::from_mode(0o700)).unwrap();
        let job = |name: &str| MetadataJob {
            route: LayoutJob {
                host: Host { label: name.into(), id: name.into(), host_id: "remote".into(), endpoints: vec![] },
                aliases: Vec::new(), host_id: "remote".into(), tunnel: None,
            },
            panes: (0..9).map(|i| MetadataPane {
                session_id: "session:one".into(), block_id: format!("block:{i}"), focused: false,
            }).collect(),
        };
        for (name, processes, batches) in [("current", 1, 3), ("legacy", 3, 3),
                                            ("broken", 3, 3), ("changed", 1, 1)] {
            let (sender, updates) = mpsc::channel();
            collect_metadata(&cli, &sender, job(name), &AtomicBool::new(false));
            let keys: Vec<_> = updates.try_iter().flat_map(|update| {
                let Update::Metadata(_, rows) = update else { panic!("unexpected update") };
                rows.into_values().flat_map(|panes| panes.into_keys())
            }).collect();
            assert_eq!(keys, ["block:0", "block:4", "block:8"][..batches], "{name}");
            assert_eq!(fs::read_to_string(root.join(format!("{name}.pids"))).unwrap().lines().count(), processes, "{name}");
        }
        let cancelled = AtomicBool::new(false);
        let (sender, updates) = mpsc::channel();
        thread::scope(|scope| {
            let task = scope.spawn(|| collect_metadata(&cli, &sender, job("stalled"), &cancelled));
            let limit = Instant::now() + Duration::from_secs(3);
            while !root.join("stalled").exists() {
                assert!(Instant::now() < limit, "fixture did not enter second read");
                thread::sleep(Duration::from_millis(5));
            }
            assert_eq!(updates.try_iter().count(), 1, "first batch was withheld");
            cancelled.store(true, Ordering::Relaxed);
            let start = Instant::now();
            task.join().unwrap();
            assert!(start.elapsed() < Duration::from_secs(2), "cancel waited for the eight second timeout");
        });
        let pid = fs::read_to_string(root.join("stalled.pids")).unwrap();
        extern "C" { fn kill(pid: i32, signal: i32) -> i32; }
        assert_ne!(unsafe { kill(pid.trim().parse().unwrap(), 0) }, 0, "metadata client survived shutdown");
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn shares_enrichment_only_for_aliases_from_one_verified_forward() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!("imux-tunnel-review-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        assert!(Command::new("/usr/bin/mkfifo")
            .arg(root.join("probe-started"))
            .arg(root.join("hold-probe"))
            .status().unwrap().success());
        let rex = root.join("rex");
        fs::write(&rex, r#"#!/bin/sh
[ "$1" = --version ] && exit 0
root=${0%/*}
route=${4#--server=}
case "$route" in
    ready)
        if [ "$7" = session.bootstrap ]; then IFS= read -r started < "$root/probe-started"; fi ;;
    stale-*)
        echo "$$" >> "$root/stalled"
        if [ "$route" = stale-0 ]; then echo started > "$root/probe-started"; fi
        # The fixture never releases this FIFO. The worker must reap the probe.
        IFS= read -r release < "$root/hold-probe"
        exit 1 ;;
    office) ;;
    *) exit 2 ;;
esac
case "$7" in
    session.bootstrap)
        echo "$route inventory" >> "$root/calls"
        echo '{"server_status":{"host_id":"remote"},"attach_all":{"sessions":[{"session_id":"session:1"}]}}' ;;
    *com.superlogical.terminal.title*)
        echo "$route metadata" >> "$root/calls"
        printf '{"host_id":"remote","metadata":{"block:1":{"child":{"name":"%s"}}}}\n' "$route" ;;
    *picker_block*)
        echo "$route layout" >> "$root/calls"
        echo '{"host_id":"remote","layouts":{"session:1":[{"window_id":"window:1","panes":[{"block_id":"block:1","terminal":true}]}]}}' ;;
    *) exit 3 ;;
esac
"#).unwrap();
        fs::set_permissions(&rex, fs::Permissions::from_mode(0o700)).unwrap();
        // Start the new fixture once before exercising the two-second probe deadline.
        assert!(Command::new(&rex).arg("--version").status().unwrap().success());
        let registration = json!({"hosts": [
            {"label":"build", "host_id":"remote", "endpoints":["ssh://build"]},
            {"label":"alias", "host_id":"remote", "endpoints":["ssh://build"]},
            {"label":"office", "host_id":"remote", "endpoints":["tcp://office"]}
        ]});
        let hosts = host_list(&registration, None).unwrap().hosts;
        let (sender, updates) = mpsc::channel();
        let cancelled = AtomicBool::new(false);
        let mut sockets = vec![PathBuf::from("ready")];
        sockets.extend((0..HOST_WORKERS * 2).map(|index| PathBuf::from(format!("stale-{index}"))));
        let (layouts, jobs) = mpsc::channel();
        refresh_sessions(
            &rex,
            hosts.clone(),
            None,
            &cancelled,
            || sockets,
            |host, aliases, rows| {
                let job = publish_sessions(&sender, host, aliases, rows).unwrap();
                layouts.send(job).unwrap();
            },
        );
        let stalled = fs::read_to_string(root.join("stalled")).unwrap();
        assert!(!stalled.is_empty() && stalled.lines().count() < HOST_WORKERS);
        extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
        }
        for pid in stalled.lines().map(|pid| pid.parse::<i32>().unwrap()) {
            assert_ne!(unsafe { kill(pid, 0) }, 0, "probe {pid} survived discovery");
        }
        for (job, ids) in jobs.try_iter() {
            let meta = collect_layout(&rex, &sender, job, ids, &cancelled, &Connections::default()).unwrap();
            collect_metadata(&rex, &sender, meta, &cancelled);
        }
        let calls = fs::read_to_string(root.join("calls")).unwrap();
        let mut calls: Vec<_> = calls.lines().collect();
        calls.sort();
        assert_eq!(
            calls,
            [
                "office inventory",
                "office layout",
                "office metadata",
                "ready inventory",
                "ready layout",
                "ready metadata"
            ]
        );
        fs::remove_dir_all(root).unwrap();

        let mut catalog = RemoteCatalog::default();
        for update in updates.try_iter() {
            catalog.apply(update);
        }
        let [build, alias, office] = hosts.as_slice() else {
            unreachable!()
        };
        for host in &hosts {
            let row = &catalog.sessions[host][0];
            assert_eq!(row.info.host, host.label);
            let runtime = row.windows[0].panes[0].runtime.as_ref().unwrap();
            assert_eq!(
                runtime.command,
                if host == office { "office" } else { "ready" }
            );
        }

        // A late forward result cannot alter a stale or reconnected declaration.
        let delayed = LayoutJob {
            host: build.clone(),
            aliases: Vec::new(),
            host_id: "remote".into(),
            tunnel: Some(PathBuf::from("ready")),
        };
        let empty = BTreeMap::from([("session:1".into(), Vec::new())]);
        catalog.apply(Update::Sessions(build.clone(), None));
        assert!(!catalog.apply(Update::Layouts(delayed.clone(), empty.clone())));
        assert!(!catalog.sessions[alias][0].stale);
        let mut reconnected = catalog.sessions[build].clone();
        reconnected[0].info.tunnel = Some(PathBuf::from("new-forward"));
        reconnected[0].stale = false;
        catalog.apply(Update::Sessions(build.clone(), Some(reconnected)));
        assert!(!catalog.apply(Update::Layouts(delayed.clone(), empty)));
        let stale_meta = read_metadata(
            &metadata_panes(&BTreeMap::from([(
                "session:1".into(),
                catalog.sessions[build][0].windows.clone(),
            )])),
            &json!({"block:1":{"child":{"name":"late"}}}),
        );
        assert!(!catalog.apply(Update::Metadata(delayed, stale_meta)));
        assert_eq!(
            catalog.sessions[build][0].windows[0].panes[0]
                .runtime
                .as_ref()
                .unwrap()
                .command,
            "ready"
        );
        catalog.apply(Update::Hosts(HostList {
            hosts: vec![alias.clone()],
            complete: true,
        }));
        assert_eq!(catalog.sessions().next().unwrap().info.host, "alias");
        assert!(catalog.sessions[alias][0].windows[0].panes[0]
            .runtime
            .is_some());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn activation_addresses_the_originating_app_and_its_exact_connected_host() {
        // Execute the real dispatch script in the platform's JavaScript engine
        // with two synthetic Macs. The second app has an identically named host
        // and session. A disconnected first app must never redirect the action.
        let script = format!(
            "const open = (function(Application) {{ {SHOW_SESSION} return run; }})(resolve);"
        ) + r#"
function run() {
    let connected = true, copies = 1, remote = true, hostName = "build", denied = false;
    let available = true, reads = [], shown = [];
    function app(pid) {
        return {
            id: () => "com.superlogical.rex",
            hosts: {whose: ({name}) => () => {
                reads.push("hosts");
                if (name !== "build") return [];
                return Array.from({length: copies}, () => ({properties() {
                    reads.push("host properties");
                    return {connected: connected || pid === 2, id: "server-key", name: "build"};
                }}));
            }},
            sessions: {byId: id => ({properties() {
                reads.push("session properties");
                if (denied) throw Object.assign(Error("Denied"), {errorNumber: -1743});
                if (!available || id !== "server-key/session:same") {
                    throw Object.assign(Error("Missing object"), {errorNumber: -1728});
                }
                return {id, remote, hostName};
            }})},
            show: () => shown.push(pid)
        };
    }
    makeApp = app;
    const pick = () => JSON.parse(open(["1", "build", "session:same"]));
    if (!pick().shown) throw Error("Failed to activate exact remote session");
    if (reads.join(",") !== "hosts,host properties,session properties") throw Error("Repeated property lookups");
    connected = false;
    if (!pick().error) throw Error("Did not report disconnected origin");
    connected = true; available = false;
    if (!pick().error.includes("no longer available")) throw Error("Did not report vanished session");
    available = true; copies = 2;
    if (!pick().error) throw Error("Accepted duplicate host names");
    copies = 1; remote = false;
    if (!pick().error) throw Error("Accepted local session");
    remote = true; hostName = "BUILD";
    if (!pick().error) throw Error("Accepted another host");
    hostName = "build"; denied = true;
    if (!pick().error.includes("Automation")) throw Error("Lost the permission error");
    if (shown.join(",") !== "1") throw Error("Wrong app or stale session selected");
}
var makeApp;
function resolve(pid) { return makeApp(pid); }
"#;
        let result = Command::new("/usr/bin/osascript")
            .args(["-l", "JavaScript", "-e", &script])
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
    }

    #[test]
    fn ignores_local_aliases_and_verifies_the_actual_remote_server() {
        let list = host_list(
            &json!({ "hosts": [
            { "host": { "label": "local alias", "host_id": "local" } },
            { "host": { "label": "build", "host_id": "remote" } },
            { "label": "flat host", "endpoint": "ssh://flat" }
        ] }),
            Some("local"),
        )
        .unwrap();
        let [remote, flat] = &list.hosts[..] else {
            panic!("local alias was not removed")
        };
        let data = json!({ "host_id": "remote", "sessions": [
            { "session_id": "session:1", "label": "Build" }
        ] });
        assert_eq!(
            read_sessions(remote, &data, Some("local")).unwrap()[0].info.host,
            "build"
        );
        assert!(read_sessions(remote, &json!({"host_id": "replaced"}), Some("local")).is_err());
        assert!(read_sessions(flat, &data, Some("remote"))
            .unwrap()
            .is_empty());
        assert!(
            read_sessions(remote, &json!({"host_id":"remote","sessions":{}}), None)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn origin_uses_registered_host_identity_before_a_unique_session_fallback() {
        let mut cache = RemoteCatalog::default();
        let list = host_list(&json!({"hosts": [
            {"label":"build","host_id":"one"}, {"label":"ci","host_id":"one"},
            {"label":"other","host_id":"two"}, {"label":"offline","host_id":"three"}
        ]}), None).unwrap();
        let hosts = list.hosts.clone();
        cache.apply(Update::Hosts(list));
        let populate = |catalog: &mut RemoteCatalog, host: &Host, sessions: Value| {
            let rows = read_sessions(host, &json!({"host_id":host.host_id,"sessions":sessions}), None).unwrap();
            catalog.apply(Update::Sessions(host.clone(), Some(rows)));
        };
        let shared = json!([{"session_id":"session:shared"}]);
        populate(&mut cache, &hosts[0], shared.clone());
        assert_eq!(cache.origin_session("ci", "session:shared").unwrap().host_id, "one");
        populate(&mut cache, &hosts[1], shared.clone());
        assert_eq!(cache.origin_session("private-key", "session:shared").unwrap().host_id, "one");
        // A registered host without a catalog cannot inherit another host's session.
        assert!(cache.origin_session("offline", "session:shared").is_none());
        assert!(cache.origin_session("three", "session:shared").is_none());
        populate(&mut cache, &hosts[2], shared);
        assert!(cache.origin_session("private-key", "session:shared").is_none());
        assert_eq!(cache.origin_session("CI", "session:shared").unwrap().host_id, "one");
        assert_eq!(cache.origin_session("two", "session:shared").unwrap().host, "other");
        populate(&mut cache, &hosts[2], json!([]));
        cache.apply(Update::Sessions(hosts[3].clone(), None));
        assert!(cache.origin_session("private-key", "session:shared").is_none());
        assert_eq!(cache.origin_session("CI", "session:shared").unwrap().host_id, "one");
    }

    #[test]
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    fn resident_catalog_offer_waits_for_an_unanswered_physical_declaration() {
        let pid = std::process::id();
        let app = LocalApp { pid, birth: crate::worker_identity::get(pid).unwrap() };
        let mut catalog = RemoteCatalog::default();
        let (_sender, receiver) = mpsc::channel();
        catalog.worker = Some(Worker {
            receiver, explicit: false, discovering_sessions: true,
            answered_before_app: Some(HashSet::new()), cancelled: Arc::default(),
            native_catalog: Some(NativeCatalog {
                token: 7, app: app.clone(), declarations: Vec::new(), offered: false,
            }),
            thread: thread::spawn(|| {}),
        });
        assert!(catalog.take_catalog_offer(Some(&app)).is_none());
        let list = |entries: Value| host_list(&json!({"hosts":entries}), None).unwrap();
        catalog.apply(Update::Hosts(list(json!([{"label":"unverified"}]))));
        assert!(catalog.take_catalog_offer(Some(&app)).is_none());
        let declarations = list(json!([{"label":"ready","host_id":"r"},{"label":"waiting","host_id":"w"}]));
        let ready = declarations.hosts[0].clone();
        catalog.apply(Update::Hosts(declarations));
        catalog.apply(Update::Sessions(ready, Some(Vec::new())));
        let records = json!([
            {"label":"ready","host_id":"r","sessions":[{"session_id":"session:removed"}]},
            {"label":"waiting","host_id":"w","sessions":[{"session_id":"session:early"}]}
        ]);
        assert!(!catalog.accept_catalog(7, &records, Some(&app), None), "a token is usable only after it was offered");
        assert!(catalog.take_catalog_offer(None).is_none());
        assert_eq!(catalog.take_catalog_offer(Some(&app)).unwrap(), json!({"token":7,"pid":pid,"birth":app.birth}));
        assert!(catalog.take_catalog_offer(Some(&app)).is_none());
        assert!(catalog.accept_catalog(7, &records, Some(&app), None));
        assert_eq!(catalog.sessions().map(|s| s.info.session_id.as_str()).collect::<Vec<_>>(), ["session:early"]);
        assert!(catalog.worker.as_ref().unwrap().native_catalog.is_none());
    }

    #[test]
    fn early_app_sessions_require_exact_declarations_and_yield_to_every_server_result() {
        let declarations = json!({"hosts":[
            {"label":"build","host_id":"r"}, {"label":"empty","host_id":"e"},
            {"label":"down","host_id":"d"}, {"label":"changed","host_id":"before"},
            {"label":"case","host_id":"c"}, {"label":"unknown"}, {"label":"duplicate","host_id":"x"}
        ]});
        let list = host_list(&declarations, None).unwrap();
        let hosts = list.hosts.clone();
        let record = |label: &str, host_id: &str| json!({"label":label,"host_id":host_id,
            "sessions":[{"session_id":"session:one","label":"early"}]});
        let app = json!({"hosts":[record("build","r"),record("empty","e"),record("down","d"),
            record("changed","after"),record("CASE","c"),record("unknown","u"),record("other","o"),
            record("duplicate","x"),record("duplicate","x")]});
        let early = || Update::AppSessions(app_session_rows(&hosts, &app["hosts"], None));
        let (_, receiver) = mpsc::channel();
        let mut cache = RemoteCatalog::default();
        cache.worker = Some(Worker {
            receiver, explicit: false, discovering_sessions: true, answered_before_app: Some(HashSet::new()),
            native_catalog: None, cancelled: Arc::default(), thread: thread::spawn(|| {}),
        });
        cache.apply(Update::Hosts(list));
        cache.apply(Update::Sessions(hosts[1].clone(), Some(Vec::new())));
        cache.apply(Update::Sessions(hosts[2].clone(), None));
        assert!(cache.apply(early()));
        let first = cache.sessions().next().unwrap();
        assert_eq!(first.info.host, "build");
        assert!(first.windows.is_empty());
        assert_eq!(cache.sessions().count(), 1);
        cache.apply(Update::Sessions(hosts[0].clone(), Some(Vec::new())));
        cache.apply(Update::SessionsReady);
        assert!(!cache.apply(early()));
        assert_eq!(cache.sessions().count(), 0);
    }

    #[test]
    fn publishes_one_host_at_a_time_and_preserves_failed_rows_as_stale() {
        let mut cache = RemoteCatalog::default();
        let list = host_list(
            &json!({"hosts": [{"label":"build"}, {"label":"slow"}]}),
            None,
        )
        .unwrap();
        let [build, slow] = &list.hosts[..] else {
            unreachable!()
        };
        let snapshot =
            |host: &Host| {
                read_sessions(host, &json!({
            "host_id":host.label, "sessions":[{"session_id":"session:1","label":host.label}]
        }), None).unwrap()
            };
        cache.apply(Update::Sessions(build.clone(), Some(snapshot(build))));
        cache.apply(Update::Sessions(slow.clone(), Some(snapshot(slow))));
        // A partial listing can omit a cached host even when its declaration
        // still exists. Its old rows must leave the fresh part of the catalog.
        assert!(cache.apply(Update::Hosts(HostList {
            hosts: vec![build.clone()],
            complete: false
        })));
        assert!(!cache.apply(Update::Sessions(slow.clone(), None)));
        assert!(!cache.apply(Update::Sessions(slow.clone(), None)));
        assert_eq!(
            cache
                .sessions()
                .map(|s| (s.info.host.as_str(), s.stale))
                .collect::<Vec<_>>(),
            [("build", false), ("slow", true)]
        );
        assert!(cache.apply(Update::Sessions(slow.clone(), Some(Vec::new()))));
        assert_eq!(cache.sessions().count(), 1);
        assert!(cache.apply(Update::Hosts(HostList {
            hosts: vec![slow.clone()],
            complete: true
        })));
        assert_eq!(cache.sessions().count(), 0);
    }

    #[test]
    fn preserves_cached_layouts_for_missing_sessions_and_replaces_complete_branches() {
        let host = host_list(&json!({"hosts": [{"label":"build"}]}), None)
            .unwrap()
            .hosts
            .pop()
            .unwrap();
        let snapshot = || {
            read_sessions(
                &host,
                &json!({"host_id":"remote", "sessions":[
                    {"session_id":"session:complete","label":"Build"},
                    {"session_id":"session:missing","label":"Other"}
                ]}),
                None,
            )
            .unwrap()
        };
        let job = || LayoutJob {
            aliases: Vec::new(),
            host: host.clone(),
            host_id: "remote".into(),
            tunnel: None,
        };
        let mut cache = RemoteCatalog::default();
        assert!(cache.apply(Update::Sessions(host.clone(), Some(snapshot()))));
        let window = json!({"window_id":"window:one","active":true,"panes":[
            {"block_id":"block:first","label":"editor","focused":true},
            {"block_id":"block:second","label":"logs"}
        ]});
        let layouts = read_layouts(
            "remote",
            &json!({"host_id":"remote","layouts":{
                "session:complete":[window.clone()], "session:missing":[window.clone()]
            }}),
        );
        assert!(cache.apply(Update::Layouts(job(), layouts)));
        let first = cache.sessions().next().unwrap();
        assert!(first.windows[0].active && first.windows[0].panes[0].focused);
        assert!(first.windows[0].label.is_empty());
        assert_eq!(first.windows[0].panes[1].label, "logs");
        assert!(!cache.apply(Update::Sessions(host.clone(), Some(snapshot()))));

        // The first session is authoritatively empty. The second view is
        // incomplete, so its existing branch stays available as stale data.
        let partial = read_layouts(
            "remote",
            &json!({"host_id":"remote","layouts":{
                "session:complete":{},
                "session:missing":[{"window_id":"window:one","panes":[{"label":"broken"}]}]
            }}),
        );
        assert!(cache.apply(Update::Layouts(job(), partial)));
        let rows: Vec<_> = cache.sessions().collect();
        assert!(rows[0].windows.is_empty() && !rows[0].layout_stale);
        assert_eq!(rows[1].windows.len(), 1);
        assert!(rows[1].layout_stale && !rows[1].stale);
        assert!(cache.apply(Update::Sessions(host.clone(), None)));
        assert!(cache.sessions().all(|session| session.stale));
        let mut renamed = snapshot();
        renamed[1].info.label = "Renamed".into();
        renamed.reverse();
        assert!(cache.apply(Update::Sessions(host, Some(renamed))));
        let restored = cache.sessions().next().unwrap();
        assert_eq!(restored.info.label, "Renamed");
        assert_eq!(restored.windows[0].panes[1].label, "logs");
        assert!(restored.layout_stale && !restored.stale);
    }

    #[test]
    fn remote_names_survive_layout_refresh_and_discard_stale_titles() {
        let host = host_list(&json!({"hosts":[{"label":"build"}]}), None)
            .unwrap()
            .hosts
            .pop()
            .unwrap();
        let job = LayoutJob {
            aliases: Vec::new(),
            host: host.clone(),
            host_id: "remote".into(),
            tunnel: None,
        };
        let sessions = read_sessions(
            &host,
            &json!({"host_id":"remote", "sessions":[
                {"session_id":"session:one", "label":"Workspace"}
            ]}),
            None,
        )
        .unwrap();
        let layouts = read_layouts(
            "remote",
            &json!({"host_id":"remote", "layouts":{
                "session:one":[{"window_id":"window:one", "panes":[
                    {"block_id":"block:terminal", "terminal":true, "focused":true},
                    {"block_id":"block:application"}
                ]}]
            }}),
        );
        let batch = metadata_panes(&layouts);
        assert_eq!(batch.len(), 1);
        assert_eq!(batch[0].block_id, "block:terminal");

        let mut cache = RemoteCatalog::default();
        cache.apply(Update::Sessions(host, Some(sessions)));
        cache.apply(Update::Layouts(job.clone(), layouts.clone()));
        let runtime = read_metadata(
            &batch,
            &json!({
                "block:terminal": {
                    "foreground":{"pid":42,"name":"zsh","argv0":"-zsh","cwd":"/remote/work"},
                    "title":"Workspace title", "title_owner":{"pid":42,"name":"zsh"}
                },
                "block:application":{"foreground":{"pid":13,"name":"unrequested"}}
            }),
        );
        assert!(cache.apply(Update::Metadata(job.clone(), runtime)));
        assert!(!cache.apply(Update::Layouts(job.clone(), layouts)));
        let panes = &cache.sessions().next().unwrap().windows[0].panes;
        assert_eq!(
            panes[0].runtime.as_ref().unwrap(),
            &RemotePaneRuntime {
                command: "zsh".into(),
                title: "Workspace title".into(),
                cwd: "/remote/work".into()
            }
        );
        assert!(panes[1].runtime.is_none());

        let runtime = read_metadata(
            &batch,
            &json!({"block:terminal":{
                "foreground":{"pid":43,"name":"nvim"},
                "title":"Workspace title", "title_owner":{"pid":42,"name":"zsh"}
            }}),
        );
        assert!(cache.apply(Update::Metadata(job, runtime)));
        let details = cache.sessions().next().unwrap().windows[0].panes[0]
            .runtime
            .as_ref()
            .unwrap();
        assert_eq!(details.command, "nvim");
        assert!(details.title.is_empty());
    }
}
