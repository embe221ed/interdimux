//! Retained project history must reach the real native helper's matcher.
#![cfg(all(unix, feature = "macos-picker"))]

use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct Helper {
    root: PathBuf,
    child: Child,
    input: ChildStdin,
    output: Receiver<Result<String, String>>,
    reader: Option<JoinHandle<()>>,
}

impl Helper {
    fn new() -> (Self, Vec<PathBuf>) {
        Self::with_zoxide("off")
    }

    fn with_zoxide(mode: &str) -> (Self, Vec<PathBuf>) {
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
        let zoxide_paths: Vec<_> = (0..40)
            .map(|index| root.join(format!("zoxide-projects/zoxide-project-{index:02}")))
            .collect();
        for path in &zoxide_paths {
            fs::create_dir_all(path).unwrap();
        }
        fs::write(
            root.join("zoxide-output"),
            zoxide_paths
                .iter()
                .map(|path| path.to_str().unwrap())
                .collect::<Vec<_>>()
                .join("\n")
                + "\n",
        )
        .unwrap();
        let zoxide = root.join("zoxide");
        fs::write(
            &zoxide,
            r#"#!/bin/sh
printf '%s\n' "$*" >> "$IMUX_HISTORY_TEST_ROOT/zoxide-calls"
printf '%s\n' "$$" >> "$IMUX_HISTORY_TEST_ROOT/zoxide-pids"
if [ "$#" -ne 3 ] || [ "$1" != query ] || [ "$2" != --list ] || [ "$3" != --all ]; then
    echo 'Only bounded full read-only listing is allowed' >&2
    exit 1
fi
if [ "$IMUX_ZOXIDE_TEST_MODE" = stall ]; then exec /bin/sleep 30; fi
exec /bin/cat "$IMUX_HISTORY_TEST_ROOT/zoxide-output"
"#,
        )
        .unwrap();
        fs::set_permissions(&zoxide, fs::Permissions::from_mode(0o700)).unwrap();
        // macOS can delay first execution of a newly written script beyond
        // the production helper's 250 ms budget. Exercise only this private
        // fixture during setup, then begin assertions with clean call logs.
        assert!(Command::new(&zoxide)
            .args(["query", "--list", "--all"])
            .env("IMUX_HISTORY_TEST_ROOT", &root)
            .env("IMUX_ZOXIDE_TEST_MODE", "success")
            .stdout(Stdio::null())
            .status()
            .unwrap()
            .success());
        fs::remove_file(root.join("zoxide-calls")).unwrap();
        fs::remove_file(root.join("zoxide-pids")).unwrap();
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
        let inherited_path = std::env::var_os("PATH").unwrap_or_default();
        let path = std::env::join_paths(
            std::iter::once(root.clone()).chain(std::env::split_paths(&inherited_path)),
        )
        .unwrap();
        let mut child = Command::new(env!("CARGO_BIN_EXE_imux"))
            .arg("macos-serve")
            .env_clear()
            .env("PATH", path)
            .env("HOME", root.join("home"))
            .env("XDG_DATA_HOME", root.join("data"))
            .env("XDG_STATE_HOME", root.join("state"))
            .env("XDG_CONFIG_HOME", root.join("config"))
            .env("INTERDIMUX_REX_BIN", &rex)
            .env("INTERDIMUX_PROJECT_DIRS", root.join("empty-root"))
            .env("INTERDIMUX_DIRS_LIMIT", "15")
            .env("INTERDIMUX_SHOW_DIRS", "on")
            .env(
                "INTERDIMUX_USE_ZOXIDE",
                if mode == "off" { "off" } else { "on" },
            )
            .env("INTERDIMUX_HYDRATE", "off")
            .env("IMUX_HISTORY_TEST_ROOT", &root)
            .env("IMUX_ZOXIDE_TEST_MODE", mode)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(
                fs::File::create(root.join("helper.stderr")).unwrap(),
            ))
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (sender, output) = mpsc::channel();
        let reader = thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if sender
                    .send(line.map_err(|error| error.to_string()))
                    .is_err()
                {
                    break;
                }
            }
        });
        (
            Self {
                root,
                child,
                input,
                output,
                reader: Some(reader),
            },
            paths,
        )
    }

    fn exchange(&mut self, request: Value) -> Value {
        writeln!(self.input, "{request}").unwrap();
        self.input.flush().unwrap();
        let line = self
            .output
            .recv_timeout(Duration::from_secs(5))
            .expect("Helper closed or blocked before replying")
            .expect("Cannot read helper reply");
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], request["id"]);
        assert_eq!(response["type"], "results", "{response}");
        response
    }

    fn zoxide_calls(&self) -> usize {
        fs::read_to_string(self.root.join("zoxide-calls"))
            .unwrap_or_default()
            .lines()
            .count()
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        // A failing timeout assertion must not leave this fixture's optional
        // child behind after the helper itself has been stopped.
        if let Ok(pids) = fs::read_to_string(self.root.join("zoxide-pids")) {
            extern "C" {
                fn kill(pid: i32, signal: i32) -> i32;
            }
            for pid in pids.lines().filter_map(|pid| pid.parse::<i32>().ok()) {
                unsafe {
                    kill(-pid, 9);
                }
            }
        }
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
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

fn open_request(id: u64) -> Value {
    json!({"id":id,"type":"open","context":{
        "client_id":"client:test","session_id":"session:origin",
        "window_id":"window:origin","block_id":"block:origin"
    }})
}

fn project_query(id: u64, operation: &str, query: &str) -> Value {
    json!({"id":id,"type":operation,"scope":"all",
        "search_field":"name","query":query,"allow_create":true})
}

#[test]
fn native_zoxide_search_loads_the_full_inventory_only_after_a_cached_miss() {
    let (mut helper, _) = Helper::with_zoxide("success");
    let opened = helper.exchange(open_request(1));
    assert_eq!(directory_rows(&opened).len(), 15);
    assert_eq!(helper.zoxide_calls(), 0, "Opening eagerly queried zoxide");

    let retained = helper.exchange(project_query(2, "query", "^old-project-24$"));
    assert_eq!(retained["matched"], 1);
    assert_eq!(retained["projects_needed"], false);
    let live = helper.exchange(project_query(3, "query", "^Origin$"));
    assert_eq!(live["matched"], 1);
    assert_eq!(live["projects_needed"], false);
    assert_eq!(helper.zoxide_calls(), 0, "Cached hits queried zoxide");

    for (id, fields) in [
        (4, json!({"scope":"session"})),
        (5, json!({"search_field":"command"})),
        (6, json!({"action_filter":"rename"})),
    ] {
        let mut request = project_query(id, "query", "zoxide-project-39");
        request
            .as_object_mut()
            .unwrap()
            .extend(fields.as_object().unwrap().clone());
        let result = helper.exchange(request);
        assert_eq!(
            result["projects_needed"], false,
            "Unrelated search requested project loading: {result}"
        );
    }
    assert_eq!(helper.zoxide_calls(), 0);

    let mut id = 7;
    let missed = helper.exchange(project_query(id, "query", "^zoxide-project-39$"));
    assert_eq!(missed["matched"], 0);
    assert_eq!(missed["projects_needed"], true);
    assert_eq!(missed["projects_loading"], false);
    assert_eq!(
        missed["can_create"], false,
        "Creation was offered before zoxide could be searched"
    );
    assert_eq!(
        helper.zoxide_calls(),
        0,
        "The ordinary query started optional work before lazy loading"
    );

    id += 1;
    let loading = helper.exchange(project_query(id, "load_projects", "^zoxide-project-39$"));
    assert_eq!(loading["projects_loading"], true);
    assert_eq!(loading["can_create"], false);
    let deadline = Instant::now() + Duration::from_secs(3);
    let exact = loop {
        assert!(
            Instant::now() < deadline,
            "Lazy project inventory never completed"
        );
        id += 1;
        let result = helper.exchange(project_query(id, "query", "^zoxide-project-39$"));
        if result["projects_loading"] != true {
            break result;
        }
        thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(
        exact["matched"], 1,
        "Lower-ranked zoxide entry was truncated before matching: {exact}"
    );
    let low_path = helper.root.join("zoxide-projects/zoxide-project-39");
    assert_eq!(
        directory_rows(&exact)[0]["path"],
        low_path.to_str().unwrap()
    );
    let low_id = exact["preferred_id"].clone();
    assert_eq!(helper.zoxide_calls(), 1);

    // Once discovered, all zoxide candidates use the same lexical matcher and
    // survive source changes and subsequent ordinary openings.
    fs::remove_file(helper.root.join("zoxide-output")).unwrap();
    fs::remove_dir(&low_path).unwrap();
    id += 1;
    let fuzzy = helper.exchange(project_query(id, "query", "zxdprj39"));
    assert_eq!(
        fuzzy["matched"], 1,
        "Zoxide inventory lost shared fuzzy matching: {fuzzy}"
    );
    assert_eq!(fuzzy["preferred_id"], low_id);
    id += 1;
    let reopened = helper.exchange(open_request(id));
    assert_eq!(
        directory_rows(&reopened).len(),
        15,
        "Loading expanded blank-query suggestions"
    );
    id += 1;
    let cached = helper.exchange(project_query(id, "query", "^zoxide-project-39$"));
    assert_eq!(
        cached["preferred_id"], low_id,
        "Reopening discarded the discovered inventory"
    );
    assert_eq!(
        helper.zoxide_calls(),
        1,
        "Cached searching or reopening repeated zoxide work"
    );
    assert_eq!(
        fs::read_to_string(helper.root.join("calls")).unwrap(),
        "snapshot\nsnapshot\n"
    );
}

#[test]
fn native_stalled_zoxide_loading_keeps_cached_queries_responsive_and_is_bounded() {
    let (mut helper, _) = Helper::with_zoxide("stall");
    helper.exchange(open_request(1));
    let loading = helper.exchange(project_query(
        2,
        "load_projects",
        "unmatched-zoxide-project",
    ));
    assert_eq!(loading["projects_loading"], true);
    assert_eq!(loading["can_create"], false);

    let deadline = Instant::now() + Duration::from_secs(3);
    let mut id = 3;
    let mut answered_while_loading = false;
    loop {
        assert!(
            Instant::now() < deadline,
            "A stalled optional helper retained loading forever"
        );
        let retained = helper.exchange(project_query(id, "query", "^old-project-24$"));
        id += 1;
        assert_eq!(
            retained["matched"], 1,
            "Stalled optional loading dropped cached history"
        );
        let status = helper.exchange(project_query(id, "query", "unmatched-zoxide-project"));
        id += 1;
        if status["projects_loading"] != true {
            break;
        }
        answered_while_loading = true;
        thread::sleep(Duration::from_millis(10));
    }
    assert!(
        answered_while_loading,
        "Cached queries waited for the optional worker instead of responding during loading"
    );
    assert_eq!(helper.zoxide_calls(), 1);
    let failed = helper.exchange(project_query(id, "query", "unmatched-zoxide-project"));
    assert_eq!(
        failed["projects_needed"], false,
        "A failed optional helper retried on every edit"
    );
    assert_eq!(failed["projects_loading"], false);
    assert_eq!(
        failed["can_create"], true,
        "Optional loading failure permanently disabled creation"
    );
    assert_eq!(helper.zoxide_calls(), 1);
    let pids = fs::read_to_string(helper.root.join("zoxide-pids")).unwrap();
    extern "C" {
        fn kill(pid: i32, signal: i32) -> i32;
    }
    for pid in pids.lines().map(|pid| pid.parse::<i32>().unwrap()) {
        assert_ne!(
            unsafe { kill(pid, 0) },
            0,
            "Timed-out zoxide child {pid} was not killed and reaped"
        );
    }
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
