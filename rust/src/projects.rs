//! Shared directory discovery and safe find-or-create query normalization.
//! Filesystem discovery only runs on an explicit directory-picker action, never a query
//! keystroke. The ordinary list is shallow; Ctrl-f opts into a bounded walk.

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::model::{Session, Snapshot, Target};

#[derive(Debug, Clone)]
pub(crate) struct Directory {
    pub path: String,
    pub label: String,
    pub project: Option<&'static str>,
    pub existing_session: Option<Target>,
}

#[derive(Debug, Clone)]
pub(crate) struct CreateTarget {
    pub name: String,
    pub cwd: String,
    pub existing_session: Option<Target>,
    pub path_query: bool,
}

fn home() -> String {
    std::env::var("HOME").unwrap_or_default()
}

fn expand_home(value: &str, home: &str) -> String {
    if value == "~" {
        home.into()
    } else if let Some(rest) = value.strip_prefix("~/") {
        format!("{home}/{rest}")
    } else {
        value.into()
    }
}

pub(crate) fn words(query: &str) -> Result<String, String> {
    if query.chars().any(|c| c.is_control()) {
        return Err("A session query cannot contain control characters".into());
    }
    let mut terms = Vec::new();
    let mut term = String::new();
    let mut chars = query.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' if chars.peek() == Some(&' ') => {
                chars.next();
                term.push(' ');
            }
            ' ' => terms.push(std::mem::take(&mut term)),
            c => term.push(c),
        }
    }
    terms.push(term);
    let mut result = Vec::new();
    for term in terms {
        if term == "|" {
            return Err("An OR expression is a filter, not a session name".into());
        }
        let bare = term.trim_start_matches(['\'', '^', '!']);
        let leading = &term[..term.len() - bare.len()];
        let bare = bare.strip_suffix('$').unwrap_or(bare);
        let bare = if leading.contains('\'') {
            bare.strip_suffix('\'').unwrap_or(bare)
        } else {
            bare
        };
        if !bare.is_empty() {
            result.push(bare.to_owned());
        }
    }
    let result = result.join(" ");
    if result.is_empty() {
        Err("Type a session name or directory".into())
    } else {
        Ok(result)
    }
}

fn name(value: &str) -> Result<String, String> {
    let name: String = value
        .chars()
        .map(|c| {
            if matches!(c, '.' | ':' | ' ' | '/') {
                '-'
            } else {
                c
            }
        })
        .collect();
    if name.is_empty() || name.len() > 160 {
        Err("The session name is empty or too long".into())
    } else {
        Ok(name)
    }
}

#[cfg(test)]
thread_local! { static DIRECTORY_PROBES: std::cell::Cell<usize> = const { std::cell::Cell::new(0) }; }

fn physical_directory(value: &str) -> Result<String, &'static str> {
    if value.chars().any(char::is_control) || excluded_network(value) {
        return Err("Choose an existing local directory");
    }
    #[cfg(test)]
    DIRECTORY_PROBES.set(DIRECTORY_PROBES.get() + 1);
    let path = fs::canonicalize(value)
        .map_err(|_| "This directory no longer exists; reload projects")?;
    let text = path.to_str().ok_or("The directory path is not valid Unicode")?;
    if text.chars().any(char::is_control) || excluded_network(text) || !path.is_dir() {
        return Err("Choose an existing local directory");
    }
    Ok(text.to_owned())
}

/// Rows carry literal absolute paths. A vanished row cannot fall back to a
/// name, a zoxide match, or HOME.
pub(crate) fn exact_path(path: &str) -> Result<String, String> {
    if !Path::new(path).is_absolute() {
        return Err("Choose an existing local directory".into());
    }
    physical_directory(path).map_err(str::to_owned)
}

fn normalized_with(
    query: &str,
    home: &str,
    resolve_zoxide: impl FnOnce(&str) -> Option<String>,
) -> Result<CreateTarget, String> {
    let query = words(query)?;
    let expanded = expand_home(&query, home);
    if let Ok(path) = physical_directory(&expanded) {
        return CreateTarget::directory(path);
    }
    let cwd = resolve_zoxide(&query)
        .and_then(|path| physical_directory(&path).ok())
        .unwrap_or_else(|| home.to_owned());
    Ok(CreateTarget {
        name: name(&query)?,
        cwd,
        existing_session: None,
        path_query: false,
    })
}

/// On explicit creation, remove fzf operators per term, resolve a real path,
/// then zoxide, then HOME. Query text is always argv/data, never shell code.
pub(crate) fn normalize_query(query: &str) -> Result<CreateTarget, String> {
    normalized_with(query, &home(), |query| {
        if crate::env_text("INTERDIMUX_USE_ZOXIDE") == "off" {
            return None;
        }
        let output = crate::dirs::zoxide(&["query", "--", query])?;
        if !output.status.success() {
            return None;
        }
        std::str::from_utf8(&output.stdout)
            .ok()?
            .split('\n')
            .next()
            .filter(|line| !line.is_empty())
            .map(str::to_owned)
    })
}

fn directory_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("root")
        .replace(['.', ':'], "-")
}

fn local_rex_sessions(snapshot: &Snapshot) -> HashSet<&str> {
    if snapshot.pane_metadata.is_empty() {
        return HashSet::new();
    }
    snapshot
        .panes
        .iter()
        .filter(|pane| {
            snapshot
                .pane_metadata
                .get(&pane.key)
                .is_some_and(|meta| meta.local)
        })
        .map(|pane| pane.session_key.as_str())
        .collect()
}

fn is_local(session: &Session, local_rex: &HashSet<&str>) -> bool {
    matches!(
        session.target,
        Target::TmuxNative { .. } | Target::TmuxLegacy { .. }
    ) || local_rex.contains(session.key.as_str())
}

// A renamed session still owns its start directory. Prefer the basename when
// multiple sessions began there, then the lexicographically smallest label.
fn preferred_start(candidate: &Session, previous: &Session, path: &str) -> bool {
    let base = directory_name(path);
    (candidate.name != base, &candidate.name) < (previous.name != base, &previous.name)
}

struct NamedSession<'a> {
    session: &'a Session,
    // Only local sessions with an active window can match through its cwd.
    active_cwd: Option<&'a str>,
}

// Exists only during one explicit project action. Resolve each distinct
// session path once, and only look up an active cwd on a name collision.
struct DirectorySessions<'a> {
    starts: HashMap<String, &'a Session>,
    names: HashMap<&'a str, NamedSession<'a>>,
    physical: HashMap<&'a str, String>,
}

