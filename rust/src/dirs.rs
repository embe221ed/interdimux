//! Directory candidates for the one-list model, and project-type detection.
//! Mirrors bash `load_recent_dirs` + `detect_project_type`.

use std::fs;
use std::io::{self, Read};
use std::path::Path;
use std::process::{Child, ChildStdout, Command, Output, Stdio};
use std::time::{Duration, Instant};

fn recent_file() -> String {
    let base = std::env::var("XDG_DATA_HOME").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| {
        format!("{}/.local/share", std::env::var("HOME").unwrap_or_default())
    });
    format!("{}/interdimux/recent_dirs", base)
}

fn recent_limit() -> usize {
    std::env::var("INTERDIMUX_RECENT_LIMIT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(10)
}

/// One directory per line, as the recent file and `zoxide query --list` both
/// write them.  A line that is not valid UTF-8 is SKIPPED, never decoded
/// lossily: the lossy string names a directory that does not exist (U+FFFD in
/// place of the byte), and even the raw bytes could not be offered, because fzf
/// hands a selection back with every invalid byte replaced by U+FFFD -- so a row
/// for such a directory can never be opened, from either renderer.  bash's
/// load_recent_dirs skips the same lines (is_utf8).
///
/// Split on '\n' alone, like bash's `read -r`: `str::lines()` would also strip a
/// trailing '\r', which bash keeps.
fn utf8_lines(bytes: &[u8]) -> impl Iterator<Item = &str> {
    bytes.split(|b| *b == b'\n').filter_map(|l| std::str::from_utf8(l).ok())
}

/// Is `d` worth offering?  An existing directory -- except on a filesystem whose
/// stat can block (mounts.rs), which is offered unchecked: one stalled mount in
/// the recent list used to hold the whole first paint for its timeout.
fn offerable(d: &str) -> bool {
    crate::mounts::is_remote(d) || Path::new(d).is_dir()
}

/// `zoxide query --list`, with `--all` or without.  `--all`: without it zoxide
/// stats EVERY entry in its database to hide the missing ones, so one entry on
/// a stalled mount hangs zoxide itself.  The existence check is ours now
/// (offerable), and a zoxide too old to know the flag gets the plain query.
fn zoxide_query(all: bool) -> Command {
    let mut c = Command::new("zoxide");
    c.args(["query", "--list"]);
    if all {
        c.arg("--all");
    }
    c.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    c
}

// Optional history enrichment must not hold up a picker or a successful switch.
// The same deadline covers --all and the compatibility fallback. A pipe is
// drained without blocking, so a full pipe or an inherited writer cannot make
// waiting/cleanup exceed the deadline or retain an unbounded reader thread.
const ZOXIDE_TIMEOUT: Duration = Duration::from_millis(250);
const ZOXIDE_OUTPUT_LIMIT: usize = 1_048_576;

pub(crate) struct Zoxide {
    child: Child,
    stdout: ChildStdout,
    deadline: Instant,
    limit: usize,
    finished: bool,
}

impl Zoxide {
    fn start(mut command: Command, deadline: Instant, limit: usize) -> Option<Self> {
        if Instant::now() >= deadline {
            return None;
        }
        command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        let mut child = command.spawn().ok()?;
        let stdout = child.stdout.take()?;
        let mut result = Self {
            child,
            stdout,
            deadline,
            limit,
            finished: false,
        };
        if nonblocking(&result.stdout).is_err() {
            result.stop();
            return None;
        }
        Some(result)
    }

    fn stop(&mut self) {
        if self.finished {
            return;
        }
        #[cfg(unix)]
        {
            extern "C" {
                fn kill(pid: i32, signal: i32) -> i32;
            }
            // The child has its own process group; also stop descendants that
            // inherited stdout, rather than leaving their pipe open forever.
            unsafe {
                kill(-(self.child.id() as i32), 9);
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        self.finished = true;
    }

    fn output(mut self) -> Option<Output> {
        let mut bytes = Vec::new();
        let mut status = None;
        let mut eof = false;
        let mut chunk = [0; 8192];
        loop {
            loop {
                if Instant::now() >= self.deadline {
                    return None;
                }
                match self.stdout.read(&mut chunk) {
                    Ok(0) => {
                        eof = true;
                        break;
                    }
                    Ok(n) => {
                        if n > self.limit.saturating_sub(bytes.len()) {
                            return None;
                        }
                        bytes.extend_from_slice(&chunk[..n]);
                    }
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(_) => return None,
                }
            }
            if status.is_none() {
                status = self.child.try_wait().ok()?;
            }
            if let Some(status) = status.filter(|_| eof) {
                self.finished = true;
                return Some(Output {
                    status,
                    stdout: bytes,
                    stderr: Vec::new(),
                });
            }
            let remaining = self.deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return None;
            }
            std::thread::sleep(remaining.min(Duration::from_millis(5)));
        }
    }
}

impl Drop for Zoxide {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(unix)]
fn nonblocking(stdout: &ChildStdout) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    extern "C" {
        fn fcntl(fd: i32, command: i32, ...) -> i32;
    }
    #[cfg(target_os = "linux")]
    const NONBLOCK: i32 = 0x800;
    #[cfg(not(target_os = "linux"))]
    const NONBLOCK: i32 = 0x4;
    let fd = stdout.as_raw_fd();
    let flags = unsafe { fcntl(fd, 3) };
    if flags < 0 || unsafe { fcntl(fd, 4, flags | NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(unix))]
fn nonblocking(_: &ChildStdout) -> io::Result<()> {
    // zoxide is optional. Do not use an unbounded pipe on an unsupported host.
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "nonblocking pipe unavailable",
    ))
}

