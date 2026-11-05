//! Shared native navigator rows: measured tree, path/context, and command columns.
//!
//! Labels and available paths remain searchable in full. Optional git badges
//! and padding give way first on a narrow terminal; fzf clips the final viewport.

use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::agent;
use crate::git::GitCache;
use crate::model::{Pane, Row, Session, Snapshot, Target, Window};
use crate::palette::{Palette, BOLD, RST};
use crate::proc::Resolver;
use crate::text::{age_of, pad_to, tildify, truncate, width};
use crate::widths::CMD_MIN;

const PRIMARY: &str = "\x1b[38;2;212;190;152m";

/// Preserve readable Unicode, but never let a label change the terminal or TSV.
fn plain(value: &str) -> String {
    value
        .chars()
        .map(|c| match c {
            '\n' | '\r' | '\t' | '\0' | '\u{2028}' | '\u{2029}' => ' ',
            '\u{061c}'
            | '\u{200e}'
            | '\u{200f}'
            | '\u{202a}'..='\u{202e}'
            | '\u{2066}'..='\u{2069}' => ' ',
            c if c.is_control() => '?',
            c => c,
        })
        .collect::<String>()
        .trim()
        .to_owned()
}

fn session_name(session: &Session) -> String {
    let name = plain(&session.name);
    if name.is_empty() {
        "Untitled session".into()
    } else {
        name
    }
}

fn window_name(window: &Window) -> String {
    let name = plain(&window.name);
    if name.is_empty() {
        format!("Window {}", plain(&window.ordinal))
    } else {
        name
    }
}

fn pane_name(pane: &Pane) -> String {
    let name = plain(&pane.name);
    if !name.is_empty() {
        return name;
    }
    let command = plain(&pane.cmd);
    if !command.is_empty() {
        command
    } else {
        format!("Pane {}", plain(&pane.ordinal))
    }
}

fn numbered(ordinal: &str, name: &str, fallback_kind: &str) -> String {
    let ordinal = plain(ordinal);
    if ordinal.is_empty() || name == format!("{fallback_kind} {ordinal}") {
        name.into()
    } else {
        format!("{ordinal}: {name}")
    }
}

fn enabled(name: &str) -> bool {
    crate::env_text(name) != "off"
}

#[derive(Clone, Default)]
struct Facts {
    path: String,
    branch: String,
    command: String,
}

struct Enrichment<'a> {
    snapshot: &'a Snapshot,
    palette: Palette,
    resolver: Option<Resolver>,
    git: GitCache,
    config: agent::Config,
    cache: HashMap<String, Facts>,
    full: bool,
    branches: bool,
    now: i64,
}

impl<'a> Enrichment<'a> {
    fn new(snapshot: &'a Snapshot) -> Self {
        Self {
            snapshot,
            palette: Palette::from_env(),
            // Supplied argv, foreign panes and short-command mode never need
            // local process access. Avoid its self-test and buffers until a
            // local pane actually asks for full argv.
            resolver: None,
            git: GitCache::new(),
            config: crate::native_config::agent_config(
                &snapshot.current.host,
                &snapshot.current.host_short,
            ),
            cache: HashMap::new(),
            full: enabled("INTERDIMUX_SHOW_FULL_COMMAND"),
            branches: enabled("INTERDIMUX_SHOW_GIT_BRANCH"),
            now: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0),
        }
    }

    fn pane(&mut self, pane: &Pane) -> Facts {
        if let Some(facts) = self.cache.get(&pane.key) {
            return facts.clone();
        }
        let metadata = self.snapshot.pane_metadata.get(&pane.key);
        let local = metadata.map_or(false, |m| m.local);
        let raw = if !self.full {
            pane.cmd.clone()
        } else if let Some(command) = metadata
            .map(|m| m.command_line.as_str())
            .filter(|s| !s.trim().is_empty())
        {
            command.to_owned()
        } else if self.full && local && pane.pid > 0 {
            self.resolver
                .get_or_insert_with(Resolver::new)
                .full_command(pane.pid, &pane.cmd)
        } else {
            pane.cmd.clone()
        };
        let home = metadata.map(|m| m.home.as_str()).unwrap_or("");
        let path = plain(&tildify(&pane.path, home));
        let branch = if !self.branches {
            String::new()
        } else if let Some(branch) = metadata.and_then(|m| m.git_branch.as_deref()) {
            plain(branch)
        } else if local {
            plain(&self.git.branch(&pane.path))
        } else {
            String::new()
        };
        let mut command = agent::native_command_field(
            &plain(&raw),
            pane.pid,
            &pane.agent_id,
            &pane.title,
            &pane.opts,
            &self.config,
            &self.snapshot.registry,
            &self.palette,
            self.now,
            agent::NativeTitle {
                current: metadata.map_or(false, |m| m.current_title),
                reported: metadata.map_or(false, |m| m.reported_title),
                alternate: metadata.and_then(|m| m.alternate_title.as_deref()),
            },
        )
        .0;
        if self.config.state {
            if let Some(progress) = metadata
                .and_then(|m| m.program_status.as_ref())
                .and_then(|s| s.progress)
            {
                command = format!("{}[{progress}%]{RST} {command}", self.palette.bold_amber);
            }
        }
        let facts = Facts {
            path,
            branch,
            command,
        };
        self.cache.insert(pane.key.clone(), facts.clone());
        facts
    }

    fn window(&mut self, window: &Window, panes: &[&Pane]) -> Facts {
        if let Some(pane) = panes.iter().find(|p| p.active).or_else(|| panes.first()) {
            return self.pane(pane);
        }
        Facts {
            path: plain(&window.path),
            branch: String::new(),
            command: crate::format::format_command(&plain(&window.cmd), &self.palette).0,
        }
    }
}

