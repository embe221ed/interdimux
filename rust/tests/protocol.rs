//! The stdin protocol's version is the subcommand's name.
//!
//! bash runs `imux gather3` (IMUX_PROTO in scripts/interdimux.sh).  A binary and
//! a script from different versions of interdimux must fail CLOSED -- exit 2,
//! nothing on stdout -- in both directions, because the script's fallback is
//! keyed on exactly that: a binary that exits 0 is believed.  Before the name
//! carried the version, a binary older than the script read the new session
//! line with the old field positions and printed every session named by its
//! timestamp, with exit 0 (tests/test_core_protocol.sh drives that case through
//! the script).  These are the binary's half: it renders only for `gather3`,
//! and refuses `gather` and `gather2` -- what OLDER scripts send, `gather`
//! with the session name in field 2, `gather2` with four sections and no
//! pane id or title -- rather than read them as the new layout.

use std::io::Write;
use std::process::{Command, Stdio};

const US: &str = "\u{1f}";

fn run(sub: &str, dump: &str) -> (Option<i32>, String, String) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_imux"))
        .arg(sub)
        .env_clear()
        .env("HOME", "/home/u")
        .env("PATH", "/usr/bin:/bin")
        .env("INTERDIMUX_NOW", "1700086400")
        .env("INTERDIMUX_COLS", "120")
        .env("INTERDIMUX_SHOW_FULL_COMMAND", "off")
        .env("INTERDIMUX_SHOW_GIT_BRANCH", "off")
        .env("INTERDIMUX_SHOW_DIRS", "off")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn imux");
    // A refusing binary may exit before reading: a broken pipe is fine here.
    let _ = child.stdin.as_mut().unwrap().write_all(dump.as_bytes());
    let out = child.wait_with_output().expect("run imux");
    (
        out.status.code(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

fn specs(out: &str) -> Vec<&str> {
    out.lines().map(|l| l.rsplit('\t').next().unwrap_or("")).collect()
}

/// One session `work` (last attached at 1700000000) with one window, framed as
/// the CURRENT script sends it: the name first, #{session_path} last.
fn current_dump() -> String {
    format!(
        "work{US}1700000000{US}1{US}{US}/home/u\n\u{1e}\n\
         work{US}0{US}shell{US}1{US}zsh{US}/home/u{US}1{US}0{US}000\n\u{1e}\n\
         work{US}0{US}0{US}1{US}zsh{US}/home/u{US}0{US}1\n\u{1e}\n\
         work{US}0{US}0\n\u{1e}\n"
    )
}

/// The same server as an OLDER script sends it: the timestamp first.
fn old_dump() -> String {
    format!(
        "1700000000{US}work{US}1{US}\n\u{1e}\n\
         work{US}0{US}shell{US}1{US}zsh{US}/home/u{US}1{US}0{US}000\n\u{1e}\n\
         work{US}0{US}0{US}1{US}zsh{US}/home/u{US}0{US}1\n\u{1e}\n\
         work{US}0{US}0\n\u{1e}\n"
    )
}

#[test]
fn gather3_is_the_protocol_the_script_speaks() {
    let (code, out, err) = run("gather3", &current_dump());
    assert_eq!(code, Some(0), "stderr: {}", err);
    assert_eq!(specs(&out), vec!["S:work", "W:work:0"], "{}", out);
}

#[test]
fn an_older_scripts_gather_is_refused_not_misread() {
    // Read as the new layout, this line is a session NAMED 1700000000 with no
    // windows -- the mirror image of the bug.  It must not be rendered at all.
    let (code, out, err) = run("gather", &old_dump());
    assert_eq!(code, Some(2), "an older script's subcommand was accepted: {}", out);
    assert!(out.is_empty(), "a refused protocol printed rows: {}", out);
    assert!(err.contains("gather3"), "the refusal should name the protocol it speaks: {}", err);
}

#[test]
fn a_newer_scripts_protocol_is_refused_too() {
    let (code, out, _) = run("gather4", &current_dump());
    assert_eq!(code, Some(2));
    assert!(out.is_empty(), "{}", out);
}

#[test]
fn the_previous_protocol_is_refused() {
    // gather2 sent four sections and pane lines with no id or title
    let (code, out, _) = run("gather2", &current_dump());
    assert_eq!(code, Some(2));
    assert!(out.is_empty(), "{}", out);
}
