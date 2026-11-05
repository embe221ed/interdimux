//! Native tmux collection/activation for the shared, switching-only navigator.
use std::collections::HashMap;
use std::process::Command;

use crate::model::{Snapshot, Target};

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

pub(crate) fn collect(ctx: &TmuxContext) -> Result<Snapshot, String> {
    let agent_config = crate::native_config::agent_config("", "");
    let state_options = crate::native_config::option_format(&agent_config);
    let u = '\u{1f}';
    let r = "\u{1e}";
    let sf = format!("#{{session_id}}{u}#{{session_name}}{u}#{{?session_last_attached,#{{session_last_attached}},#{{session_activity}}}}{u}#{{session_windows}}{u}#{{?session_attached,attached,}}{u}#{{session_path}}");
    let wf = format!("#{{session_id}}{u}#{{window_id}}{u}#{{session_name}}{u}#{{window_index}}{u}#{{window_name}}{u}#{{window_active}}{u}#{{pane_current_command}}{u}#{{pane_current_path}}{u}#{{window_panes}}{u}#{{pane_pid}}{u}#{{window_zoomed_flag}}#{{window_bell_flag}}#{{window_activity_flag}}");
    let pf = format!("#{{session_id}}{u}#{{window_id}}{u}#{{pane_id}}{u}#{{session_name}}{u}#{{window_index}}{u}#{{pane_index}}{u}#{{pane_active}}{u}#{{pane_current_command}}{u}#{{pane_current_path}}{u}#{{pane_pid}}{u}#{{window_panes}}{u}#{{pane_id}}{u}#{{pane_title}}{u}{state_options}");
    let cf = format!("#S{u}#I{u}#P{u}#{{host}}{u}#{{host_short}}");
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
    let mut sections: Vec<String> = String::from_utf8_lossy(&out.stdout)
        .split('\u{1e}')
        .map(|s| s.trim_matches('\n').to_string())
        .collect();
    if sections.len() != 5 {
        return Err("tmux returned an invalid snapshot (tmux 3.6 or newer is required)".into());
    }
    // Prefixes are private to this collector; gather3 keeps its original wire
    // format. Capturing native identity now prevents a later index reuse or
    // renumbering from redirecting an accepted row to a different object.
    let mut targets = HashMap::new();
    for (index, kind, id_count) in [(0, "S", 1), (1, "W", 2), (2, "P", 3)] {
        sections[index] = strip_native_prefixes(&sections[index], kind, id_count, &mut targets);
    }
    let mut snapshot = crate::tmux_input::parse_sections(&sections);
    for target in snapshot
        .sessions
        .iter_mut()
        .map(|s| &mut s.target)
        .chain(snapshot.windows.iter_mut().map(|w| &mut w.target))
        .chain(snapshot.panes.iter_mut().map(|p| &mut p.target))
    {
        let native = match target {
            Target::TmuxLegacy { spec } => targets
                .remove(spec)
                .ok_or("tmux snapshot lost a target's native identity")?,
            _ => return Err("unexpected target in tmux snapshot".into()),
        };
        *target = native;
    }
    let home = std::env::var("HOME").unwrap_or_default();
    for pane in &snapshot.panes {
        snapshot
            .pane_metadata
            .entry(pane.key.clone())
            .or_default()
            .local = true;
        snapshot.pane_metadata.get_mut(&pane.key).unwrap().home = home.clone();
    }
    crate::native_config::merge_registry(&mut snapshot);
    Ok(snapshot)
}

fn strip_native_prefixes(
    raw: &str,
    kind: &str,
    id_count: usize,
    targets: &mut HashMap<String, Target>,
) -> String {
    let mut lines = Vec::new();
    for line in raw.lines() {
        let fields: Vec<_> = line.splitn(id_count + 1, '\u{1f}').collect();
        if fields.len() != id_count + 1 {
            continue;
        }
        let body = fields[id_count];
        let labels: Vec<_> = body.splitn(id_count + 1, '\u{1f}').collect();
        if labels.len() < id_count || labels[0].is_empty() {
            continue;
        }
        let mut spec = format!("{kind}:{}", labels[0]);
        if id_count > 1 {
            spec.push_str(&format!(":{}", labels[1]));
        }
        if id_count > 2 {
            spec.push_str(&format!(":{}", labels[2]));
        }
        targets.insert(
            spec,
            Target::TmuxNative {
                session_id: fields[0].into(),
                window_id: (id_count > 1).then(|| fields[1].into()),
                pane_id: (id_count > 2).then(|| fields[2].into()),
            },
        );
        lines.push(body);
    }
    lines.join("\n")
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
}
