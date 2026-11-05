//! Rex transport and normalization. The shared renderer never sees Rex JSON.

use crate::agent;
use crate::model::{Current, Pane, PaneMetadata, ProgramStatus, Session, Snapshot, Target, Window};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

const SNAPSHOT_SCRIPT: &str = include_str!("rex_snapshot.lua");
const HISTORY_SCRIPT: &str = include_str!("rex_history.lua");
const ACTIVATE_SCRIPT: &str = include_str!("rex_activate.lua");
const OPERATIONS_SCRIPT: &str = include_str!("../../integrations/rex_operations.lua");
static NEXT_REQUEST: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone)]
pub(crate) struct RexContext {
    pub server: Option<String>,
    pub client_id: String,
    pub session_id: String,
    pub window_id: String,
    /// The pane focused before the floating picker opened.
    pub block_id: String,
    /// The new terminal running the picker, never a navigation candidate.
    pub picker_block_id: Option<String>,
    /// Saved before opening the float, whose focus can clear window zoom.
    pub origin_zoomed_block_id: Option<String>,
    /// Native coordinator supplies a snapshot before creating the float.
    pub snapshot_file: Option<PathBuf>,
    /// Hosted completion is an atomic record, never another CLI round trip.
    pub result_file: Option<PathBuf>,
}

pub(crate) fn collect(context: &RexContext) -> Result<Snapshot, String> {
    let output = if let Some(path) = &context.snapshot_file {
        crate::rex_ready::wait(path)?;
        fs::read(path).map_err(|e| format!("Cannot read Rex snapshot {}: {e}", path.display()))?
    } else {
        let args = context
            .picker_block_id
            .as_ref()
            .map(|id| json!({"picker_block_id":id}))
            .unwrap_or_else(|| json!({}));
        let source = format!(
            "local snapshot=(function()\n{SNAPSHOT_SCRIPT}\nend)()\nlocal history=(function()\n{HISTORY_SCRIPT}\nend)()\nreturn history.enrich(snapshot)\n"
        );
        run_script(context, &source, None, &args)?
    };
    let mut snapshot = parse_snapshot(&output, context)?;
    crate::native_config::merge_registry(&mut snapshot);
    Ok(snapshot)
}

pub(crate) fn refresh(context: &RexContext) -> Result<Snapshot, String> {
    if context.result_file.is_some() {
        action(context, "snapshot", None, &json!({}))?;
    }
    collect(context)
}

/// A scheduled send never retains the hosted mailbox or invokes app actions.
pub(crate) fn run_job(descriptor: &Value, payload: &Value) -> Result<Value, String> {
    let target = &descriptor["target"];
    let session_id = target["session_id"]
        .as_str()
        .ok_or("Scheduled Rex session is missing")?;
    let block_id = target["block_id"]
        .as_str()
        .ok_or("Scheduled Rex pane is missing")?;
    let context = RexContext {
        server: descriptor["server"].as_str().map(str::to_owned),
        client_id: descriptor["client_id"]
            .as_str()
            .unwrap_or("client:scheduled")
            .into(),
        session_id: session_id.into(),
        window_id: String::new(),
        block_id: block_id.into(),
        picker_block_id: None,
        origin_zoomed_block_id: None,
        snapshot_file: None,
        result_file: None,
    };
    let mut args = payload
        .as_object()
        .cloned()
        .ok_or("Scheduled input must be an object")?;
    args.insert("guard".into(), descriptor["guard"].clone());
    action(
        &context,
        "job-send",
        Some(&Target::Rex {
            session_id: session_id.into(),
            window_id: None,
            block_id: Some(block_id.into()),
        }),
        &Value::Object(args),
    )
}

