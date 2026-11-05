//! Shared one-shot scheduled sends. Nothing in this module runs on picker
//! startup: discovery, files and workers are used only by explicit job actions.

use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub(crate) type Dispatch = fn(&Value, &Value) -> Result<Value, String>;
static NEXT: AtomicU64 = AtomicU64::new(1);

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn state_root() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("XDG_STATE_HOME").filter(|s| !s.is_empty()) {
        return Ok(PathBuf::from(path).join("interdimux"));
    }
    std::env::var_os("HOME")
        .filter(|s| !s.is_empty())
        .map(|home| PathBuf::from(home).join(".local/state/interdimux"))
        .ok_or_else(|| "Set HOME or XDG_STATE_HOME to save scheduled jobs".into())
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 100 && id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

fn private_dir(path: &Path) -> Result<(), String> {
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
        Err(e) => Err(format!(
            "Cannot create job directory {}: {e}",
            path.display()
        )),
    }
}

fn options() -> OpenOptions {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
}

fn atomic(path: &Path, value: &Value) -> Result<(), String> {
    let temporary = path.with_extension(format!(
        "tmp-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| {
        let file = options().open(&temporary).map_err(|e| e.to_string())?;
        serde_json::to_writer(file, value).map_err(|e| e.to_string())?;
        fs::rename(&temporary, path).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
        }
        if pid == 0 || pid > i32::MAX as u32 {
            return false;
        }
        if unsafe { kill(pid as i32, 0) } == 0 {
            return true;
        }
        // EPERM still proves a live process. Never signal a stored PID to cancel.
        return io::Error::last_os_error().raw_os_error() == Some(1);
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        true
    }
}

fn worker_alive(record: &Value, pid: u32) -> bool {
    if !alive(pid) {
        return false;
    }
    // Legacy records and temporarily unreadable kernel metadata keep their
    // former behavior. A proven birth mismatch, however, is a different
    // process even when kill(pid, 0) succeeds.
    match record["worker_birth"]
        .as_str()
        .filter(|value| !value.is_empty())
    {
        Some(expected) => {
            crate::worker_identity::get(pid).map_or(true, |actual| actual == expected)
        }
        None => true,
    }
}

