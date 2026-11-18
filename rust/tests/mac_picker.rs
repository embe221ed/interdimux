#![cfg(feature = "macos-picker")]

use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

#[cfg(unix)]
#[test]
fn native_picker_publishes_fast_hosts_while_slow_hosts_are_pending() {
    use std::os::unix::fs::PermissionsExt;
    use std::time::{Duration, Instant};

    let temp = std::env::temp_dir().join(format!("imux-remote-picker-{}", std::process::id()));
    fs::create_dir(&temp).unwrap();
    let rex = temp.join("rex");
    let release = temp.join("release-slow-host");
    let release_layout = temp.join("release-fast-layout");
    let release_metadata = temp.join("release-fast-metadata");
    let rejected_switch = temp.join("rejected-switch");
    fs::write(&rex, r#"#!/bin/sh
case " $* " in
    *' hosts list --json '*)
        printf '%s\n' '{"hosts":[{"host":{"label":"slow-vps","host_id":"slow","endpoints":["ssh://slow"]}},{"host":{"label":"fast-vps","host_id":"fast"}}]}' ;;
    *' --server=slow-vps api call session.bootstrap '*)
        echo 'Rex RPC code=method_not_found' >&2; exit 1 ;;
    *' --server=slow-vps '*)
        until [ -e "$IMUX_TEST_RELEASE_HOST" ]; do sleep 0.02; done
        printf '%s\n' '{"host_id":"slow","sessions":[{"session_id":"session:local","label":"Slow workspace"}]}' ;;
    *' --server=fast-vps '*'com.superlogical.terminal.title'*)
        until [ -e "$IMUX_TEST_RELEASE_METADATA" ]; do sleep 0.02; done
        printf '%s\n' '{"host_id":"fast","metadata":{"block:fast":{"foreground":{"pid":1,"name":"nvim","cwd":"/remote/editor"},"title":"Editor project","title_owner":{"pid":1,"name":"nvim"}}}}' ;;
    *' --server=fast-vps '*'session.attach_all'*)
        until [ -e "$IMUX_TEST_RELEASE_LAYOUT" ]; do sleep 0.02; done
        printf '%s\n' '{"host_id":"fast","layouts":{"session:fast":[{"window_id":"window:1234abcd","label":"Window 1234abcd","panes":[{"block_id":"block:fast","label":"shell","terminal":true,"focused":true},{"block_id":"block:log","label":"Fast log","terminal":true}]}]}}' ;;
    *' --server=fast-vps api call session.bootstrap '*)
        if [ -f "$IMUX_TEST_SWITCH_LOG.reply" ]; then
            printf '%s\n' bootstrap >>"$IMUX_TEST_SWITCH_LOG"
            cat "$IMUX_TEST_SWITCH_LOG.reply"
        else
            printf '%s\n' '{"server_status":{"host_id":"fast"},"attach_all":{"sessions":[{"session_id":"session:fast","label":"Fast workspace"}]}}'
        fi ;;
    *' --server=fast-vps '*)
        printf '%s\n' '{"host_id":"fast","sessions":[{"session_id":"session:fast","label":"Fast workspace"}]}' ;;
    *)
        cat >/dev/null
        printf '{"clients":{"clients":[{"client_id":"client:mac","info":{"kind":"app","platform":"macos"},"principal":{"kind":"peer","transport":"unix","pid":%s}}]},"snapshot":{"version":1,"local_host_id":"local","sessions":[{"session_id":"session:local","label":"Local workspace"}],"views":{"session:local":{"windows":[]}}}}\n' "$IMUX_TEST_APP_PID" ;;
esac
"#).unwrap();
    fs::set_permissions(&rex, fs::Permissions::from_mode(0o700)).unwrap();

    let contents = temp.join("Test Picker.app/Contents");
    fs::create_dir_all(contents.join("MacOS")).unwrap();
    fs::create_dir_all(contents.join("Helpers")).unwrap();
    let helper = contents.join("Helpers/imux");
    fs::copy(env!("CARGO_BIN_EXE_imux"), &helper).unwrap();
    let app = contents.join("MacOS/InterdimuxPicker");
    fs::write(&app, r#"#!/bin/sh
[ "$1" = --show-remote-session ] && [ "$2" = "$IMUX_TEST_APP_PID" ] &&
  [ "$4" = fast-vps ] && [ "$5" = session:fast ] || exit 2
case "$3" in macos:*:*|linux:*:*) ;; *) exit 2 ;; esac
if [ "$#" -eq 5 ]; then
    echo '{"shown":true}'