pub(crate) fn action(
    context: &RexContext,
    operation: &str,
    target: Option<&Target>,
    args: &Value,
) -> Result<Value, String> {
    if operation == "detach" {
        return Err(
            "Rex has no tmux-style detach action; switch sessions or close the app window".into(),
        );
    }
    if !args.is_object() {
        return Err("Rex operation arguments must be an object".into());
    }
    let target = target
        .map(|target| {
            let mut value = activation_args(context, target)?;
            value.as_object_mut().unwrap().remove("client_id");
            Ok::<Value, String>(value)
        })
        .transpose()?;
    let request = json!({"version":1,"id":NEXT_REQUEST.fetch_add(1, Ordering::Relaxed),
        "operation":operation,"target":target,"args":args});
    if let Some(result_path) = &context.result_file {
        let hosting_ancestor = target
            .as_ref()
            .map(|t| {
                t["session_id"] == context.session_id
                    && (t["block_id"] == context.block_id
                        || (t.get("block_id").is_none()
                            && (t.get("window_id").is_none()
                                || t["window_id"] == context.window_id)))
            })
            .unwrap_or(false);
        if (operation == "close" && hosting_ancestor) || operation == "zoom" {
            write_result(
                result_path,
                &json!({"version":1,"outcome":"action",
                "operation":operation,"target":target,"args":args}),
            )?;
            return Ok(json!({"deferred":true}));
        }
        let directory = result_path
            .parent()
            .ok_or("Rex result has no private directory")?;
        let request_path = directory.join("request.json");
        let response_path = directory.join("response.json");
        write_result(&request_path, &request)?;
        let until = Instant::now() + Duration::from_secs(15);
        while Instant::now() < until {
            if let Ok(bytes) = fs::read(&response_path) {
                let response: Value = serde_json::from_slice(&bytes)
                    .map_err(|e| format!("Cannot decode native Rex response: {e}"))?;
                if response["version"] == 1 && response["id"] == request["id"] {
                    return if response["ok"].as_bool() == Some(true) {
                        Ok(action_data(
                            context,
                            operation,
                            response.get("data").cloned().unwrap_or_else(|| json!({})),
                        ))
                    } else {
                        Err(response["error"]
                            .as_str()
                            .unwrap_or("The native Rex operation failed")
                            .into())
                    };
                }
            }
            if !directory.is_dir() {
                return Err("The native Rex picker has closed".into());
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        return Err("Native Rex operation timed out; reload before retrying".into());
    }
    let source = format!("local listed,err=rex.call('session.attach_all',{{event_scope='session'}})\nif not listed then error(err,0) end\nlocal operation=(function()\n{OPERATIONS_SCRIPT}\nend)()\nlocal result=operation(rex.args.request,rex.args.context)\nif rex.args.request.operation=='create' and (not rex.args.request.args.kind or rex.args.request.args.kind=='session') and result.target then\nlocal history=(function()\n{HISTORY_SCRIPT}\nend)()\nhistory.remember(result.target.session_id,rex.args.request.args.cwd)\nend\nreturn result\n");
    let output = run_script(
        context,
        &source,
        None,
        &json!({"request":request,"context":{
            "client_id":context.client_id,"session_id":context.session_id,
            "window_id":context.window_id,"block_id":context.block_id,
            "picker_block_id":context.picker_block_id,"origin_zoomed_block_id":context.origin_zoomed_block_id,
        }}),
    )?;
    let data = serde_json::from_slice(&output)
        .map_err(|e| format!("Cannot decode Rex operation result: {e}"))?;
    Ok(action_data(context, operation, data))
}

fn action_data(context: &RexContext, operation: &str, mut data: Value) -> Value {
    if operation == "schedule-target" && data.is_object() {
        if let Some(server) = &context.server {
            data["server"] = json!(server);
        }
        data["client_id"] = json!(context.client_id);
    }
    data
}

pub(crate) fn activate(context: &RexContext, target: &Target) -> Result<(), String> {
    let mut args = activation_args(context, target)?;
    if let Some(path) = &context.result_file {
        let mut target = args;
        target.as_object_mut().unwrap().remove("client_id");
        return write_result(
            path,
            &json!({"version":1,"outcome":"select","target":target}),
        );
    }
    args["history_origin_session"] = json!(context.session_id);
    let session_id = args["session_id"].as_str().unwrap();
    run_script(context, &activation_script(), Some(session_id), &args)?;
    Ok(())
}

pub(crate) fn restore(context: &RexContext) -> Result<(), String> {
    if let Some(path) = &context.result_file {
        return write_result(path, &json!({"version":1,"outcome":"cancel"}));
    }
    let args = restoration_args(context)?;
    // Do not scope the CLI before Lua runs: the origin session may be gone.
    run_script(context, &activation_script(), None, &args)?;
    Ok(())
}

pub(crate) fn report_error(context: &RexContext, message: &str) -> Result<(), String> {
    match &context.result_file {
        Some(path) => write_result(
            path,
            &json!({"version":1,"outcome":"error","message":message}),
        ),
        None => Ok(()),
    }
}

fn activation_script() -> String {
    format!("local activate = (function()\n{ACTIVATE_SCRIPT}\nend)()\nlocal result=activate(rex.args)\nif not rex.args.restore then\nlocal history=(function()\n{HISTORY_SCRIPT}\nend)()\nhistory.remember(rex.args.session_id,nil,rex.args.history_origin_session)\nend\nreturn result\n")
}

fn write_result(path: &Path, result: &Value) -> Result<(), String> {
    let mut temporary = path.as_os_str().to_os_string();
    temporary.push(".tmp");
    let temporary = PathBuf::from(temporary);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options
        .open(&temporary)
        .map_err(|e| format!("Cannot create Rex result {}: {e}", temporary.display()))?;
    let written =
        serde_json::to_writer(file, result).map_err(|e| format!("Cannot write Rex result: {e}"));
    if let Err(error) = written {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }
    if let Err(error) = fs::rename(&temporary, path) {
        let _ = fs::remove_file(&temporary);
        return Err(format!(
            "Cannot publish Rex result {}: {error}",
            path.display()
        ));
    }
    Ok(())
}

fn restoration_args(context: &RexContext) -> Result<Value, String> {
    let mut args = activation_args(
        context,
        &Target::Rex {
            session_id: context.session_id.clone(),
            window_id: Some(context.window_id.clone()),
            block_id: Some(context.block_id.clone()),
        },
    )?;
    args["restore"] = json!(true);
    if let Some(id) = &context.origin_zoomed_block_id {
        args["origin_zoomed_block_id"] = json!(id);
    }
    Ok(args)
}

fn activation_args(context: &RexContext, target: &Target) -> Result<Value, String> {
    match target {
        Target::Rex {
            session_id,
            window_id,
            block_id,
        } => {
            let mut args = json!({
                "client_id": context.client_id,
                "session_id": session_id,
            });
            if let Some(id) = window_id {
                args["window_id"] = json!(id);
            }
            if let Some(id) = block_id {
                args["block_id"] = json!(id);
            }
            Ok(args)
        }
        _ => Err("A non-Rex target cannot be activated by the Rex backend".into()),
    }
}

fn run_script(
    context: &RexContext,
    script: &str,
    session: Option<&str>,
    args: &Value,
) -> Result<Vec<u8>, String> {
    let binary = resolve_binary()?;
    let mut command = Command::new(&binary);
    // The picker terminal has its own Rex identity. Do not let it redirect
    // collection or conflict with activation's explicit target session.
    command
        .env_remove("REX_SESSION")
        .env_remove("REX_BLOCK")
        .env_remove("REX_CLIENT");
    command.args(["--autostart=false", "--color=never", "--timeout=10s"]);
    if let Some(server) = &context.server {
        command.args(["--server", server]);
    }
    command.args(["do", "-"]);
    if let Some(id) = session {
        command.args(["--session", id]);
    }
    command.arg("--args").arg(args.to_string());
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .map_err(|e| format!("Cannot start Rex CLI {}: {e}", binary.display()))?;
    #[cfg(unix)]
    let local_identity = {
        extern "C" {
            fn getuid() -> u32;
        }
        format!(
            "local imux_collector_pid, imux_collector_uid = {}, {}\n",
            child.id(),
            unsafe { getuid() }
        )
    };
    #[cfg(not(unix))]
    let local_identity = String::new();
    let written = child
        .stdin
        .take()
        .unwrap()
        .write_all(format!("{local_identity}{script}").as_bytes());
    if let Err(error) = written {
        let _ = child.kill();
        let _ = child.wait();
        return Err(format!("Cannot send embedded script to Rex: {error}"));
    }
    let output = child
        .wait_with_output()
        .map_err(|e| format!("Cannot wait for Rex: {e}"))?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(if detail.is_empty() {
            format!("Rex CLI exited with {}", output.status)
        } else {
            detail
        });
    }
    Ok(output.stdout)
}

fn resolve_binary() -> Result<PathBuf, String> {
    if let Some(binary) = env::var_os("INTERDIMUX_REX_BIN").filter(|v| !v.is_empty()) {
        return Ok(PathBuf::from(binary));
    }
    if let Some(path) = env::var_os("PATH") {
        for dir in env::split_paths(&path) {
            let binary = dir.join("rex");
            if binary.is_file() {
                return Ok(binary);
            }
        }
    }
    let suffix = "Contents/Helpers/Rex Server.rex/Contents/MacOS/rex";
    let mut applications = vec![PathBuf::from("/Applications")];
    if let Some(home) = env::var_os("HOME") {
        applications.push(PathBuf::from(home).join("Applications"));
    }
    for parent in applications {
        for app in ["Rex Beta.app", "Rex.app"] {
            let binary = parent.join(app).join(suffix);
            if binary.is_file() {
                return Ok(binary);
            }
        }
    }
    Err("Rex CLI not found; put rex on PATH or set INTERDIMUX_REX_BIN".into())
}

/// Control bytes in server labels must never become terminal escape sequences
/// or break the shared TSV row framing. Sanitize before measuring widths.
fn label(value: &Value) -> String {
    value
        .as_str()
        .unwrap_or("")
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect()
}

fn process_metadata(data: &Value, block_id: &str) -> (String, String) {
    let process = &data["metadata"][block_id];
    let foreground = process
        .get("foreground")
        .filter(|p| p.is_object())
        .or_else(|| process.get("child").filter(|p| p.is_object()));
    let Some(foreground) = foreground else {
        return (String::new(), String::new());
    };
    let command = ["script", "argv0", "name"]
        .iter()
        .filter_map(|key| foreground.get(*key).and_then(Value::as_str))
        .find_map(|raw| {
            let raw = raw.trim();
            let name = Path::new(raw)
                .file_name()
                .and_then(|v| v.to_str())
                .unwrap_or(raw)
                .trim_start_matches('-');
            if name.is_empty() {
                None
            } else {
                Some(label(&json!(name)))
            }
        })
        .unwrap_or_default();
    let cwd = foreground
        .get("cwd")
        .filter(|v| v.as_str().is_some())
        .or_else(|| process.get("child").and_then(|p| p.get("cwd")));
    (command, cwd.map(label).unwrap_or_default())
}

fn is_picker_ui(data: &Value, block: &Value) -> bool {
    if block["label"].as_str() != Some("interdimux")
        || block["creator_name"].as_str() != Some("com.superlogical.terminal")
    {
        return false;
    }
    let Some(id) = block["block_id"].as_str() else {
        return false;
    };
    let child = &data["metadata"][id]["child"];
    // Prefer the actual executable over a changeable argv[0]/process name.
    let executable = ["path", "invoked_path", "argv0", "name"]
        .iter()
        .filter_map(|field| child[*field].as_str())
        .find(|value| !value.is_empty())
        .map(|value| value.strip_suffix(" (deleted)").unwrap_or(value));
    let Some(name) = executable.and_then(|value| Path::new(value).file_name()) else {
        return false;
    };
    name == "imux"
        || env::current_exe()
            .ok()
            .and_then(|path| path.file_name().map(|s| s.to_owned()))
            .as_deref()
            == Some(name)
        || env::var_os("INTERDIMUX_BIN")
            .and_then(|path| Path::new(&path).file_name().map(|s| s.to_owned()))
            .as_deref()
            == Some(name)
}

fn title_owned_by_foreground(metadata: &Value) -> bool {
    let Some(foreground) = metadata.get("foreground").filter(|v| v.is_object()) else {
        return false;
    };
    let Some(pid) = foreground["pid"].as_u64().filter(|pid| *pid > 0) else {
        return false;
    };
    let Some(name) = foreground["name"].as_str().filter(|name| !name.is_empty()) else {
        return false;
    };
    metadata["title_owner"]["pid"].as_u64() == Some(pid)
        && metadata["title_owner"]["name"].as_str() == Some(name)
}

fn status_timestamp(value: &str) -> Option<i64> {
    let b = value.as_bytes();
    let number = |part: &[u8]| -> Option<i64> {
        part.iter().try_fold(0i64, |n, digit| {
            if digit.is_ascii_digit() {
                Some(n * 10 + i64::from(*digit - b'0'))
            } else {
                None
            }
        })
    };
    if b.len() < 20
        || b[4] != b'-'
        || b[7] != b'-'
        || !matches!(b[10], b'T' | b't')
        || b[13] != b':'
        || b[16] != b':'
    {
        return None;
    }
    let year = number(&b[..4])?;
    let month = number(&b[5..7])?;
    let day = number(&b[8..10])?;
    let hour = number(&b[11..13])?;
    let minute = number(&b[14..16])?;
    let second = number(&b[17..19])?;
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if leap {
                29
            } else {
                28
            }
        }
        _ => return None,
    };
    if !(1..=days).contains(&day) || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let mut index = 19;
    if b.get(index) == Some(&b'.') {
        index += 1;
        let start = index;
        while b.get(index).is_some_and(u8::is_ascii_digit) {
            index += 1;
        }
        if index == start {
            return None;
        }
    }
    let offset = match b.get(index) {
        Some(b'Z' | b'z') if index + 1 == b.len() => 0,
        Some(sign @ (b'+' | b'-')) if index + 6 == b.len() && b[index + 3] == b':' => {
            let hours = number(&b[index + 1..index + 3])?;
            let minutes = number(&b[index + 4..index + 6])?;
            if hours > 23 || minutes > 59 {
                return None;
            }
            (hours * 3600 + minutes * 60) * if *sign == b'+' { 1 } else { -1 }
        }
        _ => return None,
    };
    // Gregorian civil date to Unix days, independent of timezone/locale.
    let y = year - i64::from(month <= 2);
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some((era * 146097 + doe - 719468) * 86400 + hour * 3600 + minute * 60 + second - offset)
}

