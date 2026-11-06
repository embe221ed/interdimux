//! Standalone, key-driven dashboard. No target finder exists behind this menu.
use std::process::{Command, Stdio};

use crate::navigator::Mode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Choice {
    Mode(Mode),
    NextAgent,
}

struct Entry {
    key: char,
    label: String,
    detail: String,
    choice: Choice,
}

fn entry(key: char, label: &str, detail: &str, mode: Mode) -> Entry {
    Entry {
        key,
        label: label.into(),
        detail: detail.into(),
        choice: Choice::Mode(mode),
    }
}

fn groups(tmux: bool, attention: usize) -> Vec<(&'static str, Vec<Entry>)> {
    let mut manage = vec![
        entry('r', "Rename", "choose target", Mode::Rename),
        entry('i', "Close", "confirm first", Mode::Close),
        entry('w', "Swap", "windows / panes", Mode::Swap),
        entry('z', "Zoom", "toggle pane", Mode::Zoom),
    ];
    if tmux {
        manage.push(entry('d', "Detach", "session", Mode::Detach));
    }
    vec![
        (
            "NAVIGATE",
            vec![
                entry('s', "Switch", "all open targets", Mode::Switch),
                entry(
                    'e',
                    "Agents",
                    &format!("{attention} need attention"),
                    Mode::Agents,
                ),
                Entry {
                    key: 'j',
                    label: "Next agent".into(),
                    detail: "jump to attention".into(),
                    choice: Choice::NextAgent,
                },
                entry('n', "New session", "project directory", Mode::Directories),
            ],
        ),
        ("MANAGE", manage),
        (
            "AUTOMATE",
            vec![
                entry('t', "Send", "text or a key", Mode::Send),
                entry('a', "Schedule", "send later", Mode::Schedule),
                entry('o', "Jobs", "output / cancel", Mode::Jobs),
            ],
        ),
        (
            "TOOLS",
            vec![entry('h', "Health", "tools & setup", Mode::Health)],
        ),
    ]
}

fn cell(text: &str, width: usize, color: &str) -> String {
    let text = crate::text::truncate(text, width);
    format!(
        "{color}{text}\x1b[0m{}",
        " ".repeat(width.saturating_sub(crate::text::width(&text)))
    )
}

fn section(title: &str, entries: &[Entry], width: usize) -> Vec<String> {
    let palette = crate::palette::Palette::native();
    let mut lines = vec![cell(title, width, &palette.dim_path)];
    for e in entries {
        let label = crate::text::truncate(&e.label, width.saturating_sub(5));
        let label_width = 5 + crate::text::width(&label);
        let remaining = width.saturating_sub(label_width + 2);
        let detail = crate::text::truncate(&e.detail, remaining);
        let key_color = if e.key == 'i' {
            &palette.bold_red
        } else {
            &palette.bold_amber
        };
        let detail_width = if detail.is_empty() {
            0
        } else {
            2 + crate::text::width(&detail)
        };
        let detail = if detail.is_empty() {
            String::new()
        } else {
            format!("  \x1b[2m{detail}\x1b[0m")
        };
        lines.push(format!(
            "{}[{}]\x1b[0m  {}{}{}",
            key_color,
            e.key,
            label,
            detail,
            " ".repeat(width.saturating_sub(label_width + detail_width))
        ));
    }
    lines
}

fn header(groups: &[(&str, Vec<Entry>)], columns: usize, tmux: bool) -> String {
    let wide = columns >= 62;
    let width = columns.saturating_sub(8).max(8);
    let palette = crate::palette::Palette::native();
    let mut lines = vec![
        format!(
            "{}INTERDIMUX\x1b[0m  \x1b[2m{}\x1b[0m",
            palette.bold_amber,
            if tmux { "tmux" } else { "Rex" }
        ),
        cell("Choose a tool · press its key", width, "\x1b[2m"),
        String::new(),
    ];
    if wide {
        let left_width = (width - 4) / 2;
        let right_width = width - 4 - left_width;
        for pair in groups.chunks(2) {
            let left = section(pair[0].0, &pair[0].1, left_width);
            let right = section(pair[1].0, &pair[1].1, right_width);
            for index in 0..left.len().max(right.len()) {
                lines.push(format!(
                    "{}    {}",
                    left.get(index)
                        .cloned()
                        .unwrap_or_else(|| " ".repeat(left_width)),
                    right.get(index).cloned().unwrap_or_default()
                ));
            }
            lines.push(String::new());
        }
    } else {
        for (title, entries) in groups {
            lines.extend(section(title, entries, width));
        }
    }
    while lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    lines.join("\n")
}

