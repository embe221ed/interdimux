//! Stable kernel birth identifiers for scheduler workers. Missing permissions
//! or unsupported platforms return None, preserving legacy PID-only behavior.

pub(crate) fn get(pid: u32) -> Option<String> {
    if pid == 0 || pid > i32::MAX as u32 {
        return None;
    }
    #[cfg(target_os = "macos")]
    {
        crate::macproc::start_time(pid).map(|(seconds, micros)| format!("macos:{seconds}:{micros}"))
    }
    #[cfg(target_os = "linux")]
    {
        use std::sync::OnceLock;
        static BOOT: OnceLock<Option<String>> = OnceLock::new();
        let boot = BOOT
            .get_or_init(|| std::fs::read_to_string("/proc/sys/kernel/random/boot_id").ok())
            .as_deref()?;
        let stat = std::fs::read(format!("/proc/{pid}/stat")).ok()?;
        linux_identity(pid, &stat, boot)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        None
    }
}

#[cfg(any(target_os = "linux", test))]
fn linux_identity(pid: u32, stat: &[u8], boot: &str) -> Option<String> {
    let boot = boot.trim();
    if boot.len() != 36
        || !boot.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
    {
        return None;
    }
    // /proc/PID/stat's parenthesized command may contain whitespace, ')', or
    // invalid UTF-8. Everything after its final ')' is positional ASCII data.
    let open = stat.iter().position(|byte| *byte == b'(')?;
    let close = stat.iter().rposition(|byte| *byte == b')')?;
    if open >= close || pid == 0 {
        return None;
    }
    let found = std::str::from_utf8(&stat[..open])
        .ok()?
        .trim()
        .parse::<u32>()
        .ok()?;
    if found != pid {
        return None;
    }
    let start = stat[close + 1..]
        .split(|byte| byte.is_ascii_whitespace())
        .filter(|field| !field.is_empty())
        .nth(19)?; // Field 22: starttime; the first field after comm is state (3).
    let ticks = std::str::from_utf8(start).ok()?.parse::<u64>().ok()?;
    Some(format!("linux:{}:{ticks}", boot.to_ascii_lowercase()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linux_stat_birth_handles_hostile_commands_and_distinguishes_boots() {
        let boot = "12345678-1234-1234-1234-123456789abc";
        let mut stat = b"42 (a strange ) name\xff) S".to_vec();
        for _ in 4..22 {
            stat.extend_from_slice(b" 0");
        }
        stat.extend_from_slice(b" 123456 999 888\n");
        assert_eq!(
            linux_identity(42, &stat, boot).as_deref(),
            Some("linux:12345678-1234-1234-1234-123456789abc:123456")
        );
        assert_ne!(
            linux_identity(42, &stat, boot),
            linux_identity(42, &stat, "87654321-1234-1234-1234-123456789abc")
        );
        assert!(linux_identity(43, &stat, boot).is_none());
        assert!(linux_identity(42, &stat, "bad boot id").is_none());
        assert!(linux_identity(42, b"42 (short) S 0", boot).is_none());
        assert!(linux_identity(42, b"42 malformed", boot).is_none());
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn actual_current_process_has_a_stable_kernel_birth() {
        let birth = get(std::process::id()).expect("kernel identity for our own process");
        assert_eq!(get(std::process::id()), Some(birth.clone()));
        assert!(birth.starts_with(if cfg!(target_os = "macos") {
            "macos:"
        } else {
            "linux:"
        }));
        assert_eq!(get(0), None);
        assert_eq!(get(u32::MAX), None);
    }
}
