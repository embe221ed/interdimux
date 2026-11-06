//! Explicit native-picker actions. Identity comes from the retained snapshot;
//! values remain literal data and existing Rex operations recheck membership.

use crate::model::{Snapshot, Target};
use crate::projects::CreateTarget;
use crate::rex::{self, RexContext};
use serde_json::{json, Value};

#[derive(Clone, Debug)]
pub(super) struct ActionSelection {
    /// Semantic row identity: a combined tab/pane row still renames its tab.
    pub target: Target,
    /// Exact sole pane for pane operations on a combined row.
    pub pane_target: Option<Target>,
    pub title: String,
    pub name: String,
    pub path: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Session,
    Window,
    Pane,
}

fn kind(target: &Target) -> Result<Kind, String> {
    let Target::Rex {
        session_id,
        window_id,
        block_id,
    } = target
    else {
        return Err("Choose an existing Rex session, tab or pane".into());
    };
    if session_id.is_empty()
        || window_id.as_deref() == Some("")
        || block_id.as_deref() == Some("")
        || (block_id.is_some() && window_id.is_none())
    {
        return Err("The selected Rex target has incomplete IDs; refresh the picker".into());
    }
    Ok(if block_id.is_some() {
        Kind::Pane
    } else if window_id.is_some() {
        Kind::Window
    } else {
        Kind::Session
    })
}

fn pane_target(selected: &ActionSelection) -> Result<&Target, String> {
    kind(&selected.target)?;
    let Some(pane) = &selected.pane_target else {
        return Ok(&selected.target);
    };
    if kind(pane)? != Kind::Pane {
        return Err("The combined row has no exact pane; refresh the picker".into());
    }
    let Target::Rex {
        session_id,
        window_id,
        block_id,
    } = &selected.target
    else {
        unreachable!()
    };
    let Target::Rex {
        session_id: pane_session,
        window_id: pane_window,
        ..
    } = pane
    else {
        unreachable!()
    };
    if session_id != pane_session
        || window_id
            .as_ref()
            .is_some_and(|window| Some(window) != pane_window.as_ref())
        || (block_id.is_some() && &selected.target != pane)
    {
        return Err("The combined pane does not belong to this target; refresh the picker".into());
    }
    Ok(pane)
}

pub(super) fn available(selected: &ActionSelection) -> Vec<&'static str> {
    let Ok(target_kind) = kind(&selected.target) else {
        return Vec::new();
    };
    let mut operations = vec!["rename", "close", "new-window"];
    if target_kind != Kind::Session {
        operations.push("swap");
    }
    if pane_target(selected).is_ok() {
        operations.extend(["zoom", "split-right", "split-down", "send", "preview"]);
    }
    operations
}

fn value(request: &Value, label: &str, allow_empty: bool) -> Result<String, String> {
    let value = request["value"]
        .as_str()
        .ok_or_else(|| format!("Enter {label}"))?;
    if value.len() > 32 * 1024 {
        return Err(format!("The {label} exceeds 32 KiB"));
    }
    if !allow_empty && value.trim().is_empty() {
        return Err(format!("Enter {label}"));
    }
    Ok(value.into())
}

fn result(close: bool, message: String) -> Value {
    json!({"close_picker":close,"refresh":!close,"message":message})
}

fn caption(selected: &ActionSelection) -> &str {
    if selected.title.is_empty() {
        &selected.name
    } else {
        &selected.title
    }
}

/// The parent checks fixture mode before calling this function. No action is
/// performed while filtering, selecting a row, or calculating capabilities.
pub(super) fn run(
    context: &RexContext,
    snapshot: &Snapshot,
    selected: Option<&ActionSelection>,
    secondary: Option<&ActionSelection>,
    request: &Value,
) -> Result<Value, String> {
    let allow_startup = context
        .result_file
        .as_ref()
        .and_then(|path| path.parent())
        .is_some()
        || snapshot
            .pane_metadata
            .values()
            .any(|metadata| metadata.local);
    run_with(
        snapshot,
        selected,
        secondary,
        request,
        allow_startup,
        &mut |operation, target, args| {
            if operation == "activate" {
                rex::activate(context, target.ok_or("Select a session to activate")?)?;
                Ok(json!({}))
            } else {
                rex::action(context, operation, target, args)
            }
        },
    )
}