#[derive(Clone, Copy, Default)]
struct Flags {
    zoomed: bool,
    bell: bool,
    activity: bool,
}
impl Flags {
    fn from_window(window: &Window) -> Self {
        Self {
            zoomed: window.zoomed,
            bell: window.bell,
            activity: window.activity,
        }
    }
    fn len(self) -> usize {
        self.zoomed as usize + self.bell as usize + self.activity as usize
    }
    fn render(self, palette: &Palette) -> String {
        let mut output = String::new();
        if self.zoomed {
            output.push_str(&format!("{}Z{RST}", palette.bold_amber));
        }
        if self.bell {
            output.push_str(&format!("{}!{RST}", palette.bold_red));
        }
        if self.activity {
            output.push_str(&format!("{}#{RST}", palette.dim_ssh));
        }
        output
    }
}

struct Draft {
    identity: String,
    cells: usize,
    facts: Facts,
    flags: Flags,
    session_stats: Option<String>,
    target: Target,
}

fn identity(
    prefix: &str,
    parent: &str,
    name: &str,
    current: bool,
    bold: bool,
    palette: &Palette,
) -> (String, usize) {
    let marker = if current {
        format!("{}●{RST}", palette.marker)
    } else {
        " ".into()
    };
    let parent = if parent.is_empty() {
        String::new()
    } else {
        format!(" · {parent}")
    };
    let weight = if bold { BOLD } else { "" };
    (
        format!(
            "{marker} {}{prefix}{RST}{weight}{PRIMARY}{name}{RST}{}{parent}{RST}",
            palette.dim_tree, palette.dim_tree
        ),
        2 + width(prefix) + width(&parent) + width(name),
    )
}

struct Layout {
    identity: usize,
    path: usize,
    flags: usize,
    branch: usize,
    context: usize,
}
impl Layout {
    fn measure(rows: &[Draft], cols: usize) -> Self {
        let identity_max = rows.iter().map(|r| r.cells).max().unwrap_or(0);
        let path_max = rows.iter().map(|r| width(&r.facts.path)).max().unwrap_or(0);
        let flags = rows.iter().map(|r| r.flags.len()).max().unwrap_or(0);
        let mut branch = rows
            .iter()
            .map(|r| width(&r.facts.branch))
            .max()
            .unwrap_or(0)
            .min(18);
        let command = if rows.iter().any(|r| !r.facts.command.is_empty()) {
            CMD_MIN.min(cols / 3)
        } else {
            0
        }
        .max(
            rows.iter()
                .filter_map(|r| r.session_stats.as_ref())
                .map(|s| width(s))
                .max()
                .unwrap_or(0),
        );
        let mut identity = identity_max;
        let mut path = path_max;
        let context_width = |path: usize, branch: usize| {
            if path == 0 && flags == 0 && branch == 0 {
                0
            } else {
                2 + path
                    + if flags > 0 { 1 + flags } else { 0 }
                    + if branch > 0 { 3 + branch } else { 0 }
            }
        };
        let over = |identity: usize, path: usize, branch: usize| {
            (identity + context_width(path, branch) + command + 2).saturating_sub(cols)
        };
        if over(identity, path, branch) > 0 {
            branch = 0;
        }
        // Squeeze padding, not searchable values. Overlong names/paths remain
        // available to fzf while ordinary rows still align at these columns.
        let give = over(identity, path, branch).min(path.saturating_sub(8));
        path -= give;
        let give = over(identity, path, branch).min(identity.saturating_sub(14));
        identity -= give;
        Self {
            identity,
            path,
            flags,
            branch,
            context: context_width(path, branch),
        }
    }

