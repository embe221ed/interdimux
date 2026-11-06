//! Colour handling, mirroring the bash `sgr_of`/`esc`/`escb` helpers exactly.
//!
//! A configured value is a hex `#rrggbb`, a 256-colour index, or `-1`/`default`
//! (inherit the terminal, rendered as no escape at all).

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
    match crate::env_text(name) {
        v if !v.is_empty() => v,
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
    /// the separator colour alone, for the bar between an agent row's parts
    pub sep_col: String,
}

impl Palette {
    /// Colours for the native picker. The legacy pipeline uses `from_env`.
    pub fn native() -> Self {
        NativeTheme::from_env().palette
    }

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
            sep_col: esc(&separator),
        }
    }
}

/// Native picker colours shared by its rows, previews and fzf surfaces.
///
/// `terminal` uses a Gruvbox Material orange accent over the terminal's
/// foreground, background and remaining ANSI palette.
/// `warm` retains the established warm picker colours. The caller resolves an
/// automatic backend preference before starting threads; an unresolved value
/// here deliberately keeps the warm fallback.
pub(crate) struct NativeTheme {
    /// ANSI escape for ordinary text. Empty means the terminal's foreground.
    pub primary: String,
    /// Bold ANSI accent for preview headings.
    pub preview_accent: String,
    /// ANSI colour for secondary preview text.
    pub muted: String,
    palette: Palette,
    fzf: String,
    danger: String,
    raw: String,
}

const NATIVE_COLOR_KEYS: [&str; 8] = [
    "INTERDIMUX_COLOR_ACCENT",
    "INTERDIMUX_COLOR_PATH",
    "INTERDIMUX_COLOR_GIT",
    "INTERDIMUX_COLOR_SSH",
    "INTERDIMUX_COLOR_EDITOR",
    "INTERDIMUX_COLOR_DANGER",
    "INTERDIMUX_COLOR_TREE",
    "INTERDIMUX_COLOR_SEPARATOR",
];

const TERMINAL_ACCENT: &str = "#e78a4e";

/// fzf uses commas and colons as syntax, so only admit actual colour values.
/// Keep this separate from `sgr_of`, whose legacy behaviour is intentional.
fn native_color(value: &str) -> Option<String> {
    if value == "-1" || value == "default" {
        return Some("-1".to_owned());
    }
    let bytes = value.as_bytes();
    if bytes.len() == 7 && bytes[0] == b'#' && bytes[1..].iter().all(u8::is_ascii_hexdigit) {
        return Some(value.to_ascii_lowercase());
    }
    if !bytes.is_empty() && bytes.iter().all(u8::is_ascii_digit) {
        return value.parse::<u8>().ok().map(|index| index.to_string());
    }
    None
}

impl NativeTheme {
    pub fn from_env() -> Self {
        Self::from_values(&crate::env_text("INTERDIMUX_THEME"), |name| {
            let value = crate::env_text(name);
            (!value.is_empty()).then_some(value)
        })
    }

    fn from_values(profile: &str, mut value: impl FnMut(&str) -> Option<String>) -> Self {
        let terminal = profile.trim().eq_ignore_ascii_case("terminal");
        let overrides: [Option<String>; 8] = std::array::from_fn(|i| {
            value(NATIVE_COLOR_KEYS[i]).and_then(|value| native_color(&value))
        });
        let color = |i: usize, fallback: &str| -> String {
            overrides[i].as_deref().unwrap_or(fallback).to_owned()
        };
        let defaults = if terminal {
            [TERMINAL_ACCENT, "4", "5", "6", "2", "1", "8", "8"]
        } else {
            ["173", "180", "140", "109", "150", "167", "240", "245"]
        };
        let [accent, path, git, ssh, editor, danger, tree, separator] =
            std::array::from_fn(|i| color(i, defaults[i]));
        let palette = Palette {
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
            sep_col: esc(&separator),
        };
        let fzf = if terminal {
            // The block pointer and font weight identify the focused row.
            // Preserve its ANSI colours and terminal background on both light
            // and dark themes, without a reverse-video band or fixed grey fill.
            format!(
                "--color=fg:-1,bg:-1,hl:{accent},fg+:-1:regular:bold,bg+:-1,hl+:{accent}:bold,info:{separator},prompt:{accent},pointer:{accent},marker:{editor},spinner:{ssh},header:-1,border:{separator},label:-1,footer:{separator},gutter:-1,separator:{separator},ghost:{tree},preview-fg:-1,preview-bg:-1,preview-border:{separator},preview-label:-1"
            )
        } else {
            let accent = color(0, "#d8a657");
            let header = color(1, "#d4be98");
            let editor = color(4, "#a9b665");
            let ssh = color(3, "#7daea3");
            let muted = color(7, "#928374");
            let border = color(7, "#504945");
            let ghost = color(6, "#7c6f64");
            format!(
                "--color=fg:-1,bg:-1,hl:{accent},fg+:#ddc7a1:regular:bold,bg+:#32302f,hl+:{accent},info:{muted},prompt:{accent},pointer:{accent},marker:{editor},spinner:{ssh},header:{header},border:{border},label:{header},footer:{muted},gutter:-1,separator:{border},ghost:{ghost},preview-fg:-1,preview-bg:-1,preview-border:{border},preview-label:{header}"
            )
        };
        let danger_color = color(5, if terminal { "1" } else { "#ea6962" });
        let raw_color = color(6, if terminal { "-1" } else { "#7c6f64" });
        Self {
            primary: if terminal {
                String::new()
            } else {
                esc("#d4be98")
            },
            preview_accent: escb(&color(
                0,
                if terminal { TERMINAL_ACCENT } else { "#d8a657" },
            )),
            muted: esc(&color(7, if terminal { "8" } else { "#7c6f64" })),
            palette,
            fzf,
            danger: format!("--color=border:{danger_color},prompt:{danger_color}"),
            raw: format!("--color=nomatch:{raw_color}:strip:dim"),
        }
    }

