//! Native tmux collection/activation for the shared navigator.
use std::collections::{HashMap, HashSet};
use std::process::Command;

use crate::model::{Current, Pane, Session, Snapshot, Target, Window};

#[derive(Debug, Default)]
pub(crate) struct TmuxContext {
    pub client: Option<String>,
    pub block: Option<String>,
    pub socket: Option<String>,
}

impl TmuxContext {
    pub(crate) fn command(&self) -> Command {
        let mut cmd = Command::new("tmux");
        if let Some(socket) = &self.socket {
            cmd.args(["-S", socket]);
        }
        cmd
    }

    pub(crate) fn output(&self, args: &[&str]) -> Result<String, String> {
        let out = self
            .command()
            .args(args)
            .output()
            .map_err(|e| format!("tmux: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "tmux: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
}

// Escape before tmux emits any delimiter. A literal escape prefix is escaped
// first, so user text such as "~0A" cannot become a newline when decoded.
fn wire_field(value: &str) -> String {
    format!("#{{s/~/~7E/;s/\n/~0A/;s/\r/~0D/;s/\t/~09/;s/\u{1d}/~1D/;s/\u{1e}/~1E/;s/\u{1f}/~1F/:{value}}}")
}

fn wire_record(values: &[&str]) -> String {
    values
        .iter()
        .map(|value| wire_field(value))
        .collect::<Vec<_>>()
        .join("\u{1f}")
}

pub(crate) fn collect(ctx: &TmuxContext) -> Result<Snapshot, String> {
    let agent_config = crate::native_config::agent_config("", "");
    let state_options = crate::native_config::option_format(&agent_config);
    let sf = wire_record(&[
        "session_id",
        "session_name",
        "#{?session_last_attached,#{session_last_attached},#{session_activity}}",
        "session_windows",
        "session_attached",
        "session_path",
    ]);
    let wf = wire_record(&[
        "session_id",
        "window_id",
        "window_index",
        "window_name",
        "window_active",
        "pane_current_command",
        "pane_current_path",
        "window_panes",
        "pane_pid",
        "#{window_zoomed_flag}#{window_bell_flag}#{window_activity_flag}",
    ]);
    let pf = wire_record(&[
        "session_id",
        "window_id",
        "pane_id",
        "window_index",
        "pane_index",
        "pane_active",
        "pane_current_command",
        "pane_current_path",
        "pane_pid",
        "window_panes",
        "pane_title",
        &state_options,
    ]);
    let cf = wire_record(&[
        "session_id",
        "window_index",
        "pane_index",
        "host",
        "host_short",
    ]);
    let r = "\u{1e}";
    let mut cmd = ctx.command();
    cmd.args([
        "list-sessions",
        "-F",
        &sf,
        ";",
        "display-message",
        "-p",
        r,
        ";",
        "list-windows",
        "-a",
        "-F",
        &wf,
        ";",
        "display-message",
        "-p",
        r,
        ";",
        "list-panes",
        "-a",
        "-F",
        &pf,
        ";",
        "display-message",
        "-p",
        r,
        ";",
        "display-message",
        "-p",
    ]);
    if let Some(client) = &ctx.client {
        cmd.args(["-t", &format!("={client}:")]);
    } else if let Some(block) = &ctx.block {
        cmd.args(["-t", block]);
    }
    cmd.arg(cf).args([";", "display-message", "-p", r]);
    let out = cmd.output().map_err(|e| format!("tmux: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "tmux snapshot: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let mut snapshot = parse_snapshot(&out.stdout)?;
    let home = std::env::var("HOME").unwrap_or_default();
    for pane in &snapshot.panes {
        let metadata = snapshot.pane_metadata.entry(pane.key.clone()).or_default();
        metadata.local = true;
        metadata.home.clone_from(&home);
    }
    crate::native_config::merge_registry(&mut snapshot);
    Ok(snapshot)
}

fn invalid_snapshot() -> String {
    "tmux returned an invalid or incomplete snapshot; refresh the picker (tmux 3.6 or newer is required)".into()
}

fn decode_field(encoded: &[u8]) -> Result<String, String> {
    let mut bytes = Vec::with_capacity(encoded.len());
    let mut i = 0;
    while i < encoded.len() {
        if encoded[i] == b'~' {
            let value = match encoded.get(i + 1..i + 3) {
                Some(b"7E") => b'~',
                Some(b"0A") => b'\n',
                Some(b"0D") => b'\r',
                Some(b"09") => b'\t',
                Some(b"1D") => 0x1d,
                Some(b"1E") => 0x1e,
                Some(b"1F") => 0x1f,
                _ => return Err(invalid_snapshot()),
            };
            bytes.push(value);
            i += 3;
        } else {
            // Structural controls are never valid inside an encoded field.
            if matches!(encoded[i], b'\n' | b'\r' | b'\t' | 0x1d | 0x1e | 0x1f) {
                return Err(invalid_snapshot());
            }
            bytes.push(encoded[i]);
            i += 1;
        }
    }
    // Unix paths need not be UTF-8. Invalid bytes degrade display text without
    // ever participating in record framing or native target selection.
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn records(section: &[u8], count: usize) -> Result<Vec<Vec<String>>, String> {
    section
        .split(|b| *b == b'\n')
        .filter(|line| !line.is_empty())
        .map(|line| {
            let fields = line
                .split(|b| *b == 0x1f)
                .map(decode_field)
                .collect::<Result<Vec<_>, _>>()?;
            if fields.len() != count {
                return Err(invalid_snapshot());
            }
            Ok(fields)
        })
        .collect()
}

fn native_id(value: &str, prefix: char) -> Result<(), String> {
    if value.starts_with(prefix)
        && value.len() > 1
        && value[1..].bytes().all(|b| b.is_ascii_digit())
    {
        Ok(())
    } else {
        Err(invalid_snapshot())
    }
}

fn number<T: std::str::FromStr>(value: &str) -> Result<T, String> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err(invalid_snapshot());
    }
    value.parse().map_err(|_| invalid_snapshot())
}

fn flag(value: &str) -> Result<bool, String> {
    match value {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => Err(invalid_snapshot()),
    }
}

fn window_key(session: &str, index: &str) -> String {
    format!("{session}\u{1f}{index}")
}
fn pane_key(window: &str, index: &str) -> String {
    format!("{window}\u{1f}{index}")
}

fn parse_snapshot(raw: &[u8]) -> Result<Snapshot, String> {
    let sections: Vec<_> = raw.split(|b| *b == 0x1e).collect();
    if sections.len() != 5 || sections[4].iter().any(|b| *b != b'\n') {
        return Err(invalid_snapshot());
    }
    let mut snapshot = Snapshot::default();
    let mut sessions = HashSet::new();
    for f in records(sections[0], 6)? {
        native_id(&f[0], '$')?;
        if f[1].is_empty() || !sessions.insert(f[0].clone()) {
            return Err(invalid_snapshot());
        }
        let last: i64 = number(&f[2])?;
        let _: usize = number(&f[3])?;
        let attached: usize = number(&f[4])?;
        snapshot.sessions.push(Session {
            key: f[0].clone(),
            name: f[1].clone(),
            last,
            window_count: f[3].clone(),
            attached: attached != 0,
            path: f[5].clone(),
            target: Target::TmuxNative {
                session_id: f[0].clone(),
                window_id: None,
                pane_id: None,
            },
        });
    }
    let mut windows = HashMap::new();
    for f in records(sections[1], 10)? {
        native_id(&f[0], '$')?;
        native_id(&f[1], '@')?;
        let _: u32 = number(&f[2])?;
        let key = window_key(&f[0], &f[2]);
        if !sessions.contains(&f[0]) || windows.insert(key.clone(), f[1].clone()).is_some() {
            return Err(invalid_snapshot());
        }
        let flags = f[9].as_bytes();
        if flags.len() != 3 || flags.iter().any(|b| !matches!(b, b'0' | b'1')) {
            return Err(invalid_snapshot());
        }
        snapshot.windows.push(Window {
            key,
            session_key: f[0].clone(),
            ordinal: f[2].clone(),
            name: f[3].clone(),
            active: flag(&f[4])?,
            cmd: f[5].clone(),
            path: f[6].clone(),
            pane_count: number(&f[7])?,
            pid: number(&f[8])?,
            zoomed: flags[0] == b'1',
            bell: flags[1] == b'1',
            activity: flags[2] == b'1',
            target: Target::TmuxNative {
                session_id: f[0].clone(),
                window_id: Some(f[1].clone()),
                pane_id: None,
            },
        });
    }
    let current = records(sections[3], 5)?;
    if current.len() != 1 {
        return Err(invalid_snapshot());
    }
    let f = &current[0];
    native_id(&f[0], '$')?;
    let _: u32 = number(&f[1])?;
    let _: u32 = number(&f[2])?;
    let current_window = window_key(&f[0], &f[1]);
    snapshot.current = Current {
        session_key: f[0].clone(),
        window_key: current_window.clone(),
        pane_key: pane_key(&current_window, &f[2]),
        host: f[3].clone(),
        host_short: f[4].clone(),
    };
    let mut panes = HashSet::new();
    let mut physical_panes = HashMap::new();
    for f in records(sections[2], 12)? {
        native_id(&f[0], '$')?;
        native_id(&f[1], '@')?;
        native_id(&f[2], '%')?;
        let _: u32 = number(&f[3])?;
        let _: u32 = number(&f[4])?;
        let window_key = window_key(&f[0], &f[3]);
        let key = pane_key(&window_key, &f[4]);
        if windows.get(&window_key) != Some(&f[1]) || !panes.insert(key.clone()) {
            return Err(invalid_snapshot());
        }
        // Linked windows repeat the same physical panes, but a physical pane
        // cannot simultaneously belong to a different window or pane index.
        let location = (f[1].clone(), f[4].clone());
        if physical_panes
            .insert(f[2].clone(), location.clone())
            .is_some_and(|old| old != location)
        {
            return Err(invalid_snapshot());
        }
        let _: usize = number(&f[9])?;
        let title = f[10].clone();
        snapshot.panes.push(Pane {
            key,
            session_key: f[0].clone(),
            window_key,
            ordinal: f[4].clone(),
            name: if title == snapshot.current.host || title == snapshot.current.host_short {
                String::new()
            } else {
                title.clone()
            },
            active: flag(&f[5])?,
            cmd: f[6].clone(),
            path: f[7].clone(),
            pid: number(&f[8])?,
            agent_id: f[2].clone(),
            title,
            opts: f[11].clone(),
            target: Target::TmuxNative {
                session_id: f[0].clone(),
                window_id: Some(f[1].clone()),
                pane_id: Some(f[2].clone()),
            },
        });
    }
    Ok(snapshot)
}

fn exact_id(list: &str, value: &str) -> Result<String, String> {
    list.lines()
        .find_map(|line| {
            let (id, label) = line.split_once('\u{1f}')?;
            (label == value).then(|| id.to_owned())
        })
        .ok_or_else(|| "selected tmux target no longer exists".into())
}

fn parse_spec(spec: &str) -> Result<(&str, &str, Option<&str>, Option<&str>), String> {
    let (kind, rest) = spec.split_once(':').ok_or("invalid tmux target")?;
    match kind {
        "S" => Ok((kind, rest, None, None)),
        "W" => {
            let (session, window) = rest.rsplit_once(':').ok_or("invalid tmux window")?;
            Ok((kind, session, Some(window), None))
        }
        "P" => {
            let (parent, pane) = rest.rsplit_once(':').ok_or("invalid tmux pane")?;
            let (session, window) = parent.rsplit_once(':').ok_or("invalid tmux pane window")?;
            Ok((kind, session, Some(window), Some(pane)))
        }
        _ => Err("unsupported target in switching-only picker".into()),
    }
}

pub(crate) fn activate(ctx: &TmuxContext, target: &Target) -> Result<(), String> {
    let target = match target {
        Target::TmuxLegacy { spec } => resolve_legacy(ctx, spec)?,
        Target::TmuxNative { .. } => target.clone(),
        _ => return Err("this target does not belong to tmux".into()),
    };
    let Target::TmuxNative {
        session_id: sid,
        window_id: wid,
        pane_id: pid,
    } = target
    else {
        unreachable!("only native tmux targets reach activation")
    };
    require_id(
        &ctx.output(&["list-sessions", "-F", "#{session_id}"])?,
        &sid,
    )?;
    if let Some(wid) = &wid {
        require_id(
            &ctx.output(&["list-windows", "-t", &sid, "-F", "#{window_id}"])?,
            wid,
        )?;
        if let Some(pid) = &pid {
            require_id(
                &ctx.output(&[
                    "list-panes",
                    "-t",
                    &format!("{sid}:{wid}"),
                    "-F",
                    "#{pane_id}",
                ])?,
                pid,
            )?;
        }
    } else if pid.is_some() {
        return Err("a tmux pane target requires its containing window".into());
    }
    // Validate the initiating client before changing any shared session focus.
    let clients = ctx.output(&["list-clients", "-F", "#{client_name}"])?;
    let clients: Vec<_> = clients.lines().filter(|s| !s.is_empty()).collect();
    let client = if let Some(client) = &ctx.client {
        if !clients.contains(&client.as_str()) {
            return Err("the tmux client that opened this picker is no longer attached".into());
        }
        client.clone()
    } else {
        if clients.len() != 1 {
            return Err("pass --client to select the tmux client that opened this picker".into());
        }
        clients[0].to_owned()
    };
    let mut cmd = ctx.command();
    if let Some(wid) = &wid {
        cmd.args(["select-window", "-t", &format!("{sid}:{wid}"), ";"]);
        if let Some(pid) = &pid {
            cmd.args(["select-pane", "-t", &format!("{sid}:{wid}.{pid}"), ";"]);
        }
    }
    let out = cmd
        .args(["switch-client", "-c", &client, "-t", &sid])
        .output()
        .map_err(|e| format!("tmux activation: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "tmux activation: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(())
}

fn require_id(list: &str, wanted: &str) -> Result<(), String> {
    if list.lines().any(|id| id == wanted) {
        Ok(())
    } else {
        Err("selected tmux target no longer exists in its original location".into())
    }
}

fn resolve_legacy(ctx: &TmuxContext, spec: &str) -> Result<Target, String> {
    let (_, session, window, pane) = parse_spec(spec)?;
    let sessions = ctx.output(&["list-sessions", "-F", "#{session_id}\u{1f}#{session_name}"])?;
    let sid = exact_id(&sessions, session)?;
    let wid = if let Some(index) = window {
        let windows = ctx.output(&[
            "list-windows",
            "-t",
            &sid,
            "-F",
            "#{window_id}\u{1f}#{window_index}",
        ])?;
        Some(exact_id(&windows, index)?)
    } else {
        None
    };
    let pid = if let (Some(wid), Some(index)) = (&wid, pane) {
        let panes = ctx.output(&[
            "list-panes",
            "-t",
            &format!("{sid}:{wid}"),
            "-F",
            "#{pane_id}\u{1f}#{pane_index}",
        ])?;
        Some(exact_id(&panes, index)?)
    } else {
        None
    };
    Ok(Target::TmuxNative {
        session_id: sid,
        window_id: wid,
        pane_id: pid,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn names_and_indices_are_resolved_exactly() {
        assert_eq!(
            exact_id("$1\u{1f}alpha\n$2\u{1f}alphabet\n", "alpha").unwrap(),
            "$1"
        );
        assert!(exact_id("@1\u{1f}3rd\n", "3").is_err());
    }
    #[test]
    fn colons_in_session_names_are_not_target_delimiters() {
        assert_eq!(
            parse_spec("P:a:b:2:1").unwrap(),
            ("P", "a:b", Some("2"), Some("1"))
        );
        assert_eq!(parse_spec("S:a:b").unwrap(), ("S", "a:b", None, None));
    }

    fn valid_frame() -> Vec<u8> {
        concat!(
            "$0\x1ffirst\x1f0\x1f1\x1f0\x1f/work~0Apath\n\x1e\n",
            "$0\x1f@0\x1f0\x1ftab\x1f1\x1fsh\x1f/work~1Fpath\x1f1\x1f42\x1f000\n\x1e\n",
            "$0\x1f@0\x1f%0\x1f0\x1f0\x1f1\x1fsh\x1f/work~1Epath\x1f42\x1f1\x1ftitle~7E0A\x1f\n\x1e\n",
            "$0\x1f0\x1f0\x1fhost\x1fhost\n\x1e\n"
        ).as_bytes().to_vec()
    }

    #[test]
    fn framed_values_are_decoded_only_after_record_identity() {
        let snapshot = parse_snapshot(&valid_frame()).unwrap();
        assert_eq!(snapshot.sessions.len(), 1);
        assert_eq!(snapshot.windows.len(), 1);
        assert_eq!(snapshot.panes.len(), 1);
        assert_eq!(snapshot.sessions[0].path, "/work\npath");
        assert_eq!(snapshot.windows[0].path, "/work\x1fpath");
        assert_eq!(snapshot.panes[0].path, "/work\x1epath");
        assert_eq!(snapshot.panes[0].title, "title~0A");
        assert_eq!(snapshot.sessions[0].key, "$0");
        assert_eq!(snapshot.panes[0].key, snapshot.current.pane_key);
        assert!(matches!(&snapshot.panes[0].target, Target::TmuxNative {
            session_id, window_id: Some(window), pane_id: Some(pane)
        } if session_id == "$0" && window == "@0" && pane == "%0"));
        assert_eq!(
            decode_field(b"~09~0D~1D~7E~0A~1E~1F").unwrap(),
            "\t\r\x1d~\n\x1e\x1f"
        );
        assert_eq!(decode_field(b"invalid-\xff").unwrap(), "invalid-\u{fffd}");
    }

    #[test]
    fn malformed_or_duplicate_native_records_are_rejected() {
        let valid = String::from_utf8(valid_frame()).unwrap();
        for broken in [
            valid.replacen("$0", "not-an-id", 1),
            valid.replacen("@0", "%0", 1),
            valid.replacen("\x1f000\n", "\x1fé0\n", 1),
            valid.replacen("/work~0Apath", "/work\n$0\x1fforged", 1),
            valid.replacen("/work~0Apath", "/work~", 1),
            valid.replacen("/work~0Apath", "/work~ZZpath", 1),
            valid.replacen("/work~0Apath", "/work\x1epath", 1),
            valid.replacen("first", "first\x1fextra", 1),
            valid.replacen("\x1f42\x1f000", "\x1fnot-a-pid\x1f000", 1),
        ] {
            assert!(parse_snapshot(broken.as_bytes()).is_err(), "{broken:?}");
        }
        for section in 0..3 {
            let mut parts: Vec<_> = valid.split('\x1e').map(str::to_owned).collect();
            parts[section] = parts[section].repeat(2);
            assert!(parse_snapshot(parts.join("\x1e").as_bytes()).is_err());
        }
        let mut parts: Vec<_> = valid.split('\x1e').map(str::to_owned).collect();
        parts[1].push_str("$0\x1f@1\x1f1\x1fother\x1f0\x1fsh\x1f/tmp\x1f1\x1f42\x1f000\n");
        parts[2].push_str("$0\x1f@1\x1f%0\x1f1\x1f0\x1f1\x1fsh\x1f/tmp\x1f42\x1f1\x1ftitle\x1f\n");
        assert!(parse_snapshot(parts.join("\x1e").as_bytes()).is_err());
    }

    #[test]
    fn private_tmux_paths_cannot_inject_or_hide_native_targets() {
        use std::fs;
        use std::time::{SystemTime, UNIX_EPOCH};
        if Command::new("tmux").arg("-V").output().is_err() {
            return;
        }
        let root = std::env::temp_dir().join(format!(
            "imux-framing-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&root).unwrap();
        let root = fs::canonicalize(root).unwrap();
        let ctx = TmuxContext {
            socket: Some(root.join("socket").to_string_lossy().into_owned()),
            block: Some("%0".into()),
            ..Default::default()
        };
        struct Cleanup<'a>(&'a TmuxContext, std::path::PathBuf);
        impl Drop for Cleanup<'_> {
            fn drop(&mut self) {
                let _ = self.0.command().arg("kill-server").output();
                let _ = std::fs::remove_dir_all(&self.1);
            }
        }
        let _cleanup = Cleanup(&ctx, root.clone());
        ctx.output(&[
            "-f",
            "/dev/null",
            "new-session",
            "-d",
            "-s",
            "first",
            "exec /bin/sleep 300",
        ])
        .unwrap();
        ctx.output(&["set-option", "-g", "default-shell", "/bin/sh"])
            .unwrap();
        let names = [
            "lf\ncr\rtab\tgs\x1dus\x1frs\x1e~0A",
            "prefix\n$0\x1fINJECTED-SESSION\x1f0\x1f1\x1f0\x1fsafe",
            "prefix\n$0\x1f@0\x1ffirst\x1f9\x1fINJECTED-WINDOW\x1f0\x1fcat\x1fsafe",
        ];
        let mut paths = Vec::new();
        for (i, name) in names.iter().enumerate() {
            let path = root.join(name);
            fs::create_dir(&path).unwrap();
            let path = path.to_string_lossy().into_owned();
            ctx.output(&[
                "new-session",
                "-d",
                "-s",
                &format!("holder-{i}"),
                "-c",
                &path,
                "exec /bin/sleep 300",
            ])
            .unwrap();
            paths.push(path);
        }
        #[cfg(target_os = "linux")]
        {
            use std::os::unix::ffi::OsStrExt;
            let path = root.join(std::ffi::OsStr::from_bytes(b"invalid-\xff\n\x1f\x1e"));
            fs::create_dir(&path).unwrap();
            let out = ctx
                .command()
                .args(["new-session", "-d", "-s", "invalid-bytes", "-c"])
                .arg(&path)
                .arg("exec /bin/sleep 300")
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
            let snapshot = collect(&ctx).unwrap();
            let session = snapshot
                .sessions
                .iter()
                .find(|s| s.name == "invalid-bytes")
                .unwrap();
            assert!(session.path.ends_with("invalid-\u{fffd}\n\x1f\x1e"));
        }
        // Repeat the same physical window link: strict identity checks must
        // still allow tmux's legal repeated same-session winlinks.
        ctx.output(&["link-window", "-s", "$0:0", "-t", "$0:2"])
            .unwrap();
        let snapshot = collect(&ctx).unwrap();
        let expected_sessions = 4 + usize::from(cfg!(target_os = "linux"));
        assert_eq!(snapshot.sessions.len(), expected_sessions);
        assert_eq!(snapshot.windows.len(), expected_sessions + 1);
        assert_eq!(snapshot.panes.len(), expected_sessions + 1);
        assert!(!snapshot
            .sessions
            .iter()
            .any(|s| s.name == "INJECTED-SESSION"));
        assert!(!snapshot.windows.iter().any(|w| w.name == "INJECTED-WINDOW"));
        for (i, path) in paths.iter().enumerate() {
            let session = snapshot
                .sessions
                .iter()
                .find(|s| s.name == format!("holder-{i}"))
                .unwrap();
            assert_eq!(&session.path, path);
            assert_eq!(
                &snapshot
                    .windows
                    .iter()
                    .find(|w| w.session_key == session.key)
                    .unwrap()
                    .path,
                path
            );
            assert_eq!(
                &snapshot
                    .panes
                    .iter()
                    .find(|p| p.session_key == session.key)
                    .unwrap()
                    .path,
                path
            );
        }
        let target = &snapshot
            .sessions
            .iter()
            .find(|s| s.name == "first")
            .unwrap()
            .target;
        crate::tmux_actions::action(
            &ctx,
            "rename",
            Some(target),
            &serde_json::json!({"name":"actual-first"}),
        )
        .unwrap();
        assert_eq!(
            ctx.output(&["display-message", "-p", "-t", "$0", "#{session_name}"])
                .unwrap()
                .trim(),
            "actual-first"
        );
        assert_eq!(collect(&ctx).unwrap().sessions.len(), expected_sessions);
    }
}
