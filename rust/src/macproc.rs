//! Native macOS command resolution — the O(panes), fork-free backend.
//!
//! The ps backend (proc.rs) forks `ps -eo` and reads the argv of EVERY process
//! on the host before the first row can emit (~100 ms on a busy Mac).  Here we
//! ask the kernel directly, per pane:
//!   * argv          -> sysctl(KERN_PROCARGS2, pid)
//!   * first child   -> proc_listpids(PROC_PPID_ONLY, pid)
//! so cost scales with pane count, not host load — the same win `/proc` gives
//! Linux.
//!
//! Byte-parity is the hard part.  The bash FALLBACK renderer has no libproc; it
//! uses `ps`.  So this backend must reproduce, exactly, how macOS `ps -o args=`
//! renders a command line — otherwise the rust-vs-bash parity suite breaks:
//!   * argv is argv[0..argc] from KERN_PROCARGS2, joined by single spaces (NOT
//!     the exec_path that precedes them — a login shell's argv[0] is "-zsh").
//!   * control bytes are escaped `ps`-style (see `ps_vis`), derived empirically
//!     from macOS `ps` on this host: tab -> \011, newline -> \012, every other
//!     control byte and 0x7f -> caret notation, printable/valid-UTF-8 bytes
//!     verbatim.
//!   * the first child is the lowest-pid child.  `ps -eo` orders processes by
//!     (controlling tty, pid), so lowest-pid == ps's first child for every
//!     ordinary multi-child shell (jobs, pipelines, foreground+background — all
//!     share the pane tty and stay pid-ascending).  It differs ONLY when a
//!     sibling has DETACHED from the pane tty via setsid() yet stays parented to
//!     the shell (dtach/abduco-style, single-setsid daemons): ps then lists the
//!     no-tty sibling first while we keep the lower-pid on-tty child.  Both are
//!     valid direct children and the row's SPEC/target is identical either way,
//!     so this is an accepted, display-only divergence (arguably the better pick
//!     — the on-tty command over a detached daemon).
//!
//! Two accepted, display-only divergences from `ps`, neither reachable by a real
//! command and neither able to break the row contract:
//!   * the multi-child / setsid case above.
//!   * argv that is NOT valid UTF-8 (binary/Latin-1 argv).  `ps` locale-escapes
//!     such bytes (0x80 -> "M^@", …) in a way that depends on the caller's
//!     locale; we instead map invalid bytes to U+FFFD (`from_utf8_lossy`), like
//!     the Linux /proc backend, AFTER escaping every control byte — so the row
//!     stays contract-safe.  ASCII and valid UTF-8 (accents, CJK) render
//!     byte-for-byte as `ps` does.

