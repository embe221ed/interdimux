//! Keep a bounded number of the CLI connections already opened to fetch layouts.
//! The script waits on stdin after publishing its layout. Only an explicit
//! activation writes that pipe. A bounded lifetime also releases session subscriptions.

use super::{
    command, Host, LayoutJob, ACTIVATE_TIMEOUT, FOCUS_REMOTE, LAYOUTS, OUTPUT_LIMIT,
    REFRESH_TIMEOUT,
};
use crate::dirs::BoundedCommand;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock, Weak};
use std::thread;
use std::time::{Duration, Instant};

// Two simultaneous layouts can retain their connections. Other hosts discover
// and activate normally. Idle workers block on a channel with no wakeup loop.
const MAX_PARKED: usize = 2;
const IDLE: Duration = Duration::from_secs(45);
const LIFETIME: Duration = Duration::from_secs(120);
const MAX_COMMAND: usize = 64 * 1024;

struct Commit {
    args: String,
    deadline: Instant,
    reply: mpsc::Sender<Option<Result<Value, String>>>,
}

struct Slot {
    job: LayoutJob,
    socket: Option<(u64, u64)>,
    binary: PathBuf,
    ready: Weak<AtomicBool>,
    sender: mpsc::Sender<Commit>,
}

#[derive(Default, Clone)]
pub(super) struct Connections(Arc<Mutex<Vec<Slot>>>);

#[cfg(unix)]
fn socket_identity(socket: Option<&Path>) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    let metadata = std::fs::symlink_metadata(socket?).ok()?;
    Some((metadata.dev(), metadata.ino()))
}

#[cfg(not(unix))]
fn socket_identity(_: Option<&Path>) -> Option<(u64, u64)> {
    None
}

fn script() -> &'static str {
    static SCRIPT: OnceLock<String> = OnceLock::new();
    SCRIPT.get_or_init(|| {
        format!(
        "local function layout()\n{LAYOUTS}\nend\nlocal function focus()\n{FOCUS_REMOTE}\nend\n{}",
        include_str!("rex_remote_connection.lua")
    )
    })
}

fn confirm_focus(line: std::io::Result<Vec<u8>>) -> Result<Value, String> {
    let line = line.map_err(|error| error.to_string())?;
    let reply: Value = serde_json::from_slice(&line).map_err(|error| error.to_string())?;
    if reply["focused"] == true {
        Ok(reply)
    } else {
        Err(reply["error"]
            .as_str()
            .unwrap_or("Rex did not confirm the requested focus.")
            .to_owned())
    }
}

impl Connections {
    /// Called from the background layout worker. An occupied slot leaves this
    /// read to the regular one-shot CLI without delaying the catalog.
    pub(super) fn layout(
        &self,
        binary: &Path,
        job: &LayoutJob,
        args: &str,
        deadline: Instant,
        cancelled: &AtomicBool,
    ) -> Option<Result<Value, String>> {
        let ready = Arc::new(AtomicBool::new(false));
        let (sender, receiver) = mpsc::channel::<Commit>();
        let socket = socket_identity(job.tunnel.as_deref());
        let mut slots = self.0.lock().unwrap();
        slots.retain(|s| s.ready.strong_count() > 0);
        if slots.len() >= MAX_PARKED || slots.iter().any(|s| s.job.endpoint() == job.endpoint()) {
            return None;
        }
        slots.push(Slot {
            job: job.clone(),
            socket,
            binary: binary.to_owned(),
            ready: Arc::downgrade(&ready),
            sender,
        });
        drop(slots);

        let mut cli = command(binary, Some(job.endpoint()));
        cli.args(["do", "-e", script(), "--args", args]);
        let mut process = match BoundedCommand::interactive(cli, deadline, OUTPUT_LIMIT) {
            Ok(child) => child,
            Err(error) => return Some(Err(error.to_string())),
        };
        let layout = process
            .first_line(|| cancelled.load(Ordering::Relaxed))
            .map_err(|e| e.to_string())
            .and_then(|line| serde_json::from_slice::<Value>(&line).map_err(|e| e.to_string()));
        if layout.as_ref().is_ok_and(|data| {
            data["imux_focus_connection"] == true
                && data["host_id"] == job.host_id
                && data["layouts"].is_object()
        }) {
            ready.store(true, Ordering::Release);
            let _ = thread::Builder::new()
                .name("imux-rex-connection".into())
                .spawn(move || {
                    let _alive = ready;
                    let expires = Instant::now() + LIFETIME;
                    loop {
                        let remaining = expires.saturating_duration_since(Instant::now());
                        let Ok(commit) = receiver.recv_timeout(IDLE.min(remaining)) else {
                            break;
                        };
                        let result = process
                            .exchange_line(commit.args.as_bytes(), commit.deadline, || false)
                            .map(confirm_focus);
                        let confirmed = matches!(&result, Some(Ok(_)));
                        if commit.reply.send(result).is_err() || !confirmed || remaining.is_zero() {
                            break;
                        }
                    }
                });
        }
        Some(layout)
    }