#[cfg(unix)]
struct Lock {
    _file: File,
}
#[cfg(not(unix))]
struct Lock(PathBuf);
impl Lock {
    fn get(directory: &Path) -> Result<Self, String> {
        let path = directory.join("lock");
        let until = Instant::now() + Duration::from_secs(2);
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            use std::os::unix::fs::OpenOptionsExt;
            extern "C" {
                fn flock(fd: i32, operation: i32) -> i32;
            }
            // Keep one stable inode. Deleting a stale PID lock can race with
            // another reclaimer and accidentally remove its newly held lock.
            // Kernel locks are released on crash, including before PID writes.
            let file = OpenOptions::new()
                .write(true)
                .create(true)
                .mode(0o600)
                .open(path)
                .map_err(|e| format!("Cannot open scheduled job lock: {e}"))?;
            loop {
                if unsafe { flock(file.as_raw_fd(), 2 | 4) } == 0 {
                    return Ok(Self { _file: file });
                }
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                if error.kind() != io::ErrorKind::WouldBlock {
                    return Err(format!("Cannot lock scheduled job: {error}"));
                }
                if Instant::now() >= until {
                    return Err("This scheduled job is busy; retry the action".into());
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        #[cfg(not(unix))]
        loop {
            match options().open(&path) {
                Ok(mut file) => {
                    if let Err(e) = writeln!(file, "{}", std::process::id()) {
                        let _ = fs::remove_file(&path);
                        return Err(e.to_string());
                    }
                    return Ok(Self(path));
                }
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                    let owner = fs::read_to_string(&path)
                        .ok()
                        .and_then(|s| s.trim().parse::<u32>().ok());
                    if owner.map_or(false, |pid| !alive(pid)) {
                        let _ = fs::remove_file(&path);
                        continue;
                    }
                    if Instant::now() >= until {
                        return Err("This scheduled job is busy; retry the action".into());
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) => return Err(format!("Cannot lock scheduled job: {e}")),
            }
        }
    }
}
#[cfg(not(unix))]
impl Drop for Lock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

struct Store {
    root: PathBuf,
}

#[derive(PartialEq, Eq)]
struct RecordStamp {
    modified: Option<SystemTime>,
    len: u64,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
}
impl RecordStamp {
    fn of(metadata: &fs::Metadata) -> Self {
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        Self {
            modified: metadata.modified().ok(),
            len: metadata.len(),
            #[cfg(unix)]
            device: metadata.dev(),
            #[cfg(unix)]
            inode: metadata.ino(),
        }
    }
}

impl Store {
    fn jobs(&self) -> PathBuf {
        self.root.join("jobs")
    }
    fn directory(&self, id: &str) -> Result<PathBuf, String> {
        if !valid_id(id) {
            return Err("Invalid interdimux job ID".into());
        }
        Ok(self.jobs().join(id))
    }
    fn read(&self, id: &str) -> Result<Value, String> {
        self.read_stamped(id).map(|(record, _)| record)
    }
    fn read_stamped(&self, id: &str) -> Result<(Value, RecordStamp), String> {
        let file = File::open(self.directory(id)?.join("job.json"))
            .map_err(|e| format!("Cannot read scheduled job {id}: {e}"))?;
        let metadata = file.metadata().map_err(|e| e.to_string())?;
        let mut bytes = Vec::with_capacity(metadata.len().min(65_536) as usize);
        // File::read_to_end would query size/position again. We already have
        // its size and stamp; use the generic reader without another probe.
        file.take(u64::MAX)
            .read_to_end(&mut bytes)
            .map_err(|e| format!("Cannot read scheduled job {id}: {e}"))?;
        let record: Value = serde_json::from_slice(&bytes)
            .map_err(|e| format!("Invalid scheduled job {id}: {e}"))?;
        if record["version"] != 1 || record["id"] != id {
            return Err("Unsupported or mismatched scheduled job record".into());
        }
        // The stamp comes from the opened descriptor, not a later path stat:
        // a concurrent cancellation may already have replaced that pathname.
        Ok((record, RecordStamp::of(&metadata)))
    }
    fn save(&self, record: &Value) -> Result<(), String> {
        atomic(
            &self
                .directory(record["id"].as_str().ok_or("Job has no ID")?)?
                .join("job.json"),
            record,
        )
    }
    fn log(&self, record: &Value, message: &str) {
        let line = json!({"time":now(),"id":record["id"],"status":record["status"],"target":record["label"],"message":message});
        for path in [
            self.root.join("scheduled.log"),
            self.directory(record["id"].as_str().unwrap_or(""))
                .unwrap_or_default()
                .join("output.log"),
        ] {
            let mut options = OpenOptions::new();
            options.write(true).append(true).create(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            if let Ok(mut file) = options.open(path) {
                let _ = writeln!(file, "{line}");
            }
        }
    }
    fn create(
        &self,
        descriptor: &Value,
        due: u64,
        when: &str,
        command: &str,
    ) -> Result<Value, String> {
        if !matches!(descriptor["backend"].as_str(), Some("tmux" | "rex"))
            || !descriptor["target"].is_object()
            || !descriptor["guard"].is_object()
            || descriptor["guard"]
                .as_object()
                .map_or(true, |g| g.is_empty())
        {
            return Err("Resolve one pane and its server identity before scheduling".into());
        }
        if command.is_empty() || command.contains('\0') {
            return Err("Enter nonempty command text without NUL bytes".into());
        }
        private_dir(&self.root)?;
        private_dir(&self.jobs())?;
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let id = format!(
            "{stamp:x}-{:x}-{:x}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        private_dir(&self.directory(&id)?)?;
        let record = json!({"version":1,"id":id,"status":"scheduled","created":now(),"due":due,"when":when,
            "command":command,"label":descriptor["label"],"descriptor":descriptor,"payload":send_payload(command),"worker_pid":0});
        self.save(&record)?;
        self.log(&record, "scheduled");
        Ok(record)
    }
    fn cancel(&self, id: &str) -> Result<Value, String> {
        // Establish ownership before touching a lock in a user-supplied ID.
        self.read(id)?;
        let directory = self.directory(id)?;
        let _lock = Lock::get(&directory)?;
        let mut record = self.read(id)?;
        if record["status"] != "scheduled" {
            return Err("This job is no longer pending; it cannot be cancelled".into());
        }
        record["status"] = json!("cancelled");
        record["finished"] = json!(now());
        self.save(&record)?;
        self.log(&record, "cancelled before delivery");
        Ok(record)
    }
    fn run(&self, id: &str, dispatch: Dispatch) -> Result<(), String> {
        self.read(id)?;
        let birth = crate::worker_identity::get(std::process::id());
        // A submitting picker can disappear immediately after spawn. Record
        // our own identity before waiting rather than relying on its PID write.
        {
            let _lock = Lock::get(&self.directory(id)?)?;
            let mut record = self.read(id)?;
            if record["status"] != "scheduled" {
                return Ok(());
            }
            let owner = record["worker_pid"]
                .as_u64()
                .and_then(|pid| u32::try_from(pid).ok())
                .unwrap_or(0);
            if owner != 0 && owner != std::process::id() && worker_alive(&record, owner) {
                return Ok(());
            }
            record["worker_pid"] = json!(std::process::id());
            record["worker_birth"] = json!(birth);
            self.save(&record)?;
        }
        let path = self.directory(id)?.join("job.json");
        let (mut pending, mut stamp) = self.read_stamped(id)?;
        loop {
            let record = &pending;
            if record["status"] != "scheduled" {
                return Ok(());
            }
            let due = record["due"]
                .as_u64()
                .ok_or("Scheduled job has no valid due time")?;
            if due <= now() {
                break;
            }
            std::thread::sleep(
                Duration::from_millis(250).min(Duration::from_secs(due.saturating_sub(now()))),
            );
            // Pending jobs usually do not change for hours. Keep the existing
            // cancellation/timer cadence without reopening and parsing their
            // complete records four times a second. Atomic saves change inode
            // even when a replacement has the same byte length and mtime.
            let metadata = fs::metadata(&path).map_err(|e| e.to_string())?;
            if stamp != RecordStamp::of(&metadata) {
                (pending, stamp) = self.read_stamped(id)?;
            }
        }
        let mut record = {
            let _lock = Lock::get(&self.directory(id)?)?;
            let mut record = self.read(id)?;
            if record["status"] != "scheduled" {
                return Ok(());
            }
            record["status"] = json!("running");
            record["started"] = json!(now());
            record["worker_pid"] = json!(std::process::id());
            record["worker_birth"] = json!(birth);
            self.save(&record)?;
            record
        };
        self.log(
            &record,
            "checking target identity and delivering to one pane",
        );
        let result = dispatch(&record["descriptor"], &record["payload"]);
        let _lock = Lock::get(&self.directory(id)?)?;
        record["finished"] = json!(now());
        match result {
            Ok(data) => {
                record["status"] = json!("sent");
                record["result"] = data;
                self.save(&record)?;
                self.log(&record, "delivered");
                Ok(())
            }
            Err(error) => {
                record["status"] = json!("failed");
                record["error"] = json!(error);
                self.save(&record)?;
                self.log(&record, &error);
                Err(error)
            }
        }
    }
    fn list(&self) -> Result<Vec<Value>, String> {
        let entries = match fs::read_dir(self.jobs()) {
            Ok(entries) => entries,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e.to_string()),
        };
        let mut records = Vec::new();
        for entry in entries.flatten() {
            let Some(id) = entry.file_name().to_str().map(str::to_owned) else {
                continue;
            };
            if !valid_id(&id) || !entry.file_type().map_or(false, |kind| kind.is_dir()) {
                continue;
            }
            let mut record = match self.read(&id) {
                Ok(record) => record,
                Err(error) => {
                    records.push(json!({"id":id,"status":"invalid","error":error}));
                    continue;
                }
            };
            let pid = record["worker_pid"]
                .as_u64()
                .and_then(|n| u32::try_from(n).ok())
                .unwrap_or(0);
            if matches!(record["status"].as_str(), Some("scheduled" | "running"))
                && pid > 0
                && !worker_alive(&record, pid)
            {
                if let Ok(_lock) = Lock::get(&self.directory(&id)?) {
                    if let Ok(mut current) = self.read(&id) {
                        if current["status"] == record["status"]
                            && current["worker_pid"] == record["worker_pid"]
                            && current["worker_birth"] == record["worker_birth"]
                            && !worker_alive(&current, pid)
                        {
                            current["status"] = json!("interrupted");
                            current["error"] = json!("The scheduler worker stopped; inspect the pane before scheduling again");
                            current["finished"] = json!(now());
                            let _ = self.save(&current);
                        }
                        record = current;
                    }
                }
            }
            records.push(record);
        }
        records.sort_by(|a, b| {
            a["due"]
                .as_u64()
                .unwrap_or(0)
                .cmp(&b["due"].as_u64().unwrap_or(0))
                .then_with(|| a["id"].as_str().cmp(&b["id"].as_str()))
        });
        Ok(records)
    }
}

/// The legacy send rule deliberately leaves command-looking key names such as
/// Enter/Home/Tab literal. Key values use the adapters' shared native spelling.
pub(crate) fn send_payload(text: &str) -> Value {
    let named = match text {
        "Escape" => Some("escape".into()),
        "Up" | "Down" | "Left" | "Right" => Some(text.to_ascii_lowercase()),
        "PPage" => Some("pageup".into()),
        "NPage" => Some("pagedown".into()),
        "BTab" => Some("shift+tab".into()),
        _ if text
            .strip_prefix('F')
            .filter(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|n| n.parse::<u8>().ok())
            .map_or(false, |n| (1..=12).contains(&n))
            && !text.starts_with("F0") =>
        {
            Some(text.to_ascii_lowercase())
        }
        _ => None,
    };
    let key = named.or_else(|| {
        for (prefix, modifier) in [
            ("C-M-", "ctrl+alt+"),
            ("M-C-", "ctrl+alt+"),
            ("C-", "ctrl+"),
            ("M-", "alt+"),
            ("^", "ctrl+"),
        ] {
            if let Some(rest) = text.strip_prefix(prefix) {
                if rest.len() == 1 && (33..127).contains(&rest.as_bytes()[0]) {
                    return Some(format!("{modifier}{rest}"));
                }
            }
        }
        None
    });
    match key {
        Some(key) => json!({"key":key,"enter":false}),
        None => json!({"text":text,"enter":true}),
    }
}

/// Explicit UI action only. A detached Rust worker survives picker/terminal
/// closure; persisted interrupted jobs remain visible after a machine restart.
pub(crate) fn schedule(descriptor: &Value, when: &str, command: &str) -> Result<Value, String> {
    let time = resolve_time(when)?;
    let store = Store {
        root: state_root()?,
    };
    let mut record = store.create(
        descriptor,
        time["due"].as_u64().unwrap(),
        time["when"].as_str().unwrap(),
        command,
    )?;
    let id = record["id"].as_str().unwrap().to_owned();
    let mut child = Command::new(std::env::current_exe().map_err(|e| e.to_string())?);
    child
        .args(["jobs", "run", &id, "--root"])
        .arg(&store.root)
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // Preserve unexpected worker/transport diagnostics too. These descriptors
    // are files, not the submitting PTY; setsid below owns the lifetime.
    let mut log_options = OpenOptions::new();
    log_options.write(true).append(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        log_options.mode(0o600);
    }
    if let Ok(log) = log_options.open(store.root.join("scheduled.log")) {
        if let Ok(stdout) = log.try_clone() {
            child.stdout(Stdio::from(stdout)).stderr(Stdio::from(log));
        }
    }
    for name in [
        "TMUX",
        "TMUX_PANE",
        "REX_SESSION",
        "REX_BLOCK",
        "REX_CLIENT",
        "FZF_CURRENT_ITEM",
        "FZF_QUERY",
    ] {
        child.env_remove(name);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            child.pre_exec(|| {
                extern "C" {
                    fn setsid() -> i32;
                }
                if setsid() == -1 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(())
                }
            });
        }
    }
    match child.spawn() {
        Ok(mut child) => {
            let pid = child.id();
            // Read while Child is still unreaped. Even a fast exit cannot
            // recycle its PID into an unrelated process before this lookup.
            let birth = crate::worker_identity::get(pid);
            std::thread::spawn(move || {
                let _ = child.wait();
            });
            let _lock = Lock::get(&store.directory(&id)?)?;
            record = store.read(&id)?;
            if record["status"] == "scheduled" {
                // The worker may already have recorded its own birth. Keep
                // that proof if this parent's platform probe was unavailable.
                if record["worker_pid"] != pid || birth.is_some() {
                    record["worker_birth"] = json!(birth);
                }
                record["worker_pid"] = json!(pid);
                store.save(&record)?;
            }
            Ok(record)
        }
        Err(error) => {
            record["status"] = json!("failed");
            record["error"] = json!(format!("Cannot start scheduled worker: {error}"));
            store.save(&record)?;
            Err(record["error"].as_str().unwrap().into())
        }
    }
}

pub(crate) fn list() -> Result<Vec<Value>, String> {
    Store {
        root: state_root()?,
    }
    .list()
}
pub(crate) fn cancel(id: &str) -> Result<Value, String> {
    Store {
        root: state_root()?,
    }
    .cancel(id)
}
pub(crate) fn output(id: &str) -> Result<String, String> {
    let store = Store {
        root: state_root()?,
    };
    let record = store.read(id)?;
    let path = store.directory(id)?.join("output.log");
    let mut file = File::open(&path).map_err(|e| e.to_string())?;
    let size = file.metadata().map_err(|e| e.to_string())?.len();
    file.seek(SeekFrom::Start(size.saturating_sub(65_536)))
        .map_err(|e| e.to_string())?;
    let mut bytes = Vec::new();
    file.take(65_536)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    Ok(format!(
        "{} → {}\n{}\n{}",
        record["when"].as_str().unwrap_or(""),
        record["label"].as_str().unwrap_or(""),
        record["command"].as_str().unwrap_or(""),
        String::from_utf8_lossy(&bytes)
    ))
}

pub(crate) fn cli(args: &[String], dispatch: Dispatch) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("run") => {
            let id = args.get(1).ok_or("jobs run requires an ID")?;
            let root = if args.get(2).map(String::as_str) == Some("--root") {
                PathBuf::from(args.get(3).ok_or("--root requires a path")?)
            } else {
                state_root()?
            };
            Store { root }.run(id, dispatch)
        }
        Some("list") => {
            println!("{}", json!(list()?));
            Ok(())
        }
        Some("cancel") => {
            println!(
                "{}",
                cancel(args.get(1).ok_or("jobs cancel requires an ID")?)?
            );
            Ok(())
        }
        Some("output") => {
            print!(
                "{}",
                output(args.get(1).ok_or("jobs output requires an ID")?)?
            );
            Ok(())
        }
        _ => Err("Usage: imux jobs list | cancel ID | output ID | run ID".into()),
    }
}

