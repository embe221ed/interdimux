#![cfg(feature = "macos-picker")]

use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

/// Exercises the actual persistent process: request IDs, capped full counts,
/// cached filtering, refresh invalidation, and fixture activation isolation.
#[test]
fn native_picker_json_lines_process_keeps_queries_local_and_ids_stable() {
    let path = std::env::temp_dir().join(format!(
        "imux-native-picker-ipc-{}.json",
        std::process::id()
    ));
    let mut rows: Vec<Value> = (0..5000)
        .map(|index| {
            json!({
                "id":format!("pane-{index}"),"kind":"pane","title":format!("project-{index:04}"),
                "path":format!("/workspace/開発/{index:04}")
                ,"command":format!("runner --job task-{index:04}")
            })
        })
        .collect();
    rows.extend([
        json!({"id":"directory:root","kind":"directory","title":"projects","path":"/Network/no-probe/projects"}),
        json!({"id":"directory:child","kind":"directory","title":"東京","path":"/Network/no-probe/projects/東京"}),
    ]);
    fs::write(&path, json!({"rows":rows}).to_string()).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_imux"))
        .args(["macos-serve", "--fixture"])
        .arg(&path)
        // Any accidental fallback to Rex must fail without reaching an app.
        .env("INTERDIMUX_REX_BIN", "/imux-test-do-not-connect-to-rex")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    let mut exchange = |request: Value| -> Value {
        writeln!(input, "{request}").unwrap();
        input.flush().unwrap();
        let mut line = String::new();
        assert!(
            output.read_line(&mut line).unwrap() > 0,
            "helper closed before response"
        );
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], request["id"]);
        response
    };
    let opened = exchange(json!({"id":1,"type":"open"}));
    assert_eq!(opened["total"], 5002);
    assert_eq!(opened["matched"], 5002);
    assert_eq!(opened["shown_matches"], 100);
    assert_eq!(opened["preferred_id"], "pane-0");
    assert_eq!(opened["rows"].as_array().unwrap().len(), 100);
    assert_eq!(
        opened["dashboard"],
        json!({"sessions":0,"tabs":0,"panes":5000,"attention":0,"projects":2,"terminal_tools_available":false})
    );
    for operation in ["next-agent", "schedule", "jobs", "health"] {
        let denied = exchange(json!({"id":104,"type":"dashboard_action","operation":operation}));
        assert!(denied["message"].as_str().unwrap().contains("Fixture mode"));
    }
    fs::remove_file(&path).unwrap();
    let create = exchange(json!({"id":100,"type":"query","query":"unmatched new project"}));
    assert_eq!(create["can_create"], true);
    assert_eq!(create["rows"][0]["kind"], "create");
    let denied_create =
        exchange(json!({"id":101,"type":"activate","target_id":create["preferred_id"]}));
    assert!(denied_create["message"]
        .as_str()
        .unwrap()
        .contains("never activates"));
    let blocked_create = exchange(
        json!({"id":102,"type":"query","query":"unmatched new project","allow_create":false}),
    );
    assert_eq!(blocked_create["can_create"], false);
    let stale_create =
        exchange(json!({"id":103,"type":"activate","target_id":create["preferred_id"]}));
    assert!(stale_create["message"]
        .as_str()
        .unwrap()
        .contains("no longer available"));
    for id in 2..12 {
        let response =
            exchange(json!({"id":id,"type":"query","query":"'project-4999","scope":"pane"}));
        assert_eq!(response["type"], "results");
        assert_eq!(response["matched"], 1);
        assert_eq!(response["rows"][0]["id"], "pane-4999");
    }
    for (id, field, query, matched) in [
        (20, "path", "'開発/4999", 1),
        (21, "name", "'開発/4999", 0),
        (22, "command", "'task-4999", 1),
    ] {
        let result = exchange(
            json!({"id":id,"type":"query","query":query,"scope":"pane","search_field":field}),
        );
        assert_eq!(result["search_field"], field);
        assert_eq!(result["matched"], matched, "field={field} query={query}");
    }
    let projects = exchange(
        json!({"id":23,"type":"directories","reset":true,"query":"","search_field":"path"}),
    );
    assert_eq!(projects["matched"], 2);
    assert_eq!(projects["directories_loaded"], true);
    let browsed = exchange(json!({"id":24,"type":"directories","base_id":"directory:root"}));
    assert_eq!(browsed["directories_base"], "/Network/no-probe/projects");
    let preview = exchange(json!({"id":25,"type":"preview","target_id":"directory:child"}));
    assert_eq!(preview["type"], "preview");
    assert!(preview["text"]
        .as_str()
        .unwrap()
        .contains("no Rex connection or filesystem reads"));
    let denied_directory =
        exchange(json!({"id":26,"type":"activate","target_id":"directory:child"}));
    assert_eq!(denied_directory["type"], "error");
    exchange(
        json!({"id":27,"type":"query","query":"'project-4999","scope":"pane","search_field":"all"}),
    );
    let forbidden = exchange(json!({"id":12,"type":"activate","target_id":"pane-4999"}));
    assert_eq!(forbidden["type"], "error");
    assert!(forbidden["message"]
        .as_str()
        .unwrap()
        .contains("never activates"));
    fs::write(
        &path,
        json!({"rows":[
            {"id":"session","kind":"session","title":"context"},
            {"id":"window","kind":"window","parent_id":"session","title":"context"},
            {"id":"pane-4999","kind":"pane","parent_id":"window","title":"project-4999"}
        ]})
        .to_string(),
    )
    .unwrap();
    let tree = exchange(json!({"id":13,"type":"refresh"}));
    assert_eq!(tree["matched"], 1);
    assert_eq!(tree["shown_matches"], 1);
    assert_eq!(tree["preferred_id"], "window");
    assert_eq!(tree["rows"].as_array().unwrap().len(), 2);
    assert_eq!(tree["rows"][0]["context_only"], true);
    assert_eq!(tree["rows"][1]["parent_id"], "session");
    assert_eq!(tree["rows"][1]["context_only"], false);
    assert_eq!(tree["rows"][1]["combined"], true);
    assert_eq!(tree["rows"][1]["pane_id"], "pane-4999");
    let denied = exchange(
        json!({"id":131,"type":"action","operation":"close","target_id":"window","confirmed":true}),
    );
    assert_eq!(denied["type"], "error");
    assert!(denied["message"]
        .as_str()
        .unwrap()
        .contains("never performs Rex actions"));
    fs::write(&path, json!({"rows":[]}).to_string()).unwrap();
    assert_eq!(exchange(json!({"id":14,"type":"refresh"}))["total"], 0);
    let stale = exchange(json!({"id":15,"type":"activate","target_id":"pane-4999"}));
    assert!(stale["message"]
        .as_str()
        .unwrap()
        .contains("no longer available"));
    drop(exchange);
    drop(input);
    assert!(child.wait().unwrap().success());
    fs::remove_file(path).unwrap();
}
