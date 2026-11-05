//! Native actions against private tmux servers. No user socket or session is used.
#![cfg(unix)]

use crate::model::{Snapshot, Target};
use crate::tmux_backend::{self, TmuxContext};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    name: String,
    outer: String,
    directory: PathBuf,
    context: TmuxContext,
    session: Target,
    first_window: Target,
    second_window: Target,
    panes: Vec<Target>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        for name in [&self.outer, &self.name] {
            let _ = Command::new("tmux")
                .args(["-L", name, "kill-server"])
                .env_remove("TMUX")
                .output();
        }
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn supported() -> bool {
    let Ok(output) = Command::new("tmux").arg("-V").output() else {
        return false;
    };
    let version = String::from_utf8_lossy(&output.stdout);
    let parts: Vec<_> = version
        .split(|c: char| !c.is_ascii_digit())
        .filter(|s| !s.is_empty())
        .filter_map(|s| s.parse::<u32>().ok())
        .collect();
    parts.len() >= 2 && (parts[0], parts[1]) >= (3, 6)
}

fn native(target: &Target) -> (&str, Option<&str>, Option<&str>) {
    match target {
        Target::TmuxNative {
            session_id,
            window_id,
            pane_id,
        } => (session_id, window_id.as_deref(), pane_id.as_deref()),
        _ => panic!("expected a native tmux target"),
    }
}

impl Fixture {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let name = format!(
            "imux-actions-{}-{nonce}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let directory = std::env::temp_dir().join(&name);
        std::fs::create_dir(&directory).unwrap();
        let placeholder = Target::TmuxLegacy {
            spec: String::new(),
        };
        let mut fixture = Self {
            outer: format!("{name}-outer"),
            name,
            directory,
            context: TmuxContext::default(),
            session: placeholder.clone(),
            first_window: placeholder.clone(),
            second_window: placeholder,
            panes: Vec::new(),
        };
        fixture.tmux(&[
            "-f",
            "/dev/null",
            "new-session",
            "-d",
            "-s",
            "human-session",
            "-n",
            "first",
            "-x",
            "200",
            "-y",
            "40",
            "exec /bin/cat",
        ]);
        fixture.tmux(&["set-option", "-g", "default-shell", "/bin/sh"]);
        fixture.tmux(&["set-option", "-g", "default-command", "exec /bin/cat"]);
        fixture.tmux(&["set-option", "-g", "renumber-windows", "off"]);
        fixture.tmux(&["set-window-option", "-g", "automatic-rename", "off"]);
        fixture.tmux(&[
            "split-window",
            "-d",
            "-h",
            "-t",
            "=human-session:0",
            "exec /bin/cat",
        ]);
        fixture.tmux(&[
            "new-window",
            "-d",
            "-t",
            "=human-session:1",
            "-n",
            "second",
            "exec /bin/cat",
        ]);
        let guard = fixture.tmux(&[
            "new-session",
            "-d",
            "-s",
            "kept",
            "-n",
            "guard",
            "-P",
            "-F",
            "#{pane_id}",
            "exec /bin/cat",
        ]);
        let socket = fixture.tmux(&["display-message", "-p", "#{socket_path}"]);
        fixture.context = TmuxContext {
            client: None,
            block: Some(guard.trim().into()),
            socket: Some(socket.trim().into()),
        };
        let snapshot = fixture.snapshot();
        let session = snapshot
            .sessions
            .iter()
            .find(|s| s.name == "human-session")
            .unwrap();
        let first = snapshot
            .windows
            .iter()
            .find(|w| w.session_key == session.key && w.name == "first")
            .unwrap();
        let second = snapshot
            .windows
            .iter()
            .find(|w| w.session_key == session.key && w.name == "second")
            .unwrap();
        fixture.session = session.target.clone();
        fixture.first_window = first.target.clone();
        fixture.second_window = second.target.clone();
        fixture.panes = snapshot
            .panes
            .iter()
            .filter(|p| p.session_key == session.key)
            .map(|p| p.target.clone())
            .collect();
        assert_eq!(fixture.panes.len(), 3);
        // Never send test strings to a shell while a login/startup is pending.
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if fixture.panes.iter().all(|target| {
                fixture
                    .tmux(&[
                        "display-message",
                        "-p",
                        "-t",
                        native(target).2.unwrap(),
                        "#{pane_current_command}",
                    ])
                    .trim()
                    == "cat"
            }) {
                break;
            }
            assert!(Instant::now() < deadline, "private cat panes did not start");
            thread::sleep(Duration::from_millis(20));
        }
        fixture
    }

    fn command(&self, outer: bool) -> Command {
        let mut command = Command::new("tmux");
        command.args(["-L", if outer { &self.outer } else { &self.name }]);
        command.env_remove("TMUX").env_remove("TMUX_PANE");
        command
    }

    fn tmux(&self, args: &[&str]) -> String {
        let output = self.command(false).args(args).output().unwrap();
        assert!(
            output.status.success(),
            "tmux {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }

    fn snapshot(&self) -> Snapshot {
        tmux_backend::collect(&self.context).unwrap()
    }

    fn action(&self, op: &str, target: Option<&Target>, args: Value) -> Value {
        crate::tmux_actions::action(&self.context, op, target, &args)
            .unwrap_or_else(|error| panic!("{op} {target:?}: {error}"))
    }

    fn capture(&self, target: &Target) -> String {
        self.tmux(&[
            "capture-pane",
            "-p",
            "-J",
            "-S",
            "-200",
            "-t",
            native(target).2.unwrap(),
        ])
    }

    fn await_text(&self, target: &Target, text: &str) {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            if self.capture(target).contains(text) {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "pane {target:?} did not receive {text:?}"
            );
            thread::sleep(Duration::from_millis(15));
        }
    }

    fn guard_target(&self) -> Target {
        self.snapshot()
            .panes
            .into_iter()
            .find(|p| native(&p.target).2 == self.context.block.as_deref())
            .unwrap()
            .target
    }
}

