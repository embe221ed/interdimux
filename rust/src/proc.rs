//! Full-command resolution, ported from the bash backends.
//!
//! Strategy: if the pane's own process is a shell, show its first child (the
//! command the user typed).  Never walk deeper — grandchildren are the
//! command's own subprocesses (LSPs, formatters) and showing those misleads.
//!
//! Two backends, mirroring the bash script:
//!   * `/proc` (Linux): one lazy read per pane, no fork, cost scales with panes.
//!   * `ps` (macOS/BSD, or when `/proc` is forced off): a single `ps -eo` snapshot
//!     built once, then walked in-process.  bash used to do this walk itself and
//!     hand the Rust core nothing, which meant the whole render fell back to bash
//!     on any host without `/proc`.  Owning it here lets the fast renderer run
//!     everywhere.
//!
//! Three traps this reproduces deliberately, each of which silently broke a
//! bash prototype:
//!   * the shell test must come from the pane process's OWN argv.  tmux's
//!     #{pane_current_command} names the tty's FOREGROUND process group, so
//!     gating on it inverts the test exactly when a command IS running.
//!   * /proc/<pid>/task/<pid>/children has no trailing newline.
//!   * `ps` was implicitly sanitizing argv: NUL and newline become a space,
//!     every other non-printable becomes '?'.  Raw /proc bytes would let a
//!     newline split a row and detach its trailing SPEC field — so the /proc
//!     backend sanitizes, and the ps backend stores ps output VERBATIM (ps has
//!     already sanitized it), byte-for-byte as bash's `PS_ARGS[$pid]="$args"`.

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
/// Used only by the /proc backend — the ps backend gets already-sanitized bytes.
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

/// A one-shot `ps -eo pid=,ppid=,args=` snapshot, parsed into the same two maps
/// bash builds (pid -> argv, ppid -> children).  Children preserve ps output
/// order so `first()` picks the same child bash's `${children%% *}` does.
struct PsTable {
    args: HashMap<u32, String>,
    children: HashMap<u32, Vec<u32>>,
}

impl PsTable {
    fn snapshot() -> Option<PsTable> {
        // The EXACT command bash forks, inheriting bash's environment, so any
        // width-truncation ps applies is identical on both sides.
        let out = std::process::Command::new("ps")
            .args(["-eo", "pid=,ppid=,args="])
            .output()
            .ok()?;
        // bash ignores ps's exit status and processes whatever it printed.
        let text = String::from_utf8_lossy(&out.stdout);
        let mut args: HashMap<u32, String> = HashMap::new();
        let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
        for line in text.lines() {
            if let Some((pid, ppid, a)) = parse_ps_line(line) {
                args.insert(pid, a);
                children.entry(ppid).or_default().push(pid);
            }
        }
        if args.is_empty() {
            return None; // ps missing or produced nothing -> unavailable, like bash
        }
        Some(PsTable { args, children })
    }
}

/// bash's default IFS is exactly space, tab, newline — and a ps line never holds
/// a newline, so the field separators are ASCII space and tab.  Rust's own
/// `char::is_whitespace`/`str::trim_start` are UNICODE-aware and would strip a
/// leading NBSP / U+2028 / U+2000 / U+3000 that macOS `ps -o args=` passes
/// through VERBATIM and that bash `read` KEEPS.  That mismatch is invisible for
/// ordinary commands (the shared trim erases it) but surfaces at shell detection,
/// which reads the UN-trimmed argv0: on a pathological argv0 like "\u{a0}-bash"
/// bash sees a non-shell (its `^-?…sh$` fails on the NBSP) while a Unicode strip
/// would make Rust see "-bash", descend, and emit a different row.  Match bash:
/// split and trim on ASCII IFS only.
const IFS_WS: [char; 2] = [' ', '\t'];

/// Split one `ps` line into (pid, ppid, args), mirroring bash `read -r pid ppid
/// args`: the first two IFS-delimited fields, then the remainder with its leading
/// IFS whitespace stripped and everything else preserved.  Trailing whitespace is
/// irrelevant — `full_command`'s trim removes it before it is used.
fn parse_ps_line(line: &str) -> Option<(u32, u32, String)> {
    let (pid_s, rest) = take_word(line.trim_start_matches(IFS_WS))?;
    let (ppid_s, rest) = take_word(rest.trim_start_matches(IFS_WS))?;
    let args = rest.trim_start_matches(IFS_WS).to_string();
    Some((pid_s.parse().ok()?, ppid_s.parse().ok()?, args))
}