fn resolve_directory(snapshot: &Snapshot, path: &str) -> Result<CreateTarget, String> {
    let physical = super::directories::exact_path(path)?;
    // The shared create-session parser strips fzf operators. Quote the entire
    // literal absolute path and escape spaces so path characters retain their
    // meaning, including a final $, apostrophes, backslashes and " | ".
    let query = format!("'{}'", physical.replace(' ', "\\ "));
    let resolved = crate::projects::resolve(snapshot, &query)?;
    if !resolved.path_query || resolved.cwd != physical {
        return Err("The selected directory could not be resolved exactly".into());
    }
    Ok(resolved)
}

pub(super) fn open_directory(
    context: &RexContext,
    snapshot: &Snapshot,
    path: &str,
) -> Result<Value, String> {
    let resolved = resolve_directory(snapshot, path)?;
    let allow_startup = context
        .result_file
        .as_ref()
        .and_then(|path| path.parent())
        .is_some()
        || snapshot
            .pane_metadata
            .values()
            .any(|metadata| metadata.local);
    create_resolved(
        resolved,
        allow_startup,
        &mut |operation, target, args| {
            if operation == "activate" {
                rex::activate(context, target.ok_or("Select a session to activate")?)?;
                Ok(json!({}))
            } else {
                rex::action(context, operation, target, args)
            }
        },
        |path| crate::startup::plan(path).map(|plan| plan.lines),
        crate::projects::record_use,
    )
}

fn run_with(
    snapshot: &Snapshot,
    selected: Option<&ActionSelection>,
    secondary: Option<&ActionSelection>,
    request: &Value,
    allow_startup: bool,
    dispatch: &mut impl FnMut(&str, Option<&Target>, &Value) -> Result<Value, String>,
) -> Result<Value, String> {
    let operation = request["operation"].as_str().ok_or("Choose an action")?;
    if operation == "create-session" {
        let query = value(request, "a session name or directory", false)?;
        let resolved = crate::projects::resolve(snapshot, &query)?;
        return create_resolved(
            resolved,
            allow_startup,
            dispatch,
            |path| crate::startup::plan(path).map(|plan| plan.lines),
            crate::projects::record_use,
        );
    }
    let selected = selected.ok_or("Choose a session, tab or pane first")?;
    if !available(selected).contains(&operation) {
        return Err(format!("{operation} is not available for this target"));
    }
    match operation {
        "rename" => {
            let name = value(request, "a new name", false)?;
            if name.chars().any(char::is_control) {
                return Err("A name cannot contain control characters".into());
            }
            dispatch("rename", Some(&selected.target), &json!({"name":name}))?;
            Ok(result(false, format!("Renamed {}", caption(selected))))
        }
        "close" => {
            if request["confirmed"].as_bool() != Some(true) {
                return Err("Confirm closing this target before continuing".into());
            }
            dispatch("close", Some(&selected.target), &json!({}))?;
            Ok(result(false, format!("Closed {}", caption(selected))))
        }
        "zoom" => {
            dispatch("zoom", Some(pane_target(selected)?), &json!({}))?;
            Ok(result(true, "Zoomed pane".into()))
        }
        "swap" => {
            let secondary = secondary.ok_or("Choose a second tab or pane to swap")?;
            let target_kind = kind(&selected.target)?;
            if target_kind == Kind::Session || target_kind != kind(&secondary.target)? {
                return Err("Swap requires two tabs or two panes".into());
            }
            let Target::Rex { session_id, .. } = &selected.target else {
                unreachable!()
            };
            let Target::Rex {
                session_id: other_session,
                ..
            } = &secondary.target
            else {
                unreachable!()
            };
            if session_id != other_session {
                return Err("Rex swaps only within the same session".into());
            }
            if selected.target == secondary.target {
                return Err("Choose a different swap destination".into());
            }
            dispatch(
                "swap",
                Some(&selected.target),
                &json!({"other":crate::interactive::target_json(&secondary.target)}),
            )?;
            Ok(result(false, "Swapped targets".into()))
        }
        "new-window" => {
            let query = value(request, "a tab name or directory", false)?;
            let (name, mut cwd) = crate::projects::normalize_query(&query)?;
            if crate::projects::query_directory(&query).is_none()
                && cwd == crate::env_text("HOME")
                && !selected.path.is_empty()
            {
                cwd = selected.path.clone();
            }
            dispatch(
                "create",
                Some(&selected.target),
                &json!({"kind":"window","name":name,"cwd":cwd}),
            )?;
            Ok(result(false, "Created tab".into()))
        }
        "split-right" | "split-down" => {
            let direction = if operation == "split-right" {
                "right"
            } else {
                "down"
            };
            dispatch(
                "split",
                Some(pane_target(selected)?),
                &json!({"direction":direction}),
            )?;
            Ok(result(false, format!("Split {direction}")))
        }
        "send" => {
            // Shared parsing recognizes C-c/F12/etc as a single key. Other
            // input remains literal text followed by Enter, never shell argv.
            let text = value(request, "text or a key", true)?;
            let data = dispatch(
                "send",
                Some(pane_target(selected)?),
                &crate::interactive::send_args(&text),
            )?;
            let message = match data["sent"].as_u64() {
                Some(1) => "Sent to 1 terminal pane".into(),
                Some(count) => format!("Sent to {count} terminal panes"),
                None => "Input sent".into(),
            };
            Ok(result(false, message))
        }
        "preview" => {
            let lines = match request.get("lines") {
                None => 80,
                Some(value) => value
                    .as_u64()
                    .filter(|lines| (1..=200).contains(lines))
                    .ok_or("Preview lines must be between 1 and 200")?,
            };
            let data = dispatch(
                "preview",
                Some(pane_target(selected)?),
                &json!({"lines":lines}),
            )?;
            let text = data["text"]
                .as_str()
                .ok_or("The terminal returned no preview text")?;
            Ok(json!({"text":text,"close_picker":false,"refresh":false}))
        }
        _ => Err("Unknown native picker action".into()),
    }
}