impl<'a> DirectorySessions<'a> {
    fn new(snapshot: &'a Snapshot) -> Self {
        let local = local_rex_sessions(snapshot);
        let mut active = HashMap::new();
        for window in snapshot.windows.iter().filter(|window| window.active) {
            active
                .entry(window.session_key.as_str())
                .or_insert(window.path.as_str());
        }
        let mut index = Self {
            starts: HashMap::new(),
            names: HashMap::new(),
            physical: HashMap::new(),
        };
        for session in &snapshot.sessions {
            let active_cwd = if is_local(session, &local) {
                if !session.path.is_empty() {
                    let start = index
                        .physical
                        .entry(session.path.as_str())
                        .or_insert_with(|| canonical(&session.path));
                    index
                        .starts
                        .entry(start.clone())
                        .and_modify(|previous| {
                            if preferred_start(session, previous, start) {
                                *previous = session;
                            }
                        })
                        .or_insert(session);
                }
                active.get(session.key.as_str()).copied()
            } else {
                None
            };
            index.names.entry(&session.name).or_insert(NamedSession {
                session,
                active_cwd,
            });
        }
        index
    }

    fn identity(&mut self, path: &str) -> (String, Option<Target>) {
        if let Some(session) = self.starts.get(path) {
            return (session.name.clone(), Some(session.target.clone()));
        }
        let base = directory_name(path);
        let mut name = base.clone();
        let mut ordinal = 1;
        while let Some(named) = self.names.get(name.as_str()) {
            if let Some(active) = named.active_cwd.filter(|s| !s.is_empty()) {
                self.physical
                    .entry(active)
                    .or_insert_with(|| canonical(active));
                let cwd = self.physical[active].as_str();
                let start = self
                    .physical
                    .get(named.session.path.as_str())
                    .map_or("", String::as_str);
                let below = |child: &str, parent: &str| {
                    !parent.is_empty() && child != parent && Path::new(child).starts_with(parent)
                };
                let same_branch =
                    !start.is_empty() && (start == "/" || below(path, start) || below(start, path));
                if cwd == path || (below(cwd, path) && same_branch) {
                    return (name, Some(named.session.target.clone()));
                }
            }
            name = if ordinal == 1 {
                let parent = Path::new(path)
                    .parent()
                    .map(|p| directory_name(&p.to_string_lossy()))
                    .unwrap_or_else(|| "root".into());
                format!("{parent}-{base}")
            } else {
                format!("{base}-{ordinal}")
            };
            ordinal += 1;
        }
        (name, None)
    }
}

impl CreateTarget {
    fn directory(cwd: String) -> Result<Self, String> {
        let basename = Path::new(&cwd)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("root");
        Ok(Self {
            name: name(basename)?,
            cwd,
            existing_session: None,
            path_query: true,
        })
    }

    pub(crate) fn window_in(mut self, origin: &str) -> (String, String) {
        if !self.path_query && self.cwd == home() && !origin.is_empty() {
            self.cwd = origin.to_owned();
        }
        (self.name, self.cwd)
    }

    fn with_session(mut self, snapshot: &Snapshot) -> Self {
        if self.path_query {
            (self.name, self.existing_session) = DirectorySessions::new(snapshot).identity(&self.cwd);
        } else {
            self.existing_session = snapshot.sessions.iter()
                .find(|s| s.name == self.name)
                .map(|s| s.target.clone());
        }
        self
    }
}

pub(crate) fn resolve(snapshot: &Snapshot, query: &str) -> Result<CreateTarget, String> {
    Ok(normalize_query(query)?.with_session(snapshot))
}

/// Directory-only commands accept typed fzf syntax but never fall back to a
/// session name or zoxide if the directory has vanished.
pub(crate) fn resolve_directory_query(snapshot: &Snapshot, query: &str) -> Result<CreateTarget, String> {
    let path = words(query).ok()
        .and_then(|query| physical_directory(&expand_home(&query, &home())).ok())
        .ok_or_else(|| format!("The directory does not exist: {query:?}"))?;
    Ok(CreateTarget::directory(path)?.with_session(snapshot))
}

pub(crate) fn resolve_directory(snapshot: &Snapshot, path: &str) -> Result<CreateTarget, String> {
    Ok(CreateTarget::directory(exact_path(path)?)?.with_session(snapshot))
}

fn recent_file() -> PathBuf {
    let data = match crate::env_text("XDG_DATA_HOME") {
        value if !value.is_empty() => PathBuf::from(value),
        _ => Path::new(&home()).join(".local/share"),
    };
    data.join("interdimux/recent_dirs")
}

// This is our own small history file. Reading it starts no finder, zoxide or
// mount process and probes no candidate directory, so it is safe on first paint.
pub(crate) fn recent_text(path: &Path) -> Option<String> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        #[cfg(target_os = "linux")]
        options.custom_flags(0x800);
        #[cfg(not(target_os = "linux"))]
        options.custom_flags(0x4);
    }
    let mut file = options.open(path).ok()?;
    if !file.metadata().ok()?.is_file() {
        return None;
    }
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take(1_048_577)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() > 1_048_576 {
        return None;
    }
    Some(
        bytes
            .split(|b| *b == b'\n')
            .filter_map(|line| std::str::from_utf8(line).ok())
            .collect::<Vec<_>>()
            .join("\n"),
    )
}

fn remember(path: &str, home: &str, file: &Path) {
    if path.is_empty() || path == home || path.chars().any(char::is_control) {
        return;
    }
    let Some(parent) = file.parent() else {
        return;
    };
    if fs::create_dir_all(parent).is_err() {
        return;
    }
    let mut entries = vec![path.to_owned()];
    let mut seen = HashSet::from([path.to_owned()]);
    for old in recent_text(file).unwrap_or_default().split('\n') {
        if entries.len() >= 51 {
            break;
        }
        if old.is_empty() || old.chars().any(char::is_control) || !seen.insert(old.to_owned()) {
            continue;
        }
        entries.push(old.to_owned());
    }
    static NEXT_HISTORY: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let serial = NEXT_HISTORY.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let temporary = parent.join(format!(".recent_dirs-{}-{serial}.tmp", std::process::id()));
    let written = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .and_then(|mut out| out.write_all(format!("{}\n", entries.join("\n")).as_bytes()));
    if written.is_err() || fs::rename(&temporary, file).is_err() {
        let _ = fs::remove_file(temporary);
    }
}

/// Best-effort bookkeeping after a successful explicit project action. A
/// failure to remember or teach zoxide never costs the switch/create itself.
pub(crate) fn record_use(path: &str) {
    let home = home();
    if path.is_empty() || path == home || path.chars().any(char::is_control) {
        return;
    }
    remember(path, &home, &recent_file());
    if crate::env_text("INTERDIMUX_USE_ZOXIDE") != "off" && !excluded_network(path) {
        let _ = crate::dirs::zoxide(&["add", "--", path]);
    }
}