pub(crate) fn zoxide(args: &[&str]) -> Option<Output> {
    let mut command = Command::new("zoxide");
    command.args(args);
    Zoxide::start(
        command,
        Instant::now() + ZOXIDE_TIMEOUT,
        ZOXIDE_OUTPUT_LIMIT,
    )?
    .output()
}

/// Start enrichment before rendering. The timeout begins at spawn, not when
/// the caller eventually collects the output. Drop always kills and reaps it.
pub fn start_zoxide() -> Option<Zoxide> {
    let use_zoxide = std::env::var("INTERDIMUX_USE_ZOXIDE")
        .map(|v| v == "on")
        .unwrap_or(true);
    if !use_zoxide {
        return None;
    }
    Zoxide::start(
        zoxide_query(true),
        Instant::now() + ZOXIDE_TIMEOUT,
        ZOXIDE_OUTPUT_LIMIT,
    )
}

fn listed_zoxide(child: Zoxide) -> Option<Output> {
    let deadline = child.deadline;
    let output = child.output()?;
    if output.status.success() {
        return Some(output);
    }
    // Only a completed rejection gets an old-zoxide compatibility retry. A
    // stalled or oversized response does not consume a second timeout budget.
    Zoxide::start(zoxide_query(false), deadline, ZOXIDE_OUTPUT_LIMIT)?
        .output()
        .filter(|output| output.status.success())
}

/// The legacy gatherer's small recent/zoxide suggestion list.
pub fn candidates(zoxide: Option<Zoxide>) -> Vec<String> {
    candidates_with_limit(zoxide, recent_limit())
}

/// Explicit project discovery must consider history before presentation caps.
/// Output and history-file byte caps still bound the amount of enrichment.
pub(crate) fn retained_candidates(zoxide: Option<Zoxide>) -> Vec<String> {
    candidates_with_limit(zoxide, usize::MAX)
}

fn candidates_with_limit(zoxide: Option<Zoxide>, limit: usize) -> Vec<String> {
    let mut seen: std::collections::HashSet<String> = Default::default();
    let mut out = Vec::new();
    if let Some(text) = crate::projects::recent_text(Path::new(&recent_file())) {
        for d in utf8_lines(text.as_bytes()) {
            if out.len() >= limit {
                break;
            }
            if d.is_empty() || seen.contains(d) || !offerable(d) {
                continue;
            }
            seen.insert(d.to_string());
            out.push(d.to_string());
        }
    }
    if let Some(output) = zoxide.and_then(listed_zoxide) {
        let mut n = 0;
        for d in utf8_lines(&output.stdout) {
            if n >= limit {
                break;
            }
            if d.is_empty() || seen.contains(d) || !offerable(d) {
                continue;
            }
            seen.insert(d.to_string());
            out.push(d.to_string());
            n += 1;
        }
    }
    out
}