fn take_word(s: &str) -> Option<(&str, &str)> {
    if s.is_empty() {
        return None;
    }
    match s.find(IFS_WS) {
        Some(i) => Some((&s[..i], &s[i..])),
        None => Some((s, "")),
    }
}

pub struct Resolver {
    proc_ok: bool,          // Linux /proc backend
    ps: Option<PsTable>,    // macOS/BSD ps backend
    available: bool,
    cache: HashMap<u32, String>, // /proc cmdline memo (unused by the ps backend)
}

impl Resolver {
    pub fn new() -> Self {
        let pid = std::process::id();
        let proc_ok = !force_ps()
            && fs::metadata(format!("/proc/{}/task/{}/children", pid, pid)).is_ok();
        if proc_ok {
            return Resolver { proc_ok: true, ps: None, available: true, cache: HashMap::new() };
        }
        // No /proc (macOS/BSD), or the ps backend was forced: one ps snapshot.
        match PsTable::snapshot() {
            Some(t) => Resolver { proc_ok: false, ps: Some(t), available: true, cache: HashMap::new() },
            None => Resolver { proc_ok: false, ps: None, available: false, cache: HashMap::new() },
        }
    }

    #[allow(dead_code)] // used by tests
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
        // Empty argv elements are DROPPED, which is a deliberate divergence from
        // both `ps args=` and the bash backend (it appends "$a " for every
        // segment, empty ones included).  A process with an empty argv element
        // renders `a  b` there and `a b` here.  The run of blank cells is noise
        // in a one-line command column, the bash renderer is frozen, and the
        // parity harness only compares real argv, so this is the better output
        // rather than an oversight.  Note the trailing NUL every /proc/cmdline
        // carries would otherwise add a stray space to EVERY command.
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

    /// argv of `pid` from whichever backend is active.  ps output is stored
    /// verbatim (ps already sanitized it) so it is byte-identical to bash's
    /// `PS_ARGS[$pid]`; /proc is read and sanitized lazily.
    fn args_of(&mut self, pid: u32) -> String {
        if let Some(t) = &self.ps {
            return t.args.get(&pid).cloned().unwrap_or_default();
        }
        if self.proc_ok {
            return self.cmdline(pid);
        }
        String::new()
    }

    /// The pid of the shell's first child, in the same order bash would pick.
    fn first_child(&self, pid: u32) -> Option<u32> {
        if let Some(t) = &self.ps {
            return t.children.get(&pid).and_then(|v| v.first()).copied();
        }
        if self.proc_ok {
            let s = fs::read_to_string(format!("/proc/{}/task/{}/children", pid, pid)).ok()?;
            return s.split_whitespace().next()?.parse().ok();
        }
        None
    }

