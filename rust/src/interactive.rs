//! Persistent shared picker controller. fzf stays alive across native actions.
//! Helpers connect over a private local socket; labels never become shell code.
#![cfg(unix)]

use crate::model::{Row, Snapshot, Target};
use crate::navigator::Mode;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::{self, DirBuilder};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::{
    fs::DirBuilderExt,
    net::{UnixListener, UnixStream},
};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc,
};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub(crate) trait Adapter: Sync {
    fn workspace(&self) -> Option<PathBuf> {
        None
    }
    fn live_snapshot(&self) -> Option<PathBuf> {
        None
    }
    fn refresh(&self) -> Result<Snapshot, String>;
    fn cached(&self) -> Result<Snapshot, String>;
    fn action(
        &self,
        operation: &str,
        target: Option<&Target>,
        args: &Value,
    ) -> Result<Value, String>;
    fn activate(&self, target: &Target) -> Result<(), String>;
    fn backend_name(&self) -> &'static str;
}

struct Directory(PathBuf);

#[derive(Default)]
struct LiveUpdate {
    requested: AtomicU64,
    consumed: AtomicU64,
    deferred: AtomicBool,
}
impl LiveUpdate {
    fn pending(&self) -> bool {
        self.requested.load(Ordering::Acquire) != self.consumed.load(Ordering::Acquire)
    }
    fn acknowledge(&self, generation: u64) {
        self.consumed.fetch_max(generation, Ordering::AcqRel);
    }
}
impl Directory {
    fn new(parent: Option<PathBuf>) -> Result<Self, String> {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let path = parent.map(|base| base.join("ui")).unwrap_or_else(|| {
            std::env::temp_dir().join(format!("imux-ui-{}-{stamp}", std::process::id()))
        });
        DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .map_err(|e| e.to_string())?;
        Ok(Self(path))
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

pub(crate) fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

pub(crate) fn target_json(target: &Target) -> Value {
    match target {
        Target::Rex {
            session_id,
            window_id,
            block_id,
        } => {
            let mut value = json!({"session_id":session_id});
            if let Some(id) = window_id {
                value["window_id"] = json!(id)
            }
            if let Some(id) = block_id {
                value["block_id"] = json!(id)
            }
            value
        }
        Target::TmuxNative {
            session_id,
            window_id,
            pane_id,
        } => {
            let mut value = json!({"session_id":session_id});
            if let Some(id) = window_id {
                value["window_id"] = json!(id)
            }
            if let Some(id) = pane_id {
                value["pane_id"] = json!(id)
            }
            value
        }
        Target::Directory { path } => json!({"path":path}),
        Target::TmuxLegacy { spec } => json!({"spec":spec}),
    }
}

pub(crate) fn decode_target(value: &Value, backend: &str) -> Result<Target, String> {
    let session_id = value["session_id"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("The backend returned no session ID")?
        .to_owned();
    let window_id = value["window_id"].as_str().map(str::to_owned);
    if backend == "rex" {
        Ok(Target::Rex {
            session_id,
            window_id,
            block_id: value["block_id"].as_str().map(str::to_owned),
        })
    } else {
        Ok(Target::TmuxNative {
            session_id,
            window_id,
            pane_id: value["pane_id"].as_str().map(str::to_owned),
        })
    }
}

fn safe_status(text: &str) -> String {
    text.chars()
        .map(|c| {
            if c.is_control() || "()[]{}+\\".contains(c) || matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}') {
                ' '
            } else {
                c
            }
        })
        .take(220)
        .collect()
}

fn status(text: &str) -> String {
    format!("change-header({})", safe_status(text))
}

struct Runtime<'a, A: Adapter> {
    adapter: &'a A,
    snapshot: Snapshot,
    prepared: crate::navigator::PreparedRows,
    targets: Vec<Target>,
    target_indices: HashMap<Target, usize>,
    rows: String,
    scope: crate::search::Scope,
    message: String,
    swap_source: Option<Target>,
    pending_query: Option<String>,
    final_done: Arc<AtomicBool>,
    preview_cache: HashMap<String, (std::time::Instant, String)>,
    cols: usize,
    full_cols: usize,
    preview_open: bool,
    mode: Mode,
    agent_states: Vec<String>,
    startup_abort: bool,
    live_pending: Arc<LiveUpdate>,
    live_rows_dirty: bool,
}