    fn context(&self, row: &Draft, palette: &Palette) -> String {
        if self.context == 0 {
            return String::new();
        }
        let body = format!(
            "{} {}{}{RST}",
            palette.sep, palette.dim_path, row.facts.path
        );
        let mut output = pad_to(&body, 2 + width(&row.facts.path), 2 + self.path);
        let mut cells = (2 + width(&row.facts.path)).max(2 + self.path);
        if self.flags > 0 {
            if row.flags.len() > 0 {
                output.push_str(&format!(" {}", row.flags.render(palette)));
                cells += 1 + row.flags.len();
            }
            let target = 2 + self.path + 1 + self.flags;
            output = pad_to(&output, cells, target);
            cells = cells.max(target);
        }
        if self.branch > 0 && !row.facts.branch.is_empty() {
            let branch = truncate(&row.facts.branch, self.branch);
            output.push_str(&format!(" {}‹{branch}›{RST}", palette.dim_git));
            cells += 3 + width(&branch);
        }
        pad_to(&output, cells, self.context)
    }
}

/// Snapshot enrichment is collected once; resizing only measures and pads it.
/// Recreate this value after a backend refresh or an action changes the snapshot.
pub(crate) struct Prepared {
    drafts: Vec<Draft>,
    palette: Palette,
    session_rules: bool,
}

impl Prepared {
    pub(crate) fn new(snapshot: &Snapshot) -> Self {
        let mut windows: HashMap<&str, Vec<&Window>> = HashMap::new();
        let mut panes: HashMap<(&str, &str), Vec<&Pane>> = HashMap::new();
        for window in &snapshot.windows {
            windows
                .entry(window.session_key.as_str())
                .or_default()
                .push(window);
        }
        for pane in &snapshot.panes {
            panes
                .entry((pane.session_key.as_str(), pane.window_key.as_str()))
                .or_default()
                .push(pane);
        }
        let mut sessions: Vec<_> = snapshot.sessions.iter().collect();
        let order = crate::env_text("INTERDIMUX_ORDER");
        if order.is_empty() || order == "mru" {
            sessions.sort_by(|a, b| b.last.cmp(&a.last));
            if let Some(index) = sessions
                .iter()
                .position(|s| s.key == snapshot.current.session_key)
            {
                let current = sessions.remove(index);
                sessions.push(current);
            }
        }
        let mut enrichment = Enrichment::new(snapshot);
        let mut drafts = Vec::new();
        for session in sessions {
            let name = session_name(session);
            let children = windows
                .get(session.key.as_str())
                .map(Vec::as_slice)
                .unwrap_or(&[]);
            let session_current = session.key == snapshot.current.session_key;
            let (rendered, cells) =
                identity("", "", &name, session_current, true, &enrichment.palette);
            let age = age_of(session.last, enrichment.now);
            let mut stats = format!(
                "{} win{}",
                children.len(),
                if session.attached { " ●" } else { "" }
            );
            if !age.is_empty() {
                stats.push_str(&format!(" {age}"));
            }
            drafts.push(Draft {
                identity: rendered,
                cells,
                facts: Facts::default(),
                flags: Flags::default(),
                session_stats: Some(stats),
                target: session.target.clone(),
            });
            for (index, window) in children.iter().enumerate() {
                let last = index + 1 == children.len();
                let prefix = format!("  {} ", if last { "└─" } else { "├─" });
                let label = window_name(window);
                let title = numbered(&window.ordinal, &label, "Window");
                let children = panes
                    .get(&(session.key.as_str(), window.key.as_str()))
                    .map(Vec::as_slice)
                    .unwrap_or(&[]);
                let window_current = session_current && window.key == snapshot.current.window_key;
                let facts = enrichment.window(window, children);
                if children.len() == 1 {
                    let pane = children[0];
                    let pane_label = pane_name(pane);
                    let title = if pane_label == label || pane_label == plain(&pane.cmd) {
                        title
                    } else {
                        format!("{title} · {pane_label}")
                    };
                    let (rendered, cells) = identity(
                        &prefix,
                        &name,
                        &title,
                        window_current
                            && (snapshot.current.pane_key.is_empty()
                                || pane.key == snapshot.current.pane_key),
                        false,
                        &enrichment.palette,
                    );
                    drafts.push(Draft {
                        identity: rendered,
                        cells,
                        facts,
                        flags: Flags::from_window(window),
                        session_stats: None,
                        target: pane.target.clone(),
                    });
                } else {
                    let (rendered, cells) = identity(
                        &prefix,
                        &name,
                        &title,
                        window_current,
                        false,
                        &enrichment.palette,
                    );
                    drafts.push(Draft {
                        identity: rendered,
                        cells,
                        facts,
                        flags: Flags::from_window(window),
                        session_stats: None,
                        target: window.target.clone(),
                    });
                    let continuation = if last { " " } else { "│" };
                    for (index, pane) in children.iter().enumerate() {
                        let prefix = format!(
                            "  {continuation}  {} ",
                            if index + 1 == children.len() {
                                "└─"
                            } else {
                                "├─"
                            }
                        );
                        let label = pane_name(pane);
                        let ordinal =
                            format!("{}.{}", plain(&window.ordinal), plain(&pane.ordinal));
                        let title = numbered(&ordinal, &label, "Pane");
                        let (rendered, cells) = identity(
                            &prefix,
                            &name,
                            &title,
                            window_current && pane.key == snapshot.current.pane_key,
                            false,
                            &enrichment.palette,
                        );
                        let facts = enrichment.pane(pane);
                        drafts.push(Draft {
                            identity: rendered,
                            cells,
                            facts,
                            flags: Flags::default(),
                            session_stats: None,
                            target: pane.target.clone(),
                        });
                    }
                }
            }
        }
        Self {
            drafts,
            palette: enrichment.palette,
            session_rules: enabled("INTERDIMUX_SESSION_RULE"),
        }
    }