/// Warm history suggestions for the ordinary one-list picker. This function
/// performs no directory scans, candidate stats, canonicalization or processes.
pub(crate) fn cached_directories(snapshot: &Snapshot) -> Vec<Directory> {
    if crate::env_text("INTERDIMUX_SHOW_DIRS") == "off" {
        return Vec::new();
    }
    cached_with(
        snapshot,
        recent_text(&recent_file()).unwrap_or_default().split('\n'),
        usize::MAX,
    )
}

/// Optional lazy inventory: only the worker calls this bounded process path.
/// Candidate paths remain lexical, including entries that have disappeared.
pub(crate) fn zoxide_inventory() -> Vec<String> {
    if crate::env_text("INTERDIMUX_SHOW_DIRS") == "off" {
        return Vec::new();
    }
    crate::dirs::zoxide_inventory()
}

/// Turn an already loaded inventory into matcher rows without filesystem work.
pub(crate) fn cached_paths(snapshot: &Snapshot, paths: &[String]) -> Vec<Directory> {
    if crate::env_text("INTERDIMUX_SHOW_DIRS") == "off" {
        return Vec::new();
    }
    cached_with(snapshot, paths.iter().map(String::as_str), usize::MAX)
}

/// This limits blank-query suggestions, never the retained search inventory.
pub(crate) fn suggestion_limit() -> usize {
    crate::env_text("INTERDIMUX_DIRS_LIMIT")
        .parse::<usize>()
        .unwrap_or(15)
        .min(1000)
}

fn cached_with<'a>(
    snapshot: &Snapshot,
    paths: impl Iterator<Item = &'a str>,
    limit: usize,
) -> Vec<Directory> {
    // Keep input order for recency, and only index identities for requested
    // paths. This stays lexical even if the filesystem is slow or offline.
    let mut matches: HashMap<&str, Option<&Session>> = HashMap::new();
    let mut ordered = Vec::new();
    for raw in paths {
        if ordered.len() == limit {
            break;
        }
        let path = if raw == "/" {
            raw
        } else {
            raw.trim_end_matches('/')
        };
        if Path::new(path).is_absolute()
            && !path.chars().any(char::is_control)
            && matches.insert(path, None).is_none()
        {
            ordered.push(path);
        }
    }
    if ordered.is_empty() {
        return Vec::new();
    }
    let mut local = None;
    for session in &snapshot.sessions {
        if session.path.is_empty() {
            continue;
        }
        let trimmed = session.path.trim_end_matches('/');
        let path = if trimmed.is_empty() { "/" } else { trimmed };
        if let Some(best) = matches.get_mut(path) {
            if is_local(
                session,
                local.get_or_insert_with(|| local_rex_sessions(snapshot)),
            ) && best.map_or(true, |previous| preferred_start(session, previous, path))
            {
                *best = Some(session);
            }
        }
    }
    ordered
        .into_iter()
        .map(|path| Directory {
            path: path.into(),
            label: Path::new(path)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or(path)
                .into(),
            project: None,
            existing_session: matches[path].map(|session| session.target.clone()),
        })
        .collect()
}

struct ScanConfig {
    roots: Vec<PathBuf>,
    depth: usize,
    limit: usize,
    budget: Duration,
    home: String,
    markers: Vec<String>,
}

impl ScanConfig {
    fn from_env() -> Self {
        let home = home();
        let configured = crate::env_text("INTERDIMUX_PROJECT_DIRS");
        let roots = if configured.is_empty() {
            let roots: Vec<_> = ["projects", "code", "src", "repos", "work", "dev"]
                .iter()
                .map(|part| Path::new(&home).join(part))
                .filter(|path| !excluded_network(&path.to_string_lossy()) && path.is_dir())
                .collect();
            if roots.is_empty() {
                vec![PathBuf::from(&home)]
            } else {
                roots
            }
        } else {
            configured
                .split(':')
                .filter(|part| !part.is_empty())
                .map(|part| PathBuf::from(expand_home(part, &home)))
                .collect()
        };
        let depth = crate::env_text("INTERDIMUX_SCAN_DEPTH")
            .parse::<usize>()
            .unwrap_or(3)
            .clamp(1, 10);
        Self {
            roots,
            depth,
            limit: 20_000,
            budget: Duration::from_millis(150),
            home,
            markers: project_markers(&crate::env_text("INTERDIMUX_PROJECT_MARKERS")),
        }
    }
}

pub(crate) fn excluded_network(path: &str) -> bool {
    // macOS has no /proc mount table. Avoid its network/automount namespaces;
    // configured ordinary local roots remain useful on both platforms.
    path.starts_with("//")
        || ["/Network", "/net"]
            .iter()
            .any(|prefix| path == *prefix || path.starts_with(&format!("{prefix}/")))
        || crate::mounts::is_remote(path)
        || native_network(path)
}

#[cfg(any(target_os = "macos", test))]
fn macos_mounts(text: &str) -> Vec<(String, bool)> {
    text.lines()
        .filter_map(|line| {
            let (head, options) = line.rsplit_once(" (")?;
            let (_, point) = head.split_once(" on ")?;
            let filesystem = options.trim_end_matches(')').split(',').next()?.trim();
            let remote = matches!(
                filesystem,
                "nfs" | "smbfs" | "webdav" | "autofs" | "osxfuse" | "macfuse" | "fusefs"
            ) || filesystem.starts_with("fuse.");
            Some((point.to_owned(), remote))
        })
        .collect()
}

#[cfg(any(target_os = "macos", test))]
fn mount_is_remote(mounts: &[(String, bool)], path: &str) -> bool {
    mounts
        .iter()
        .filter(|(point, _)| Path::new(path).starts_with(point))
        .max_by_key(|(point, _)| point.len())
        .map_or(false, |(_, remote)| *remote)
}

#[cfg(target_os = "macos")]
fn native_network(path: &str) -> bool {
    static MOUNTS: std::sync::OnceLock<Vec<(String, bool)>> = std::sync::OnceLock::new();
    let home = home();
    if !home.is_empty() && home != "/" && Path::new(path).starts_with(&home) {
        return false;
    }
    mount_is_remote(
        MOUNTS.get_or_init(|| {
            Command::new("/sbin/mount")
                .stdin(Stdio::null())
                .stderr(Stdio::null())
                .output()
                .ok()
                .filter(|output| output.status.success())
                .map(|output| macos_mounts(&String::from_utf8_lossy(&output.stdout)))
                .unwrap_or_default()
        }),
        path,
    )
}

#[cfg(not(target_os = "macos"))]
fn native_network(_: &str) -> bool {
    false
}

