//! The legacy gather3 input adapter. Its framing and tolerance remain unchanged.

use std::io::{self, Write};

use crate::agent;
use crate::model::{Current, Pane, Session, Snapshot, Target, Window};
use crate::pipeline::{self, RenderOptions};

const US: char = '\u{1f}';

pub(crate) fn gather() {
    let sections = read_sections();
    // Start the directory query before parsing, as the original gather3 did.
    let zoxide = if crate::env_text("INTERDIMUX_SHOW_DIRS") == "on" {
        crate::dirs::start_zoxide()
    } else {
        None
    };
    let snapshot = parse_sections(&sections);
    let options = RenderOptions::from_env(&snapshot);
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    pipeline::render_snapshot_with_zoxide(&snapshot, &options, zoxide, |row| match row.target {
        Target::TmuxLegacy { spec } => {
            writeln!(
                out,
                "{}\t{}\t{}\t{}",
                row.identity, row.context, row.command, spec
            )
            .ok();
        }
        Target::Directory { path } => {
            writeln!(
                out,
                "{}\t{}\t{}\tD:{}",
                row.identity, row.context, row.command, path
            )
            .ok();
        }
        Target::Rex { .. } | Target::TmuxNative { .. } => {
            unreachable!("gather3 only produces legacy tmux and directory targets")
        }
    });
    let _ = out.flush();
}

/// Read the five sections from stdin, separated by RS (\x1e) lines, in the
/// order sessions / windows / panes / current-target / Claude registry.  The
/// first four are bash's single batched tmux query and the fifth is what bash
/// read from ~/.claude/sessions (claude_registry_r), so this binary never
/// shells out to tmux or reads agent files itself — which keeps it testable
/// and keeps the socket plumbing in one place.
fn read_sections() -> Vec<String> {
    // Read BYTES, not a String.  A pane's cwd is arbitrary bytes on Linux, so
    // read_to_string() errors on the first non-UTF-8 path — and swallowing that
    // error yields an empty list, i.e. a silently blank picker.  Lossy decoding
    // degrades one filename to U+FFFD instead of losing every row.  Sized for
    // the dump at once (bash's heredoc pipe holds 64 KiB): an empty Vec starts
    // from a 32-byte probe and doubles, 11 reads for 13 KB of 90 panes.
    let mut buf = Vec::with_capacity(1 << 16);
    if io::Read::read_to_end(&mut io::stdin(), &mut buf).is_err() {
        std::process::exit(1); // let bash fall back rather than print nothing
    }
    let parts: Vec<String> = String::from_utf8_lossy(&buf)
        .split('\u{1e}')
        .map(|s| s.trim_matches('\n').to_string())
        .collect();
    // EXACTLY five sections, or the framing is not what we think it is.  A pane
    // cwd may legally contain RS (tmux only rejects control bytes in session and
    // window NAMES), and one stray RS renumbers every later section: windows and
    // panes vanish and the current-row marker is lost — silently, with a
    // successful exit.  bash has the same guard on its side; exiting non-zero
    // here makes it fall back to its own renderer instead of showing a wrong list.
    if parts.len() != 5 {
        eprintln!("imux: expected 5 input sections, got {}", parts.len());
        std::process::exit(3);
    }
    parts
}

