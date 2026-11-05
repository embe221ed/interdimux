//! Error history is deliberately lazy: no files are examined until an actual
//! failure, an explicit health check, or an acknowledgement.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const CAP: u64 = 65_536;
const RETAIN: usize = 32_768;
const BODY: usize = 16_384;
const BEFORE: &str = "== (before the first entry)";
static NEXT: AtomicU64 = AtomicU64::new(1);

fn root() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("XDG_STATE_HOME").filter(|s| !s.is_empty()) {
        return Ok(PathBuf::from(path).join("interdimux"));
    }
    std::env::var_os("HOME")
        .filter(|s| !s.is_empty())
        .map(|home| PathBuf::from(home).join(".local/state/interdimux"))
        .ok_or_else(|| "Set HOME or XDG_STATE_HOME to save navigator errors".into())
}

fn directory(path: &Path) -> Result<(), String> {
    if path.is_dir() {
        return Ok(());
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    match builder.create(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists && path.is_dir() => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

fn regular(path: &Path, write: bool) -> io::Result<File> {
    // Check before opening devices, then check the opened descriptor as well.
    // O_NONBLOCK prevents a FIFO replacement from hanging the picker, and
    // O_NOFOLLOW prevents following a symlink introduced between these checks.
    match fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.is_file() => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "navigator diagnostics require a regular file",
            ));
        }
        Ok(_) => (),
        Err(e) if write && e.kind() == io::ErrorKind::NotFound => (),
        Err(e) => return Err(e),
    }
    let mut options = OpenOptions::new();
    options.read(true).write(write).create(write);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
        #[cfg(any(target_os = "linux", target_os = "android"))]
        options.custom_flags(0x800 | 0x20000);
        #[cfg(not(any(target_os = "linux", target_os = "android")))]
        options.custom_flags(0x4 | 0x100);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "navigator diagnostics require a regular file",
        ));
    }
    Ok(file)
}

fn try_lock(file: &File) -> io::Result<bool> {
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        extern "C" {
            fn flock(fd: i32, operation: i32) -> i32;
        }
        if unsafe { flock(file.as_raw_fd(), 2 | 4) } == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        if matches!(
            error.kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
        ) {
            return Ok(false);
        }
        Err(error)
    }
    #[cfg(not(unix))]
    {
        let _ = file;
        Ok(true)
    }
}

fn read_tail(file: &mut File) -> io::Result<(String, bool)> {
    let size = file.metadata()?.len();
    let cut = size > CAP;
    file.seek(SeekFrom::Start(size.saturating_sub(CAP)))?;
    let mut bytes = Vec::new();
    file.take(CAP).read_to_end(&mut bytes)?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    // A cut through an old entry is not a fresh unmarked prefix. Start at the
    // first complete header when one exists, so trimming preserves boundaries.
    let text = if cut {
        text.lines()
            .position(|line| line.starts_with("== "))
            .map(|index| text.lines().skip(index).collect::<Vec<_>>().join("\n") + "\n")
            .unwrap_or(text)
    } else {
        text
    };
    Ok((text, cut))
}

#[derive(Debug)]
struct Entry {
    header: String,
    text: String,
}

fn entries(text: &str) -> Vec<Entry> {
    let mut entries = Vec::<Entry>::new();
    for line in text.split_inclusive('\n') {
        let header = line.trim_end_matches(['\r', '\n']);
        if line.starts_with("== ") {
            entries.push(Entry {
                header: header.into(),
                text: line.into(),
            });
        } else if let Some(last) = entries.last_mut() {
            last.text.push_str(line);
        } else {
            entries.push(Entry {
                header: BEFORE.into(),
                text: line.into(),
            });
        }
    }
    entries
}

