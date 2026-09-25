//! imux — the heavy-processing core for interdimux.
//!
//! The bash script stays as the tmux-integration and UI layer; this binary owns
//! the part that was 181ms of in-process bash: parsing the tmux dumps, sizing
//! the columns, resolving commands and git branches, and rendering the rows.
//!
//! Contract: `imux gather3` writes exactly what `interdimux.sh --list` writes.
//! bash falls back to its own implementation when this binary is absent, so the
//! two must stay in step — tests/test_rust_parity.sh enforces that.  The
//! subcommand's name is the stdin protocol's version: see PROTOCOL.

mod agent;
mod dirs;
mod format;
mod git;
mod macproc;
mod mounts;
mod palette;
mod proc;
mod render;
mod text;
mod titles;
mod widths;

use std::io::{self, Write};

use git::GitCache;
use palette::{Palette, RST};
use proc::Resolver;
use text::{age_of, truncate, width};
use widths::{Maxima, Widths};

const US: char = '\u{1f}';

/// The stdin protocol this build speaks, and the subcommand bash runs it with.
/// The name IS the version: bump it (gather3, ...) with every change to the
/// framing or to the position of any field, in step with IMUX_PROTO in
/// scripts/interdimux.sh.
///
/// Nothing else can make an old binary refuse new input.  Neither TPM's update
/// nor a `git pull` rebuilds rust/, and an INTERDIMUX_BIN installed elsewhere
/// is never rebuilt at all, so a script newer than its binary is routine.  When
/// the session name moved from the second field to the first, a binary built
/// before that read the timestamp as the name: every session was drawn as
/// `S:1790254646`, no window or pane matched one, and the exit status was 0, so
/// that WAS the picker.  An old binary exits 2 on a subcommand it does not
/// know, and an extra argument or an environment variable would only have been
/// ignored.  So a mismatch in either direction fails closed: bash falls back to
/// its own renderer and says, once, that the binary needs rebuilding.
const PROTOCOL: &str = "gather3";

/// A variable's value as text, whatever bytes it holds.  std::env::var gives
/// NOTHING for a value that is not UTF-8: one Latin-1 byte in the user's
/// title rules emptied the whole rule set bash handed over, every built-in
/// rule with it (review R02).  Lossy: a U+FFFD fails every test the stray
/// byte would, and compares with a path decoded the same way.
pub(crate) fn env_text(name: &str) -> String {
    std::env::var_os(name).map(|v| v.to_string_lossy().into_owned()).unwrap_or_default()
}
fn env_is(name: &str, want: &str) -> bool {
    env_text(name) == want
}
fn env_or(name: &str, default: &str) -> String {
    match env_text(name) {
        v if !v.is_empty() => v,
        _ => default.to_string(),
    }
}

struct Session {
    last: i64,
    name: String,
    windows: String,
    attached: bool,
    /// #{session_path}: where the session was started.  A `cd` inside it never
    /// changes this, which is what makes it the session's directory identity.
    path: String,
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
    active: bool,
    cmd: String,
    path: String,
    pid: u32,
    /// #{pane_id} (`%N`), #{pane_title} and the values of the options agent
    /// plugins publish (one per INTERDIMUX_STATE_OPTS name, each ended by GS):
    /// empty on a line cut before them.
    id: String,
    title: String,
    opts: String,
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some(PROTOCOL) => gather(),
        Some("--version") | Some("-V") => println!("imux {}", env!("CARGO_PKG_VERSION")),
        // Another version of the protocol: a script older (`gather`) or newer
        // than this build.  Refused like any unknown subcommand -- exit 2 and
        // nothing on stdout -- so that script renders the list itself.
        Some(other) if other.starts_with("gather") => {
            eprintln!(
                "imux: this build speaks {}, not {}: the script and this binary are from different versions of interdimux",
                PROTOCOL, other
            );
            std::process::exit(2);
        }
        _ => {
            eprintln!("imux: usage: imux {}", PROTOCOL);
            std::process::exit(2);
        }
    }
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
    // degrades one filename to U+FFFD instead of losing every row.
    let mut buf = Vec::new();
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

