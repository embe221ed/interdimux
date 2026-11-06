//! Native dashboard totals and its small, explicit backend action surface.
use super::Candidate;
use crate::model::{Snapshot, Target};
use crate::rex::{self, RexContext};
use serde_json::{json, Value};
use std::collections::HashSet;

const TERMINAL_TOOL: &str = r#"
local args = rex.args
local allowed = { interdimux_schedule = true, interdimux_jobs = true, interdimux_health = true }
if not allowed[args.action] then error('Unsupported dashboard tool', 0) end
-- Attaching returns the current view and is also required for client.action.
-- Never substitute the active tab or focused block for a stale saved origin.
local attached, attach_error = rex.call('session.attach', { session_id = args.session_id })
if not attached then error(attach_error, 0) end
local found = false
for _, window in ipairs(attached.view and attached.view.windows or {}) do
  if window.window_id == args.window_id then
    for _, layer in ipairs(window.layers or {}) do
      for _, block in ipairs(layer.blocks or {}) do
        if block.block_id == args.block_id then found = true end
      end
    end
  end
end
if not found then error('The original Rex pane moved or closed; reopen the dashboard from a focused pane', 0) end
-- The custom action's caller is this short-lived CLI, so explicitly supply
-- the persistent app client to the existing integration's app_context guard.
local result, action_error = rex.call('client.action', {
  action = args.action, args = { client_id = args.client_id }, origin = 'api',
  session_id = args.session_id, block_id = args.block_id,
})
if not result then error(action_error, 0) end
return { started = true }
"#;

pub(super) fn counts(rows: &[Candidate], attention: usize) -> Value {
    let panes = rows
        .iter()
        .filter_map(|row| row.pane_id.as_deref())
        .collect::<HashSet<_>>()
        .len();
    json!({
        "sessions":rows.iter().filter(|row| row.kind == "session").count(),
        "tabs":rows.iter().filter(|row| row.kind == "window").count(),
        // Combined tab rows still retain the exact underlying pane ID.
        "panes":panes,"attention":attention,
        "projects":rows.iter().filter(|row| row.kind == "directory").count(),
    })
}

pub(super) fn origin(context: &RexContext, snapshot: &Snapshot) -> Result<Target, String> {
    let target = Target::Rex {
        session_id: context.session_id.clone(),
        window_id: Some(context.window_id.clone()),
        block_id: Some(context.block_id.clone()),
    };
    if context.client_id.is_empty()
        || context.session_id.is_empty()
        || context.window_id.is_empty()
        || context.block_id.is_empty()
        || !snapshot
            .sessions
            .iter()
            .any(|session| session.key == context.session_id)
        || !snapshot.windows.iter().any(|window| {
            window.key == context.window_id && window.session_key == context.session_id
        })
        || !snapshot.panes.iter().any(|pane| {
            pane.target == target
                && pane.key == context.block_id
                && pane.window_key == context.window_id
                && pane.session_key == context.session_id
        })
    {
        return Err(
            "Open the dashboard from a focused Rex pane to use Schedule, Jobs, or Health".into(),
        );
    }
    Ok(target)
}

pub(super) fn run(
    context: &RexContext,
    snapshot: &Snapshot,
    operation: &str,
) -> Result<Value, String> {
    run_with(context, snapshot, operation, &mut |operation, target| {
        if operation == "activate" {
            return rex::activate(context, target);
        }
        let Target::Rex {
            session_id,
            window_id: Some(window_id),
            block_id: Some(block_id),
        } = target
        else {
            return Err("The original Rex pane is unavailable".into());
        };
        rex::run_script(
            context,
            TERMINAL_TOOL,
            None,
            &json!({
                "action":operation,"client_id":context.client_id,
                "session_id":session_id,"window_id":window_id,"block_id":block_id,
            }),
        )?;
        Ok(())
    })
}