fn terminal_rows() -> Option<usize> {
    #[cfg(any(target_os = "macos", target_os = "linux", target_os = "freebsd"))]
    {
        #[repr(C)]
        struct Size {
            rows: u16,
            columns: u16,
            x: u16,
            y: u16,
        }
        extern "C" {
            fn ioctl(
                fd: std::os::raw::c_int,
                request: std::os::raw::c_ulong,
                ...
            ) -> std::os::raw::c_int;
        }
        #[cfg(any(target_os = "macos", target_os = "freebsd"))]
        let request = 0x4008_7468;
        #[cfg(target_os = "linux")]
        let request = 0x5413;
        let mut size = Size {
            rows: 0,
            columns: 0,
            x: 0,
            y: 0,
        };
        // SAFETY: TIOCGWINSZ writes exactly this four-u16 winsize structure.
        if unsafe { ioctl(2, request, &mut size) } == 0 && size.rows > 0 {
            return Some(usize::from(size.rows));
        }
    }
    None
}

pub(crate) fn choose(
    tmux: bool,
    attention: usize,
    keep_screen: bool,
    columns: usize,
) -> Result<Option<Choice>, String> {
    let groups = groups(tmux, attention);
    let entries: Vec<_> = groups.iter().flat_map(|(_, entries)| entries).collect();
    // A large popup still gets a compact card. Margins center it without
    // changing the native terminal's geometry or waiting for another resize.
    let horizontal = columns.saturating_sub(88) / 2;
    let content_columns = columns.saturating_sub(2 * horizontal);
    let header = header(&groups, content_columns, tmux);
    let vertical = terminal_rows()
        .unwrap_or(24)
        .saturating_sub(header.lines().count() + 4)
        / 2;
    let mut bindings = vec![
        "esc:abort".into(),
        "q:abort".into(),
        "ctrl-c:abort".into(),
        "ctrl-g:abort".into(),
        "ctrl-z:ignore".into(),
        "enter:ignore".into(),
    ];
    for e in &entries {
        bindings.push(format!("{}:print({})+accept", e.key, e.key));
    }
    let fzf = crate::env_text("INTERDIMUX_FZF_BIN");
    let mut command = Command::new(if fzf.is_empty() { "fzf" } else { &fzf });
    command
        .args([
            "--ansi",
            "--layout=reverse",
            "--height=100%",
            "--style=minimal",
            "--border=none",
            "--padding=1,3",
            "--no-input",
            "--disabled",
            "--info=hidden",
            "--no-separator",
            "--no-scrollbar",
            "--pointer=",
            "--footer=Press a key · Esc / q close",
            "--footer-border=none",
        ])
        .arg(crate::palette::NativeTheme::from_env().fzf_color())
        .arg(format!("--margin={vertical},{horizontal}"))
        .arg(format!("--header={header}"))
        .arg(format!("--bind={}", bindings.join(",")))
        .env_remove("FZF_DEFAULT_OPTS")
        .env_remove("FZF_DEFAULT_OPTS_FILE")
        .env_remove("FZF_DEFAULT_COMMAND")
        .env_remove("FZF_CURRENT_ITEM")
        .env_remove("FZF_RAW")
        // An empty pipe/null input prevents fzf's default directory walker.
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    if keep_screen {
        command.arg("--no-clear");
    }
    if keep_screen && std::env::var_os("ESCDELAY").is_none() {
        command.env("ESCDELAY", "10");
    }
    let output = command
        .output()
        .map_err(|e| format!("cannot start Dashboard: {e}"))?;
    let route = std::str::from_utf8(&output.stdout)
        .map_err(|_| "Dashboard returned invalid UTF-8")?
        .trim();
    if !route.is_empty() {
        return entries
            .iter()
            .find(|e| route == e.key.to_string())
            .map(|e| Some(e.choice))
            .ok_or_else(|| "Dashboard returned an unknown command".into());
    }
    match output.status.code() {
        Some(0 | 1 | 130) => Ok(None),
        status => Err(format!(
            "Dashboard failed with status {status:?}; fzf 0.74+ is required"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_keys_are_unique_and_rex_hides_detach() {
        let sections = groups(false, 3);
        let entries: Vec<_> = sections.iter().flat_map(|(_, e)| e).collect();
        assert_eq!(
            entries.iter().map(|e| e.key).collect::<String>(),
            "sejnriwztaoh"
        );
        assert!(entries
            .iter()
            .any(|e| e.key == 'e' && e.detail.contains('3')));
        let tmux = groups(true, 0);
        assert!(tmux
            .iter()
            .flat_map(|(_, e)| e)
            .any(|e| e.key == 'd' && e.choice == Choice::Mode(Mode::Detach)));
    }
    #[test]
    fn grouped_layout_is_compact_and_narrow_layout_keeps_every_key() {
        let entries = groups(false, 0);
        let wide = header(&entries, 100, false);
        assert!(wide.lines().count() <= 16);
        let narrow = header(&entries, 40, false);
        for key in "sejnriwztaoh".chars() {
            assert!(narrow.contains(&format!("[{key}]")));
        }
        assert!(!wide.contains("Search"));
    }
}
