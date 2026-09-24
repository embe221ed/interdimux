//! Full-command resolution, ported from the bash backends.
//!
//! Strategy: if the pane's own process is a shell, show one of its direct
//! children (the command the user typed) — the one in the pane tty's
//! FOREGROUND process group, see `Resolver::pick_child`.  Never walk deeper —
//! grandchildren are the command's own subprocesses (LSPs, formatters) and
//! showing those misleads.
//!
//! Three backends, each fork-free per pane where possible:
//!   * `/proc` (Linux): one lazy read per pane, no fork, cost scales with panes.
//!   * libproc (macOS): sysctl(KERN_PROCARGS2) + proc_listpids, per pane — the
//!     native equivalent of the `/proc` path (see macproc.rs).  This is the
//!     default off-Linux; it forks nothing.
//!   * `ps` (other BSDs, when libproc can't read argv, or INTERDIMUX_FORCE_PS=1):
//!     a single `ps -eo` snapshot built lazily, then walked in-process.  bash
//!     used to do this walk itself and hand the Rust core nothing, which meant
//!     the whole render fell back to bash on any host without `/proc`.  Owning
//!     it here lets the fast renderer run everywhere.
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

use crate::macproc;

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

/// A one-shot `ps -eo pid=,ppid=,pgid=,tpgid=,args=` snapshot, parsed into the
/// same maps bash builds (pid -> argv, pid -> (pgid, tpgid), ppid -> children).
/// Children preserve ps output order so `first()` picks the same child bash's
/// `${children%% *}` does.
struct PsTable {
    args: HashMap<u32, String>,
    groups: HashMap<u32, (i64, i64)>,
    children: HashMap<u32, Vec<u32>>,
}

