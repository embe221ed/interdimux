//! imux — the heavy-processing core for interdimux.
//!
//! The bash script stays as the tmux-integration and UI layer; this binary owns
//! the part that was 181ms of in-process bash: parsing the tmux dumps, sizing
//! the columns, resolving commands and git branches, and rendering the rows.
//!
//! Contract: `imux gather` writes exactly what `interdimux.sh --list` writes.
//! bash falls back to its own implementation when this binary is absent, so the
//! two must stay in step — tests/test_rust_parity.sh enforces that.

mod dirs;
mod format;
mod git;
mod macproc;
mod palette;
mod proc;
mod render;
mod text;
mod widths;

use std::io::{self, Write};

use git::GitCache;
use palette::{Palette, RST};
use proc::Resolver;
use text::{age_of, truncate, width};
use widths::{Maxima, Widths};

const US: char = '\u{1f}';

fn env_is(name: &str, want: &str) -> bool {
    std::env::var(name).map(|v| v == want).unwrap_or(false)
}
fn env_or(name: &str, default: &str) -> String {
    match std::env::var(name) {
        Ok(v) if !v.is_empty() => v,
        _ => default.to_string(),
    }
}

struct Session {
    last: i64,
    name: String,
    windows: String,
    attached: bool,
}
struct Window {
    session: String,
    idx: String,
    name: String,
    active: bool,
    cmd: String,
    path: String,
    panes: usize,
    pid: u32,
    zoomed: bool,
    bell: bool,
    activity: bool,
}
struct Pane {
    session: String,
    widx: String,
    idx: String,
    cmd: String,
    path: String,
    pid: u32,
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("gather") => gather(),
        Some("--version") | Some("-V") => println!("imux {}", env!("CARGO_PKG_VERSION")),
        _ => {
            eprintln!("imux: usage: imux gather");
            std::process::exit(2);
        }
    }
}

/// Read the three tmux sections from stdin, separated by RS (\x1e) lines, in the
/// order sessions / windows / panes / current-target.  bash already performs the
/// single batched query, so this binary never shells out to tmux itself — which
/// keeps it testable and keeps the socket plumbing in one place.
fn read_sections() -> Vec<String> {
    // Read BYTES, not a String.  A pane's cwd is arbitrary bytes on Linux, so
    // read_to_string() errors on the first non-UTF-8 path — and swallowing that
    // error yields an empty list, i.e. a silently blank picker.  Lossy decoding
    // degrades one filename to U+FFFD instead of losing every row.
    let mut buf = Vec::new();
    if io::Read::read_to_end(&mut io::stdin(), &mut buf).is_err() {
        std::process::exit(1); // let bash fall back rather than print nothing
    }
    let parts: Vec<String> = String::from_utf8_lossy(&buf)
        .split('\u{1e}')
        .map(|s| s.trim_matches('\n').to_string())
        .collect();
    // EXACTLY four sections, or the framing is not what we think it is.  A pane
    // cwd may legally contain RS (tmux only rejects control bytes in session and
    // window NAMES), and one stray RS renumbers every later section: windows and
    // panes vanish and the current-row marker is lost — silently, with a
    // successful exit.  bash has the same guard on its side; exiting non-zero
    // here makes it fall back to its own renderer instead of showing a wrong list.
    if parts.len() != 4 {
        eprintln!("imux: expected 4 input sections, got {}", parts.len());
        std::process::exit(3);
    }
    parts
}

