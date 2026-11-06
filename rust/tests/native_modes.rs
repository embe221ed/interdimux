//! Direct shared modes use captured native IDs without starting Rex or fzf.
#![cfg(unix)]
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
impl Fixture {
    fn new() -> Self {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "imux-modes-{}-{stamp}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(root.join("project")).unwrap();
        let project = root.join("project").to_string_lossy().into_owned();
        let status = |name: &str, pid: u32, state: &str, kind: &str| json!({"foreground":{"name":name,"pid":pid,"cwd":project},"program_status":{"records":[{"state":state,"kind":kind,"owner":{"name":name,"pid":pid}}]}});
        let snapshot = json!({"version":1,"host_id":"host","sessions":[{"session_id":"session:o","label":"origin"},{"session_id":"session:t","label":"target-project"}],
            "mru":{"session:o":10,"session:t":20},"session_paths":{"session:t":project},
            "views":{"session:o":{"active_window_id":"window:o","windows":[{"window_id":"window:o","label":"origin","focused_block_id":"block:o","layers":[{"kind":"tiled","blocks":[{"block_id":"block:o","label":"origin","host_id":"host"}]}]}]},
            "session:t":{"active_window_id":"window:t","windows":[{"window_id":"window:t","label":"target","focused_block_id":"block:a","layers":[{"kind":"tiled","blocks":[{"block_id":"block:a","label":"review","host_id":"host"},{"block_id":"block:b","label":"question","host_id":"host"},{"block_id":"block:c","label":"approve input blocked","host_id":"host"}]}]}]}},
            "metadata":{"block:o":{"foreground":{"name":"cat","pid":0}},"block:a":status("codex",12,"blocked","permission"),"block:b":status("claude",13,"blocked","question"),"block:c":{"foreground":{"name":"cat","pid":0}}},"errors":{}});
        fs::write(
            root.join("snapshot.json"),
            serde_json::to_vec(&snapshot).unwrap(),
        )
        .unwrap();
        Self { root }
    }
    fn command(&self, verb: &str, session: &str, window: &str, block: &str) -> Command {
        let mut c = Command::new(env!("CARGO_BIN_EXE_imux"));
        c.arg(verb);
        c.args([
            "--backend",
            "rex",
            "--client",
            "client:app",
            "--session",
            session,
            "--window",
            window,
            "--block",
            block,
            "--picker-block",
            "block:picker",
            "--snapshot",
        ])
        .arg(self.root.join("snapshot.json"))
        .arg("--result")
        .arg(self.root.join("result.json"));
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().starts_with("INTERDIMUX_") {
                c.env_remove(key);
            }
        }
        c.env("HOME", &self.root)
            .env("XDG_DATA_HOME", self.root.join("data"))
            .env("XDG_STATE_HOME", self.root.join("state"))
            .env("INTERDIMUX_REX_BIN", self.root.join("missing-rex"))
            .env("INTERDIMUX_FZF_BIN", self.root.join("missing-fzf"))
            .env("INTERDIMUX_SHOW_FULL_COMMAND", "off")
            .env("INTERDIMUX_SHOW_GIT_BRANCH", "off");
        c
    }
    fn origin(&self, verb: &str) -> Command {
        self.command(verb, "session:o", "window:o", "block:o")
    }
    fn result(&self) -> Value {
        serde_json::from_slice(&fs::read(self.root.join("result.json")).unwrap()).unwrap()
    }
}
fn text(output: Output) -> String {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap()
}

#[test]
fn exact_agents_counts_and_state_validation_do_not_fuzzy_match_labels() {
    let f = Fixture::new();
    assert_eq!(
        text(
            f.origin("agents")
                .args(["--count", "approve,input"])
                .output()
                .unwrap()
        ),
        "2\n"
    );
    for state in ["approve", "input"] {
        assert_eq!(
            text(
                f.origin("agents")
                    .args(["--count", "--states", state])
                    .output()
                    .unwrap()
            ),
            "1\n",
            "native status kind must distinguish permission from input"
        );
    }
    assert_eq!(
        text(
            f.origin("agents")
                .args(["--count", "--states", "error"])
                .output()
                .unwrap()
        ),
        "0\n"
    );
    let rows = text(f.origin("agents").arg("approve,input").output().unwrap());
    assert_eq!(rows.lines().count(), 2);
    assert!(rows.lines().next().unwrap().contains("block:a"));
    assert!(!rows.contains("block:c"));
    assert!(!f
        .origin("agents")
        .args(["--states", "approve,invalid"])
        .output()
        .unwrap()
        .status
        .success());
    assert!(
        !f.root.join("request.json").exists(),
        "read-only agents modes must not start backend transports"
    );
}