pub(crate) fn parse_sections(sections: &[String]) -> Snapshot {
    let sessions_raw = sections.first().map(String::as_str).unwrap_or("");
    let windows_raw = sections.get(1).map(String::as_str).unwrap_or("");
    let panes_raw = sections.get(2).map(String::as_str).unwrap_or("");
    let cur_raw = sections.get(3).map(String::as_str).unwrap_or("");
    let registry = agent::parse_registry(sections.get(4).map(String::as_str).unwrap_or(""));
    let mut cur = cur_raw.splitn(5, US);
    let session = cur.next().unwrap_or("");
    let window = cur.next().unwrap_or("");
    let pane = cur.next().unwrap_or("");
    let current = Current {
        session_key: session.to_string(),
        window_key: window_key(session, window),
        pane_key: pane_key(session, window, pane),
        host: cur.next().unwrap_or("").to_string(),
        host_short: cur.next().unwrap_or("").to_string(),
    };
    // ---- parse -------------------------------------------------------------
    //
    // tmux gives every list-* line a 100 ms wall-clock budget and, when the
    // server is descheduled for that long mid-line, returns the line CUT at the
    // next '#{' (format.c, FORMAT_TIME_LIMIT) -- `s^_0^_zsh^_1^_zsh^_` -- with
    // no error.  A cut line still names its session/window/pane, so it is KEPT
    // (dropping it lost the row, and a window took its panes with it); what it
    // lost is shown as absent for this one paint.  bash's gather_targets applies
    // the same rules -- see the comments there.

    // The session NAME is the first field (bash's _sfmt), so a cut line keeps
    // its identity; everything after it may be missing.  #{session_path} is
    // last and taken whole -- at most five fields -- so a US inside it stays in
    // the path, exactly as bash's `read` hands the remainder to its last name.
    let sessions: Vec<Session> = sessions_raw
        .lines()
        .filter(|l| !l.is_empty())
        .filter_map(|l| {
            let f: Vec<&str> = l.splitn(5, US).collect();
            let name = f[0].to_string();
            if name.is_empty() {
                return None;
            }
            Some(Session {
                last: f.get(1).and_then(|s| s.parse().ok()).unwrap_or(0),
                key: name.clone(),
                target: Target::TmuxLegacy {
                    spec: format!("S:{}", name),
                },
                name,
                window_count: f.get(2).unwrap_or(&"").to_string(),
                attached: !f.get(3).unwrap_or(&"").is_empty(),
                path: f.get(4).unwrap_or(&"").to_string(),
            })
        })
        .collect();

    let windows: Vec<Window> = windows_raw
        .lines()
        .filter(|l| !l.is_empty())
        .filter_map(|l| {
            let f: Vec<&str> = l.split(US).collect();
            // Never MORE than 9: `< 9` once accepted *at least* 9, so a US inside
            // pane_current_path shifted every later field and pane_pid became
            // whatever followed the injected separator — a pid this process
            // then read from /proc.
            if f.len() > 9 || f[0].is_empty() {
                return None;
            }
            if f.len() == 9 && !f[8].is_empty() {
                let flags = f[8].as_bytes();
                return Some(Window {
                    key: window_key(f[0], f[1]),
                    session_key: f[0].into(),
                    ordinal: f[1].into(),
                    target: Target::TmuxLegacy {
                        spec: format!("W:{}:{}", f[0], f[1]),
                    },
                    name: f[2].into(),
                    active: f[3] == "1",
                    cmd: f[4].into(),
                    path: f[5].into(),
                    pane_count: f[6].parse().unwrap_or(1),
                    pid: f[7].parse().unwrap_or(0),
                    zoomed: flags.first() == Some(&b'1'),
                    bell: flags.get(1) == Some(&b'1'),
                    activity: flags.get(2) == Some(&b'1'),
                });
            }
            // Cut short.  Kept only while it is plausibly a window: a numeric
            // index and window_active as 0/1 -- or no window_active at all
            // when tmux cut the line before it (short_active).  The other
            // short line there is, the tail of a line split by a newline in a
            // pane cwd (`<path tail>^_<panes>^_<pid>^_<flags>`), has the
            // 3-digit flags where `active` belongs.  And the pid is NEVER read
            // from a short line: it is the one field that reaches /proc, and
            // such a fragment can put any number in that position.
            if !is_index(f.get(1)) || !short_active(f.get(3), l.ends_with(US)) {
                return None;
            }
            Some(Window {
                key: window_key(f[0], f[1]),
                session_key: f[0].into(),
                ordinal: f[1].into(),
                target: Target::TmuxLegacy {
                    spec: format!("W:{}:{}", f[0], f[1]),
                },
                name: f.get(2).unwrap_or(&"").to_string(),
                active: f.get(3) == Some(&"1"),
                cmd: f.get(4).unwrap_or(&"").to_string(),
                path: f.get(5).unwrap_or(&"").to_string(),
                pane_count: 1,
                pid: 0,
                zoomed: false,
                bell: false,
                activity: false,
            })
        })
        .collect();

    let panes: Vec<Pane> = panes_raw
        .lines()
        .filter(|l| !l.is_empty())
        .filter_map(|l| {
            let f: Vec<&str> = l.split(US).collect();
            if f.len() > 11 || f[0].is_empty() {
                return None;
            }
            // #{pane_id}, #{pane_title} and the options follow #{window_panes}
            // (gather3).  A
            // pane id that is there and is not %N: not a pane line at all.
            if let Some(id) = f.get(8) {
                if !id.is_empty() && !is_pane_id(id) {
                    return None;
                }
            }
            // Whole means all eleven fields.  Fewer ending in US is a line cut
            // in its tail -- or a US inside the cwd of one cut before
            // #{window_panes}, whose "pid" is whatever followed the stray
            // separator.  Either way it is a cut line: never read its pid.
            let whole = f.len() == 11 && !f[7].is_empty();
            // A cut pane line is kept on the same terms as a window line.  Here
            // the trailing separator is the ONLY difference between a line cut
            // before #{pane_active} (`s^_0^_1^_`) and the tail of a line split
            // by a newline in a pane cwd (`<tail>^_<pid>^_<window_panes>`):
            // both are three fields, numeric in the second and third.
            if !whole
                && (!is_index(f.get(1))
                    || !is_index(f.get(2))
                    || !short_active(f.get(3), l.ends_with(US)))
            {
                return None;
            }
            Some(Pane {
                key: pane_key(f[0], f[1], f[2]),
                session_key: f[0].into(),
                window_key: window_key(f[0], f[1]),
                ordinal: f[2].into(),
                name: f
                    .get(9)
                    .filter(|title| {
                        !title.is_empty()
                            && **title != current.host
                            && **title != current.host_short
                    })
                    .unwrap_or(&"")
                    .to_string(),
                target: Target::TmuxLegacy {
                    spec: format!("P:{}:{}:{}", f[0], f[1], f[2]),
                },
                active: f.get(3) == Some(&"1"),
                cmd: f.get(4).unwrap_or(&"").to_string(),
                path: f.get(5).unwrap_or(&"").to_string(),
                pid: if whole { f[6].parse().unwrap_or(0) } else { 0 },
                agent_id: f.get(8).unwrap_or(&"").to_string(),
                title: f.get(9).unwrap_or(&"").to_string(),
                opts: f.get(10).unwrap_or(&"").to_string(),
            })
        })
        .collect();

    Snapshot {
        sessions,
        windows,
        panes,
        current,
        registry,
        pane_metadata: Default::default(),
    }
}

fn window_key(session: &str, window: &str) -> String {
    format!("{}{}{}", session, US, window)
}

fn pane_key(session: &str, window: &str, pane: &str) -> String {
    format!("{}{}{}{}{}", session, US, window, US, pane)
}

/// A tmux window or pane index: present, and nothing but ASCII digits.
fn is_index(f: Option<&&str>) -> bool {
    matches!(f, Some(s) if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
}

/// A tmux pane id: `%` and ASCII digits.
fn is_pane_id(s: &str) -> bool {
    s.len() > 1 && s.starts_with('%') && s[1..].bytes().all(|b| b.is_ascii_digit())
}

/// window_active / pane_active on a line that is not whole: 0 or 1 -- or
/// nothing, when tmux `cut` the line before it.  tmux stops at a `#{`, so the
/// separator in front of it has already been copied and every cut line ends
/// in US; the fragment a newline in a cwd leaves ends in a flag or a count.
/// Keyed on that mark, not on the field: a pane fragment's fourth field is
/// just as empty as a cut line's.
fn short_active(f: Option<&&str>, cut: bool) -> bool {
    match f {
        Some(&"0") | Some(&"1") => true,
        None | Some(&"") => cut,
        _ => false,
    }
}