// POSIX calendar conversion, shared by Linux/macOS and independent of `atd`.
#[repr(C)]
struct Tm {
    sec: i32,
    min: i32,
    hour: i32,
    mday: i32,
    mon: i32,
    year: i32,
    wday: i32,
    yday: i32,
    isdst: i32,
    gmtoff: std::os::raw::c_long,
    zone: *const std::os::raw::c_char,
}
extern "C" {
    fn localtime_r(value: *const i64, out: *mut Tm) -> *mut Tm;
    fn mktime(value: *mut Tm) -> i64;
    fn strptime(
        text: *const std::os::raw::c_char,
        format: *const std::os::raw::c_char,
        out: *mut Tm,
    ) -> *mut std::os::raw::c_char;
}
fn local(seconds: u64) -> Result<Tm, String> {
    let seconds = i64::try_from(seconds).map_err(|_| "Scheduled time is out of range")?;
    let mut tm = unsafe { std::mem::zeroed::<Tm>() };
    if unsafe { localtime_r(&seconds, &mut tm) }.is_null() {
        Err("Cannot convert scheduled time".into())
    } else {
        Ok(tm)
    }
}
fn calendar(tm: &mut Tm) -> Result<u64, String> {
    tm.isdst = -1;
    let value = unsafe { mktime(tm) };
    u64::try_from(value).map_err(|_| "Scheduled time is out of range".into())
}
fn stamp(due: u64) -> Result<String, String> {
    let tm = local(due)?;
    let offset = tm.gmtoff;
    let sign = if offset < 0 { '-' } else { '+' };
    let offset = offset.abs();
    Ok(format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02} {sign}{:02}{:02}",
        tm.year + 1900,
        tm.mon + 1,
        tm.mday,
        tm.hour,
        tm.min,
        tm.sec,
        offset / 3600,
        offset % 3600 / 60
    ))
}
fn parsed_date(text: &str, format: &str) -> Result<Option<u64>, String> {
    let Ok(text) = std::ffi::CString::new(text) else {
        return Ok(None);
    };
    let Ok(format) = std::ffi::CString::new(format) else {
        return Ok(None);
    };
    let mut tm = unsafe { std::mem::zeroed::<Tm>() };
    let end = unsafe { strptime(text.as_ptr(), format.as_ptr(), &mut tm) };
    if end.is_null() || unsafe { *end } != 0 {
        return Ok(None);
    }
    // mktime normalizes February 31, leap seconds, and clocks skipped by a
    // daylight-saving transition. Explicit dates must never silently move a
    // scheduled send to another day or hour.
    let requested = (tm.year, tm.mon, tm.mday, tm.hour, tm.min, tm.sec);
    let due = calendar(&mut tm)?;
    if requested != (tm.year, tm.mon, tm.mday, tm.hour, tm.min, tm.sec) {
        return Err("The requested date or clock time does not exist in the local timezone".into());
    }
    Ok(Some(due))
}
fn parse_time(spec: &str, now: u64) -> Result<u64, String> {
    let spec = spec.trim();
    if spec.is_empty()
        || spec.len() > 512
        || spec.chars().any(char::is_control)
        || spec.split_whitespace().any(|word| word.starts_with('-'))
    {
        return Err("Enter a relative delay or a clock time".into());
    }
    let lower = spec.to_ascii_lowercase();
    if lower == "now" {
        return Ok(now);
    }
    if let Some(unit) = lower.chars().last() {
        let number = &lower[..lower.len() - unit.len_utf8()];
        if !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()) {
            let scale = match unit {
                's' => Some(1u64),
                'm' => Some(60),
                'h' => Some(3600),
                'd' => Some(86400),
                _ => None,
            };
            if let Some(scale) = scale {
                return number
                    .parse::<u64>()
                    .ok()
                    .and_then(|n| n.checked_mul(scale))
                    .and_then(|n| now.checked_add(n))
                    .ok_or_else(|| "The delay is too large".into());
            }
        }
    }
    if lower.len() <= 3 && lower.bytes().all(|b| b.is_ascii_digit()) {
        return lower
            .parse::<u64>()
            .ok()
            .and_then(|n| n.checked_mul(60))
            .and_then(|n| now.checked_add(n))
            .ok_or_else(|| "The delay is too large".into());
    }
    let mut words = lower.split_whitespace();
    let clock = words.next().unwrap_or("");
    let day = words.next();
    if words.next().is_none() && matches!(day, None | Some("today" | "tomorrow")) {
        let bare = clock.trim_end_matches("am").trim_end_matches("pm");
        let pair = match bare {
            "noon" => Some((12, 0)),
            "midnight" => Some((0, 0)),
            "teatime" => Some((16, 0)),
            _ => {
                if let Some((h, m)) = bare.split_once(':') {
                    h.parse::<i32>().ok().zip(m.parse::<i32>().ok())
                } else if bare.len() == 4 && bare.bytes().all(|b| b.is_ascii_digit()) {
                    bare[..2]
                        .parse::<i32>()
                        .ok()
                        .zip(bare[2..].parse::<i32>().ok())
                } else if clock.ends_with("am") || clock.ends_with("pm") {
                    bare.parse::<i32>().ok().map(|h| (h, 0))
                } else {
                    None
                }
            }
        };
        if let Some((mut hour, minute)) = pair {
            if clock.ends_with("am") || clock.ends_with("pm") {
                if !(1..=12).contains(&hour) {
                    return Err("Clock hours must be 1–12 with am/pm".into());
                }
                hour = hour % 12 + if clock.ends_with("pm") { 12 } else { 0 };
            }
            if !(0..=23).contains(&hour) || !(0..=59).contains(&minute) {
                return Err("Enter a valid clock time".into());
            }
            let mut tm = local(now)?;
            tm.hour = hour;
            tm.min = minute;
            tm.sec = 0;
            if day == Some("tomorrow") {
                tm.mday += 1
            }
            let mut due = calendar(&mut tm)?;
            if due < now && day.is_none() {
                tm.mday += 1;
                tm.hour = hour;
                tm.min = minute;
                due = calendar(&mut tm)?;
            }
            if (tm.hour, tm.min) != (hour, minute) {
                return Err("The requested clock time does not exist in the local timezone".into());
            }
            if due < now {
                return Err("The requested time is in the past".into());
            }
            return Ok(due);
        }
    }
    for format in ["%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"] {
        if let Some(due) = parsed_date(spec, format)? {
            return if due < now {
                Err("The requested time is in the past".into())
            } else {
                Ok(due)
            };
        }
    }
    let due = at_time(spec)?;
    if due < now {
        Err("The requested time is in the past".into())
    } else {
        Ok(due)
    }
}