impl<A: Adapter> Runtime<'_, A> {
    fn update_rows(&mut self) {
        let rows = self.prepared.rows(
            &self.snapshot,
            self.cols.saturating_sub(3),
            self.mode,
            &self.agent_states,
        );
        let mut output = String::new();
        for row in rows {
            let index = if let Some(index) = self.target_indices.get(&row.target) {
                *index
            } else {
                let index = self.targets.len();
                self.targets.push(row.target.clone());
                self.target_indices.insert(row.target.clone(), index);
                index
            };
            output.push_str(&format!(
                "{}\t{}\t{}\timux:{index}\n",
                row.identity, row.context, row.command
            ));
        }
        self.live_rows_dirty |= self.rows != output;
        self.rows = output;
    }
    fn target(&self, request: &Value) -> Result<Target, String> {
        let token = request["token"].as_str().unwrap_or("");
        let index: usize = token
            .strip_prefix("imux:")
            .and_then(|n| n.parse().ok())
            .ok_or("Select a target first")?;
        let target = self
            .targets
            .get(index)
            .ok_or("This target is no longer available")?;
        if matches!(target, Target::Directory { .. }) {
            return Ok(target.clone());
        }
        // Old tokens are never reused; an item removed by a refresh cannot
        // accidentally refer to the row that took its place.
        if !self.snapshot.sessions.iter().any(|s| &s.target == target)
            && !self.snapshot.windows.iter().any(|w| &w.target == target)
            && !self.snapshot.panes.iter().any(|p| &p.target == target)
        {
            return Err("This target no longer exists; reload the list".into());
        }
        Ok(target.clone())
    }
    fn matching(&self, request: &Value) -> Result<(), String> {
        if request["matches"].as_u64() == Some(0) {
            return Err("No matching target".into());
        }
        if request["raw"].as_str() == Some("0") {
            return Err("This row does not match; Ctrl+n/p moves between matches".into());
        }
        Ok(())
    }
    fn refresh(&mut self) -> Result<(), String> {
        self.snapshot = self.adapter.refresh()?;
        crate::navigator::hide(&mut self.snapshot);
        self.preview_cache.clear();
        self.prepared = crate::navigator::PreparedRows::new(&self.snapshot);
        self.update_rows();
        Ok(())
    }
    fn cached(&mut self) -> Result<(), String> {
        self.snapshot = self.adapter.cached()?;
        crate::navigator::hide(&mut self.snapshot);
        self.preview_cache.clear();
        self.prepared = crate::navigator::PreparedRows::new(&self.snapshot);
        self.update_rows();
        Ok(())
    }
    fn describe(&self, target: &Target) -> Value {
        if let Target::Directory { path } = target {
            return json!({"kind":"directory","name":Path::new(path).file_name().and_then(|s|s.to_str()).unwrap_or(path),"cwd":path,"count":0});
        }
        if let Some(pane) = self.snapshot.panes.iter().find(|p| &p.target == target) {
            return json!({"kind":"pane","name":pane.name,"cwd":pane.path,"count":1});
        }
        if let Some(window) = self.snapshot.windows.iter().find(|w| &w.target == target) {
            return json!({"kind":"window","name":window.name,"cwd":window.path,"count":window.pane_count});
        }
        if let Some(session) = self.snapshot.sessions.iter().find(|s| &s.target == target) {
            let count = self
                .snapshot
                .panes
                .iter()
                .filter(|p| p.session_key == session.key)
                .count();
            return json!({"kind":"session","name":session.name,"cwd":session.path,"count":count});
        }
        json!({})
    }
    fn action_target(&self, target: Target, operation: &str) -> Target {
        row_action_target(&self.snapshot, target, operation)
    }
    fn create_and_activate(&self, query: &str) -> Result<(), String> {
        let resolved = crate::projects::resolve(&self.snapshot, query)?;
        let cwd = resolved.cwd;
        if let Some(target) = resolved.existing_session {
            self.adapter.activate(&target)?;
            if resolved.path_query {
                crate::projects::record_use(&cwd)
            }
            return Ok(());
        }
        let mut args = json!({"name":resolved.name,"cwd":cwd});
        if self.adapter.backend_name() == "tmux"
            || self.adapter.workspace().is_some()
            || self.snapshot.pane_metadata.values().any(|m| m.local)
        {
            if let Some(plan) = crate::startup::plan(&cwd) {
                args["startup_lines"] = json!(plan.lines);
            }
        }
        let data = self.adapter.action("create", None, &args)?;
        let target = decode_target(
            data.get("target").unwrap_or(&data),
            self.adapter.backend_name(),
        )?;
        self.adapter.activate(&target)?;
        if resolved.path_query {
            crate::projects::record_use(&cwd)
        }
        Ok(())
    }
    fn handle(&mut self, request: &Value) -> Result<Value, String> {
        let event = request["event"].as_str().unwrap_or("");
        match event {
            "rows" => {
                // Acknowledge when the reload helper consumes its rows, not when
                // it accepts an HTTP command that a modal can later discard.
                // Acknowledge only this generation, preserving newer events.
                let generation = self.live_pending.requested.load(Ordering::Acquire);
                if self.live_pending.pending() {
                    let _ = self.cached();
                }
                self.live_pending.acknowledge(generation);
                self.live_rows_dirty = false;
                Ok(json!({"text":self.rows}))
            }
            "live" => {
                if self.final_done.load(Ordering::Acquire) {
                    return Ok(json!({"text":""}));
                }
                if !self.live_pending.pending() && !self.live_rows_dirty {
                    return Ok(json!({"text":""}));
                }
                // fzf blocks input while restoring an --id-nth tracked item
                // after reload. Let a burst of typing finish first.
                if request["idle_ms"].as_u64().map_or(false, |idle| idle < 150) {
                    // The helper received this update, so retry on the next
                    // watcher tick. The longer watchdog is only for commands
                    // fzf accepts but discards while opening a modal.
                    self.live_pending.deferred.store(true, Ordering::Release);
                    return Ok(json!({"text":""}));
                }
                let generation = self.live_pending.requested.load(Ordering::Acquire);
                let _ = self.cached();
                if !self.live_rows_dirty {
                    self.live_pending.acknowledge(generation);
                    return Ok(json!({"text":"refresh-preview"}));
                }
                let text = format!(
                    "{}track-current+reload-sync({})+refresh-preview",
                    if request["matches"].as_u64() == Some(0) {
                        "change-header()+"
                    } else {
                        ""
                    },
                    request["reload"].as_str().unwrap_or("true")
                );
                Ok(json!({"text":text}))
            }
            "message" => {
                Ok(json!({"message":self.message,"final":self.final_done.load(Ordering::Acquire)}))
            }
            "startup-finished" => {
                self.startup_abort = request["abort"].as_bool().unwrap_or(false);
                Ok(json!({}))
            }
            "hints" => {
                let target = self.target(request).ok();
                let text = context_footer(
                    self.cols,
                    self.mode,
                    target
                        .as_ref()
                        .map(|t| self.describe(t)["kind"].as_str().unwrap_or("").to_owned())
                        .as_deref(),
                    self.adapter.backend_name(),
                    request["matches"].as_u64() == Some(0),
                );
                Ok(json!({"text":text}))
            }
            "set-mode" => {
                self.mode = Mode::parse(request["mode"].as_str().unwrap_or("switch"))?;
                self.swap_source = None;
                self.scope = if self.mode == Mode::Agents {
                    crate::search::Scope::Name
                } else {
                    crate::search::Scope::default()
                };
                self.pending_query = Some(if self.mode == Mode::Agents {
                    crate::native_agents::query(&self.agent_states)
                } else {
                    String::new()
                });
                self.update_rows();
                self.message = if self.mode == Mode::Agents {
                    format!(
                        "{} agents need attention; clear the query to see every target",
                        crate::native_agents::collect(&self.snapshot, &self.agent_states).len()
                    )
                } else {
                    format!("{}: choose a target", self.mode.label())
                };
                Ok(json!({}))
            }
            "agent-count" => Ok(
                json!({"count":crate::native_agents::collect(&self.snapshot,&self.agent_states).len()}),
            ),
            "dashboard-info" => Ok(
                json!({"backend":self.adapter.backend_name(),"agents":crate::native_agents::collect(&self.snapshot,&self.agent_states).len()}),
            ),
            "agent-next" => {
                let agents = crate::native_agents::collect(&self.snapshot, &self.agent_states);
                if let Some(agent) =
                    crate::native_agents::next(&agents, &self.snapshot.current.pane_key)
                {
                    self.adapter.activate(&agent.target)?;
                    self.final_done.store(true, Ordering::Release);
                    Ok(json!({"text":"abort"}))
                } else {
                    self.message = "No agent needs you".into();
                    Ok(json!({}))
                }
            }
            "enter" => {
                if let Some(operation) = self.mode.operation() {
                    self.matching(request)?;
                    return Ok(json!({"action":operation}));
                }
                let mut accept = request.clone();
                accept["event"] = json!("accept");
                self.handle(&accept)
            }
            "notice" => {
                self.message = request["message"].as_str().unwrap_or("").into();
                Ok(json!({}))
            }
            "health" => Ok(json!({"lines":health_report(self.adapter,&self.snapshot)})),
            "resize" | "layout" => {
                let full_cols = request["columns"]
                    .as_u64()
                    .unwrap_or(self.full_cols as u64)
                    .clamp(20, 1000) as usize;
                if event == "layout" {
                    self.preview_open = !self.preview_open;
                }
                let cols = if self.preview_open {
                    full_cols.saturating_sub(1) / 2
                } else {
                    full_cols
                };
                self.full_cols = full_cols;
                if cols == self.cols && event != "layout" {
                    return Ok(json!({"text":""}));
                }
                self.cols = cols;
                self.update_rows();
                Ok(
                    json!({"text":format!("reload-sync({})+change-footer({})",request["reload"].as_str().unwrap_or("true"),context_footer(self.cols,self.mode,None,self.adapter.backend_name(),false))}),
                )
            }
            "directories" => {
                let entries = crate::projects::directories(
                    &self.snapshot,
                    request["base"].as_str(),
                    request["deep"].as_str(),
                );
                Ok(
                    json!({"entries":entries.iter().map(|d|json!({"path":d.path,"label":d.label,"project":d.project,"existing":d.existing_session.as_ref().map(target_json)})).collect::<Vec<_>>()}),
                )
            }
            "describe" => {
                self.matching(request)?;
                let target = self.action_target(
                    self.target(request)?,
                    request["operation"].as_str().unwrap_or(""),
                );
                Ok(self.describe(&target))
            }
            "scope" => {
                self.scope = crate::search::Scope::from_nth(request["nth"].as_str().unwrap_or(""))
                    .unwrap_or(self.scope)
                    .next();
                Ok(json!({"text":format!("rebind(result)+{}+{}",self.scope.actions(),status(""))}))
            }
            "after" => {
                if self.startup_abort || self.final_done.load(Ordering::Acquire) {
                    return Ok(json!({"text":"abort"}));
                }
                // A modal can discard queued HTTP transforms. Its own reload
                // consumes the pending publication through the rows helper.
                let live_changed = self.live_pending.pending();
                let query = self
                    .pending_query
                    .take()
                    .map(|q| {
                        format!(
                            "+rebind(result)+change-nth({})+change-query({q})",
                            self.scope.nth()
                        )
                    })
                    .unwrap_or_default();
                let text = format!(
                    "{}reload-sync({})+refresh-preview+{}+change-prompt({})+{}(zero){query}",
                    if live_changed { "track-current+" } else { "" },
                    request["reload"].as_str().unwrap_or("true"),
                    status(&self.message),
                    if self.mode == Mode::Switch {
                        self.scope.prompt()
                    } else {
                        format!("{} · {}", self.mode.label(), self.scope.prompt())
                    },
                    if self.mode == Mode::Switch {
                        "rebind"
                    } else {
                        "unbind"
                    }
                );
                self.message.clear();
                Ok(json!({"text":text}))
            }
            "preview" => {
                let target = self.target(request)?;
                let cols = request["columns"].as_u64().unwrap_or(70) as usize;
                let lines = request["lines"].as_u64().unwrap_or(30) as usize;
                if let Target::Directory { path } = &target {
                    return Ok(json!({"text":crate::preview::directory(path,cols,lines)}));
                }
                let key = format!("{:?}:{cols}:{lines}", target);
                if let Some((at, text)) = self.preview_cache.get(&key) {
                    if at.elapsed() < Duration::from_millis(300) {
                        return Ok(json!({"text":text}));
                    }
                }
                self.preview_cache
                    .retain(|_, (at, _)| at.elapsed() < Duration::from_millis(300));
                if self.preview_cache.len() >= 64 {
                    self.preview_cache.clear();
                }
                let capture_target = crate::preview::capture_target(&self.snapshot, &target);
                let captured = capture_target
                    .map(|t| {
                        self.adapter
                            .action("preview", Some(&t), &json!({"lines":lines}))
                    })
                    .unwrap_or_else(|| Err("No terminal in this target".into()));
                let capture = captured
                    .as_ref()
                    .map(|v| v["text"].as_str().unwrap_or(""))
                    .map_err(String::as_str);
                let text = crate::preview::render(&self.snapshot, &target, capture, cols, lines);
                self.preview_cache
                    .insert(key, (std::time::Instant::now(), text.clone()));
                Ok(json!({"text":text}))
            }
            "accept" | "create-query" => {
                if event == "create-query" || request["matches"].as_u64() == Some(0) {
                    if self.mode == Mode::Agents
                        && request["query"]
                            .as_str()
                            .unwrap_or("")
                            .split_whitespace()
                            .any(|s| ["^!", "^?", "^×", "^✓", "^~", "^·", "^@"].contains(&s))
                        && request["explicit"].as_bool() != Some(true)
                    {
                        return Err(
                            "No waiting agent matches; clear the state filter to create a session"
                                .into(),
                        );
                    }
                    self.create_and_activate(request["query"].as_str().unwrap_or(""))?;
                } else {
                    self.matching(request)?;
                    let target = self.target(request)?;
                    if let Target::Directory { path } = &target {
                        let directory = crate::projects::query_directory(path)
                            .ok_or("This recent directory no longer exists")?;
                        self.create_and_activate(&directory)?;
                    } else {
                        self.adapter.activate(&target)?;
                    }
                }
                self.final_done.store(true, Ordering::Release);
                Ok(json!({"text":"abort"}))
            }
            "activate-target" => {
                let target = decode_target(&request["target"], self.adapter.backend_name())?;
                if !self.snapshot.sessions.iter().any(|s| s.target == target) {
                    return Err(
                        "The project session no longer exists; refresh the directories".into(),
                    );
                }
                self.adapter.activate(&target)?;
                if let Some(path) = request["path"].as_str() {
                    if let Some(path) = crate::projects::query_directory(path) {
                        crate::projects::record_use(&path);
                    }
                }
                self.final_done.store(true, Ordering::Release);
                Ok(json!({"text":"abort"}))
            }
            "action" => {
                let op = request["operation"].as_str().ok_or("Missing action")?;
                if op == "agents" {
                    return self.handle(&json!({"event":"set-mode","mode":"agents"}));
                }
                if op == "refresh" {
                    self.refresh()?;
                    self.message = "List refreshed".into();
                    return Ok(json!({}));
                }
                let mut args = request["args"].clone();
                if !args.is_object() {
                    args = json!({});
                }
                let target = if op == "create" && args["kind"].as_str() != Some("window") {
                    None
                } else {
                    self.matching(request)?;
                    Some(self.action_target(
                        self.target(request)?,
                        if op == "create" { "window" } else { op },
                    ))
                };
                if op == "schedule-target" {
                    return self.adapter.action(op, target.as_ref(), &args);
                }
                if matches!(target, Some(Target::Directory { .. })) {
                    return Err("Choose a session, window or pane for this action".into());
                }
                if op == "swap" {
                    if target
                        .as_ref()
                        .map(|t| self.describe(t)["kind"] == "session")
                        .unwrap_or(true)
                    {
                        return Err("Choose a window or pane to swap".into());
                    }
                    if let Some(source) = self.swap_source.take() {
                        if self.describe(&source)["kind"]
                            != self.describe(target.as_ref().unwrap())["kind"]
                        {
                            return Err("Choose two windows or two panes to swap".into());
                        }
                        args["other"] = target_json(&source);
                    } else {
                        self.swap_source = target;
                        self.pending_query = Some(String::new());
                        self.message =
                            "Swap source marked; select the destination and press Ctrl+s again"
                                .into();
                        return Ok(json!({}));
                    }
                }
                let data = self.adapter.action(op, target.as_ref(), &args)?;
                if data["deferred"].as_bool() == Some(true) {
                    self.final_done.store(true, Ordering::Release);
                } else {
                    self.cached()?;
                    self.message = format!("{} completed", op);
                }
                Ok(data)
            }
            _ => Err("Unknown picker request".into()),
        }
    }
}

