//! imux — the heavy-processing core for interdimux.
//!
//! The legacy Bash tmux frontend uses the compatible gather3 renderer. The
//! native tmux and Rex frontends share Rust's model, rendering, scopes,
//! previews, directory discovery, dialogs, and persistent action controller.
//!
//! Contract: `imux gather3` writes exactly what `interdimux.sh --list` writes.
//! bash falls back to its own implementation when this binary is absent, so the
//! two must stay in step — tests/test_rust_parity.sh enforces that.  The
//! subcommand's name is the stdin protocol's version: see PROTOCOL.

mod agent;
mod dashboard;
mod diagnostics;
mod dirs;
mod format;
mod git;
#[cfg(unix)]
mod interactive;
mod jobs;
mod macproc;
#[cfg(feature = "macos-picker")]
mod mac_picker;
mod model;
mod mounts;
mod native_agents;
mod native_config;
mod navigator;
mod palette;
mod pipeline;
mod presentation;
mod preview;
mod proc;
mod projects;
mod render;
mod rex;
mod rex_ready;
mod search;
mod startup;
mod text;
mod titles;
#[cfg(all(test, unix))]
mod tmux_action_tests;
#[cfg(unix)]
mod tmux_actions;
mod tmux_backend;
mod tmux_input;
mod widths;
mod worker_identity;

/// The stdin protocol this build speaks, and the subcommand bash runs it with.
/// The name IS the version: bump it (gather3, ...) with every change to the
/// framing or to the position of any field, in step with IMUX_PROTO in
/// scripts/interdimux.sh.
///
/// Nothing else can make an old binary refuse new input.  Neither TPM's update
/// nor a `git pull` rebuilds rust/, and an INTERDIMUX_BIN installed elsewhere
/// is never rebuilt at all, so a script newer than its binary is routine.  When
/// the session name moved from the second field to the first, a binary built
/// before that read the timestamp as the name: every session was drawn as
/// `S:1790254646`, no window or pane matched one, and the exit status was 0, so
/// that WAS the picker.  An old binary exits 2 on a subcommand it does not
/// know, and an extra argument or an environment variable would only have been
/// ignored.  So a mismatch in either direction fails closed: bash falls back to
/// its own renderer and says, once, that the binary needs rebuilding.
const PROTOCOL: &str = "gather3";