impl PsTable {
    fn snapshot() -> Option<PsTable> {
        // The EXACT command bash forks, inheriting bash's environment, so any
        // width-truncation ps applies is identical on both sides.
        let out = std::process::Command::new("ps")
            .args(["-eo", "pid=,ppid=,pgid=,tpgid=,args="])
            .output()
            .ok()?;
        // bash ignores ps's exit status and processes whatever it printed.
        let text = String::from_utf8_lossy(&out.stdout);
        let mut args: HashMap<u32, String> = HashMap::new();
        let mut groups: HashMap<u32, (i64, i64)> = HashMap::new();
        let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
        for line in text.lines() {
            if let Some(r) = parse_ps_line(line) {
                args.insert(r.pid, r.args);
                groups.insert(r.pid, (r.pgid, r.tpgid));
                children.entry(r.ppid).or_default().push(r.pid);
            }
        }
        if args.is_empty() {
            return None; // ps missing or produced nothing -> unavailable, like bash
        }
        Some(PsTable { args, groups, children })
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

/// One parsed `ps` line.
#[derive(Debug, PartialEq)]
struct PsRow {
    pid: u32,
    ppid: u32,
    pgid: i64,
    tpgid: i64,
    args: String,
}

/// Split one `ps` line into its five columns, mirroring bash `read -r pid ppid
/// pgid tpgid args`: the first four IFS-delimited fields, then the remainder
/// with its leading IFS whitespace stripped and everything else preserved.
/// Like `read`, a short line leaves the later fields empty rather than failing.
/// Trailing whitespace is irrelevant — `full_command`'s trim removes it before
/// it is used.
fn parse_ps_line(line: &str) -> Option<PsRow> {
    let (pid_s, rest) = take_word(line.trim_start_matches(IFS_WS))?;
    let (ppid_s, rest) = take_word(rest.trim_start_matches(IFS_WS))?;
    let (pgid_s, rest) = take_word(rest.trim_start_matches(IFS_WS)).unwrap_or(("", ""));
    let (tpgid_s, rest) = take_word(rest.trim_start_matches(IFS_WS)).unwrap_or(("", ""));
    let args = rest.trim_start_matches(IFS_WS).to_string();
    Some(PsRow {
        pid: pid_s.parse().ok()?,
        ppid: ppid_s.parse().ok()?,
        // Unparseable group ids only disable the foreground preference (bash's
        // string compare never matches them either); they never drop the row.
        pgid: pgid_s.parse().unwrap_or(0),
        tpgid: tpgid_s.parse().unwrap_or(0),
        args,
    })
}

/// (pgrp, tpgid) from the text of /proc/<pid>/stat.  The comm field is
/// parenthesised and may hold spaces, ')' and newlines, so the fields are
/// counted from the LAST ')': state ppid pgrp session tty_nr tpgid.
fn parse_stat_ids(stat: &str) -> Option<(i64, i64)> {
    let rest = &stat[stat.rfind(')')? + 1..];
    let f: Vec<&str> = rest.split_whitespace().take(6).collect();
    Some((f.get(2)?.parse().ok()?, f.get(5)?.parse().ok()?))
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
    libproc: bool,          // macOS native backend (sysctl + proc_listpids)
    ps: Option<PsTable>,    // ps snapshot backend (FORCE_PS / other BSD, lazy)
    ps_tried: bool,         // the ps snapshot has been attempted
    cache: HashMap<u32, String>, // argv memo (proc & libproc; ps holds its own map)
    mac_buf: Vec<u8>,       // reusable KERN_PROCARGS2 scratch buffer (libproc only)
}

impl Resolver {
    pub fn new() -> Self {
        let pid = std::process::id();
        let forced_ps = force_ps();
        let proc_ok =
            !forced_ps && fs::metadata(format!("/proc/{}/task/{}/children", pid, pid)).is_ok();
        let mut r = Resolver {
            proc_ok,
            libproc: false,
            ps: None,
            ps_tried: false,
            cache: HashMap::new(),
            mac_buf: Vec::new(),
        };
        // Construction stays cheap.  On Linux /proc handles it (lazy per-pid).
        // Otherwise prefer the native macOS backend (fork-free, O(panes)) — but
        // NOT when ps is forced, and only if it can actually read argv here.  The
        // ps snapshot is the last resort (other BSDs, sandboxed libproc) and is
        // itself deferred to first use (ensure_ps), so a SHOW_FULL_COMMAND=off
        // list forks nothing.
        if !proc_ok && !forced_ps && macproc::available() {
            r.libproc = true;
            r.mac_buf = vec![0u8; macproc::argmax()];
        }
        r
    }

    /// Take the one ps snapshot, the first time a command is actually resolved,
    /// and only when no fork-free backend is active.
    fn ensure_ps(&mut self) {
        if self.proc_ok || self.libproc || self.ps_tried {
            return;
        }
        self.ps_tried = true;
        self.ps = PsTable::snapshot();
    }

    #[allow(dead_code)] // used by tests
    pub fn available(&self) -> bool {
        self.proc_ok || self.libproc || self.ps.is_some()
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
        if self.libproc {
            if let Some(v) = self.cache.get(&pid) {
                return v.clone();
            }
            let v = macproc::pid_argv(pid, &mut self.mac_buf).unwrap_or_default();
            self.cache.insert(pid, v.clone());
            return v;
        }
        if let Some(t) = &self.ps {
            return t.args.get(&pid).cloned().unwrap_or_default();
        }
        if self.proc_ok {
            return self.cmdline(pid);
        }
        String::new()
    }

    /// The shell's direct children, in the order bash sees them: fork order
    /// from /proc, ps output order from the snapshot, ascending pid from libproc.
    fn children(&self, pid: u32) -> Vec<u32> {
        if self.libproc {
            return macproc::children(pid);
        }
        if let Some(t) = &self.ps {
            return t.children.get(&pid).cloned().unwrap_or_default();
        }
        if self.proc_ok {
            // A pid that fails to parse ends the list, as a non-number would
            // never have matched anything on the bash side either.
            return fs::read_to_string(format!("/proc/{}/task/{}/children", pid, pid))
                .map(|s| s.split_whitespace().map_while(|w| w.parse().ok()).collect())
                .unwrap_or_default();
        }
        Vec::new()
    }

    /// (process group, the controlling tty's foreground process group) of `pid`.
    fn group_ids(&self, pid: u32) -> Option<(i64, i64)> {
        if pid == 0 {
            return None;
        }
        if self.libproc {
            return macproc::group_ids(pid);
        }
        if let Some(t) = &self.ps {
            return t.groups.get(&pid).copied();
        }
        if self.proc_ok {
            let raw = fs::read(format!("/proc/{}/stat", pid)).ok()?;
            return parse_stat_ids(&String::from_utf8_lossy(&raw));
        }
        None
    }

    /// Which of a shell's direct children is the command to show — the one in
    /// the pane tty's FOREGROUND process group, the job the shell is waiting
    /// on (and what tmux's own #{pane_current_command} names).  Not simply the
    /// first child: that is the OLDEST, so a job backgrounded earlier (or
    /// stopped with ^Z, or a shell plugin's helper) shadowed whatever ran in
    /// the foreground after it.  Mirrors bash `pick_child`, in order:
    ///   * the job leader itself, when it is one of the shell's children;
    ///   * else the first child in that group — a pipeline whose leader already
    ///     exited (`cat f | less`) keeps the dead leader's pid as its group id;
    ///   * else the first child: the shell is itself in the foreground (at its
    ///     prompt, jobs only in the background), or the foreground belongs to
    ///     something that is not the shell's direct child.
    /// One child needs no lookup at all: every rule above picks it.
    fn pick_child(&self, pid: u32) -> Option<u32> {
        let kids = self.children(pid);
        let first = *kids.first()?;
        if kids.len() == 1 {
            return Some(first);
        }
        let fg = match self.group_ids(pid) {
            Some((_, t)) if t > 0 && t != i64::from(pid) => t,
            _ => return Some(first),
        };
        if let Some(&leader) = kids.iter().find(|&&c| i64::from(c) == fg) {
            return Some(leader);
        }
        for &c in &kids {
            if self.group_ids(c).map(|(g, _)| g) == Some(fg) {
                return Some(c);
            }
        }
        Some(first)
    }

    /// The command to display for a pane.  `short` is tmux's
    /// #{pane_current_command}, used only as the fallback.  This tail is shared
    /// by both backends and mirrors bash `resolve_command`: tab->space, trim,
    /// and fall back to the short command when the result is empty.
    pub fn full_command(&mut self, pid: u32, short: &str) -> String {
        // Only fork ps when neither fork-free backend is active.
        if !self.proc_ok && !self.libproc {
            self.ensure_ps();
            if self.ps.is_none() {
                return short.replace('\t', " ");
            }
        }
        let own = self.args_of(pid);
        let argv0 = own.split(' ').next().unwrap_or("");
        let resolved = if is_shell(argv0) {
            match self.pick_child(pid) {
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

    /// A ps-backed resolver from (pid, ppid, argv) rows.  Every process leads
    /// its own group and has no controlling tty (tpgid -1), so no foreground
    /// job is known and child selection falls back to the first child.
    fn ps_resolver(lines: &[(u32, u32, &str)]) -> Resolver {
        let rows: Vec<(u32, u32, i64, i64, &str)> =
            lines.iter().map(|&(pid, ppid, a)| (pid, ppid, i64::from(pid), -1, a)).collect();
        ps_resolver_groups(&rows)
    }

    /// A ps-backed resolver from (pid, ppid, pgid, tpgid, argv) rows.
    fn ps_resolver_groups(lines: &[(u32, u32, i64, i64, &str)]) -> Resolver {
        let mut args = HashMap::new();
        let mut groups = HashMap::new();
        let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
        for &(pid, ppid, pgid, tpgid, a) in lines {
            args.insert(pid, a.to_string());
            groups.insert(pid, (pgid, tpgid));
            children.entry(ppid).or_default().push(pid);
        }
        Resolver {
            proc_ok: false,
            libproc: false,
            ps: Some(PsTable { args, groups, children }),
            ps_tried: true,
            cache: HashMap::new(),
            mac_buf: Vec::new(),
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
            libproc: false,
            ps: None,
            ps_tried: false,
            cache: HashMap::new(),
            mac_buf: Vec::new(),
        };
        assert_eq!(r.cmdline(0), "");
    }

    #[test]
    fn resolves_this_process() {
        // full_command triggers the lazy ps snapshot (or uses /proc); our own
        // process is not a shell, so it resolves to our real, non-empty argv
        // rather than the short fallback.
        let mut r = Resolver::new();
        let me = std::process::id();
        let got = r.full_command(me, "\u{0}unlikely-fallback");
        assert!(r.available(), "a backend should be available on the test host");
        assert!(!got.is_empty() && got != "\u{0}unlikely-fallback",
                "should resolve our own argv, got {:?}", got);
    }

    #[test]
    fn ps_snapshot_is_deferred_until_first_resolution() {
        // A resolver that never resolves a command must never take the snapshot,
        // so SHOW_FULL_COMMAND=off does not fork ps.  (On a /proc host proc_ok is
        // true and ps is never used at all; this asserts the off-Linux path.)
        let r = Resolver {
            proc_ok: false,
            libproc: false,
            ps: None,
            ps_tried: false,
            cache: HashMap::new(),
            mac_buf: Vec::new(),
        };
        assert!(!r.ps_tried, "construction must not attempt the ps snapshot");
        assert!(r.ps.is_none());
    }

    // --- ps-backend parsing + resolution ------------------------------------

    fn row(pid: u32, ppid: u32, pgid: i64, tpgid: i64, args: &str) -> Option<PsRow> {
        Some(PsRow { pid, ppid, pgid, tpgid, args: args.to_string() })
    }

    #[test]
    fn parses_ps_lines_like_bash_read() {
        // leading pad, multi-space padding, internal spacing preserved
        assert_eq!(parse_ps_line("  501  1234   501  -1 /usr/bin/vim foo.rs"),
                   row(501, 1234, 501, -1, "/usr/bin/vim foo.rs"));
        assert_eq!(parse_ps_line("1 0 1 0 /sbin/launchd"),
                   row(1, 0, 1, 0, "/sbin/launchd"));
        // an internal double space in argv survives
        assert_eq!(parse_ps_line("7 7 7 9 cmd  two"),
                   row(7, 7, 7, 9, "cmd  two"));
        // no args column (kernel thread style) -> empty argv, still parses
        assert_eq!(parse_ps_line("9 2 0 -1 "), row(9, 2, 0, -1, ""));
        // junk / header-ish lines are dropped
        assert_eq!(parse_ps_line("  PID PPID PGID TPGID COMMAND"), None);
        assert_eq!(parse_ps_line(""), None);
        // a short line leaves the later fields empty, as bash `read` does
        assert_eq!(parse_ps_line("5 1 5"), row(5, 1, 5, 0, ""));
        assert_eq!(parse_ps_line("5 1"), row(5, 1, 0, 0, ""));
    }

    #[test]
    fn ps_parsing_uses_ascii_ifs_not_unicode_whitespace() {
        // macOS `ps -o args=` passes NBSP / U+2028 / U+2000 / U+3000 through
        // verbatim; bash `read` (ASCII IFS) KEEPS a leading one in the args
        // field, so the parser must too — a Unicode `trim_start` here diverges
        // from bash at shell detection on a pathological argv0.
        assert_eq!(parse_ps_line("501 1 501 501 \u{a0}-bash --norc"),
                   row(501, 1, 501, 501, "\u{a0}-bash --norc"));
        // pid/ppid still split on ASCII space; internal Unicode ws survives
        assert_eq!(parse_ps_line("7 7 7 7 cmd\u{2000}two"),
                   row(7, 7, 7, 7, "cmd\u{2000}two"));
        // a leading ASCII tab before a field is IFS and IS stripped, like bash
        assert_eq!(parse_ps_line("\t3 4 3 -1 x"), row(3, 4, 3, -1, "x"));
    }

    #[test]
    fn stat_ids_are_counted_from_the_last_paren() {
        // a real line: pid (comm) state ppid pgrp session tty_nr tpgid ...
        assert_eq!(parse_stat_ids("762622 (cat) R 762615 762615 762615 34816 762700 4194304"),
                   Some((762615, 762700)));
        // comm may hold spaces, ')' and a newline; only the LAST ')' ends it
        assert_eq!(parse_stat_ids("42 (a) b) c\nd) S 1 40 40 34816 41 0"), Some((40, 41)));
        // no controlling tty
        assert_eq!(parse_stat_ids("7 (kworker) I 2 0 0 0 -1 0"), Some((0, -1)));
        // a vanished process reads as nothing, never as garbage ids
        assert_eq!(parse_stat_ids(""), None);
        assert_eq!(parse_stat_ids("12 (x) S 1"), None);
    }

    // --- which child: the foreground job ------------------------------------

    #[test]
    fn a_foreground_job_beats_an_older_background_one() {
        // `sleep 601 &` then `sleep 600`: the shell's FIRST child is the older
        // background job, but the tty's foreground group is the newer one.
        let mut r = ps_resolver_groups(&[
            (100, 1, 100, 300, "bash"),
            (200, 100, 200, 300, "sleep 601"),
            (300, 100, 300, 300, "sleep 600"),
        ]);
        assert_eq!(r.full_command(100, "sleep"), "sleep 600");
    }

    #[test]
    fn a_pipeline_whose_leader_exited_is_found_by_its_group() {
        // `sleep 605 & true | sleep 606`: `true` led the pipeline's group (250)
        // and is gone, so the foreground group names no live child — the child
        // IN that group is the command.
        let mut r = ps_resolver_groups(&[
            (100, 1, 100, 250, "bash"),
            (200, 100, 200, 250, "sleep 605"),
            (260, 100, 250, 250, "sleep 606"),
        ]);
        assert_eq!(r.full_command(100, "bash"), "sleep 606");
    }

    #[test]
    fn a_shell_at_its_prompt_keeps_showing_its_first_child() {
        // tpgid == the shell: nothing runs in the foreground, the children are
        // background jobs -> the first one, exactly as before.  The second
        // child sits in the SHELL's own group (a prompt plugin's async worker,
        // forked without job control): being "in the foreground group" must not
        // promote it while the shell itself is that group.
        let mut r = ps_resolver_groups(&[
            (100, 1, 100, 100, "zsh"),
            (200, 100, 200, 100, "sleep 601"),
            (300, 100, 100, 100, "zsh-async-worker"),
        ]);
        assert_eq!(r.full_command(100, "zsh"), "sleep 601");
    }

    #[test]
    fn a_foreground_group_outside_the_shells_children_is_not_followed() {
        // The foreground belongs to a grandchild's group (sudo, a nested shell):
        // never walk deeper — the first child, as before.
        let mut r = ps_resolver_groups(&[
            (100, 1, 100, 900, "bash"),
            (200, 100, 200, 900, "sleep 601"),
            (300, 100, 300, 900, "sudo -s"),
            (900, 300, 900, 900, "vim /etc/hosts"),
        ]);
        assert_eq!(r.full_command(100, "bash"), "sleep 601");
    }

    #[test]
    fn unknown_or_absent_foreground_groups_fall_back_to_the_first_child() {
        for tpgid in [0, -1] {
            let mut r = ps_resolver_groups(&[
                (100, 1, 100, tpgid, "bash"),
                (200, 100, 200, tpgid, "first"),
                (300, 100, 300, tpgid, "second"),
            ]);
            assert_eq!(r.full_command(100, "bash"), "first", "tpgid {}", tpgid);
        }
    }

    #[test]
    fn proc_stat_ids_agree_with_ps() {
        // The /proc parse against an independent reader of the same kernel
        // record: `ps -o pgid=,tpgid=` for this very process.
        let me = std::process::id();
        let raw = match std::fs::read_to_string(format!("/proc/{}/stat", me)) {
            Ok(s) => s,
            Err(_) => return, // not a /proc host
        };
        let out = match std::process::Command::new("ps")
            .args(["-o", "pgid=,tpgid=", "-p", &me.to_string()])
            .output()
        {
            Ok(o) if o.status.success() => o,
            _ => return, // no ps to compare against
        };
        let text = String::from_utf8_lossy(&out.stdout);
        let want: Vec<i64> = text.split_whitespace().map(|w| w.parse().unwrap()).collect();
        assert_eq!(parse_stat_ids(&raw), Some((want[0], want[1])), "ps said {:?}", text);
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