    #[cfg(test)]
    pub(crate) fn rows(&self, cols: usize) -> Vec<Row> {
        self.rows_and_widths(cols).0
    }

    /// Return padding budgets with rows so directory suggestions reuse the
    /// same measurement instead of scanning colored row strings again.
    pub(crate) fn rows_and_widths(&self, cols: usize) -> (Vec<Row>, (usize, usize)) {
        let layout = Layout::measure(&self.drafts, cols);
        let palette = &self.palette;
        let rows = self
            .drafts
            .iter()
            .map(|row| {
                if let Some(stats) = &row.session_stats {
                    let target = layout.identity
                        + if layout.context > 0 {
                            1 + layout.context
                        } else {
                            0
                        };
                    let dashes = target.saturating_sub(row.cells + 3);
                    let identity = if self.session_rules && dashes >= 3 {
                        format!(
                            "{} {}{}{}  ",
                            row.identity,
                            palette.dim_tree,
                            "─".repeat(dashes),
                            RST
                        )
                    } else {
                        pad_to(&row.identity, row.cells, layout.identity)
                    };
                    Row {
                        identity,
                        context: format!("{}{}{RST}", palette.dim_tree, stats),
                        command: String::new(),
                        target: row.target.clone(),
                    }
                } else {
                    Row {
                        identity: pad_to(&row.identity, row.cells, layout.identity),
                        context: layout.context(&row, palette),
                        command: row.facts.command.clone(),
                        target: row.target.clone(),
                    }
                }
            })
            .collect();
        (rows, (layout.identity, layout.context))
    }
}