/// First matching marker wins — the same order bash checks in.  Nothing is
/// probed on a filesystem whose stat can block (mounts.rs).
pub fn project_type(dir: &str) -> Option<&'static str> {
    if crate::mounts::is_remote(dir) {
        return None;
    }
    const FILES: &[(&str, &str)] = &[
        ("Cargo.toml", "Rust"),
        ("go.mod", "Go"),
        ("package.json", "Node.js"),
        ("pyproject.toml", "Python"),
        ("CMakeLists.txt", "C/C++"),
        ("build.gradle", "Java"),
        ("pom.xml", "Java"),
        ("mix.exs", "Elixir"),
        ("flake.nix", "Nix"),
        ("Makefile", "Make"),
    ];
    let base = Path::new(dir);
    for (f, t) in FILES {
        if base.join(f).is_file() {
            return Some(t);
        }
    }
    if base.join(".git").is_dir() {
        return Some("Git");
    }
    None
}

/// What `Canon::canon_dir` learns of path prefixes (see `plain_path`): one
/// per list, whose few milliseconds it holds for.
#[derive(Default)]
pub struct Canon {
    /// prefixes known to be there and not symlinks
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    plain: std::collections::HashSet<String>,
}

impl Canon {
    /// The directory `p` names, spelled one way: what `pwd -P` prints there,
    /// so every spelling of one directory -- a trailing or doubled '/', a path
    /// through a symlink -- comes out the same.  A directory row is hidden
    /// when a session was started in it (or its active window is in it) under
    /// ANY spelling, since Enter on the row resolves it and switches to that
    /// session: tmux keeps `-c ~/repo/` with its slash, and a session started
    /// from a shell in a symlinked directory keeps the logical path, while the
    /// recent list and zoxide have their own spellings.  bash's canon_dir --
    /// keep them in step: runs of '/' collapse and trailing ones go, then the
    /// physical path of a directory that exists, except on a filesystem whose
    /// stat can block (mounts.rs), which keeps its spelling; so does a
    /// relative path.
    pub fn canon_dir(&mut self, p: &str) -> String {
        let mut s = String::with_capacity(p.len());
        for c in p.chars() {
            if c == '/' && s.ends_with('/') {
                continue;
            }
            s.push(c);
        }
        while s.len() > 1 && s.ends_with('/') {
            s.pop();
        }
        if !s.starts_with('/') || crate::mounts::is_remote(&s) || self.plain_path(&s) {
            return s;
        }
        match fs::canonicalize(&s) {
            Ok(r) if r.is_dir() => r.to_str().map(str::to_string).unwrap_or(s),
            _ => s,
        }
    }

    /// Is `s` (absolute, tidied) its own physical path?  It is when every
    /// component is there and none is a symlink, `.` or `..`: realpath then
    /// returns `s` as it is, and canon_dir returns `s` whether or not it names
    /// a directory.  readlink(2) failing with EINVAL says "there, and not a
    /// link" -- the probe realpath makes of every component anyway, here made
    /// once per prefix per list: the rows' directories share most of theirs.
    /// A link, a dot, any other answer: false, and realpath decides as before.
    /// That holds for glibc's realpath (every version) and musl's since 1.2.2,
    /// which Rust's musl targets bundle since 1.71 (rust-version is 1.74); an
    /// older musl asked the kernel, which on a case-insensitive filesystem may
    /// give back a name in another case.  Linux only: macOS's realpath also
    /// respells a name in its case on disk.
    #[cfg(target_os = "linux")]
    fn plain_path(&mut self, s: &str) -> bool {
        let mut end = 0;
        for comp in s[1..].split('/') {
            end += 1 + comp.len();
            if comp.is_empty() || comp == "." || comp == ".." {
                return false;
            }
            let prefix = &s[..end];
            if self.plain.contains(prefix) {
                continue;
            }
            match fs::read_link(prefix) {
                Err(e) if e.kind() == std::io::ErrorKind::InvalidInput => {
                    self.plain.insert(prefix.to_string());
                }
                _ => return false,
            }
        }
        true
    }

