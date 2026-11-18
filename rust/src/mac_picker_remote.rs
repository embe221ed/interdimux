//! Discover and refresh Rex host catalogs independently of the local picker.

use crate::dirs::bounded_command_output;
use crate::rex;
#[cfg(test)]
use serde_json::json;
use serde_json::Value;
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const HOST_WORKERS: usize = 4;
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

// The Rex Mac scripting dictionary exposes each connected host and its
// host-scoped session objects. Always address the exact local app process.
const SHOW_SESSION: &str = include_str!("rex_show_session.js");

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct RemoteSession {
    pub host: String,
    pub host_id: String,
    pub session_id: String,
    pub label: String,
    pub stale: bool,
    pub tunnel: Option<PathBuf>,
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

enum Update {
    Hosts(HostList),
    Sessions(Host, Option<Vec<RemoteSession>>),
    DiscoveryFailed,
}

struct Worker {
    receiver: Receiver<Update>,
    cancelled: Arc<AtomicBool>,
    thread: JoinHandle<()>,
}

#[derive(Default)]
pub(super) struct RemoteCatalog {
    sessions: BTreeMap<Host, Vec<RemoteSession>>,
    worker: Option<Worker>,
}

impl RemoteCatalog {
    /// Keep the previous catalog usable throughout one shared refresh.
    pub fn refresh(&mut self, local_host_id: Option<String>) {
        if self.worker.is_some() {
            return;
        }
        let (sender, receiver) = mpsc::channel();
        let cancelled = Arc::new(AtomicBool::new(false));
        let worker_cancelled = cancelled.clone();
        if let Ok(thread) = thread::Builder::new()
            .name("imux-rex-hosts".into())
            .spawn(move || run_refresh(sender, local_host_id.as_deref(), &worker_cancelled))
        {
            self.worker = Some(Worker {
                receiver,
                cancelled,
                thread,
            });
        }
    }

    pub fn pending(&self) -> bool {
        self.worker.is_some()
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
        match update {
            Update::Hosts(list) => {
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
                changed
            }
            Update::Sessions(host, Some(sessions)) => {
                let changed = self.sessions.get(&host) != Some(&sessions);
                self.sessions.insert(host, sessions);
                changed
            }
            Update::Sessions(host, None) => {
                mark_stale(self.sessions.get_mut(&host).into_iter().flatten())
            }
            Update::DiscoveryFailed => mark_stale(self.sessions.values_mut().flatten()),
        }
    }

    pub fn sessions(&self) -> impl Iterator<Item = &RemoteSession> {
        let all = self.sessions.values().flatten();
        let mut seen = HashSet::new();
        all.clone()
            .filter(|row| !row.stale)
            .chain(all.filter(|row| row.stale))
            .filter(move |row| seen.insert((&row.host_id, &row.session_id)))
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

fn run_refresh(sender: Sender<Update>, local_host_id: Option<&str>, cancelled: &AtomicBool) {
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
    let collect_host = |host: Host| {
        let sessions = request(
            &binary,
            Some(&host.label),
            &["do", "-e", SNAPSHOT],
            REFRESH_TIMEOUT,
            || cancelled.load(Ordering::Relaxed),
        )
        .and_then(|data| read_sessions(&host, &data, local_host_id));
        let _ = sender.send(Update::Sessions(host, sessions.ok()));
    };
    let via_tunnel = |host: &Host| host.uses_ssh() && !host.host_id.is_empty();
    let sockets = if hosts.iter().any(via_tunnel) {
        ssh_tunnels()
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
        collect_in_parallel(sockets, tunnel_workers, cancelled, |socket| {
            let Some(endpoint) = socket.to_str() else {
                return;
            };
            let Ok(data) = request(
                &binary,
                Some(endpoint),
                &["do", "-e", SNAPSHOT],
                TUNNEL_PROBE_TIMEOUT,
                || cancelled.load(Ordering::Relaxed),
            ) else {
                return;
            };
            let host_id = string(&data["host_id"]);
            if host_id.is_empty() {
                return;
            }
            for host in tunneled.iter().filter(|host| host.host_id == host_id) {
                if let Ok(mut sessions) = read_sessions(host, &data, local_host_id) {
                    for session in &mut sessions {
                        session.tunnel = Some(socket.clone());
                    }
                    if resolved.lock().unwrap().insert(host.label.clone()) {
                        let _ = sender.send(Update::Sessions(host.clone(), Some(sessions)));
                    }
                }
            }
        });
        let resolved = resolved.into_inner().unwrap();
        let remaining = tunneled
            .into_iter()
            .filter(|host| !resolved.contains(&host.label))
            .collect();
        collect_in_parallel(remaining, tunnel_workers, cancelled, collect_host);
    });
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
                host: host.label.clone(),
                host_id: host_id.to_owned(),
                session_id: session_id.to_owned(),
                label: if label.is_empty() { session_id } else { label }.to_owned(),
                stale: false,
                tunnel: None,
            })
        })
        .collect())
}

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
}