fn limited(text: &str, bytes: usize) -> &str {
    let mut end = bytes.min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

fn single_line(text: &str, bytes: usize) -> String {
    limited(text, bytes)
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect::<String>()
        .trim()
        .into()
}

struct History {
    root: PathBuf,
}

impl History {
    fn path(&self) -> PathBuf {
        self.root.join("errors.log")
    }

    fn load(&self) -> Result<(Vec<Entry>, bool), String> {
        let mut file = match regular(&self.path(), false) {
            Ok(file) => file,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok((Vec::new(), false)),
            Err(e) => return Err(format!("Cannot read {}: {e}", self.path().display())),
        };
        let (text, cut) = read_tail(&mut file).map_err(|e| e.to_string())?;
        Ok((entries(&text), cut))
    }

    fn record(&self, context: &str, error: &str) -> Result<(), String> {
        if error.trim().is_empty() {
            return Ok(());
        }
        directory(&self.root)?;
        let mut file = regular(&self.path(), true).map_err(|e| e.to_string())?;
        if !try_lock(&file).map_err(|e| e.to_string())? {
            return Ok(());
        }
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let context = single_line(context, 512);
        let mut body = limited(error, BODY)
            .lines()
            .map(|line| {
                if line.starts_with("== ") {
                    format!(" {line}")
                } else {
                    line.into()
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
        if error.len() > BODY {
            body.push_str("\n[error text truncated]");
        }
        let prefix = if file.metadata().map_err(|e| e.to_string())?.len() > 0 {
            file.seek(SeekFrom::End(-1)).map_err(|e| e.to_string())?;
            let mut last = [0];
            file.read_exact(&mut last).map_err(|e| e.to_string())?;
            if last[0] == b'\n' {
                ""
            } else {
                "\n"
            }
        } else {
            ""
        };
        let entry = format!(
            "{prefix}== {stamp} {}-{} {context}\n{body}\n",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        file.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?;
        file.write_all(entry.as_bytes())
            .map_err(|e| e.to_string())?;
        if file.metadata().map_err(|e| e.to_string())?.len() > CAP {
            let (tail, _) = read_tail(&mut file).map_err(|e| e.to_string())?;
            let history = entries(&tail);
            let mut first = history.len();
            let mut bytes = 0;
            while first > 0 && history.len() - first < 50 {
                let next = history[first - 1].text.len();
                if first < history.len() && bytes + next > RETAIN {
                    break;
                }
                first -= 1;
                bytes += next;
            }
            let retained = history[first..]
                .iter()
                .map(|entry| entry.text.as_str())
                .collect::<String>();
            file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
            file.set_len(0).map_err(|e| e.to_string())?;
            file.write_all(retained.as_bytes())
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    fn ack(&self) -> Result<usize, String> {
        let (history, _) = self.load()?;
        let Some(last) = history.last() else {
            return Ok(0);
        };
        let mut file = regular(&self.root.join("errors.seen"), true)
            .map_err(|e| format!("Cannot write errors.seen: {e}"))?;
        if !try_lock(&file).map_err(|e| e.to_string())? {
            return Err("Navigator error acknowledgement is busy; retry the action".into());
        }
        file.set_len(0).map_err(|e| e.to_string())?;
        writeln!(file, "{}", last.header).map_err(|e| e.to_string())?;
        Ok(history.len())
    }

    fn report(&self) -> Vec<String> {
        let (history, cut) = match self.load() {
            Ok(result) => result,
            Err(error) => return vec![format!("WARN {error}")],
        };
        if history.is_empty() {
            return vec!["OK no navigator errors logged".into()];
        }
        let mut findings = Vec::new();
        let marker = match regular(&self.root.join("errors.seen"), false) {
            Ok(mut file) => {
                let mut bytes = Vec::new();
                match Read::by_ref(&mut file).take(CAP).read_to_end(&mut bytes) {
                    Ok(_) => String::from_utf8_lossy(&bytes)
                        .lines()
                        .next()
                        .unwrap_or("")
                        .to_owned(),
                    Err(e) => {
                        findings.push(format!("WARN cannot read errors.seen: {e}"));
                        String::new()
                    }
                }
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => String::new(),
            Err(e) => {
                findings.push(format!("WARN cannot read errors.seen: {e}"));
                String::new()
            }
        };
        let seen = history
            .iter()
            .rposition(|entry| entry.header == marker)
            .map_or(0, |index| index + 1);
        let new = history.len() - seen;
        let latest = history.last().unwrap();
        let latest = latest
            .text
            .lines()
            .filter(|line| !line.starts_with("== "))
            .find(|line| !line.trim().is_empty())
            .unwrap_or(&latest.header);
        if new > 0 {
            findings.push(format!(
                "ERROR navigator has logged {new} {}error(s); most recent: {}; acknowledge with imux doctor --ack; full log: {}",
                if new < history.len() { "new " } else { "" },
                single_line(latest, 240), self.path().display()
            ));
        } else {
            findings.push(format!(
                "WARN navigator has logged {} error(s), all acknowledged; most recent: {}; full log: {}",
                history.len(), single_line(latest, 240), self.path().display()
            ));
        }
        if cut {
            findings.push("WARN error history report is limited to the newest 64 KiB".into());
        }
        findings
    }
}

/// Best effort only: a busy/unwritable/special log never delays an action or
/// replaces its original backend failure.
pub(crate) fn record(context: &str, error: &str) {
    if let Ok(root) = root() {
        let _ = (History { root }).record(context, error);
    }
}

pub(crate) fn report() -> Vec<String> {
    match root() {
        Ok(root) => (History { root }).report(),
        Err(error) => vec![format!("WARN {error}")],
    }
}

pub(crate) fn ack() -> Result<usize, String> {
    History { root: root()? }.ack()
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        root: PathBuf,
        history: History,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "imux-errors-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            Self {
                history: History {
                    root: root.join("state"),
                },
                root,
            }
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn empty_history_does_not_create_state_and_ack_keeps_history() {
        let f = Fixture::new();
        assert_eq!(f.history.report(), ["OK no navigator errors logged"]);
        assert_eq!(f.history.ack().unwrap(), 0);
        assert!(!f.root.exists());
        f.history.record("rex send", "no terminal pane").unwrap();
        assert!(f.history.report()[0].starts_with("ERROR "));
        let before = fs::read(f.history.path()).unwrap();
        assert_eq!(f.history.ack().unwrap(), 1);
        assert_eq!(fs::read(f.history.path()).unwrap(), before);
        assert!(f.history.report()[0].contains("all acknowledged"));
        f.history
            .record("tmux close", "server disappeared")
            .unwrap();
        let report = f.history.report();
        assert!(report[0].contains("1 new error(s)"), "{report:?}");
        assert!(report[0].contains("server disappeared"));
    }

    #[test]
    fn unmarked_prefix_and_last_duplicate_header_follow_legacy_rules() {
        let f = Fixture::new();
        directory(&f.history.root).unwrap();
        fs::write(f.history.path(), "unmarked failure\n").unwrap();
        assert_eq!(f.history.ack().unwrap(), 1);
        assert_eq!(
            fs::read_to_string(f.history.root.join("errors.seen"))
                .unwrap()
                .trim(),
            BEFORE
        );
        assert!(f.history.report()[0].contains("all acknowledged"));
        fs::write(
            f.history.path(),
            "unmarked failure\n== repeated\none\n== other\ntwo\n== repeated\nthree\n== new\nfour\n",
        )
        .unwrap();
        fs::write(f.history.root.join("errors.seen"), "== repeated\n").unwrap();
        assert!(f.history.report()[0].contains("1 new error(s)"));
        fs::write(f.history.root.join("errors.seen"), "== trimmed away\n").unwrap();
        assert!(f.history.report()[0].contains("5 error(s)"));
        assert_eq!(f.history.ack().unwrap(), 5);
    }

    #[test]
    fn writes_keep_newest_entries_under_size_and_count_limits() {
        let f = Fixture::new();
        directory(&f.history.root).unwrap();
        let old = (0..100)
            .map(|i| format!("== old {i}\n{}\n", "x".repeat(900)))
            .collect::<String>();
        fs::write(f.history.path(), old).unwrap();
        f.history.record("new", "the newest failure").unwrap();
        let text = fs::read_to_string(f.history.path()).unwrap();
        assert!(text.len() <= RETAIN, "{}", text.len());
        assert!(entries(&text).len() <= 50);
        assert!(text.ends_with("the newest failure\n"));
        assert!(text.starts_with("== "));
        f.history.record("unicode", &"🦀".repeat(40_000)).unwrap();
        let text = fs::read_to_string(f.history.path()).unwrap();
        assert!(text.len() <= CAP as usize);
        assert!(text.ends_with("[error text truncated]\n"));
    }

    #[test]
    fn headers_are_unique_body_headers_cannot_forge_entries_and_files_are_private() {
        let f = Fixture::new();
        f.history
            .record("context\nnew line", "first\n== fake header\nbody")
            .unwrap();
        f.history.record("context", "second").unwrap();
        let text = fs::read_to_string(f.history.path()).unwrap();
        let records = entries(&text);
        assert_eq!(records.len(), 2);
        assert_ne!(records[0].header, records[1].header);
        assert!(records[0].text.contains("\n == fake header\n"));
        f.history.ack().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for name in ["errors.log", "errors.seen"] {
                assert_eq!(
                    fs::metadata(f.history.root.join(name))
                        .unwrap()
                        .permissions()
                        .mode()
                        & 0o777,
                    0o600
                );
            }
            assert_eq!(
                fs::metadata(&f.history.root).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn special_files_and_busy_logs_never_block_or_touch_their_targets() {
        use std::os::unix::fs::{symlink, FileTypeExt};
        let f = Fixture::new();
        directory(&f.history.root).unwrap();
        let target = f.root.join("untouched");
        fs::write(&target, "untouched").unwrap();
        symlink(&target, f.history.path()).unwrap();
        assert!(f.history.record("bad", "failure").is_err());
        assert!(f.history.report()[0].starts_with("WARN "));
        assert!(f.history.ack().is_err());
        assert_eq!(fs::read_to_string(&target).unwrap(), "untouched");
        fs::remove_file(f.history.path()).unwrap();
        extern "C" {
            fn mkfifo(path: *const std::os::raw::c_char, mode: u32) -> i32;
        }
        let fifo = std::ffi::CString::new(f.history.path().as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(unsafe { mkfifo(fifo.as_ptr(), 0o600) }, 0);
        let started = std::time::Instant::now();
        assert!(f.history.record("bad", "failure").is_err());
        assert!(f.history.ack().is_err());
        assert!(f.history.report()[0].starts_with("WARN "));
        assert!(started.elapsed() < std::time::Duration::from_millis(200));
        fs::remove_file(f.history.path()).unwrap();
        f.history.record("first", "original").unwrap();
        let marker = f.history.root.join("errors.seen");
        let fifo = std::ffi::CString::new(marker.as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(unsafe { mkfifo(fifo.as_ptr(), 0o600) }, 0);
        assert!(f.history.ack().is_err());
        let report = f.history.report();
        assert!(report.iter().any(|line| line.starts_with("WARN ")));
        assert!(report.iter().any(|line| line.starts_with("ERROR ")));
        assert!(fs::symlink_metadata(&marker).unwrap().file_type().is_fifo());
        fs::remove_file(marker).unwrap();
        let held = regular(&f.history.path(), true).unwrap();
        assert!(try_lock(&held).unwrap());
        let before = fs::read(f.history.path()).unwrap();
        f.history.record("busy", "skipped").unwrap();
        assert_eq!(fs::read(f.history.path()).unwrap(), before);
    }
}