    #[cfg(not(target_os = "linux"))]
    fn plain_path(&mut self, _s: &str) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tmp(tag: &str) -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!("imux-dirs-{}-{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn project_type_precedence_matches_bash() {
        let d = tmp("prec");
        fs::write(d.join("Makefile"), "").unwrap();
        assert_eq!(project_type(d.to_str().unwrap()), Some("Make"));
        // Cargo.toml is checked before Makefile
        fs::write(d.join("Cargo.toml"), "").unwrap();
        assert_eq!(project_type(d.to_str().unwrap()), Some("Rust"));
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn a_bare_git_dir_is_the_last_resort() {
        let d = tmp("git");
        fs::create_dir_all(d.join(".git")).unwrap();
        assert_eq!(project_type(d.to_str().unwrap()), Some("Git"));
        fs::remove_dir_all(&d).ok();
    }

    /// A non-UTF-8 line is skipped whole -- never offered under a lossy name
    /// that no directory has -- while its neighbours, a valid non-ASCII name
    /// among them, survive.  '\r' is kept, as bash's `read -r` keeps it.
    #[test]
    fn a_non_utf8_line_is_skipped_not_mangled() {
        let got: Vec<&str> = utf8_lines(b"/a\n/non\xffutf8\n/caf\xc3\xa9\n/cr\r\n").collect();
        assert_eq!(got, vec!["/a", "/caf\u{e9}", "/cr\r", ""]);
        assert!(!got.iter().any(|l| l.contains('\u{fffd}')), "a lossy name leaked: {:?}", got);
    }

    #[test]
    fn an_empty_dir_has_no_type() {
        let d = tmp("empty");
        assert_eq!(project_type(d.to_str().unwrap()), None);
        fs::remove_dir_all(&d).ok();
    }

    /// Every spelling of one directory is one directory: a trailing or doubled
    /// '/', and a path through a symlink, come out as `pwd -P` prints it.  One
    /// that is not there (or not absolute) is only tidied -- as bash's canon_dir.
    #[test]
    fn canon_dir_spells_a_directory_one_way() {
        let d = tmp("canon");
        let real = d.join("real");
        fs::create_dir_all(&real).unwrap();
        std::os::unix::fs::symlink(&real, d.join("link")).unwrap();
        fs::create_dir_all(real.join("sub")).unwrap();
        fs::write(real.join("file"), "").unwrap();
        let phys = fs::canonicalize(&real).unwrap().to_str().unwrap().to_string();
        let base = d.to_str().unwrap();
        // one Canon for them all, as for a list: what it learnt of one
        // spelling's prefixes must not change the answer for the next
        let mut c = Canon::default();
        for spelling in [
            format!("{}/real", base),
            format!("{}/real/", base),
            format!("{}//real//", base),
            format!("{}/link", base),
            format!("{}/link/", base),
            format!("{}/real/../real", base),
            format!("{}/./real", base),
        ] {
            assert_eq!(c.canon_dir(&spelling), phys, "{}", spelling);
        }
        assert_eq!(c.canon_dir(&format!("{}/link/sub", base)), format!("{}/sub", phys));
        assert_eq!(c.canon_dir(&format!("{}/real/sub", base)), format!("{}/sub", phys));
        // not a directory, or not there: tidied only
        assert_eq!(c.canon_dir(&format!("{}/real/file", base)), format!("{}/real/file", base));
        assert_eq!(c.canon_dir(&format!("{}/real/file/x", base)), format!("{}/real/file/x", base));
        assert_eq!(c.canon_dir(&format!("{}//gone//", base)), format!("{}/gone", base));
        assert_eq!(c.canon_dir("rel//x/"), "rel/x");
        assert_eq!(c.canon_dir("//"), "/");
        fs::remove_dir_all(&d).ok();
    }
    #[cfg(unix)]
    #[test]
    fn bounded_zoxide_drains_pipes_and_cleans_up_timeout_overflow_and_drop() {
        fn command(script: &str) -> Command {
            let mut command = Command::new("/bin/sh");
            command.args(["-c", script]);
            command
        }
        fn alive(pid: u32) -> bool {
            extern "C" {
                fn kill(pid: i32, signal: i32) -> i32;
            }
            unsafe { kill(pid as i32, 0) == 0 }
        }
        let output = Zoxide::start(
            command("printf 'valid output'"),
            Instant::now() + Duration::from_secs(1),
            32,
        )
        .unwrap()
        .output()
        .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"valid output");
        for (script, limit) in [
            ("exec sleep 30", 32),
            ("exec yes oversized-output", 32),
            ("sleep 30 & exit 0", 32),
        ] {
            let child = Zoxide::start(
                command(script),
                Instant::now() + Duration::from_millis(40),
                limit,
            )
            .unwrap();
            let pid = child.child.id();
            let started = Instant::now();
            assert!(child.output().is_none());
            assert!(started.elapsed() < Duration::from_secs(1));
            assert!(!alive(pid), "timed out/oversized child was not reaped");
        }
        let child = Zoxide::start(
            command("exec sleep 30"),
            Instant::now() + Duration::from_secs(10),
            32,
        )
        .unwrap();
        let pid = child.child.id();
        drop(child);
        assert!(
            !alive(pid),
            "dropping uncollected enrichment did not kill/reap it"
        );
    }
}
