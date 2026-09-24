//! A directory that already has a session is not offered as a `D:` row, and a
//! session's directory is where it was STARTED (#{session_path}, the fifth
//! field of the session line) -- not only where its active pane happens to be.
//! A `cd src` inside the project used to bring the project's own row back as a
//! "new session" suggestion.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

const US: &str = "\u{1f}";

fn tmp(tag: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!("imux-sessdirs-{}-{}", tag, std::process::id()));
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).unwrap();
    p
}

/// Render with directory rows on, the recent list holding `recent`.
fn d_rows(root: &PathBuf, dump: &str, recent: &[&str]) -> Vec<String> {
    let data = root.join("data");
    std::fs::create_dir_all(data.join("interdimux")).unwrap();
    std::fs::write(data.join("interdimux/recent_dirs"), recent.join("\n") + "\n").unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_imux"))
        .arg("gather")
        .env_clear()
        .env("HOME", "/home/u")
        .env("PATH", "/usr/bin:/bin")
        .env("XDG_DATA_HOME", &data)
        .env("INTERDIMUX_NOW", "1700086400")
        .env("INTERDIMUX_COLS", "160")
        .env("INTERDIMUX_SHOW_FULL_COMMAND", "off")
        .env("INTERDIMUX_SHOW_GIT_BRANCH", "off")
        .env("INTERDIMUX_SHOW_DIRS", "on")
        .env("INTERDIMUX_USE_ZOXIDE", "off")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("spawn imux");
    child.stdin.as_mut().unwrap().write_all(dump.as_bytes()).unwrap();
    let out = child.wait_with_output().expect("run imux");
    assert!(out.status.success());
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.split('\t').nth(3))
        .filter_map(|s| s.strip_prefix("D:"))
        .map(str::to_string)
        .collect()
}

#[test]
fn a_sessions_start_directory_is_not_offered_again_after_a_cd() {
    let root = tmp("cd");
    let (web, other) = (root.join("web"), root.join("other"));
    std::fs::create_dir_all(web.join("src")).unwrap();
    std::fs::create_dir_all(&other).unwrap();
    let (web, other) = (web.to_str().unwrap(), other.to_str().unwrap());
    // session `web` was started in web/ and its only pane has since cd'd to src/
    let dump = format!(
        "web{US}1700000000{US}1{US}{US}{web}\n\u{1e}\n\
         web{US}0{US}bash{US}1{US}bash{US}{web}/src{US}1{US}0{US}000\n\u{1e}\n\u{1e}\nx{US}0{US}0\n"
    );
    let got = d_rows(&root, &dump, &[web, other]);
    assert_eq!(got, vec![other.to_string()], "web was re-offered after a cd");
    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn a_unit_separator_inside_the_start_directory_stays_in_it() {
    let root = tmp("us");
    let odd = root.join("we\u{1f}ird");
    std::fs::create_dir_all(&odd).unwrap();
    let odd = odd.to_str().unwrap();
    let dump = format!(
        "odd{US}1700000000{US}1{US}{US}{odd}\n\u{1e}\n\u{1e}\n\u{1e}\nx{US}0{US}0\n"
    );
    let got = d_rows(&root, &dump, &[odd]);
    assert!(got.is_empty(), "the session's own directory was offered: {:?}", got);
    std::fs::remove_dir_all(&root).ok();
}