fn create_resolved(
    resolved: CreateTarget,
    allow_startup: bool,
    dispatch: &mut impl FnMut(&str, Option<&Target>, &Value) -> Result<Value, String>,
    startup: impl FnOnce(&str) -> Option<Vec<String>>,
    remember: impl FnOnce(&str),
) -> Result<Value, String> {
    let target = if let Some(target) = resolved.existing_session {
        if kind(&target)? != Kind::Session {
            return Err("The resolved project is not a session target".into());
        }
        target
    } else {
        let mut args = json!({"name":resolved.name,"cwd":resolved.cwd});
        if allow_startup {
            if let Some(lines) = startup(&resolved.cwd) {
                args["startup_lines"] = json!(lines);
            }
        }
        let data = dispatch("create", None, &args)?;
        let target = crate::interactive::decode_target(data.get("target").unwrap_or(&data), "rex")?;
        if kind(&target)? != Kind::Session {
            return Err("Session creation did not return a session target".into());
        }
        target
    };
    dispatch("activate", Some(&target), &json!({}))?;
    if resolved.path_query {
        remember(&resolved.cwd);
    }
    Ok(result(true, "Session opened".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_directory_paths_preserve_operators_spaces_and_reuse_session_identity() {
        use crate::model::{Pane, PaneMetadata, Session};
        let root = std::env::temp_dir().join(format!(
            "imux-literal-project-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        for name in [
            "quotes ' and$",
            "^bang! | token",
            "東京 path$",
            "back\\ slash$",
        ] {
            let path = root.join(name);
            std::fs::create_dir(&path).unwrap();
            let physical = std::fs::canonicalize(&path)
                .unwrap()
                .to_str()
                .unwrap()
                .to_owned();
            let resolved = resolve_directory(&Snapshot::default(), path.to_str().unwrap()).unwrap();
            assert_eq!(resolved.cwd, physical);
            assert!(resolved.path_query);
            assert!(!resolved.name.is_empty());
            let mut snapshot = Snapshot::default();
            let selected = target("s", None, None);
            snapshot.sessions.push(Session {
                key: "s".into(),
                name: "Renamed project".into(),
                window_count: "1".into(),
                attached: false,
                last: 0,
                path: physical.clone(),
                target: selected.clone(),
            });
            snapshot.panes.push(Pane {
                key: "p".into(),
                session_key: "s".into(),
                window_key: "w".into(),
                ordinal: "1".into(),
                name: String::new(),
                active: false,
                cmd: "bash".into(),
                path: physical.clone(),
                pid: 0,
                agent_id: String::new(),
                title: String::new(),
                opts: String::new(),
                target: target("s", Some("w"), Some("p")),
            });
            snapshot.pane_metadata.insert(
                "p".into(),
                PaneMetadata {
                    local: true,
                    ..PaneMetadata::default()
                },
            );
            let reused = resolve_directory(&snapshot, path.to_str().unwrap()).unwrap();
            assert_eq!(reused.name, "Renamed project");
            assert_eq!(reused.existing_session, Some(selected));
            std::fs::remove_dir(&path).unwrap();
            assert!(
                resolve_directory(&snapshot, path.to_str().unwrap()).is_err(),
                "deleted paths must not become HOME sessions"
            );
        }
        std::fs::remove_dir(root).unwrap();
        assert!(resolve_directory(&Snapshot::default(), "/Network/never-probe/project").is_err());
    }

    fn target(session: &str, window: Option<&str>, pane: Option<&str>) -> Target {
        Target::Rex {
            session_id: session.into(),
            window_id: window.map(str::to_owned),
            block_id: pane.map(str::to_owned),
        }
    }
    fn selected(target: Target) -> ActionSelection {
        ActionSelection {
            target,
            pane_target: None,
            title: "Display title".into(),
            name: "editable label".into(),
            path: "/project".into(),
        }
    }
    fn combined() -> ActionSelection {
        let mut row = selected(target("s", Some("w"), None));
        row.pane_target = Some(target("s", Some("w"), Some("p")));
        row
    }
    type Call = (String, Option<Target>, Value);
    fn execute(
        row: Option<&ActionSelection>,
        other: Option<&ActionSelection>,
        request: Value,
    ) -> (Result<Value, String>, Vec<Call>) {
        let mut calls = Vec::new();
        let answer = run_with(
            &Snapshot::default(),
            row,
            other,
            &request,
            false,
            &mut |op, target, args| {
                calls.push((op.into(), target.cloned(), args.clone()));
                Ok(json!({"sent":1,"text":"terminal output"}))
            },
        );
        (answer, calls)
    }

    #[test]
    fn combined_rows_keep_semantic_actions_on_tabs_and_pane_actions_exact() {
        let row = combined();
        for (operation, expected_operation, expected_target, args, close) in [
            (
                "rename",
                "rename",
                &row.target,
                json!({"name":"literal ' \" $(no-evaluation)"}),
                false,
            ),
            ("close", "close", &row.target, json!({}), false),
            (
                "zoom",
                "zoom",
                row.pane_target.as_ref().unwrap(),
                json!({}),
                true,
            ),
            (
                "split-right",
                "split",
                row.pane_target.as_ref().unwrap(),
                json!({"direction":"right"}),
                false,
            ),
            (
                "split-down",
                "split",
                row.pane_target.as_ref().unwrap(),
                json!({"direction":"down"}),
                false,
            ),
        ] {
            let (answer, calls) = execute(
                Some(&row),
                None,
                json!({"operation":operation,"value":"literal ' \" $(no-evaluation)","confirmed":true}),
            );
            let answer = answer.unwrap();
            assert_eq!(
                calls,
                [(
                    expected_operation.into(),
                    Some(expected_target.clone()),
                    args
                )]
            );
            assert_eq!(answer["close_picker"], close);
            assert_eq!(answer["refresh"], !close);
        }
    }

    #[test]
    fn invalid_actions_never_dispatch() {
        let row = combined();
        for request in [
            json!({"operation":"close"}),
            json!({"operation":"close","confirmed":"true"}),
            json!({"operation":"rename","value":""}),
            json!({"operation":"rename","value":"a\nb"}),
            json!({"operation":"rename","value":123}),
            json!({"operation":"preview","lines":0}),
            json!({"operation":"preview","lines":201}),
            json!({"operation":"preview","lines":"80"}),
            json!({"operation":"send","value":"x".repeat(32769)}),
            json!({"operation":"detach"}),
            json!({"operation":"create-session","value":""}),
            json!({"operation":"create-session"}),
            json!({"operation":"create-session","value":"one\ntwo"}),
        ] {
            let (answer, calls) = execute(Some(&row), None, request.clone());
            assert!(answer.is_err(), "{request:?}");
            assert!(calls.is_empty(), "{request:?}");
        }
        let (answer, calls) = execute(None, None, json!({"operation":"zoom"}));
        assert!(answer.is_err() && calls.is_empty());
    }

    #[test]
    fn capability_and_pane_membership_checks_precede_dispatch() {
        let mut row = combined();
        row.pane_target = Some(target("other-session", Some("w"), Some("p")));
        for operation in ["send", "zoom", "split-right", "preview"] {
            let (answer, calls) = execute(
                Some(&row),
                None,
                json!({"operation":operation,"value":"C-c"}),
            );
            assert!(answer.is_err() && calls.is_empty());
        }
        assert!(available(&selected(target("s", None, None)))
            .iter()
            .all(|op| *op != "swap"));
        for invalid in [
            target("", None, None),
            target("s", None, Some("p")),
            Target::Directory {
                path: "/tmp".into(),
            },
        ] {
            assert!(available(&selected(invalid)).is_empty());
        }
    }

    #[test]
    fn swap_checks_same_kind_session_and_distinct_ids() {
        let row = combined();
        for other in [
            selected(target("s", None, None)),
            selected(target("s", Some("w2"), Some("p2"))),
            selected(target("other", Some("w2"), None)),
            row.clone(),
        ] {
            let (answer, calls) = execute(Some(&row), Some(&other), json!({"operation":"swap"}));
            assert!(answer.is_err() && calls.is_empty());
        }
        let other = selected(target("s", Some("w2"), None));
        let (answer, calls) = execute(Some(&row), Some(&other), json!({"operation":"swap"}));
        assert!(answer.is_ok());
        assert_eq!(
            calls,
            [(
                "swap".into(),
                Some(row.target),
                json!({"other":{"session_id":"s","window_id":"w2"}})
            )]
        );
        let first = selected(target("s", Some("w1"), Some("p1")));
        let second = selected(target("s", Some("w2"), Some("p2")));
        let (answer, calls) = execute(Some(&first), Some(&second), json!({"operation":"swap"}));
        assert!(answer.is_ok());
        assert_eq!(
            calls,
            [(
                "swap".into(),
                Some(first.target),
                json!({"other":{"session_id":"s","window_id":"w2","block_id":"p2"}})
            )]
        );
    }

    #[test]
    fn send_uses_shared_literal_and_key_parsing_and_preserves_broadcast_targets() {
        let row = combined();
        for value in ["C-c", "F12", "echo '$HOME'; $(touch nope)", "one\ntwo", ""] {
            let (answer, calls) =
                execute(Some(&row), None, json!({"operation":"send","value":value}));
            assert!(answer.is_ok());
            assert_eq!(
                calls,
                [(
                    "send".into(),
                    row.pane_target.clone(),
                    crate::interactive::send_args(value)
                )]
            );
        }
        let session = selected(target("s", None, None));
        let (_, calls) = execute(
            Some(&session),
            None,
            json!({"operation":"send","value":"C-c"}),
        );
        assert_eq!(calls[0].1, Some(session.target));
    }

    #[test]
    fn explicit_preview_never_refreshes_or_activates() {
        let row = combined();
        let (answer, calls) = execute(Some(&row), None, json!({"operation":"preview","lines":200}));
        assert_eq!(
            answer.unwrap(),
            json!({"text":"terminal output","close_picker":false,"refresh":false})
        );
        assert_eq!(
            calls,
            [("preview".into(), row.pane_target, json!({"lines":200}))]
        );
    }

    #[test]
    fn new_tab_uses_a_literal_directory_and_never_activates_or_hydrates() {
        let directory = std::env::temp_dir().join(format!(
            "imux-native-tab-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let project = directory.join("my project.v2");
        std::fs::create_dir_all(&project).unwrap();
        let physical = std::fs::canonicalize(&project).unwrap();
        let row = combined();
        let (answer, calls) = execute(
            Some(&row),
            None,
            json!({"operation":"new-window","value":project.to_str().unwrap()}),
        );
        std::fs::remove_dir_all(directory).unwrap();
        let answer = answer.unwrap();
        assert_eq!(answer["close_picker"], false);
        assert_eq!(answer["refresh"], true);
        assert_eq!(
            calls,
            [(
                "create".into(),
                Some(row.target),
                json!({"kind":"window","name":"my-project-v2","cwd":physical.to_str().unwrap()})
            )]
        );
    }

    fn resolved(existing: Option<Target>, path_query: bool) -> CreateTarget {
        CreateTarget {
            name: "project".into(),
            cwd: "/project".into(),
            existing_session: existing,
            path_query,
        }
    }

    #[test]
    fn creating_a_local_session_hydrates_then_activates_and_records_only_success() {
        let mut calls = Vec::new();
        let mut remembered = Vec::new();
        let answer = create_resolved(
            resolved(None, true),
            true,
            &mut |op, target, args| {
                calls.push((op.to_owned(), target.cloned(), args.clone()));
                Ok(json!({"target":{"session_id":"new"}}))
            },
            |path| {
                assert_eq!(path, "/project");
                Some(vec!["literal startup command".into()])
            },
            |path| remembered.push(path.to_owned()),
        )
        .unwrap();
        assert_eq!(
            calls,
            [
                (
                    "create".into(),
                    None,
                    json!({"name":"project","cwd":"/project","startup_lines":["literal startup command"]})
                ),
                (
                    "activate".into(),
                    Some(target("new", None, None)),
                    json!({})
                )
            ]
        );
        assert_eq!(remembered, ["/project"]);
        assert_eq!(answer["close_picker"], true);
        assert_eq!(answer["refresh"], false);
    }

    #[test]
    fn existing_sessions_skip_creation_and_startup_and_names_do_not_record_paths() {
        let existing = target("existing", None, None);
        let mut calls = Vec::new();
        create_resolved(
            resolved(Some(existing.clone()), false),
            true,
            &mut |op, target, args| {
                calls.push((op.to_owned(), target.cloned(), args.clone()));
                Ok(json!({}))
            },
            |_| panic!("Existing session must not hydrate"),
            |_| panic!("Name query must not record directory history"),
        )
        .unwrap();
        assert_eq!(calls, [("activate".into(), Some(existing), json!({}))]);
    }

    #[test]
    fn remote_startup_and_failed_creation_never_run_followup_effects() {
        let mut calls = Vec::new();
        create_resolved(
            resolved(None, false),
            false,
            &mut |op, _, args| {
                calls.push((op.to_owned(), args.clone()));
                Ok(json!({"session_id":"new"}))
            },
            |_| panic!("Remote snapshot must not read local startup configuration"),
            |_| panic!("Not a path query"),
        )
        .unwrap();
        assert!(calls[0].1.get("startup_lines").is_none());
        for fails in ["create", "activate"] {
            let mut calls = Vec::new();
            let answer = create_resolved(
                resolved(None, true),
                false,
                &mut |op, _, _| {
                    calls.push(op.to_owned());
                    if op == fails {
                        Err("test failure".into())
                    } else {
                        Ok(json!({"session_id":"new"}))
                    }
                },
                |_| None,
                |_| panic!("Failed create/activation must not record use"),
            );
            assert!(answer.is_err());
            assert_eq!(calls.last().unwrap(), fails);
        }
    }

    #[test]
    fn invalid_created_target_is_not_activated_or_recorded() {
        for returned in [
            json!({}),
            json!({"session_id":""}),
            json!({"session_id":"s","window_id":"w"}),
            json!({"session_id":"s","block_id":"p"}),
        ] {
            let mut calls = Vec::new();
            let answer = create_resolved(
                resolved(None, true),
                false,
                &mut |op, _, _| {
                    calls.push(op.to_owned());
                    Ok(returned.clone())
                },
                |_| None,
                |_| panic!("Invalid target must not record directory history"),
            );
            assert!(answer.is_err());
            assert_eq!(calls, ["create"]);
        }
    }
}