#[test]
fn native_send_resolves_grouping_keys_and_preserves_literal_text() {
    if !supported() {
        eprintln!("tmux >=3.6 unavailable; private action test skipped");
        return;
    }
    let fixture = Fixture::new();
    let guard = fixture.guard_target();
    fixture.action(
        "send",
        Some(&fixture.panes[0]),
        json!({"text":"PANE-ONLY","enter":true}),
    );
    fixture.await_text(&fixture.panes[0], "PANE-ONLY");
    assert!(!fixture.capture(&fixture.panes[1]).contains("PANE-ONLY"));
    assert!(!fixture.capture(&fixture.panes[2]).contains("PANE-ONLY"));
    fixture.action(
        "send",
        Some(&fixture.first_window),
        json!({"text":"WINDOW-ONLY","enter":true}),
    );
    fixture.await_text(&fixture.panes[0], "WINDOW-ONLY");
    fixture.await_text(&fixture.panes[1], "WINDOW-ONLY");
    assert!(!fixture.capture(&fixture.panes[2]).contains("WINDOW-ONLY"));
    fixture.action(
        "send",
        Some(&fixture.session),
        json!({"text":"SESSION-ALL","enter":true}),
    );
    for pane in &fixture.panes {
        fixture.await_text(pane, "SESSION-ALL");
    }
    assert!(!fixture.capture(&guard).contains("SESSION-ALL"));
    let marker = fixture.directory.join("must-not-be-created");
    let literal = format!("literal ; $(touch {})", marker.display());
    fixture.action(
        "send",
        Some(&fixture.panes[0]),
        json!({"text":literal,"enter":true}),
    );
    fixture.await_text(&fixture.panes[0], &literal);
    assert!(!marker.exists());
    fixture.action(
        "send",
        Some(&fixture.panes[0]),
        json!({"text":";","enter":false}),
    );
    fixture.await_text(&fixture.panes[0], ";");
}

#[test]
fn linked_window_send_uses_the_selected_sessions_grouping_key() {
    if !supported() {
        eprintln!("tmux >=3.6 unavailable; private action test skipped");
        return;
    }
    let fixture = Fixture::new();
    let guard = fixture.guard_target();
    let shared_id = native(&fixture.first_window).1.unwrap();
    let kept_id = native(&guard).0;
    fixture.tmux(&[
        "link-window",
        "-s",
        &format!("{}:{shared_id}", native(&fixture.session).0),
        "-t",
        &format!("{kept_id}:1"),
    ]);
    let snapshot = fixture.snapshot();
    let linked = snapshot
        .windows
        .iter()
        .find(|w| {
            let (sid, wid, _) = native(&w.target);
            sid == kept_id && wid == Some(shared_id)
        })
        .unwrap();
    fixture.action(
        "send",
        Some(&linked.target),
        json!({"text":"LINKED-WINDOW-ONLY","enter":true}),
    );
    fixture.await_text(&fixture.panes[0], "LINKED-WINDOW-ONLY");
    fixture.await_text(&fixture.panes[1], "LINKED-WINDOW-ONLY");
    assert!(!fixture
        .capture(&fixture.panes[2])
        .contains("LINKED-WINDOW-ONLY"));
    assert!(!fixture.capture(&guard).contains("LINKED-WINDOW-ONLY"));
}

