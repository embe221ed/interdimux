//! Retained project history must reach the real native helper's matcher.
#![cfg(all(unix, feature = "macos-picker"))]

use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

struct Helper {
    root: PathBuf,
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
}

impl Helper {
    fn new() -> (Self, Vec<PathBuf>) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "imux-project-history-protocol-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir(&root).unwrap();
        let root = fs::canonicalize(root).unwrap();
        let paths: Vec<_> = (0..25)
            .map(|index| root.join(format!("older/old-project-{index:02}")))
            .collect();
        for path in &paths {
            fs::create_dir_all(path).unwrap();
        }
        for directory in ["home", "empty-root", "data/interdimux"] {
            fs::create_dir_all(root.join(directory)).unwrap();
        }
        let history = paths
            .iter()
            .map(|path| path.to_str().unwrap())
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        fs::write(root.join("data/interdimux/recent_dirs"), history).unwrap();
        fs::write(root.join("snapshot.json"), json!({
            "version":1,"host_id":"local","local_host_id":"local",
            "sessions":[{"session_id":"session:origin","label":"Origin"}],
            "views":{"session:origin":{"active_window_id":"window:origin","windows":[{
                "window_id":"window:origin","label":"Terminal","focused_block_id":"block:origin",
                "layers":[{"blocks":[{"block_id":"block:origin","creator_name":"com.superlogical.terminal","host_id":"local"}]}]
            }]}},
            "metadata":{"block:origin":{"foreground":{"name":"sh","cwd":root.join("home")}}}
        }).to_string()).unwrap();
        let rex = root.join("rex");
        fs::write(&rex, r#"#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['IMUX_HISTORY_TEST_ROOT'])
source = sys.stdin.read()
if 'local snapshot=' not in source or 'local clients=' not in source:
    raise SystemExit('Only the initial read-only snapshot is allowed')
with (root / 'calls').open('a') as out:
    out.write('snapshot\n')
print(json.dumps({'clients': {'clients': [{'client_id': 'client:test', 'info': {'kind': 'app', 'platform': 'macos'}, 'principal': {'kind': 'peer', 'transport': 'unix'}}]}, 'snapshot': json.loads((root / 'snapshot.json').read_text())}))
"#).unwrap();
        fs::set_permissions(&rex, fs::Permissions::from_mode(0o700)).unwrap();
        let mut child = Command::new(env!("CARGO_BIN_EXE_imux"))
            .arg("macos-serve")
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", root.join("home"))
            .env("XDG_DATA_HOME", root.join("data"))
            .env("XDG_STATE_HOME", root.join("state"))
            .env("XDG_CONFIG_HOME", root.join("config"))
            .env("INTERDIMUX_REX_BIN", &rex)
            .env("INTERDIMUX_PROJECT_DIRS", root.join("empty-root"))
            .env("INTERDIMUX_DIRS_LIMIT", "15")
            .env("INTERDIMUX_SHOW_DIRS", "on")
            .env("INTERDIMUX_USE_ZOXIDE", "off")
            .env("INTERDIMUX_HYDRATE", "off")
            .env("IMUX_HISTORY_TEST_ROOT", &root)
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
            paths,
        )
    }

    fn exchange(&mut self, request: Value) -> Value {
        writeln!(self.input, "{request}").unwrap();
        self.input.flush().unwrap();
        let mut line = String::new();
        assert!(
            self.output.read_line(&mut line).unwrap() > 0,
            "Helper closed before replying"
        );
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], request["id"]);
        assert_eq!(response["type"], "results", "{response}");
        response
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn directory_rows(response: &Value) -> Vec<&Value> {
    response["rows"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| row["kind"] == "directory")
        .collect()
}

#[test]
fn native_history_search_survives_suggestion_caps_projects_and_deleted_cached_paths() {
    let (mut helper, paths) = Helper::new();
    let older = paths[24].to_str().unwrap();
    let opened = helper.exchange(json!({"id":1,"type":"open","context":{
        "client_id":"client:test","session_id":"session:origin",
        "window_id":"window:origin","block_id":"block:origin"
    }}));
    assert_eq!(
        directory_rows(&opened).len(),
        15,
        "Initial suggestions must stay small"
    );
    assert!(!directory_rows(&opened)
        .iter()
        .any(|row| row["path"] == older));

    let exact = helper.exchange(json!({"id":2,"type":"query","scope":"all",
        "search_field":"name","query":"^old-project-24$","allow_create":false}));
    assert_eq!(
        exact["matched"], 1,
        "An older exact match was removed before matching: {exact}"
    );
    assert_eq!(directory_rows(&exact)[0]["path"], older);
    let older_id = exact["preferred_id"].clone();

    // Exercise actual explicit Projects discovery, then return to the main list.
    let projects = helper.exchange(json!({"id":3,"type":"directories","reset":true,
        "query":"","search_field":"name"}));
    assert_eq!(projects["directories_loaded"], true);
    let fuzzy = helper.exchange(json!({"id":4,"type":"query","scope":"directory",
        "search_field":"name","query":"oldprj24","allow_create":false}));
    assert_eq!(
        fuzzy["matched"], 1,
        "Projects must retain shared fuzzy matching: {fuzzy}"
    );
    assert_eq!(fuzzy["preferred_id"], older_id);
    let cleared = helper.exchange(json!({"id":5,"type":"query","scope":"all",
        "search_field":"all","query":"","allow_create":false}));
    assert_eq!(directory_rows(&cleared).len(), 15);

    // Ordinary queries use the retained snapshot even when both its source
    // history file and a candidate directory disappear after explicit loading.
    fs::remove_file(helper.root.join("data/interdimux/recent_dirs")).unwrap();
    fs::remove_dir(&paths[24]).unwrap();
    for (id, query) in [(6, "^old-project-24$"), (7, "oldprj24")] {
        let result = helper.exchange(json!({"id":id,"type":"query","scope":"all",
            "search_field":"name","query":query,"allow_create":false}));
        assert_eq!(
            result["matched"], 1,
            "Cached older history disappeared: {result}"
        );
        assert_eq!(result["preferred_id"], older_id);
        assert_eq!(directory_rows(&result)[0]["path"], older);
    }
    assert_eq!(
        fs::read_to_string(helper.root.join("calls")).unwrap(),
        "snapshot\n",
        "Typing or Projects discovery unexpectedly called Rex again"
    );
}