/// Escape a byte string the way macOS `ps -o args=` does.  Platform-independent
/// pure logic, so it is unit-tested on every CI host, not just macOS.
pub fn ps_vis(bytes: &[u8]) -> String {
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    for &b in bytes {
        match b {
            b'\t' => out.extend_from_slice(b"\\011"),
            b'\n' => out.extend_from_slice(b"\\012"),
            // every other C0 control byte, plus DEL, as caret notation
            0x00..=0x1f | 0x7f => {
                out.push(b'^');
                out.push(b ^ 0x40);
            }
            // printable ASCII and every high (UTF-8) byte pass through verbatim
            _ => out.push(b),
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(target_os = "macos")]
mod imp {
    use std::os::raw::{c_int, c_uint, c_void};
    use std::ptr;

    const CTL_KERN: c_int = 1;
    const KERN_ARGMAX: c_int = 8;
    const KERN_PROCARGS2: c_int = 49;
    const PROC_PPID_ONLY: u32 = 6;

    extern "C" {
        fn sysctl(
            name: *mut c_int,
            namelen: c_uint,
            oldp: *mut c_void,
            oldlenp: *mut usize,
            newp: *mut c_void,
            newlen: usize,
        ) -> c_int;
        // libproc, part of libSystem — no extra link directive needed.
        fn proc_listpids(typ: u32, typeinfo: u32, buffer: *mut c_void, buffersize: c_int) -> c_int;
    }

    /// Buffer size for a KERN_PROCARGS2 read — the kernel's argument-area max.
    pub fn argmax() -> usize {
        let mut mib = [CTL_KERN, KERN_ARGMAX];
        let mut val: c_int = 0;
        let mut size = std::mem::size_of::<c_int>();
        let rc = unsafe {
            sysctl(
                mib.as_mut_ptr(),
                mib.len() as c_uint,
                &mut val as *mut _ as *mut c_void,
                &mut size,
                ptr::null_mut(),
                0,
            )
        };
        if rc == 0 && val > 0 {
            val as usize
        } else {
            256 * 1024 // conservative fallback; historical ARG_MAX
        }
    }

    /// `ps`-style joined+escaped argv of `pid`, or None when it cannot be read
    /// (the process is gone, or it belongs to another uid — same cases where the
    /// caller falls back to tmux's short command).  `buf` is a reusable scratch
    /// buffer sized to `argmax()`.
    pub fn pid_argv(pid: u32, buf: &mut Vec<u8>) -> Option<String> {
        if pid == 0 {
            return None;
        }
        let mut mib = [CTL_KERN, KERN_PROCARGS2, pid as c_int];
        let mut size = buf.len();
        let rc = unsafe {
            sysctl(
                mib.as_mut_ptr(),
                mib.len() as c_uint,
                buf.as_mut_ptr() as *mut c_void,
                &mut size,
                ptr::null_mut(),
                0,
            )
        };
        if rc != 0 || size < 4 {
            return None;
        }
        let data = &buf[..size];
        // Layout: [argc: c_int][exec_path\0][pad\0...][argv0\0 argv1\0 ...][env...]
        let argc = i32::from_ne_bytes([data[0], data[1], data[2], data[3]]);
        if argc <= 0 {
            return None;
        }
        let mut p = 4usize;
        // skip the exec_path string (NOT shown by ps) ...
        while p < data.len() && data[p] != 0 {
            p += 1;
        }
        // ... and the run of NUL padding after it
        while p < data.len() && data[p] == 0 {
            p += 1;
        }
        // read exactly argc NUL-terminated argv entries and join with one space
        let mut joined: Vec<u8> = Vec::new();
        for i in 0..argc {
            if p >= data.len() {
                break;
            }
            let start = p;
            while p < data.len() && data[p] != 0 {
                p += 1;
            }
            if i > 0 {
                joined.push(b' ');
            }
            joined.extend_from_slice(&data[start..p]);
            p += 1; // step over the NUL
        }
        if joined.is_empty() {
            return None;
        }
        Some(super::ps_vis(&joined))
    }

    /// The lowest-pid direct child of `pid`, or None.  Two syscalls: size, fetch.
    pub fn first_child(pid: u32) -> Option<u32> {
        let need = unsafe { proc_listpids(PROC_PPID_ONLY, pid, ptr::null_mut(), 0) };
        if need <= 0 {
            return None;
        }
        // slack in case a child spawns between the sizing call and the fetch
        let cap = need as usize / std::mem::size_of::<c_int>() + 8;
        let mut pids = vec![0 as c_int; cap];
        let got = unsafe {
            proc_listpids(
                PROC_PPID_ONLY,
                pid,
                pids.as_mut_ptr() as *mut c_void,
                (pids.len() * std::mem::size_of::<c_int>()) as c_int,
            )
        };
        if got <= 0 {
            return None;
        }
        let n = got as usize / std::mem::size_of::<c_int>();
        pids.truncate(n.min(pids.len()));
        pids.into_iter().filter(|&p| p > 0).map(|p| p as u32).min()
    }

    /// libproc is usable if we can read our own argv.  Cheap self-test, run once.
    pub fn available() -> bool {
        let mut buf = vec![0u8; argmax()];
        pid_argv(std::process::id(), &mut buf).is_some()
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    // Stubs so the resolver compiles and links on Linux/other; the /proc or ps
    // backends are used there, and available() being false means these are never
    // called at runtime.
    pub fn argmax() -> usize {
        0
    }
    pub fn pid_argv(_pid: u32, _buf: &mut Vec<u8>) -> Option<String> {
        None
    }
    pub fn first_child(_pid: u32) -> Option<u32> {
        None
    }
    pub fn available() -> bool {
        false
    }
}

pub use imp::{argmax, available, first_child, pid_argv};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ps_vis_matches_macos_ps_escaping() {
        // derived byte-for-byte from macOS `ps -o args=` on the dev host
        assert_eq!(ps_vis(b"plain text"), "plain text");
        assert_eq!(ps_vis(b"a\tb"), "a\\011b"); // tab -> backslash-octal
        assert_eq!(ps_vis(b"a\nb"), "a\\012b"); // newline -> backslash-octal
        assert_eq!(ps_vis(b"c\x1fd"), "c^_d"); // 0x1f -> caret (^ + (0x1f^0x40))
        assert_eq!(ps_vis(b"e\x01f"), "e^Af"); // 0x01 -> ^A
        assert_eq!(ps_vis(b"g\x1bh"), "g^[h"); // ESC -> ^[
        assert_eq!(ps_vis(b"i\x7fj"), "i^?j"); // DEL -> ^?
        assert_eq!(ps_vis(b"k\rl"), "k^Ml"); // CR -> ^M (NOT octal, unlike tab/nl)
    }

    #[test]
    fn ps_vis_preserves_valid_utf8_like_ps() {
        // Valid UTF-8 argv — the only non-ASCII a real command carries — passes
        // through byte-for-byte, exactly as macOS `ps -o args=` renders it, so
        // libproc and the bash+ps fallback show real commands identically.
        assert_eq!(ps_vis("é".as_bytes()), "é");
        assert_eq!(ps_vis("\u{a0}-bash".as_bytes()), "\u{a0}-bash");
        assert_eq!(ps_vis("café-über-日本.txt".as_bytes()), "café-über-日本.txt");
    }

    #[test]
    fn ps_vis_invalid_utf8_is_lossy_but_row_safe() {
        // For argv that is NOT valid UTF-8 (binary/Latin-1 — never a real
        // command) we deliberately diverge from ps's locale-dependent byte
        // escaping and map invalid bytes to U+FFFD, matching the /proc backend.
        // What MUST hold: every control byte is still escaped and no raw
        // row-breaker survives.  (The earlier test here was tautological — it
        // compared ps_vis's output against from_utf8_lossy of the same bytes,
        // i.e. its own implementation — so it proved nothing about this class.)
        let out = ps_vis(b"cmd\x80\xff\x1f-x");
        assert!(out.contains('\u{fffd}'), "invalid bytes become U+FFFD: {:?}", out);
        assert!(out.contains("^_"), "the 0x1f control byte is still escaped: {:?}", out);
        for c in ['\n', '\t', '\x1f', '\x1e', '\0'] {
            assert!(!out.contains(c), "no raw row-breaker survives: {:?} in {:?}", c, out);
        }
    }

    #[test]
    fn ps_vis_never_lets_a_row_breaker_through() {
        for bad in [b"x\ny".as_slice(), b"x\ty", b"x\x1fy", b"x\x1ey"] {
            let out = ps_vis(bad);
            assert!(!out.contains('\n'));
            assert!(!out.contains('\t'));
            assert!(!out.contains('\x1f'));
            assert!(!out.contains('\x1e'));
        }
    }
}