/// `at -v` prints its resolved time BEFORE reading a job. Keep stdin open,
/// never provide a body, then kill/wait before closing it: no at job is queued.
fn at_time(spec: &str) -> Result<u64, String> {
    at_time_with(spec, Path::new("at"))
}

fn at_time_with(spec: &str, program: &Path) -> Result<u64, String> {
    let mut child=Command::new(program).arg("-v").args(["-q","i"]).args(spec.split_whitespace()).env("LC_ALL","C")
        .stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::piped()).spawn()
        .map_err(|_|"This time needs at's parser; use 30s,5m,2h,HHMM,17:30,noon tomorrow or an ISO date/time".to_owned())?;
    let stdin = child.stdin.take();
    let stderr = child.stderr.take().ok_or("Cannot read at's time parser")?;
    let (send, receive) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().take(16) {
            if send.send(line).is_err() {
                break;
            }
        }
    });
    let end = Instant::now() + Duration::from_secs(2);
    let mut messages = Vec::new();
    let mut result = None;
    while let Some(remaining) = end.checked_duration_since(Instant::now()) {
        match receive.recv_timeout(remaining) {
            Ok(Ok(line)) => {
                if let Ok(Some(due)) = parsed_date(line.trim(), "%a %b %e %H:%M:%S %Y") {
                    result = Some(due);
                    break;
                }
                messages.push(line);
            }
            _ => break,
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    drop(stdin);
    let _ = reader.join();
    result.ok_or_else(|| {
        format!(
            "Time was refused: {}",
            messages.join(" ").chars().take(300).collect::<String>()
        )
    })
}

pub(crate) fn resolve_time(spec: &str) -> Result<Value, String> {
    let due = parse_time(spec, now())?;
    Ok(json!({"due":due,"when":stamp(due)?}))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        base: PathBuf,
        store: Store,
    }
    impl Fixture {
        fn new() -> Self {
            let base = std::env::temp_dir().join(format!(
                "imux-jobs-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            private_dir(&base).unwrap();
            Self {
                store: Store {
                    root: base.join("state"),
                },
                base,
            }
        }
        fn descriptor(&self) -> Value {
            json!({"backend":"rex","target":{"session_id":"session:stable","block_id":"block:stable"},
                "guard":{"instance_id":"server:original","host_id":"host:original"},
                "label":"my project desc=literal ' $() #name","capture":self.base.join("delivered.jsonl")})
        }
        fn create(&self, command: &str) -> Value {
            self.store
                .create(&self.descriptor(), now(), "resolved time", command)
                .unwrap()
        }
        fn deliveries(&self) -> Vec<Value> {
            fs::read_to_string(self.base.join("delivered.jsonl"))
                .unwrap_or_default()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.base);
        }
    }

    fn deliver(descriptor: &Value, payload: &Value) -> Result<Value, String> {
        if descriptor["guard"]["instance_id"] != "server:original" {
            return Err("The server restarted; refusing recycled pane identity".into());
        }
        let path = descriptor["capture"]
            .as_str()
            .ok_or("missing test capture")?;
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|e| e.to_string())?;
        writeln!(
            file,
            "{}",
            json!({"target":descriptor["target"],"payload":payload})
        )
        .map_err(|e| e.to_string())?;
        Ok(json!({"delivered":true}))
    }

    #[test]
    fn legacy_key_detection_keeps_command_looking_words_literal() {
        for (input, key) in [
            ("C-c", "ctrl+c"),
            ("M-x", "alt+x"),
            ("C-M-x", "ctrl+alt+x"),
            ("M-C-x", "ctrl+alt+x"),
            ("^x", "ctrl+x"),
            ("C-;", "ctrl+;"),
            ("Escape", "escape"),
            ("Up", "up"),
            ("PPage", "pageup"),
            ("BTab", "shift+tab"),
            ("F12", "f12"),
        ] {
            assert_eq!(
                send_payload(input),
                json!({"key":key,"enter":false}),
                "{input}"
            );
        }
        for text in [
            "Enter",
            "Home",
            "End",
            "Tab",
            "Space",
            "c-c",
            "C-c C-c",
            "C-é",
            "C- ",
            "F01",
            "F+1",
            "F13",
            "echo '$HOME'; #H",
            "tab\tand\nnewline",
        ] {
            assert_eq!(
                send_payload(text),
                json!({"text":text,"enter":true}),
                "{text}"
            );
        }
    }

    #[test]
    fn shorthand_minutes_and_clocks_do_not_shadow_hhmm() {
        let baseline = 1_700_000_000;
        for (spec, seconds) in [
            ("30s", 30),
            ("5m", 300),
            ("2h", 7200),
            ("1d", 86400),
            ("90", 5400),
            ("09", 540),
        ] {
            assert_eq!(
                parse_time(spec, baseline).unwrap(),
                baseline + seconds,
                "{spec}"
            );
        }
        let due = parse_time("1730", baseline).unwrap();
        let clock = local(due).unwrap();
        assert_eq!((clock.hour, clock.min, clock.sec), (17, 30, 0));
        assert!(due >= baseline && due - baseline < 90_000);
        let noon = local(parse_time("noon tomorrow", baseline).unwrap()).unwrap();
        assert_eq!((noon.hour, noon.min), (12, 0));
        let morning = local(parse_time("1:10am tomorrow", baseline).unwrap()).unwrap();
        assert_eq!((morning.hour, morning.min), (1, 10));
        for bad in [
            "",
            "25:99",
            "-f /tmp/must-not-run",
            "now -f /tmp/must-not-run",
            "1\n2",
            "9999999999999999999999999999999999999h",
        ] {
            assert!(parse_time(bad, baseline).is_err(), "{bad}");
        }
    }

    #[test]
    fn explicit_dates_reject_calendar_normalization_instead_of_sending_on_another_day() {
        let baseline = 1_700_000_000;
        for invalid in [
            "2027-02-29 12:00",
            "2027-02-31 12:00:00",
            "2027-04-31 12:00",
        ] {
            assert!(
                parse_time(invalid, baseline)
                    .unwrap_err()
                    .contains("does not exist"),
                "{invalid}"
            );
        }
        let valid = local(parse_time("2028-02-29 12:34:56", baseline).unwrap()).unwrap();
        assert_eq!(
            (
                valid.year + 1900,
                valid.mon + 1,
                valid.mday,
                valid.hour,
                valid.min,
                valid.sec
            ),
            (2028, 2, 29, 12, 34, 56)
        );
    }

    #[test]
    fn clocks_skipped_by_daylight_saving_are_rejected_without_shifting_tomorrow() {
        const CHILD: &str = "IMUX_TEST_DST_CALENDAR";
        if std::env::var_os(CHILD).is_none() {
            // TZ is process-global; isolate it from the rest of the parallel
            // suite. POSIX transition rules need no installed zoneinfo files.
            let output = Command::new(std::env::current_exe().unwrap())
                .args(["jobs::tests::clocks_skipped_by_daylight_saving_are_rejected_without_shifting_tomorrow", "--exact", "--nocapture"])
                .env(CHILD, "1")
                .env("TZ", "EST5EDT,M3.2.0/2,M11.1.0/2")
                .output().unwrap();
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }
        let date = |value| parsed_date(value, "%Y-%m-%d %H:%M").unwrap().unwrap();
        let before = date("2027-03-14 01:30");
        assert!(parse_time("02:30 today", before)
            .unwrap_err()
            .contains("does not exist"));
        assert!(parse_time("2027-03-14 02:30", before)
            .unwrap_err()
            .contains("does not exist"));
        assert!(parse_time("02:30 tomorrow", date("2027-03-13 12:00"))
            .unwrap_err()
            .contains("does not exist"));
        let next = local(parse_time("02:30", date("2027-03-14 12:00")).unwrap()).unwrap();
        assert_eq!(
            (next.mon + 1, next.mday, next.hour, next.min),
            (3, 15, 2, 30)
        );
    }

    #[test]
    fn jobs_round_trip_literal_data_and_permissions_then_deliver_once() {
        let f = Fixture::new();
        assert!(f.store.list().unwrap().is_empty());
        assert!(
            !f.store.root.exists(),
            "listing an absent store creates no files"
        );
        let text = "echo tab\tquotes '\"' $HOME `date`; #H\nnext-line";
        let record = f.create(text);
        let id = record["id"].as_str().unwrap();
        assert_eq!(f.store.read(id).unwrap()["command"], text);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(f.store.directory(id).unwrap())
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o700
            );
            assert_eq!(
                fs::metadata(f.store.directory(id).unwrap().join("job.json"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        f.store.run(id, deliver).unwrap();
        f.store.run(id, deliver).unwrap();
        assert_eq!(f.deliveries().len(), 1);
        assert_eq!(
            f.deliveries()[0]["payload"],
            json!({"text":text,"enter":true})
        );
        assert_eq!(f.store.read(id).unwrap()["status"], "sent");
        assert!(f.store.root.join("scheduled.log").is_file());
        assert!(f.store.directory(id).unwrap().join("output.log").is_file());
    }

    #[test]
    fn undo_prevents_delivery_and_never_touches_unrelated_jobs() {
        let f = Fixture::new();
        let record = f.create("C-c");
        let id = record["id"].as_str().unwrap();
        fs::write(f.store.jobs().join("unrelated.txt"), "untouched").unwrap();
        assert_eq!(f.store.cancel(id).unwrap()["status"], "cancelled");
        f.store.run(id, deliver).unwrap();
        assert!(f.deliveries().is_empty());
        assert!(f.store.cancel("../unrelated.txt").is_err());
        assert!(f.store.cancel("unrelated.txt").is_err());
        assert_eq!(
            fs::read_to_string(f.store.jobs().join("unrelated.txt")).unwrap(),
            "untouched"
        );
        assert_eq!(f.store.list().unwrap().len(), 1);
        let unrelated = f.store.jobs().join("deadbeef");
        fs::create_dir(&unrelated).unwrap();
        fs::write(unrelated.join("lock"), i32::MAX.to_string()).unwrap();
        assert!(f.store.cancel("deadbeef").is_err());
        assert!(f.store.run("deadbeef", deliver).is_err());
        assert_eq!(
            fs::read_to_string(unrelated.join("lock")).unwrap(),
            i32::MAX.to_string()
        );
    }

    #[test]
    fn backend_identity_failure_is_persisted_without_send() {
        let f = Fixture::new();
        let mut descriptor = f.descriptor();
        descriptor["guard"]["instance_id"] = json!("restarted-server");
        let record = f
            .store
            .create(&descriptor, now(), "resolved", "make deploy")
            .unwrap();
        let id = record["id"].as_str().unwrap();
        assert!(f.store.run(id, deliver).unwrap_err().contains("restarted"));
        let failed = f.store.read(id).unwrap();
        assert_eq!(failed["status"], "failed");
        assert!(failed["error"].as_str().unwrap().contains("restarted"));
        assert!(f.deliveries().is_empty());
        assert!(f.store.cancel(id).is_err());
    }

    #[test]
    fn two_workers_cannot_claim_the_same_send() {
        let f = Fixture::new();
        let record = f.create("echo once");
        let id = record["id"].as_str().unwrap();
        std::thread::scope(|scope| {
            let first = scope.spawn(|| f.store.run(id, deliver));
            let second = scope.spawn(|| f.store.run(id, deliver));
            first.join().unwrap().unwrap();
            second.join().unwrap().unwrap();
        });
        assert_eq!(f.deliveries().len(), 1);
        assert_eq!(f.store.read(id).unwrap()["status"], "sent");
    }

    #[cfg(unix)]
    #[test]
    fn abandoned_lock_file_is_reused_without_breaking_mutual_exclusion() {
        use std::sync::mpsc;
        let f = Fixture::new();
        let record = f.create("echo once");
        let directory = f.store.directory(record["id"].as_str().unwrap()).unwrap();
        // A process could have died between creating the file and writing a
        // PID. Its empty file must not keep a pending send locked forever.
        fs::write(directory.join("lock"), "").unwrap();
        let first = Lock::get(&directory).unwrap();
        let (began_tx, began_rx) = mpsc::channel();
        let (acquired_tx, acquired_rx) = mpsc::channel();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                began_tx.send(()).unwrap();
                let _second = Lock::get(&directory).unwrap();
                acquired_tx.send(()).unwrap();
            });
            began_rx.recv().unwrap();
            assert!(matches!(
                acquired_rx.recv_timeout(Duration::from_millis(30)),
                Err(mpsc::RecvTimeoutError::Timeout)
            ));
            drop(first);
            acquired_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        });
        assert!(directory.join("lock").is_file());
    }

    #[test]
    fn waiting_worker_records_identity_and_honors_cancellation() {
        let f = Fixture::new();
        let record = f
            .store
            .create(&f.descriptor(), now() + 100, "later", "echo not sent")
            .unwrap();
        let id = record["id"].as_str().unwrap();
        std::thread::scope(|scope| {
            let worker = scope.spawn(|| f.store.run(id, deliver));
            let until = Instant::now() + Duration::from_secs(2);
            while f.store.read(id).unwrap()["worker_pid"] != std::process::id() {
                assert!(
                    Instant::now() < until,
                    "waiting worker did not persist its own identity"
                );
                std::thread::sleep(Duration::from_millis(1));
            }
            f.store.cancel(id).unwrap();
            worker.join().unwrap().unwrap();
        });
        assert_eq!(f.store.read(id).unwrap()["status"], "cancelled");
        assert!(f.deliveries().is_empty());
    }

    #[test]
    fn waiting_worker_observes_replaced_due_time_before_the_original_deadline() {
        let f = Fixture::new();
        let record = f
            .store
            .create(&f.descriptor(), now() + 5, "later", "echo once")
            .unwrap();
        let id = record["id"].as_str().unwrap();
        std::thread::scope(|scope| {
            let worker = scope.spawn(|| f.store.run(id, deliver));
            let until = Instant::now() + Duration::from_secs(2);
            while f.store.read(id).unwrap()["worker_pid"] != std::process::id() {
                assert!(Instant::now() < until, "worker did not begin");
                std::thread::sleep(Duration::from_millis(1));
            }
            let mut changed = f.store.read(id).unwrap();
            changed["due"] = json!(now());
            f.store.save(&changed).unwrap();
            while f.store.read(id).unwrap()["status"] != "sent" {
                assert!(Instant::now() < until, "worker ignored the replaced record");
                std::thread::sleep(Duration::from_millis(5));
            }
            worker.join().unwrap().unwrap();
        });
        assert_eq!(f.deliveries().len(), 1);
    }

    #[test]
    fn listing_orders_times_and_reports_dead_workers() {
        let f = Fixture::new();
        let a = f
            .store
            .create(&f.descriptor(), now() + 100, "later", "echo later")
            .unwrap();
        let mut b = f
            .store
            .create(&f.descriptor(), now() + 50, "earlier", "echo earlier")
            .unwrap();
        b["worker_pid"] = json!(i32::MAX);
        f.store.save(&b).unwrap();
        let rows = f.store.list().unwrap();
        assert_eq!(rows[0]["id"], b["id"]);
        assert_eq!(rows[1]["id"], a["id"]);
        assert_eq!(rows[0]["status"], "interrupted");
        assert!(rows[0]["error"]
            .as_str()
            .unwrap()
            .contains("worker stopped"));
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    fn another_birth(birth: &str) -> String {
        let (prefix, counter) = birth.rsplit_once(':').unwrap();
        let counter = counter.parse::<u64>().unwrap();
        format!("{prefix}:{}", if counter == 0 { 1 } else { 0 })
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn listing_rejects_reused_live_pids_but_keeps_matching_and_legacy_workers() {
        let birth = crate::worker_identity::get(std::process::id()).unwrap();
        for state in ["scheduled", "running"] {
            let f = Fixture::new();
            let mut record = f.create("echo must not be sent by listing");
            record["status"] = json!(state);
            record["worker_pid"] = json!(std::process::id());
            record["worker_birth"] = json!(birth);
            f.store.save(&record).unwrap();
            assert_eq!(f.store.list().unwrap()[0]["status"], state);
            record.as_object_mut().unwrap().remove("worker_birth");
            f.store.save(&record).unwrap();
            assert_eq!(
                f.store.list().unwrap()[0]["status"],
                state,
                "old records remain readable without claiming PID reuse"
            );
            record["worker_birth"] = json!(another_birth(&birth));
            f.store.save(&record).unwrap();
            assert!(
                alive(std::process::id()),
                "the reused PID is deliberately still alive"
            );
            let rows = f.store.list().unwrap();
            assert_eq!(rows[0]["status"], "interrupted");
            assert_eq!(
                f.store.read(record["id"].as_str().unwrap()).unwrap()["status"],
                "interrupted"
            );
            assert!(f.deliveries().is_empty());
        }
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn explicit_worker_run_does_not_confuse_a_reused_pid_with_an_existing_worker() {
        struct Sleeper(std::process::Child);
        impl Drop for Sleeper {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let mut unrelated = Sleeper(Command::new("sleep").arg("30").spawn().unwrap());
        let pid = unrelated.0.id();
        let birth = crate::worker_identity::get(pid).unwrap();
        let f = Fixture::new();
        let mut record = f.create("echo exactly once");
        let id = record["id"].as_str().unwrap().to_owned();
        record["worker_pid"] = json!(pid);
        record["worker_birth"] = json!(birth);
        f.store.save(&record).unwrap();
        f.store.run(&id, deliver).unwrap();
        assert!(
            f.deliveries().is_empty(),
            "matching birth still prevents a second worker"
        );
        record["worker_birth"] = json!(another_birth(&birth));
        f.store.save(&record).unwrap();
        f.store.run(&id, deliver).unwrap();
        f.store.run(&id, deliver).unwrap();
        assert_eq!(f.deliveries().len(), 1);
        let sent = f.store.read(&id).unwrap();
        assert_eq!(sent["status"], "sent");
        assert_eq!(
            sent["worker_birth"],
            json!(crate::worker_identity::get(std::process::id()).unwrap())
        );
        assert!(
            unrelated.0.try_wait().unwrap().is_none(),
            "the unrelated process must never be signalled"
        );
    }

    #[cfg(unix)]
    #[test]
    fn at_time_probe_never_finishes_or_submits_a_job_body() {
        use std::os::unix::fs::PermissionsExt;
        let f = Fixture::new();
        let shim = f.base.join("fake-at");
        fs::write(&shim,"#!/bin/sh\nprintf 'Thu Nov  5 17:30:00 2037\\n' >&2\ncat >/dev/null\n: > \"$0.submitted\"\n").unwrap();
        fs::set_permissions(&shim, fs::Permissions::from_mode(0o700)).unwrap();
        let due = at_time_with("noon tomorrow", &shim).unwrap();
        assert_eq!(local(due).unwrap().year + 1900, 2037);
        assert!(
            !f.base.join("fake-at.submitted").exists(),
            "the parser received EOF and submitted a job"
        );
    }
}
