//! Colour handling, mirroring the bash `sgr_of`/`esc`/`escb` helpers exactly.
//!
//! A configured value is a hex `#rrggbb`, a 256-colour index, or `-1`/`default`
//! (inherit the terminal, rendered as no escape at all).

use std::env;

pub const RST: &str = "\x1b[0m";
pub const DIM: &str = "\x1b[2m";
pub const BOLD: &str = "\x1b[1m";

/// `#rrggbb` -> "38;2;r;g;b", "NNN" -> "38;5;NNN", -1/default/empty -> "".
fn sgr_of(v: &str) -> String {
    let b = v.as_bytes();
    if b.len() == 7 && b[0] == b'#' && v[1..].chars().all(|c| c.is_ascii_hexdigit()) {
        let r = u8::from_str_radix(&v[1..3], 16).unwrap_or(0);
        let g = u8::from_str_radix(&v[3..5], 16).unwrap_or(0);
        let bl = u8::from_str_radix(&v[5..7], 16).unwrap_or(0);
        return format!("38;2;{};{};{}", r, g, bl);
    }
    if v.is_empty() || v == "-1" || v == "default" || !v.chars().all(|c| c.is_ascii_digit()) {
        return String::new();
    }
    format!("38;5;{}", v)
}

/// Coloured escape, or empty when the colour is "inherit".
fn esc(v: &str) -> String {
    let s = sgr_of(v);
    if s.is_empty() { String::new() } else { format!("\x1b[{}m", s) }
}

/// Bold + coloured.  Note bash emits `\e[1m` even when the colour is inherit.
fn escb(v: &str) -> String {
    let s = sgr_of(v);
    if s.is_empty() { "\x1b[1m".to_string() } else { format!("\x1b[1;{}m", s) }
}

fn opt(name: &str, default: &str) -> String {
    match env::var(name) {
        Ok(v) if !v.is_empty() => v,
        _ => default.to_string(),
    }
}

pub struct Palette {
    pub dim_cmd: String,
    pub bold_amber: String,
    pub marker: String,
    pub dim_path: String,
    pub dim_ssh: String,
    pub dim_edit: String,
    pub dim_git: String,
    pub dim_tree: String,
    pub bold_red: String,
    pub sep: String,
}

impl Palette {
    pub fn from_env() -> Self {
        let accent = opt("INTERDIMUX_COLOR_ACCENT", "173");
        let path = opt("INTERDIMUX_COLOR_PATH", "180");
        let git = opt("INTERDIMUX_COLOR_GIT", "140");
        let ssh = opt("INTERDIMUX_COLOR_SSH", "109");
        let editor = opt("INTERDIMUX_COLOR_EDITOR", "150");
        let danger = opt("INTERDIMUX_COLOR_DANGER", "167");
        let tree = opt("INTERDIMUX_COLOR_TREE", "240");
        let separator = opt("INTERDIMUX_COLOR_SEPARATOR", "245");
        Palette {
            dim_cmd: esc(&accent),
            bold_amber: escb(&accent),
            marker: escb(&accent),
            dim_path: esc(&path),
            dim_ssh: esc(&ssh),
            dim_edit: esc(&editor),
            dim_git: esc(&git),
            dim_tree: esc(&tree),
            bold_red: escb(&danger),
            sep: format!("{}│{}", esc(&separator), RST),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sgr_forms_match_bash() {
        assert_eq!(sgr_of("173"), "38;5;173");
        assert_eq!(sgr_of("#e78a4e"), "38;2;231;138;78");
        assert_eq!(sgr_of("-1"), "");
        assert_eq!(sgr_of("default"), "");
        assert_eq!(sgr_of(""), "");
        // a non-numeric, non-hex value is "inherit" in bash's case statement too
        assert_eq!(sgr_of("brightred"), "");
    }

    #[test]
    fn escapes_match_bash() {
        assert_eq!(esc("173"), "\x1b[38;5;173m");
        assert_eq!(esc("-1"), "");
        // bash's escb emits a bare bold when the colour is inherit
        assert_eq!(escb("-1"), "\x1b[1m");
        assert_eq!(escb("167"), "\x1b[1;38;5;167m");
    }

    #[test]
    fn hex_must_be_exactly_six_digits() {
        assert_eq!(sgr_of("#abc"), "");
        assert_eq!(sgr_of("#gggggg"), "");
    }
}
