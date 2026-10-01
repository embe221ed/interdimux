//! Directory candidates for the one-list model, and project-type detection.
//! Mirrors bash `load_recent_dirs` + `detect_project_type`.

use std::fs;
use std::path::Path;
use std::process::{Child, Command, Stdio};

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

/// zoxide's query, STARTED, for `candidates` to collect.  gather calls this
/// before it renders the first row, so the query -- 7-20 ms, the largest single
/// cost of a list with directory rows on -- runs while the tmux rows are drawn
/// instead of after them; the rows still all go out in one write at the end.
/// None when zoxide is off, or not installed (then there is nothing to wait
/// for: the plain query could not start either).
pub fn start_zoxide() -> Option<Child> {
    let use_zoxide = std::env::var("INTERDIMUX_USE_ZOXIDE").map(|v| v == "on").unwrap_or(true);
    if !use_zoxide {
        return None;
    }
    zoxide_query(true).spawn().ok()
}

/// The recent list first, then zoxide's frecency, deduped, existing dirs only.
/// `zoxide` is start_zoxide's child: collected here, not re-run.  Never cached
/// across lists -- the recent file changes on every switch.
pub fn candidates(zoxide: Option<Child>) -> Vec<String> {
    let mut seen: std::collections::HashSet<String> = Default::default();
    let mut out = Vec::new();
    let limit = recent_limit();

    // Read BYTES, not a String.  read_to_string() errors on the first invalid
    // UTF-8 byte and the `if let Ok` swallowed it, so ONE non-UTF-8 directory
    // name silently deleted the entire recent list — and interdimux writes this
    // file itself, so visiting such a directory once killed the feature
    // permanently.  Now only that one line is skipped (see utf8_lines).
    if let Ok(bytes) = fs::read(recent_file()) {
        for d in utf8_lines(&bytes) {
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

    if let Some(child) = zoxide {
        let ok = |o: std::process::Output| if o.status.success() { Some(o) } else { None };
        let listed = child
            .wait_with_output()
            .ok()
            .and_then(ok)
            .or_else(|| zoxide_query(false).output().ok().and_then(ok));
        if let Some(o) = listed {
            let mut n = 0;
            for d in utf8_lines(&o.stdout) {
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

/// The directory `p` names, spelled one way: what `pwd -P` prints there, so
/// every spelling of one directory -- a trailing or doubled '/', a path through
/// a symlink -- comes out the same.  A directory row is hidden when a session
/// was started in it (or its active window is in it) under ANY spelling, since
/// Enter on the row resolves it and switches to that session: tmux keeps
/// `-c ~/repo/` with its slash, and a session started from a shell in a
/// symlinked directory keeps the logical path, while the recent list and zoxide
/// have their own spellings.  bash's canon_dir -- keep them in step: runs of
/// '/' collapse and trailing ones go, then the physical path of a directory
/// that exists, except on a filesystem whose stat can block (mounts.rs), which
/// keeps its spelling; so does a relative path.
pub fn canon_dir(p: &str) -> String {
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
    if !s.starts_with('/') || crate::mounts::is_remote(&s) {
        return s;
    }
    match fs::canonicalize(&s) {
        Ok(r) if r.is_dir() => r.to_str().map(str::to_string).unwrap_or(s),
        _ => s,
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
        let phys = fs::canonicalize(&real).unwrap().to_str().unwrap().to_string();
        let base = d.to_str().unwrap();
        for spelling in [
            format!("{}/real", base),
            format!("{}/real/", base),
            format!("{}//real//", base),
            format!("{}/link", base),
            format!("{}/link/", base),
        ] {
            assert_eq!(canon_dir(&spelling), phys, "{}", spelling);
        }
        assert_eq!(canon_dir(&format!("{}//gone//", base)), format!("{}/gone", base));
        assert_eq!(canon_dir("rel//x/"), "rel/x");
        assert_eq!(canon_dir("//"), "/");
        fs::remove_dir_all(&d).ok();
    }
}
