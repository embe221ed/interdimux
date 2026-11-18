//! Directory candidates for the one-list model, and project-type detection.
//! Mirrors bash `load_recent_dirs` + `detect_project_type`.

use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStderr, ChildStdout, Command, Output, Stdio};
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

fn zoxide_program() -> std::ffi::OsString {
    if let Some(path) = std::env::var_os("INTERDIMUX_ZOXIDE_BIN").filter(|path| !path.is_empty()) {
        return path;
    }
    fn executable(path: &Path) -> bool {
        fs::metadata(path).map_or(false, |metadata| {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
            }
            #[cfg(not(unix))]
            {
                metadata.is_file()
            }
        })
    }
    // Launch Services does not inherit an interactive shell's expanded PATH.
    // Prefer its PATH when present, then the usual local installation paths.
    if let Some(path) = std::env::var_os("PATH") {
        for directory in std::env::split_paths(&path) {
            let candidate = directory.join("zoxide");
            if executable(&candidate) { return candidate.into_os_string(); }
        }
    }
    let mut fallback = Vec::with_capacity(3);
    if let Some(home) = std::env::var_os("HOME").filter(|home| !home.is_empty()) {
        fallback.push(PathBuf::from(home).join(".cargo/bin/zoxide"));
    }
    fallback.extend([PathBuf::from("/opt/homebrew/bin/zoxide"), PathBuf::from("/usr/local/bin/zoxide")]);
    fallback.into_iter().find(|path| executable(path))
        .map(PathBuf::into_os_string).unwrap_or_else(|| "zoxide".into())
}

/// `zoxide query --list`, with `--all` or without.  `--all`: without it zoxide
/// stats EVERY entry in its database to hide the missing ones, so one entry on
/// a stalled mount hangs zoxide itself.  The existence check is ours now
/// (offerable), and a zoxide too old to know the flag gets the plain query.
fn zoxide_query(all: bool) -> Command {
    let mut c = Command::new(zoxide_program());
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

pub(crate) type Zoxide = BoundedCommand;

pub(crate) struct BoundedCommand {
    child: Child,
    stdout: ChildStdout,
    stderr: Option<ChildStderr>,
    deadline: Instant,
    limit: usize,
    finished: bool,
}

impl BoundedCommand {
    fn start(command: Command, deadline: Instant, limit: usize) -> Option<Self> {
        Self::spawn(command, deadline, limit, false, Stdio::null()).ok()
    }

    fn spawn(
        mut command: Command,
        deadline: Instant,
        limit: usize,
        capture_stderr: bool,
        stdin: Stdio,
    ) -> io::Result<Self> {
        if Instant::now() >= deadline {
            return Err(command_timed_out());
        }
        command
            .stdin(stdin)
            .stdout(Stdio::piped())
            .stderr(if capture_stderr { Stdio::piped() } else { Stdio::null() });
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        let mut child = command.spawn()?;
        let stdout = child.stdout.take().expect("child stdout is piped");
        let stderr = child.stderr.take();
        let result = Self {
            child,
            stdout,
            stderr,
            deadline,
            limit,
            finished: false,
        };
        nonblocking(&result.stdout)?;
        if let Some(pipe) = &result.child.stdin {
            nonblocking(pipe)?;
        }
        if let Some(stderr) = &result.stderr {
            nonblocking(stderr)?;
        }
        Ok(result)
    }

    #[cfg(feature = "macos-picker")]
    pub(crate) fn interactive(command: Command, deadline: Instant, limit: usize) -> io::Result<Self> {
        Self::spawn(command, deadline, limit, true, Stdio::piped())
    }

    #[cfg(feature = "macos-picker")]
    pub(crate) fn id(&self) -> u32 {
        self.child.id()
    }

    /// Read a first newline-delimited reply while the command waits for input.
    #[cfg(feature = "macos-picker")]
    pub(crate) fn first_line(&mut self, cancelled: impl Fn() -> bool) -> io::Result<Vec<u8>> {
        let mut line = Vec::new();
        let mut errors = Vec::new();
        let mut eof = false;
        let mut stderr_eof = false;
        loop {
            if cancelled() || Instant::now() >= self.deadline {
                return Err(command_timed_out());
            }
            let offset = line.len();
            let progress = read_command_pipe(&mut self.stdout, &mut line, &mut eof, self.limit)?;
            if line[offset..].contains(&b'\n') {
                return Ok(line);
            }
            if let Some(stderr) = self.stderr.as_mut().filter(|_| !stderr_eof) {
                read_command_pipe(stderr, &mut errors, &mut stderr_eof, self.limit)?;
            }
            if eof {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, String::from_utf8_lossy(&errors).trim().to_owned()));
            }
            if !progress { std::thread::sleep(Duration::from_millis(5)); }
        }
    }

    /// Commit one bounded command line. A closed pipe before the first byte
    /// permits a cold retry. Once any input went through, report the outcome.
    #[cfg(feature = "macos-picker")]
    pub(crate) fn exchange_line(&mut self, line: &[u8], deadline: Instant, cancelled: impl Fn() -> bool) -> Option<io::Result<Vec<u8>>> {
        use std::io::Write;
        self.deadline = deadline;
        let input = self.child.stdin.as_mut()?;
        let mut offset = 0;
        while offset < line.len() {
            if cancelled() || Instant::now() >= deadline {
                return (offset != 0).then(|| Err(command_timed_out()));
            }
            match input.write(&line[offset..]) {
                Ok(0) => return (offset != 0).then(|| Err(io::ErrorKind::WriteZero.into())),
                Ok(n) => offset += n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(5)),
                Err(e) => return (offset != 0).then_some(Err(e)),
            }
        }
        Some(self.first_line(cancelled))
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

    fn output(self) -> Option<Output> {
        self.output_until(|| false).ok()
    }

    fn output_until(mut self, cancelled: impl Fn() -> bool) -> io::Result<Output> {
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let mut status = None;
        let mut stdout_eof = false;
        let mut stderr_eof = self.stderr.is_none();
        loop {
            if cancelled() {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "command cancelled"));
            }
            let remaining = self.deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(command_timed_out());
            }
            let mut progress = false;
            if !stdout_eof {
                progress |= read_command_pipe(&mut self.stdout, &mut stdout, &mut stdout_eof, self.limit)?;
            }
            if let Some(pipe) = self.stderr.as_mut().filter(|_| !stderr_eof) {
                progress |= read_command_pipe(pipe, &mut stderr, &mut stderr_eof, self.limit)?;
            }
            if status.is_none() {
                status = self.child.try_wait()?;
            }
            if let Some(status) = status.filter(|_| stdout_eof && stderr_eof) {
                self.finished = true;
                return Ok(Output { status, stdout, stderr });
            }
            if !progress {
                std::thread::sleep(remaining.min(Duration::from_millis(5)));
            }
        }
    }
}

