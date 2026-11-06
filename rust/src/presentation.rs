//! Shared native navigator rows: measured tree, path/context, and command columns.
//!
//! Every displayed field has a bounded cell budget. Names and commands shorten
//! on the right; paths retain their useful suffix. Exact native targets and the
//! original snapshot remain available to actions and previews.

use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::agent;
use crate::git::GitCache;
use crate::model::{Pane, Row, Session, Snapshot, Target, Window};
use crate::palette::{NativeTheme, Palette, BOLD, RST};
use crate::proc::Resolver;
use crate::text::{age_of, tildify, truncate, truncate_ansi, truncate_left, width, PreparedAnsi};

const IDENTITY_MAX: usize = 40;
const CONTEXT_MAX: usize = 44;
const COMMAND_MAX: usize = 80;

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
    primary: String,
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
            palette: Palette::native(),
            primary: NativeTheme::from_env().primary,
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
                foreground_status: metadata.is_some_and(|m| m.program_status.is_some()),
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
    identity: PreparedAnsi,
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
    primary: &str,
) -> (String, usize) {
    let marker = if current {
        format!("{}•{RST}", palette.dim_cmd)
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
            "{marker} {}{prefix}{RST}{weight}{primary}{name}{RST}{}{parent}{RST}",
            palette.dim_tree, palette.dim_tree
        ),
        2 + width(prefix) + width(&parent) + width(name),
    )
}

/// These maxima belong to a snapshot, not a viewport. In particular, measuring
/// long Unicode paths again on every resize adds work without changing them.
#[derive(Default)]
struct Measurements {
    identity: usize,
    path: usize,
    flags: usize,
    branch: usize,
}

impl Measurements {
    fn new(rows: &[Draft]) -> Self {
        let mut result = Self::default();
        for row in rows {
            result.identity = result.identity.max(row.cells);
            result.path = result.path.max(width(&row.facts.path));
            result.flags = result.flags.max(row.flags.len());
            result.branch = result.branch.max(width(&row.facts.branch).min(18));
        }
        result
    }
}

struct Layout {
    identity: usize,
    path: usize,
    flags: usize,
    branch: usize,
    context: usize,
    command: usize,
}
impl Layout {
    fn measure(measured: &Measurements, cols: usize, directory_widths: (usize, usize)) -> Self {
        // The TSV display has two one-cell separators. Even a zero-width
        // viewport produces bounded empty fields without arithmetic underflow.
        let usable = cols.saturating_sub(2);
        let identity_max = measured.identity.max(directory_widths.0);
        let path_max = measured.path.max(directory_widths.1);
        let flags = measured.flags;
        let branch_max = measured.branch;
        let context_wanted = if path_max == 0 && flags == 0 && branch_max == 0 {
            0
        } else {
            2 + path_max.min(CONTEXT_MAX)
                + if flags > 0 { 1 + flags } else { 0 }
                + if branch_max > 0 { 3 + branch_max } else { 0 }
        };
        // Give identity at most 40% and context at most one third of a narrow
        // viewport, leaving command/status visible even under very long labels.
        let identity = identity_max
            .min(IDENTITY_MAX)
            .min(usable.saturating_mul(2) / 5);
        let context = context_wanted.min(CONTEXT_MAX).min(usable / 3);
        let command = usable.saturating_sub(identity + context).min(COMMAND_MAX);
        let fixed = 2 + if flags > 0 { 1 + flags } else { 0 };
        let room = context.saturating_sub(fixed);
        // Git is optional; retain flags and a useful path suffix before a badge.
        let branch = if branch_max > 0 && room >= path_max.min(8) + 3 + branch_max {
            branch_max
        } else {
            0
        };
        let path = room
            .saturating_sub(if branch > 0 { 3 + branch } else { 0 })
            .min(path_max);
        Self {
            identity,
            path,
            flags,
            branch,
            context,
            command,
        }
    }

    fn context(&self, row: &Draft, palette: &Palette) -> String {
        if self.context == 0 {
            return String::new();
        }
        let path = truncate_left(&row.facts.path, self.path);
        let mut output = format!("{} {}{}{RST}", palette.sep, palette.dim_path, path);
        output.extend(std::iter::repeat(' ').take(self.path.saturating_sub(width(&path))));
        let mut cells = 2 + self.path;
        if self.flags > 0 {
            if row.flags.len() > 0 {
                output.push_str(&format!(" {}", row.flags.render(palette)));
                cells += 1 + row.flags.len();
            }
            let target = 2 + self.path + 1 + self.flags;
            output.extend(std::iter::repeat(' ').take(target.saturating_sub(cells)));
            cells = cells.max(target);
        }
        if self.branch > 0 && !row.facts.branch.is_empty() {
            let branch = truncate(&row.facts.branch, self.branch);
            output.push_str(&format!(" {}‹{branch}›{RST}", palette.dim_git));
            cells += 3 + width(&branch);
        }
        if cells > self.context {
            // Only tiny viewports can be narrower than the fixed ornaments.
            truncate_ansi(&output, self.context)
        } else {
            output.extend(std::iter::repeat(' ').take(self.context - cells));
            output
        }
    }
}

