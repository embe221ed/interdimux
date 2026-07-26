//! Git branch for a directory, read straight from .git/HEAD — no `git` fork.
//! Ported from the bash pure-bash reader, including worktree/submodule support
//! where .git is a FILE containing "gitdir: <path>".

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Default)]
pub struct GitCache {
    cache: HashMap<String, String>,
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
        if let Some(v) = self.cache.get(dir) {
            return v.clone();
        }
        let out = Self::lookup(dir);
        self.cache.insert(dir.to_string(), out.clone());
        out
    }

    fn lookup(dir: &str) -> String {
        let mut d = PathBuf::from(dir);
        loop {
            let dot = d.join(".git");
            let head = if dot.is_dir() {
                Some(dot.join("HEAD"))
            } else if dot.is_file() {
                // "gitdir: <path>", possibly relative to d
                fs::read_to_string(&dot).ok().and_then(|s| {
                    let line = s.lines().next()?.trim().to_string();
                    let p = line.strip_prefix("gitdir: ")?;
                    let gd = if p.starts_with('/') {
                        PathBuf::from(p)
                    } else {
                        d.join(p)
                    };
                    let h = gd.join("HEAD");
                    if h.is_file() { Some(h) } else { None }
                })
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

    #[test]
    fn a_non_repo_yields_empty() {
        let d = tmpdir("bare");
        let mut g = GitCache::new();
        assert_eq!(g.branch(d.to_str().unwrap()), "");
        fs::remove_dir_all(&d).ok();
    }
}
