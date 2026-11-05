//! Exercise the common controller against private tmux servers and a deterministic fzf.
#![cfg(unix)]

use std::fs::{self, File};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct Fixture {
    inner: String,
    outer: String,
    dir: PathBuf,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        for name in [&self.outer, &self.inner] {
            let _ = Command::new("tmux")
                .args(["-L", name, "kill-server"])
                .env_remove("TMUX")
                .output();
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

impl Fixture {
    fn command(&self, outer: bool) -> Command {
        let mut command = Command::new("tmux");
        command.args(["-L", if outer { &self.outer } else { &self.inner }]);
        command.env_remove("TMUX").env_remove("TMUX_PANE");
        command
    }

    fn tmux(&self, args: &[&str]) -> String {
        success(self.command(false).args(args).output().unwrap())
    }

    fn socket(&self) -> String {
        self.tmux(&["display-message", "-p", "#{socket_path}"])
            .trim()
            .into()
    }

    fn driver(&self, verb: &str, client: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_imux"));
        command.args([
            verb,
            "--backend",
            "tmux",
            "--socket",
            &self.socket(),
            "--client",
            client,
        ]);
        command
            .env_remove("TMUX")
            .env_remove("TMUX_PANE")
            .env_remove("INTERDIMUX_CLIENT")
            .env("INTERDIMUX_ORDER", "index")
            .env("INTERDIMUX_COLS", "160")
            .env("INTERDIMUX_FZF_BIN", self.dir.join("fzf"));
        command
    }

    fn token(&self, client: &str, needle: &str) -> String {
        let rows = success(self.driver("list", client).output().unwrap());
        rows.lines()
            .find(|line| {
                plain(line)
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .contains(needle)
            })
            .unwrap_or_else(|| panic!("no row matching {needle:?}: {rows:?}"))
            .rsplit('\t')
            .next()
            .unwrap()
            .into()
    }

    fn pick(&self, client: &str, mode: &str, token: &str) -> Output {
        let stdout = self.dir.join("stdout");
        let stderr = self.dir.join("stderr");
        let mut child = self
            .driver("pick", client)
            .env("IMUX_TEST_MODE", mode)
            .env("IMUX_TEST_TOKEN", token)
            .env("IMUX_TEST_SOCKET", self.socket())
            .stdin(Stdio::null())
            .stdout(File::create(&stdout).unwrap())
            .stderr(File::create(&stderr).unwrap())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("the shared navigator did not finish");
            }
            thread::sleep(Duration::from_millis(20));
        };
        Output {
            status,
            stdout: fs::read(stdout).unwrap(),
            stderr: fs::read(stderr).unwrap(),
        }
    }

    fn client_session(&self, client: &str) -> String {
        self.tmux(&[
            "display-message",
            "-p",
            "-t",
            &format!("={client}:"),
            "#{session_name}",
        ])
        .trim()
        .into()
    }
}

fn success(output: Output) -> String {
    assert!(
        output.status.success(),
        "command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap()
}

fn plain(text: &str) -> String {
    let mut output = String::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            for c in chars.by_ref() {
                if c.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            output.push(c);
        }
    }
    output
}