    /// A complete argument for main pickers, dialogs and dashboards.
    pub fn fzf_color(&self) -> String {
        self.fzf.clone()
    }

    /// Apply after the base theme for a destructive-action dialog.
    pub fn danger_color(&self) -> String {
        self.danger.clone()
    }

    /// Apply after the base theme when fzf displays nonmatching raw rows.
    pub fn raw_color(&self) -> String {
        self.raw.clone()
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

    fn native(profile: &str, values: &[(&str, &str)]) -> NativeTheme {
        NativeTheme::from_values(profile, |name| {
            values
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| (*value).to_owned())
        })
    }

    #[test]
    fn terminal_theme_inherits_surfaces_and_uses_gruvbox_orange() {
        let theme = native("terminal", &[]);
        assert!(theme.primary.is_empty());
        assert_eq!(theme.preview_accent, "\x1b[1;38;2;231;138;78m");
        assert_eq!(theme.muted, "\x1b[38;5;8m");
        assert_eq!(theme.palette.dim_git, "\x1b[38;5;5m");
        let color = theme.fzf_color();
        for expected in [
            "fg:-1,bg:-1",
            "fg+:-1:regular:bold,bg+:-1",
            "preview-fg:-1,preview-bg:-1",
            "hl:#e78a4e",
            "pointer:#e78a4e",
            "prompt:#e78a4e",
            "marker:2",
            "spinner:6",
        ] {
            assert!(color.contains(expected), "missing {expected}");
        }
        assert!(!color.contains("reverse") && !color.contains("strip"));
        assert_eq!(theme.danger_color(), "--color=border:1,prompt:1");
        assert_eq!(theme.raw_color(), "--color=nomatch:-1:strip:dim");
    }

    #[test]
    fn warm_theme_keeps_the_existing_selection_and_unresolved_fallback() {
        let warm = native("warm", &[]);
        assert_eq!(warm.primary, "\x1b[38;2;212;190;152m");
        assert_eq!(warm.preview_accent, "\x1b[1;38;2;216;166;87m");
        assert_eq!(warm.muted, "\x1b[38;2;124;111;100m");
        assert!(warm
            .fzf_color()
            .contains("fg+:#ddc7a1:regular:bold,bg+:#32302f"));
        assert_eq!(warm.palette.dim_cmd, "\x1b[38;5;173m");
        assert_eq!(warm.palette.dim_path, "\x1b[38;5;180m");
        assert_eq!(warm.raw_color(), "--color=nomatch:#7c6f64:strip:dim");
        for profile in ["", "auto", "unknown", "terminal,bg:0"] {
            assert_eq!(native(profile, &[]).fzf_color(), warm.fzf_color());
        }
        assert_eq!(
            native(" TERMINAL ", &[]).fzf_color(),
            native("terminal", &[]).fzf_color()
        );
    }

    #[test]
    fn native_overrides_are_shared_by_rows_previews_and_fzf() {
        for profile in ["terminal", "warm"] {
            let theme = native(
                profile,
                &[
                    ("INTERDIMUX_COLOR_ACCENT", "#AABBCC"),
                    ("INTERDIMUX_COLOR_PATH", "default"),
                    ("INTERDIMUX_COLOR_GIT", "255"),
                    ("INTERDIMUX_COLOR_SSH", "014"),
                    ("INTERDIMUX_COLOR_EDITOR", "0"),
                    ("INTERDIMUX_COLOR_DANGER", "#Ff0000"),
                    ("INTERDIMUX_COLOR_TREE", "-1"),
                    ("INTERDIMUX_COLOR_SEPARATOR", "7"),
                ],
            );
            assert_eq!(theme.palette.bold_amber, "\x1b[1;38;2;170;187;204m");
            assert_eq!(theme.preview_accent, theme.palette.bold_amber);
            assert!(theme.palette.dim_path.is_empty());
            assert_eq!(theme.palette.dim_git, "\x1b[38;5;255m");
            assert_eq!(theme.palette.dim_ssh, "\x1b[38;5;14m");
            assert_eq!(theme.palette.dim_edit, "\x1b[38;5;0m");
            assert_eq!(theme.muted, theme.palette.sep_col);
            assert_eq!(
                theme.danger_color(),
                "--color=border:#ff0000,prompt:#ff0000"
            );
            assert_eq!(theme.raw_color(), "--color=nomatch:-1:strip:dim");
            for expected in [
                "hl:#aabbcc",
                "prompt:#aabbcc",
                "spinner:14",
                "marker:0",
                "border:7",
            ] {
                assert!(theme.fzf_color().contains(expected), "missing {expected}");
            }
        }
    }

    #[test]
    fn invalid_native_colors_cannot_inject_fzf_or_terminal_controls() {
        for invalid in [
            "",
            "256",
            "99999999999999999",
            "+2",
            "-2",
            " 2",
            "#abc",
            "#12345g",
            "#ééé",
            "red",
            "1,bg:0",
            "1:bold",
            "1\x1b[0m",
            "1\n--bind=enter:abort",
        ] {
            assert!(native_color(invalid).is_none(), "accepted {invalid:?}");
            for profile in ["terminal", "warm"] {
                let theme = NativeTheme::from_values(profile, |_| Some(invalid.to_owned()));
                let default = native(profile, &[]);
                assert_eq!(theme.fzf_color(), default.fzf_color());
                assert_eq!(theme.danger_color(), default.danger_color());
                assert_eq!(theme.raw_color(), default.raw_color());
                assert_eq!(theme.palette.dim_cmd, default.palette.dim_cmd);
            }
        }
    }
}
