//! Lines tmux cut short.
//!
//! tmux 3.7b gives every list-* line a 100 ms wall-clock budget (format.c,
//! FORMAT_TIME_LIMIT) and, when the server is descheduled for that long in the
//! middle of one, returns the line cut at the next `#{` -- `s^_0^_zsh^_1^_zsh^_`
//! -- with no error.  The parsers used to demand exactly 9 (window) / 8 (pane)
//! fields and a session name in field 2, so a cut line silently dropped its
//! window, pane or whole session.  The shapes below are the ones observed on a
//! real server under SIGSTOP (every cut ends in the separator that preceded the
//! `#{` it stopped at).
//!
//! A separate file from golden.rs, which pins layout; this pins which rows exist.

use std::io::Write;
use std::process::{Command, Stdio};

const US: &str = "\u{1f}";

fn render(dump: &str, extra: &[(&str, &str)]) -> String {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_imux"));
    cmd.arg("gather3")
        .env_clear()
        .env("HOME", "/home/u")
        .env("PATH", "/usr/bin:/bin")
        .env("INTERDIMUX_NOW", "1700086400")
        .env("INTERDIMUX_COLS", "160")
        .env("INTERDIMUX_SHOW_FULL_COMMAND", "off")
        .env("INTERDIMUX_SHOW_GIT_BRANCH", "off")
        .env("INTERDIMUX_SHOW_DIRS", "off");
    for (k, v) in extra {
        cmd.env(k, v);
    }
    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn imux");
    child.stdin.as_mut().unwrap().write_all(dump.as_bytes()).unwrap();
    let out = child.wait_with_output().expect("run imux");
    assert!(out.status.success(), "imux exited {:?}", out.status);
    assert!(out.stderr.is_empty(), "imux wrote to stderr: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn line(fields: &[&str]) -> String {
    fields.join(US)
}

/// sessions / windows / panes / current / (no) registry, framed exactly as
/// bash sends them
fn dump(sessions: &[String], windows: &[String], panes: &[String]) -> String {
    format!(
        "{}\n\u{1e}\n{}\n\u{1e}\n{}\n\u{1e}\ncur{US}9{US}9\n\u{1e}\n",
        sessions.join("\n"),
        windows.join("\n"),
        panes.join("\n"),
    )
}

fn specs(out: &str) -> Vec<String> {
    out.lines().map(|l| l.split('\t').nth(3).unwrap_or("").to_string()).collect()
}

fn strip(s: &str) -> String {
    let mut o = String::new();
    let mut esc = false;
    for c in s.chars() {
        if esc {
            if c == 'm' {
                esc = false
            }
        } else if c == '\x1b' {
            esc = true
        } else {
            o.push(c)
        }
    }
    o
}

/// The row whose spec is `spec`, split into its four fields, ANSI stripped.
fn row(out: &str, spec: &str) -> Option<Vec<String>> {
    out.lines()
        .find(|l| l.split('\t').nth(3) == Some(spec))
        .map(|l| l.split('\t').map(strip).collect())
}

fn sess(name: &str, ts: &str) -> String {
    line(&[name, ts, "1", ""])
}
fn win(s: &str, idx: &str, name: &str, active: &str, cmd: &str, path: &str, panes: &str, pid: &str) -> String {
    line(&[s, idx, name, active, cmd, path, panes, pid, "000"])
}

#[test]
fn a_window_line_cut_after_its_command_still_renders_the_window() {
    let d = dump(
        &[sess("s", "1700000000")],
        &[
            // cut before #{pane_current_path}: 5 fields and the trailing US
            format!("{}{US}", line(&["s", "0", "editor", "1", "nvim"])),
            win("s", "1", "shell", "0", "zsh", "/home/u", "1", "0"),
        ],
        &[],
    );
    let out = render(&d, &[]);
    assert_eq!(specs(&out), vec!["S:s", "W:s:0", "W:s:1"], "{}", out);
    let r = row(&out, "W:s:0").unwrap();
    assert!(r[0].contains("0:editor"), "the window keeps its name: {:?}", r);
    assert_eq!(r[2].trim(), "nvim", "and the command it did carry: {:?}", r);
}

#[test]
fn a_window_line_cut_before_its_command_still_renders_the_window() {
    let d = dump(
        &[sess("s", "1700000000")],
        &[format!("{}{US}", line(&["s", "0", "editor", "1"]))],
        &[],
    );
    assert_eq!(specs(&render(&d, &[])), vec!["S:s", "W:s:0"]);
}

#[test]
fn a_pane_line_cut_after_its_command_still_renders_the_pane() {
    let d = dump(
        &[sess("s", "1700000000")],
        &[win("s", "0", "split", "1", "zsh", "/home/u", "2", "0")],
        &[
            format!("{}{US}", line(&["s", "0", "0", "1", "nvim"])),
            line(&["s", "0", "1", "0", "zsh", "/home/u", "0", "2"]),
        ],
    );
    let out = render(&d, &[]);
    assert_eq!(specs(&out), vec!["S:s", "W:s:0", "P:s:0:0", "P:s:0:1"], "{}", out);
}

#[test]
fn a_session_line_cut_after_its_name_keeps_the_session_and_its_windows() {
    let d = dump(
        &[
            sess("first", "1700000300"),
            format!("cut{US}"), // cut before the timestamp
            sess("last", "1700000100"),
        ],
        &[
            win("first", "0", "a", "1", "zsh", "/home/u", "1", "0"),
            win("cut", "0", "b", "1", "zsh", "/home/u", "1", "0"),
            win("last", "0", "c", "1", "zsh", "/home/u", "1", "0"),
        ],
        &[],
    );
    let out = render(&d, &[]);
    let s = specs(&out);
    assert!(s.contains(&"S:cut".to_string()), "the cut session vanished: {:?}", s);
    assert!(s.contains(&"W:cut:0".to_string()), "...and took its window with it: {:?}", s);
    // no timestamp sorts as 0: last, for this one paint (bash sorts it the same)
    assert_eq!(s.iter().filter(|x| x.starts_with("S:")).collect::<Vec<_>>(), vec!["S:first", "S:last", "S:cut"]);
}

/// The pid is the one field that reaches /proc.  A short line never supplies
/// it, even when the position is populated: the line below carries THIS test
/// process's pid where pane_pid would be, and with full-command resolution on
/// the row must show tmux's own command, not our argv.
#[test]
fn a_short_line_never_has_its_pid_read() {
    let me = std::process::id().to_string();
    let d = dump(
        &[sess("s", "1700000000")],
        &[
            // 9 fields, cut before the flags: the pid position is filled
            format!("{}{US}", line(&["s", "0", "w", "1", "zsh", "/home/u", "2", &me])),
        ],
        &[
            // 8 fields, cut before window_panes
            format!("{}{US}", line(&["s", "0", "0", "1", "vim", "/home/u", &me])),
            line(&["s", "0", "1", "0", "zsh", "/home/u", "0", "2"]),
        ],
    );
    let out = render(&d, &[("INTERDIMUX_SHOW_FULL_COMMAND", "on")]);
    let w = row(&out, "W:s:0").expect("the window row");
    assert_eq!(w[2].trim(), "zsh", "a short window line's pid was read: {:?}", w);
    // ...and a short window line counts as one pane: its count is gone too
    assert!(row(&out, "P:s:0:0").is_none(), "{}", out);

    // A control: the SAME pid on a whole line IS resolved, so the probe works.
    let d = dump(
        &[sess("s", "1700000000")],
        &[win("s", "0", "w", "1", "zsh", "/home/u", "1", &me)],
        &[],
    );
    let out = render(&d, &[("INTERDIMUX_SHOW_FULL_COMMAND", "on")]);
    let w = row(&out, "W:s:0").expect("the window row");
    assert_ne!(w[2].trim(), "zsh", "control: a whole line's pid should resolve to our argv: {:?}", w);
}

#[test]
fn a_short_pane_line_never_has_its_pid_read() {
    let me = std::process::id().to_string();
    let d = dump(
        &[sess("s", "1700000000")],
        &[win("s", "0", "w", "1", "zsh", "/home/u", "2", "0")],
        &[
            format!("{}{US}", line(&["s", "0", "0", "1", "vim", "/home/u", &me])),
            line(&["s", "0", "1", "0", "zsh", "/home/u", "0", "2"]),
        ],
    );
    let out = render(&d, &[("INTERDIMUX_SHOW_FULL_COMMAND", "on")]);
    let p = row(&out, "P:s:0:0").expect("the pane row");
    assert_eq!(p[2].trim(), "vim", "a short pane line's pid was read: {:?}", p);
}

/// A newline inside a pane cwd splits ONE line into two, and both halves are
/// short.  The first half is a genuine (cut) window; the second --
/// `<path tail>^_<panes>^_<pid>^_<flags>` -- must not become a window of some
/// session that happens to be called like the path's tail.
#[test]
fn the_tail_of_a_newline_split_line_is_not_a_window() {
    let d = dump(
        &[sess("s", "1700000000"), sess("b", "1699999000")],
        &[
            line(&["s", "0", "w", "1", "zsh", "/tmp/a"]),
            line(&["b", "1", "4242", "000"]),
            win("b", "0", "real", "1", "zsh", "/home/u", "1", "0"),
        ],
        &[
            // the pane-section equivalent: `<tail>^_<pid>^_<window_panes>`
            line(&["b", "4242", "2"]),
        ],
    );
    let out = render(&d, &[]);
    assert_eq!(specs(&out), vec!["S:s", "W:s:0", "S:b", "W:b:0"], "{}", out);
    assert!(!out.contains("4242"), "a fragment's field was rendered: {}", out);
}

/// Cut before #{window_active} (3 fields kept) or before #{window_name} (2):
/// the line ends in the separator, and that mark -- not a 0/1 in the active
/// field, which a cut this early never reached -- is what makes it a window.
#[test]
fn a_window_line_cut_before_its_active_flag_still_renders_the_window() {
    for kept in [vec!["s", "0", "editor"], vec!["s", "0"]] {
        let d = dump(
            &[sess("s", "1700000000")],
            &[
                format!("{}{US}", line(&kept)),
                win("s", "1", "shell", "0", "zsh", "/home/u", "1", "0"),
            ],
            &[],
        );
        let out = render(&d, &[]);
        assert_eq!(specs(&out), vec!["S:s", "W:s:0", "W:s:1"], "cut after {:?}: {}", kept, out);
    }
}

#[test]
fn a_pane_line_cut_before_its_active_flag_still_renders_the_pane() {
    let d = dump(
        &[sess("s", "1700000000")],
        &[win("s", "0", "split", "1", "zsh", "/home/u", "2", "0")],
        &[
            format!("{}{US}", line(&["s", "0", "0"])),
            line(&["s", "0", "1", "0", "zsh", "/home/u", "0", "2"]),
        ],
    );
    let out = render(&d, &[]);
    assert_eq!(specs(&out), vec!["S:s", "W:s:0", "P:s:0:0", "P:s:0:1"], "{}", out);
}

/// The tail a newline in a PANE cwd leaves, `<tail>^_<pid>^_<window_panes>`,
/// is three fields, numeric in the second and third, with no fourth -- the
/// shape of a pane line cut before #{pane_active}, minus the trailing
/// separator.  Accepting any empty pane_active would file it as pane 2 of the
/// window whose index equals that pid; here that window exists and has two
/// panes, so the phantom would be drawn.
#[test]
fn the_tail_of_a_newline_split_pane_line_is_not_a_pane() {
    let d = dump(
        &[sess("b", "1700000000")],
        &[win("b", "4242", "real", "1", "zsh", "/home/u", "2", "0")],
        &[
            line(&["b", "4242", "2"]),
            line(&["b", "4242", "0", "1", "zsh", "/home/u", "0", "2"]),
            format!("{}{US}", line(&["b", "4242", "1"])), // a genuine cut
        ],
    );
    let out = render(&d, &[]);
    assert_eq!(specs(&out), vec!["S:b", "W:b:4242", "P:b:4242:0", "P:b:4242:1"], "{}", out);
}