fn project_markers(extra: &str) -> Vec<String> {
    let mut markers: Vec<String> = [
        ".git",
        "Makefile",
        "package.json",
        "Cargo.toml",
        "go.mod",
        "pyproject.toml",
        "CMakeLists.txt",
        ".hg",
        ".svn",
        "build.gradle",
        "pom.xml",
        "mix.exs",
        "flake.nix",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect();
    for marker in extra.split(':') {
        if marker
            .split('/')
            .any(|part| !matches!(part, "" | "." | ".."))
            && !marker.chars().any(char::is_control)
            && !markers.iter().any(|m| m == marker)
        {
            markers.push(marker.to_owned());
        }
    }
    markers
}

fn project_type(path: &str, markers: &[String]) -> Option<&'static str> {
    if excluded_network(path) {
        return None;
    }
    if let Some(kind) = crate::dirs::project_type(path) {
        return Some(kind);
    }
    let base = Path::new(path);
    if base.join(".git").is_file() {
        return Some("Git");
    }
    markers
        .iter()
        .any(|marker| base.join(marker.trim_start_matches('/')).exists())
        .then_some("Project")
}

fn excluded_name(name: &str) -> bool {
    name.starts_with('.') || matches!(name, "node_modules" | "vendor" | "target" | "__pycache__")
}

/// The operation budget bounds local work, not a stalled filesystem syscall;
/// known network mounts are excluded before any such syscall is attempted.
fn walk(roots: &[PathBuf], depth: usize, config: &ScanConfig, include_roots: bool) -> Vec<String> {
    let started = Instant::now();
    let mut queue: VecDeque<_> = roots.iter().cloned().map(|path| (path, 0usize)).collect();
    let mut result = Vec::new();
    let mut seen = HashSet::new();
    let mut visited = 0;
    while let Some((path, level)) = queue.pop_front() {
        if visited >= config.limit || started.elapsed() >= config.budget {
            break;
        }
        let Some(text) = path.to_str() else {
            continue;
        };
        if text.is_empty() || excluded_network(text) || !seen.insert(path.clone()) {
            continue;
        }
        if level == 0 && include_roots && path.is_dir() {
            result.push(text.to_owned());
        }
        if level >= depth {
            continue;
        }
        let Ok(entries) = fs::read_dir(&path) else {
            continue;
        };
        let mut children = Vec::new();
        for entry in entries {
            visited += 1;
            if visited > config.limit || started.elapsed() >= config.budget {
                break;
            }
            let Ok(entry) = entry else {
                continue;
            };
            let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                continue;
            };
            if excluded_name(&name) || (name == "Library" && path == Path::new(&config.home)) {
                continue;
            }
            // file_type does not follow symlinks: no cycles or accidental
            // descent into a linked network mount or unrelated directory.
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if !kind.is_dir() || kind.is_symlink() {
                continue;
            }
            let child = entry.path();
            let Some(text) = child.to_str() else {
                continue;
            };
            if excluded_network(text) {
                continue;
            }
            children.push(child);
        }
        children.sort();
        for child in children {
            result.push(child.to_string_lossy().into_owned());
            queue.push_back((child, level + 1));
        }
    }
    result
}

fn canonical(path: &str) -> String {
    if excluded_network(path) {
        return path.trim_end_matches('/').to_owned();
    }
    physical_directory(path).unwrap_or_else(|_| path.trim_end_matches('/').to_owned())
}

fn discover(
    snapshot: &Snapshot,
    config: &ScanConfig,
    base: Option<&str>,
    query: Option<&str>,
    recent: Vec<String>,
) -> Vec<Directory> {
    let mut paths = Vec::new();
    if let Some(base) = base {
        let base = PathBuf::from(expand_home(base, &config.home));
        let depth = match query {
            None => 1,
            Some("") => 2.min(config.depth),
            Some(_) => config.depth.saturating_mul(2).min(10),
        };
        paths.extend(walk(&[base], depth, config, true));
        if let Some(query) = query.filter(|query| !query.is_empty()) {
            let query = expand_home(query, &config.home).to_lowercase();
            paths.retain(|path| path.to_lowercase().contains(&query));
        }
    } else {
        let deep = query.is_some();
        let query = query.unwrap_or("");
        let expanded = expand_home(query, &config.home);
        let mut roots = config.roots.clone();
        if deep && !query.is_empty() {
            let direct = if Path::new(&expanded).is_absolute() {
                PathBuf::from(&expanded)
            } else {
                Path::new(&config.home).join(&expanded)
            };
            if !excluded_network(&direct.to_string_lossy()) && direct.is_dir() {
                roots.insert(0, direct);
            }
        }
        let depth = if !deep {
            1
        } else if query.is_empty() {
            2.min(config.depth)
        } else {
            config.depth.saturating_mul(2).min(10)
        };
        paths.extend(walk(&roots, depth, config, deep));
        if deep && !query.is_empty() {
            let query = expanded.to_lowercase();
            paths.retain(|path| {
                path.to_lowercase().contains(&query)
                    || Path::new(path)
                        .file_name()
                        .and_then(|s| s.to_str())
                        .map_or(false, |name| name.to_lowercase().contains(&query))
            });
        }
    }
    // Retained history is a lexical cache, separate from bounded filesystem
    // discovery. Neither the scan limit nor metadata budget may discard a late
    // history/zoxide name before the frontend's own fuzzy matcher sees it.
    let mut result = if base.is_none() {
        cached_with(snapshot, recent.iter().map(String::as_str), usize::MAX)
    } else {
        Vec::new()
    };
    let mut seen: std::collections::HashMap<String, usize> = result
        .iter()
        .enumerate()
        .map(|(index, entry)| (entry.path.clone(), index))
        .collect();
    let started = Instant::now();
    let mut sessions = None;
    for (scanned, path) in paths.into_iter().enumerate() {
        if scanned >= config.limit || started.elapsed() >= config.budget {
            break;
        }
        if path.chars().any(|c| c.is_control()) {
            continue;
        }
        let retained_index = seen.get(path.trim_end_matches('/')).copied();
        let path = canonical(&path);
        if path.is_empty() {
            continue;
        }
        let project = if excluded_network(&path) {
            None
        } else {
            project_type(&path, &config.markers)
        };
        let existing_session = sessions.get_or_insert_with(|| DirectorySessions::new(snapshot)).identity(&path).1;
        if let Some(index) = retained_index.or_else(|| seen.get(&path).copied()) {
            result[index].project = project;
            result[index].path = path.clone();
            seen.insert(path.clone(), index);
            result[index].existing_session = existing_session;
            continue;
        }
        let label = Path::new(&path)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(&path)
            .to_owned();
        seen.insert(path.clone(), result.len());
        result.push(Directory {
            existing_session,
            path,
            label,
            project,
        });
    }
    // Stable sort preserves recent/zoxide rank within each project tier.
    if base.is_some() || query.is_some() {
        result.sort_by_key(|entry| entry.project.is_none());
    }
    result
}