/// Snapshot enrichment is collected once; resizing only measures and pads it.
/// Recreate this value after a backend refresh or an action changes the snapshot.
pub(crate) struct Prepared {
    drafts: Vec<Draft>,
    measurements: Measurements,
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
            let (rendered, cells) = identity(
                "",
                "",
                &name,
                session_current,
                true,
                &enrichment.palette,
                &enrichment.primary,
            );
            let age = age_of(session.last, enrichment.now);
            let mut stats = format!(
                "{} win{}",
                children.len(),
                if session.attached { " •" } else { "" }
            );
            if !age.is_empty() {
                stats.push_str(&format!(" {age}"));
            }
            drafts.push(Draft {
                identity: PreparedAnsi::new(&rendered),
                cells,
                facts: Facts::default(),
                flags: Flags::default(),
                session_stats: Some(format!("{}{stats}{RST}", enrichment.palette.dim_tree)),
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
                        &enrichment.primary,
                    );
                    drafts.push(Draft {
                        identity: PreparedAnsi::new(&rendered),
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
                        &enrichment.primary,
                    );
                    drafts.push(Draft {
                        identity: PreparedAnsi::new(&rendered),
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
                            &enrichment.primary,
                        );
                        let facts = enrichment.pane(pane);
                        drafts.push(Draft {
                            identity: PreparedAnsi::new(&rendered),
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
        let measurements = Measurements::new(&drafts);
        Self {
            drafts,
            measurements,
            palette: enrichment.palette,
            session_rules: enabled("INTERDIMUX_SESSION_RULE"),
        }
    }

    #[cfg(test)]
    pub(crate) fn rows(&self, cols: usize) -> Vec<Row> {
        self.rows_and_widths(cols, (0, 0)).0
    }

    /// Return padding budgets with rows so directory suggestions reuse the
    /// same measurement instead of scanning colored row strings again.
    pub(crate) fn rows_and_widths(
        &self,
        cols: usize,
        directory_widths: (usize, usize),
    ) -> (Vec<Row>, (usize, usize, usize)) {
        let layout = Layout::measure(&self.measurements, cols, directory_widths);
        let palette = &self.palette;
        let rows = self
            .drafts
            .iter()
            .map(|row| {
                let (mut identity, mut cells) = row.identity.truncate(layout.identity);
                let (context, command) = if let Some(stats) = &row.session_stats {
                    let spare = layout.identity.saturating_sub(cells);
                    if self.session_rules && spare >= 4 {
                        identity.push_str(&format!(
                            " {}{}{RST}",
                            palette.dim_tree,
                            "─".repeat(spare - 1)
                        ));
                        cells = layout.identity;
                    }
                    let context = if self.session_rules && layout.context > 0 {
                        format!("{}{}{RST}", palette.dim_tree, "─".repeat(layout.context))
                    } else {
                        " ".repeat(layout.context)
                    };
                    (context, stats.as_str())
                } else {
                    (layout.context(row, palette), row.facts.command.as_str())
                };
                identity.extend(std::iter::repeat(' ').take(layout.identity.saturating_sub(cells)));
                Row {
                    identity,
                    context,
                    command: truncate_ansi(command, layout.command),
                    target: row.target.clone(),
                }
            })
            .collect();
        (rows, (layout.identity, layout.context, layout.command))
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
    use crate::text::ansi_width;

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

    // Reproducible in-process measurement: all pane facts are supplied, so
    // filesystem, subprocess and backend latency are deliberately excluded.
    // Run: cargo test --release presentation::tests::rendering_benchmark -- --ignored --nocapture
    #[test]
    #[ignore = "manual rendering performance measurement"]
    fn rendering_benchmark() {
        use std::hint::black_box;
        use std::time::Instant;
        fn measure(mut operation: impl FnMut()) -> f64 {
            for _ in 0..5 {
                operation();
            }
            let started = Instant::now();
            for _ in 0..10 {
                operation();
            }
            let per_iteration = started.elapsed().as_secs_f64() / 10.0;
            let iterations = (0.05 / per_iteration).ceil().clamp(10.0, 10000.0) as usize;
            let mut samples = Vec::new();
            for _ in 0..11 {
                let started = Instant::now();
                for _ in 0..iterations {
                    operation();
                }
                samples.push(started.elapsed().as_secs_f64() * 1e6 / iterations as f64);
            }
            samples.sort_by(f64::total_cmp);
            samples[samples.len() / 2]
        }
        for count in [100, 1000] {
            let seed = fixture();
            let mut snapshot = Snapshot::default();
            for session_index in 0..count / 20 {
                let mut session = seed.sessions[0].clone();
                session.key = format!("session:{session_index}");
                session.name = format!("project-{session_index}-workspace");
                session.last = 1_700_000_000;
                session.target = target(&session.key, None, None);
                snapshot.sessions.push(session.clone());
                for window_index in 0..5 {
                    let mut window = seed.windows[0].clone();
                    window.key = format!("window:{session_index}-{window_index}");
                    window.session_key = session.key.clone();
                    window.ordinal = (window_index + 1).to_string();
                    window.name = format!("service-{window_index}-editor-and-tests");
                    window.pane_count = 4;
                    window.target = target(&session.key, Some(&window.key), None);
                    snapshot.windows.push(window.clone());
                    for pane_index in 0..4 {
                        let mut pane = seed.panes[0].clone();
                        pane.key = format!("pane:{session_index}-{window_index}-{pane_index}");
                        pane.session_key = session.key.clone();
                        pane.window_key = window.key.clone();
                        pane.ordinal = (pane_index + 1).to_string();
                        pane.name = if pane_index == 0 {
                            "review 👩🏽‍💻 日本語 e\u{301}".into()
                        } else {
                            format!("long-running-test-worker-{pane_index}")
                        };
                        pane.path = format!("/workspace/projects/service-{session_index}/packages/frontend/components/source");
                        pane.cmd = "cargo".into();
                        pane.target = target(&session.key, Some(&window.key), Some(&pane.key));
                        snapshot.pane_metadata.insert(pane.key.clone(), PaneMetadata {
                            command_line: format!("cargo test --package service-{session_index} --all-features --test integration -- --nocapture"),
                            git_branch: Some("feature/rendering-review".into()),
                            ..PaneMetadata::default()
                        });
                        snapshot.panes.push(pane);
                    }
                }
            }
            let prepare = measure(|| {
                black_box(Prepared::new(black_box(&snapshot)));
            });
            let prepared = Prepared::new(&snapshot);
            let mut resize = 0;
            let rows = measure(|| {
                let cols = [64, 120, 180][resize % 3];
                resize += 1;
                black_box(prepared.rows_and_widths(black_box(cols), (0, 0)));
            });
            println!(
                "render_bench panes={count} rows={} prepare_us={prepare:.2} resize_us={rows:.2}",
                prepared.drafts.len()
            );
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
        assert!(strip(&result[0].identity).starts_with("• dotfiles"));
        assert_eq!(
            strip(&result[1].identity).trim_end(),
            "•   └─ 1: editor · review · dotfiles"
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
                "•   ├─ 1: editor · dotfiles",
                "•   │  ├─ 1.1: review · dotfiles",
                "    │  └─ 1.2: logs · dotfiles",
                "    └─ 2: terminal · dotfiles"
            ]
        );
        assert!(strip(&result[0].command).contains("2 win •"));
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
    fn every_display_column_is_bounded_without_changing_source_metadata_or_targets() {
        let mut snapshot = fixture();
        snapshot.sessions[0].name = "家庭🏠".repeat(35);
        snapshot.windows[0].name = format!("editor-{}", "long-window-".repeat(15));
        snapshot.panes[0].name = "👩🏽‍💻review".repeat(20);
        snapshot.panes[0].path = format!("{}日本語/src", "/deep/parent/".repeat(20));
        snapshot.panes[0].cmd = "python3".into();
        snapshot.windows[0].zoomed = true;
        snapshot.windows[0].bell = true;
        snapshot.windows[0].activity = true;
        let command = format!("python3 script.py {}", "--long-option=value ".repeat(25));
        snapshot.pane_metadata.insert(
            snapshot.panes[0].key.clone(),
            PaneMetadata {
                command_line: command.clone(),
                git_branch: Some("feature/very-long-branch-name".into()),
                ..PaneMetadata::default()
            },
        );
        let original_session = snapshot.sessions[0].name.clone();
        let original_path = snapshot.panes[0].path.clone();
        let prepared = Prepared::new(&snapshot);
        for cols in 0..=240 {
            let (result, budgets) = prepared.rows_and_widths(cols, (0, 0));
            assert!(budgets.0 <= 40 && budgets.1 <= 44 && budgets.2 <= 80);
            assert!(budgets.0 + budgets.1 + budgets.2 <= cols.saturating_sub(2));
            assert_eq!(result[0].target, snapshot.sessions[0].target);
            assert_eq!(result[1].target, snapshot.panes[0].target);
            for row in &result {
                let sizes = (
                    ansi_width(&row.identity),
                    ansi_width(&row.context),
                    ansi_width(&row.command),
                );
                assert!(
                    sizes.0 <= budgets.0 && sizes.1 <= budgets.1 && sizes.2 <= budgets.2,
                    "cols={cols}, sizes={sizes:?}, budgets={budgets:?}"
                );
                if cols >= 2 {
                    assert!(sizes.0 + sizes.1 + sizes.2 + 2 <= cols);
                }
            }
        }
        let wide = prepared.rows(300);
        assert_eq!(ansi_width(&wide[1].identity), 40);
        assert_eq!(ansi_width(&wide[1].context), 44);
        assert_eq!(ansi_width(&wide[1].command), 80);
        assert!(strip(&wide[1].identity).ends_with('…'));
        assert!(strip(&wide[1].command).ends_with('…'));
        assert!(strip(&wide[1].command).starts_with("python3 script.py "));
        assert!(strip(&wide[1].context).contains("日本語/src"));
        assert!(strip(&wide[1].context).starts_with("│ …"));
        assert_eq!(snapshot.sessions[0].name, original_session);
        assert_eq!(snapshot.panes[0].path, original_path);
        assert_eq!(
            snapshot.pane_metadata[&snapshot.panes[0].key].command_line,
            command
        );
    }

    #[test]
    fn session_rules_and_stats_stay_in_their_own_columns() {
        let mut snapshot = fixture();
        snapshot.sessions[0].name = "a session with a very long heading ".repeat(8);
        let prepared = Prepared::new(&snapshot);
        for cols in [2, 8, 24, 60, 120, 300] {
            let (result, (identity, context, command)) = prepared.rows_and_widths(cols, (0, 0));
            assert_eq!(ansi_width(&result[0].identity), identity);
            assert_eq!(ansi_width(&result[0].context), context);
            assert!(ansi_width(&result[0].command) <= command);
            assert_eq!(ansi_width(&result[1].identity), identity);
            assert_eq!(ansi_width(&result[1].context), context);
        }
        let wide = prepared.rows(120);
        assert_eq!(strip(&wide[0].command), "1 win •");
        assert!(strip(&wide[0].context).chars().all(|c| c == '─'));
        assert!(!strip(&wide[0].identity).contains("1 win"));
    }

    #[test]
    fn directory_measurements_reserve_visible_columns_even_without_native_paths() {
        let mut snapshot = fixture();
        snapshot.panes[0].path = "/".into();
        let prepared = Prepared::new(&snapshot);
        let (_, native) = prepared.rows_and_widths(120, (0, 0));
        let (_, with_directories) = prepared.rows_and_widths(120, (80, 160));
        assert_eq!(native.1, 3);
        assert!(with_directories.1 > native.1);
        assert_eq!(with_directories, (40, 39, 39));

        let empty = Prepared::new(&Snapshot::default());
        let (rows, budgets) = empty.rows_and_widths(120, (20, 160));
        assert!(rows.is_empty());
        assert_eq!(budgets, (20, 39, 59));
    }

    #[test]
    fn missing_metadata_never_creates_a_blank_grid_or_repeated_breadcrumbs() {
        let mut snapshot = fixture();
        snapshot.panes[0].name = "editor".into();
        snapshot.panes[0].cmd.clear();
        snapshot.panes[0].path.clear();
        let result = rows(&snapshot, 160);
        assert!(result[1].context.is_empty());
        assert!(result[1].command.is_empty());
        assert_eq!(strip(&result[0].command), "1 win •");
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
        assert!(result[2].identity.contains('•'));
        assert!(!result[3].identity.contains('•'));
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
        assert!(strip(&narrow[1].context).starts_with("│ …"));
        assert!(strip(&narrow[1].context).trim_end().ends_with("/src"));
        assert!(strip(&narrow[1].identity).ends_with('…'));
        assert_eq!(narrow[1].target, wide[1].target);
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