#[test]
fn rename_reorder_create_split_swap_and_close_keep_native_identity() {
    if !supported() {
        eprintln!("tmux >=3.6 unavailable; private action test skipped");
        return;
    }
    let fixture = Fixture::new();
    fixture.action(
        "rename",
        Some(&fixture.session),
        json!({"name":"renamed ; $(literal)"}),
    );
    fixture.action(
        "rename",
        Some(&fixture.first_window),
        json!({"name":"renamed-window"}),
    );
    fixture.action(
        "rename",
        Some(&fixture.panes[0]),
        json!({"name":"renamed-pane"}),
    );
    let snapshot = fixture.snapshot();
    assert!(snapshot
        .sessions
        .iter()
        .any(|s| s.target == fixture.session && s.name == "renamed ; $(literal)"));
    assert!(snapshot
        .windows
        .iter()
        .any(|w| w.target == fixture.first_window && w.name == "renamed-window"));
    assert!(snapshot
        .panes
        .iter()
        .any(|p| p.target == fixture.panes[0] && p.name == "renamed-pane"));
    let (sid, first_id, _) = native(&fixture.first_window);
    fixture.tmux(&[
        "move-window",
        "-s",
        first_id.unwrap(),
        "-t",
        &format!("{sid}:9"),
    ]);
    fixture.tmux(&[
        "swap-pane",
        "-d",
        "-s",
        native(&fixture.panes[0]).2.unwrap(),
        "-t",
        native(&fixture.panes[1]).2.unwrap(),
    ]);
    fixture.action(
        "rename",
        Some(&fixture.first_window),
        json!({"name":"still-same-window"}),
    );
    fixture.action(
        "rename",
        Some(&fixture.panes[0]),
        json!({"name":"still-same-pane"}),
    );
    fixture.action(
        "send",
        Some(&fixture.first_window),
        json!({"text":"AFTER-REORDER","enter":true}),
    );
    fixture.await_text(&fixture.panes[0], "AFTER-REORDER");
    fixture.await_text(&fixture.panes[1], "AFTER-REORDER");
    assert!(!fixture.capture(&fixture.panes[2]).contains("AFTER-REORDER"));

    let created = fixture.action(
        "create",
        Some(&fixture.session),
        json!({"kind":"window","name":"created-window","cwd":fixture.directory.to_str().unwrap()}),
    );
    let created_pane = crate::interactive::decode_target(&created["target"], "tmux").unwrap();
    let (created_sid, created_wid, created_pid) = native(&created_pane);
    assert_eq!(created_sid, sid);
    let created_window = Target::TmuxNative {
        session_id: sid.into(),
        window_id: created_wid.map(str::to_owned),
        pane_id: None,
    };
    let split = fixture.action("split", Some(&created_window), json!({"direction":"down"}));
    let split_pane = crate::interactive::decode_target(&split["target"], "tmux").unwrap();
    assert_eq!(native(&split_pane).1, created_wid);
    assert_ne!(native(&split_pane).2, created_pid);
    fixture.action("zoom", Some(&created_window), json!({}));
    assert_eq!(
        fixture
            .tmux(&[
                "display-message",
                "-p",
                "-t",
                created_wid.unwrap(),
                "#{window_zoomed_flag}"
            ])
            .trim(),
        "1"
    );
    fixture.action("zoom", Some(&created_window), json!({}));
    assert_eq!(
        fixture
            .tmux(&[
                "display-message",
                "-p",
                "-t",
                created_wid.unwrap(),
                "#{window_zoomed_flag}"
            ])
            .trim(),
        "0"
    );
    fixture.action(
        "swap",
        Some(&fixture.panes[0]),
        json!({"other":crate::interactive::target_json(&split_pane)}),
    );
    let moved_pid = native(&fixture.panes[0]).2.unwrap();
    assert_eq!(
        fixture
            .tmux(&["display-message", "-p", "-t", moved_pid, "#{window_id}"])
            .trim(),
        created_wid.unwrap()
    );
    assert!(
        crate::tmux_actions::action(
            &fixture.context,
            "rename",
            Some(&fixture.panes[0]),
            &json!({"name":"wrong-object"})
        )
        .is_err(),
        "a moved pane's old parent scope must not target its replacement"
    );
    fixture.action(
        "swap",
        Some(&fixture.first_window),
        json!({"other":crate::interactive::target_json(&fixture.second_window)}),
    );
    fixture.action(
        "rename",
        Some(&fixture.first_window),
        json!({"name":"native-window-after-swap"}),
    );
    assert_eq!(
        fixture
            .tmux(&[
                "display-message",
                "-p",
                "-t",
                first_id.unwrap(),
                "#{window_name}"
            ])
            .trim(),
        "native-window-after-swap"
    );
    fixture.action("close", Some(&created_window), json!({}));
    assert!(!fixture
        .snapshot()
        .windows
        .iter()
        .any(|w| w.target == created_window));
    let extra = fixture.action(
        "create",
        None,
        json!({"name":"extra-session","cwd":fixture.directory.to_str().unwrap()}),
    );
    let extra_pane = crate::interactive::decode_target(&extra["target"], "tmux").unwrap();
    let extra_session = Target::TmuxNative {
        session_id: native(&extra_pane).0.into(),
        window_id: None,
        pane_id: None,
    };
    fixture.action("close", Some(&extra_session), json!({}));
    fixture.action("close", Some(&fixture.session), json!({}));
    let snapshot = fixture.snapshot();
    assert_eq!(snapshot.sessions.len(), 1);
    assert_eq!(snapshot.sessions[0].name, "kept");
}

