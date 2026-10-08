//! Git branch for a directory, read straight from .git/HEAD — no `git` fork.
//! Ported from the bash pure-bash reader, including worktree/submodule support
//! where .git is a FILE containing "gitdir: <path>".

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Default)]
pub struct GitCache {
    /// The answer for every directory a walk started from or passed through,
    /// by its spelling there.  Where a directory has no repository of its
    /// own, its answer IS its parent's, so a sibling's walk -- every pane and
    /// directory row under one $HOME -- stops at the first ancestor already
    /// walked instead of probing each level up to `/` again.
    cache: HashMap<OsString, String>,
}

impl GitCache {
    pub fn new() -> Self {
        Self::default()
    }

    /// Branch name, or `@<7-char sha>` for a detached HEAD, or empty.
    /// Walks up toward `/` exactly as the bash loop does.
    pub fn branch(&mut self, dir: &str) -> String {
        if dir.is_empty() {
            return String::new();
        }
        if let Some(v) = self.cache.get(OsStr::new(dir)) {
            return v.clone();
        }
        let mut passed = Vec::new();
        let out = self.lookup(dir, &mut passed);
        for d in passed {
            self.cache.insert(d.into_os_string(), out.clone());
        }
        out
    }

    /// The walk from `dir`, every level of which goes into `passed`: each
    /// one's answer is the one this returns.
    fn lookup(&self, dir: &str, passed: &mut Vec<PathBuf>) -> String {
        let mut d = PathBuf::from(dir);
        loop {
            if let Some(v) = self.cache.get(d.as_os_str()) {
                return v.clone();
            }
            passed.push(d.clone());
            // Never probe a filesystem whose stat can block (mounts.rs): the
            // walk stops there, badge-less, rather than stall the first paint.
            if d.to_str().map_or(false, crate::mounts::is_remote) {
                return String::new();
            }
            let dot = d.join(".git");
            // One stat answers both questions: is_dir() and then is_file()
            // were two for every level without a .git, nearly all of them.
            let md = fs::metadata(&dot).ok();
            let head = if md.as_ref().map_or(false, fs::Metadata::is_dir) {
                // Only with a HEAD in it, as git's own discovery has it: an
                // empty .git (a half-made clone, a stray `mkdir .git` inside a
                // repository) is skipped and the walk goes on to the enclosing
                // repository.  Taking it as the answer ended the walk with no
                // badge at all, where the bash renderer found the parent's.
                let h = dot.join("HEAD");
                if h.is_file() { Some(h) } else { None }
            } else if md.as_ref().map_or(false, fs::Metadata::is_file) {
                // "gitdir: <path>", possibly relative to d
                let gd = fs::read_to_string(&dot).ok().and_then(|s| {
                    let line = s.lines().next()?.trim().to_string();
                    let p = line.strip_prefix("gitdir: ")?;
                    Some(if p.starts_with('/') { PathBuf::from(p) } else { d.join(p) })
                });
                match gd {
                    // a worktree whose repository is on such a mount: stop here
                    Some(gd) if gd.to_str().map_or(false, crate::mounts::is_remote) => {
                        return String::new();
                    }
                    Some(gd) => {
                        let h = gd.join("HEAD");
                        if h.is_file() { Some(h) } else { None }
                    }
                    None => None,
                }
            } else {
                None
            };

            if let Some(h) = head {
                if let Ok(content) = fs::read_to_string(&h) {
                    let line = content.lines().next().unwrap_or("").trim_end();
                    return match line.strip_prefix("ref: refs/heads/") {
                        Some(b) => b.to_string(),
                        None => {
                            let sha: String = line.chars().take(7).collect();
                            if sha.is_empty() { String::new() } else { format!("@{}", sha) }
                        }
                    };
                }
                return String::new();
            }

            match d.parent() {
                Some(p) if p != Path::new("") && p != d => d = p.to_path_buf(),
                _ => return String::new(),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tmpdir(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("imux-git-test-{}-{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn reads_a_branch_from_a_normal_repo() {
        let d = tmpdir("normal");
        fs::create_dir_all(d.join(".git")).unwrap();
        fs::write(d.join(".git/HEAD"), "ref: refs/heads/feature/x\n").unwrap();
        let mut g = GitCache::new();
        assert_eq!(g.branch(d.to_str().unwrap()), "feature/x");
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn detached_head_renders_a_short_sha() {
        let d = tmpdir("detached");
        fs::create_dir_all(d.join(".git")).unwrap();
        fs::write(d.join(".git/HEAD"), "0123456789abcdef0123456789abcdef01234567\n").unwrap();
        let mut g = GitCache::new();
        assert_eq!(g.branch(d.to_str().unwrap()), "@0123456");
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn walks_up_to_the_repo_root() {
        let d = tmpdir("nested");
        fs::create_dir_all(d.join(".git")).unwrap();
        fs::write(d.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        let deep = d.join("a/b/c");
        fs::create_dir_all(&deep).unwrap();
        let mut g = GitCache::new();
        assert_eq!(g.branch(deep.to_str().unwrap()), "main");
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn worktree_gitdir_file_is_followed() {
        let d = tmpdir("worktree");
        let real = d.join("realgit");
        fs::create_dir_all(&real).unwrap();
        fs::write(real.join("HEAD"), "ref: refs/heads/wt\n").unwrap();
        let wt = d.join("wt");
        fs::create_dir_all(&wt).unwrap();
        fs::write(wt.join(".git"), format!("gitdir: {}\n", real.display())).unwrap();
        let mut g = GitCache::new();
        assert_eq!(g.branch(wt.to_str().unwrap()), "wt");
        fs::remove_dir_all(&d).ok();
    }

    /// An empty .git inside a repository is not a repository: the walk goes
    /// on to the enclosing one, as git's discovery and the bash reader do.
    #[test]
    fn an_empty_dot_git_is_skipped_for_the_enclosing_repo() {
        let d = tmpdir("emptydotgit");
        fs::create_dir_all(d.join(".git")).unwrap();
        fs::write(d.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        let inner = d.join("inner");
        fs::create_dir_all(inner.join(".git")).unwrap();
        let mut g = GitCache::new();
        assert_eq!(g.branch(inner.to_str().unwrap()), "main");
        fs::remove_dir_all(&d).ok();
    }

    /// Git writes HEAD with a trailing newline, but a HEAD or gitdir file
    /// written without one (by a tool, by hand) is still valid to git.
    #[test]
    fn head_and_gitdir_files_without_a_trailing_newline_are_read() {
        let d = tmpdir("nonl");
        fs::create_dir_all(d.join("a/.git")).unwrap();
        fs::write(d.join("a/.git/HEAD"), "ref: refs/heads/no-newline").unwrap();
        let real = d.join("realgit");
        fs::create_dir_all(&real).unwrap();
        fs::write(real.join("HEAD"), "ref: refs/heads/wt\r\n").unwrap();
        fs::create_dir_all(d.join("wt")).unwrap();
        fs::write(d.join("wt/.git"), format!("gitdir: {}", real.display())).unwrap();
        let mut g = GitCache::new();
        assert_eq!(g.branch(d.join("a").to_str().unwrap()), "no-newline");
        assert_eq!(g.branch(d.join("wt").to_str().unwrap()), "wt", "CRLF HEAD, newline-less gitdir");
        fs::remove_dir_all(&d).ok();
    }

    /// The walk's answers are kept for every directory it passed, and none of
    /// them hides a nearer repository: a directory below one already walked
    /// is probed itself before the walk reaches that ancestor.
    #[test]
    fn a_walk_answers_for_its_ancestors_and_never_hides_a_nearer_repo() {
        let d = tmpdir("memo");
        fs::create_dir_all(d.join(".git")).unwrap();
        fs::write(d.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        fs::create_dir_all(d.join("x/inner/.git")).unwrap();
        fs::write(d.join("x/inner/.git/HEAD"), "ref: refs/heads/other\n").unwrap();
        fs::create_dir_all(d.join("x/y")).unwrap();
        fs::create_dir_all(d.join("x/inner/z")).unwrap();
        let mut g = GitCache::new();
        let at = |p: &str| d.join(p).to_str().unwrap().to_string();
        assert_eq!(g.branch(&at("x/y")), "main");
        assert_eq!(g.branch(&at("x")), "main", "an ancestor the walk passed");
        assert_eq!(g.branch(&at("x/inner/z")), "other", "a repo below one walked");
        assert_eq!(g.branch(&at("x/inner")), "other");
        assert_eq!(g.branch(&format!("{}/", at("x/y"))), "main", "another spelling");
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn a_non_repo_yields_empty() {
        let d = tmpdir("bare");
        let mut g = GitCache::new();
        assert_eq!(g.branch(d.to_str().unwrap()), "");
        fs::remove_dir_all(&d).ok();
    }
}