elif [ "$6" != fast ]; then
    exit 2
elif [ -f "$IMUX_TEST_SWITCH_LOG.native" ]; then
    cat "$IMUX_TEST_SWITCH_LOG.native"
else
    echo '{"needs_remote_check":true}'
fi
"#).unwrap();
    fs::set_permissions(&app, fs::Permissions::from_mode(0o700)).unwrap();
    let mut child = Command::new(&helper)
        .args(["macos-serve"])
        .env("HOME", &temp)
        .env("INTERDIMUX_REX_BIN", &rex)
        .env("IMUX_TEST_RELEASE_HOST", &release)
        .env("IMUX_TEST_RELEASE_LAYOUT", &release_layout)
        .env("IMUX_TEST_RELEASE_METADATA", &release_metadata)
        .env("IMUX_TEST_APP_PID", std::process::id().to_string())
        .env("IMUX_TEST_SWITCH_LOG", &rejected_switch)
        .env("INTERDIMUX_SHOW_DIRS", "off")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    let mut serial = 0;
    let mut exchange = |mut request: Value| -> Value {
        serial += 1;
        request["id"] = json!(serial);
        writeln!(input, "{request}").unwrap();
        input.flush().unwrap();
        let mut line = String::new();
        assert!(output.read_line(&mut line).unwrap() > 0);
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], serial);
        if request["type"] != "activate" && request["type"] != "complete_remote_reveal" {
            assert_ne!(response["type"], "error", "{response}");
        }
        response
    };

    let local_open = json!({"type":"open","context":{"client_id":"client:mac","session_id":"session:local"}});
    let open = exchange(local_open.clone());
    assert_eq!(open["remote_pending"], true);
    assert_eq!(open["rows"][0]["id"], "session:local");
    let from_remote = exchange(json!({"type":"open","context":{
        "client_id":"client:mac","origin_server":"slow-vps","origin_session_id":"session:local"
    }}));
    assert_eq!(from_remote["previous_session_id"], "session:local");
    assert_eq!(from_remote["preferred_id"], "session:local");
    let back_local = exchange(local_open.clone());
    assert_eq!(back_local["previous_session_pending"], true);
    assert!(back_local["previous_session_id"].is_null());
    let query = exchange(json!({"type":"query","query":"Local workspace","scope":"session"}));
    assert_eq!(query["rows"][0]["id"], "session:local");
    let wait_for_update = |exchange: &mut dyn FnMut(Value) -> Value| {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let update = exchange(json!({"type":"remote_update"}));
            if update["changed"] == true || update["pending"] == false {
                return update;
            }
            assert!(Instant::now() < deadline, "No host published a result");
            std::thread::sleep(Duration::from_millis(15));
        }
    };
    // Fast discovery may have completed while reopening from the other host.
    if !back_local["rows"].as_array().unwrap().iter().any(|row| row["host"] == "fast-vps") {
        assert_eq!(wait_for_update(&mut exchange)["pending"], true);
    }
    let warm = exchange(local_open.clone());
    assert_eq!(warm["previous_session_pending"], true);
    assert_eq!(warm["remote_pending"], true);
    assert!(warm["rows"].as_array().unwrap().iter().any(|row| row["host"] == "fast-vps"));
    assert!(!warm["rows"].as_array().unwrap().iter().any(|row| row["kind"] == "window"));
    fs::write(&release_layout, "").unwrap();
    assert_eq!(wait_for_update(&mut exchange)["pending"], true);
    let fast_layout = exchange(json!({"type":"query","query":"","scope":"window"}));
    assert_eq!(fast_layout["matched"], 1);
    assert_eq!(fast_layout["rows"][1]["title"], "Window 1234abcd");
    let fast_pane = exchange(json!({"type":"query","query":"Fast log","scope":"pane"}));
    assert_eq!(fast_pane["matched"], 1);
    assert_eq!(fast_pane["rows"][2]["title"], "Fast log");
    let fallback = exchange(json!({"type":"query","query":"shell","scope":"pane"}));
    assert_eq!(fallback["matched"], 1);
    assert_eq!(fallback["rows"][2]["name"], "shell");
    let local = exchange(json!({"type":"query","query":"Local workspace","scope":"session"}));
    assert_eq!(local["rows"][0]["id"], "session:local");
    fs::write(&release_metadata, "").unwrap();
    assert_eq!(wait_for_update(&mut exchange)["pending"], true);
    let named_tab = exchange(json!({"type":"query","query":"nvim","scope":"window"}));
    assert_eq!(named_tab["matched"], 1);
    assert_eq!(named_tab["rows"][1]["id"], fast_layout["rows"][1]["id"]);
    assert_eq!(named_tab["rows"][1]["title"], "nvim");
    let named_pane = exchange(json!({"type":"query","query":"nvim","scope":"pane","search_field":"command"}));
    assert_eq!(named_pane["matched"], 1);
    assert_eq!(named_pane["rows"][2]["id"], fallback["rows"][2]["id"]);
    assert_eq!(named_pane["rows"][2]["name"], "nvim");
    assert_eq!(named_pane["rows"][2]["title"], "Editor project");
    assert_eq!(named_pane["rows"][2]["path"], "/remote/editor");
    let miss = exchange(json!({"type":"query","query":"Slow workspace","scope":"all","search_field":"all"}));
    assert_eq!(miss["can_create"], true);
    fs::write(&release, "").unwrap();
    wait_for_update(&mut exchange);
    let stale = exchange(json!({"type":"activate","target_id":miss["preferred_id"]}));
    assert_eq!(stale["type"], "error");
    assert!(stale["message"].as_str().unwrap().contains("no longer available"));
    let combined = exchange(json!({"type":"query","query":"","scope":"session"}));
    assert_eq!(combined["matched"], 3);
    let previous = "remote:slow:session:local";
    assert_eq!(combined["preferred_id"], previous);
    assert_eq!(combined["previous_session_id"], previous);
    assert!(combined["previous_session_pending"].is_null());
    // Check the host and session have survived discovery in a single RPC.
    // Neither stale case should ever reach the local app's reveal command.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        let reply = rejected_switch.with_extension("reply");
        fs::write(&reply, r#"{"server_status":{"host_id":"replacement"},"attach_all":{"sessions":[{"session_id":"session:fast"}]}}"#).unwrap();
        let rejected = exchange(json!({"type":"activate","target_id":"remote:fast:session:fast"}));
        assert_eq!(rejected["type"], "error");
        assert!(rejected["message"].as_str().unwrap().contains("host changed"), "{rejected}");
        fs::write(&reply, r#"{"server_status":{"host_id":"fast"},"attach_all":{"sessions":[]}}"#).unwrap();
        let missing = exchange(json!({"type":"activate","target_id":"remote:fast:session:fast"}));
        assert_eq!(missing["type"], "error");
        assert!(missing["message"].as_str().unwrap().contains("session no longer exists"), "{missing}");
        assert_eq!(fs::read_to_string(&rejected_switch).unwrap(), "bootstrap\nbootstrap\n");
        fs::remove_file(reply).unwrap();
    }
    assert_eq!(exchange(local_open.clone())["preferred_id"], previous);
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        let activate = json!({"type":"activate","target_id":"remote:fast:session:fast"});
        // Reopening starts another inventory refresh. Drain it before counting
        // remote requests caused by Enter.
        while wait_for_update(&mut exchange)["pending"] == true {}
        let native = rejected_switch.with_extension("native");
        let inventory = rejected_switch.with_extension("reply");
        fs::write(&inventory, r#"{"server_status":{"host_id":"fast"},"attach_all":{"sessions":[{"session_id":"session:fast"}]}}"#).unwrap();
        fs::write(&rejected_switch, "").unwrap();
        fs::write(&native, r#"{"shown":true}"#).unwrap();
        assert_eq!(exchange(activate.clone())["type"], "activated");
        // A replaced route or an uncertain Show result never retries through SSH.
        for response in [r#"{"error":"replaced host"}"#, r#"{"error":"Show timed out"}"#, "broken reply"] {
            fs::write(&native, response).unwrap();
            assert_eq!(exchange(activate.clone())["type"], "error");
        }
        assert_eq!(fs::read_to_string(&rejected_switch).unwrap(), "");
        fs::write(&native, r#"{"needs_remote_check":true}"#).unwrap();
        assert_eq!(exchange(activate.clone())["type"], "activated");
        assert_eq!(fs::read_to_string(&rejected_switch).unwrap(), "bootstrap\n");
        fs::write(&rejected_switch, "").unwrap();
        let mut resident = activate;
        resident["native_reveal"] = true.into();
        let grant = exchange(resident.clone());
        assert_eq!(grant["type"], "reveal_remote");
        assert_eq!(grant["pid"], std::process::id());
        assert!(grant["birth"].as_str().is_some_and(|v| !v.is_empty()));
        assert_eq!(grant["session_id"], "session:fast");
        assert_eq!(grant["host_id"], "fast");
        let complete = |grant: &Value, result: Value| json!({"type":"complete_remote_reveal",
            "activation_id":grant["id"], "result":result});
        let confirmed = complete(&grant, json!({"shown":true}));
        let mut wrong = confirmed.clone();
        wrong["activation_id"] = 0.into();
        assert_eq!(exchange(wrong)["type"], "error");
        assert_eq!(exchange(confirmed.clone())["type"], "activated");
        assert_eq!(exchange(confirmed)["type"], "error");
        let grant = exchange(resident.clone());
        assert_eq!(exchange(complete(&grant, json!({"error":"Show timed out"})))["type"], "error");
        assert_eq!(fs::read_to_string(&rejected_switch).unwrap(), "");
        let grant = exchange(resident.clone());
        assert_eq!(exchange(complete(&grant, json!({"needs_remote_check":true})))["type"], "activated");
        assert_eq!(fs::read_to_string(&rejected_switch).unwrap(), "bootstrap\n");
        let grant = exchange(resident);
        assert_eq!(exchange(local_open)["preferred_id"], "remote:fast:session:fast");
        assert_eq!(exchange(complete(&grant, json!({"shown":true})))["type"], "error");
    }
    let preview = exchange(json!({"type":"open","preview_only":true}));
    assert_eq!(preview["remote_pending"], false);
    assert!(preview["rows"].as_array().unwrap().iter().all(|row| row["host"].is_null()));

    drop(exchange);
    drop(input);
    assert!(child.wait().unwrap().success());
    fs::remove_dir_all(temp).unwrap();
}

#[test]
fn reveal_callback_rejects_replaced_local_process_before_automation() {
    let output = Command::new(env!("CARGO_BIN_EXE_imux"))
        .args(["macos-serve", "--show-session", &std::process::id().to_string(),
            "old-birth", "remote", "session:remote"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("original Rex app closed"));
}

#[cfg(unix)]
#[test]
fn explicit_refresh_rediscovers_sessions_while_old_metadata_stalls() {
    use std::os::unix::fs::PermissionsExt;
    use std::time::{Duration, Instant};

    let temp = std::env::temp_dir().join(format!("imux-remote-refresh-{}", std::process::id()));
    fs::create_dir(&temp).unwrap();
    let rex = temp.join("rex");
    fs::write(&rex, r#"#!/bin/sh
root=${0%/*}
case " $* " in
    *' hosts list --json '*)
        echo '{"hosts":[{"label":"dev","host_id":"remote"}]}' ;;
    *' --server=dev api call session.bootstrap '*)
        echo inventory >>"$root/inventories"
        session=old
        if [ -f "$root/new-session" ]; then
            touch "$root/new-inventory-started"
            until [ -f "$root/release-inventory" ]; do sleep 0.02; done
            session=new
        fi
        printf '{"server_status":{"host_id":"remote"},"attach_all":{"sessions":[{"session_id":"session:%s","label":"%s"}]}}\n' "$session" "$session" ;;
    *' --server=dev '*'com.superlogical.terminal.title'*)
        echo "$$" >"$root/metadata-pid"
        exec sleep 30 ;;
    *' --server=dev '*'session.attach_all'*)
        case "$*" in
            *'session:new'*) echo '{"host_id":"remote","layouts":{"session:new":[]}}' ;;
            *) echo '{"host_id":"remote","layouts":{"session:old":[{"window_id":"window:old","panes":[{"block_id":"block:old","terminal":true}]}]}}' ;;
        esac ;;
    *' do - '*)
        source=$(cat)
        snapshot='{"version":1,"local_host_id":"local","sessions":[{"session_id":"session:local","label":"Local"}],"views":{"session:local":{"windows":[]}}}'
        case "$source" in
            *'return {clients=clients,snapshot='*)
                printf '{"clients":{"clients":[{"client_id":"client:mac","info":{"kind":"app","platform":"macos"},"principal":{"kind":"peer","transport":"unix"}}]},"snapshot":%s}\n' "$snapshot" ;;
            *) echo "$snapshot" ;;
        esac ;;
    *) exit 1 ;;
esac
"#).unwrap();
    fs::set_permissions(&rex, fs::Permissions::from_mode(0o700)).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_imux"))
        .arg("macos-serve")
        .env("HOME", &temp)
        .env("INTERDIMUX_REX_BIN", &rex)
        .env("INTERDIMUX_SHOW_DIRS", "off")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn().unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    let mut exchange = |mut request: Value| -> Value {
        request["id"] = json!(1);
        writeln!(input, "{request}").unwrap();
        input.flush().unwrap();
        let mut line = String::new();
        assert!(output.read_line(&mut line).unwrap() > 0);
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_ne!(response["type"], "error", "{response}");
        response
    };
    let open = json!({"type":"open","context":{"client_id":"client:mac","session_id":"session:local"}});
    let has = |response: &Value, id: &str| response["rows"].as_array().unwrap().iter().any(|r| r["id"] == id);
    let wait = |marker: &str| {
        let deadline = Instant::now() + Duration::from_secs(4);
        while !temp.join(marker).exists() {
            assert!(Instant::now() < deadline, "Timed out waiting for {marker}");
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    assert!(has(&exchange(open.clone()), "session:local"));
    wait("metadata-pid");
    assert!(has(&exchange(open.clone()), "remote:remote:session:old"));
    assert_eq!(fs::read_to_string(temp.join("inventories")).unwrap().lines().count(), 1);
    fs::write(temp.join("new-session"), "").unwrap();
    let start = Instant::now();
    let refreshed = exchange(json!({"type":"refresh"}));
    assert!(has(&refreshed, "session:local"));
    assert!(start.elapsed() < Duration::from_secs(3), "Local results waited for remote enrichment");
    wait("new-inventory-started");
    let pid = fs::read_to_string(temp.join("metadata-pid")).unwrap();
    assert!(!Command::new("kill").args(["-0", pid.trim()]).stderr(Stdio::null()).status().unwrap().success());

    // The old session stays visible until its replacement inventory arrives.
    for request in [json!({"type":"refresh"}), open, json!({"type":"refresh"})] {
        assert!(has(&exchange(request), "remote:remote:session:old"));
    }
    fs::write(temp.join("release-inventory"), "").unwrap();
    let deadline = Instant::now() + Duration::from_secs(4);
    while exchange(json!({"type":"remote_update"}))["pending"] == true {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    let result = exchange(json!({"type":"query","scope":"session","query":""}));
    assert!(has(&result, "remote:remote:session:new"));
    assert!(!has(&result, "remote:remote:session:old"));
    assert_eq!(fs::read_to_string(temp.join("inventories")).unwrap().lines().count(), 2);
    drop(exchange);
    drop(input);
    assert!(child.wait().unwrap().success());
    fs::remove_dir_all(temp).unwrap();
}

#[test]
fn native_picker_normalization_uses_declared_letters_without_false_matches() {
    let cases = [
        ("extended-latin", "ḃeta", "beta", "eeta"),
        ("vietnamese", "ỏrb", "orb", "srb"),
        ("vietnamese-boundary", "ỷard", "yard", "aard"),
        ("superscript", "ⁱtem", "item", "atem"),
        ("subscript", "ₕello", "hello", "aello"),
        ("accent-control", "écho", "echo", "acho"),
        ("umlaut-control", "ömega", "omega", "amega"),
    ];
    let path = std::env::temp_dir().join(format!(
        "imux-native-picker-normalization-{}.json",
        std::process::id()
    ));
    let rows: Vec<_> = cases
        .iter()
        .map(|(id, name, _, _)| json!({"id":id,"kind":"session","title":name,"search_name":name}))
        .collect();
    fs::write(&path, json!({"rows":rows}).to_string()).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_imux"))
        .args(["macos-serve", "--fixture"])
        .arg(&path)
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
        assert!(output.read_line(&mut line).unwrap() > 0);
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], request["id"]);
        response
    };
    exchange(json!({"id":1,"type":"open"}));
    fs::remove_file(&path).unwrap();
    for (id, literal, normalized, wrong) in cases {
        for (query, expected) in [
            (normalized.to_owned(), vec![id]),
            (format!("'{normalized}"), vec![id]),
            (literal.to_owned(), vec![id]),
            (format!("'{literal}"), vec![id]),
            (wrong.to_owned(), vec![]),
            (format!("'{wrong}"), vec![]),
            (
                format!("!{normalized}"),
                cases
                    .iter()
                    .map(|case| case.0)
                    .filter(|key| *key != id)
                    .collect(),
            ),
        ] {
            let response = exchange(
                json!({"id":2,"type":"query","query":query,"search_field":"name","allow_create":false}),
            );
            assert_eq!(response["type"], "results", "{query:?}");
            let mut ids: Vec<_> = response["rows"]
                .as_array()
                .unwrap()
                .iter()
                .map(|row| row["id"].as_str().unwrap())
                .collect();
            let mut expected = expected;
            ids.sort_unstable();
            expected.sort_unstable();
            assert_eq!(ids, expected, "{query:?}");
            assert_eq!(response["matched"], expected.len(), "{query:?}");
            assert_eq!(response["can_create"], false, "{query:?}");
        }
    }
    drop(exchange);
    drop(input);
    assert!(child.wait().unwrap().success());
}

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
    fs::write(&path,json!({"rows":[
        {"id":"weak-live","kind":"pane","title":"frontend logs utilities index diagnostics"},
        {"id":"fluid-project","kind":"directory","title":"fluid-packages-sui","path":"/Network/no-probe/fluid-packages-sui"}
    ]}).to_string()).unwrap();
    exchange(json!({"id":200,"type":"refresh"}));
    fs::remove_file(&path).unwrap();
    for query in ["flui", "fluid", "'fluid", "^fluid"] {
        let ranked = exchange(
            json!({"id":201,"type":"query","query":query,"scope":"all","search_field":"all"}),
        );
        assert_eq!(ranked["preferred_id"], "fluid-project");
        assert_eq!(ranked["rows"][0]["id"], "fluid-project");
    }
    let scoped = exchange(json!({"id":202,"type":"query","query":"fluid","scope":"pane"}));
    assert_eq!(scoped["preferred_id"], "weak-live");
    fs::write(
        &path,
        json!({"rows":[
            {"id":"digits","kind":"session","title":"12AB origin","search_name":"12AB origin"},
            {"id":"uppercase","kind":"session","title":"Alpha beta","search_name":"Alpha beta"},
            {"id":"unicode-space","kind":"session","title":"東京 x","search_name":"東京 x"},
            {"id":"unicode-backslash","kind":"session","title":"東京\\ x","search_name":"東京\\ x"},
            {"id":"space","kind":"session","title":"foo bar","search_name":"foo bar"},
            {"id":"dollar","kind":"session","title":"foo$bar","search_name":"foo$bar"}
        ]})
        .to_string(),
    )
    .unwrap();
    exchange(json!({"id":203,"type":"refresh"}));
    fs::remove_file(&path).unwrap();
    for (query, expected) in [
        ("'12ab", "digits"),
        ("^Alpha", "uppercase"),
        ("'東京\\ x", "unicode-space"),
        ("^東京\\ x$", "unicode-space"),
        ("foo\\", ""),
        ("foo\\ ", "space"),
        ("foo$", ""),
        ("foo$b", "dollar"),
    ] {
        let result = exchange(
            json!({"id":204,"type":"query","query":query,"scope":"all","search_field":"name","allow_create":false}),
        );
        assert_eq!(
            result["matched"],
            u64::from(!expected.is_empty()),
            "{query:?}"
        );
        if !expected.is_empty() {
            assert_eq!(result["preferred_id"], expected, "{query:?}");
            assert_eq!(result["rows"][0]["id"], expected, "{query:?}");
        }
        assert_eq!(result["can_create"], false);
    }
    drop(exchange);
    drop(input);
    assert!(child.wait().unwrap().success());
}

#[cfg(unix)]
#[test]
fn preview_worker_opens_without_collecting_a_second_catalog() {
    use std::os::unix::fs::PermissionsExt;

    let temp = std::env::temp_dir().join(format!("imux-preview-worker-{}", std::process::id()));
    fs::create_dir(&temp).unwrap();
    let rex = temp.join("rex");
    fs::write(&rex, r#"#!/bin/sh
clients='{"clients":[{"client_id":"app","info":{"kind":"app","platform":"macos"},"principal":{"kind":"peer","transport":"unix"}}]}'
case "$*" in
    *' do -e '*)
        IFS= read -r handshake
        if [ "$IMUX_TEST_PREVIEW" = legacy ]; then echo '"imux-preview-oneshot"'; exit 0; fi
        echo "$clients"
        while IFS= read -r request; do
            case "$request" in
                *closed*) echo '{"error":"pane closed"}' ;;
                *broken*) echo malformed; exit 1 ;;
                *) echo '{"text":"exact pane output"}' ;;
            esac
        done
        exit 0 ;;
esac
source=$(cat)
case "$source" in
    *"session.attach_all"*) echo 'unexpected full collection' >&2; exit 1 ;;
    *"client.list"*) echo "$clients" ;;
    *'rex.call("session.attach", {session_id=request.target.session_id})'*) echo '{"text":"exact pane output"}' ;;
    *) exit 1 ;;
esac
"#).unwrap();
    fs::set_permissions(&rex, fs::Permissions::from_mode(0o700)).unwrap();
    for mode in ["stream", "legacy"] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_imux"))
            .arg("macos-serve")
            .env("INTERDIMUX_REX_BIN", &rex)
            .env("IMUX_TEST_PREVIEW", mode)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut input = child.stdin.take().unwrap();
        let capture = |pane| {
            json!({"id":4,"type":"capture_preview","target_id":"w",
            "target":{"session_id":"s","window_id":"w","block_id":pane},"lines":20})
        };
        let mut requests = vec![
            capture("a"),
            json!({"id":2,"type":"open_preview","context":{"client_id":"wrong"}}),
            json!({"id":3,"type":"open_preview","context":{"client_id":"app"}}),
            capture("a"),
            json!({"id":5,"type":"query","query":""}),
        ];
        if mode == "stream" {
            requests.extend([
                capture("closed"),
                capture("a"),
                capture("broken"),
                capture("a"),
            ]);
        }
        requests.extend([
            json!({"id":6,"type":"open_preview","context":{"client_id":"wrong"}}),
            capture("a"),
        ]);
        for request in requests {
            writeln!(input, "{request}").unwrap();
        }
        drop(input);
        let responses: Vec<Value> = BufReader::new(child.stdout.take().unwrap())
            .lines()
            .map(|line| serde_json::from_str(&line.unwrap()).unwrap())
            .collect();
        assert!(child.wait().unwrap().success());
        let mut expected = vec!["error", "error", "preview_ready", "preview", "error"];
        if mode == "stream" {
            expected.extend(["error", "preview", "error", "error"]);
        }
        expected.extend(["error", "error"]);
        assert_eq!(
            responses
                .iter()
                .map(|r| r["type"].as_str().unwrap())
                .collect::<Vec<_>>(),
            expected,
            "{responses:?}"
        );
        assert_eq!(responses[3]["target_id"], "w");
        assert_eq!(responses[3]["text"], "exact pane output");
    }
    fs::remove_dir_all(&temp).unwrap();
}