#[test]
fn completed_idle_and_failed_agents_are_excluded_from_attention_defaults() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    let snapshot_path = f.root.join("snapshot.json");
    let mut snapshot: Value = serde_json::from_slice(&fs::read(&snapshot_path).unwrap()).unwrap();
    snapshot["metadata"]["block:b"]["program_status"]["records"][0]["state"] = json!("working");
    let chooser = f.root.join("fzf");
    fs::write(
        &chooser,
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$IMUX_TEST_FZF_ARGS\"\nexit 130\n",
    )
    .unwrap();
    fs::set_permissions(&chooser, fs::Permissions::from_mode(0o700)).unwrap();
    let arguments = f.root.join("fzf-args");
    for state in ["done", "idle", "error"] {
        snapshot["metadata"]["block:a"]["program_status"]["records"][0]["state"] = json!(state);
        fs::write(&snapshot_path, serde_json::to_vec(&snapshot).unwrap()).unwrap();

        text(f.origin("agent-next").output().unwrap());
        assert_eq!(
            f.result()["outcome"],
            "cancel",
            "default attention included {state}"
        );
        text(
            f.origin("agent-next")
                .args(["--states", state])
                .output()
                .unwrap(),
        );
        assert_eq!(
            f.result()["target"]["block_id"],
            "block:a",
            "explicit filter omitted {state}"
        );

        for (filter, expected) in [
            (None, "0 need attention"),
            (Some(state), "1 need attention"),
        ] {
            let mut command = f.origin("pick");
            command
                .args(["--mode", "dashboard"])
                .env("INTERDIMUX_FZF_BIN", &chooser)
                .env("IMUX_TEST_FZF_ARGS", &arguments);
            if let Some(filter) = filter {
                command.args(["--agent-states", filter]);
            }
            text(command.output().unwrap());
            assert!(
                fs::read_to_string(&arguments).unwrap().contains(expected),
                "dashboard disagreed for {state}"
            );
        }
    }
}

#[test]
fn next_attention_visits_every_agent_then_wraps_using_native_ids() {
    let f = Fixture::new();
    text(f.origin("agent-next").output().unwrap());
    assert_eq!(f.result()["target"]["block_id"], "block:a");
    text(
        f.command("agent-next", "session:t", "window:t", "block:a")
            .output()
            .unwrap(),
    );
    assert_eq!(f.result()["target"]["block_id"], "block:b");
    text(
        f.command("agent-next", "session:t", "window:t", "block:b")
            .output()
            .unwrap(),
    );
    assert_eq!(f.result()["target"]["block_id"], "block:a");
    assert!(!f.root.join("request.json").exists());
}
#[test]
fn jump_obeys_picker_mru_order_and_hide_keeps_current_session() {
    let f = Fixture::new();
    text(f.origin("jump").arg("1").output().unwrap());
    assert_eq!(f.result()["target"]["session_id"], "session:t");
    assert!(!f.origin("jump").arg("0").output().unwrap().status.success());
    assert_eq!(
        text(
            f.origin("agents")
                .arg("--count")
                .env("INTERDIMUX_HIDE", "target-*")
                .output()
                .unwrap()
        ),
        "0\n"
    );
    assert_eq!(
        text(
            f.command("agents", "session:t", "window:t", "block:a")
                .arg("--count")
                .env("INTERDIMUX_HIDE", "target-*")
                .output()
                .unwrap()
        ),
        "2\n"
    );
}
#[test]
fn project_modes_reuse_physical_existing_session_without_startup_or_creation() {
    let f = Fixture::new();
    let path = f.root.join("project");
    fs::write(path.join(".interdimux-startup"), "must-never-run\n").unwrap();
    assert_eq!(
        text(f.origin("session-name-for").arg(&path).output().unwrap()).trim(),
        "target-project"
    );
    text(f.origin("connect-dir").arg(&path).output().unwrap());
    assert_eq!(f.result()["target"]["session_id"], "session:t");
    assert!(
        !f.root.join("request.json").exists(),
        "existing project must not create or run startup commands"
    );
}