pub(super) fn activate(session: &RemoteSession, app: Option<&LocalApp>) -> Result<(), String> {
    let app =
        app.ok_or("Reopen the picker from a running local Rex app to switch remote sessions.")?;
    let binary = rex::resolve_binary()?;
    let endpoint = session
        .tunnel
        .as_deref()
        .filter(|path| is_ssh_tunnel(path))
        .and_then(Path::to_str)
        .unwrap_or(&session.host);
    let data = request(
        &binary,
        Some(endpoint),
        &["do", "-e", SNAPSHOT],
        REFRESH_TIMEOUT,
        || false,
    )
    .map_err(|error| format!("{}: {error}", session.host))?;
    if data["host_id"] != session.host_id
        || !data["sessions"].as_array().is_some_and(|sessions| {
            sessions
                .iter()
                .any(|s| s["session_id"] == session.session_id)
        })
    {
        return Err("The host or session changed. Refresh the picker before switching.".into());
    }
    if crate::worker_identity::get(app.pid).as_ref() != Some(&app.birth) {
        return Err("The original Rex app closed. Reopen the picker from the intended app.".into());
    }
    let mut command = Command::new("/usr/bin/osascript");
    command
        .args(["-l", "JavaScript", "-e", SHOW_SESSION, "--"])
        .arg(app.pid.to_string())
        .arg(&session.host)
        .arg(&session.session_id);
    let output = bounded_command_output(command, ACTIVATE_TIMEOUT, OUTPUT_LIMIT, || false)
        .map_err(|error| format!("Cannot show the session in the local Rex app: {error}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
    }
    let reply: Value = serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("Invalid response from Rex automation: {error}"))?;
    if reply["shown"] != true {
        return Err(reply["error"]
            .as_str()
            .unwrap_or("Rex did not show the selected session.")
            .into());
    }
    Ok(())
}

fn request(
    binary: &Path,
    host: Option<&str>,
    args: &[&str],
    timeout: Duration,
    cancelled: impl Fn() -> bool,
) -> Result<Value, String> {
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
    command.args(args);
    let output = bounded_command_output(command, timeout, OUTPUT_LIMIT, cancelled)
        .map_err(|error| format!("Rex CLI: {error}"))?;
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
    let connected = true, available = true, shown = [];
    function app(pid) {
        return {
            id: () => "com.superlogical.rex",
            hosts: {whose: ({name}) => () => name === "build" ? [{
                connected: () => connected || pid === 2, id: () => "server-key"
            }] : []},
            sessions: {byId: (id) => ({
                exists: () => available && id === "server-key/session:same",
                remote: () => true, hostName: () => "build"
            })},
            show: () => shown.push(pid)
        };
    }
    makeApp = app;
    const pick = () => JSON.parse(open(["1", "build", "session:same"]));
    if (!pick().shown) throw Error("Failed to activate exact remote session");
    connected = false;
    if (!pick().error) throw Error("Did not report disconnected origin");
    connected = true; available = false;
    if (!pick().error) throw Error("Did not report vanished session");
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
            read_sessions(remote, &data, Some("local")).unwrap()[0].host,
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
                .map(|s| (s.host.as_str(), s.stale))
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
}
