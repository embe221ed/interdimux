//! rust/README.md's "The boundary" is what a developer builds against, so
//! what it says of the protocol is checked against what this binary does:
//! the subcommand it names must be one the binary renders for, and the input
//! sections it lists must be as many as the binary reads.  (It named
//! `imux gather2` and four sections for a while after both had changed.)
//! The oracle is the binary's exit status: 0 renders, 2 is an unknown
//! subcommand, 3 a framing it does not accept.

use std::io::Write;
use std::process::{Command, Stdio};

fn readme() -> String {
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/README.md");
    std::fs::read_to_string(p).expect("rust/README.md").replace('\n', " ")
}

/// Exit status of `imux <sub>` fed `n` empty sections.
fn status(sub: &str, n: usize) -> Option<i32> {
    let dump = vec![""; n].join("\n\u{1e}\n") + "\n";
    let mut child = Command::new(env!("CARGO_BIN_EXE_imux"))
        .arg(sub)
        .env_clear()
        .env("HOME", "/home/u")
        .env("PATH", "/usr/bin:/bin")
        .env("INTERDIMUX_NOW", "1700086400")
        .env("INTERDIMUX_COLS", "120")
        .env("INTERDIMUX_SHOW_DIRS", "off")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn imux");
    // a refusing binary may exit before reading: a broken pipe is fine here
    let _ = child.stdin.as_mut().unwrap().write_all(dump.as_bytes());
    child.wait().expect("run imux").code()
}

#[test]
fn the_boundary_names_the_subcommand_and_the_sections_this_binary_reads() {
    let text = readme();
    let at = text.find("`imux gather").expect("the README names the subcommand");
    let sub: String = text[at + "`imux ".len()..].chars().take_while(|&c| c != '`').collect();
    let at = text.find("in the order ").expect("the README lists the sections in order");
    let list = text[at + "in the order ".len()..].split(':').next().unwrap_or("");
    let n = list.split(" / ").count();
    assert_eq!(status(&sub, n), Some(0), "imux {} with the README's {} sections ({})", sub, n, list.trim());
    // and the check can fail: one section fewer is refused
    assert_eq!(status(&sub, n - 1), Some(3));
}