fn program_status(metadata: &Value) -> Option<ProgramStatus> {
    let foreground = metadata.get("foreground")?.as_object()?;
    let pid = foreground.get("pid")?.as_u64().filter(|pid| *pid > 0)?;
    let name = foreground
        .get("name")?
        .as_str()
        .filter(|name| !name.is_empty())?;
    let records = metadata.get("program_status")?.get("records")?.as_array()?;
    let mut chosen = None;
    let mut priority = 0;
    for record in records {
        // PID alone is insufficient: it can have been reused by a new program.
        if record["owner"]["pid"].as_u64() != Some(pid)
            || record["owner"]["name"].as_str() != Some(name)
        {
            continue;
        }
        let (rank, word) = match record["state"].as_str() {
            Some("blocked") if record["kind"] == "permission" => (60, "approve"),
            Some("blocked") => (59, "input"),
            Some("error") => (50, "error"),
            Some("working") => (40, "working"),
            Some("done") => (30, "done"),
            // Rex specifies unknown states as idle so newer reporting
            // programs remain visible without inventing urgency.
            Some(_) => (20, "idle"),
            None => continue,
        };
        if rank > priority {
            priority = rank;
            chosen = Some(ProgramStatus {
                state: word.to_owned(),
                progress: matches!(record["state"].as_str(), Some("working" | "blocked"))
                    .then(|| record["progress"].as_u64().filter(|value| *value <= 100))
                    .flatten()
                    .map(|value| value as u8),
                title: label(&record["title"]),
                message: label(&record["msg"]),
                app: label(record.get("effective_app").unwrap_or(&record["app"])),
                task_id: label(&record["id"]),
                since: record["updated_at"]
                    .as_str()
                    .and_then(status_timestamp)
                    .unwrap_or(0),
            });
        }
    }
    chosen
}

fn short_id(id: &str) -> &str {
    let suffix = id.rsplit(':').next().unwrap_or(id);
    if suffix.len() > 8 && suffix.is_ascii() {
        &suffix[suffix.len() - 8..]
    } else {
        suffix
    }
}

fn default_window_name(name: &str) -> bool {
    name.strip_prefix("Window ")
        .map(|suffix| suffix.len() == 8 && suffix.bytes().all(|c| c.is_ascii_hexdigit()))
        .unwrap_or(false)
}

fn array(value: Option<&Value>) -> Result<&[Value], String> {
    match value {
        None | Some(Value::Null) => Ok(&[]),
        Some(Value::Array(values)) => Ok(values),
        // rex do serializes newly constructed empty Lua tables as objects.
        Some(Value::Object(values)) if values.is_empty() => Ok(&[]),
        _ => Err("Rex snapshot contains a malformed list".into()),
    }
}

fn id<'a>(value: &'a Value, key: &str) -> Result<&'a str, String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("Rex snapshot is missing {key}"))
}

