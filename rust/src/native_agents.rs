//! Agent selection uses the renderer's state rules, never fuzzy label matches.
use crate::agent;
use crate::model::{Row, Snapshot, Target};
use crate::palette::Palette;
use std::collections::{HashMap, HashSet};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone)]
pub(crate) struct Agent {
    pub key: String,
    pub target: Target,
    pub name: String,
    pub state: String,
    pub since: i64,
    pub command: String,
    pub location: String,
}

pub(crate) fn states(value: &str) -> Result<Vec<String>, String> {
    let mut result = Vec::new();
    if value.is_empty() {
        return Ok(result);
    }
    for state in value.split(',') {
        if !matches!(
            state,
            "approve" | "input" | "error" | "done" | "working" | "idle"
        ) {
            return Err(format!(
                "Unknown agent state {state:?}; use approve,input,error,done,working,idle"
            ));
        }
        if !result.iter().any(|s| s == state) {
            result.push(state.into());
        }
    }
    Ok(result)
}

fn priority(state: &str) -> u8 {
    match state {
        "approve" => 0,
        "input" => 1,
        "error" => 2,
        "done" => 3,
        "working" => 4,
        "idle" => 5,
        _ => 6,
    }
}

pub(crate) fn plain(text: &str) -> String {
    let mut output = String::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            for next in chars.by_ref() {
                if ('@'..='~').contains(&next) && next != '[' {
                    break;
                }
            }
        } else if c.is_control()
            || matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{2028}'|'\u{2029}'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}')
        {
            output.push(' ')
        } else {
            output.push(c)
        }
    }
    output.trim().into()
}

pub(crate) fn collect(snapshot: &Snapshot, wanted: &[String]) -> Vec<Agent> {
    let config =
        crate::native_config::agent_config(&snapshot.current.host, &snapshot.current.host_short);
    let palette = Palette::from_env();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let mut seen = HashSet::new();
    let mut resolver = None;
    let mut result = Vec::new();
    let mut sessions = HashMap::with_capacity(snapshot.sessions.len());
    for session in &snapshot.sessions {
        sessions
            .entry(session.key.as_str())
            .or_insert(session.name.as_str());
    }
    let mut windows = HashMap::with_capacity(snapshot.windows.len());
    for window in &snapshot.windows {
        windows
            .entry((window.session_key.as_str(), window.key.as_str()))
            .or_insert(window.ordinal.as_str());
    }
    for pane in &snapshot.panes {
        let physical = if pane.agent_id.is_empty() {
            &pane.key
        } else {
            &pane.agent_id
        };
        if !seen.insert(physical.clone()) {
            continue;
        }
        let metadata = snapshot.pane_metadata.get(&pane.key);
        let raw = if let Some(command) = metadata
            .map(|m| m.command_line.as_str())
            .filter(|s| !s.is_empty())
        {
            command.to_owned()
        } else if metadata.map_or(false, |m| m.local)
            && pane.pid > 0
            && crate::env_text("INTERDIMUX_SHOW_FULL_COMMAND") != "off"
        {
            resolver
                .get_or_insert_with(crate::proc::Resolver::new)
                .full_command(pane.pid, &pane.cmd)
        } else {
            pane.cmd.clone()
        };
        if crate::proc::is_idle_shell(&raw) {
            continue;
        }
        let known = agent::agent_of(&raw, &config);
        let published = snapshot
            .registry
            .get(&pane.agent_id)
            .filter(|r| r.sid.is_empty() || r.sid == pane.pid.to_string());
        let (_, option_description) =
            crate::titles::apply_options(&config.rules, &config.state_opts, &pane.opts);
        let (command, state) = agent::native_command_field(
            &raw,
            pane.pid,
            &pane.agent_id,
            &pane.title,
            &pane.opts,
            &config,
            &snapshot.registry,
            &palette,
            now,
            agent::NativeTitle {
                current: metadata.map_or(false, |m| m.current_title),
                reported: metadata.map_or(false, |m| m.reported_title),
                alternate: metadata.and_then(|m| m.alternate_title.as_deref()),
            },
        );
        if known.is_none()
            && state.is_empty()
            && !(config.state && published.is_some())
            && option_description.is_empty()
        {
            continue;
        }
        if !wanted.is_empty() && !wanted.iter().any(|s| s == &state) {
            continue;
        }
        let since = published
            .filter(|r| config.state && r.word == state && r.since > 0)
            .map_or(0, |r| r.since);
        let session = sessions
            .get(pane.session_key.as_str())
            .copied()
            .unwrap_or("");
        let window = windows
            .get(&(pane.session_key.as_str(), pane.window_key.as_str()))
            .copied()
            .unwrap_or("");
        result.push(Agent {
            key: pane.key.clone(),
            target: pane.target.clone(),
            name: plain(&known.map(|(n, _)| n).unwrap_or_else(|| {
                raw.split_whitespace()
                    .next()
                    .unwrap_or("")
                    .rsplit('/')
                    .next()
                    .unwrap_or("")
                    .into()
            })),
            state,
            since,
            command: plain(&command),
            location: plain(&format!("{session}:{window}.{}", pane.ordinal)),
        });
    }
    result.sort_by_key(|a| {
        (
            priority(&a.state),
            if a.since > 0 { a.since } else { i64::MAX },
        )
    });
    result
}

pub(crate) fn next<'a>(agents: &'a [Agent], current: &str) -> Option<&'a Agent> {
    let index = agents
        .iter()
        .position(|a| a.key == current)
        .map_or(0, |i| (i + 1) % agents.len().max(1));
    agents.get(index)
}