fn gather() {
    let sections = read_sections();
    let sessions_raw = sections.first().cloned().unwrap_or_default();
    let windows_raw = sections.get(1).cloned().unwrap_or_default();
    let panes_raw = sections.get(2).cloned().unwrap_or_default();
    let cur_raw = sections.get(3).cloned().unwrap_or_default();

    let home = env_or("HOME", "");
    let p = Palette::from_env();
    let show_git = env_is("INTERDIMUX_SHOW_GIT_BRANCH", "on");
    let show_full = env_is("INTERDIMUX_SHOW_FULL_COMMAND", "on");
    let preview_on = env_is("INTERDIMUX_SHOW_PREVIEW", "on");
    let mru = env_or("INTERDIMUX_ORDER", "mru") == "mru";
    let cols: usize = env_or("INTERDIMUX_COLS", "80").parse().unwrap_or(80);
    let session_rule = env_is("INTERDIMUX_SESSION_RULE", "on");
    let now: i64 = env_or("INTERDIMUX_NOW", "0").parse().unwrap_or(0);

    let mut cur = cur_raw.splitn(3, US);
    let current_session = cur.next().unwrap_or("").to_string();
    let current_window = cur.next().unwrap_or("").to_string();
    let current_pane = cur.next().unwrap_or("").to_string();

    // ---- parse -------------------------------------------------------------
    let mut sessions: Vec<Session> = sessions_raw
        .lines()
        .filter(|l| !l.is_empty())
        .filter_map(|l| {
            let f: Vec<&str> = l.split(US).collect();
            let name = (*f.get(1)?).to_string();
            if name.is_empty() {
                return None;
            }
            Some(Session {
                last: f.first().and_then(|s| s.parse().ok()).unwrap_or(0),
                name,
                windows: f.get(2).unwrap_or(&"").to_string(),
                attached: !f.get(3).unwrap_or(&"").is_empty(),
            })
        })
        .collect();

    let windows: Vec<Window> = windows_raw
        .lines()
        .filter(|l| !l.is_empty())
        .filter_map(|l| {
            let f: Vec<&str> = l.split(US).collect();
            // EXACTLY 9: `< 9` accepted *at least* 9, so a US inside
            // pane_current_path shifted every later field and pane_pid became
            // whatever followed the injected separator — a pid this process
            // then read from /proc.
            if f.len() != 9 || f[0].is_empty() {
                return None;
            }
            let flags = f[8].as_bytes();
            Some(Window {
                session: f[0].into(),
                idx: f[1].into(),
                name: f[2].into(),
                active: f[3] == "1",
                cmd: f[4].into(),
                path: f[5].into(),
                panes: f[6].parse().unwrap_or(1),
                pid: f[7].parse().unwrap_or(0),
                zoomed: flags.first() == Some(&b'1'),
                bell: flags.get(1) == Some(&b'1'),
                activity: flags.get(2) == Some(&b'1'),
            })
        })
        .collect();

    let panes: Vec<Pane> = panes_raw
        .lines()
        .filter(|l| !l.is_empty())
        .filter_map(|l| {
            let f: Vec<&str> = l.split(US).collect();
            if f.len() != 8 || f[0].is_empty() {
                return None;
            }
            Some(Pane {
                session: f[0].into(),
                widx: f[1].into(),
                idx: f[2].into(),
                cmd: f[4].into(),
                path: f[5].into(),
                pid: f[6].parse().unwrap_or(0),
            })
        })
        .collect();

    // ---- measure + compute widths -----------------------------------------
    let mut mx = Maxima::default();
    for s in &sessions {
        mx.observe_session(&s.name);
    }
    for w in &windows {
        mx.observe_window(&w.idx, &w.name, &w.path, &home);
    }
    for pn in &panes {
        mx.observe_pane(&pn.path, &home);
    }
    let w = widths::compute(mx, cols, preview_on);

    // ---- MRU: most recent first, the CURRENT session moved to the END ------
    // (so Enter on an empty query toggles back to the previous session)
    if mru {
        sessions.sort_by(|a, b| b.last.cmp(&a.last));
        if let Some(i) = sessions.iter().position(|s| s.name == current_session) {
            let c = sessions.remove(i);
            sessions.push(c);
        }
    }

    // ---- group -------------------------------------------------------------
    let mut wins_by_sess: std::collections::HashMap<&str, Vec<&Window>> = Default::default();
    for x in &windows {
        wins_by_sess.entry(x.session.as_str()).or_default().push(x);
    }
    let mut panes_by_win: std::collections::HashMap<(&str, &str), Vec<&Pane>> = Default::default();
    for x in &panes {
        panes_by_win.entry((x.session.as_str(), x.widx.as_str())).or_default().push(x);
    }

    // ---- emit --------------------------------------------------------------
    let mut git = GitCache::new();
    let mut res = Resolver::new();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    let mut session_dirs: std::collections::HashSet<String> = Default::default();

    let cmd_field = |cmd: &str, pid: u32, r: &mut Resolver| -> String {
        let raw = if show_full { r.full_command(pid, cmd) } else { cmd.replace('\t', " ") };
        format::format_command(&raw, &p).0
    };

    for s in &sessions {
        let is_cur = s.name == current_session;
        let (ident, sdisp_full) = render::session_ident(&s.name, is_cur, &w, &p, session_rule);
        let age = age_of(s.last, now);
        let meta = render::session_meta(&s.windows, s.attached, &age, &p);
        writeln!(out, "{}\t{}\t\tS:{}", ident, meta, s.name).ok();

        let ws = match wins_by_sess.get(s.name.as_str()) {
            Some(v) => v,
            None => continue,
        };
        // the session-name prefix carried on child rows, truncated to PFX_W
        let mut sdisp = sdisp_full.clone();
        if width(&sdisp) > w.pfx {
            sdisp = truncate(&sdisp, w.pfx);
        }

        for (i, x) in ws.iter().enumerate() {
            let last = i + 1 == ws.len();
            let cont = if last { " " } else { "│" };
            let wcur = is_cur && x.idx == current_window;
            if x.active && !x.path.is_empty() {
                session_dirs.insert(x.path.clone());
            }
            let ident = render::window_ident(&sdisp, &x.idx, &x.name, last, wcur, &w, &p);
            let ctx = render::ctx_field(
                &x.path, x.zoomed, x.bell, x.activity, &w, &p, &home, &mut git, show_git,
            );
            let cmd = cmd_field(&x.cmd, x.pid, &mut res);
            writeln!(out, "{}\t{}\t{}\tW:{}:{}", ident, ctx, cmd, x.session, x.idx).ok();

            if x.panes > 1 {
                if let Some(ps) = panes_by_win.get(&(x.session.as_str(), x.idx.as_str())) {
                    for (j, pn) in ps.iter().enumerate() {
                        let plast = j + 1 == ps.len();
                        let pcur = wcur && pn.idx == current_pane;
                        let ident =
                            render::pane_ident(&sdisp, &pn.widx, &pn.idx, cont, plast, pcur, &w, &p);
                        let ctx = render::ctx_field(
                            &pn.path, false, false, false, &w, &p, &home, &mut git, show_git,
                        );
                        let cmd = cmd_field(&pn.cmd, pn.pid, &mut res);
                        writeln!(
                            out, "{}\t{}\t{}\tP:{}:{}:{}",
                            ident, ctx, cmd, pn.session, pn.widx, pn.idx
                        )
                        .ok();
                    }
                }
            }
        }
    }

    // ---- directory rows (the one-list model) -------------------------------
    if env_is("INTERDIMUX_SHOW_DIRS", "on") {
        // A malformed limit falls back to the default, matching bash: it now
        // normalises the numeric options up front (a junk value used to make
        // `[ -ge ]` print "integer expression expected" onto the popup), so
        // "off" here would be the two renderers disagreeing again -- this time
        // with the Rust one silently dropping every directory row.
        let limit: usize = env_or("INTERDIMUX_DIRS_LIMIT", "15").parse().unwrap_or(15);
        let mut n = 0;
        for d in dirs::candidates() {
            if n >= limit {
                break;
            }
            if d.contains('\t') || session_dirs.contains(&d) {
                continue;
            }
            let base = d.rsplit('/').next().unwrap_or(&d);
            let base = if base.is_empty() { d.as_str() } else { base };
            let ident = render::dir_ident(base, &w, &p);
            let ctx = render::ctx_field(
                &d, false, false, false, &w, &p, &home, &mut git, show_git,
            );
            let badge = match dirs::project_type(&d) {
                Some(t) => format!("{}{}{}", palette::DIM, t, RST),
                None => String::new(),
            };
            writeln!(out, "{}\t{}\t{}\tD:{}", ident, ctx, badge, d).ok();
            n += 1;
        }
    }
    let _ = out.flush();
}

fn out_flush<W: Write>(w: &mut W) {
    let _ = w.flush();
}