    /// The command to display for a pane.  `short` is tmux's
    /// #{pane_current_command}, used only as the fallback.  This tail is shared
    /// by both backends and mirrors bash `resolve_command`: tab->space, trim,
    /// and fall back to the short command when the result is empty.
    pub fn full_command(&mut self, pid: u32, short: &str) -> String {
        if !self.available {
            return short.replace('\t', " ");
        }
        let own = self.args_of(pid);
        let argv0 = own.split(' ').next().unwrap_or("");
        let resolved = if is_shell(argv0) {
            match self.first_child(pid) {
                Some(child) => self.args_of(child),
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

    fn ps_resolver(lines: &[(u32, u32, &str)]) -> Resolver {
        let mut args = HashMap::new();
        let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
        for &(pid, ppid, a) in lines {
            args.insert(pid, a.to_string());
            children.entry(ppid).or_default().push(pid);
        }
        Resolver {
            proc_ok: false,
            ps: Some(PsTable { args, children }),
            available: true,
            cache: HashMap::new(),
        }
    }

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
        let mut r = Resolver {
            proc_ok: true,
            ps: None,
            available: true,
            cache: HashMap::new(),
        };
        assert_eq!(r.cmdline(0), "");
    }

    #[test]
    fn resolves_this_process() {
        let mut r = Resolver::new();
        assert!(r.available(), "some backend should be available on the test host");
        // both /proc and ps snapshots include our own pid
        let me = std::process::id();
        assert!(!r.args_of(me).is_empty(), "should resolve our own argv");
    }

    // --- ps-backend parsing + resolution ------------------------------------

    #[test]
    fn parses_ps_lines_like_bash_read() {
        // leading pad, multi-space padding, internal spacing preserved
        assert_eq!(parse_ps_line("  501  1234 /usr/bin/vim foo.rs"),
                   Some((501, 1234, "/usr/bin/vim foo.rs".to_string())));
        assert_eq!(parse_ps_line("1 0 /sbin/launchd"),
                   Some((1, 0, "/sbin/launchd".to_string())));
        // an internal double space in argv survives
        assert_eq!(parse_ps_line("7 7 cmd  two"),
                   Some((7, 7, "cmd  two".to_string())));
        // no args column (kernel thread style) -> empty argv, still parses
        assert_eq!(parse_ps_line("9 2 "), Some((9, 2, String::new())));
        // junk / header-ish lines are dropped
        assert_eq!(parse_ps_line("  PID PPID COMMAND"), None);
        assert_eq!(parse_ps_line(""), None);
    }

    #[test]
    fn ps_parsing_uses_ascii_ifs_not_unicode_whitespace() {
        // macOS `ps -o args=` passes NBSP / U+2028 / U+2000 / U+3000 through
        // verbatim; bash `read` (ASCII IFS) KEEPS a leading one in the args
        // field, so the parser must too — a Unicode `trim_start` here diverges
        // from bash at shell detection on a pathological argv0.
        assert_eq!(parse_ps_line("501 1 \u{a0}-bash --norc"),
                   Some((501, 1, "\u{a0}-bash --norc".to_string())));
        // pid/ppid still split on ASCII space; internal Unicode ws survives
        assert_eq!(parse_ps_line("7 7 cmd\u{2000}two"),
                   Some((7, 7, "cmd\u{2000}two".to_string())));
        // a leading ASCII tab before a field is IFS and IS stripped, like bash
        assert_eq!(parse_ps_line("\t3 4 x"), Some((3, 4, "x".to_string())));
    }

    #[test]
    fn ps_backend_unicode_ws_argv0_is_not_a_shell_matching_bash() {
        // argv0 "\u{a0}-bash" is NOT a shell to bash's `^-?…sh$` (the leading
        // NBSP breaks the anchor), so it must NOT descend to the child — the
        // pane shows its own line, with the NBSP trimmed by the shared tail
        // exactly as bash's `[[:space:]]` trim does in a UTF-8 locale.
        let mut r = ps_resolver(&[
            (100, 1, "\u{a0}-bash --norc -c sleep"),
            (200, 100, "sleep 99999"),
        ]);
        assert_eq!(r.full_command(100, "bash"), "-bash --norc -c sleep");
    }

    #[test]
    fn ps_backend_descends_from_shell_to_first_child() {
        // pane pid 100 is zsh; its first child (in ps order) is the command
        let mut r = ps_resolver(&[
            (100, 1, "-zsh"),
            (200, 100, "nvim src/main.rs"),
            (201, 100, "some-later-child"),
        ]);
        assert_eq!(r.full_command(100, "zsh"), "nvim src/main.rs");
    }

    #[test]
    fn ps_backend_non_shell_shows_own_argv() {
        let mut r = ps_resolver(&[(300, 1, "sleep 602")]);
        assert_eq!(r.full_command(300, "sleep"), "sleep 602");
    }

    #[test]
    fn ps_backend_shell_without_children_shows_the_shell() {
        let mut r = ps_resolver(&[(400, 1, "bash --norc --noprofile -i")]);
        assert_eq!(r.full_command(400, "bash"), "bash --norc --noprofile -i");
    }

    #[test]
    fn ps_backend_missing_pid_falls_back_to_short() {
        let mut r = ps_resolver(&[(1, 0, "/sbin/init")]);
        assert_eq!(r.full_command(99999, "weechat"), "weechat");
    }

    #[test]
    fn ps_backend_first_child_preserves_ps_order() {
        // bash takes ${children%% *} == the FIRST child seen in ps output
        let mut r = ps_resolver(&[
            (10, 1, "zsh"),
            (30, 10, "first"),
            (20, 10, "second"),
        ]);
        assert_eq!(r.full_command(10, "zsh"), "first");
    }
}