/// A variable's value as text, whatever bytes it holds.  std::env::var gives
/// NOTHING for a value that is not UTF-8: one Latin-1 byte in the user's
/// title rules emptied the whole rule set bash handed over, every built-in
/// rule with it (review R02).  Lossy: a U+FFFD fails every test the stray
/// byte would, and compares with a path decoded the same way.
pub(crate) fn env_text(name: &str) -> String {
    std::env::var_os(name)
        .map(|v| v.to_string_lossy().into_owned())
        .unwrap_or_default()
}
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("macos-serve") => {
            #[cfg(feature = "macos-picker")]
            if let Err(error) = mac_picker::serve(&args[1..]) {
                eprintln!("imux: {error}");
                std::process::exit(1);
            }
            #[cfg(not(feature = "macos-picker"))]
            {
                eprintln!("imux: rebuild with --features macos-picker to use the native picker helper");
                std::process::exit(2);
            }
        }
        Some(PROTOCOL) => tmux_input::gather(),
        Some("pick" | "list") => {
            let list_only = args[0] == "list";
            if let Err(error) = navigator::run(&args[1..], list_only) {
                diagnostics::record(if list_only { "list" } else { "picker" }, &error);
                eprintln!("imux: {error}");
                if !list_only {
                    navigator::hold_error();
                }
                std::process::exit(1);
            }
        }
        Some(
            verb @ ("switch" | "kill" | "rename" | "zoom" | "swap" | "detach" | "send" | "dirs"
            | "schedule" | "doctor" | "agents" | "agent-next" | "jump" | "connect-dir"
            | "session-name-for" | "dashboard" | "send-at" | "send-in"),
        ) => {
            if let Err(error) = navigator::run_mode(verb, &args[1..]) {
                if verb != "doctor" {
                    diagnostics::record(verb, &error);
                }
                eprintln!("imux: {error}");
                if matches!(
                    verb,
                    "switch"
                        | "kill"
                        | "rename"
                        | "zoom"
                        | "swap"
                        | "detach"
                        | "send"
                        | "dirs"
                        | "schedule"
                        | "dashboard"
                ) {
                    navigator::hold_error();
                }
                std::process::exit(1);
            }
        }
        Some(
            verb @ ("--agents" | "--agent-next" | "--jump" | "--connect-dir" | "--session-name-for"
            | "--send-at" | "--send-in" | "--doctor"),
        ) => {
            if let Err(error) = navigator::run_mode(verb.trim_start_matches('-'), &args[1..]) {
                if verb != "--doctor" {
                    diagnostics::record(verb, &error);
                }
                eprintln!("imux: {error}");
                std::process::exit(1);
            }
        }
        Some("jobs") if args.iter().any(|arg| arg == "--backend") => {
            if let Err(error) = navigator::run_mode("jobs", &args[1..]) {
                diagnostics::record("jobs", &error);
                eprintln!("imux: {error}");
                navigator::hold_error();
                std::process::exit(1);
            }
        }
        Some("--sched-list") => {
            if let Err(error) = jobs::cli(&["list".into()], run_job) {
                eprintln!("imux: {error}");
                std::process::exit(1);
            }
        }
        Some("--sched-cancel") => {
            let mut command = vec!["cancel".into()];
            command.extend_from_slice(&args[1..]);
            if let Err(error) = jobs::cli(&command, run_job) {
                eprintln!("imux: {error}");
                std::process::exit(1);
            }
        }
        Some("jobs") => {
            if let Err(error) = jobs::cli(&args[1..], run_job) {
                eprintln!("imux: {error}");
                std::process::exit(1);
            }
        }
        #[cfg(unix)]
        Some("ui") => {
            if let Err(error) = interactive::helper(&args[1..]) {
                eprintln!("imux: {error}");
                std::process::exit(1);
            }
        }
        Some("--help" | "-h") => {
            println!("imux gather3\nimux pick|list --backend tmux|rex [OPTIONS]\n\nRex:  --client ID --session ID --window ID --block ID [--picker-block ID] [--server ADDRESS]\nTmux: [--client CLIENT] [--block PANE] [--socket PATH]\n\nModes: switch, kill, rename, zoom, swap, detach, send, dirs, schedule, jobs, doctor, agents, dashboard.\nUse pick --mode MODE, or MODE --backend ... (jobs --backend ... opens its UI).\nDirect: agents [--count] [--states approve,input], agent-next, jump N, connect-dir DIR, session-name-for DIR.\nScheduled sends: send-in SECONDS TARGET COMMAND, send-at WHEN TARGET COMMAND (plus backend/origin options).\nJob records: jobs list | cancel ID | output ID.\nInside picker: Ctrl+g actions, Ctrl+] scope, Ctrl+/ preview, Ctrl+r reload.\nCtrl+e rename, Ctrl+x confirmed close, Ctrl+z zoom, Ctrl+s swap, Ctrl+t send.\nCtrl+o directories; Alt+Enter create; Alt+n window; Alt+v/h split.\nHosted Rex supplies --snapshot FILE --result FILE; completion uses its native coordinator.");
        }
        Some("--version") | Some("-V") => println!("imux {}", env!("CARGO_PKG_VERSION")),
        // Another version of the protocol: a script older (`gather`) or newer
        // than this build.  Refused like any unknown subcommand -- exit 2 and
        // nothing on stdout -- so that script renders the list itself.
        Some(other) if other.starts_with("gather") => {
            eprintln!(
                "imux: this build speaks {}, not {}: the script and this binary are from different versions of interdimux",
                PROTOCOL, other
            );
            std::process::exit(2);
        }
        _ => {
            eprintln!("imux: usage: imux {}", PROTOCOL);
            std::process::exit(2);
        }
    }
}

fn run_job(
    descriptor: &serde_json::Value,
    payload: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    match descriptor["backend"].as_str() {
        Some("rex") => rex::run_job(descriptor, payload),
        Some("tmux") => tmux_actions::run_job(descriptor, payload),
        _ => Err("The scheduled command has an unknown backend".into()),
    }
}
