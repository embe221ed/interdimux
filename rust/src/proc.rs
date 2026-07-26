//! Full-command resolution, ported from the bash /proc backend.
//!
//! Strategy: if the pane's own process is a shell, show its first child (the
//! command the user typed).  Never walk deeper — grandchildren are the
//! command's own subprocesses (LSPs, formatters) and showing those misleads.
//!
//! Three traps this reproduces deliberately, each of which silently broke a
//! bash prototype:
//!   * the shell test must come from the pane process's OWN argv.  tmux's
//!     #{pane_current_command} names the tty's FOREGROUND process group, so
//!     gating on it inverts the test exactly when a command IS running.
//!   * /proc/<pid>/task/<pid>/children has no trailing newline.
//!   * `ps` was implicitly sanitizing argv: NUL and newline become a space,
//!     every other non-printable becomes '?'.  Raw /proc bytes would let a
//!     newline split a row and detach its trailing SPEC field.

use std::collections::HashMap;
use std::fs;

/// Does this look like a login/interactive shell?  Mirrors SHELLS_PATTERN:
/// `^-?(ba|z|fi|da|a|k|tc|c)?sh$|^-?login$`
pub fn is_shell(cmd: &str) -> bool {
    let base = cmd.rsplit('/').next().unwrap_or(cmd);
    let s = base.strip_prefix('-').unwrap_or(base);
    if s == "login" {
        return true;
    }
    match s.strip_suffix("sh") {
        Some(prefix) => matches!(prefix, "" | "ba" | "z" | "fi" | "da" | "a" | "k" | "tc" | "c"),
        None => false,
    }
}

/// Render argv the way `ps args=` does, so both backends produce identical rows.
pub fn sanitize(s: &str) -> String {
    if !s.chars().any(|c| c.is_control()) {
        return s.to_string();
    }
    s.chars()
        .map(|c| match c {
            '\n' | '\0' => ' ',
            c if c.is_control() => '?',
            c => c,
        })
        .collect()
}

pub struct Resolver {
    available: bool,
    cache: HashMap<u32, String>,
}

impl Resolver {
    pub fn new() -> Self {
        let pid = std::process::id();
        let available = !force_ps()
            && fs::metadata(format!("/proc/{}/task/{}/children", pid, pid)).is_ok();
        Resolver { available, cache: HashMap::new() }
    }

    #[allow(dead_code)] // used by tests and by future non-Linux gating
    pub fn available(&self) -> bool {
        self.available
    }

    /// Space-joined argv of `pid`, ps-style.  Empty when the process is gone —
    /// callers then fall back to tmux's own #{pane_current_command}.
    fn cmdline(&mut self, pid: u32) -> String {
        if pid == 0 {
            return String::new(); // /proc//cmdline is the KERNEL boot line
        }
        if let Some(v) = self.cache.get(&pid) {
            return v.clone();
        }
        let raw = fs::read(format!("/proc/{}/cmdline", pid)).unwrap_or_default();
        let joined = raw
            .split(|b| *b == 0)
            .filter(|s| !s.is_empty())
            .map(|s| String::from_utf8_lossy(s).into_owned())
            .collect::<Vec<_>>()
            .join(" ");
        let out = sanitize(&joined);
        self.cache.insert(pid, out.clone());
        out
    }

    fn first_child(&self, pid: u32) -> Option<u32> {
        let s = fs::read_to_string(format!("/proc/{}/task/{}/children", pid, pid)).ok()?;
        s.split_whitespace().next()?.parse().ok()
    }

    /// The command to display for a pane.  `short` is tmux's
    /// #{pane_current_command}, used only as the fallback.
    pub fn full_command(&mut self, pid: u32, short: &str) -> String {
        if !self.available {
            return short.replace('\t', " ");
        }
        let own = self.cmdline(pid);
        let argv0 = own.split(' ').next().unwrap_or("");
        let resolved = if is_shell(argv0) {
            match self.first_child(pid) {
                Some(child) => self.cmdline(child),
                None => own.clone(),
            }
        } else {
            own.clone()
        };
        let r = resolved.replace('\t', " ");
        let r = r.trim();
        if r.is_empty() {
            short.replace('\t', " ")
        } else {
            r.to_string()
        }
    }
}

fn force_ps() -> bool {
    std::env::var("INTERDIMUX_FORCE_PS").map(|v| v == "1").unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_detection_matches_the_bash_pattern() {
        for s in ["sh", "bash", "zsh", "fish", "dash", "ash", "ksh", "tcsh", "csh", "login"] {
            assert!(is_shell(s), "{} should be a shell", s);
            assert!(is_shell(&format!("-{}", s)), "-{} should be a shell", s);
        }
        assert!(is_shell("/bin/bash"), "path-qualified shells count");
        for s in ["vim", "nvim", "sleep", "ssh", "python", "wish", "flush"] {
            assert!(!is_shell(s), "{} should NOT be a shell", s);
        }
    }

    #[test]
    fn sanitize_matches_ps_semantics() {
        // ps maps NUL and newline to a space, every other unprintable to '?'
        assert_eq!(sanitize("a\nb"), "a b");
        assert_eq!(sanitize("c\td"), "c?d");
        assert_eq!(sanitize("e\rf"), "e?f");
        assert_eq!(sanitize("g\x0bh"), "g?h");
        assert_eq!(sanitize("m\x01n"), "m?n");
        assert_eq!(sanitize("o\x1fp"), "o?p");
        assert_eq!(sanitize("q\x7fr"), "q?r");
        assert_eq!(sanitize("plain text"), "plain text");
    }

    #[test]
    fn sanitize_never_lets_a_row_breaker_through() {
        for bad in ["\n", "\t", "\x1f", "\x1e"] {
            let out = sanitize(&format!("cmd{}arg", bad));
            assert!(!out.contains('\n'), "newline survived: {:?}", out);
            assert!(!out.contains('\t'), "tab survived: {:?}", out);
            assert!(!out.contains('\x1f'), "US survived: {:?}", out);
        }
    }

    #[test]
    fn pid_zero_never_reads_the_kernel_cmdline() {
        let mut r = Resolver { available: true, cache: HashMap::new() };
        assert_eq!(r.cmdline(0), "");
    }

    #[test]
    fn resolves_this_process() {
        let mut r = Resolver::new();
        if !r.available() {
            return; // non-Linux
        }
        let me = std::process::id();
        let c = r.cmdline(me);
        assert!(!c.is_empty(), "should read our own cmdline");
    }
}