fn gather() {
    let sections = read_sections();
    let sessions_raw = sections.first().cloned().unwrap_or_default();
    let windows_raw = sections.get(1).cloned().unwrap_or_default();
    let panes_raw = sections.get(2).cloned().unwrap_or_default();
    let cur_raw = sections.get(3).cloned().unwrap_or_default();
    let registry = agent::parse_registry(sections.get(4).map(String::as_str).unwrap_or(""));

    let home = env_or("HOME", "");
    let p = Palette::from_env();
    let show_git = env_is("INTERDIMUX_SHOW_GIT_BRANCH", "on");
    let show_full = env_is("INTERDIMUX_SHOW_FULL_COMMAND", "on");
    let preview_on = env_is("INTERDIMUX_SHOW_PREVIEW", "on");
    let mru = env_or("INTERDIMUX_ORDER", "mru") == "mru";
    let cols: usize = env_or("INTERDIMUX_COLS", "80").parse().unwrap_or(80);
    let session_rule = env_is("INTERDIMUX_SESSION_RULE", "on");
    let now: i64 = env_or("INTERDIMUX_NOW", "0").parse().unwrap_or(0);
    // The agents view (bash VIEW): marks in the gutter, one row per waiting pane.
    let agents_view = env_is("INTERDIMUX_VIEW", "agents");

    let mut cur = cur_raw.splitn(5, US);
    let current_session = cur.next().unwrap_or("").to_string();
    let current_window = cur.next().unwrap_or("").to_string();
    let current_pane = cur.next().unwrap_or("").to_string();
    let host = cur.next().unwrap_or("").to_string();
    let host_short = cur.next().unwrap_or("").to_string();
    let acfg = agent::Config::from_env(&host, &host_short);

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
    let mut sessions: Vec<Session> = sessions_raw
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
                name,
                windows: f.get(2).unwrap_or(&"").to_string(),
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
                session: f[0].into(),
                idx: f[1].into(),
                name: f.get(2).unwrap_or(&"").to_string(),
                active: f.get(3) == Some(&"1"),
                cmd: f.get(4).unwrap_or(&"").to_string(),
                path: f.get(5).unwrap_or(&"").to_string(),
                panes: 1,
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
                session: f[0].into(),
                widx: f[1].into(),
                idx: f[2].into(),
                active: f.get(3) == Some(&"1"),
                cmd: f.get(4).unwrap_or(&"").to_string(),
                path: f.get(5).unwrap_or(&"").to_string(),
                pid: if whole { f[6].parse().unwrap_or(0) } else { 0 },
                id: f.get(8).unwrap_or(&"").to_string(),
                title: f.get(9).unwrap_or(&"").to_string(),
                opts: f.get(10).unwrap_or(&"").to_string(),
            })
        })
        .collect();

    // ---- measure + compute widths -----------------------------------------
    // Branches are looked up here, before the widths, because whether any row
    // HAS one decides whether the badge is worth path cells.  The cache makes
    // the emit loop's lookups free, so this is the same I/O as before.
    let mut git = GitCache::new();
    let mut mx = Maxima::default();
    for s in &sessions {
        mx.observe_session(&s.name);
    }
    for w in &windows {
        mx.observe_window(&w.idx, &w.name, &w.path, &home);
        mx.observe_flags(w.zoomed, w.bell, w.activity);
        if show_git {
            mx.observe_branch(&git.branch(&w.path));
        }
    }
    for pn in &panes {
        mx.observe_pane(&pn.path, &home);
        if show_git {
            mx.observe_branch(&git.branch(&pn.path));
        }
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
    let mut res = Resolver::new();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    let mut session_dirs: std::collections::HashSet<String> = Default::default();

    let mut marked: std::collections::HashSet<String> = Default::default();
    let cmd_field = |cmd: &str, pid: u32, pn: Option<&&Pane>, r: &mut Resolver| -> (String, String) {
        let raw = if show_full { r.full_command(pid, cmd) } else { cmd.replace('\t', " ") };
        let (id, opts, title) =
            pn.map(|x| (x.id.as_str(), x.opts.as_str(), x.title.as_str())).unwrap_or(("", "", ""));
        agent::command_field(&raw, pid, id, title, opts, &acfg, &registry, &p, now)
    };

    for s in &sessions {
        // A directory that already has a session is not offered as a D: row:
        // its start directory, and (below) its active window's cwd.
        if !s.path.is_empty() {
            session_dirs.insert(s.path.clone());
        }
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
            let mut ident = render::window_ident(&sdisp, &x.idx, &x.name, last, wcur, &w, &p);
            let ctx = render::ctx_field(
                &x.path, x.zoomed, x.bell, x.activity, &w, &p, &home, &mut git, show_git,
            );
            // the window row speaks for its active pane: its id, options, title
            let ap = panes_by_win
                .get(&(x.session.as_str(), x.idx.as_str()))
                .and_then(|ps| ps.iter().rev().find(|pn| pn.active));
            let (cmd, state) = cmd_field(&x.cmd, x.pid, ap, &mut res);
            let pane_rows = x.panes > 1 && panes_by_win.contains_key(&(x.session.as_str(), x.idx.as_str()));
            // ...on the window row only where no pane rows follow to carry it
            if agents_view && !pane_rows {
                let id = ap.map(|pn| pn.id.as_str()).unwrap_or("");
                if let Some(m) = agent::view_mark(&state, id, &mut marked, &p) {
                    ident = render::with_gutter(&ident, wcur, &m, &p);
                }
            }
            writeln!(out, "{}\t{}\t{}\tW:{}:{}", ident, ctx, cmd, x.session, x.idx).ok();

            if x.panes > 1 {
                if let Some(ps) = panes_by_win.get(&(x.session.as_str(), x.idx.as_str())) {
                    for (j, pn) in ps.iter().enumerate() {
                        let plast = j + 1 == ps.len();
                        let pcur = wcur && pn.idx == current_pane;
                        let mut ident =
                            render::pane_ident(&sdisp, &pn.widx, &pn.idx, cont, plast, pcur, &w, &p);
                        let ctx = render::ctx_field(
                            &pn.path, false, false, false, &w, &p, &home, &mut git, show_git,
                        );
                        let (cmd, state) = cmd_field(&pn.cmd, pn.pid, Some(pn), &mut res);
                        if agents_view {
                            if let Some(m) = agent::view_mark(&state, &pn.id, &mut marked, &p) {
                                ident = render::with_gutter(&ident, pcur, &m, &p);
                            }
                        }
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
        // ...under whatever spelling (dirs::canon_dir, as bash's emit_dir_rows).
        let taken: std::collections::HashSet<String> =
            session_dirs.iter().map(|s| dirs::canon_dir(s)).collect();
        let mut n = 0;
        for d in dirs::candidates() {
            if n >= limit {
                break;
            }
            if d.contains('\t')
                || session_dirs.contains(&d)
                || taken.contains(&dirs::canon_dir(&d))
            {
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

fn out_flush<W: Write>(w: &mut W) {
    let _ = w.flush();
}