    pub(super) fn activate(
        &self,
        binary: &Path,
        host: &Host,
        host_id: &str,
        endpoint: &str,
        args: &str,
    ) -> Option<Result<Value, String>> {
        if args.len() >= MAX_COMMAND {
            return None;
        }
        let slots = self.0.lock().unwrap();
        let slot = slots.iter().find(|s| {
            s.job.host_id == host_id
                && s.job.endpoint() == endpoint
                && s.binary == binary
                && (s.job.host == *host || s.job.aliases.contains(host))
                && s.socket == socket_identity(s.job.tunnel.as_deref())
                && s.ready
                    .upgrade()
                    .is_some_and(|ready| ready.load(Ordering::Acquire))
        })?;
        let sender = slot.sender.clone();
        drop(slots);
        let timeout = REFRESH_TIMEOUT + ACTIVATE_TIMEOUT;
        let (reply, receive) = mpsc::channel();
        sender
            .send(Commit {
                args: format!("{args}\n"),
                deadline: Instant::now() + timeout,
                reply,
            })
            .ok()?;
        // An input write that failed before sending any bytes permits a cold
        // retry. Loss of a reply after submission never replays a GUI action.
        receive.recv_timeout(timeout).unwrap_or_else(|_| {
            Some(Err(
                "The Rex connection ended before confirming the switch. Refresh the picker.".into(),
            ))
        })
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    fn job(name: &str) -> LayoutJob {
        LayoutJob {
            host: Host {
                label: name.into(),
                id: name.into(),
                host_id: "physical".into(),
                endpoints: vec![name.into()],
            },
            host_id: "physical".into(),
            aliases: Vec::new(),
            tunnel: None,
        }
    }

    #[test]
    fn reuses_only_the_verified_route_and_never_retries_a_lost_acknowledgement() {
        let dir = std::env::temp_dir().join(format!("imux-parked-{}", std::process::id()));
        fs::create_dir(&dir).unwrap();
        let cli = dir.join("rex");
        fs::write(
            &cli,
            r#"#!/bin/sh
root=${0%/*}
printf '%s\n' "$$" >> "$root/children"
if [ "$4" = "--server=legacy" ]; then
    printf '%s\n' '{"host_id":"physical","layouts":{"session:one":[]}}'
    exit 0
fi
printf '%s\n' '{"host_id":"physical","layouts":{"session:one":[]},"imux_focus_connection":true}'
while IFS= read -r action; do
    printf '%s %s\n' "$$" "$action" >> "$root/actions"
    [ "$action" != "lose-reply" ] || exit 1
    printf '%s\n' '{"focused":true}'
done
"#,
        )
        .unwrap();
        fs::set_permissions(&cli, fs::Permissions::from_mode(0o700)).unwrap();
        let pool = Connections::default();
        let legacy = job("legacy");
        let first = job("one");
        let second = job("two");
        let third = job("three");
        let load = |route: &LayoutJob| {
            pool.layout(
                &cli,
                route,
                "{}",
                Instant::now() + REFRESH_TIMEOUT,
                &AtomicBool::new(false),
            )
        };
        assert!(load(&legacy).unwrap().is_ok());
        assert!(pool
            .activate(&cli, &legacy.host, "physical", "legacy", "incorrect")
            .is_none());
        assert!(load(&first).unwrap().is_ok());
        assert!(load(&first).is_none());
        assert!(load(&second).unwrap().is_ok());
        assert!(load(&third).is_none());
        assert!(!dir.join("actions").exists());

        let activate = |host: &Host, physical: &str, args: &str| {
            pool.activate(&cli, host, physical, "one", args)
        };
        let mut replaced = first.host.clone();
        replaced.endpoints.push("replacement".into());
        assert!(activate(&replaced, "physical", "incorrect").is_none());
        assert!(activate(&first.host, "replacement", "incorrect").is_none());
        assert_eq!(
            activate(&first.host, "physical", "tab").unwrap().unwrap()["focused"],
            true
        );
        assert_eq!(
            activate(&first.host, "physical", "pane").unwrap().unwrap()["focused"],
            true
        );
        // Some(Err) is terminal for this Enter; None would replay the action.
        assert!(activate(&first.host, "physical", "lose-reply")
            .unwrap()
            .is_err());
        let children = fs::read_to_string(dir.join("children")).unwrap();
        let pids: Vec<_> = children.lines().collect();
        assert_eq!(pids.len(), 3);
        assert_eq!(
            fs::read_to_string(dir.join("actions")).unwrap(),
            format!("{0} tab\n{0} pane\n{0} lose-reply\n", pids[1])
        );
        drop(pool);
        // Closing a picker must reap even the untouched second connection.
        extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        for pid in pids {
            while unsafe { kill(pid.parse().unwrap(), 0) } == 0 {
                assert!(
                    Instant::now() < deadline,
                    "parked process {pid} outlived its owner"
                );
                thread::sleep(Duration::from_millis(5));
            }
        }
        fs::remove_dir_all(dir).unwrap();
    }
}