/// base selects browsing; query selects an explicit deep search; neither gives
/// recent/zoxide entries plus shallow project roots. fzf filters the result in
/// memory until another explicit directory action requests a fresh snapshot.
pub(crate) fn directories(
    snapshot: &Snapshot,
    base: Option<&str>,
    query: Option<&str>,
) -> Vec<Directory> {
    let config = ScanConfig::from_env();
    let recent = if base.is_none() {
        crate::dirs::retained_candidates(crate::dirs::start_zoxide())
    } else {
        Vec::new()
    };
    discover(snapshot, &config, base, query, recent)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(1);

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let stamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let next = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "imux-projects-{}-{stamp}-{next}",
                std::process::id()
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn dir(&self, path: &str) -> String {
            let path = self.0.join(path);
            fs::create_dir_all(&path).unwrap();
            path.to_str().unwrap().into()
        }
        fn config(&self) -> ScanConfig {
            ScanConfig {
                roots: vec![self.0.clone()],
                depth: 3,
                limit: 200,
                budget: Duration::from_secs(1),
                home: self.0.to_str().unwrap().into(),
                markers: project_markers(""),
            }
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn strips_fzf_operators_per_term_and_preserves_escaped_spaces() {
        for (query, expected) in [
            ("'docs", "docs"),
            ("^docs", "docs"),
            ("docs$", "docs"),
            ("!docs", "docs"),
            ("'docs'", "docs"),
            ("^one !two$", "one two"),
            (" my\\ project ", "my project"),
            ("foo |bar", "foo |bar"),
        ] {
            assert_eq!(words(query).unwrap(), expected, "{query}");
        }
        for query in ["", "   ", "' ^ !$", "foo | bar", "one\ntwo"] {
            assert!(words(query).is_err(), "{query}");
        }
    }

    #[test]
    fn normalization_uses_physical_paths_and_data_not_shell_evaluation() {
        let fixture = Fixture::new();
        let dir = fixture.dir("my project");
        let result = normalized_with("~/my\\ project", fixture.0.to_str().unwrap(), |_| {
            panic!("existing path must not query zoxide")
        })
        .unwrap();
        assert_eq!(
            (result.name, result.cwd),
            (
                "my-project".into(),
                fs::canonicalize(&dir).unwrap().to_str().unwrap().into()
            )
        );
        let escaped = dir.replace(' ', "\\ ");
        assert_eq!(
            resolve_directory_query(&Snapshot::default(), &format!("^{escaped}$")).unwrap().cwd,
            canonical(&dir)
        );
        assert_eq!(
            resolve_directory_query(&Snapshot::default(), &format!("'{escaped}'")).unwrap().cwd,
            canonical(&dir)
        );
        let result = normalized_with("^api.v2$ !server:prod", "/home/test", |_| None).unwrap();
        assert_eq!(result.name, "api-v2-server-prod");
        assert_eq!(result.cwd, "/home/test");
        assert!(!result.path_query);
        let marker = fixture.0.join("must-not-exist");
        let query = format!("$(touch {})", marker.display());
        assert!(normalized_with(&query, "/home/test", |_| None).is_ok());
        assert!(!marker.exists());
    }

    #[test]
    fn project_actions_probe_each_input_once_and_recheck_the_next_selection() {
        let fixture = Fixture::new();
        let path = fixture.dir("my project$");
        let snapshot = Snapshot::default();
        let original = canonical(&path);
        let escaped = format!("'{}'", path.replace(' ', "\\ "));

        let actions = [
            (resolve_directory as fn(&Snapshot, &str) -> _, &path),
            (resolve_directory_query, &escaped),
            (resolve, &escaped),
        ];
        for (select, query) in actions {
            DIRECTORY_PROBES.set(0);
            assert_eq!(select(&snapshot, query).unwrap().cwd, original);
            assert_eq!(DIRECTORY_PROBES.get(), 1);
        }
        DIRECTORY_PROBES.set(0);
        let (tab, cwd) = normalize_query(&escaped).unwrap().window_in("/origin");
        assert_eq!((tab.as_str(), cwd.as_str()), ("my-project$", original.as_str()));
        assert_eq!(DIRECTORY_PROBES.get(), 1);

        DIRECTORY_PROBES.set(0);
        let matched = normalized_with("short", "/home/test", |_| Some(path.clone())).unwrap();
        assert!(!matched.path_query);
        assert_eq!(matched.window_in("/origin"), ("short".into(), original));
        assert_eq!(DIRECTORY_PROBES.get(), 2, "typed name and zoxide result are distinct paths");

        fs::remove_dir(&path).unwrap();
        assert!(resolve_directory(&snapshot, &path).is_err());
        assert!(resolve_directory_query(&snapshot, &escaped).is_err());
        assert!(resolve_directory(&snapshot, &fixture.dir(&"x".repeat(160))).is_ok());
        let long = fixture.dir(&"x".repeat(161));
        assert!(resolve_directory(&snapshot, &long).is_err());
        assert!(resolve(&snapshot, &long).is_err());
    }

    #[test]
    fn zoxide_changes_cwd_but_not_a_nonpath_query_name() {
        let fixture = Fixture::new();
        let path = fixture.dir("actual-project");
        let result = normalized_with("short", "/home/test", |query| {
            assert_eq!(query, "short");
            Some(path.clone())
        })
        .unwrap();
        assert_eq!(result.name, "short");
        assert_eq!(result.cwd, canonical(&path));
        assert!(!result.path_query);
    }

    #[test]
    fn default_is_shallow_deep_search_reaches_nested_projects_and_prunes_noise() {
        let fixture = Fixture::new();
        fixture.dir("team/api");
        fs::write(fixture.0.join("team/api/Cargo.toml"), "").unwrap();
        fixture.dir("Library/hidden-project");
        fixture.dir("node_modules/hidden-project");
        fixture.dir(".git/hidden-project");
        let shallow = discover(
            &Snapshot::default(),
            &fixture.config(),
            None,
            None,
            Vec::new(),
        );
        assert_eq!(
            shallow.iter().map(|d| d.label.as_str()).collect::<Vec<_>>(),
            ["team"]
        );
        let deep = discover(
            &Snapshot::default(),
            &fixture.config(),
            None,
            Some("api"),
            Vec::new(),
        );
        assert_eq!(deep.len(), 1);
        assert_eq!(deep[0].label, "api");
        assert_eq!(deep[0].project, Some("Rust"));
        let browsed = discover(
            &Snapshot::default(),
            &fixture.config(),
            Some(fixture.0.join("team").to_str().unwrap()),
            Some("api"),
            Vec::new(),
        );
        assert_eq!(browsed.len(), 1);
        assert_eq!(browsed[0].label, "api");
        assert!(discover(
            &Snapshot::default(),
            &fixture.config(),
            None,
            Some("hidden-project"),
            Vec::new()
        )
        .is_empty());
    }

    #[test]
    fn browse_and_budget_are_bounded_and_symlinks_do_not_escape() {
        let fixture = Fixture::new();
        fixture.dir("a/sub");
        fixture.dir("b/sub");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&fixture.0, fixture.0.join("cycle")).unwrap();
        let entries = discover(
            &Snapshot::default(),
            &fixture.config(),
            Some(fixture.0.to_str().unwrap()),
            None,
            Vec::new(),
        );
        assert_eq!(entries.len(), 3);
        assert!(!entries
            .iter()
            .any(|d| d.path.ends_with("cycle") || d.path.ends_with("sub")));
        let mut config = fixture.config();
        config.limit = 1;
        assert!(walk(&config.roots, 10, &config, false).len() <= 1);
        assert!(excluded_network("/Network/server/repo"));
        assert!(excluded_network("/net/server/repo"));
    }

    #[test]
    fn exact_canonical_path_marks_existing_local_session() {
        let fixture = Fixture::new();
        let path = fixture.dir("project");
        let target = Target::TmuxNative {
            session_id: "$1".into(),
            window_id: None,
            pane_id: None,
        };
        let snapshot = Snapshot {
            sessions: vec![crate::model::Session {
                key: "$1".into(),
                name: "already-open".into(),
                window_count: "1".into(),
                attached: true,
                last: 0,
                path: format!("{path}/"),
                target: target.clone(),
            }],
            ..Snapshot::default()
        };
        let entries = discover(
            &snapshot,
            &fixture.config(),
            None,
            None,
            vec![path.clone(), format!("{path}/")],
        );
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].existing_session, Some(target));
    }
    fn session(id: usize, name: &str, path: &str) -> crate::model::Session {
        crate::model::Session {
            key: format!("${id}"),
            name: name.into(),
            path: path.into(),
            window_count: "1".into(),
            attached: false,
            last: 0,
            target: Target::TmuxNative {
                session_id: format!("${id}"),
                window_id: None,
                pane_id: None,
            },
        }
    }
    fn active_window(session: &crate::model::Session, path: &str) -> crate::model::Window {
        crate::model::Window {
            key: "@1".into(),
            session_key: session.key.clone(),
            ordinal: "0".into(),
            name: "shell".into(),
            active: true,
            cmd: "zsh".into(),
            path: path.into(),
            pane_count: 1,
            pid: 0,
            zoomed: false,
            bell: false,
            activity: false,
            target: Target::TmuxNative {
                session_id: session.key.clone(),
                window_id: Some("@1".into()),
                pane_id: None,
            },
        }
    }
    #[cfg(unix)]
    #[test]
    fn discovery_reuses_start_and_active_paths_only_for_this_pass() {
        use std::os::unix::fs::symlink;
        let f = Fixture::new();
        let first = canonical(&f.dir("first"));
        let second = canonical(&f.dir("second"));
        let other = canonical(&f.dir("other"));
        let link = f.0.join("alias");
        symlink(&first, &link).unwrap();
        let work = session(1, "renamed", link.to_str().unwrap());
        let visiting = session(2, "other", &second);
        let mut remote = session(3, "first", &first);
        remote.target = Target::Rex {
            session_id: "remote".into(),
            window_id: None,
            block_id: None,
        };
        let snapshot = Snapshot {
            windows: vec![active_window(&visiting, &other)],
            sessions: vec![remote, work.clone(), visiting.clone()],
            ..Snapshot::default()
        };
        let mut index = DirectorySessions::new(&snapshot);
        assert_eq!(index.physical.len(), 2, "probe only distinct local starts");
        assert_eq!(index.identity(&first).1.as_ref(), Some(&work.target));
        for _ in 0..3 {
            assert_eq!(index.identity(&other).1.as_ref(), Some(&visiting.target));
        }
        assert_eq!(
            index.physical.len(),
            3,
            "cache the one cwd needed to resolve collisions"
        );
        fs::remove_file(&link).unwrap();
        symlink(&second, &link).unwrap();
        assert_eq!(index.identity(&first).1.as_ref(), Some(&work.target));
        let mut refreshed = DirectorySessions::new(&snapshot);
        let (label, target) = refreshed.identity(&first);
        assert_ne!(label, "first");
        assert!(
            target.is_none(),
            "a remote session cannot claim the obsolete start path"
        );
        assert_eq!(
            refreshed.identity(&other).1.as_ref(),
            Some(&visiting.target)
        );
    }

    #[test]
    fn cached_root_and_missing_start_are_distinct_and_recents_keep_their_order() {
        let snapshot = Snapshot {
            sessions: vec![
                session(1, "root", ""),
                session(2, "at-root", "/"),
                session(3, "renamed", "/absent/repo/"),
                session(4, "repo", "/absent/repo"),
            ],
            ..Snapshot::default()
        };
        let entries = cached_with(
            &snapshot,
            ["/absent/repo/", "/", "/absent/repo", "/missing"].into_iter(),
            5,
        );
        assert_eq!(
            entries
                .iter()
                .map(|entry| entry.path.as_str())
                .collect::<Vec<_>>(),
            ["/absent/repo", "/", "/missing"]
        );
        assert_eq!(
            entries[0].existing_session.as_ref(),
            Some(&snapshot.sessions[3].target)
        );
        assert_eq!(
            entries[1].existing_session.as_ref(),
            Some(&snapshot.sessions[1].target)
        );
        assert!(entries[2].existing_session.is_none());
    }

    #[test]
    fn directory_identity_reuses_renamed_start_paths_and_prefers_the_basename_session() {
        let f = Fixture::new();
        let path = f.dir("repo");
        let renamed = session(1, "my-work", &format!("{path}/"));
        let mut snapshot = Snapshot {
            sessions: vec![renamed],
            ..Snapshot::default()
        };
        let resolved = resolve(&snapshot, &path).unwrap();
        assert_eq!(resolved.name, "my-work");
        assert!(resolved.path_query);
        assert_eq!(
            resolved.existing_session,
            Some(snapshot.sessions[0].target.clone())
        );
        snapshot.sessions.push(session(2, "repo", &path));
        assert_eq!(resolve(&snapshot, &path).unwrap().name, "repo");
        let entries = discover(&snapshot, &f.config(), None, None, vec![path]);
        assert_eq!(
            entries[0].existing_session,
            Some(snapshot.sessions[1].target.clone())
        );
    }
    #[test]
    fn collision_names_follow_legacy_parent_then_basename_numeric_order_and_keep_spaces() {
        let f = Fixture::new();
        let a = f.dir("one/api");
        let b = f.dir("two/api");
        let c = f.dir("three/elsewhere");
        let mut snapshot = Snapshot {
            sessions: vec![session(1, "api", &a)],
            ..Snapshot::default()
        };
        assert_eq!(resolve(&snapshot, &b).unwrap().name, "two-api");
        snapshot.sessions.push(session(2, "two-api", &c));
        assert_eq!(resolve(&snapshot, &b).unwrap().name, "api-2");
        snapshot.sessions.push(session(3, "api-2", &c));
        assert_eq!(resolve(&snapshot, &b).unwrap().name, "api-3");
        let spaces = f.dir("My Project.v2");
        assert_eq!(
            resolve(&Snapshot::default(), &spaces).unwrap().name,
            "My Project-v2"
        );
    }
    #[test]
    fn same_named_sessions_reuse_descendant_cwd_only_on_the_same_start_branch() {
        let f = Fixture::new();
        let project = f.dir("work/api");
        let cwd = f.dir("work/api/src");
        let unrelated = f.dir("elsewhere");
        let started = session(1, "api", f.0.to_str().unwrap());
        let window = active_window(&started, &cwd);
        let mut snapshot = Snapshot {
            sessions: vec![started],
            windows: vec![window],
            ..Snapshot::default()
        };
        assert!(resolve(&snapshot, &project)
            .unwrap()
            .existing_session
            .is_some());
        snapshot.sessions[0].path = unrelated;
        assert!(resolve(&snapshot, &project)
            .unwrap()
            .existing_session
            .is_none());
        snapshot.windows[0].path = project.clone();
        assert!(resolve(&snapshot, &project)
            .unwrap()
            .existing_session
            .is_some());
        snapshot.sessions[0].name = "unrelated-name".into();
        let entries = discover(&snapshot, &f.config(), None, None, vec![project]);
        assert!(
            entries[0].existing_session.is_none(),
            "an unrelated named session merely visiting the path is not its identity"
        );
    }
    #[test]
    fn custom_markers_work_without_promoting_every_directory_for_empty_or_dot_entries() {
        let f = Fixture::new();
        let plain = f.dir("plain");
        let custom = f.dir("custom");
        let git = f.dir("git");
        fs::write(Path::new(&custom).join("Move.toml"), "").unwrap();
        fs::write(Path::new(&git).join(".git"), "gitdir: /elsewhere").unwrap();
        let markers = project_markers("Move.toml::.:..:/:./:.github/workflows");
        assert_eq!(project_type(&plain, &markers), None);
        assert_eq!(project_type(&custom, &markers), Some("Project"));
        assert_eq!(project_type(&git, &markers), Some("Git"));
        fs::create_dir_all(Path::new(&plain).join(".github/workflows")).unwrap();
        assert_eq!(project_type(&plain, &markers), Some("Project"));
    }
    #[test]
    fn library_is_pruned_only_directly_inside_home() {
        let f = Fixture::new();
        f.dir("Library/cache");
        f.dir("work/Library/project");
        let home = discover(&Snapshot::default(), &f.config(), None, None, vec![]);
        assert!(!home.iter().any(|d| d.label == "Library"));
        let inside = discover(
            &Snapshot::default(),
            &f.config(),
            Some(f.0.join("work").to_str().unwrap()),
            None,
            vec![],
        );
        assert!(inside.iter().any(|d| d.label == "Library"));
    }
    #[test]
    fn history_updates_are_atomic_deduplicated_bounded_and_never_record_home() {
        let f = Fixture::new();
        let file = f.0.join("data/recent_dirs");
        remember("/project/a", "/home/user", &file);
        remember("/project/b", "/home/user", &file);
        remember("/project/a", "/home/user", &file);
        assert_eq!(recent_text(&file).unwrap(), "/project/a\n/project/b\n");
        remember("/home/user", "/home/user", &file);
        assert_eq!(recent_text(&file).unwrap(), "/project/a\n/project/b\n");
        for i in 0..60 {
            remember(&format!("/project/{i}"), "/home/user", &file);
        }
        assert_eq!(recent_text(&file).unwrap().lines().count(), 51);
        assert_eq!(
            fs::read_dir(file.parent().unwrap()).unwrap().count(),
            1,
            "temporary writes are removed"
        );
    }
    #[test]
    fn cached_suggestions_never_probe_remote_missing_or_fifo_candidate_directories() {
        let text = "/Network/offline/repo\n/not-present/project\n/Network/offline/repo\nrelative\nbad\tpath\n";
        let entries = cached_with(&Snapshot::default(), text.split('\n'), 15);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].path, "/Network/offline/repo");
        assert!(entries.iter().all(|d| d.project.is_none()));
        assert_eq!(cached_with(&Snapshot::default(), text.split('\n'), 1).len(), 1);
        let f = Fixture::new();
        let file = f.0.join("history");
        fs::write(&file, b"/first\n/bad\xff\n/last\n").unwrap();
        assert_eq!(recent_text(&file).unwrap(), "/first\n/last\n");
    }
    #[test]
    fn macos_mount_guard_keeps_local_volumes_and_local_overrides_inside_remote_trees() {
        let mounts = macos_mounts("/dev/disk1 on / (apfs, local, journaled)\n//server/share on /Volumes/NAS Data (smbfs, nodev)\n/dev/disk2 on /Volumes/NAS Data/local (apfs, local)\n/dev/disk3 on /Volumes/External (apfs, local)\n");
        assert!(mount_is_remote(&mounts, "/Volumes/NAS Data/repo"));
        assert!(!mount_is_remote(&mounts, "/Volumes/NAS Data/local/repo"));
        assert!(!mount_is_remote(&mounts, "/Volumes/NAS Data2/repo"));
        assert!(!mount_is_remote(&mounts, "/Volumes/External/repo"));
    }
    #[test]
    fn retained_history_survives_scan_limits_and_deep_fuzzy_queries() {
        let f = Fixture::new();
        let recent: Vec<_> = (0..25)
            .map(|i| f.dir(&format!("outside/older-project-{i:02}")))
            .collect();
        let mut config = f.config();
        config.roots = vec![PathBuf::from(f.dir("empty-root"))];
        config.limit = 3;
        config.budget = Duration::ZERO;
        let result = discover(
            &Snapshot::default(),
            &config,
            None,
            Some("oldprj24"),
            recent.clone(),
        );
        assert_eq!(
            result.len(),
            25,
            "scan bounds must not truncate retained history before matching"
        );
        assert!(result.iter().any(|entry| entry.path == recent[24]));
        assert!(result.iter().all(|entry| entry.project.is_none()));
    }

    // Each case runs in its own process so PATH and history changes cannot
    // race other tests or touch the caller's environment or real zoxide data.
    #[cfg(unix)]
    #[test]
    fn optional_zoxide_and_retained_history_are_bounded_and_isolated() {
        const CASE: &str = "IMUX_DISCOVERY_CHILD_CASE";
        if let Ok(case) = std::env::var(CASE) {
            let root = PathBuf::from(std::env::var("IMUX_DISCOVERY_ROOT").unwrap());
            let old = root
                .join("older/old-project-24")
                .to_string_lossy()
                .into_owned();
            let started = Instant::now();
            match case.as_str() {
                "history" => {
                    let cached = cached_directories(&Snapshot::default());
                    assert_eq!(cached.len(), 25);
                    assert_eq!(cached.last().unwrap().path, old);
                    // Removing the source after collection must not affect
                    // ordinary lexical matching of these retained entries.
                    fs::remove_file(recent_file()).unwrap();
                    assert!(cached.iter().any(|entry| entry.label == "old-project-24"));
                }
                "resolve-stall" => {
                    assert_eq!(normalize_query("unmatched-project-name").unwrap().cwd, home());
                }
                "add-stall" => {
                    record_use(&old);
                    assert!(recent_text(&recent_file()).unwrap().starts_with(&old));
                }
                "inventory-success" | "resolver-fallback" | "resolver-override" => {
                    let paths = zoxide_inventory();
                    assert_eq!(paths.len(), 25, "inventory command: {:?}",
                        fs::read_to_string(root.join("executable-used")));
                    assert!(paths[24].ends_with("zoxide-project-24"));
                    let entries = cached_paths(&Snapshot::default(), &paths);
                    assert_eq!(entries.len(), 25);
                    assert_eq!(entries[24].path, paths[24]);
                    if case == "resolver-override" {
                        assert_eq!(fs::read_to_string(root.join("executable-used")).unwrap().trim(),
                            root.join("explicit-zoxide").to_str().unwrap());
                    }
                }
                "inventory-off" => {
                    assert!(zoxide_inventory().is_empty());
                    assert!(!root.join("pids").exists());
                }
                _ => {
                    let entries = directories(&Snapshot::default(), None, Some("oldprj24"));
                    assert!(
                        entries.iter().any(|entry| entry.path == old),
                        "stalled optional enrichment dropped own history"
                    );
                    if case == "old-success" {
                        assert!(
                            entries
                                .iter()
                                .any(|entry| entry.label == "zoxide-project-24"),
                            "lower-ranked zoxide entry was truncated before matching"
                        );
                    }
                }
            }
            assert!(
                started.elapsed() < Duration::from_secs(2),
                "optional zoxide stalled {case}: {:?}",
                started.elapsed()
            );
            if let Ok(pids) = fs::read_to_string(root.join("pids")) {
                extern "C" {
                    fn kill(pid: i32, signal: i32) -> i32;
                }
                for pid in pids.lines().map(|pid| pid.parse::<i32>().unwrap()) {
                    assert_ne!(
                        unsafe { kill(pid, 0) },
                        0,
                        "zoxide child {pid} was not killed/reaped"
                    );
                }
            }
            return;
        }
        use std::os::unix::fs::PermissionsExt;
        let f = Fixture::new();
        let root = fs::canonicalize(&f.0).unwrap();
        let data = root.join("data/interdimux");
        fs::create_dir_all(&data).unwrap();
        let recents: Vec<_> = (0..25)
            .map(|i| {
                fs::canonicalize(f.dir(&format!("older/old-project-{i:02}")))
                    .unwrap()
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        let zoxide: Vec<_> = (0..25)
            .map(|i| {
                fs::canonicalize(f.dir(&format!("zoxide-projects/zoxide-project-{i:02}")))
                    .unwrap()
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        let zoxide_file = root.join("zoxide-output");
        fs::write(&zoxide_file, zoxide.join("\n") + "\n").unwrap();
        let executable = root.join("zoxide");
        fs::write(&executable, r##"#!/bin/sh
[ "$1" = --version ] && exit 0
printf '%s\n' "$$" >> "$IMUX_DISCOVERY_ROOT/pids"
printf '%s\n' "$0" >> "$IMUX_DISCOVERY_ROOT/executable-used"
case "$IMUX_DISCOVERY_CHILD_CASE" in
  inventory-success|resolver-fallback|resolver-override)
    cat "$IMUX_DISCOVERY_ROOT/zoxide-output"; exit ;;
  old-success|fallback-stall)
    if [ "$3" = --all ]; then exit 2; fi
    if [ "$IMUX_DISCOVERY_CHILD_CASE" = old-success ]; then cat "$IMUX_DISCOVERY_ROOT/zoxide-output"; exit; fi
    ;;
  oversized) exec yes /not/a/real/directory ;;
esac
exec sleep 30
"##).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        // macOS can spend longer than the command deadline on the first
        // launch of a newly written executable, before its script even runs.
        assert!(Command::new(&executable).arg("--version").status().unwrap().success());
        fs::create_dir_all(root.join(".cargo/bin")).unwrap();
        std::os::unix::fs::symlink(&executable, root.join(".cargo/bin/zoxide")).unwrap();
        std::os::unix::fs::symlink(&executable, root.join("explicit-zoxide")).unwrap();
        for case in [
            "history",
            "resolve-stall",
            "add-stall",
            "list-stall",
            "fallback-stall",
            "oversized",
            "old-success",
            "inventory-success",
            "inventory-off",
            "resolver-fallback",
            "resolver-override",
        ] {
            fs::write(data.join("recent_dirs"), recents.join("\n") + "\n").unwrap();
            let _ = fs::remove_file(root.join("pids"));
            let _ = fs::remove_file(root.join("executable-used"));
            let mut command = Command::new(std::env::current_exe().unwrap());
            command.args(["--exact", "projects::tests::optional_zoxide_and_retained_history_are_bounded_and_isolated", "--nocapture"])
                .env(CASE, case).env("IMUX_DISCOVERY_ROOT", &root)
                .env("HOME", &root).env("XDG_DATA_HOME", root.join("data"))
                .env("INTERDIMUX_SHOW_DIRS", "on")
                .env("INTERDIMUX_USE_ZOXIDE", if case == "inventory-off" { "off" } else { "on" })
                .env("INTERDIMUX_DIRS_LIMIT", "3").env("INTERDIMUX_RECENT_LIMIT", "3")
                .env("INTERDIMUX_PROJECT_DIRS", f.dir("empty-root"))
                .env_remove("INTERDIMUX_ZOXIDE_BIN")
                .env("PATH", if case.starts_with("resolver-") { "/usr/bin:/bin".to_owned() }
                    else { format!("{}:/usr/bin:/bin", root.display()) });
            if case == "resolver-override" {
                command.env("INTERDIMUX_ZOXIDE_BIN", root.join("explicit-zoxide"));
            }
            let result = command.output().unwrap();
            assert!(
                result.status.success(),
                "{case}: {}{}",
                String::from_utf8_lossy(&result.stdout),
                String::from_utf8_lossy(&result.stderr)
            );
        }
    }
}