#[test]
fn closing_the_source_last_window_or_pane_hops_its_attached_client_first() {
    if !supported() {
        eprintln!("tmux >=3.6 unavailable; private action test skipped");
        return;
    }
    let binary = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .map(|directory| directory.join("tmux"))
        .find(|path| path.is_file())
        .unwrap();
    for kind in ["window", "pane"] {
        let fixture = Fixture::new();
        fixture.action("close", Some(&fixture.second_window), json!({}));
        if kind == "pane" {
            fixture.action("close", Some(&fixture.panes[1]), json!({}));
        }
        let session = native(&fixture.session).0;
        let attach = format!(
            "TMUX= {} -S {} attach-session -t {}; exec /bin/cat",
            crate::interactive::quote(binary.to_str().unwrap()),
            crate::interactive::quote(fixture.context.socket.as_ref().unwrap()),
            crate::interactive::quote(session)
        );
        let output = fixture
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
                &attach,
            ])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        let client = loop {
            let clients = fixture.tmux(&["list-clients", "-F", "#{client_name}"]);
            if let Some(client) = clients.lines().find(|name| !name.is_empty()) {
                break client.to_owned();
            }
            assert!(Instant::now() < deadline, "private client did not attach");
            thread::sleep(Duration::from_millis(20));
        };
        let source = TmuxContext {
            client: Some(client.clone()),
            block: native(&fixture.panes[0]).2.map(str::to_owned),
            socket: fixture.context.socket.clone(),
        };
        let target = if kind == "pane" {
            &fixture.panes[0]
        } else {
            &fixture.first_window
        };
        crate::tmux_actions::action(&source, "close", Some(target), &json!({})).unwrap();
        let clients = fixture.tmux(&[
            "list-clients",
            "-F",
            "#{client_name}\u{1f}#{client_session}",
        ]);
        assert!(
            clients
                .lines()
                .any(|line| line == format!("{client}\u{1f}kept")),
            "closing the source {kind} detached its client instead of moving it: {clients:?}"
        );
        let snapshot = tmux_backend::collect(&source).unwrap();
        assert_eq!(snapshot.sessions.len(), 1);
        assert_eq!(snapshot.current.session_key, "kept");
    }
}

