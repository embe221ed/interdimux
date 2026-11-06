//! Backend-neutral preview formatting. Only adapters capture terminal content.

use crate::model::{Pane, Session, Snapshot, Target, Window};
use crate::palette::RST;
use std::fs;
use std::io::Read;
use std::path::Path;
use std::time::{Duration, Instant};

#[derive(Default)]
struct Selection<'a> {
    session: Option<&'a Session>,
    window: Option<&'a Window>,
    pane: Option<&'a Pane>,
}

fn selection<'a>(snapshot: &'a Snapshot, target: &Target) -> Selection<'a> {
    if let Some(pane) = snapshot.panes.iter().find(|p| &p.target == target) {
        return Selection {
            session: snapshot.sessions.iter().find(|s| s.key == pane.session_key),
            window: snapshot
                .windows
                .iter()
                .find(|w| w.session_key == pane.session_key && w.key == pane.window_key),
            pane: Some(pane),
        };
    }
    if let Some(window) = snapshot.windows.iter().find(|w| &w.target == target) {
        return Selection {
            session: snapshot
                .sessions
                .iter()
                .find(|s| s.key == window.session_key),
            window: Some(window),
            pane: None,
        };
    }
    Selection {
        session: snapshot.sessions.iter().find(|s| &s.target == target),
        ..Selection::default()
    }
}

fn active_window<'a>(snapshot: &'a Snapshot, session: &Session) -> Option<&'a Window> {
    snapshot
        .windows
        .iter()
        .filter(|w| w.session_key == session.key)
        .find(|w| w.active)
        .or_else(|| {
            snapshot
                .windows
                .iter()
                .find(|w| w.session_key == session.key)
        })
}

fn active_pane<'a>(snapshot: &'a Snapshot, window: &Window) -> Option<&'a Pane> {
    let belongs = |p: &&Pane| p.session_key == window.session_key && p.window_key == window.key;
    snapshot
        .panes
        .iter()
        .filter(belongs)
        .find(|p| p.active)
        .or_else(|| snapshot.panes.iter().filter(belongs).next())
}

/// Resolve a parent preview to its active terminal without names or ordinals.
/// A selected pane always captures exactly that pane, including floating ones.
pub(crate) fn capture_target(snapshot: &Snapshot, target: &Target) -> Option<Target> {
    let selected = selection(snapshot, target);
    if let Some(pane) = selected.pane {
        return Some(pane.target.clone());
    }
    let window = selected
        .window
        .or_else(|| selected.session.and_then(|s| active_window(snapshot, s)))?;
    active_pane(snapshot, window).map(|p| p.target.clone())
}

