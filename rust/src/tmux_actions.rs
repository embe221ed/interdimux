//! Native-ID actions for the shared controller. The legacy Bash frontend stays intact.
use crate::{
    model::{Snapshot, Target},
    tmux_backend::{self, TmuxContext},
};
use serde_json::{json, Value};

fn run(ctx: &TmuxContext, args: Vec<String>) -> Result<String, String> {
    ctx.output(&args.iter().map(String::as_str).collect::<Vec<_>>())
}
fn ids(target: &Target) -> Result<(&str, Option<&str>, Option<&str>), String> {
    match target {
        Target::TmuxNative {
            session_id,
            window_id,
            pane_id,
        } => Ok((session_id, window_id.as_deref(), pane_id.as_deref())),
        _ => Err("This target is not a native tmux object".into()),
    }
}
fn validate(snapshot: &Snapshot, target: &Target) -> Result<(), String> {
    if snapshot.sessions.iter().any(|s| &s.target == target)
        || snapshot.windows.iter().any(|w| &w.target == target)
        || snapshot.panes.iter().any(|p| &p.target == target)
    {
        Ok(())
    } else {
        Err("The selected tmux target no longer exists".into())
    }
}
fn pane(snapshot: &Snapshot, target: &Target) -> Result<Target, String> {
    crate::preview::capture_target(snapshot, target).ok_or("No pane exists in this target".into())
}
fn key_name(key: &str) -> String {
    let mut s = key
        .replace("ctrl+", "C-")
        .replace("alt+", "M-")
        .replace("shift+tab", "BTab");
    s = match s.as_str() {
        "enter" => "Enter".into(),
        "escape" => "Escape".into(),
        "pageup" => "PPage".into(),
        "pagedown" => "NPage".into(),
        "backspace" => "BSpace".into(),
        "space" => "Space".into(),
        "tab" => "Tab".into(),
        "up" => "Up".into(),
        "down" => "Down".into(),
        "left" => "Left".into(),
        "right" => "Right".into(),
        _ => s,
    };
    if s.starts_with('f') && s[1..].parse::<u8>().is_ok() {
        s.make_ascii_uppercase();
    }
    s
}
fn created(text: &str) -> Result<Value, String> {
    let parts: Vec<_> = text.trim().split('\u{1f}').collect();
    if parts.len() != 3 {
        return Err("tmux returned an invalid new target".into());
    }
    Ok(json!({"target":{"session_id":parts[0],"window_id":parts[1],"pane_id":parts[2]}}))
}

// tmux expands names/cwd as formats. Runs of '#' before '[' are copied
// literally by its format parser, so only other runs need doubling.
fn literal_format(value: &str) -> String {
    let mut out = String::new();
    let mut chars = value.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '#' {
            out.push(c);
            continue;
        }
        let mut count = 1;
        while chars.peek() == Some(&'#') {
            chars.next();
            count += 1;
        }
        out.extend(std::iter::repeat('#').take(count));
        if chars.peek() != Some(&'[') {
            out.extend(std::iter::repeat('#').take(count));
        }
    }
    // The tmux client treats a trailing semicolon as a command separator
    // even inside an argv word supplied directly through execve.
    if out.ends_with(';') {
        out.insert(out.len() - 1, '\\');
    }
    out
}