#[test]
fn scheduled_target_survives_focus_changes_and_refuses_a_different_server() {
    if !supported() {
        return;
    }
    let fixture = Fixture::new();
    fixture.tmux(&["select-pane", "-t", native(&fixture.panes[0]).2.unwrap()]);
    let descriptor = fixture.action("schedule-target", Some(&fixture.first_window), json!({}));
    assert_eq!(
        descriptor["target"]["pane_id"],
        native(&fixture.panes[0]).2.unwrap()
    );
    fixture.tmux(&["select-pane", "-t", native(&fixture.panes[1]).2.unwrap()]);
    fixture.tmux(&["copy-mode", "-t", native(&fixture.panes[0]).2.unwrap()]);
    let text = "scheduled $(must-not-execute); $HOME";
    crate::tmux_actions::run_job(&descriptor, &json!({"text":text,"enter":true})).unwrap();
    fixture.await_text(&fixture.panes[0], text);
    assert!(!fixture.capture(&fixture.panes[1]).contains(text));
    assert_eq!(
        fixture
            .tmux(&[
                "display-message",
                "-p",
                "-t",
                native(&fixture.panes[0]).2.unwrap(),
                "#{pane_in_mode}"
            ])
            .trim(),
        "0"
    );
    let mut stale = descriptor;
    stale["guard"]["started"] = json!("not-this-server");
    let error = crate::tmux_actions::run_job(&stale, &json!({"text":"wrong-server","enter":true}))
        .unwrap_err();
    assert!(error.contains("restarted or changed"));
    assert!(!fixture.capture(&fixture.panes[0]).contains("wrong-server"));
}

#[test]
fn startup_commands_run_literally_only_in_a_created_session() {
    if !supported() {
        return;
    }
    let fixture = Fixture::new();
    fixture.tmux(&["set-option", "-g", "default-command", ""]);
    let marker = fixture.directory.join("startup-ran");
    let line = format!(
        "printf '%s' 'startup-ok' > {}",
        crate::interactive::quote(marker.to_str().unwrap())
    );
    let made = fixture.action("create", None, json!({"kind":"session","name":"startup-project","cwd":fixture.directory,"startup_lines":[line]}));
    let target = crate::interactive::decode_target(&made["target"], "tmux").unwrap();
    let until = Instant::now() + Duration::from_secs(3);
    while std::fs::read_to_string(&marker).ok().as_deref() != Some("startup-ok") {
        assert!(Instant::now() < until, "startup did not run in new shell");
        thread::sleep(Duration::from_millis(15));
    }
    let existing = fixture.action(
        "create",
        None,
        json!({"kind":"session","name":"startup-project","startup_lines":["printf duplicate"]}),
    );
    assert_eq!(
        existing["target"]["session_id"],
        made["target"]["session_id"]
    );
    assert!(!fixture.capture(&target).contains("duplicate"));
}

#[test]
fn native_names_and_directories_are_not_tmux_formats() {
    if !supported() {
        return;
    }
    let fixture = Fixture::new();
    for name in ["project#{session_name}", "p#[q", ";", "semi;colon"] {
        let cwd = fixture.directory.join(format!("dir-{name}"));
        std::fs::create_dir(&cwd).unwrap();
        let made = fixture.action(
            "create",
            None,
            json!({"kind":"session","name":name,"cwd":cwd}),
        );
        let target = crate::interactive::decode_target(&made["target"], "tmux").unwrap();
        let id = native(&target).2.unwrap();
        let actual = fixture.tmux(&[
            "display-message",
            "-p",
            "-t",
            id,
            "#{session_name}\u{1f}#{pane_current_path}",
        ]);
        assert_eq!(
            actual.trim(),
            format!(
                "{name}\u{1f}{}",
                std::fs::canonicalize(&cwd).unwrap().display()
            )
        );
        let renamed = format!("renamed-{name}");
        let session = Target::TmuxNative {
            session_id: native(&target).0.into(),
            window_id: None,
            pane_id: None,
        };
        fixture.action("rename", Some(&session), json!({"name":renamed}));
        assert_eq!(
            fixture
                .tmux(&["display-message", "-p", "-t", id, "#{session_name}"])
                .trim(),
            renamed
        );
    }
    fixture.action(
        "rename",
        Some(&fixture.panes[0]),
        json!({"name":"pane#{pane_id}"}),
    );
    assert_eq!(
        fixture
            .tmux(&[
                "display-message",
                "-p",
                "-t",
                native(&fixture.panes[0]).2.unwrap(),
                "#{pane_title}"
            ])
            .trim(),
        "pane#{pane_id}"
    );
}
