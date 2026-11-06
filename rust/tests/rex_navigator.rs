//! The real Rust controller with fake transport and chooser processes. No Rex
//! installation or live server is involved, and each child owns its environment.
#![cfg(unix)]

use serde_json::{json, Value};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "imux-rex-navigator-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
        ));
        fs::create_dir(&root).unwrap();
        fs::write(root.join("snapshot.json"), snapshot().to_string()).unwrap();
        let fixture = Self { root };
        fixture.executable(
            "rex",
            r#"#!/bin/sh
set -eu
# The surrounding Rex terminal must not redirect this transport connection.
[ "${REX_SESSION+x}" != x ] && [ "${REX_BLOCK+x}" != x ] && [ "${REX_CLIENT+x}" != x ]
printf 'BEGIN\n' >> "$IMUX_TEST_CALLS"
for arg in "$@"; do printf 'ARG=%s\n' "$arg" >> "$IMUX_TEST_CALLS"; done
script=$(cat)
case "$script" in
  *client.perform*)
    printf 'SCRIPT=ACTIVATE\n' >> "$IMUX_TEST_CALLS"
    printf '{}\n'
    ;;
  *session.attach_all*)
    printf 'SCRIPT=SNAPSHOT\n' >> "$IMUX_TEST_CALLS"
    cat "$IMUX_TEST_SNAPSHOT"
    ;;
  *) printf 'unknown embedded script\n' >&2; exit 2 ;;
esac
printf 'END\n' >> "$IMUX_TEST_CALLS"
"#,
        );
        fixture.executable(
            "fzf",
            r#"#!/bin/sh
set -eu
# The switch-only controller must isolate global fzf callbacks and commands.
[ "${FZF_DEFAULT_OPTS+x}" != x ]
[ "${FZF_DEFAULT_OPTS_FILE+x}" != x ]
[ "${FZF_DEFAULT_COMMAND+x}" != x ]
printf '%s\n' "$@" > "$IMUX_TEST_FZF_ARGS"
cat > "$IMUX_TEST_ROWS"
case "$IMUX_TEST_MODE" in
  select) awk 'NR == 4 { print; exit }' "$IMUX_TEST_ROWS" ;;
  singleton) awk 'NR == 6 { print; exit }' "$IMUX_TEST_ROWS" ;;
  cancel) exit 130 ;;
  nomatch) exit 1 ;;
  empty) exit 0 ;;
  failure) exit 2 ;;
  *) exit 3 ;;