fn command_timed_out() -> io::Error {
    io::Error::new(io::ErrorKind::TimedOut, "command timed out")
}

fn read_command_pipe(
    pipe: &mut impl Read,
    output: &mut Vec<u8>,
    eof: &mut bool,
    limit: usize,
) -> io::Result<bool> {
    let mut chunk = [0; 8192];
    match pipe.read(&mut chunk) {
        Ok(0) => *eof = true,
        Ok(n) => {
            if n > limit.saturating_sub(output.len()) {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "command output exceeded its limit"));
            }
            output.extend_from_slice(&chunk[..n]);
            return Ok(true);
        }
        Err(error) if matches!(error.kind(), io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock) => {}
        Err(error) => return Err(error),
    }
    Ok(false)
}

#[cfg(feature = "macos-picker")]
pub(crate) fn bounded_command_output(
    command: Command,
    timeout: Duration,
    limit: usize,
    cancelled: impl Fn() -> bool,
) -> io::Result<Output> {
    BoundedCommand::spawn(command, Instant::now() + timeout, limit, true, Stdio::null())?
        .output_until(cancelled)
}

impl Drop for BoundedCommand {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(unix)]
fn nonblocking(pipe: &impl std::os::fd::AsRawFd) -> io::Result<()> {
    extern "C" {
        fn fcntl(fd: i32, command: i32, ...) -> i32;
    }
    #[cfg(target_os = "linux")]
    const NONBLOCK: i32 = 0x800;
    #[cfg(not(target_os = "linux"))]
    const NONBLOCK: i32 = 0x4;
    let fd = pipe.as_raw_fd();
    let flags = unsafe { fcntl(fd, 3) };
    if flags < 0 || unsafe { fcntl(fd, 4, flags | NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(unix))]
fn nonblocking<T>(_: &T) -> io::Result<()> {
    // Do not use an unbounded pipe on an unsupported host.
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "nonblocking pipe unavailable",
    ))
}

pub(crate) fn zoxide(args: &[&str]) -> Option<Output> {
    let mut command = Command::new(zoxide_program());
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

/// Full lexical inventory for lazy background enrichment. Unlike discovery's
/// candidates(), this never stats individual database entries or applies a
/// suggestion count limit. Existence is checked only on explicit activation.
pub(crate) fn zoxide_inventory() -> Vec<String> {
    let Some(output) = start_zoxide().and_then(listed_zoxide) else { return Vec::new(); };
    lexical_paths(&output.stdout)
}

fn lexical_paths(bytes: &[u8]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    utf8_lines(bytes).filter_map(|path| {
        let path = if path == "/" { path } else { path.trim_end_matches('/') };
        (Path::new(path).is_absolute() && !path.chars().any(char::is_control)
            && seen.insert(path.to_owned())).then(|| path.to_owned())
    }).collect()
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
    fn lexical_inventory_keeps_late_and_missing_paths_without_probing() {
        let mut bytes = (0..40).map(|i| format!("/not-created/zoxide-project-{i:02}\n"))
            .collect::<String>().into_bytes();
        bytes.extend_from_slice(b"/not-created/zoxide-project-39/\nrelative/path\n/control\tpath\n/invalid-\xff\n/\n");
        bytes.extend_from_slice("/not-created/café-東京\n".as_bytes());
        let paths = lexical_paths(&bytes);
        assert_eq!(paths.len(), 42);
        assert_eq!(paths[39], "/not-created/zoxide-project-39");
        assert_eq!(&paths[40..], ["/", "/not-created/café-東京"]);
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