/// Remove terminal commands while retaining colour (SGR) and readable text.
/// OSC/DCS strings, cursor movement and alternate-screen sequences never enter
/// fzf's preview output. This also makes clipped captures safe to concatenate.
fn safe_text(input: &str, colour: bool) -> String {
    let mut out = String::with_capacity(input.len().min(65_536));
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if out.len() >= 1_048_576 {
            break;
        }
        if c == '\x1b' {
            match chars.next() {
                Some('[') => {
                    let mut sequence = String::new();
                    let mut final_char = None;
                    for next in chars.by_ref() {
                        if ('@'..='~').contains(&next) {
                            final_char = Some(next);
                            break;
                        }
                        if sequence.len() < 96 {
                            sequence.push(next);
                        }
                    }
                    if colour
                        && final_char == Some('m')
                        && sequence
                            .chars()
                            .all(|c| c.is_ascii_digit() || c == ';' || c == ':')
                    {
                        out.push_str("\x1b[");
                        out.push_str(&sequence);
                        out.push('m');
                    }
                }
                Some(']') | Some('P') | Some('^') | Some('_') => {
                    while let Some(next) = chars.next() {
                        if next == '\x07' {
                            break;
                        }
                        if next == '\x1b' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                Some('(') | Some(')') | Some('*') | Some('+') => {
                    chars.next();
                }
                _ => {}
            }
        } else {
            match c {
                '\n' => out.push('\n'),
                '\t' => out.push_str("    "),
                '\r' => {}
                '\u{061c}'
                | '\u{200e}'
                | '\u{200f}'
                | '\u{202a}'..='\u{202e}'
                | '\u{2066}'..='\u{2069}' => out.push(' '),
                c if c.is_control() => {}
                c => out.push(c),
            }
        }
    }
    out
}

fn plain(value: &str) -> String {
    safe_text(value, false)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn label(name: &str, fallback: &str) -> String {
    let name = plain(name);
    if name.is_empty() {
        fallback.into()
    } else {
        name
    }
}

fn numbered(ordinal: &str, name: &str, kind: &str) -> String {
    let ordinal = plain(ordinal);
    let name = label(name, &format!("{kind} {ordinal}"));
    if ordinal.is_empty() || name == format!("{kind} {ordinal}") {
        name
    } else {
        format!("{ordinal}: {name}")
    }
}

fn command<'a>(snapshot: &'a Snapshot, pane: &'a Pane) -> &'a str {
    snapshot
        .pane_metadata
        .get(&pane.key)
        .map(|metadata| metadata.command_line.as_str())
        .filter(|command| !command.is_empty())
        .unwrap_or(&pane.cmd)
}

fn clip(line: &str, columns: usize) -> String {
    let visible = safe_text(line, false);
    let shortened = crate::text::truncate(&visible, columns);
    if shortened == visible {
        return line.into();
    }
    let keep = shortened.chars().count().saturating_sub(1);
    let mut result = String::new();
    let mut chars = line.chars().peekable();
    let mut count = 0;
    while let Some(c) = chars.next() {
        if c == '\x1b' && chars.peek() == Some(&'[') {
            result.push(c);
            for next in chars.by_ref() {
                result.push(next);
                if next == 'm' {
                    break;
                }
            }
        } else {
            if count >= keep {
                break;
            }
            result.push(c);
            count += 1;
        }
    }
    result.push_str(RST);
    if columns > 0 {
        result.push('…');
    }
    result
}

#[cfg(test)]
mod clipping_tests {
    use super::*;

    #[test]
    fn colored_preview_clipping_preserves_unicode_graphemes() {
        for cluster in ["❤️", "👍🏽", "🇵🇱", "👨‍💻", "👨‍👩‍👧‍👦", "1️⃣", "a\u{301}"]
        {
            // SGR changes may occur within a grapheme in terminal captures.
            let colored = cluster
                .chars()
                .map(|c| format!("\x1b[32m{c}"))
                .collect::<String>()
                + "tail";
            let width = crate::text::width(cluster);
            assert_eq!(plain(&clip(&colored, width + 1)), format!("{cluster}…"));
            assert_eq!(plain(&clip(&colored, width)), "…");
            assert_eq!(plain(&clip(&colored, 0)), "");
            assert!(clip(&colored, width + 1).contains("\x1b[32m"));
        }
    }
}

fn summary(snapshot: &Snapshot, selected: &Selection<'_>) -> Vec<String> {
    if selected.pane.is_some() {
        return Vec::new();
    }
    if let Some(window) = selected.window {
        return snapshot
            .panes
            .iter()
            .filter(|p| p.session_key == window.session_key && p.window_key == window.key)
            .map(|p| {
                format!(
                    "{} {}  {}  {}",
                    if p.active { "•" } else { " " },
                    numbered(
                        &p.ordinal,
                        if p.name.is_empty() { &p.cmd } else { &p.name },
                        "Pane"
                    ),
                    plain(command(snapshot, p)),
                    plain(&p.path)
                )
            })
            .collect();
    }
    if let Some(session) = selected.session {
        return snapshot
            .windows
            .iter()
            .filter(|w| w.session_key == session.key)
            .map(|w| {
                format!(
                    "{} {}  {}  {}",
                    if w.active { "•" } else { " " },
                    numbered(&w.ordinal, &w.name, "Window"),
                    plain(&w.cmd),
                    plain(&w.path)
                )
            })
            .collect();
    }
    Vec::new()
}

/// Header, child summary and the latest captured terminal lines. All work is
/// in memory: no process-table, filesystem, shell or backend queries here.
pub(crate) fn render(
    snapshot: &Snapshot,
    target: &Target,
    capture: Result<&str, &str>,
    columns: usize,
    lines: usize,
) -> String {
    let theme = crate::palette::NativeTheme::from_env();
    let accent = &theme.preview_accent;
    let muted = &theme.muted;
    let columns = columns.clamp(1, 1_024);
    let lines = lines.clamp(1, 1_000);
    let selected = selection(snapshot, target);
    let mut output = Vec::new();
    let mut heading = selected
        .session
        .map(|s| label(&s.name, "Untitled session"))
        .unwrap_or_else(|| "Target unavailable".into());
    if let Some(window) = selected.window {
        heading.push_str(" › ");
        heading.push_str(&numbered(&window.ordinal, &window.name, "Window"));
    }
    if let Some(pane) = selected.pane {
        heading.push_str(" › ");
        heading.push_str(&numbered(
            &pane.ordinal,
            if pane.name.is_empty() {
                &pane.cmd
            } else {
                &pane.name
            },
            "Pane",
        ));
    }
    output.push(format!("{accent}{heading}{RST}"));
    let representative = selected
        .pane
        .or_else(|| selected.window.and_then(|w| active_pane(snapshot, w)))
        .or_else(|| {
            selected
                .session
                .and_then(|s| active_window(snapshot, s))
                .and_then(|w| active_pane(snapshot, w))
        });
    let command = representative
        .map(|p| command(snapshot, p))
        .or_else(|| selected.window.map(|w| w.cmd.as_str()))
        .unwrap_or("");
    let path = representative
        .map(|p| p.path.as_str())
        .or_else(|| selected.window.map(|w| w.path.as_str()))
        .or_else(|| selected.session.map(|s| s.path.as_str()))
        .unwrap_or("");
    if let Some(report) = representative
        .and_then(|p| snapshot.pane_metadata.get(&p.key))
        .and_then(|metadata| metadata.program_status.as_ref())
    {
        // Keep terminal output visible in small previews. Only show verified
        // foreground reports, never infer progress from an arbitrary title.
        let budget = lines.saturating_sub(5).min(3);
        if budget > 0 {
            let state = match report.state.as_str() {
                "approve" => "Needs approval",
                "input" => "Needs input",
                "working" => "Working",
                "done" => "Done",
                "error" => "Error",
                _ => "Idle",
            };
            let progress = report
                .progress
                .map(|n| format!(" · {n}%"))
                .unwrap_or_default();
            let app = plain(&report.app);
            let app = if app.is_empty() {
                app
            } else {
                format!(" · {app}")
            };
            output.push(format!("{accent}{state}{progress}{app}{RST}"));
            let title = plain(&report.title);
            let message = plain(&report.message);
            if budget > 1 && !title.is_empty() {
                output.push(format!("{muted}task {RST}{title}"));
            }
            if budget > 2 && !message.is_empty() && message != title {
                output.push(message);
            }
        }
    }
    if !command.is_empty() {
        output.push(format!("{muted}cmd  {RST}{}", plain(command)));
    }
    if !path.is_empty() {
        output.push(format!("{muted}path {RST}{}", plain(path)));
    }
    let children = summary(snapshot, &selected);
    let summary_limit = (lines.saturating_sub(output.len() + 3) / 2).min(8);
    output.extend(children.iter().take(summary_limit).cloned());
    if children.len() > summary_limit && summary_limit > 0 {
        output.push(format!(
            "{muted}… {} more{RST}",
            children.len() - summary_limit
        ));
    }
    if output.len() < lines {
        output.push(format!("{muted}{}{RST}", "─".repeat(columns.min(120))));
    }
    let remaining = lines.saturating_sub(output.len());
    match capture {
        Ok(content) => {
            let safe = safe_text(content, true);
            let capture_lines: Vec<_> = safe.lines().collect();
            let last = capture_lines
                .iter()
                .rposition(|line| !safe_text(line, false).trim().is_empty())
                .map_or(0, |i| i + 1);
            let first = last.saturating_sub(remaining);
            if last == 0 && remaining > 0 {
                output.push(format!("{muted}(empty terminal){RST}"));
            } else {
                output.extend(
                    capture_lines[first..last]
                        .iter()
                        .map(|line| (*line).to_owned()),
                );
            }
        }
        Err(error) if remaining > 0 => {
            output.push(format!("{muted}Preview unavailable: {}{RST}", plain(error)))
        }
        Err(_) => {}
    }
    output
        .into_iter()
        .take(lines)
        .map(|line| format!("{}{RST}\n", clip(&line, columns)))
        .collect()
}

/// Directory previews share the same sanitization and viewport bounds as pane
/// previews. Branches come from GitCache's direct reads; no git/shell process,
/// startup script, recursive walk or arbitrary preview command is executed.
pub(crate) fn directory(path: &str, columns: usize, lines: usize) -> String {
    let theme = crate::palette::NativeTheme::from_env();
    let accent = &theme.preview_accent;
    let muted = &theme.muted;
    let columns = columns.clamp(1, 1_024);
    let lines = lines.clamp(1, 1_000);
    let mut output = vec![format!("{accent}{}{RST}", plain(path))];
    if crate::projects::excluded_network(path) {
        output.push(format!(
            "{muted}Directory preview is disabled on network mounts{RST}"
        ));
        return formatted(output, columns, lines);
    }
    let root = Path::new(path);
    // Do not let a symlink silently turn an ordinary local spelling into a
    // known network/automount path before project/README probes start.
    if let Ok(physical) = fs::canonicalize(root) {
        if physical
            .to_str()
            .map_or(true, crate::projects::excluded_network)
        {
            output.push(format!(
                "{muted}Directory preview is disabled on network mounts{RST}"
            ));
            return formatted(output, columns, lines);
        }
    }
    let Ok(entries) = fs::read_dir(root) else {
        output.push(format!("{muted}Directory unavailable{RST}"));
        return formatted(output, columns, lines);
    };
    let mut git = crate::git::GitCache::new();
    let branch = git.branch(path);
    let mut detail = crate::dirs::project_type(path)
        .unwrap_or("Directory")
        .to_owned();
    if !branch.is_empty() {
        detail.push_str(" · ");
        detail.push_str(&plain(&branch));
    }
    output.push(format!("{muted}{detail}{RST}"));
    let started = Instant::now();
    let mut names = Vec::new();
    let mut limited = false;
    for (index, entry) in entries.enumerate() {
        if index >= 512 || started.elapsed() >= Duration::from_millis(75) {
            limited = true;
            break;
        }
        let Ok(entry) = entry else {
            continue;
        };
        let name = entry.file_name().to_string_lossy().into_owned();
        let kind = entry.file_type().ok();
        let suffix = if kind.as_ref().map_or(false, fs::FileType::is_dir) {
            "/"
        } else if kind.as_ref().map_or(false, fs::FileType::is_symlink) {
            "@"
        } else {
            ""
        };
        names.push(format!("{}{suffix}", plain(&name)));
    }
    names.sort_by_key(|name| name.to_lowercase());
    let readme_limit = (lines.saturating_sub(4) / 3).min(8);
    for candidate in [
        "README.md",
        "README",
        "README.rst",
        "README.txt",
        "readme.md",
        "readme",
    ] {
        let candidate = root.join(candidate);
        // A README symlink can lead anywhere or name a blocking special file.
        if !fs::symlink_metadata(&candidate)
            .map_or(false, |metadata| metadata.file_type().is_file())
        {
            continue;
        }
        let Ok(file) = fs::File::open(&candidate) else {
            continue;
        };
        let mut bytes = Vec::new();
        if file.take(8_192).read_to_end(&mut bytes).is_err() {
            continue;
        }
        let text = safe_text(&String::from_utf8_lossy(&bytes), false);
        output.push(format!("{muted}── README{RST}"));
        output.extend(
            text.lines()
                .filter(|line| !line.trim().is_empty())
                .take(readme_limit)
                .map(str::to_owned),
        );
        break;
    }
    if output.len() < lines {
        output.push(format!("{muted}── Files{RST}"));
    }
    let available = lines.saturating_sub(output.len()).min(30);
    output.extend(names.iter().take(available).cloned());
    if output.len() < lines && (limited || names.len() > available) {
        output.push(format!("{muted}… more entries{RST}"));
    }
    formatted(output, columns, lines)
}

fn formatted(output: Vec<String>, columns: usize, lines: usize) -> String {
    output
        .into_iter()
        .take(lines)
        .map(|line| format!("{}{RST}\n", clip(&line, columns)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(window: Option<&str>, pane: Option<&str>) -> Target {
        Target::Rex {
            session_id: "s".into(),
            window_id: window.map(str::to_owned),
            block_id: pane.map(str::to_owned),
        }
    }

    fn fixture() -> Snapshot {
        Snapshot {
            sessions: vec![Session {
                key: "s".into(),
                name: "project".into(),
                window_count: "2".into(),
                attached: true,
                last: 0,
                path: "/project".into(),
                target: target(None, None),
            }],
            windows: ["a", "b"]
                .into_iter()
                .map(|key| Window {
                    key: key.into(),
                    session_key: "s".into(),
                    ordinal: key.into(),
                    name: "editor".into(),
                    active: key == "b",
                    cmd: "nvim".into(),
                    path: format!("/project/{key}"),
                    pane_count: 1,
                    pid: 0,
                    zoomed: false,
                    bell: false,
                    activity: false,
                    target: target(Some(key), None),
                })
                .collect(),
            panes: ["a", "b"]
                .into_iter()
                .map(|key| Pane {
                    key: key.into(),
                    session_key: "s".into(),
                    window_key: key.into(),
                    ordinal: "1".into(),
                    name: "same label".into(),
                    active: true,
                    cmd: format!("command-{key}"),
                    path: format!("/project/{key}"),
                    pid: 0,
                    agent_id: String::new(),
                    title: String::new(),
                    opts: String::new(),
                    target: target(Some(key), Some(key)),
                })
                .collect(),
            ..Snapshot::default()
        }
    }

    #[test]
    fn captures_exact_native_pane_and_active_parent() {
        let snapshot = fixture();
        assert_eq!(
            capture_target(&snapshot, &target(None, None)),
            Some(target(Some("b"), Some("b")))
        );
        assert_eq!(
            capture_target(&snapshot, &target(Some("a"), None)),
            Some(target(Some("a"), Some("a")))
        );
        assert_eq!(
            capture_target(&snapshot, &target(Some("a"), Some("a"))),
            Some(target(Some("a"), Some("a")))
        );
        assert_eq!(
            capture_target(&snapshot, &target(Some("gone"), Some("a"))),
            None
        );
    }

    #[test]
    fn native_progress_and_task_details_are_safe_and_viewport_bounded() {
        let mut snapshot = fixture();
        snapshot.pane_metadata.insert(
            "a".into(),
            crate::model::PaneMetadata {
                program_status: Some(crate::model::ProgramStatus {
                    state: "working".into(),
                    progress: Some(42),
                    title: "Indexing\nsource".into(),
                    message: "\x1b]2;unsafe\x07Loading 界🚀".into(),
                    app: "builder\u{202e}".into(),
                    ..Default::default()
                }),
                ..Default::default()
            },
        );
        let target = target(Some("a"), Some("a"));
        let rendered = render(&snapshot, &target, Ok("latest terminal output"), 40, 12);
        let plain = safe_text(&rendered, false);
        assert!(plain.contains("Working · 42% · builder"));
        assert!(plain.contains("task Indexing source"));
        assert!(plain.contains("Loading 界🚀"));
        assert!(plain.contains("latest terminal output"));
        assert!(!rendered.contains("unsafe"));
        assert!(!rendered.contains('\u{202e}'));
        for lines in [1, 3, 5, 8, 12] {
            let rendered = safe_text(
                &render(&snapshot, &target, Ok("terminal"), 12, lines),
                false,
            );
            assert!(rendered.lines().count() <= lines);
            assert!(rendered.lines().all(|line| crate::text::width(line) <= 12));
        }
    }

    #[test]
    fn parent_summaries_and_metadata_use_selected_identity() {
        let snapshot = fixture();
        let session = safe_text(
            &render(&snapshot, &target(None, None), Ok("screen"), 100, 24),
            false,
        );
        assert!(session.contains("project"));
        assert!(session.contains("a: editor"));
        assert!(session.contains("b: editor"));
        assert!(session.contains("command-b"));
        let pane = safe_text(
            &render(
                &snapshot,
                &target(Some("a"), Some("a")),
                Ok("screen"),
                100,
                24,
            ),
            false,
        );
        assert!(pane.contains("command-a"));
        assert!(!pane.contains("command-b"));
    }

    #[test]
    fn strips_terminal_commands_preserves_colour_and_visible_link_text() {
        let content = "\x1b[31mred\x1b[0m\x1b[2J\x1b[?1049l\x1b]52;c;secret\x07\x1b]8;;https://example.test\x1b\\link\x1b]8;;\x1b\\\x1bPignored\x1b\\done";
        let safe = safe_text(content, true);
        assert!(safe.contains("\x1b[31mred\x1b[0m"));
        assert!(safe.contains("linkdone"));
        for forbidden in ["[2J", "1049", "secret", "https:", "ignored"] {
            assert!(!safe.contains(forbidden));
        }
    }

    #[test]
    fn bounded_capture_shows_latest_nonblank_lines_and_unicode_fits() {
        let snapshot = fixture();
        let output = render(
            &snapshot,
            &target(Some("a"), Some("a")),
            Ok("old\nolder\nlatest界界界界\n   \n"),
            12,
            5,
        );
        let plain = safe_text(&output, false);
        assert_eq!(plain.lines().count(), 5);
        assert!(!plain.contains("old"));
        assert!(plain.contains("latest"));
        assert!(plain.lines().all(|line| crate::text::width(line) <= 12));
        assert!(!output.contains("\x1b[?1049l"));
    }

    #[test]
    fn empty_or_failed_capture_stays_inside_preview_and_handles_tiny_size() {
        let snapshot = fixture();
        assert!(render(
            &snapshot,
            &target(None, None),
            Err("gone\n\x1b[2J"),
            100,
            24
        )
        .contains("Preview unavailable: gone"));
        assert!(
            render(&snapshot, &target(None, None), Ok("  \n"), 100, 24).contains("empty terminal")
        );
        assert_eq!(
            safe_text(
                &render(&snapshot, &target(None, None), Ok("text"), 0, 0),
                false
            )
            .lines()
            .count(),
            1
        );
    }

    #[test]
    fn directory_preview_reads_branch_readme_and_entries_without_executing_text() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("imux-preview-{}-{stamp}", std::process::id()));
        fs::create_dir_all(root.join(".git")).unwrap();
        fs::create_dir_all(root.join("source")).unwrap();
        fs::write(root.join(".git/HEAD"), "ref: refs/heads/feature/preview\n").unwrap();
        fs::write(root.join("Cargo.toml"), "").unwrap();
        fs::write(
            root.join("README.md"),
            "# Read me\n\x1b[2J$(touch never-run)\nmore details\n",
        )
        .unwrap();
        let rendered = directory(root.to_str().unwrap(), 120, 24);
        let visible = safe_text(&rendered, false);
        assert!(visible.contains("Rust · feature/preview"));
        assert!(visible.contains("# Read me"));
        assert!(visible.contains("$(touch never-run)"));
        assert!(visible.contains("source/"));
        assert!(!rendered.contains("\x1b[2J"));
        assert!(!root.join("never-run").exists());
        let tiny = safe_text(&directory(root.to_str().unwrap(), 8, 4), false);
        assert!(tiny.lines().count() <= 4);
        assert!(tiny.lines().all(|line| crate::text::width(line) <= 8));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn directory_preview_skips_known_network_namespaces() {
        let output = directory("/Network/never-probe/project", 100, 5);
        assert!(output.contains("disabled on network mounts"));
        assert!(!output.contains("Directory unavailable"));
    }
}
