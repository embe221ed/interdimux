//! Directory candidates for the one-list model, and project-type detection.
//! Mirrors bash `load_recent_dirs` + `detect_project_type`.

use std::fs;
use std::path::Path;

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

/// The recent list first, then zoxide's frecency, deduped, existing dirs only.
pub fn candidates() -> Vec<String> {
    let mut seen: std::collections::HashSet<String> = Default::default();
    let mut out = Vec::new();
    let limit = recent_limit();

    // Read BYTES and decode lossily per line.  read_to_string() errors on the
    // first invalid UTF-8 byte and the `if let Ok` swallowed it, so ONE
    // non-UTF-8 directory name silently deleted the entire recent list — and
    // interdimux writes this file itself, so visiting such a directory once
    // killed the feature permanently.
    if let Ok(bytes) = fs::read(recent_file()) {
        let content = String::from_utf8_lossy(&bytes).into_owned();
        for d in content.lines() {
            if out.len() >= limit {
                break;
            }
            if d.is_empty() || seen.contains(d) || !Path::new(d).is_dir() {
                continue;
            }
            seen.insert(d.to_string());
            out.push(d.to_string());
        }
    }

    let use_zoxide = std::env::var("INTERDIMUX_USE_ZOXIDE").map(|v| v == "on").unwrap_or(true);
    if use_zoxide {
        if let Ok(o) = std::process::Command::new("zoxide").args(["query", "--list"]).output() {
            let mut n = 0;
            for d in String::from_utf8_lossy(&o.stdout).lines() {
                if n >= limit {
                    break;
                }
                if d.is_empty() || seen.contains(d) || !Path::new(d).is_dir() {
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

/// First matching marker wins — the same order bash checks in.
pub fn project_type(dir: &str) -> Option<&'static str> {
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

    #[test]
    fn an_empty_dir_has_no_type() {
        let d = tmp("empty");
        assert_eq!(project_type(d.to_str().unwrap()), None);
        fs::remove_dir_all(&d).ok();
    }
}
