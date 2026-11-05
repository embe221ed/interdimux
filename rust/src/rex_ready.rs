//! Hosted Rex startup waits only for its initial snapshot to be published.
//! Native GUI sizing is observed in the background and never gates painting.

use serde_json::Value;
use std::fs;
use std::io;
use std::path::Path;
use std::time::{Duration, Instant};

const TIMEOUT: Duration = Duration::from_secs(5);
const POLL: Duration = Duration::from_millis(10);

enum State {
    Pending,
    Ready,
}

fn state(bytes: &[u8]) -> Result<State, String> {
    let record: Value = serde_json::from_slice(bytes)
        .map_err(|error| format!("Cannot decode Rex picker readiness: {error}"))?;
    if record["version"].as_u64() != Some(1) {
        return Err("Unsupported Rex picker readiness version; rebuild interdimux".into());
    }
    let ready = record["ready"]
        .as_bool()
        .ok_or("Rex picker readiness must contain a boolean ready state")?;
    if let Some(error) = record.get("error") {
        if !error.is_null() {
            let message = error
                .as_str()
                .filter(|message| !message.is_empty())
                .ok_or("Rex picker readiness contains an invalid error message")?;
            return Err(format!("Rex could not prepare the picker: {message}"));
        }
    }
    Ok(if ready { State::Ready } else { State::Pending })
}

fn wait_with(snapshot: &Path, timeout: Duration, poll: Duration) -> Result<(), String> {
    let parent = snapshot
        .parent()
        .ok_or("Rex snapshot has no parent directory")?;
    let gate = parent.join("ready.json");
    let mut bytes = match fs::read(&gate) {
        Ok(bytes) => bytes,
        // Older integrations and captured test snapshots have no gate. Never
        // delay them or wait for a file which they do not promise to publish.
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("Cannot read Rex picker readiness: {error}")),
    };
    let deadline = Instant::now() + timeout;
    loop {
        match state(&bytes)? {
            State::Ready => return Ok(()),
            State::Pending => {}
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("Rex picker snapshot timed out; close the picker and retry".into());
        }
        std::thread::sleep(poll.min(remaining));
        bytes = match fs::read(&gate) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Err("Rex closed the picker while its snapshot was being prepared".into());
            }
            Err(error) => return Err(format!("Cannot read Rex picker readiness: {error}")),
        };
    }
}

/// The native integration alone opts into this handshake by supplying a gate.
/// Its pending→ready transition only publishes complete snapshot data. It does
/// not wait for font changes, GUI ownership, stabilization, or an extra process.
pub(crate) fn wait(snapshot: &Path) -> Result<(), String> {
    wait_with(snapshot, TIMEOUT, POLL)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(1);
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "imux-ready-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn snapshot(&self) -> PathBuf {
            self.0.join("snapshot.json")
        }
        fn publish(&self, record: Value) {
            fs::write(self.0.join("ready.tmp"), record.to_string()).unwrap();
            fs::rename(self.0.join("ready.tmp"), self.0.join("ready.json")).unwrap();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn absent_gate_and_ready_gate_need_no_wait_budget() {
        let fixture = Fixture::new();
        assert!(wait_with(&fixture.snapshot(), Duration::ZERO, POLL).is_ok());
        fixture.publish(json!({"version":1,"ready":true}));
        assert!(wait_with(&fixture.snapshot(), Duration::ZERO, POLL).is_ok());
    }

    #[test]
    fn pending_waits_for_atomic_ready_publication() {
        let fixture = Fixture::new();
        fixture.publish(json!({"version":1,"ready":false}));
        std::thread::scope(|scope| {
            let publisher = scope.spawn(|| {
                std::thread::sleep(Duration::from_millis(15));
                fixture.publish(json!({"version":1,"ready":true}));
            });
            wait_with(
                &fixture.snapshot(),
                Duration::from_secs(1),
                Duration::from_millis(1),
            )
            .unwrap();
            publisher.join().unwrap();
        });
    }

    #[test]
    fn pending_timeout_and_native_error_are_reported() {
        let fixture = Fixture::new();
        fixture.publish(json!({"version":1,"ready":false}));
        assert!(wait_with(&fixture.snapshot(), Duration::ZERO, POLL)
            .unwrap_err()
            .contains("timed out"));
        fixture.publish(json!({"version":1,"ready":false,"error":"the app disconnected"}));
        assert!(wait(&fixture.snapshot())
            .unwrap_err()
            .contains("the app disconnected"));
    }

    #[test]
    fn malformed_or_unsupported_gate_fails_instead_of_painting_early() {
        let fixture = Fixture::new();
        for record in [
            json!({"version":2,"ready":true}),
            json!({"version":1,"ready":"true"}),
            json!({"version":1,"ready":true,"error":false}),
            json!([]),
        ] {
            fixture.publish(record);
            assert!(wait(&fixture.snapshot()).is_err());
        }
        fs::write(fixture.0.join("ready.json"), "{").unwrap();
        assert!(wait(&fixture.snapshot())
            .unwrap_err()
            .contains("Cannot decode"));
    }

    #[test]
    fn removing_a_pending_gate_means_the_picker_closed() {
        let fixture = Fixture::new();
        fixture.publish(json!({"version":1,"ready":false}));
        std::thread::scope(|scope| {
            let remover = scope.spawn(|| {
                std::thread::sleep(Duration::from_millis(15));
                fs::remove_file(fixture.0.join("ready.json")).unwrap();
            });
            let error = wait_with(
                &fixture.snapshot(),
                Duration::from_secs(1),
                Duration::from_millis(1),
            )
            .unwrap_err();
            assert!(error.contains("closed the picker"));
            remover.join().unwrap();
        });
    }
}