pub(crate) fn mark(state: &str) -> &'static str {
    match state {
        "approve" => "!",
        "input" => "?",
        "error" => "×",
        "done" => "✓",
        "working" => "~",
        "idle" => "·",
        _ => "@",
    }
}

pub(crate) fn query(wanted: &[String]) -> String {
    let all = [
        "approve", "input", "error", "done", "working", "idle", "unknown",
    ];
    let selected: Vec<&str> = if wanted.is_empty() {
        all.to_vec()
    } else {
        wanted.iter().map(String::as_str).collect()
    };
    selected
        .iter()
        .map(|s| format!("^{}", mark(s)))
        .collect::<Vec<_>>()
        .join(" | ")
}

pub(crate) fn mark_rows(rows: &mut [Row], agents: &[Agent]) {
    let mut markers = HashMap::with_capacity(agents.len());
    for agent in agents {
        markers
            .entry(&agent.target)
            .or_insert_with(|| mark(&agent.state));
    }
    for row in rows {
        let marker = markers.get(&row.target).copied().unwrap_or(" ");
        row.identity = format!("{marker} {}", row.identity);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Pane;
    fn fixture() -> Snapshot {
        let mut s = Snapshot::default();
        for (id, cmd, state, since) in [
            ("one", "codex", "approve", 30),
            ("two", "claude", "approve", 10),
            ("three", "cat", "input", 5),
            ("stale", "sleep", "approve", 1),
        ] {
            s.panes.push(Pane {
                key: id.into(),
                session_key: "s".into(),
                window_key: "w".into(),
                ordinal: "1".into(),
                name: format!("{id} input approval"),
                active: false,
                cmd: cmd.into(),
                path: String::new(),
                pid: 12,
                agent_id: id.into(),
                title: String::new(),
                opts: String::new(),
                target: Target::Rex {
                    session_id: "s".into(),
                    window_id: Some("w".into()),
                    block_id: Some(id.into()),
                },
            });
            s.registry.insert(
                id.into(),
                agent::Record {
                    sid: if id == "stale" { "99" } else { "12" }.into(),
                    word: state.into(),
                    since,
                },
            );
        }
        s
    }
    #[test]
    fn exact_states_not_labels_and_urgency_age_order() {
        let s = fixture();
        let a = collect(&s, &states("approve,input").unwrap());
        assert_eq!(
            a.iter().map(|a| a.key.as_str()).collect::<Vec<_>>(),
            ["two", "one", "three"]
        );
        assert!(!a.iter().any(|a| a.key == "stale"));
    }
    #[test]
    fn next_wraps_each_agent_instead_of_bouncing() {
        let a = collect(&fixture(), &states("approve,input").unwrap());
        assert_eq!(next(&a, "two").unwrap().key, "one");
        assert_eq!(next(&a, "one").unwrap().key, "three");
        assert_eq!(next(&a, "three").unwrap().key, "two");
        assert_eq!(next(&a, "elsewhere").unwrap().key, "two");
        assert!(next(&[], "x").is_none());
    }
    #[test]
    fn bad_states_are_rejected() {
        assert!(states("approve,bogus").is_err());
        assert_eq!(
            states("approve,approve,input").unwrap(),
            ["approve", "input"]
        );
    }

    #[test]
    fn locations_keep_linked_window_ids_scoped_to_their_session() {
        use crate::model::{Session, Window};
        let mut snapshot = fixture();
        for (key, name, ordinal) in [("s", "Original", "1"), ("other", "Other", "7")] {
            snapshot.sessions.push(Session {
                key: key.into(),
                name: name.into(),
                window_count: "1".into(),
                attached: false,
                last: 0,
                path: String::new(),
                target: Target::Rex {
                    session_id: key.into(),
                    window_id: None,
                    block_id: None,
                },
            });
            snapshot.windows.push(Window {
                key: "w".into(),
                session_key: key.into(),
                ordinal: ordinal.into(),
                name: "shared".into(),
                active: true,
                cmd: String::new(),
                path: String::new(),
                pane_count: 1,
                pid: 0,
                zoomed: false,
                bell: false,
                activity: false,
                target: Target::Rex {
                    session_id: key.into(),
                    window_id: Some("w".into()),
                    block_id: None,
                },
            });
        }
        snapshot.panes[1].session_key = "other".into();
        let agents = collect(&snapshot, &[]);
        assert_eq!(
            agents.iter().find(|a| a.key == "one").unwrap().location,
            "Original:1.1"
        );
        assert_eq!(
            agents.iter().find(|a| a.key == "two").unwrap().location,
            "Other:7.1"
        );
    }

    #[test]
    fn row_markers_use_full_targets_and_leave_parent_rows_unmarked() {
        let agents = collect(&fixture(), &[]);
        let mut rows = vec![
            Row {
                identity: "duplicate".into(),
                context: String::new(),
                command: String::new(),
                target: agents[0].target.clone(),
            },
            Row {
                identity: "duplicate".into(),
                context: String::new(),
                command: String::new(),
                target: agents[2].target.clone(),
            },
            Row {
                identity: "parent".into(),
                context: String::new(),
                command: String::new(),
                target: Target::Rex {
                    session_id: "s".into(),
                    window_id: Some("w".into()),
                    block_id: None,
                },
            },
        ];
        mark_rows(&mut rows, &agents);
        assert_eq!(
            rows.iter()
                .map(|row| row.identity.as_str())
                .collect::<Vec<_>>(),
            ["! duplicate", "? duplicate", "  parent"]
        );
    }
}