#[cfg(test)]
pub(crate) fn rows(snapshot: &Snapshot, cols: usize) -> Vec<Row> {
    Prepared::new(snapshot).rows(cols)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Current, PaneMetadata, Target};

    fn target(session: &str, window: Option<&str>, pane: Option<&str>) -> Target {
        Target::Rex {
            session_id: session.into(),
            window_id: window.map(str::to_owned),
            block_id: pane.map(str::to_owned),
        }
    }

    fn fixture() -> Snapshot {
        Snapshot {
            sessions: vec![Session {
                key: "session:secret".into(),
                name: "dotfiles".into(),
                window_count: "1".into(),
                attached: true,
                last: 0,
                path: String::new(),
                target: target("session:secret", None, None),
            }],
            windows: vec![Window {
                key: "window:secret".into(),
                session_key: "session:secret".into(),
                ordinal: "1".into(),
                name: "editor".into(),
                active: true,
                cmd: String::new(),
                path: String::new(),
                pane_count: 1,
                pid: 0,
                zoomed: false,
                bell: false,
                activity: false,
                target: target("session:secret", Some("window:secret"), None),
            }],
            panes: vec![Pane {
                key: "pane:secret".into(),
                session_key: "session:secret".into(),
                window_key: "window:secret".into(),
                ordinal: "1".into(),
                name: "review".into(),
                active: true,
                cmd: "nvim".into(),
                path: "/opt/tools/interdimux".into(),
                pid: 0,
                agent_id: String::new(),
                title: String::new(),
                opts: String::new(),
                target: target("session:secret", Some("window:secret"), Some("pane:secret")),
            }],
            current: Current {
                session_key: "session:secret".into(),
                window_key: "window:secret".into(),
                pane_key: "pane:secret".into(),
                ..Current::default()
            },
            ..Snapshot::default()
        }
    }

    fn strip(value: &str) -> String {
        let mut chars = value.chars();
        let mut plain = String::new();
        while let Some(c) = chars.next() {
            if c == '\u{1b}' {
                for c in chars.by_ref() {
                    if c.is_ascii_alphabetic() {
                        break;
                    }
                }
            } else {
                plain.push(c);
            }
        }
        plain
    }

    #[test]
    fn singleton_windows_merge_labels_metadata_and_exact_pane_target() {
        let snapshot = fixture();
        let result = rows(&snapshot, 100);
        assert_eq!(result.len(), 2);
        assert!(strip(&result[0].identity).starts_with("● dotfiles"));
        assert_eq!(
            strip(&result[1].identity).trim_end(),
            "●   └─ 1: editor · review · dotfiles"
        );
        assert_eq!(
            strip(&result[1].context).trim_end(),
            "│ /opt/tools/interdimux"
        );
        assert_eq!(strip(&result[1].command), "nvim");
        assert_eq!(result[1].target, snapshot.panes[0].target);
        assert_ne!(result[1].target, snapshot.windows[0].target);
        assert!(!result.iter().any(|row| row.identity.contains("SESSION")
            || row.identity.contains("WINDOW")
            || row.identity.contains("PANE")));
    }

    #[test]
    fn tree_branches_continue_to_siblings_and_only_splits_have_pane_children() {
        let mut snapshot = fixture();
        let mut logs = snapshot.panes[0].clone();
        logs.key = "pane:logs".into();
        logs.ordinal = "2".into();
        logs.name = "logs".into();
        logs.cmd = "tail".into();
        logs.target = target("session:secret", Some("window:secret"), Some("pane:logs"));
        snapshot.panes.push(logs);
        let mut terminal = snapshot.windows[0].clone();
        terminal.key = "window:terminal".into();
        terminal.ordinal = "2".into();
        terminal.name = "terminal".into();
        terminal.target = target("session:secret", Some("window:terminal"), None);
        snapshot.windows.push(terminal);
        let mut shell = snapshot.panes[0].clone();
        shell.key = "pane:shell".into();
        shell.window_key = "window:terminal".into();
        shell.name = "zsh".into();
        shell.cmd = "zsh".into();
        shell.target = target(
            "session:secret",
            Some("window:terminal"),
            Some("pane:shell"),
        );
        snapshot.panes.push(shell);
        let result = rows(&snapshot, 100);
        let tree: Vec<_> = result
            .iter()
            .map(|row| strip(&row.identity).trim_end().to_owned())
            .collect();
        assert_eq!(
            &tree[1..],
            [
                "●   ├─ 1: editor · dotfiles",
                "●   │  ├─ 1.1: review · dotfiles",
                "    │  └─ 1.2: logs · dotfiles",
                "    └─ 2: terminal · dotfiles"
            ]
        );
        assert!(strip(&result[0].context).contains("2 win ●"));
        assert_eq!(
            strip(&result[1].context).trim_end(),
            "│ /opt/tools/interdimux"
        );
        assert_eq!(result[1].target, snapshot.windows[0].target);
        assert_eq!(result[4].target, snapshot.panes[2].target);
        assert!(strip(&result[2].context).contains("/opt/tools/interdimux"));
        for row in &result {
            println!(
                "{}  {}  {}",
                strip(&row.identity),
                strip(&row.context),
                strip(&row.command)
            );
        }
    }

    #[test]
    fn full_search_labels_processes_and_paths_are_not_truncated() {
        let mut snapshot = fixture();
        let session = "前置き非常に長い名前-with-a-unique-session-suffix";
        let window = "very-long-window-name-with-a-distinct-search-suffix";
        let pane = "custom-pane-name-with-a-different-search-suffix";
        snapshot.sessions[0].name = session.into();
        snapshot.windows[0].name = window.into();
        snapshot.panes[0].name = pane.into();
        let result = rows(&snapshot, 24);
        assert!(result[0].identity.contains(session));
        assert!(result[1].identity.contains(window));
        assert!(result[1].identity.contains(pane));
        assert!(result[1].command.contains("nvim"));
        assert!(result[1].context.contains("/opt/tools/interdimux"));
        assert!(!result.iter().any(|row| row.identity.contains('…')));
        assert!(
            strip(&result[1].identity).find(window).unwrap()
                < strip(&result[1].identity).find(session).unwrap(),
            "the target name must lead the repeated session breadcrumb"
        );
    }

    #[test]
    fn missing_metadata_never_creates_a_blank_grid_or_repeated_breadcrumbs() {
        let mut snapshot = fixture();
        snapshot.panes[0].name = "editor".into();
        snapshot.panes[0].cmd.clear();
        snapshot.panes[0].path.clear();
        let result = rows(&snapshot, 160);
        assert!(result[1].context.is_empty());
        assert!(result.iter().all(|row| row.command.is_empty()));
        assert!(!strip(&result[1].identity).contains("        "));
        assert!(result[1].identity.contains("dotfiles"));
    }

    #[test]
    fn labels_paths_and_commands_cannot_inject_controls_or_row_separators() {
        let mut snapshot = fixture();
        snapshot.sessions[0].name = "日本語\tname\n\u{202e}label".into();
        snapshot.panes[0].cmd = "cmd\u{1b}[2J\u{2028}next".into();
        snapshot.panes[0].path = "/tmp/a\r\u{85}b".into();
        let result = rows(&snapshot, 100);
        let visible = result
            .iter()
            .flat_map(|r| [&r.identity, &r.context, &r.command])
            .cloned()
            .collect::<String>();
        assert!(visible.contains("日本語"));
        for control in ['\t', '\n', '\r', '\u{85}', '\u{2028}', '\u{202e}'] {
            assert!(!visible.contains(control), "raw control {control:?}");
        }
        assert!(!visible.contains("\u{1b}[2J"));
    }

    #[test]
    fn formatted_pane_titles_cannot_inject_terminal_or_field_controls() {
        let mut snapshot = fixture();
        snapshot.panes[0].cmd = "codex".into();
        snapshot.panes[0].title = "Review\t日本語\n\u{1b}]52;c;unsafe\u{7}\u{202e}done".into();
        snapshot.pane_metadata.insert(
            snapshot.panes[0].key.clone(),
            PaneMetadata {
                current_title: true,
                ..PaneMetadata::default()
            },
        );
        let mut enrichment = Enrichment::new(&snapshot);
        enrichment.config.show_title = agent::ShowTitle::All;
        let facts = enrichment.pane(&snapshot.panes[0]);
        assert!(
            facts.command.contains("日本語"),
            "the title should be exercised, not discarded"
        );
        let rendered = strip(&facts.command);
        assert!(!rendered.chars().any(char::is_control));
        assert!(!facts.command.contains("\u{1b}]"));
        assert!(!rendered.contains('\u{202e}'));
    }

    #[test]
    fn duplicate_labels_use_ordinals_while_keys_control_current_and_selection() {
        let mut snapshot = fixture();
        let mut other = snapshot.panes[0].clone();
        other.key = "pane:other".into();
        other.ordinal = "2".into();
        other.target = target("session:secret", Some("window:secret"), Some("pane:other"));
        snapshot.panes.push(other);
        let result = rows(&snapshot, 100);
        assert!(strip(&result[2].identity)
            .trim_end()
            .contains("1.1: review · dotfiles"));
        assert!(strip(&result[3].identity)
            .trim_end()
            .contains("1.2: review · dotfiles"));
        assert!(result[2].identity.contains('●'));
        assert!(!result[3].identity.contains('●'));
        assert_ne!(result[2].target, result[3].target);
        assert!(strip(&result[2].context).contains("/opt/tools/interdimux"));
        assert!(!result.iter().any(|row| format!(
            "{}{}{}",
            row.identity, row.context, row.command
        )
        .contains("secret")));
    }

    #[test]
    fn context_and_command_columns_align_in_terminal_cells_with_unicode() {
        let mut snapshot = fixture();
        let mut second = snapshot.panes[0].clone();
        second.key = "pane:two".into();
        second.ordinal = "2".into();
        second.name = "日本語のログ 🚀".into();
        second.path = "/opt/logs".into();
        second.cmd = "tail".into();
        second.target = target("session:secret", Some("window:secret"), Some("pane:two"));
        snapshot.panes.push(second);
        let result = rows(&snapshot, 180);
        let body = &result[1..];
        let identity_width = width(&strip(&body[0].identity));
        let context_width = width(&strip(&body[0].context));
        assert!(body
            .iter()
            .all(|row| width(&strip(&row.identity)) == identity_width));
        assert!(body
            .iter()
            .all(|row| width(&strip(&row.context)) == context_width));
        assert_eq!(result.len(), 4, "group rules must not add separator rows");
        assert!(strip(&result[0].identity).contains('─'));
    }

    #[test]
    fn authoritative_commands_reuse_editor_ssh_interpreter_and_idle_shell_formatting() {
        for (command, expected) in [
            ("/usr/local/bin/nvim -u NONE /tmp/main.rs", "nvim main.rs"),
            (
                "ssh -p 2222 user@build.example tail -f /var/log/app",
                "ssh user@build.example",
            ),
            (
                "/usr/bin/python3 /tmp/tool.py --fast",
                "python3 tool.py --fast",
            ),
            ("/bin/zsh -i", "zsh"),
        ] {
            let mut snapshot = fixture();
            snapshot.pane_metadata.insert(
                "pane:secret".into(),
                PaneMetadata {
                    command_line: command.into(),
                    ..PaneMetadata::default()
                },
            );
            let result = rows(&snapshot, 160);
            assert_eq!(strip(&result[1].command), expected);
            assert!(
                !result[1].context.contains(expected),
                "command leaked into path scope"
            );
        }
    }

    #[test]
    fn full_command_preference_also_applies_to_supplied_metadata() {
        let mut snapshot = fixture();
        snapshot.pane_metadata.insert(
            "pane:secret".into(),
            PaneMetadata {
                command_line: "nvim /tmp/long.rs".into(),
                ..PaneMetadata::default()
            },
        );
        let mut enrichment = Enrichment::new(&snapshot);
        enrichment.full = false;
        assert_eq!(strip(&enrichment.pane(&snapshot.panes[0]).command), "nvim");
    }

    #[test]
    fn window_flags_survive_when_optional_git_badge_gives_up_width() {
        let mut snapshot = fixture();
        snapshot.windows[0].zoomed = true;
        snapshot.windows[0].bell = true;
        snapshot.windows[0].activity = true;
        snapshot.pane_metadata.insert(
            "pane:secret".into(),
            PaneMetadata {
                git_branch: Some("feature/switching".into()),
                ..PaneMetadata::default()
            },
        );
        let wide = rows(&snapshot, 180);
        assert!(strip(&wide[1].context).contains("Z!#"));
        assert!(strip(&wide[1].context).contains("‹feature/switching›"));
        let narrow = rows(&snapshot, 35);
        assert!(strip(&narrow[1].context).contains("Z!#"));
        assert!(!strip(&narrow[1].context).contains("feature/switching"));
        assert_eq!(narrow[1].target, wide[1].target);
    }

    #[test]
    fn terminal_home_and_supplied_git_metadata_do_not_need_local_access() {
        let mut snapshot = fixture();
        snapshot.panes[0].path = "/remote/home/user/project/src".into();
        snapshot.pane_metadata.insert(
            "pane:secret".into(),
            PaneMetadata {
                home: "/remote/home/user".into(),
                git_branch: Some("feature/picker".into()),
                ..PaneMetadata::default()
            },
        );
        let wide = rows(&snapshot, 180);
        assert!(strip(&wide[1].context).contains("~/project/src ‹feature/picker›"));
        let narrow = rows(&snapshot, 38);
        assert!(!strip(&narrow[1].context).contains("feature/picker"));
        assert!(strip(&narrow[1].context).contains("~/project/src"));
        assert!(strip(&narrow[1].identity).contains("editor · review"));
        assert_eq!(wide.len(), narrow.len());
    }

    #[test]
    fn local_git_enrichment_never_reads_a_foreign_panes_path_or_process() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("imux-presentation-{}-{nonce}", std::process::id()));
        std::fs::create_dir_all(path.join(".git")).unwrap();
        std::fs::write(path.join(".git/HEAD"), "ref: refs/heads/local-only\n").unwrap();
        struct Cleanup(std::path::PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(path.clone());
        let mut snapshot = fixture();
        snapshot.panes[0].path = path.to_str().unwrap().into();
        snapshot.panes[0].pid = std::process::id();
        snapshot.panes[0].cmd = "foreign-process".into();
        snapshot
            .pane_metadata
            .insert("pane:secret".into(), PaneMetadata::default());
        let foreign = rows(&snapshot, 240);
        assert_eq!(strip(&foreign[1].command), "foreign-process");
        assert!(!strip(&foreign[1].context).contains("local-only"));
        snapshot.panes[0].pid = 0;
        snapshot.pane_metadata.get_mut("pane:secret").unwrap().local = true;
        let local = rows(&snapshot, 240);
        assert!(strip(&local[1].context).contains("‹local-only›"));
        snapshot
            .pane_metadata
            .get_mut("pane:secret")
            .unwrap()
            .git_branch = Some(String::new());
        let known_absent = rows(&snapshot, 240);
        assert!(!strip(&known_absent[1].context).contains("local-only"));
    }

    #[test]
    fn explicit_program_reports_are_visible_and_respect_hidden_titles() {
        let mut snapshot = fixture();
        snapshot.panes[0].cmd = "codex".into();
        snapshot.panes[0].title = "Review requested changes".into();
        snapshot.pane_metadata.insert(
            snapshot.panes[0].key.clone(),
            PaneMetadata {
                reported_title: true,
                ..PaneMetadata::default()
            },
        );
        let mut enrichment = Enrichment::new(&snapshot);
        enrichment.config.show_title = agent::ShowTitle::Known;
        assert!(strip(&enrichment.pane(&snapshot.panes[0]).command)
            .contains("Review requested changes"));
        enrichment.config.show_title = agent::ShowTitle::Off;
        enrichment.cache.clear();
        assert!(!strip(&enrichment.pane(&snapshot.panes[0]).command)
            .contains("Review requested changes"));
    }

    #[test]
    fn verified_program_progress_is_compact_and_respects_state_preference() {
        let mut snapshot = fixture();
        for progress in [0, 42, 100] {
            snapshot.pane_metadata.insert(
                snapshot.panes[0].key.clone(),
                PaneMetadata {
                    program_status: Some(crate::model::ProgramStatus {
                        state: "working".into(),
                        progress: Some(progress),
                        ..crate::model::ProgramStatus::default()
                    }),
                    ..PaneMetadata::default()
                },
            );
            let mut enrichment = Enrichment::new(&snapshot);
            enrichment.config.state = true;
            assert_eq!(
                strip(&enrichment.pane(&snapshot.panes[0]).command),
                format!("[{progress}%] nvim")
            );
            enrichment.config.state = false;
            enrichment.cache.clear();
            assert_eq!(strip(&enrichment.pane(&snapshot.panes[0]).command), "nvim");
        }
    }
    #[test]
    fn resizing_reuses_enrichment_until_the_snapshot_is_refreshed() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("imux-resize-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(path.join(".git")).unwrap();
        struct Cleanup(std::path::PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(path.clone());
        std::fs::write(path.join(".git/HEAD"), "ref: refs/heads/first\n").unwrap();
        let mut snapshot = fixture();
        snapshot.panes[0].path = path.to_string_lossy().into();
        snapshot.pane_metadata.insert(
            snapshot.panes[0].key.clone(),
            PaneMetadata {
                local: true,
                ..PaneMetadata::default()
            },
        );
        let prepared = Prepared::new(&snapshot);
        assert!(strip(&prepared.rows(240)[1].context).contains("‹first›"));
        std::fs::write(path.join(".git/HEAD"), "ref: refs/heads/updated\n").unwrap();
        for cols in [180, 36, 240] {
            let result = prepared.rows(cols);
            assert!(!strip(&result[1].context).contains("updated"));
            assert_eq!(result[1].target, snapshot.panes[0].target);
        }
        let refreshed = Prepared::new(&snapshot).rows(240);
        assert!(strip(&refreshed[1].context).contains("‹updated›"));
    }
}