fn send_pane(ctx: &TmuxContext, pane: &str, args: &Value) -> Result<(), String> {
    if ctx
        .output(&["display-message", "-p", "-t", pane, "#{pane_in_mode}"])?
        .trim()
        == "1"
    {
        ctx.output(&["send-keys", "-X", "-t", pane, "cancel"])?;
    }
    if let Some(key) = args["key"].as_str() {
        ctx.output(&["send-keys", "-t", pane, &key_name(key)])?;
    } else {
        let buffer = format!("imux-send-{}", std::process::id());
        let mut command = ctx.command();
        command
            .args(["load-buffer", "-b", &buffer, "-"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null());
        let mut child = command.spawn().map_err(|e| e.to_string())?;
        use std::io::Write;
        child
            .stdin
            .take()
            .unwrap()
            .write_all(args["text"].as_str().unwrap_or("").as_bytes())
            .map_err(|e| e.to_string())?;
        if !child.wait().map_err(|e| e.to_string())?.success() {
            return Err("tmux could not buffer the text".into());
        }
        ctx.output(&["paste-buffer", "-d", "-b", &buffer, "-t", pane])?;
        if args["enter"].as_bool() == Some(true) {
            ctx.output(&["send-keys", "-t", pane, "Enter"])?;
        }
    }
    Ok(())
}

fn hydrate(ctx: &TmuxContext, pane: &str, lines: &Value) -> Result<(), String> {
    let Some(lines) = lines.as_array() else {
        return if lines.is_null() {
            Ok(())
        } else {
            Err("Startup commands must be literal lines".into())
        };
    };
    if lines.is_empty() {
        return Ok(());
    }
    for line in lines {
        let line = line
            .as_str()
            .ok_or("Startup commands must be literal lines")?;
        if line.contains(['\0', '\r', '\n']) {
            return Err("Startup commands must be separate literal lines".into());
        }
    }
    // Bracketed paste is enabled when interactive shells draw their prompt.
    // A bounded stable-shell fallback covers shells which do not enable it.
    let mut last = String::new();
    let mut stable = 0;
    for attempt in 0..40 {
        let state = ctx.output(&[
            "display-message",
            "-p",
            "-t",
            pane,
            "#{pane_current_command}\u{1f}#{bracket_paste_flag}",
        ])?;
        let (command, paste) = state
            .trim()
            .split_once('\u{1f}')
            .unwrap_or((state.trim(), ""));
        if paste == "1" {
            break;
        }
        if matches!(
            command,
            "sh" | "bash"
                | "zsh"
                | "fish"
                | "dash"
                | "ksh"
                | "mksh"
                | "tcsh"
                | "csh"
                | "nu"
                | "pwsh"
        ) {
            if command == last {
                stable += 1;
            } else {
                stable = 0;
                last = command.into();
            }
            if attempt >= 6 && stable >= 5 {
                break;
            }
        } else {
            stable = 0;
        }
        if attempt == 39 {
            return Err("The new session's shell is not ready for startup commands".into());
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    for line in lines
        .iter()
        .filter_map(Value::as_str)
        .filter(|l| !l.is_empty())
    {
        send_pane(ctx, pane, &json!({"text":line,"enter":true}))?;
    }
    Ok(())
}

pub(crate) fn run_job(descriptor: &Value, payload: &Value) -> Result<Value, String> {
    let socket = descriptor["socket"]
        .as_str()
        .ok_or("The scheduled tmux socket is missing")?;
    let pane = descriptor["target"]["pane_id"]
        .as_str()
        .filter(|s| s.starts_with('%') && s[1..].bytes().all(|b| b.is_ascii_digit()))
        .ok_or("The scheduled tmux pane is missing")?;
    let ctx = TmuxContext {
        socket: Some(socket.into()),
        client: None,
        block: Some(pane.into()),
    };
    let identity = ctx.output(&[
        "display-message",
        "-p",
        "#{pid}\u{1f}#{socket_path}\u{1f}#{start_time}",
    ])?;
    let identity: Vec<_> = identity.trim().split('\u{1f}').collect();
    if identity.len() != 3 || identity[2].is_empty() {
        return Err("tmux did not report its server identity".into());
    }
    if descriptor["guard"]["pid"].as_str() != Some(identity[0])
        || identity[1] != socket
        || descriptor["guard"]["started"].as_str() != Some(identity[2])
    {
        return Err(
            "The tmux server restarted or changed; the scheduled command was skipped".into(),
        );
    }
    if ctx
        .output(&["display-message", "-p", "-t", pane, "#{pane_id}"])?
        .trim()
        != pane
    {
        return Err("The scheduled tmux pane no longer exists".into());
    }
    send_pane(&ctx, pane, payload)?;
    Ok(json!({"sent":1}))
}
pub(crate) fn action(
    ctx: &TmuxContext,
    op: &str,
    target: Option<&Target>,
    args: &Value,
) -> Result<Value, String> {
    if op == "health" {
        let identity = ctx.output(&[
            "display-message",
            "-p",
            "Server #{pid} · #{version} · #{socket_path}",
        ])?;
        let clients = ctx.output(&["list-clients", "-F", "#{client_name}"])?;
        return Ok(
            json!({"lines":[format!("OK tmux {}", identity.trim()),format!("OK {} connected clients",clients.lines().count()),"OK native-ID actions, guarded scheduled sends, client detach and cross-session swaps"]}),
        );
    }
    let snapshot = tmux_backend::collect(ctx)?;
    if let Some(t) = target {
        validate(&snapshot, t)?;
    }
    if op == "create" {
        let name = args["name"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or("Enter a name")?;
        if name.chars().any(char::is_control) {
            return Err("Names cannot contain control characters".into());
        }
        let format = "#{session_id}\u{1f}#{window_id}\u{1f}#{pane_id}";
        let window = args["kind"].as_str() == Some("window");
        if !window {
            if let Some(existing) = snapshot.sessions.iter().find(|s| s.name == name) {
                return Ok(json!({"target":crate::interactive::target_json(&existing.target)}));
            }
        }
        let mut cmd = vec![
            if window { "new-window" } else { "new-session" }.into(),
            "-d".into(),
            "-P".into(),
            "-F".into(),
            format.into(),
        ];
        if window {
            cmd.extend([
                "-t".into(),
                ids(target.ok_or("Select a parent session")?)?.0.into(),
                "-n".into(),
                literal_format(name),
            ]);
        } else {
            cmd.extend(["-s".into(), literal_format(name)]);
        }
        if let Some(cwd) = args["cwd"].as_str().filter(|s| !s.is_empty()) {
            cmd.extend(["-c".into(), literal_format(cwd)]);
        }
        let result = created(&run(ctx, cmd)?)?;
        if !window {
            if let Some(pane) = result["target"]["pane_id"].as_str() {
                hydrate(ctx, pane, &args["startup_lines"])?;
            }
        }
        return Ok(result);
    }
    let target = target.ok_or("Select a target")?;
    let (sid, wid, pid) = ids(target)?;
    let session_key = snapshot
        .sessions
        .iter()
        .find(|s| ids(&s.target).map_or(false, |(id, _, _)| id == sid))
        .map(|s| s.key.as_str())
        .ok_or("The selected session no longer exists")?;
    let window_key = wid
        .and_then(|id| {
            snapshot.windows.iter().find(|w| {
                ids(&w.target).map_or(false, |(session, window, _)| {
                    session == sid && window == Some(id)
                })
            })
        })
        .map(|w| w.key.as_str());
    let qualified = wid.map(|wid| format!("{sid}:{wid}"));
    let native = pid.or(qualified.as_deref()).unwrap_or(sid);
    match op {
        "schedule-target" => {
            let p = pane(&snapshot, target)?;
            let (session, window, pane_id) = ids(&p)?;
            let identity = ctx.output(&[
                "display-message",
                "-p",
                "#{pid}\u{1f}#{socket_path}\u{1f}#{start_time}",
            ])?;
            let identity: Vec<_> = identity.trim().split('\u{1f}').collect();
            if identity.len() != 3 || identity[2].is_empty() {
                return Err("tmux did not report its server identity".into());
            }
            return Ok(
                json!({"backend":"tmux","socket":identity[1],"guard":{"pid":identity[0],"started":identity[2]},
                "target":{"session_id":session,"window_id":window,"pane_id":pane_id},"label":pane_id}),
            );
        }
        "rename" => {
            let name = args["name"]
                .as_str()
                .filter(|s| !s.is_empty())
                .ok_or("Enter a name")?;
            if name.chars().any(char::is_control) {
                return Err("Names cannot contain control characters".into());
            }
            if pid.is_some() {
                ctx.output(&["select-pane", "-t", native, "-T", &literal_format(name)])?;
            } else {
                ctx.output(&[
                    if wid.is_some() {
                        "rename-window"
                    } else {
                        "rename-session"
                    },
                    "-t",
                    native,
                    "--",
                    &literal_format(name),
                ])?;
            }
        }
        "close" => {
            let closes_session = wid.is_none()
                || snapshot
                    .windows
                    .iter()
                    .filter(|w| w.session_key == session_key)
                    .count()
                    == 1
                    && (pid.is_none()
                        || snapshot
                            .panes
                            .iter()
                            .filter(|p| p.session_key == session_key)
                            .count()
                            == 1);
            if closes_session {
                if let Some(other) = snapshot
                    .sessions
                    .iter()
                    .filter(|s| s.key != session_key)
                    .max_by_key(|s| s.last)
                {
                    let other_id = ids(&other.target)?.0;
                    let clients =
                        ctx.output(&["list-clients", "-F", "#{client_name}\u{1f}#{session_id}"])?;
                    for line in clients.lines() {
                        if let Some((client, session)) = line.split_once('\u{1f}') {
                            if session == sid {
                                ctx.output(&["switch-client", "-c", client, "-t", other_id])?;
                            }
                        }
                    }
                }
            }
            ctx.output(&[
                if pid.is_some() {
                    "kill-pane"
                } else if wid.is_some() {
                    "kill-window"
                } else {
                    "kill-session"
                },
                "-t",
                native,
            ])?;
        }
        "zoom" => {
            let p = pane(&snapshot, target)?;
            let (_, _, p) = ids(&p)?;
            ctx.output(&["resize-pane", "-Z", "-t", p.unwrap()])?;
        }
        "swap" => {
            let other = crate::interactive::decode_target(&args["other"], "tmux")?;
            validate(&snapshot, &other)?;
            let (other_sid, ow, op) = ids(&other)?;
            if pid.is_some() && op.is_some() {
                ctx.output(&["swap-pane", "-d", "-s", op.unwrap(), "-t", pid.unwrap()])?;
            } else if wid.is_some() && ow.is_some() {
                ctx.output(&[
                    "swap-window",
                    "-d",
                    "-s",
                    &format!("{other_sid}:{}", ow.unwrap()),
                    "-t",
                    qualified.as_deref().unwrap(),
                ])?;
            } else {
                return Err("Choose two windows or two panes to swap".into());
            }
        }
        "split" => {
            let p = pane(&snapshot, target)?;
            let (_, _, p) = ids(&p)?;
            let direction = if args["direction"].as_str() == Some("down") {
                "-v"
            } else {
                "-h"
            };
            return created(&ctx.output(&[
                "split-window",
                "-d",
                direction,
                "-t",
                p.unwrap(),
                "-P",
                "-F",
                "#{session_id}\u{1f}#{window_id}\u{1f}#{pane_id}",
            ])?);
        }
        "preview" => {
            let p = pane(&snapshot, target)?;
            let (_, _, p) = ids(&p)?;
            let lines = args["lines"]
                .as_u64()
                .unwrap_or(30)
                .clamp(1, 2000)
                .to_string();
            return Ok(
                json!({"text":ctx.output(&["capture-pane","-p","-e","-t",p.unwrap(),"-S",&format!("-{lines}")])?}),
            );
        }
        "send" => {
            let panes: Vec<_> = snapshot
                .panes
                .iter()
                .filter(|p| {
                    p.session_key == session_key
                        && window_key.map_or(true, |w| p.window_key == w)
                        && pid.map_or(true, |id| {
                            ids(&p.target).map_or(false, |(_, _, p)| p == Some(id))
                        })
                })
                .collect();
            let mut sent = std::collections::HashSet::new();
            for pane in panes {
                let pane_id = ids(&pane.target)?
                    .2
                    .ok_or("Pane target lost its native ID")?;
                if !sent.insert(pane_id) {
                    continue;
                }
                send_pane(ctx, pane_id, args)?;
            }
        }
        "detach" => {
            ctx.output(&["detach-client", "-s", sid])?;
        }
        _ => return Err(format!("Unsupported tmux action: {op}")),
    }
    Ok(json!({}))
}