fn row_action_target(snapshot: &Snapshot, target: Target, operation: &str) -> Target {
    if matches!(operation, "rename" | "close" | "swap" | "window") {
        if let Some(pane) = snapshot.panes.iter().find(|p| p.target == target) {
            if snapshot
                .panes
                .iter()
                .filter(|p| p.session_key == pane.session_key && p.window_key == pane.window_key)
                .count()
                == 1
            {
                if let Some(window) = snapshot
                    .windows
                    .iter()
                    .find(|w| w.session_key == pane.session_key && w.key == pane.window_key)
                {
                    return window.target.clone();
                }
            }
        }
    }
    target
}

fn serve(stream: &mut UnixStream, runtime: &mut Runtime<'_, impl Adapter>) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(3)));
    let mut text = String::new();
    let response = match BufReader::new((&mut *stream).take(1024 * 1024)).read_line(&mut text) {
        Ok(_) => match serde_json::from_str::<Value>(&text) {
            Ok(request) => match runtime.handle(&request) {
                Ok(data) => json!({"ok":true,"data":data}),
                Err(error) => {
                    runtime.message = error.clone();
                    json!({"ok":false,"error":error})
                }
            },
            Err(_) => json!({"ok":false,"error":"Invalid picker request"}),
        },
        Err(e) => json!({"ok":false,"error":format!("picker request: {e}")}),
    };
    if let Ok(mut bytes) = serde_json::to_vec(&response) {
        bytes.push(b'\n');
        let _ = stream.write_all(&bytes);
    }
}

// The socket lives in our mode-0700 workspace. No TCP port or public control
// endpoint is opened. Return false until fzf has initialized its listener.
fn fzf_action(socket: &Path, action: &str) -> bool {
    let Ok(mut stream) = UnixStream::connect(socket) else {
        return false;
    };
    let timeout = Some(Duration::from_millis(250));
    let _ = stream.set_write_timeout(timeout);
    let _ = stream.set_read_timeout(timeout);
    let request = format!("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{action}", action.len());
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }
    let mut line = String::new();
    BufReader::new(stream.take(1024))
        .read_line(&mut line)
        .is_ok()
        && line.split_whitespace().nth(1) == Some("200")
}

fn snapshot_stamp(path: &Path) -> Option<(SystemTime, u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    let metadata = fs::metadata(path).ok()?;
    Some((metadata.modified().ok()?, metadata.len(), metadata.ino()))
}

fn watch_snapshot(
    path: &Path,
    socket: &Path,
    action: &str,
    stop: &AtomicBool,
    updates: &LiveUpdate,
) {
    // The first comparison covers publications between initial collection
    // and listener startup. Unchanged rows will not interrupt initial typing.
    let mut previous = None;
    let mut posted: Option<std::time::Instant> = None;
    let mut posted_generation = 0;
    while !stop.load(Ordering::Acquire) {
        if updates.deferred.swap(false, Ordering::AcqRel)
            || updates.consumed.load(Ordering::Acquire) >= posted_generation
        {
            posted = None;
        }
        let current = snapshot_stamp(path);
        if current.is_some() && current != previous {
            previous = current;
            updates.requested.fetch_add(1, Ordering::AcqRel);
        }
        if updates.pending() {
            // fzf may discard an accepted transform while handing the terminal
            // to a modal. Retry at most once a second until rows is consumed.
            if posted.map_or(true, |at| at.elapsed() >= Duration::from_secs(1)) {
                if fzf_action(socket, action) {
                    posted = Some(std::time::Instant::now());
                    posted_generation = updates.requested.load(Ordering::Acquire);
                }
            }
        } else {
            posted = None;
        }
        std::thread::park_timeout(Duration::from_millis(100));
    }
}