fn write_executable(path: &Path, text: &str) {
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

#[test]
fn common_picker_switches_native_targets_and_rejects_reused_indices() {
    let Ok(version) = Command::new("tmux").arg("-V").output() else {
        eprintln!("tmux is unavailable; skipping the private-server integration test");
        return;
    };
    let version = String::from_utf8_lossy(&version.stdout);
    let digits: Vec<_> = version
        .split(|c: char| !c.is_ascii_digit())
        .filter(|s| !s.is_empty())
        .filter_map(|s| s.parse::<u32>().ok())
        .collect();
    if digits.len() < 2 || (digits[0], digits[1]) < (3, 6) {
        eprintln!("tmux 3.6 or newer is required; skipping the private-server integration test");
        return;
    }
    let suffix = format!(
        "{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    );
    let fixture = Fixture {
        inner: format!("imux-nav-{suffix}"),
        outer: format!("imux-nav-outer-{suffix}"),
        dir: std::env::temp_dir().join(format!("imux-nav-{suffix}")),
    };
    fs::create_dir(&fixture.dir).unwrap();
    fs::set_permissions(&fixture.dir, fs::Permissions::from_mode(0o700)).unwrap();
    fixture.tmux(&[
        "-f",
        "/dev/null",
        "new-session",
        "-d",
        "-s",
        "home",
        "-n",
        "home",
        "-x",
        "160",
        "-y",
        "40",
        "sleep 99999",
    ]);
    fixture.tmux(&["set-option", "-g", "default-shell", "/bin/sh"]);
    fixture.tmux(&["set-option", "-g", "renumber-windows", "off"]);
    fixture.tmux(&["set-option", "-g", "base-index", "0"]);
    fixture.tmux(&["set-window-option", "-g", "pane-base-index", "0"]);
    for name in ["work", "other"] {
        let first_name = if name == "work" {
            "work-first"
        } else {
            "first"
        };
        fixture.tmux(&[
            "new-session",
            "-d",
            "-s",
            name,
            "-n",
            first_name,
            "sleep 99999",
        ]);
    }
    let first_window = fixture
        .tmux(&["display-message", "-p", "-t", "=work:0", "#{window_id}"])
        .trim()
        .to_owned();
    let picked_window = fixture
        .tmux(&[
            "new-window",
            "-d",
            "-t",
            "=work:2",
            "-n",
            "pick-window",
            "-P",
            "-F",
            "#{window_id}",
            "sleep 99999",
        ])
        .trim()
        .to_owned();
    let picked_pane = fixture
        .tmux(&[
            "split-window",
            "-d",
            "-h",
            "-t",
            &picked_window,
            "-P",
            "-F",
            "#{pane_id}",
            "sleep 99999",
        ])
        .trim()
        .to_owned();
    success(
        fixture
            .command(true)
            .args([
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                "viewer",
                "-x",
                "160",
                "-y",
                "40",
                &format!("TMUX= tmux -L {} attach-session -t '=home:'", fixture.inner),
            ])
            .output()
            .unwrap(),
    );
    success(
        fixture
            .command(true)
            .args([
                "new-window",
                "-d",
                "-t",
                "viewer",
                "-n",
                "second",
                &format!(
                    "TMUX= tmux -L {} attach-session -t '=other:'",
                    fixture.inner
                ),
            ])
            .output()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    let (client, other_client) = loop {
        let clients = fixture.tmux(&[
            "list-clients",
            "-F",
            "#{client_name}\u{1f}#{client_session}",
        ]);
        let find = |session| {
            clients.lines().find_map(|line| {
                let (client, name) = line.split_once('\u{1f}')?;
                (name == session).then(|| client.to_owned())
            })
        };
        if let (Some(a), Some(b)) = (find("home"), find("other")) {
            break (a, b);
        }
        assert!(
            Instant::now() < deadline,
            "private tmux clients did not attach"
        );
        thread::sleep(Duration::from_millis(20));
    };
    write_executable(
        &fixture.dir.join("fzf"),
        r#"#!/bin/sh
picked=
while IFS= read -r line; do
    case "$line" in *"$IMUX_TEST_TOKEN") picked=$line ;; esac
done
case "$IMUX_TEST_MODE" in
    cancel) exit 130 ;;
    nomatch) exit 1 ;;
    swap)
        tmux -S "$IMUX_TEST_SOCKET" swap-pane -d -s '=work:2.0' -t '=work:2.1' || exit 2
        ;;
    reuse)
        tmux -S "$IMUX_TEST_SOCKET" kill-window -t '=work:2' || exit 2
        tmux -S "$IMUX_TEST_SOCKET" new-window -d -t '=work:2' -n replacement 'sleep 99999' || exit 2
        ;;
esac
[ -n "$picked" ] || exit 1
printf '%s\n' "$picked"
"#,
    );
    success(fixture.pick(&client, "cancel", "unused"));
    assert_eq!(fixture.client_session(&client), "home");
    success(fixture.pick(&client, "nomatch", "unused"));
    assert_eq!(fixture.client_session(&client), "home");
    let pane_token = fixture.token(&client, "1: sleep");
    success(fixture.pick(&client, "swap", &pane_token));
    assert_eq!(fixture.client_session(&client), "work");
    assert_eq!(
        fixture
            .tmux(&[
                "display-message",
                "-p",
                "-t",
                "=work:",
                "#{window_id}\u{1f}#{pane_id}"
            ])
            .trim(),
        format!("{picked_window}\u{1f}{picked_pane}")
    );
    let window_token = fixture.token(&client, "work-first");
    success(fixture.pick(&client, "select", &window_token));
    assert_eq!(
        fixture
            .tmux(&["display-message", "-p", "-t", "=work:", "#{window_id}"])
            .trim(),
        first_window
    );
    let home_token = fixture.token(&client, "home");
    success(fixture.pick(&client, "select", &home_token));
    assert_eq!(fixture.client_session(&client), "home");
    let stale_token = fixture.token(&client, "pick-window");
    let stale = fixture.pick(&client, "reuse", &stale_token);
    assert!(
        !stale.status.success(),
        "a reused window index must not become the accepted target"
    );
    assert!(String::from_utf8_lossy(&stale.stderr).contains("no longer exists"));
    assert_eq!(fixture.client_session(&client), "home");
    assert_eq!(fixture.client_session(&other_client), "other");
    assert_ne!(
        fixture
            .tmux(&["display-message", "-p", "-t", "=work:2", "#{window_id}"])
            .trim(),
        picked_window
    );
}
