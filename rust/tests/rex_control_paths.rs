//! Literal Rex paths must not become a different directory after display cleanup.
#![cfg(all(unix, feature = "macos-picker"))]

use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Helper {
    root: PathBuf,
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
}

impl Helper {
    fn new(control: char, associated: bool) -> (Self, String, String) {
        let root = std::env::temp_dir().join(format!(
            "imux-rex-paths-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        let root = fs::canonicalize(root).unwrap();
        let raw = root.join(format!("work{control}name"));
        let ordinary = root.join("work name");
        fs::create_dir(&raw).unwrap();
        fs::create_dir(&ordinary).unwrap();
        let raw = raw.to_str().unwrap().to_owned();
        let ordinary = ordinary.to_str().unwrap().to_owned();
        let mut snapshot = json!({"version":1,"host_id":"local","local_host_id":"local",
            "sessions":[{"session_id":"session:literal","label":"different-project"}],
            "views":{"session:literal":{"active_window_id":"window:literal","windows":[{
                "window_id":"window:literal","label":"target-window","focused_block_id":"block:literal",
                "layers":[{"blocks":[{"block_id":"block:literal","creator_name":"com.superlogical.terminal","host_id":"local"}]}]
            }]}},
            "metadata":{"block:literal":{"foreground":{"name":"sh","cwd":raw}}}
        });
        if associated {
            snapshot["session_paths"] = json!({"session:literal":raw});
        }
        fs::write(root.join("snapshot.json"), snapshot.to_string()).unwrap();
        let data = root.join("data/interdimux");
        fs::create_dir_all(&data).unwrap();
        fs::write(data.join("recent_dirs"), format!("{ordinary}\n")).unwrap();
        let rex = root.join("rex");
        fs::write(&rex, r#"#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['IMUX_TEST_ROOT'])
source = sys.stdin.read()
args = json.loads(sys.argv[sys.argv.index('--args') + 1])
with (root / 'calls.jsonl').open('a') as out:
    out.write(json.dumps(args) + '\n')
if 'request' in args:
    print(json.dumps({'target': {'session_id': 'session:new'}}))
elif 'local snapshot=' in source:
    snapshot = json.loads((root / 'snapshot.json').read_text())
    if 'client.list' in source:
        print(json.dumps({'clients': {'clients': [{'client_id': 'client:test', 'info': {'kind': 'app', 'platform': 'macos'}, 'principal': {'kind': 'peer', 'transport': 'unix'}}]}, 'snapshot': snapshot}))
    else:
        print(json.dumps(snapshot))
else:
    print('{}')
"#).unwrap();
        fs::set_permissions(&rex, fs::Permissions::from_mode(0o700)).unwrap();
        let mut child = Command::new(env!("CARGO_BIN_EXE_imux"))
            .arg("macos-serve")
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", &root)
            .env("XDG_DATA_HOME", root.join("data"))
            .env("XDG_STATE_HOME", root.join("state"))
            .env("INTERDIMUX_REX_BIN", &rex)
            .env("INTERDIMUX_USE_ZOXIDE", "off")
            .env("INTERDIMUX_HYDRATE", "off")
            .env("IMUX_TEST_ROOT", &root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        (
            Self {
                root,
                child,
                input,
                output,
            },
            raw,
            ordinary,
        )
    }

    fn exchange(&mut self, request: Value) -> Value {
        writeln!(self.input, "{request}").unwrap();
        self.input.flush().unwrap();
        let mut line = String::new();
        assert!(
            self.output.read_line(&mut line).unwrap() > 0,
            "helper closed unexpectedly"
        );
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], request["id"]);
        response
    }

    fn calls(&self) -> Vec<Value> {
        fs::read_to_string(self.root.join("calls.jsonl"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn rex_paths_keep_literal_identity_through_recents_creation_and_new_tabs() {
    for control in ['\n', '\t', '\r', '\u{1f}', '\u{1e}', '\u{1b}'] {
        for associated in [false, true] {
            let (mut helper, raw, ordinary) = Helper::new(control, associated);
            let opened = helper.exchange(json!({"id":1,"type":"open","context":{
                "client_id":"client:test","session_id":"session:literal",
                "window_id":"window:literal","block_id":"block:literal"
            }}));
            assert_eq!(opened["type"], "results", "{opened}");
            let rows = opened["rows"].as_array().unwrap();
            for id in ["session:literal", "window:literal"] {
                let path = rows.iter().find(|row| row["id"] == id).unwrap()["path"]
                    .as_str()
                    .unwrap();
                assert!(
                    !path.chars().any(char::is_control),
                    "unsafe display path {path:?}"
                );
                assert_ne!(
                    path, ordinary,
                    "control path displayed as the space sibling"
                );
            }
            let recent = rows.iter().find(|row| row["kind"] == "directory").unwrap();
            assert_eq!(recent["path"], ordinary);
            assert_eq!(
                recent["current"], false,
                "recent space sibling aliased raw cwd"
            );
            let recent_id = recent["id"].as_str().unwrap().to_owned();
            for target in ["session:literal", "window:literal"] {
                let created = helper
                    .exchange(json!({"id":2,"type":"action","operation":"new-window",
                    "target_id":target,"value":"named-new-tab"}));
                assert_eq!(created["type"], "action_done", "{created}");
                let calls = helper.calls();
                let request = calls.last().unwrap();
                assert_eq!(request["request"]["operation"], "create");
                assert_eq!(request["request"]["args"]["kind"], "window");
                assert_eq!(
                    request["request"]["args"]["cwd"], raw,
                    "new tab inherited display path"
                );
            }
            let recent_open =
                helper.exchange(json!({"id":3,"type":"activate","target_id":recent_id}));
            assert_eq!(recent_open["type"], "activated", "{recent_open}");
            let created = helper.exchange(
                json!({"id":4,"type":"action","operation":"create-session","value":ordinary}),
            );
            assert_eq!(created["type"], "action_done", "{created}");
            let calls = helper.calls();
            let session_creates: Vec<_> = calls
                .iter()
                .filter(|args| {
                    args["request"]["operation"] == "create"
                        && args["request"]["args"]["kind"].is_null()
                })
                .collect();
            assert_eq!(
                session_creates.len(),
                2,
                "Recents and Find/create must create, not reuse raw-path session"
            );
            for create in session_creates {
                assert_eq!(create["request"]["args"]["cwd"], ordinary);
            }
            assert_eq!(calls.last().unwrap()["session_id"], "session:new");
            let invalid = helper
                .exchange(json!({"id":4,"type":"action","operation":"create-session","value":raw}));
            assert_eq!(invalid["type"], "error");
            assert!(invalid["message"]
                .as_str()
                .unwrap()
                .contains("control characters"));
        }
    }
}