fn parse_snapshot(bytes: &[u8], context: &RexContext) -> Result<Snapshot, String> {
    let data: Value = serde_json::from_slice(bytes)
        .map_err(|e| format!("Cannot decode Rex snapshot JSON: {e}"))?;
    if data["version"].as_u64() != Some(1) {
        return Err("Unsupported Rex snapshot version; rebuild interdimux".into());
    }
    let sessions = array(data.get("sessions"))?;
    let views = data
        .get("views")
        .and_then(Value::as_object)
        .ok_or("Rex snapshot is missing its views map")?;
    let mut snapshot = Snapshot {
        current: Current {
            session_key: context.session_id.clone(),
            window_key: context.window_id.clone(),
            pane_key: context.block_id.clone(),
            host: String::new(),
            host_short: String::new(),
        },
        ..Snapshot::default()
    };
    let mut names = HashMap::new();
    for session in sessions {
        *names.entry(label(&session["label"])).or_insert(0usize) += 1;
    }
    for session in sessions {
        let session_id = id(session, "session_id")?;
        let view = match views.get(session_id) {
            Some(view) => view,
            None => continue, // Closed during collection; never offer its stale row.
        };
        let windows = array(view.get("windows"))?;
        let raw_name = label(&session["label"]);
        let name = if raw_name.trim().is_empty() {
            format!("Session {}", short_id(session_id))
        } else if names.get(&raw_name).copied().unwrap_or(0) > 1 {
            format!("{} [{}]", raw_name, short_id(session_id))
        } else {
            raw_name
        };
        snapshot.sessions.push(Session {
            key: session_id.into(),
            name,
            window_count: windows.len().to_string(),
            attached: session_id == context.session_id,
            last: data["mru"][session_id].as_i64().unwrap_or(0),
            path: String::new(),
            target: Target::Rex {
                session_id: session_id.into(),
                window_id: None,
                block_id: None,
            },
        });
        let first_window = snapshot.windows.len();
        for (window_index, window) in windows.iter().enumerate() {
            let window_id = id(window, "window_id")?;
            let ordinal = (window_index + 1).to_string();
            let mut name = label(&window["label"]);
            if name.trim().is_empty() {
                name = format!("Window {ordinal}");
            }
            let mut blocks = Vec::new();
            for layer in array(window.get("layers"))? {
                for block in array(layer.get("blocks"))? {
                    let block_id = id(block, "block_id")?;
                    if context.picker_block_id.as_deref() != Some(block_id)
                        && !is_picker_ui(&data, block)
                    {
                        blocks.push(block);
                    }
                }
            }
            // The float owns Rex focus while it is open. Keep the initiating
            // pane active if it still belongs here, including after a swap;
            // otherwise use the surviving focus instead of a stale origin ID.
            let origin = (session_id == context.session_id)
                .then(|| {
                    blocks
                        .iter()
                        .find(|block| block["block_id"].as_str() == Some(context.block_id.as_str()))
                })
                .flatten();
            let active_block = origin
                .or_else(|| {
                    blocks.iter().find(|block| {
                        block["block_id"].as_str() == window["focused_block_id"].as_str()
                    })
                })
                .or_else(|| blocks.first());
            let active_id = active_block.and_then(|block| block["block_id"].as_str());
            if origin.is_some() {
                snapshot.current.window_key = window_id.into();
            }
            let (active_command, active_path) = active_block
                .and_then(|block| block["block_id"].as_str())
                .map(|id| process_metadata(&data, id))
                .unwrap_or_default();
            if default_window_name(&name) {
                name = if active_command.is_empty() {
                    format!("Window {ordinal}")
                } else {
                    active_command.clone()
                };
            }
            snapshot.windows.push(Window {
                key: window_id.into(),
                session_key: session_id.into(),
                ordinal,
                name,
                active: view["active_window_id"].as_str() == Some(window_id),
                cmd: active_command,
                path: active_path,
                pane_count: blocks.len(),
                pid: 0,
                zoomed: window["zoomed_block_id"].as_str().is_some()
                    || (session_id == context.session_id
                        && context.origin_zoomed_block_id.as_deref().is_some_and(|id| {
                            blocks
                                .iter()
                                .any(|block| block["block_id"].as_str() == Some(id))
                        })),
                bell: false,
                activity: false,
                target: Target::Rex {
                    session_id: session_id.into(),
                    window_id: Some(window_id.into()),
                    block_id: None,
                },
            });
            for (block_index, block) in blocks.iter().enumerate() {
                let block_id = id(block, "block_id")?;
                let (command, path) = process_metadata(&data, block_id);
                let metadata = &data["metadata"][block_id];
                let local = ((context.snapshot_file.is_some() && context.result_file.is_some())
                    || (data["local_host_id"]
                        .as_str()
                        .filter(|s| !s.is_empty())
                        .is_some()
                        && data["local_host_id"] == data["host_id"]))
                    && data["host_id"].as_str().filter(|s| !s.is_empty()).is_some()
                    && data["host_id"].as_str() == block["host_id"].as_str();
                let process = metadata
                    .get("foreground")
                    .filter(|p| p.is_object())
                    .or_else(|| metadata.get("child").filter(|p| p.is_object()));
                let mut title = if title_owned_by_foreground(metadata) {
                    label(&metadata["title"])
                } else {
                    String::new()
                };
                let mut current_title = !title.trim().is_empty();
                let mut reported_title = false;
                let mut alternate_title = None;
                let program_status = program_status(metadata);
                if let Some(status) = &program_status {
                    snapshot.registry.insert(
                        block_id.to_owned(),
                        agent::Record {
                            sid: String::new(),
                            word: status.state.clone(),
                            since: status.since,
                        },
                    );
                    let is_title = !status.title.trim().is_empty();
                    let activity_title = if is_title {
                        &status.title
                    } else {
                        &status.message
                    };
                    if title.trim().is_empty() && !activity_title.trim().is_empty() {
                        title = activity_title.clone();
                        reported_title = true;
                        current_title = is_title;
                    } else if is_title && !activity_title.trim().is_empty() {
                        alternate_title = Some(activity_title.clone());
                    }
                }
                snapshot.pane_metadata.insert(
                    block_id.to_owned(),
                    PaneMetadata {
                        home: label(&metadata["home"]),
                        local,
                        command_line: String::new(),
                        git_branch: None,
                        reported_title,
                        current_title,
                        alternate_title,
                        program_status,
                    },
                );
                let mut block_label = label(&block["label"]);
                if block_label.trim().is_empty()
                    || (!command.is_empty()
                        && (block_label.eq_ignore_ascii_case("shell")
                            || block_label.eq_ignore_ascii_case("terminal")))
                {
                    block_label = if command.is_empty() {
                        format!("Pane {}", block_index + 1)
                    } else {
                        command.clone()
                    };
                }
                snapshot.panes.push(Pane {
                    key: block_id.into(),
                    session_key: session_id.into(),
                    window_key: window_id.into(),
                    ordinal: (block_index + 1).to_string(),
                    name: block_label,
                    active: active_id == Some(block_id),
                    cmd: command,
                    path,
                    pid: process
                        .and_then(|p| p["pid"].as_u64())
                        .and_then(|pid| u32::try_from(pid).ok())
                        .unwrap_or(0),
                    agent_id: block_id.to_owned(),
                    title,
                    opts: String::new(),
                    target: Target::Rex {
                        session_id: session_id.into(),
                        window_id: Some(window_id.into()),
                        block_id: Some(block_id.into()),
                    },
                });
            }
        }
        // Rex has no native session-start directory. Keep an explicit create
        // association when known; otherwise describe its active pane's cwd.
        let session_path = data["session_paths"][session_id]
            .as_str()
            .map(|s| label(&json!(s)))
            .filter(|s| !s.is_empty())
            .or_else(|| {
                snapshot.windows[first_window..]
                    .iter()
                    .find(|w| w.active && !w.path.is_empty())
                    .or_else(|| {
                        snapshot.windows[first_window..]
                            .iter()
                            .find(|w| !w.path.is_empty())
                    })
                    .map(|w| w.path.clone())
            });
        if let Some(path) = session_path {
            if let Some(session) = snapshot.sessions.last_mut() {
                session.path = path;
            }
        }
    }
    if !sessions.is_empty() && snapshot.sessions.is_empty() {
        let detail = data
            .get("errors")
            .and_then(Value::as_object)
            .map(|errors| {
                errors
                    .values()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join("; ")
            })
            .unwrap_or_default();
        return Err(format!(
            "Rex snapshot returned no usable session views: {detail}"
        ));
    }
    Ok(snapshot)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> RexContext {
        RexContext {
            server: None,
            client_id: "client:origin".into(),
            session_id: "session:a".into(),
            window_id: "window:a".into(),
            block_id: "block:origin".into(),
            picker_block_id: Some("block:picker".into()),
            origin_zoomed_block_id: Some("block:origin".into()),
            snapshot_file: None,
            result_file: None,
        }
    }

    fn parse(data: Value) -> Snapshot {
        parse_snapshot(&serde_json::to_vec(&data).unwrap(), &context()).unwrap()
    }

    #[test]
    fn empty_and_nullable_lists_are_accepted() {
        for sessions in [Value::Null, json!([]), json!({})] {
            let result = parse(json!({"version":1, "sessions":sessions, "views":{}}));
            assert!(result.sessions.is_empty());
            assert!(result.panes.is_empty());
        }
    }

    #[test]
    fn duplicate_labels_keep_distinct_keys_and_full_targets() {
        let result = parse(json!({"version":1,
            "sessions":[{"session_id":"session:a","label":"same"},{"session_id":"session:b","label":"same"}],
            "views":{"session:a":{"windows":null},"session:b":{"windows":[]}}
        }));
        assert_eq!(result.sessions.len(), 2);
        assert_ne!(result.sessions[0].key, result.sessions[1].key);
        assert_ne!(result.sessions[0].name, result.sessions[1].name);
        assert_eq!(
            result.sessions[1].target,
            Target::Rex {
                session_id: "session:b".into(),
                window_id: None,
                block_id: None,
            }
        );
    }

    #[test]
    fn placed_floating_blocks_are_included_and_picker_excluded() {
        let result = parse(json!({"version":1,
            "sessions":[{"session_id":"session:a","label":"work"}],
            "views":{"session:a":{"active_window_id":"window:a","windows":[{
                "window_id":"window:a","label":"editor","focused_block_id":"block:picker",
                "layers":[
                    {"kind":"tiled","blocks":[{"block_id":"block:origin","label":"editor"}]},
                    {"kind":"floating","blocks":[{"block_id":"block:float","label":"logs"}]},
                    {"kind":"floating","blocks":[{"block_id":"block:picker","label":"interdimux"}]}
                ]
            }]}}
        }));
        assert_eq!(result.windows[0].pane_count, 2);
        assert_eq!(result.panes.len(), 2);
        assert!(result.panes[0].active); // Origin, not the now-focused picker.
        assert_eq!(result.panes[1].key, "block:float");
        assert!(!result.panes.iter().any(|p| p.key == "block:picker"));
        assert_eq!(result.current.pane_key, "block:origin");
    }

    #[test]
    fn active_panes_and_current_marker_follow_the_surviving_origin_after_a_swap() {
        let result = parse(json!({"version":1,
            "sessions":[{"session_id":"session:a","label":"work"}],
            "views":{"session:a":{"active_window_id":"window:a","windows":[
                {"window_id":"window:a","focused_block_id":"block:picker","layers":[{"blocks":[
                    {"block_id":"block:replacement"},{"block_id":"block:picker"}
                ]}]},
                {"window_id":"window:b","focused_block_id":"block:other","layers":[{"blocks":[
                    {"block_id":"block:other"},{"block_id":"block:origin"}
                ]}]}
            ]}},
            "metadata":{
                "block:replacement":{"foreground":{"name":"zsh","cwd":"/replacement"}},
                "block:origin":{"foreground":{"name":"nvim","cwd":"/origin"}},
                "block:other":{"foreground":{"name":"top","cwd":"/other"}}
            }
        }));
        assert_eq!(result.current.window_key, "window:b");
        assert_eq!(result.current.pane_key, "block:origin");
        assert!(
            result.panes[0].active,
            "The replacement is the old window's surviving pane"
        );
        assert!(!result.panes[1].active);
        assert!(
            result.panes[2].active,
            "The origin must stay active under the picker"
        );
        assert_eq!(result.windows[1].cmd, "nvim");
        assert_eq!(result.windows[1].path, "/origin");
        assert!(!result.windows[0].zoomed);
        assert!(
            result.windows[1].zoomed,
            "Saved zoom follows its pane to the new window"
        );
    }

    #[test]
    fn a_closed_origin_uses_the_windows_surviving_focused_pane() {
        let result = parse(json!({"version":1,
            "sessions":[{"session_id":"session:a","label":"work"}],
            "views":{"session:a":{"active_window_id":"window:a","windows":[{
                "window_id":"window:a","focused_block_id":"block:focused","layers":[{"blocks":[
                    {"block_id":"block:first"},{"block_id":"block:focused"}
                ]}]
            }]}},
            "metadata":{
                "block:first":{"foreground":{"name":"zsh","cwd":"/first"}},
                "block:focused":{"foreground":{"name":"nvim","cwd":"/focused"}}
            }
        }));
        assert!(!result.panes[0].active);
        assert!(result.panes[1].active);
        assert_eq!(result.windows[0].cmd, "nvim");
        assert!(
            !result.windows[0].zoomed,
            "A closed origin cannot keep a stale zoom badge"
        );
        assert_eq!(result.sessions[0].path, "/focused");
        assert_eq!(
            crate::preview::capture_target(&result, &result.windows[0].target),
            Some(result.panes[1].target.clone())
        );
    }

    #[test]
    fn closed_sessions_are_skipped_and_control_bytes_cannot_escape_rows() {
        let result = parse(json!({"version":1,
            "sessions":[{"session_id":"session:gone","label":"gone"},{"session_id":"session:a","label":"tab\tnew\n\u{1b}[2J"}],
            "views":{"session:a":{"windows":[]}}, "errors":{"session:gone":"not found"}
        }));
        assert_eq!(result.sessions.len(), 1);
        assert!(!result.sessions[0].name.chars().any(char::is_control));
        assert_eq!(result.sessions[0].key, "session:a");
    }

    #[test]
    fn invalid_json_version_and_shapes_are_errors() {
        assert!(parse_snapshot(b"not json", &context()).is_err());
        assert!(parse_snapshot(br#"{"version":2,"views":{}}"#, &context()).is_err());
        assert!(
            parse_snapshot(br#"{"version":1,"sessions":"bad","views":{}}"#, &context()).is_err()
        );
    }

    #[test]
    fn activation_has_exact_originating_client_and_typed_ids() {
        let target = Target::Rex {
            session_id: "session:other".into(),
            window_id: Some("window:other".into()),
            block_id: Some("block:other".into()),
        };
        let args = activation_args(&context(), &target).unwrap();
        assert_eq!(args["client_id"], "client:origin");
        assert_eq!(args["session_id"], "session:other");
        assert_eq!(args["block_id"], "block:other");
        assert!(args.get("restore").is_none());
        assert!(args.get("origin_zoomed_block_id").is_none());
        assert!(activation_args(
            &context(),
            &Target::TmuxLegacy {
                spec: "S:name".into()
            }
        )
        .is_err());
    }

    #[test]
    fn cancellation_alone_requests_saved_zoom_restoration() {
        let mut context = context();
        let args = restoration_args(&context).unwrap();
        assert_eq!(args["restore"], true);
        assert_eq!(args["origin_zoomed_block_id"], "block:origin");
        assert_eq!(args["block_id"], "block:origin");
        context.origin_zoomed_block_id = None;
        assert!(restoration_args(&context)
            .unwrap()
            .get("origin_zoomed_block_id")
            .is_none());
    }

    #[test]
    fn process_metadata_is_separate_from_pane_label_and_uses_real_cwd() {
        let result = parse(json!({"version":1,
            "sessions":[{"session_id":"session:a","label":"work"}],
            "views":{"session:a":{"active_window_id":"window:a","windows":[{
                "window_id":"window:a","label":"editor","focused_block_id":"block:origin",
                "layers":[{"kind":"tiled","blocks":[
                    {"block_id":"block:origin","label":"My build logs"},
                    {"block_id":"block:other","label":""}
                ]}]
            }]}},
            "metadata":{
                "block:origin":{"foreground":{"script":"/work/dev-server.js","argv0":"node","name":"node","cwd":"/work/project"},"child":{"name":"login","cwd":"/home/me"}},
                "block:other":{"foreground":null,"child":{"argv0":"-zsh","name":"zsh","cwd":"/work/other"}}
            }
        }));
        assert_eq!(result.panes[0].name, "My build logs");
        assert_eq!(result.panes[0].cmd, "dev-server.js");
        assert_eq!(result.panes[0].path, "/work/project");
        assert_eq!(result.windows[0].cmd, "dev-server.js");
        assert_eq!(result.windows[0].path, "/work/project");
        assert_eq!(result.panes[1].name, "zsh");
        assert_eq!(result.panes[1].cmd, "zsh");
        assert_eq!(result.panes[1].path, "/work/other");
    }

    #[test]
    fn native_default_labels_follow_process_names_without_replacing_custom_labels() {
        for (window, pane, process, expected_window, expected_pane) in [
            ("Window deadbeef", "shell", true, "codex", "codex"),
            ("Window ABCD1234", "Terminal", true, "codex", "codex"),
            (
                "Window deadbeef notes",
                "My build logs",
                true,
                "Window deadbeef notes",
                "My build logs",
            ),
            (
                "Window nothexzz",
                "shell scripts",
                true,
                "Window nothexzz",
                "shell scripts",
            ),
            ("Window deadbeef", "shell", false, "Window 1", "shell"),
        ] {
            let metadata = if process {
                json!({"block:origin":{"foreground":{"argv0":"/usr/bin/codex","name":"codex"}}})
            } else {
                Value::Null
            };
            let result = parse(json!({"version":1,
                "sessions":[{"session_id":"session:a","label":"work"}],
                "views":{"session:a":{"windows":[{
                    "window_id":"window:a","label":window,"focused_block_id":"block:origin",
                    "layers":[{"kind":"tiled","blocks":[{"block_id":"block:origin","label":pane}]}]
                }]}}, "metadata":metadata
            }));
            assert_eq!(result.windows[0].name, expected_window);
            assert_eq!(result.panes[0].name, expected_pane);
        }
    }

    #[test]
    fn hosted_completion_records_are_atomic_and_do_not_include_the_app_identity() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory =
            std::env::temp_dir().join(format!("imux-rex-result-{}-{unique}", std::process::id()));
        fs::create_dir(&directory).unwrap();
        let result_path = directory.join("result.json");
        let mut context = context();
        context.result_file = Some(result_path.clone());
        let read = || serde_json::from_slice::<Value>(&fs::read(&result_path).unwrap()).unwrap();
        activate(
            &context,
            &Target::Rex {
                session_id: "session:other".into(),
                window_id: Some("window:other".into()),
                block_id: Some("block:other".into()),
            },
        )
        .unwrap();
        assert_eq!(
            read(),
            json!({"version":1,"outcome":"select","target":{
                "session_id":"session:other","window_id":"window:other","block_id":"block:other"
            }})
        );
        restore(&context).unwrap();
        assert_eq!(read(), json!({"version":1,"outcome":"cancel"}));
        report_error(&context, "fzf failed").unwrap();
        assert_eq!(
            read(),
            json!({"version":1,"outcome":"error","message":"fzf failed"})
        );
        assert!(!directory.join("result.json.tmp").exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&result_path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn close_origin_pane_and_zoom_are_deferred_until_the_host_exits() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory =
            std::env::temp_dir().join(format!("imux-rex-deferred-{}-{unique}", std::process::id()));
        fs::create_dir(&directory).unwrap();
        let mut context = context();
        context.result_file = Some(directory.join("result.json"));
        let origin = Target::Rex {
            session_id: context.session_id.clone(),
            window_id: Some(context.window_id.clone()),
            block_id: Some(context.block_id.clone()),
        };
        for operation in ["close", "zoom"] {
            assert_eq!(
                action(&context, operation, Some(&origin), &json!({})).unwrap()["deferred"],
                true
            );
            let result: Value =
                serde_json::from_slice(&fs::read(context.result_file.as_ref().unwrap()).unwrap())
                    .unwrap();
            assert_eq!(result["outcome"], "action");
            assert_eq!(result["operation"], operation);
            assert_eq!(result["target"]["block_id"], "block:origin");
        }
        assert!(action(&context, "detach", Some(&origin), &json!({}))
            .unwrap_err()
            .contains("no tmux-style detach"));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn hosted_host_proof_mru_and_project_path_are_normalized_conservatively() {
        let mut data = json!({"version":1,"host_id":"host:local",
            "sessions":[{"session_id":"session:a","label":"work"}],
            "views":{"session:a":{"active_window_id":"window:a","windows":[{
                "window_id":"window:a","label":"editor","focused_block_id":"block:origin",
                "layers":[{"blocks":[{"block_id":"block:origin","label":"shell","host_id":"host:local"}]}]
            }]}},
            "metadata":{"block:origin":{"home":"/home/me","foreground":{"pid":123,"name":"zsh","cwd":"/active/path"}}},
            "mru":{"session:a":1234},"session_paths":{"session:a":"/initial/path"}
        });
        let mut ctx = context();
        let direct = parse_snapshot(&serde_json::to_vec(&data).unwrap(), &ctx).unwrap();
        assert!(!direct.pane_metadata["block:origin"].local);
        data["local_host_id"] = json!("host:local");
        let proven = parse_snapshot(&serde_json::to_vec(&data).unwrap(), &ctx).unwrap();
        assert!(proven.pane_metadata["block:origin"].local);
        data["local_host_id"] = json!("host:remote");
        let unproven = parse_snapshot(&serde_json::to_vec(&data).unwrap(), &ctx).unwrap();
        assert!(!unproven.pane_metadata["block:origin"].local);
        data.as_object_mut().unwrap().remove("local_host_id");
        assert_eq!(direct.sessions[0].last, 1234);
        assert_eq!(direct.sessions[0].path, "/initial/path");
        assert!(
            direct.windows[0].zoomed,
            "saved origin zoom remains visible while picker has focus"
        );
        ctx.snapshot_file = Some("snapshot.json".into());
        ctx.result_file = Some("result.json".into());
        data.as_object_mut().unwrap().remove("session_paths");
        let hosted = parse_snapshot(&serde_json::to_vec(&data).unwrap(), &ctx).unwrap();
        assert!(hosted.pane_metadata["block:origin"].local);
        assert_eq!(hosted.pane_metadata["block:origin"].home, "/home/me");
        assert_eq!(hosted.sessions[0].path, "/active/path");
        data["host_id"] = json!("host:other");
        let remote = parse_snapshot(&serde_json::to_vec(&data).unwrap(), &ctx).unwrap();
        assert!(!remote.pane_metadata["block:origin"].local);
    }

    #[test]
    fn collector_proves_only_the_exact_local_unix_peer() {
        let setup = r#"
local imux_collector_pid, imux_collector_uid = 123, 501
local principal = { kind = "peer", transport = "unix", pid = 123, uid = 501 }
rex = {
  call = function(method)
    if method == "session.attach_all" then return { sessions = {} } end
    if method == "server.status" then return { host_id = "host:local" } end
    if method == "server.whoami" then return { principal = principal } end
    error("Unexpected method: " .. tostring(method))
  end,
}
"#;
        let code = format!(
            "{setup}\nlocal function snapshot()\n{SNAPSHOT_SCRIPT}\nend\n\
             assert(snapshot().local_host_id == 'host:local')\n\
             principal.pid = 124; assert(snapshot().local_host_id == nil)\n\
             principal.pid = 123; principal.uid = 502; assert(snapshot().local_host_id == nil)\n\
             principal.uid = 501; principal.transport = 'tcp'; assert(snapshot().local_host_id == nil)\n\
             principal.transport = 'unix'; principal.kind = 'remote'; assert(snapshot().local_host_id == nil)\n\
             principal.kind = 'peer'; principal.path = {{'login-server'}}; assert(snapshot().local_host_id == nil)\n\
             principal.path = {{hop = 'login-server'}}; assert(snapshot().local_host_id == nil)\n\
             principal.path = ''; assert(snapshot().local_host_id == nil)\n\
             principal.path = false; assert(snapshot().local_host_id == nil)\n\
             principal.path = {{}}; assert(snapshot().local_host_id == 'host:local')"
        );
        let mut child = match Command::new("lua")
            .arg("-")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(child) => child,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            Err(error) => panic!("Cannot start Lua: {error}"),
        };
        child
            .stdin
            .take()
            .unwrap()
            .write_all(code.as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn standalone_and_hosted_history_share_mru_without_remote_filesystem_reads() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        let output = match Command::new("lua")
            .arg(root.join("tests/rex_history.lua"))
            .arg(root)
            .output()
        {
            Ok(output) => output,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            Err(error) => panic!("Cannot start Lua: {error}"),
        };
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn native_activity_prioritizes_permission_and_ignores_stale_owners() {
        let owner = json!({"pid":123,"name":"codex"});
        let mut metadata = json!({"foreground":owner,"program_status":{"records":[
            {"state":"idle","owner":owner},
            {"state":"done","owner":owner},
            {"state":"working","owner":owner},
            {"state":"error","owner":owner},
            {"state":"blocked","kind":"question","owner":owner,"msg":"Choose a branch"},
            {"state":"blocked","kind":"permission","owner":owner,"title":"Approve\ncommand\u{1b}"}
        ]}});
        assert_eq!(
            program_status(&metadata),
            Some(ProgramStatus {
                state: "approve".into(),
                title: "Approve command ".into(),
                ..ProgramStatus::default()
            })
        );
        metadata["program_status"]["records"]
            .as_array_mut()
            .unwrap()
            .pop();
        assert_eq!(
            program_status(&metadata),
            Some(ProgramStatus {
                state: "input".into(),
                message: "Choose a branch".into(),
                ..ProgramStatus::default()
            })
        );
        metadata["program_status"]["records"] = json!([
            {"state":"blocked","kind":"permission","owner":{"pid":999,"name":"codex"}},
            {"state":"blocked","kind":"permission","owner":{"pid":123,"name":"reused-pid"}},
            {"state":"blocked","kind":"permission"},
            {"state":"working","owner":owner,"msg":"Current task"}
        ]);
        assert_eq!(
            program_status(&metadata),
            Some(ProgramStatus {
                state: "working".into(),
                message: "Current task".into(),
                ..ProgramStatus::default()
            })
        );
        metadata["foreground"] = Value::Null;
        metadata["child"] = owner;
        assert_eq!(
            program_status(&metadata),
            None,
            "status requires a verified current foreground owner"
        );
    }

    #[test]
    fn native_progress_preserves_verified_task_details_and_rejects_invalid_percentages() {
        let owner = json!({"pid":123,"name":"cargo"});
        let mut metadata = json!({"foreground":owner,"program_status":{"records":[
            {"state":"working","owner":owner,"id":"build/tests","effective_app":"cargo",
             "title":"Integration tests","msg":"42 of 100\nfinished\u{1b}","progress":42},
            {"state":"blocked","kind":"permission","owner":{"pid":123,"name":"old-process"},"progress":99}
        ]}});
        let status = program_status(&metadata).unwrap();
        assert_eq!(status.state, "working");
        assert_eq!(status.progress, Some(42));
        assert_eq!(status.app, "cargo");
        assert_eq!(status.task_id, "build/tests");
        assert_eq!(status.title, "Integration tests");
        assert_eq!(status.message, "42 of 100 finished ");
        for value in [
            json!(-1),
            json!(101),
            json!(255),
            json!("42"),
            json!(42.5),
            Value::Null,
        ] {
            metadata["program_status"]["records"][0]["progress"] = value;
            assert_eq!(program_status(&metadata).unwrap().progress, None);
        }
        for value in [0, 100] {
            metadata["program_status"]["records"][0]["progress"] = json!(value);
            assert_eq!(program_status(&metadata).unwrap().progress, Some(value));
        }
        metadata["program_status"]["records"][0]["state"] = json!("done");
        assert_eq!(program_status(&metadata).unwrap().progress, None);
        metadata["program_status"]["records"][0]["state"] = json!("future-state");
        let status = program_status(&metadata).unwrap();
        assert_eq!(status.state, "idle");
        assert_eq!(status.progress, None);
        metadata["foreground"]["pid"] = json!(999);
        assert!(program_status(&metadata).is_none());
    }

    #[test]
    fn live_collector_reuses_only_clean_views_and_metadata() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        let output = match Command::new("lua")
            .arg(root.join("tests/rex_snapshot.lua"))
            .arg(root)
            .output()
        {
            Ok(output) => output,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            Err(error) => panic!("Cannot start Lua: {error}"),
        };
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn native_activity_uses_the_shared_registry_and_prefers_its_title() {
        let result = parse(json!({"version":1,
            "sessions":[{"session_id":"session:a","label":"work"}],
            "views":{"session:a":{"windows":[{"window_id":"window:a","layers":[{"blocks":[{
                "block_id":"block:origin","label":"agent"
            }]}]}]}},
            "metadata":{"block:origin":{"title":"Old terminal title",
                "foreground":{"pid":123,"name":"codex","argv0":"codex"},
                "program_status":{"records":[{"state":"blocked","kind":"permission",
                    "owner":{"pid":123,"name":"codex"},"title":"Review changes"}]}
            }}
        }));
        let record = result.registry.get("block:origin").unwrap();
        assert_eq!(record.word, "approve");
        assert!(record.sid.is_empty());
        assert_eq!(record.since, 0);
        assert_eq!(result.panes[0].agent_id, "block:origin");
        assert_eq!(result.panes[0].title, "Review changes");
        assert!(result.pane_metadata["block:origin"].current_title);
        assert_eq!(
            result.pane_metadata["block:origin"]
                .program_status
                .as_ref()
                .unwrap()
                .title,
            "Review changes"
        );
        let rows = crate::presentation::rows(&result, 120);
        assert!(
            rows.iter().any(|r| r.command.contains("Review changes")),
            "A verified program report must remain visible in the shared renderer"
        );
    }

    #[test]
    fn current_agent_conversations_prefer_owned_osc_over_status_messages() {
        let owner = json!({"pid":123,"name":"codex"});
        let mut data = json!({"version":1,"sessions":[{"session_id":"session:a","label":"work"}],
            "views":{"session:a":{"windows":[{"window_id":"window:a","layers":[{"blocks":[{"block_id":"block:origin","label":"agent"}]}]}]}},
            "metadata":{"block:origin":{"foreground":{"pid":123,"name":"codex","argv0":"codex"},
                "title":"⠸ Investigate memory usage | project","title_owner":owner,
                "program_status":{"records":[{"state":"working","owner":owner,"title":"A status title","msg":"Running tools"}]}}}});
        let result = parse(data.clone());
        assert_eq!(
            result.panes[0].title,
            "⠸ Investigate memory usage | project"
        );
        let rows = crate::presentation::rows(&result, 140);
        assert!(rows[1].command.contains("Investigate memory usage"));
        assert!(!rows[1].command.contains("codex"));
        assert!(!rows[1].command.contains("A status title"));
        data["metadata"]["block:origin"]["title_owner"]["pid"] = json!(999);
        let result = parse(data.clone());
        assert_eq!(result.panes[0].title, "A status title");
        assert!(result.pane_metadata["block:origin"].current_title);
        data["metadata"]["block:origin"]["program_status"]["records"][0]
            .as_object_mut()
            .unwrap()
            .remove("title");
        let result = parse(data);
        assert_eq!(result.panes[0].title, "Running tools");
        assert!(
            !result.pane_metadata["block:origin"].current_title,
            "Status messages are not conversation names"
        );
        assert!(result.pane_metadata["block:origin"]
            .alternate_title
            .is_none());
    }

    #[test]
    fn retained_terminal_titles_require_both_foreground_owner_fields() {
        let mut metadata = json!({"title":"Previous conversation","foreground":{"pid":12,"name":"codex"},"title_owner":{"pid":12,"name":"codex"}});
        assert!(title_owned_by_foreground(&metadata));
        metadata["title_owner"]["name"] = json!("zsh");
        assert!(!title_owned_by_foreground(&metadata));
        metadata["title_owner"] = json!({"pid":13,"name":"codex"});
        assert!(!title_owned_by_foreground(&metadata));
        metadata["title_owner"] = Value::Null;
        assert!(!title_owned_by_foreground(&metadata));
        metadata["foreground"] = Value::Null;
        assert!(!title_owned_by_foreground(&metadata));
    }

    #[test]
    fn generic_owned_terminal_titles_keep_a_verified_program_title_as_fallback() {
        let owner = json!({"pid":123,"name":"codex"});
        let mut data = json!({"version":1,"sessions":[{"session_id":"session:a","label":"work"}],
            "views":{"session:a":{"windows":[{"window_id":"window:a","layers":[{"blocks":[{"block_id":"block:origin","label":"agent"}]}]}]}},
            "metadata":{"block:origin":{"foreground":{"pid":123,"name":"codex","argv0":"codex"},
                "title":"Codex","title_owner":owner,
                "program_status":{"records":[{"state":"working","owner":owner,"title":"Repair startup race"}]}}}});
        for osc in ["Codex", "user@unknown:~/project"] {
            data["metadata"]["block:origin"]["title"] = json!(osc);
            let snapshot = parse(data.clone());
            assert_eq!(snapshot.panes[0].title, osc);
            assert_eq!(
                snapshot.pane_metadata["block:origin"]
                    .alternate_title
                    .as_deref(),
                Some("Repair startup race")
            );
            let rows = crate::presentation::rows(&snapshot, 140);
            assert!(rows[1].command.contains("Repair startup race"));
            assert!(!rows[1].command.contains("codex"));
        }
        data["metadata"]["block:origin"]["program_status"]["records"][0]["owner"]["pid"] =
            json!(999);
        let snapshot = parse(data);
        assert!(snapshot.pane_metadata["block:origin"]
            .alternate_title
            .is_none());
        assert!(!crate::presentation::rows(&snapshot, 140)[1]
            .command
            .contains("Repair startup race"));
    }

    #[test]
    fn collector_reads_explicit_program_titles_even_when_state_words_are_disabled() {
        let setup = r#"
local status_calls, title_calls = 0, 0
local terminal = { block_id = "block:a", creator_name = "com.superlogical.terminal" }
rex = {
  call = function(method)
    if method == "session.attach_all" then return { sessions = { { session_id = "session:a" } } } end
    if method == "server.status" then return { host_id = "host:a" } end
    if method == "com.superlogical.terminal.process" then return { foreground = { pid = 123, name = "codex" } } end
    if method == "com.superlogical.terminal.title" then title_calls = title_calls + 1; return { title = "" } end
    if method == "com.superlogical.terminal.program_status" then
      status_calls = status_calls + 1
      return { records = { { state = "working", owner = { pid = 123, name = "codex" }, title = "Repair startup race" } } }
    end
    error("Unexpected method: " .. tostring(method))
  end,
  session = { view = function() return { windows = { { layers = { { blocks = { terminal } } } } } } end },
}
local function snapshot()
"#;
        for (state, mode, expected, titles) in [
            ("off", "known", 1, 1),
            ("off", "off", 0, 0),
            ("on", "off", 1, 0),
        ] {
            let code = format!(
                "{setup}\n{SNAPSHOT_SCRIPT}\nend\nlocal result = snapshot()\nassert(status_calls == {expected}, tostring(status_calls))\nassert(title_calls == {titles}, tostring(title_calls))\n{}",
                if expected == 1 {
                    "assert(result.metadata['block:a'].program_status.records[1].title == 'Repair startup race')"
                } else {
                    "assert(result.metadata['block:a'].program_status == nil)"
                },
            );
            let mut command = Command::new("lua");
            command
                .arg("-")
                .env("INTERDIMUX_AGENT_STATE", state)
                .env("INTERDIMUX_SHOW_TITLE", mode)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());
            let mut child = match command.spawn() {
                Ok(child) => child,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    eprintln!("Lua unavailable; snapshot collector title test skipped");
                    return;
                }
                Err(error) => panic!("Cannot start Lua: {error}"),
            };
            child
                .stdin
                .take()
                .unwrap()
                .write_all(code.as_bytes())
                .unwrap();
            let output = child.wait_with_output().unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }

    #[test]
    fn collector_skips_all_three_metadata_requests_for_its_picker_block_only() {
        let setup = r#"
local calls = { process = 0, title = 0, program_status = 0 }
local blocks = {
  { block_id = "block:target", creator_name = "com.superlogical.terminal" },
  { block_id = "block:picker", creator_name = "com.superlogical.terminal" },
}
rex = {
  call = function(method, args)
    if method == "session.attach_all" then return { sessions = { { session_id = "session:a" } } } end
    if method == "server.status" then return { host_id = "host:a" } end
    local name = method:match("^com%.superlogical%.terminal%.(.+)$")
    assert(calls[name] ~= nil, "Unexpected method: " .. tostring(method))
    assert(not rex.args or args.block_id ~= rex.args.picker_block_id, "queried picker metadata")
    calls[name] = calls[name] + 1
    if name == "process" then return { foreground = { pid = 123, name = "codex" } } end
    if name == "title" then return { title = "Conversation", owner = { pid = 123, name = "codex" } } end
    return { records = { { state = "working", owner = { pid = 123, name = "codex" } } } }
  end,
  session = { view = function() return { windows = { { layers = { { blocks = blocks } } } } } end },
}
"#;
        for skip_picker in [false, true] {
            let args = if skip_picker {
                "rex.args = { picker_block_id = 'block:picker' }"
            } else {
                ""
            };
            let count = if skip_picker { 1 } else { 2 };
            let code = format!(
                "{setup}\n{args}\nlocal function snapshot()\n{SNAPSHOT_SCRIPT}\nend\nlocal result = snapshot()\n\
                 assert(calls.process == {count} and calls.title == {count} and calls.program_status == {count})\n\
                 assert(result.metadata['block:target'].title_owner.pid == 123)\n\
                 assert(result.metadata['block:target'].program_status.records[1].state == 'working')\n\
                 assert((result.metadata['block:picker'] == nil) == {})\n\
                 assert(#result.views['session:a'].windows[1].layers[1].blocks == 2)",
                if skip_picker { "true" } else { "false" },
            );
            let mut command = Command::new("lua");
            command
                .arg("-")
                .env("INTERDIMUX_AGENT_STATE", "on")
                .env("INTERDIMUX_SHOW_TITLE", "known")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());
            let mut child = match command.spawn() {
                Ok(child) => child,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    eprintln!("Lua unavailable; picker metadata test skipped");
                    return;
                }
                Err(error) => panic!("Cannot start Lua: {error}"),
            };
            child
                .stdin
                .take()
                .unwrap()
                .write_all(code.as_bytes())
                .unwrap();
            let output = child.wait_with_output().unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }
    #[test]
    fn only_confirmed_background_picker_executables_are_hidden() {
        let snapshot = parse(
            json!({"version":1,"sessions":[{"session_id":"session:a","label":"work"}],
            "views":{"session:a":{"windows":[{"window_id":"window:a","layers":[{"blocks":[
                {"block_id":"block:origin","label":"interdimux","creator_name":"com.superlogical.terminal"},
                {"block_id":"block:background","label":"interdimux","creator_name":"com.superlogical.terminal"},
                {"block_id":"block:app","label":"interdimux","creator_name":"other.application"},
                {"block_id":"block:renamed","label":"my work","creator_name":"com.superlogical.terminal"},
                {"block_id":"block:spoof","label":"interdimux","creator_name":"com.superlogical.terminal"},
                {"block_id":"block:unknown","label":"interdimux","creator_name":"com.superlogical.terminal"},
                {"block_id":"block:picker","label":"shell","creator_name":"com.superlogical.terminal"}
            ]}]}]}},"metadata":{
                "block:origin":{"child":{"path":"/bin/zsh","argv0":"-zsh","name":"zsh"}},
                "block:background":{"child":{"path":"/opt/tools/interdimux/rust/target/release/imux"}},
                "block:app":{"child":{"path":"/opt/tools/interdimux/rust/target/release/imux"}},
                "block:renamed":{"child":{"argv0":"/opt/tools/interdimux/rust/target/release/imux"}},
                "block:spoof":{"child":{"path":"/bin/cat","argv0":"imux","name":"imux"}}
            }}),
        );
        let keys: Vec<_> = snapshot.panes.iter().map(|p| p.key.as_str()).collect();
        assert_eq!(
            keys,
            [
                "block:origin",
                "block:app",
                "block:renamed",
                "block:spoof",
                "block:unknown"
            ]
        );
    }

    #[test]
    fn status_timestamps_parse_utc_offsets_fractions_and_gregorian_dates() {
        for (text, expected) in [
            ("1970-01-01T00:00:00Z", 0),
            ("1970-01-01T01:30:00+01:30", 0),
            ("1969-12-31T18:30:00-05:30", 0),
            ("2024-02-29T12:34:56.123456789Z", 1709210096),
            ("2024-02-29t14:34:56.9+02:00", 1709210096),
            ("2000-02-29T00:00:00Z", 951782400),
            ("1969-12-31T23:59:59Z", -1),
        ] {
            assert_eq!(status_timestamp(text), Some(expected), "{text}");
        }
        for text in [
            "",
            "2023-02-29T00:00:00Z",
            "1900-02-29T00:00:00Z",
            "2024-04-31T00:00:00Z",
            "2024-00-01T00:00:00Z",
            "2024-01-00T00:00:00Z",
            "2024-01-01T24:00:00Z",
            "2024-01-01T00:60:00Z",
            "2024-01-01T00:00:61Z",
            "2024-01-01T00:00:00.Z",
            "2024-01-01T00:00:00+24:00",
            "2024-01-01T00:00:00+00:60",
            "2024-01-01T00:00:00",
            "2024-01-01T00:00:00Z trailing",
            "2024-aa-01T00:00:00Z",
            "2024-01-01T00:00:xxZ",
            "2024- 1-01T00:00:00Z",
        ] {
            assert_eq!(status_timestamp(text), None, "{text}");
        }
    }
    #[test]
    fn native_status_age_comes_only_from_the_selected_current_owner_record() {
        let owner = json!({"pid":123,"name":"codex"});
        let mut metadata = json!({"foreground":owner,"program_status":{"records":[
            {"state":"working","owner":owner,"updated_at":"2024-02-29T12:34:56Z"},
            {"state":"blocked","kind":"permission","owner":{"pid":999,"name":"codex"},"updated_at":"2025-01-01T00:00:00Z"}
        ]}});
        assert_eq!(program_status(&metadata).unwrap().since, 1709210096);
        let snapshot = parse(
            json!({"version":1,"sessions":[{"session_id":"session:a","label":"work"}],
            "views":{"session:a":{"windows":[{"window_id":"window:a","layers":[{"blocks":[{"block_id":"block:origin","label":"agent"}]}]}]}},
            "metadata":{"block:origin":metadata.clone()}}),
        );
        assert_eq!(snapshot.registry["block:origin"].since, 1709210096);
        metadata["program_status"]["records"][0]["updated_at"] = json!("invalid");
        assert_eq!(program_status(&metadata).unwrap().since, 0);
        metadata["program_status"]["records"][0]["owner"]["name"] = json!("zsh");
        assert!(program_status(&metadata).is_none());
    }
    #[test]
    fn picker_executable_recognition_supports_deleted_and_current_binary_names() {
        let block = json!({"block_id":"ui","label":"interdimux","creator_name":"com.superlogical.terminal"});
        let mut data = json!({"metadata":{"ui":{"child":{"path":"/opt/bin/imux (deleted)"}}}});
        assert!(is_picker_ui(&data, &block));
        data["metadata"]["ui"]["child"]["path"] =
            json!(env::current_exe().unwrap().to_string_lossy());
        assert!(is_picker_ui(&data, &block));
        data["metadata"]["ui"]["child"] = json!({"path":"/bin/cat","argv0":"imux","name":"imux"});
        assert!(
            !is_picker_ui(&data, &block),
            "an authoritative unrelated executable wins over a spoofable name"
        );
    }
}