fn run_with(
    context: &RexContext,
    snapshot: &Snapshot,
    operation: &str,
    dispatch: &mut impl FnMut(&str, &Target) -> Result<(), String>,
) -> Result<Value, String> {
    if operation == "next-agent" {
        let states = crate::native_agents::states(crate::native_agents::DEFAULT_ATTENTION)?;
        let agents = crate::native_agents::collect(snapshot, &states);
        if let Some(agent) = crate::native_agents::next(&agents, &context.block_id) {
            dispatch("activate", &agent.target)?;
            return Ok(
                json!({"close_picker":true,"refresh":false,"message":"Opened the next agent needing attention"}),
            );
        }
        return Ok(
            json!({"close_picker":false,"refresh":false,"message":"No agent needs attention"}),
        );
    }
    let (action, title) = match operation {
        "schedule" => ("interdimux_schedule", "Schedule"),
        "jobs" => ("interdimux_jobs", "Jobs"),
        "health" => ("interdimux_health", "Health"),
        _ => return Err("Dashboard action must be next-agent, schedule, jobs, or health".into()),
    };
    let target = origin(context, snapshot)?;
    dispatch(action, &target)?;
    Ok(json!({"close_picker":true,"refresh":false,"message":format!("Opened {title} in Rex")}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Pane, PaneMetadata, ProgramStatus, Session, Window};

    fn fixture() -> (RexContext, Snapshot) {
        let mut context = super::super::empty_context();
        context.client_id = "client:app".into();
        context.session_id = "session:one".into();
        context.window_id = "window:one".into();
        context.block_id = "block:first".into();
        let mut snapshot = Snapshot::default();
        snapshot.sessions.push(Session {
            key: context.session_id.clone(),
            name: "work".into(),
            window_count: "1".into(),
            attached: true,
            last: 0,
            path: String::new(),
            target: Target::Rex {
                session_id: context.session_id.clone(),
                window_id: None,
                block_id: None,
            },
        });
        snapshot.windows.push(Window {
            key: context.window_id.clone(),
            session_key: context.session_id.clone(),
            ordinal: "1".into(),
            name: "terminal".into(),
            active: true,
            cmd: "bash".into(),
            path: String::new(),
            pane_count: 2,
            pid: 0,
            zoomed: false,
            bell: false,
            activity: false,
            target: Target::Rex {
                session_id: context.session_id.clone(),
                window_id: Some(context.window_id.clone()),
                block_id: None,
            },
        });
        for (id, state) in [
            ("block:first", "approve"),
            ("block:second", "input"),
            ("block:idle", "idle"),
        ] {
            snapshot.panes.push(Pane {
                key: id.into(),
                session_key: context.session_id.clone(),
                window_key: context.window_id.clone(),
                ordinal: "1".into(),
                name: "pane".into(),
                active: id == context.block_id,
                cmd: "bash".into(),
                path: String::new(),
                pid: 0,
                agent_id: id.into(),
                title: String::new(),
                opts: String::new(),
                target: Target::Rex {
                    session_id: context.session_id.clone(),
                    window_id: Some(context.window_id.clone()),
                    block_id: Some(id.into()),
                },
            });
            snapshot.pane_metadata.insert(
                id.into(),
                PaneMetadata {
                    program_status: Some(ProgramStatus {
                        state: state.into(),
                        app: "codex".into(),
                        ..ProgramStatus::default()
                    }),
                    ..PaneMetadata::default()
                },
            );
            snapshot.registry.insert(
                id.into(),
                crate::agent::Record {
                    sid: String::new(),
                    word: state.into(),
                    since: 0,
                },
            );
        }
        (context, snapshot)
    }

    #[test]
    fn dashboard_next_agent_uses_shared_attention_order_and_exact_pane() {
        let (context, snapshot) = fixture();
        let mut seen = Vec::new();
        let response = run_with(&context, &snapshot, "next-agent", &mut |op, target| {
            seen.push((op.to_owned(), target.clone()));
            Ok(())
        })
        .unwrap();
        assert_eq!(response["close_picker"], true);
        assert_eq!(
            seen,
            vec![("activate".into(), snapshot.panes[1].target.clone())]
        );
        let mut context = context;
        context.block_id = "block:second".into();
        run_with(&context, &snapshot, "next-agent", &mut |_, target| {
            assert_eq!(target, &snapshot.panes[0].target);
            Ok(())
        })
        .unwrap();
        let response = run_with(&context, &Snapshot::default(), "next-agent", &mut |_, _| {
            panic!("empty attention must never switch")
        })
        .unwrap();
        assert_eq!(response["close_picker"], false);
        assert_eq!(response["refresh"], false);
    }

    #[test]
    fn dashboard_terminal_tools_are_allowlisted_and_require_exact_origin() {
        let (context, mut snapshot) = fixture();
        for (operation, expected) in [
            ("schedule", "interdimux_schedule"),
            ("jobs", "interdimux_jobs"),
            ("health", "interdimux_health"),
        ] {
            let response = run_with(&context, &snapshot, operation, &mut |op, target| {
                assert_eq!(op, expected);
                assert_eq!(target, &snapshot.panes[0].target);
                Ok(())
            })
            .unwrap();
            assert_eq!(response["close_picker"], true);
            assert_eq!(response["refresh"], false);
        }
        for operation in [
            "interdimux_kill",
            "close",
            "health; rm -rf /",
            "",
            "client.config.reload",
        ] {
            assert!(run_with(&context, &snapshot, operation, &mut |_, _| panic!(
                "unknown operation dispatched"
            ))
            .is_err());
        }
        let mut unknown = context.clone();
        unknown.block_id.clear();
        assert!(run_with(&unknown, &snapshot, "jobs", &mut |_, _| panic!(
            "unknown origin dispatched"
        ))
        .is_err());
        snapshot.panes[0].window_key = "window:moved".into();
        assert!(
            run_with(&context, &snapshot, "schedule", &mut |_, _| panic!(
                "moved origin dispatched"
            ))
            .is_err()
        );
        snapshot.panes.remove(0);
        assert!(run_with(&context, &snapshot, "health", &mut |_, _| panic!(
            "closed origin dispatched"
        ))
        .is_err());
    }

    #[test]
    fn dashboard_action_failure_keeps_picker_open_via_error() {
        let (context, snapshot) = fixture();
        for operation in ["next-agent", "health"] {
            assert_eq!(
                run_with(&context, &snapshot, operation, &mut |_, _| Err(
                    "disconnected".into()
                ))
                .unwrap_err(),
                "disconnected"
            );
        }
    }
}