/// Returns true when an action already completed final activation/deferred close.
pub(crate) fn run<A: Adapter>(
    adapter: &A,
    snapshot: Snapshot,
    prepared: crate::navigator::PreparedRows,
    initial_rows: &[Row],
    command: &mut Command,
    cols: usize,
    mode: Mode,
    agent_states: Vec<String>,
) -> Result<(Output, bool), String> {
    let directory = Directory::new(adapter.workspace())?;
    let socket = directory.0.join("c");
    let listener = UnixListener::bind(&socket).map_err(|e| e.to_string())?;
    let binary = std::env::current_exe().map_err(|e| e.to_string())?;
    let base = format!(
        "{} ui {}",
        quote(&binary.to_string_lossy()),
        quote(&socket.to_string_lossy())
    );
    let reload = format!("{base} rows");
    let after = format!("{base} after {}", quote(&reload));
    let live_path = adapter.live_snapshot();
    let fzf_socket = directory.0.join("f.sock");
    if live_path.is_some() {
        command.arg(format!("--listen={}", fzf_socket.display()));
        command.arg("--id-nth=4");
        command.env_remove("FZF_API_KEY");
    }
    command.args(["--no-hscroll", "--cycle"]);
    let empty = if mode == Mode::Agents {
        "No agent needs attention · clear the query to widen"
    } else if mode.operation().is_some() {
        "No matching target · Ctrl+r reload · Esc close"
    } else {
        "Enter creates a session from the query · Alt+Enter creates even when matches exist"
    };
    command.arg(format!("--bind=change:change-header()+rebind(result),result:best+unbind(result),zero:change-header({empty}),ctrl-n:down-match,ctrl-p:up-match"));
    let preview_open = crate::navigator::preview_enabled();
    let list_cols = if preview_open {
        cols.saturating_sub(1) / 2
    } else {
        cols
    };
    command.arg(format!(
        "--footer={}",
        context_footer(list_cols, mode, None, adapter.backend_name(), false)
    ));
    let initial_scope = if mode == Mode::Agents {
        crate::search::Scope::Name
    } else {
        match crate::env_text("INTERDIMUX_MATCH_SCOPE").as_str() {
            "name" => crate::search::Scope::Name,
            "path" => crate::search::Scope::Path,
            "cmd" => crate::search::Scope::Command,
            "all" => crate::search::Scope::All,
            _ => crate::search::Scope::default(),
        }
    };
    command.args(crate::search::options(
        initial_scope,
        crate::env_text("INTERDIMUX_RAW") != "off",
    ));
    if mode != Mode::Switch {
        command.arg(format!(
            "--prompt={} · {}",
            mode.label(),
            initial_scope.prompt()
        ));
    }
    if mode == Mode::Agents {
        command.arg(format!(
            "--query={}",
            crate::native_agents::query(&agent_states)
        ));
    }
    command.arg(if crate::navigator::preview_enabled() {
        "--preview-window=right,50%,border-left"
    } else {
        "--preview-window=right,50%,hidden,border-left"
    });
    command.arg(format!("--preview={base} preview {{4}}"));
    command.arg(format!(
        "--bind=ctrl-/:toggle-preview+transform({base} layout {})",
        quote(&reload)
    ));
    command.arg(format!(
        "--bind=resize:transform({base} resize {})",
        quote(&reload)
    ));
    command.arg(format!("--bind=enter:wait+transform({base} enter),alt-enter:wait+transform({base} create-query),ctrl-]:transform({base} scope)"));
    // Footer work is asynchronous, in-memory and only follows cursor focus;
    // typing/filtering never recollects a backend or scans a directory.
    command.arg(format!(
        "--bind=focus:bg-cancel+bg-transform-footer({base} hints {{4}})"
    ));
    if matches!(
        mode,
        Mode::Directories | Mode::Jobs | Mode::Health | Mode::Dashboard
    ) {
        // Startup transforms run while the outer finder can still initialize
        // its TTY. execute explicitly hands the terminal to nested fzf dialogs.
        command.arg(format!(
            "--bind=start:wait+execute({base} startup {})+transform({after})",
            match mode {
                Mode::Directories => "create",
                Mode::Jobs => "jobs",
                Mode::Health => "health",
                _ => "dashboard",
            }
        ));
    }
    for (key, operation) in [
        ("ctrl-r", "refresh"),
        ("ctrl-e", "rename"),
        ("ctrl-x", "close"),
        ("ctrl-z", "zoom"),
        ("ctrl-s", "swap"),
        ("ctrl-t", "send"),
        ("ctrl-d", "detach"),
        ("ctrl-o", "create"),
        ("alt-n", "window"),
        ("alt-v", "split-right"),
        ("alt-h", "split-down"),
        ("ctrl-g", "menu"),
        ("alt-a", "agents"),
        ("alt-j", "jobs"),
        ("alt-t", "schedule"),
    ] {
        let token = if matches!(operation, "refresh" | "create" | "menu") {
            ""
        } else {
            " {4}"
        };
        command.arg(format!(
            "--bind={key}:wait+execute({base} action {operation}{token})+transform({after})"
        ));
    }
    // Rebuild from the same snapshot and assign stable opaque tokens. There
    // are no collection calls, shell callbacks or RPCs on query changes.
    let final_done = Arc::new(AtomicBool::new(false));
    let stop = Arc::new(AtomicBool::new(false));
    let live_pending = Arc::new(LiveUpdate::default());
    let initial_text = initial_rows
        .iter()
        .enumerate()
        .map(|(index, row)| {
            format!(
                "{}\t{}\t{}\timux:{index}\n",
                row.identity, row.context, row.command
            )
        })
        .collect::<String>();
    let target_indices = initial_rows
        .iter()
        .enumerate()
        .map(|(index, r)| (r.target.clone(), index))
        .collect();
    let mut runtime = Runtime {
        adapter,
        snapshot,
        prepared,
        targets: initial_rows.iter().map(|r| r.target.clone()).collect(),
        target_indices,
        rows: initial_text,
        scope: initial_scope,
        message: String::new(),
        swap_source: None,
        pending_query: None,
        final_done: Arc::clone(&final_done),
        preview_cache: HashMap::new(),
        cols: list_cols,
        full_cols: cols,
        preview_open,
        mode,
        agent_states,
        startup_abort: false,
        live_pending: Arc::clone(&live_pending),
        live_rows_dirty: false,
    };
    let input_rows = runtime.rows.clone();
    let result = std::thread::scope(|scope| {
        let stopping = Arc::clone(&stop);
        let server = scope.spawn(move || {
            while !stopping.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        if stopping.load(Ordering::Acquire) {
                            break;
                        }
                        serve(&mut stream, &mut runtime)
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
        });
        let watcher = live_path.map(|path| {
            let stopping = Arc::clone(&stop);
            // Collection and rendering must not run inside a synchronous fzf
            // transform: those commands stop it from accepting input. A focus
            // change can cancel this background helper; the generation remains
            // pending until rows are consumed, so the watcher retries it.
            let action = format!("bg-transform({base} live {})", quote(&reload));
            scope.spawn(move || {
                watch_snapshot(&path, &fzf_socket, &action, &stopping, &live_pending)
            })
        });
        let output = (|| {
            let mut child = command
                .spawn()
                .map_err(|e| format!("cannot start fzf: {e}"))?;
            let mut stdin = child.stdin.take().ok_or("fzf has no input stream")?;
            let writer = scope.spawn(move || stdin.write_all(input_rows.as_bytes()));
            let output = child.wait_with_output().map_err(|e| format!("fzf: {e}"));
            let written = writer.join().map_err(|_| "fzf input writer failed")?;
            if let Err(e) = written {
                if e.kind() != std::io::ErrorKind::BrokenPipe {
                    return Err(e.to_string());
                }
            }
            output
        })();
        stop.store(true, Ordering::Release);
        if let Some(watcher) = watcher {
            watcher.thread().unpark();
            watcher.join().map_err(|_| "picker live refresh failed")?;
        }
        let _ = UnixStream::connect(&socket);
        server.join().map_err(|_| "picker controller failed")?;
        output
    });
    result.map(|output| (output, final_done.load(Ordering::Acquire)))
}