esac
"#,
        );
        fixture
    }

    fn executable(&self, name: &str, source: &str) {
        let path = self.root.join(name);
        fs::write(&path, source).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }

    fn run(&self, subcommand: &str, mode: &str) -> Output {
        self.run_with_files(subcommand, mode, false)
    }

    fn run_with_files(&self, subcommand: &str, mode: &str, hosted: bool) -> Output {
        self.command(subcommand, mode, hosted).output().unwrap()
    }

    fn command(&self, subcommand: &str, mode: &str, hosted: bool) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_imux"));
        command
            .args([
                subcommand,
                "--backend",
                "rex",
                "--client",
                "client:initiating-app",
                "--session",
                "session:one",
                "--window",
                "window:one",
                "--block",
                "block:origin",
                "--origin-zoom",
                "block:origin",
                "--server",
                "unix:///tmp/rex test.sock",
            ])
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", &self.root)
            .env("TERM", "xterm-256color")
            .env("INTERDIMUX_REX_BIN", self.root.join("rex"))
            .env("INTERDIMUX_FZF_BIN", self.root.join("fzf"))
            .env("INTERDIMUX_ORDER", "normal")
            .env("INTERDIMUX_SESSION_RULE", "off")
            .env("INTERDIMUX_COLS", "120")
            .env("REX_BLOCK", "block:picker")
            .env("REX_SESSION", "session:inherited-but-wrong")
            .env("REX_CLIENT", "client:inherited-but-wrong")
            .env("FZF_DEFAULT_OPTS", "--bind=change:abort")
            .env("FZF_DEFAULT_OPTS_FILE", "/not/a/config")
            .env("FZF_DEFAULT_COMMAND", "an-unrelated-command")
            .env("IMUX_TEST_MODE", mode)
            .env("IMUX_TEST_CALLS", self.root.join("calls"))
            .env("IMUX_TEST_SNAPSHOT", self.root.join("snapshot.json"))
            .env("IMUX_TEST_FZF_ARGS", self.root.join("fzf-args"))
            .env("IMUX_TEST_ROWS", self.root.join("rows"))
            .stdin(Stdio::null());
        if hosted {
            command
                .arg("--snapshot")
                .arg(self.root.join("snapshot.json"))
                .arg("--result")
                .arg(self.root.join("result.json"));
        }
        command
    }

    fn calls(&self) -> Vec<String> {
        fs::read_to_string(self.root.join("calls"))
            .unwrap()
            .split("BEGIN\n")
            .skip(1)
            .map(str::to_owned)
            .collect()
    }

    fn activation(&self) -> (String, Value) {
        let calls = self.calls();
        assert_eq!(calls.len(), 2, "one snapshot and one activation: {calls:?}");
        assert_eq!(
            calls
                .iter()
                .filter(|c| c.contains("SCRIPT=SNAPSHOT"))
                .count(),
            1
        );
        let activation = calls
            .into_iter()
            .find(|c| c.contains("SCRIPT=ACTIVATE"))
            .unwrap();
        let args = activation
            .lines()
            .find_map(|line| {
                line.strip_prefix("ARG={")
                    .map(|rest| serde_json::from_str(&format!("{{{rest}")).unwrap())
            })
            .unwrap();
        (activation, args)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn snapshot() -> Value {
    json!({"version":1,
        "sessions":[
            {"session_id":"session:two","label":"duplicate"},
            {"session_id":"session:one","label":"duplicate"}
        ],
        "views":{
            "session:two":{"active_window_id":"window:two","windows":[{
                "window_id":"window:two","label":"duplicate","focused_block_id":"block:two-a",
                "layers":[{"kind":"tiled","blocks":[
                    {"block_id":"block:two-a","label":"shell"},
                    {"block_id":"block:two-b","label":"shell"}
                ]}]
            }]},
            "session:one":{"active_window_id":"window:one","windows":[{
                "window_id":"window:one","label":"duplicate","focused_block_id":"block:picker",
                "layers":[
                    {"kind":"tiled","blocks":[{"block_id":"block:origin","label":"shell"}]},
                    {"kind":"floating","blocks":[{"block_id":"block:picker","label":"interdimux"}]}
                ]
            }]}
        }, "errors":{}
    })
}

#[test]
fn direct_session_jumps_collect_only_the_catalog_and_preserve_ordering() {
    for (number, order, hidden, expected) in [
        ("1", "normal", "", "session:three"),
        ("2", "normal", "", "session:two"),
        ("3", "normal", "", "session:one"),
        ("1", "index", "", "session:two"),
        ("1", "normal", "third", "session:two"),
        ("1", "normal", "*", "session:one"),
    ] {
        let fixture = Fixture::new();
        fs::write(
            fixture.root.join("snapshot.json"),
            json!({
                "version":1, "sessions_only":true,
                "sessions":[{"session_id":"session:two","label":"second"},
                    {"session_id":"session:one","label":"origin"},
                    {"session_id":"session:three","label":"third"}],
                "views":{}, "metadata":{},
                "mru":{"session:one":100,"session:two":20,"session:three":30}
            })
            .to_string(),
        )
        .unwrap();
        let output = fixture
            .command("jump", "unused", false)
            .arg(number)
            .env_remove("REX_BLOCK")
            .env("INTERDIMUX_ORDER", order)
            .env("INTERDIMUX_HIDE", hidden)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let (_, selected) = fixture.activation();
        assert_eq!(selected["session_id"], expected);
        assert!(selected.get("window_id").is_none() && selected.get("block_id").is_none());
        let calls = fixture.calls();
        let args: Value = calls[0]
            .lines()
            .find_map(|line| {
                line.strip_prefix("ARG={")
                    .map(|rest| serde_json::from_str(&format!("{{{rest}")).unwrap())
            })
            .unwrap();
        assert_eq!(args["sessions_only"], true);
        assert!(!fixture.root.join("fzf-args").exists());
    }
}

#[test]
fn no_waiting_agent_leaves_direct_focus_alone_but_completes_hosted_picker() {
    let fixture = Fixture::new();
    let output = fixture
        .command("agent-next", "unused", false)
        .env_remove("REX_BLOCK")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let calls = fixture.calls();
    assert_eq!(
        calls.len(),
        1,
        "no-op direct shortcut must not start an activation transport"
    );
    assert!(calls[0].contains("SCRIPT=SNAPSHOT"));

    let output = fixture.run_with_files("agent-next", "unused", true);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let result: Value =
        serde_json::from_slice(&fs::read(fixture.root.join("result.json")).unwrap()).unwrap();
    assert_eq!(result["outcome"], "cancel");
    assert_eq!(fixture.calls().len(), 1);
}

#[test]
fn list_uses_one_snapshot_process_and_hides_ids_from_visible_rows() {
    let fixture = Fixture::new();
    let output = fixture.run("list", "select");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let calls = fixture.calls();
    assert_eq!(calls.len(), 1);
    assert!(calls[0].contains("SCRIPT=SNAPSHOT"));
    assert!(
        !fixture.root.join("rows").exists(),
        "list must not start fzf"
    );
    let rows = String::from_utf8(output.stdout).unwrap();
    assert_eq!(
        rows.lines().count(),
        6,
        "single-pane windows use one combined row"
    );
    for (index, row) in rows.lines().enumerate() {
        let fields: Vec<_> = row.split('\t').collect();
        assert_eq!(fields.len(), 4);
        assert_eq!(fields[3], format!("imux:{index}"));
        assert!(!fields[..3].join(" ").contains("block:"));
    }
    assert!(
        !rows.contains("interdimux"),
        "the picker is not a pane candidate"
    );
}

#[test]
fn duplicate_labels_select_exact_hidden_target_and_originating_client() {
    let fixture = Fixture::new();
    let output = fixture.run("pick", "select");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let (activation, args) = fixture.activation();
    assert_eq!(args["client_id"], "client:initiating-app");
    assert_eq!(args["session_id"], "session:two");
    assert_eq!(args["window_id"], "window:two");
    assert_eq!(args["block_id"], "block:two-b");
    assert!(activation.contains("ARG=--session\nARG=session:two\n"));
    assert!(activation.contains("ARG=--server\nARG=unix:///tmp/rex test.sock\n"));
    let rows = fs::read_to_string(fixture.root.join("rows")).unwrap();
    assert!(rows.lines().nth(2).unwrap().contains("shell"));
    assert!(rows.lines().nth(3).unwrap().contains("shell"));
    let chooser_args = fs::read_to_string(fixture.root.join("fzf-args")).unwrap();
    assert!(chooser_args.contains("--with-nth=1..3\n"));
    assert!(chooser_args.contains("--nth=1..3\n"));
    assert!(chooser_args.contains("--no-clear\n"));
    assert!(chooser_args.contains("--raw\n"));
    assert!(chooser_args.contains("ctrl-e:"));
}

#[test]
fn combined_singleton_row_selects_the_exact_pane() {
    for hosted in [false, true] {
        let fixture = Fixture::new();
        let output = fixture.run_with_files("pick", "singleton", hosted);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let target = if hosted {
            let result: Value =
                serde_json::from_slice(&fs::read(fixture.root.join("result.json")).unwrap())
                    .unwrap();
            assert_eq!(result["outcome"], "select");
            result["target"].clone()
        } else {
            fixture.activation().1
        };
        assert_eq!(target["session_id"], "session:one");
        assert_eq!(target["window_id"], "window:one");
        assert_eq!(target["block_id"], "block:origin");
    }
}

#[test]
fn cancellation_and_no_selection_are_successful_and_restore_the_origin() {
    for mode in ["cancel", "nomatch", "empty"] {
        let fixture = Fixture::new();
        let output = fixture.run("pick", mode);
        assert!(
            output.status.success(),
            "{mode}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let (_, args) = fixture.activation();
        assert_eq!(args["client_id"], "client:initiating-app");
        assert_eq!(args["session_id"], "session:one");
        assert_eq!(args["window_id"], "window:one");
        assert_eq!(args["block_id"], "block:origin");
        assert_eq!(args["restore"], true);
        assert_eq!(args["origin_zoomed_block_id"], "block:origin");
    }
}

#[test]
fn real_chooser_failures_are_not_reported_as_cancellation() {
    let fixture = Fixture::new();
    let output = fixture.run("pick", "failure");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("fzf failed"));
    // Preserve the error terminal's focus until acknowledgement; restoring the
    // origin here would send its Enter key to the underlying real pane.
    let calls = fixture.calls();
    assert_eq!(calls.len(), 1);
    assert!(calls[0].contains("SCRIPT=SNAPSHOT"));
    assert!(!calls[0].contains("SCRIPT=ACTIVATE"));
}

#[test]
fn direct_action_mode_reuses_its_first_backend_snapshot() {
    let fixture = Fixture::new();
    let output = fixture.run("rename", "cancel");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let calls = fixture.calls();
    assert_eq!(
        calls
            .iter()
            .filter(|c| c.contains("SCRIPT=SNAPSHOT"))
            .count(),
        1
    );
    assert_eq!(
        calls
            .iter()
            .filter(|c| c.contains("SCRIPT=ACTIVATE"))
            .count(),
        1
    );
}

#[test]
fn hosted_picker_returns_selection_and_cancellation_without_starting_rex() {
    for mode in ["select", "cancel", "nomatch", "empty"] {
        let fixture = Fixture::new();
        let output = fixture.run_with_files("pick", mode, true);
        assert!(
            output.status.success(),
            "{mode}: {}",
            String::from_utf8_lossy(&output.stderr),
        );
        assert!(
            !fixture.root.join("calls").exists(),
            "the host supplied its snapshot and performs native activation",
        );
        let result: Value =
            serde_json::from_slice(&fs::read(fixture.root.join("result.json")).unwrap()).unwrap();
        assert_eq!(result["version"], 1);
        if mode == "select" {
            assert_eq!(result["outcome"], "select");
            assert_eq!(result["target"]["session_id"], "session:two");
            assert_eq!(result["target"]["window_id"], "window:two");
            assert_eq!(result["target"]["block_id"], "block:two-b");
        } else {
            assert_eq!(result["outcome"], "cancel");
            assert!(result.get("target").is_none());
        }
        assert!(!fixture.root.join("result.json.tmp").exists());
    }
}

#[test]
fn hosted_chooser_failure_publishes_an_error_without_starting_rex() {
    let fixture = Fixture::new();
    let output = fixture.run_with_files("pick", "failure", true);
    assert!(!output.status.success());
    assert!(!fixture.root.join("calls").exists());
    let result: Value =
        serde_json::from_slice(&fs::read(fixture.root.join("result.json")).unwrap()).unwrap();
    assert_eq!(result["version"], 1);
    assert_eq!(result["outcome"], "error");
    assert!(result["message"].as_str().unwrap().contains("fzf failed"));
    assert!(!fixture.root.join("result.json.tmp").exists());
}