fn rpc(socket: &Path, request: &Value) -> Result<Value, String> {
    let mut stream = UnixStream::connect(socket).map_err(|e| format!("picker connection: {e}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(20)))
        .map_err(|e| e.to_string())?;
    let mut bytes = serde_json::to_vec(request).map_err(|e| e.to_string())?;
    bytes.push(b'\n');
    stream.write_all(&bytes).map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(stream.take(4 * 1024 * 1024))
        .read_line(&mut line)
        .map_err(|e| format!("picker response: {e}"))?;
    let response: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
    if response["ok"].as_bool() != Some(true) {
        return Err(response["error"]
            .as_str()
            .unwrap_or("Picker request failed")
            .into());
    }
    Ok(response["data"].clone())
}

fn request(event: &str, token: &str) -> Value {
    let current = crate::env_text("FZF_CURRENT_ITEM");
    let token = if token.is_empty() {
        current
            .rsplit_once('\t')
            .map(|(_, token)| token)
            .filter(|token| token.starts_with("imux:"))
            .unwrap_or("")
    } else {
        token
    };
    json!({"event":event,"token":token,"query":crate::env_text("FZF_QUERY"),
        "idle_ms":std::env::var("FZF_IDLE_TIME_MS").ok().and_then(|s|s.parse::<u64>().ok()),
        "matches":std::env::var("FZF_MATCH_COUNT").ok().and_then(|s|s.parse::<u64>().ok()),"raw":crate::env_text("FZF_RAW"),"nth":crate::env_text("FZF_NTH"),
        "columns":std::env::var(if event=="resize"||event=="layout"{"FZF_COLUMNS"}else{"FZF_PREVIEW_COLUMNS"}).ok().and_then(|s|s.parse::<u64>().ok()),
        "lines":std::env::var("FZF_PREVIEW_LINES").ok().and_then(|s|s.parse::<u64>().ok())})
}

fn chooser(
    prompt: &str,
    header: &str,
    initial: &str,
    rows: &[String],
    input: bool,
) -> Result<Option<String>, String> {
    let mut command =
        Command::new(std::env::var("INTERDIMUX_FZF_BIN").unwrap_or_else(|_| "fzf".into()));
    command
        .args([
            "--ansi",
            "--layout=reverse",
            "--height=10",
            "--border=rounded",
            "--no-multi",
            "--no-info",
            "--no-preview",
            "--no-header-first",
            "--delimiter=\t",
            "--with-nth=1",
        ])
        .arg(crate::palette::NativeTheme::from_env().fzf_color())
        .arg(format!("--prompt={prompt} ❯ "))
        .arg(format!("--header={header}"))
        .arg(format!("--query={initial}"))
        .env_remove("FZF_DEFAULT_OPTS")
        .env_remove("FZF_DEFAULT_OPTS_FILE")
        .env_remove("FZF_DEFAULT_COMMAND")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    if input {
        command.args(["--disabled", "--bind=enter:print-query+abort,ctrl-a:beginning-of-line,ctrl-e:end-of-line,ctrl-k:kill-line,ctrl-u:unix-line-discard,alt-b:backward-word,alt-f:forward-word,alt-d:kill-word,alt-backspace:backward-kill-word"]);
    }
    if prompt == "Confirm" {
        command.arg(crate::palette::NativeTheme::from_env().danger_color());
    }
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    if let Some(mut stream) = child.stdin.take() {
        let _ = stream.write_all(rows.join("\n").as_bytes());
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let value = String::from_utf8(out.stdout)
        .map_err(|_| "Invalid input")?
        .trim_end_matches(['\r', '\n'])
        .to_owned();
    if (input && !value.is_empty()) || (!input && out.status.success()) {
        Ok(Some(value))
    } else {
        Ok(None)
    }
}

fn directory_picker(socket: &Path) -> Result<Option<(String, Option<Value>)>, String> {
    let mut base: Option<String> = None;
    let mut deep: Option<String> = None;
    loop {
        let data = rpc(
            socket,
            &json!({"event":"directories","base":base,"deep":deep}),
        )?;
        let entries = data["entries"]
            .as_array()
            .ok_or("Directory discovery returned invalid data")?;
        let mut command =
            Command::new(std::env::var("INTERDIMUX_FZF_BIN").unwrap_or_else(|_| "fzf".into()));
        command.args(["--ansi","--layout=reverse","--height=90%","--border=rounded","--no-multi","--print-query","--expect=ctrl-f,ctrl-g,ctrl-r","--delimiter=\t","--with-nth=1..3","--nth=1..3","--tabstop=2","--prompt=Directories ❯ ","--footer=Enter open · Ctrl+g browse · Ctrl+f deep search · Ctrl+r reset · Esc back"])
            .arg(crate::palette::NativeTheme::from_env().fzf_color())
            .env_remove("FZF_DEFAULT_OPTS").env_remove("FZF_DEFAULT_OPTS_FILE").env_remove("FZF_DEFAULT_COMMAND")
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit());
        let binary = std::env::current_exe().map_err(|e| e.to_string())?;
        command
            .arg(format!(
                "--preview={} ui {} dir-preview {{2}}",
                quote(&binary.to_string_lossy()),
                quote(&socket.to_string_lossy())
            ))
            .args([
                "--preview-window=right,50%,border-left",
                "--bind=ctrl-/:toggle-preview",
            ]);
        let mut input = String::new();
        for (index, entry) in entries.iter().enumerate() {
            let marker = if entry["existing"].is_object() {
                "▸"
            } else if entry["project"].is_string() {
                "◆"
            } else {
                "·"
            };
            let label = entry["label"]
                .as_str()
                .unwrap_or("")
                .chars()
                .map(|c| if c.is_control() { ' ' } else { c })
                .collect::<String>();
            let path = entry["path"].as_str().unwrap_or("");
            if path.chars().any(char::is_control) {
                continue;
            }
            input.push_str(&format!(
                "{marker} {label}\t{path}\t{}{}\t{index}\n",
                entry["project"].as_str().unwrap_or(""),
                if entry["existing"].is_object() {
                    " · open session"
                } else {
                    ""
                }
            ));
        }
        let mut child = command.spawn().map_err(|e| e.to_string())?;
        let mut stdin = child.stdin.take().ok_or("Directory picker has no input")?;
        let output = std::thread::scope(|scope| {
            let writer = scope.spawn(move || stdin.write_all(input.as_bytes()));
            let output = child.wait_with_output().map_err(|e| e.to_string());
            let _ = writer.join();
            output
        })?;
        if !output.status.success() {
            return Ok(None);
        }
        let text = String::from_utf8(output.stdout).map_err(|_| "Invalid directory selection")?;
        let mut lines = text.lines();
        let query = lines.next().unwrap_or("");
        let key = lines.next().unwrap_or("");
        let row = lines.next().unwrap_or("");
        let selected = row
            .rsplit('\t')
            .next()
            .and_then(|s| s.parse::<usize>().ok())
            .and_then(|index| entries.get(index));
        match key {
            "ctrl-r" => {
                base = None;
                deep = None;
            }
            "ctrl-f" => {
                deep = Some(query.into());
            }
            "ctrl-g" => {
                if let Some(entry) = selected {
                    base = entry["path"].as_str().map(str::to_owned);
                    deep = None;
                }
            }
            _ => {
                let Some(entry) = selected else { continue };
                return Ok(Some((
                    entry["path"]
                        .as_str()
                        .ok_or("Directory has no path")?
                        .into(),
                    entry["existing"]
                        .is_object()
                        .then(|| entry["existing"].clone()),
                )));
            }
        }
    }
}

fn dashboard_picker(socket: &Path) -> Result<bool, String> {
    let info = rpc(socket, &json!({"event":"dashboard-info"}))?;
    let mut choices = vec![
        (
            "switch",
            "Switch — navigate sessions, windows and panes".to_string(),
        ),
        (
            "agents",
            format!("Agents — {} need attention", info["agents"]),
        ),
        ("agent-next", "Next agent needing attention".into()),
        ("dirs", "New session — choose a project directory".into()),
        ("rename", "Rename — choose a target".into()),
        ("kill", "Close — choose and confirm a target".into()),
        ("swap", "Swap — choose two windows or panes".into()),
        ("zoom", "Zoom — choose a pane".into()),
        ("send", "Send — choose a target".into()),
        ("schedule", "Schedule — choose a terminal".into()),
        (
            "jobs",
            "Jobs — view output or cancel scheduled commands".into(),
        ),
        (
            "doctor",
            "Health — check tools, configuration and backend".into(),
        ),
    ];
    if info["backend"] == "tmux" {
        choices.insert(8, ("detach", "Detach — choose a session".into()));
    }
    let rows = choices
        .iter()
        .map(|(_, label)| label.clone())
        .collect::<Vec<_>>();
    let Some(choice) = chooser(
        "Dashboard",
        "Choose a tool · Escape closes the dashboard",
        "",
        &rows,
        false,
    )?
    else {
        return Ok(false);
    };
    let code = choices
        .iter()
        .find(|(_, label)| *label == choice)
        .map(|(code, _)| *code)
        .ok_or("Unknown dashboard entry")?;
    if code == "agent-next" {
        rpc(socket, &json!({"event":"agent-next"}))?;
        return Ok(true);
    }
    if matches!(code, "dirs" | "jobs" | "doctor") {
        rpc(socket, &json!({"event":"set-mode","mode":"switch"}))?;
        helper(&[
            socket.to_string_lossy().into(),
            "action".into(),
            match code {
                "dirs" => "create",
                "doctor" => "health",
                _ => "jobs",
            }
            .into(),
        ])?;
    } else {
        rpc(socket, &json!({"event":"set-mode","mode":code}))?;
    }
    Ok(true)
}

fn schedule_picker(descriptor: &Value) -> Result<(), String> {
    let label = descriptor["label"].as_str().unwrap_or("selected terminal");
    let Some(command) = chooser(
        "Schedule command",
        &format!(
            "To {} · a key such as C-c presses one key",
            safe_status(label)
        ),
        "",
        &[],
        true,
    )?
    else {
        return Ok(());
    };
    let mut previous = "5m".to_string();
    let mut error = String::new();
    loop {
        let header = if error.is_empty() {
            "When: 30s, 5m, 14:30 or tomorrow 09:00 · command is retained".to_owned()
        } else {
            format!(
                "{} · correct the time; command is retained",
                safe_status(&error)
            )
        };
        let Some(when) = chooser("When", &header, &previous, &[], true)? else {
            return Ok(());
        };
        previous = when.clone();
        if let Err(problem) = crate::jobs::resolve_time(&when) {
            error = problem;
            continue;
        }
        match crate::jobs::schedule(descriptor, &when, &command) {
            Ok(record) => {
                let id = record["id"]
                    .as_str()
                    .ok_or("Scheduler returned no job ID")?;
                let rows = vec!["Keep scheduled".to_owned(), "Undo scheduling".to_owned()];
                if chooser(
                    "Scheduled",
                    &format!(
                        "{} → {} · {}",
                        safe_status(&command),
                        safe_status(label),
                        record["when"].as_str().unwrap_or(&when)
                    ),
                    "",
                    &rows,
                    false,
                )?
                .as_deref()
                    == Some("Undo scheduling")
                {
                    crate::jobs::cancel(id)?;
                }
                return Ok(());
            }
            Err(problem) => return Err(problem),
        }
    }
}

fn jobs_picker() -> Result<(), String> {
    loop {
        let jobs = crate::jobs::list()?;
        let rows = jobs
            .iter()
            .map(|job| {
                format!(
                    "{} · {} · {} · {}\t{}",
                    job["when"].as_str().unwrap_or("unknown time"),
                    job["status"].as_str().unwrap_or("unknown"),
                    safe_status(job["label"].as_str().unwrap_or("terminal")),
                    safe_status(job["command"].as_str().unwrap_or("")),
                    job["id"].as_str().unwrap_or("")
                )
            })
            .collect::<Vec<_>>();
        if rows.is_empty() {
            let _ = chooser(
                "Jobs",
                "No scheduled commands · Escape returns",
                "",
                &["No jobs".into()],
                false,
            )?;
            return Ok(());
        }
        let Some((key, chosen)) = jobs_table(&rows)? else {
            return Ok(());
        };
        if key == "ctrl-r" {
            continue;
        }
        let id = chosen
            .rsplit_once('\t')
            .map(|(_, id)| id)
            .ok_or("Job selection has no ID")?;
        let Some(job) = jobs.iter().find(|j| j["id"].as_str() == Some(id)) else {
            continue;
        };
        if key == "ctrl-x" && job["status"] != "scheduled" {
            let _ = chooser(
                "Job status",
                "Only commands that are still scheduled can be cancelled",
                "",
                &[format!(
                    "This job is {}",
                    job["status"].as_str().unwrap_or("unknown")
                )],
                false,
            )?;
            continue;
        }
        let mut actions = vec!["View output / status".to_owned(), "Refresh jobs".to_owned()];
        if job["status"] == "scheduled" {
            actions.insert(1, "Cancel scheduled command".into());
        }
        let direct = match key.as_str() {
            "ctrl-x" => Some("Cancel scheduled command".into()),
            "ctrl-o" => Some("View output / status".into()),
            _ => None,
        };
        let Some(action) = (if direct.is_some() {
            direct
        } else {
            chooser(
                "Job",
                &format!(
                    "{} · {}",
                    safe_status(job["command"].as_str().unwrap_or("")),
                    job["status"].as_str().unwrap_or("unknown")
                ),
                "",
                &actions,
                false,
            )?
        }) else {
            continue;
        };
        match action.as_str() {
            "Cancel scheduled command" => {
                if chooser(
                    "Confirm",
                    "Cancel this scheduled command?",
                    "",
                    &["Keep scheduled".into(), "Confirm cancellation".into()],
                    false,
                )?
                .as_deref()
                    == Some("Confirm cancellation")
                {
                    crate::jobs::cancel(id)?;
                }
            }
            "View output / status" => {
                let output = crate::jobs::output(id)?;
                let rows = output.lines().map(safe_status).collect::<Vec<_>>();
                let _ = chooser(
                    "Job output",
                    "Enter or Escape returns to jobs",
                    "",
                    &if rows.is_empty() {
                        vec!["No output recorded".into()]
                    } else {
                        rows
                    },
                    false,
                )?;
            }
            _ => {}
        }
    }
}

fn jobs_table(rows: &[String]) -> Result<Option<(String, String)>, String> {
    let mut command =
        Command::new(std::env::var("INTERDIMUX_FZF_BIN").unwrap_or_else(|_| "fzf".into()));
    command
        .args([
            "--ansi",
            "--layout=reverse",
            "--height=100%",
            "--border=rounded",
            "--no-multi",
            "--delimiter=\t",
            "--with-nth=1",
            "--prompt=Jobs ❯ ",
            "--header=Enter inspect · Ctrl+x cancel · Ctrl+o output · Ctrl+r refresh · Esc back",
            "--expect=ctrl-x,ctrl-o,ctrl-r",
        ])
        .arg(crate::palette::NativeTheme::from_env().fzf_color())
        .env_remove("FZF_DEFAULT_OPTS")
        .env_remove("FZF_DEFAULT_OPTS_FILE")
        .env_remove("FZF_DEFAULT_COMMAND")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    if let Some(mut input) = child.stdin.take() {
        let _ = input.write_all(rows.join("\n").as_bytes());
    }
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Ok(None);
    }
    let text = String::from_utf8(output.stdout).map_err(|_| "Invalid job selection")?;
    let mut lines = text.lines();
    let key = lines.next().unwrap_or("").into();
    let selected = lines.next().unwrap_or("").into();
    Ok(Some((key, selected)))
}

pub(crate) fn helper(args: &[String]) -> Result<(), String> {
    let socket = Path::new(args.first().ok_or("ui requires a socket")?);
    let event = args.get(1).map(String::as_str).unwrap_or("");
    if event == "startup" {
        let operation = args.get(2).map(String::as_str).unwrap_or("dashboard");
        if operation == "dashboard" {
            let selected = dashboard_picker(socket)?;
            rpc(
                socket,
                &json!({"event":"startup-finished","abort":!selected}),
            )?;
        } else {
            helper(&[
                socket.to_string_lossy().into(),
                "action".into(),
                operation.into(),
            ])?;
            let message = rpc(socket, &json!({"event":"message"}))?;
            if message["final"].as_bool() != Some(true)
                && !message["message"].as_str().unwrap_or("").is_empty()
            {
                rpc(socket, &json!({"event":"startup-finished","abort":false}))?;
            } else {
                rpc(socket, &json!({"event":"startup-finished","abort":true}))?;
            }
        }
        return Ok(());
    }
    if event == "enter" {
        let req = request("enter", args.get(2).map(String::as_str).unwrap_or(""));
        if req["matches"].as_u64() != Some(0) && req["token"].as_str() == Some("") {
            // fzf omits CURRENT_ITEM above 64 KiB. Resolve the short opaque
            // token in a second native action only when a row exists.
            let binary = std::env::current_exe().map_err(|e| e.to_string())?;
            print!(
                "transform({} ui {} enter {{4}})",
                quote(&binary.to_string_lossy()),
                quote(&socket.to_string_lossy())
            );
            return Ok(());
        }
        match rpc(socket, &req) {
            Ok(value) => {
                if let Some(operation) = value["action"].as_str() {
                    // A transform may choose an action, but must not run a
                    // modal while fzf still owns the terminal. Let execute
                    // suspend the finder before starting the nested chooser.
                    let binary = std::env::current_exe().map_err(|e| e.to_string())?;
                    let base = format!(
                        "{} ui {}",
                        quote(&binary.to_string_lossy()),
                        quote(&socket.to_string_lossy())
                    );
                    let reload = format!("{base} rows");
                    print!(
                        "execute({base} action {operation} {})+transform({base} after {})",
                        quote(req["token"].as_str().unwrap_or("")),
                        quote(&reload)
                    );
                } else {
                    print!("{}", value["text"].as_str().unwrap_or(""));
                }
            }
            Err(error) => print!("{}", status(&error)),
        }
        return Ok(());
    }
    if event == "dir-preview" {
        let columns = std::env::var("FZF_PREVIEW_COLUMNS")
            .ok()
            .and_then(|n| n.parse().ok())
            .unwrap_or(60);
        let lines = std::env::var("FZF_PREVIEW_LINES")
            .ok()
            .and_then(|n| n.parse().ok())
            .unwrap_or(25);
        print!(
            "{}",
            crate::preview::directory(
                args.get(2).map(String::as_str).unwrap_or(""),
                columns,
                lines
            )
        );
        return Ok(());
    }
    let token = if matches!(event, "after" | "resize" | "layout" | "live") {
        None
    } else if event == "action" {
        args.get(3)
    } else {
        args.get(2)
    }
    .map(String::as_str)
    .unwrap_or("");
    let mut req = request(event, token);
    if matches!(event, "after" | "resize" | "layout" | "live") {
        req["reload"] = json!(args.get(2).map(String::as_str).unwrap_or("true"));
    }
    if event == "action" {
        let mut op = args.get(2).map(String::as_str).unwrap_or("").to_owned();
        if op == "menu" {
            let info = rpc(socket, &json!({"event":"dashboard-info"}))?;
            let mut description = req.clone();
            description["event"] = json!("describe");
            let kind = rpc(socket, &description)
                .ok()
                .and_then(|d| d["kind"].as_str().map(str::to_owned));
            let mut choices = vec![
                "Rename",
                "Close",
                "Zoom",
                "Swap",
                "Send",
                "New session",
                "New named session",
                "New window",
                "Split right",
                "Split down",
                "Agents needing attention",
                "Next agent needing attention",
                "Schedule command",
                "Scheduled jobs",
                "Dashboard",
                "Detach clients",
                "Reload",
                "Health",
            ];
            if info["backend"] == "rex" {
                choices.retain(|s| *s != "Detach clients");
            }
            if kind.is_none() || kind.as_deref() == Some("directory") {
                choices.retain(|s| {
                    !matches!(
                        *s,
                        "Rename"
                            | "Close"
                            | "Zoom"
                            | "Swap"
                            | "Send"
                            | "Detach clients"
                            | "Schedule command"
                            | "New window"
                            | "Split right"
                            | "Split down"
                    )
                });
            } else if kind.as_deref() == Some("session") {
                choices.retain(|s| *s != "Swap");
            }
            let Some(selected) = chooser(
                "Actions",
                "Escape returns to the navigator",
                "",
                &choices.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
                false,
            )?
            else {
                return Ok(());
            };
            op = match selected.as_str() {
                "Rename" => "rename",
                "Close" => "close",
                "Zoom" => "zoom",
                "Swap" => "swap",
                "Send" => "send",
                "New session" => "create",
                "New named session" => "named",
                "New window" => "window",
                "Split right" => "split-right",
                "Split down" => "split-down",
                "Agents needing attention" => "agents",
                "Next agent needing attention" => "agent-next",
                "Schedule command" => "schedule",
                "Scheduled jobs" => "jobs",
                "Dashboard" => "dashboard",
                "Detach clients" => "detach",
                "Health" => "health",
                _ => "refresh",
            }
            .into();
        }
        if op == "dashboard" {
            let _ = dashboard_picker(socket)?;
            return Ok(());
        }
        if op == "agent-next" {
            let _ = rpc(socket, &json!({"event":"agent-next"}));
            return Ok(());
        }
        if op == "jobs" {
            if let Err(error) = jobs_picker() {
                let _ = rpc(socket, &json!({"event":"notice","message":error}));
            }
            return Ok(());
        }
        if op == "health" {
            let data = rpc(socket, &json!({"event":"health"}))?;
            let rows = data["lines"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect::<Vec<_>>();
            let _ = chooser(
                "Health",
                "Enter or Escape returns to the navigator",
                "",
                &rows,
                false,
            )?;
            return Ok(());
        }
        if op == "named" {
            let Some(value) = chooser(
                "New session",
                "Create from a name or directory",
                "",
                &[],
                true,
            )?
            else {
                return Ok(());
            };
            let mut q = request("create-query", "");
            q["query"] = json!(value);
            q["explicit"] = json!(true);
            let _ = rpc(socket, &q);
            return Ok(());
        }
        let mut values = json!({});
        let description = if matches!(op.as_str(), "refresh" | "create" | "agents") {
            json!({})
        } else {
            let mut d = req.clone();
            d["event"] = json!("describe");
            d["operation"] = json!(op);
            match rpc(socket, &d) {
                Ok(d) => d,
                Err(_) => return Ok(()),
            }
        };
        let name = description["name"].as_str().unwrap_or("");
        let kind = description["kind"].as_str().unwrap_or("target");
        if op == "schedule" {
            let mut target_request = req.clone();
            target_request["operation"] = json!("schedule-target");
            target_request["args"] = json!({});
            let descriptor = rpc(socket, &target_request)?;
            if let Err(error) = schedule_picker(&descriptor) {
                let _ = rpc(socket, &json!({"event":"notice","message":error}));
            }
            return Ok(());
        }
        match op.as_str() {
            "rename" => {
                let Some(value) = chooser(
                    "Rename",
                    &format!("Rename {kind}: {}", safe_status(name)),
                    name,
                    &[],
                    true,
                )?
                else {
                    return Ok(());
                };
                values["name"] = json!(value);
            }
            "close" | "detach" => {
                let verb = if op == "detach" {
                    "Detach clients from"
                } else {
                    "Close"
                };
                let label = format!(
                    "{verb} {kind} {} ({} pane(s))?",
                    safe_status(name),
                    description["count"]
                );
                let rows = vec!["Keep open".into(), "Confirm action".into()];
                if chooser("Confirm", &label, "", &rows, false)?.as_deref()
                    != Some("Confirm action")
                {
                    return Ok(());
                }
            }
            "send" => {
                let Some(value) = chooser(
                    "Send",
                    &format!(
                        "To {kind} {} ({} panes). A command runs with Enter; C-c presses one key.",
                        safe_status(name),
                        description["count"]
                    ),
                    "",
                    &[],
                    true,
                )?
                else {
                    return Ok(());
                };
                values = send_args(&value);
            }
            "create" => {
                let Some((path, existing)) = directory_picker(socket)? else {
                    return Ok(());
                };
                if let Some(target) = existing {
                    // Selecting an existing project switches directly, rather
                    // than creating a second session under a duplicate label.
                    let mut q = request("activate-target", "");
                    q["target"] = target;
                    q["path"] = json!(path);
                    let _ = rpc(socket, &q);
                    return Ok(());
                }
                let mut q = request("create-query", "");
                q["query"] = json!(path);
                q["explicit"] = json!(true);
                let _ = rpc(socket, &q);
                return Ok(());
            }
            "window" => {
                let Some(value) = chooser(
                    "New window / directory",
                    "Type a name or an absolute / ~/directory path",
                    "",
                    &[],
                    true,
                )?
                else {
                    return Ok(());
                };
                let (name, mut cwd) = match create_query(&value) {
                    Ok(value) => value,
                    Err(error) => {
                        let _ = rpc(socket, &json!({"event":"notice","message":error}));
                        return Ok(());
                    }
                };
                if crate::projects::query_directory(&value).is_none()
                    && cwd == crate::env_text("HOME")
                {
                    if let Some(origin) = description["cwd"].as_str().filter(|s| !s.is_empty()) {
                        cwd = origin.into();
                    }
                }
                values = json!({"name":name,"cwd":cwd,"kind":"window"});
                op = "create".into();
            }
            "split-right" | "split-down" => {
                values["direction"] = json!(if op == "split-right" { "right" } else { "down" });
                op = "split".into();
            }
            _ => {}
        }
        req["operation"] = json!(op);
        req["args"] = values;
        let _ = rpc(socket, &req); // The controller retains errors for the header.
        return Ok(());
    }
    match rpc(socket, &req) {
        Ok(value) => {
            if let Some(text) = value["text"].as_str() {
                print!("{text}");
            }
        }
        Err(error) => {
            if matches!(event, "accept" | "create-query" | "scope" | "after") {
                print!("{}", status(&error));
            } else if event == "preview" {
                println!("{}", safe_status(&error));
            } else {
                return Err(error);
            }
        }
    }
    Ok(())
}

fn context_footer(
    cols: usize,
    mode: Mode,
    kind: Option<&str>,
    backend: &str,
    no_match: bool,
) -> String {
    let enter = mode.operation().unwrap_or(if kind == Some("directory") {
        "open"
    } else {
        "switch"
    });
    let mut hints = if no_match {
        if mode == Mode::Agents {
            vec![
                ("No waiting agent".into(), 1),
                ("clear query".into(), 0),
                ("Esc close".into(), 0),
            ]
        } else if mode.operation().is_some() {
            vec![
                ("No match".into(), 1),
                ("^r reload".into(), 0),
                ("Esc close".into(), 0),
            ]
        } else {
            vec![
                ("Enter create".into(), 0),
                ("Esc close".into(), 0),
                ("^g actions".into(), 1),
                ("Alt+Enter create".into(), 2),
            ]
        }
    } else {
        vec![
            (format!("Enter {enter}"), 0),
            ("Esc close".into(), 0),
            ("^g actions".into(), 1),
            ("^r reload".into(), 2),
            ("^/ preview".into(), 3),
            ("^] scope".into(), 4),
        ]
    };
    if !no_match && kind != Some("directory") {
        hints.push(("^e rename".into(), 5));
        hints.push(("^x close".into(), 8));
        if kind == Some("pane") {
            hints.extend([("^z zoom".into(), 6), ("^t send".into(), 7)]);
        }
        if matches!(kind, Some("window" | "pane")) {
            hints.push(("^s swap".into(), 7));
        }
        if kind == Some("session") && backend == "tmux" {
            hints.push(("^d detach".into(), 6));
        }
        hints.push(("^o new".into(), 4));
    }
    while crate::text::width(
        &hints
            .iter()
            .map(|(s, _)| s.as_str())
            .collect::<Vec<_>>()
            .join(" · "),
    ) > cols.saturating_sub(3)
        && hints.len() > 1
    {
        let index = hints
            .iter()
            .enumerate()
            .max_by_key(|(i, (_, priority))| (*priority, *i))
            .map(|(i, _)| i)
            .unwrap();
        hints.remove(index);
    }
    hints
        .iter()
        .map(|(s, _)| s.as_str())
        .collect::<Vec<_>>()
        .join(" · ")
}

/// Expensive checks are deliberately confined to the explicit Health action.
pub(crate) fn health_report(adapter: &impl Adapter, snapshot: &Snapshot) -> Vec<String> {
    let mut lines = vec![
        format!("Backend: {}", adapter.backend_name()),
        format!(
            "{} sessions · {} windows · {} panes",
            snapshot.sessions.len(),
            snapshot.windows.len(),
            snapshot.panes.len()
        ),
    ];
    let fzf = std::env::var("INTERDIMUX_FZF_BIN").unwrap_or_else(|_| "fzf".into());
    match Command::new(&fzf).arg("--version").output() {
        Ok(output) if output.status.success() => {
            let version = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            let mut parts = version.split_whitespace().next().unwrap_or("").split('.');
            let major = parts
                .next()
                .and_then(|s| s.parse::<u32>().ok())
                .unwrap_or(0);
            let minor = parts
                .next()
                .and_then(|s| s.parse::<u32>().ok())
                .unwrap_or(0);
            lines.push(format!(
                "{}: fzf {version} {}",
                if major > 0 || minor >= 74 {
                    "OK"
                } else {
                    "ERROR"
                },
                if major > 0 || minor >= 74 {
                    "supports persistent/raw picker controls"
                } else {
                    "requires version 0.74 or newer"
                }
            ));
        }
        Ok(output) => lines.push(format!("ERROR: {fzf} --version exited {}", output.status)),
        Err(error) => lines.push(format!("ERROR: cannot execute {fzf}: {error}")),
    }
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let probe = std::env::temp_dir().join(format!("imux-health-{}-{stamp}", std::process::id()));
    match fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&probe)
    {
        Ok(_) => {
            let _ = fs::remove_file(probe);
            lines.push("OK: private temporary files are writable".into());
        }
        Err(e) => lines.push(format!("ERROR: cannot create temporary files: {e}")),
    }
    for (key, values) in [
        ("INTERDIMUX_ORDER", &["mru", "index"][..]),
        ("INTERDIMUX_RAW", &["on", "off"]),
        ("INTERDIMUX_PREVIEW", &["on", "off"]),
        ("INTERDIMUX_SHOW_PREVIEW", &["on", "off"]),
        ("INTERDIMUX_AGENT_STATE", &["on", "off"]),
        ("INTERDIMUX_SHOW_TITLE", &["known", "all", "off"]),
    ] {
        let value = crate::env_text(key);
        if !value.is_empty() && !values.contains(&value.as_str()) {
            lines.push(format!(
                "ERROR: {key}={value:?}; expected {}",
                values.join(" or ")
            ));
        }
    }
    for key in [
        "INTERDIMUX_DIRS_LIMIT",
        "INTERDIMUX_SCAN_DEPTH",
        "INTERDIMUX_TITLE_MAX",
    ] {
        let value = crate::env_text(key);
        if !value.is_empty() && value.parse::<usize>().is_err() {
            lines.push(format!("ERROR: {key} must be a nonnegative integer"));
        }
    }
    match crate::navigator::fzf_options(&crate::env_text("INTERDIMUX_FZF_OPTS")) {
        Ok((_, ignored)) if !ignored.is_empty() => lines.push(format!(
            "WARN: owned picker keeps its output/grid contract; ignores configured {}",
            ignored.join(", ")
        )),
        Err(e) => lines.push(format!("ERROR: {e}")),
        _ => {}
    }
    match adapter.action("health", None, &json!({})) {
        Ok(value) => {
            if let Some(native) = value["lines"].as_array() {
                lines.extend(native.iter().filter_map(|v| v.as_str().map(str::to_owned)));
            }
        }
        Err(e) => lines.push(format!("WARN: native backend health: {e}")),
    }
    lines.extend(crate::diagnostics::report());
    lines.push(
        "OK: query filtering stays inside fzf; metadata, previews, scans and jobs load on demand"
            .into(),
    );
    lines
}

/// Fzf operators are filters, not shell syntax. Never evaluate a creation query.
pub(crate) fn create_query(query: &str) -> Result<(String, String), String> {
    crate::projects::normalize_query(query)
}

pub(crate) fn send_args(text: &str) -> Value {
    crate::jobs::send_payload(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn live_publication_retries_a_dropped_command_without_another_file_change() {
        let directory = Directory::new(None).unwrap();
        let path = directory.0.join("snapshot.json");
        fs::write(&path, "{}").unwrap();
        let socket = directory.0.join("f.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let stop = AtomicBool::new(false);
        let updates = LiveUpdate::default();
        std::thread::scope(|scope| {
            let watcher =
                scope.spawn(|| watch_snapshot(&path, &socket, "refresh-preview", &stop, &updates));
            let started = std::time::Instant::now();
            let mut received = 0;
            while received < 2 && started.elapsed() < Duration::from_secs(5) {
                if let Ok((mut stream, _)) = listener.accept() {
                    stream
                        .set_read_timeout(Some(Duration::from_secs(1)))
                        .unwrap();
                    let mut reader = BufReader::new(&mut stream);
                    let mut line = String::new();
                    loop {
                        line.clear();
                        if reader.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
                            break;
                        }
                    }
                    let mut body = [0; 15];
                    reader.read_exact(&mut body).unwrap();
                    assert_eq!(&body, b"refresh-preview");
                    received += 1;
                    // First command is accepted but discarded, just as fzf
                    // can do during a modal transition. Only the retry is used.
                    if received == 2 {
                        updates.acknowledge(updates.requested.load(Ordering::Acquire));
                    }
                    stream
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
                        .unwrap();
                } else {
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
            stop.store(true, Ordering::Release);
            watcher.thread().unpark();
            watcher.join().unwrap();
            assert_eq!(
                received, 2,
                "an accepted but unused refresh must be retried"
            );
            assert!(!updates.pending());
            assert!(started.elapsed() >= Duration::from_secs(1));
            // An acknowledgment never consumes a publication it did not read.
            updates.requested.fetch_add(1, Ordering::AcqRel);
            updates.acknowledge(1);
            assert!(updates.pending());
        });
    }

    #[test]
    fn creation_queries_are_data_and_filters_are_rejected() {
        assert_eq!(create_query("'my\\ project$").unwrap().0, "my-project");
        assert!(create_query("one | two").is_err());
        assert!(create_query("").is_err());
        assert!(create_query("$(touch /tmp/no)")
            .unwrap()
            .0
            .starts_with("$(touch-"));
    }
    #[test]
    fn send_only_treats_a_single_exact_key_as_a_key() {
        assert_eq!(send_args("C-c")["key"], "ctrl+c");
        assert_eq!(send_args("C-c echo test")["text"], "C-c echo test");
        assert_eq!(send_args("F12")["key"], "f12");
        assert_eq!(send_args("echo '$HOME'")["text"], "echo '$HOME'");
    }
    #[test]
    fn fzf_status_cannot_inject_actions() {
        assert!(!safe_status("x)+execute(rm)+(").contains(')'));
    }
    #[test]
    fn combined_rows_use_window_actions_and_exact_pane_navigation() {
        let sections = vec![
            "demo\x1f0\x1f1\x1fattached\x1f/tmp".to_string(),
            "demo\x1f0\x1feditor\x1f1\x1fsh\x1f/tmp\x1f1\x1f0\x1f000".to_string(),
            "demo\x1f0\x1f0\x1f1\x1fsh\x1f/tmp\x1f0\x1f1\x1f%1\x1ftitle\x1f".to_string(),
            "demo\x1f0\x1f0\x1fhost\x1fhost".to_string(),
            String::new(),
        ];
        let snapshot = crate::tmux_input::parse_sections(&sections);
        let pane = snapshot.panes[0].target.clone();
        let window = snapshot.windows[0].target.clone();
        for op in ["rename", "close", "swap", "window"] {
            assert_eq!(row_action_target(&snapshot, pane.clone(), op), window);
        }
        for op in ["send", "zoom", "split", "accept"] {
            assert_eq!(row_action_target(&snapshot, pane.clone(), op), pane);
        }
    }
    struct Fake {
        activations: std::sync::Mutex<Vec<Target>>,
    }
    impl Adapter for Fake {
        fn refresh(&self) -> Result<Snapshot, String> {
            Ok(fixture())
        }
        fn cached(&self) -> Result<Snapshot, String> {
            Ok(fixture())
        }
        fn action(&self, _: &str, _: Option<&Target>, _: &Value) -> Result<Value, String> {
            Err("Unexpected backend action".into())
        }
        fn activate(&self, target: &Target) -> Result<(), String> {
            self.activations.lock().unwrap().push(target.clone());
            Ok(())
        }
        fn backend_name(&self) -> &'static str {
            "rex"
        }
    }
    fn fixture() -> Snapshot {
        let sections=vec!["demo\x1f0\x1f1\x1fattached\x1f/tmp".into(),"demo\x1f0\x1feditor\x1f1\x1fcodex\x1f/tmp\x1f2\x1f0\x1f000".into(),
            "demo\x1f0\x1f0\x1f1\x1fcodex\x1f/tmp\x1f0\x1f12\x1f%1\x1fReview\x1f\ndemo\x1f0\x1f1\x1f0\x1fcat\x1f/tmp\x1f0\x1f13\x1f%2\x1fapprove input\x1f".into(),"demo\x1f0\x1f0\x1fhost\x1fhost".into(),String::new()];
        let mut snapshot = crate::tmux_input::parse_sections(&sections);
        snapshot.panes[0].pid = 12;
        snapshot.panes[1].name = "approve input".into();
        snapshot.registry.insert(
            "%1".into(),
            crate::agent::Record {
                sid: "12".into(),
                word: "approve".into(),
                since: 10,
            },
        );
        snapshot
    }
    fn runtime(adapter: &Fake, mode: Mode) -> Runtime<'_, Fake> {
        let snapshot = fixture();
        let rows =
            crate::navigator::rows(&snapshot, 117, mode, &["approve".into(), "input".into()]);
        let prepared = crate::navigator::PreparedRows::new(&snapshot);
        Runtime {
            adapter,
            snapshot,
            prepared,
            targets: rows.iter().map(|r| r.target.clone()).collect(),
            target_indices: rows
                .iter()
                .enumerate()
                .map(|(i, r)| (r.target.clone(), i))
                .collect(),
            rows: String::new(),
            scope: crate::search::Scope::default(),
            message: String::new(),
            swap_source: None,
            pending_query: None,
            final_done: Arc::new(AtomicBool::new(false)),
            preview_cache: HashMap::new(),
            cols: 120,
            full_cols: 120,
            preview_open: false,
            mode,
            agent_states: vec!["approve".into(), "input".into()],
            startup_abort: false,
            live_pending: Arc::new(LiveUpdate::default()),
            live_rows_dirty: false,
        }
    }
    #[test]
    fn action_modes_never_switch_or_create_on_enter() {
        let adapter = Fake {
            activations: Default::default(),
        };
        let mut r = runtime(&adapter, Mode::Close);
        let index = r
            .targets
            .iter()
            .position(|t| *t == r.snapshot.panes[0].target)
            .unwrap();
        let value = r
            .handle(&json!({"event":"enter","token":format!("imux:{index}"),"matches":1,"raw":"1"}))
            .unwrap();
        assert_eq!(value["action"], "close");
        assert!(adapter.activations.lock().unwrap().is_empty());
        assert!(r
            .handle(&json!({"event":"enter","matches":0,"query":"would-create"}))
            .is_err());
        assert!(adapter.activations.lock().unwrap().is_empty());
    }
    #[test]
    fn agent_view_matches_state_markers_not_words_in_nonagent_titles() {
        let adapter = Fake {
            activations: Default::default(),
        };
        let mut r = runtime(&adapter, Mode::Switch);
        r.handle(&json!({"event":"set-mode","mode":"agents"}))
            .unwrap();
        assert_eq!(r.pending_query.as_deref(), Some("^! | ^?"));
        assert_eq!(
            r.rows.lines().filter(|line| line.starts_with("! ")).count(),
            1
        );
        assert!(r.rows.contains("approve input"));
        assert!(r
            .handle(&json!({"event":"accept","matches":0,"query":"^! | ^?"}))
            .is_err());
        assert!(adapter.activations.lock().unwrap().is_empty());
    }
    #[test]
    fn contextual_hints_follow_target_and_native_capabilities() {
        let session = context_footer(200, Mode::Switch, Some("session"), "rex", false);
        assert!(
            !session.contains("detach") && !session.contains("swap") && !session.contains("zoom")
        );
        assert!(
            context_footer(200, Mode::Switch, Some("session"), "tmux", false).contains("detach")
        );
        let pane = context_footer(200, Mode::Rename, Some("pane"), "rex", false);
        assert!(pane.contains("Enter rename") && pane.contains("zoom") && pane.contains("send"));
        let directory = context_footer(200, Mode::Switch, Some("directory"), "rex", false);
        assert!(directory.contains("Enter open") && !directory.contains("rename"));
        assert!(
            crate::text::width(&context_footer(
                32,
                Mode::Switch,
                Some("pane"),
                "rex",
                false
            )) <= 29
        );
    }
    #[test]
    fn empty_result_hints_fit_and_only_offer_creation_in_switch_mode() {
        for cols in 20..200 {
            for mode in [
                Mode::Switch,
                Mode::Agents,
                Mode::Rename,
                Mode::Close,
                Mode::Send,
            ] {
                let footer = context_footer(cols, mode, None, "rex", true);
                assert!(
                    crate::text::width(&footer) <= cols - 3,
                    "{mode:?}, {cols}: {footer}"
                );
                if mode.operation().is_some() {
                    assert!(!footer.contains("create"), "{footer}");
                    assert!(footer.contains("reload"), "{footer}");
                }
            }
        }
    }

    #[test]
    fn refresh_and_action_snapshots_replace_prepared_presentation() {
        let adapter = Fake {
            activations: Default::default(),
        };
        let mut r = runtime(&adapter, Mode::Switch);
        r.snapshot.sessions[0].name = "old snapshot name".into();
        r.prepared = crate::navigator::PreparedRows::new(&r.snapshot);
        r.update_rows();
        assert!(r.rows.contains("old snapshot name"));
        r.refresh().unwrap();
        assert!(!r.rows.contains("old snapshot name"));
        r.snapshot.sessions[0].name = "another old name".into();
        r.prepared = crate::navigator::PreparedRows::new(&r.snapshot);
        r.update_rows();
        assert!(r.rows.contains("another old name"));
        r.cached().unwrap();
        assert!(!r.rows.contains("another old name"));
    }
}
