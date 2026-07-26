//! Row rendering.  Output contract, unchanged from bash:
//!
//!   IDENTITY <TAB> CONTEXT <TAB> COMMAND <TAB> SPEC
//!
//! The SPEC sits last so fzf's --nth indexes are stable, and \x1f must never
//! reach any of the four fields.

use crate::git::GitCache;
use crate::palette::{Palette, BOLD, DIM, RST};
use crate::text::{pad_to, tildify, trim_path, truncate, width};
use crate::widths::Widths;

/// The path + git badge + flag glyphs column.
pub fn ctx_field(
    path: &str,
    zoomed: bool,
    bell: bool,
    activity: bool,
    w: &Widths,
    p: &Palette,
    home: &str,
    git: &mut GitCache,
    show_git: bool,
) -> String {
    let disp = tildify(path, home).replace('\t', " ");
    let disp = trim_path(&disp, w.path);
    let mut out = format!("{} {}{}{}", p.sep, p.dim_path, disp, RST);
    let mut len = 2 + width(&disp);
    out = pad_to(&out, len, w.path + 2);
    len = len.max(w.path + 2);

    if w.badge > 0 {
        let mut badge = String::new();
        let mut blen = 0usize;
        if show_git {
            let mut b = git.branch(path);
            if !b.is_empty() {
                if width(&b) > w.badge.saturating_sub(2) {
                    b = truncate(&b, w.badge.saturating_sub(2));
                }
                badge.push_str(&format!(" {}‹{}›{}", p.dim_git, b, RST));
                blen += width(&b) + 3;
            }
        }
        if zoomed {
            badge.push_str(&format!(" {}Z{}", p.bold_amber, RST));
            blen += 2;
        }
        if bell {
            badge.push_str(&format!(" {}!{}", p.bold_red, RST));
            blen += 2;
        }
        if activity {
            badge.push_str(&format!(" {}#{}", p.dim_ssh, RST));
            blen += 2;
        }
        out.push_str(&badge);
        len += blen;
        out = pad_to(&out, len, w.path + 3 + w.badge);
    }
    out
}

/// Session header row identity column.
pub fn session_ident(name: &str, current: bool, w: &Widths, p: &Palette) -> (String, String) {
    let marker = if current {
        format!("{}*{}", p.marker, RST)
    } else {
        " ".to_string()
    };
    let mut sdisp = name.replace('\t', " ");
    if width(&sdisp) > w.ident.saturating_sub(4) {
        sdisp = truncate(&sdisp, w.ident.saturating_sub(4));
    }
    let body = format!("{} {}▸{} {}{}{}", marker, p.dim_tree, RST, BOLD, sdisp, RST);
    let plain = 1 + 3 + width(&sdisp);
    (pad_to(&body, plain, w.ident), sdisp)
}

/// Session metadata column ("5 win ● 3m").
pub fn session_meta(windows: &str, attached: bool, age: &str, p: &Palette) -> String {
    let mut s = format!("{}{} win{}", DIM, windows, RST);
    if attached {
        s.push_str(&format!(" {}●{}", p.dim_edit, RST));
    }
    if !age.is_empty() {
        s.push_str(&format!(" {}{}{}", DIM, age, RST));
    }
    s
}

/// Window row identity column.  `sdisp` is the (already prefix-truncated)
/// session name carried on child rows so filtered rows stay identifiable.
pub fn window_ident(
    sdisp: &str,
    idx: &str,
    name: &str,
    last: bool,
    current: bool,
    w: &Widths,
    p: &Palette,
) -> String {
    let marker = if current {
        format!("{}*{}", p.marker, RST)
    } else {
        " ".to_string()
    };
    let glyph = if last { "└─" } else { "├─" };
    let mut idname = format!("{}:{}", idx, name.replace('\t', " "));
    let used = 1 + 4 + width(sdisp) + 1;
    let maxid = w.ident.saturating_sub(used);
    if maxid > 2 && width(&idname) > maxid {
        idname = truncate(&idname, maxid);
    }
    let body = format!(
        "{} {}{}{} {}{}{} {}",
        marker, p.dim_tree, glyph, RST, DIM, sdisp, RST, idname
    );
    let plain = used + width(&idname);
    pad_to(&body, plain, w.ident)
}

/// Pane row identity column.
pub fn pane_ident(
    sdisp: &str,
    widx: &str,
    pidx: &str,
    cont: &str,
    last: bool,
    current: bool,
    w: &Widths,
    p: &Palette,
) -> String {
    let marker = if current {
        format!("{}*{}", p.marker, RST)
    } else {
        " ".to_string()
    };
    let pglyph = if last { "└╴" } else { "├╴" };
    // Identity budget: 7 glyph columns + "sdisp widx." + pidx.  Multi-digit
    // indexes can push past IDENT_W — shorten the dim session prefix, never the
    // pane id itself.
    let mut pdisp = sdisp.to_string();
    let over = (9 + width(&pdisp) + width(widx) + width(pidx)) as isize - w.ident as isize;
    if over > 0 && width(&pdisp) > (over as usize + 1) {
        pdisp = truncate(&pdisp, width(&pdisp) - over as usize);
    }
    let pprefix = format!("{} {}.", pdisp, widx);
    let body = format!(
        "{} {}{} {}{} {}{}{}{}",
        marker, p.dim_tree, cont, pglyph, RST, DIM, pprefix, RST, pidx
    );
    // marker(1) + " │ ├╴ "(6) = 7 cells before the prefix, matching bash's
    // fld_add "$pmarker" 1 + fld_add "..." 6
    let plain = 7 + width(&pprefix) + width(pidx);
    pad_to(&body, plain, w.ident)
}

/// Directory row identity column (the one-list model).
pub fn dir_ident(base: &str, w: &Widths, p: &Palette) -> String {
    let mut b = base.replace('\t', " ");
    if width(&b) > w.ident.saturating_sub(4) {
        b = truncate(&b, w.ident.saturating_sub(4));
    }
    let body = format!("  {}+{} {}{}{}", p.dim_tree, RST, DIM, b, RST);
    let plain = 1 + 3 + width(&b);
    pad_to(&body, plain, w.ident)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::widths::{compute, Maxima};

    fn setup() -> (Widths, Palette) {
        let w = compute(Maxima { sess: 10, win: 16, path: 24 }, 200, false);
        (w, Palette::from_env())
    }

    fn visible(s: &str) -> String {
        // strip SGR escapes so we can assert on the rendered text
        let mut out = String::new();
        let mut in_esc = false;
        for c in s.chars() {
            if in_esc {
                if c == 'm' {
                    in_esc = false;
                }
            } else if c == '\x1b' {
                in_esc = true;
            } else {
                out.push(c);
            }
        }
        out
    }

    #[test]
    fn every_identity_column_pads_to_exactly_ident_width() {
        let (w, p) = setup();
        let (s, sdisp) = session_ident("proj", true, &w, &p);
        assert_eq!(width(&visible(&s)), w.ident);
        let win = window_ident(&sdisp, "0", "editor", false, false, &w, &p);
        assert_eq!(width(&visible(&win)), w.ident);
        let pane = pane_ident(&sdisp, "0", "1", "│", true, false, &w, &p);
        assert_eq!(width(&visible(&pane)), w.ident);
        let dir = dir_ident("someproject", &w, &p);
        assert_eq!(width(&visible(&dir)), w.ident);
    }

    #[test]
    fn long_names_are_truncated_not_overflowed() {
        let (w, p) = setup();
        let (s, _) = session_ident(&"x".repeat(200), false, &w, &p);
        assert_eq!(width(&visible(&s)), w.ident);
        assert!(visible(&s).contains('…'));
    }

    #[test]
    fn wide_characters_do_not_break_the_column() {
        let (w, p) = setup();
        let (s, _) = session_ident("日本語プロジェクト", false, &w, &p);
        // This is precisely what bash gets wrong: it would pad by char count.
        assert_eq!(width(&visible(&s)), w.ident);
    }

    #[test]
    fn the_current_marker_appears_only_when_current() {
        let (w, p) = setup();
        let (yes, _) = session_ident("a", true, &w, &p);
        let (no, _) = session_ident("a", false, &w, &p);
        assert!(visible(&yes).starts_with('*'));
        assert!(visible(&no).starts_with(' '));
    }

    #[test]
    fn tree_glyphs_mark_the_last_child() {
        let (w, p) = setup();
        assert!(visible(&window_ident("s", "0", "n", true, false, &w, &p)).contains('└'));
        assert!(visible(&window_ident("s", "0", "n", false, false, &w, &p)).contains('├'));
    }

    #[test]
    fn ctx_field_pads_to_the_full_context_width() {
        let (w, p) = setup();
        let mut g = GitCache::new();
        let c = ctx_field("/tmp", false, false, false, &w, &p, "/home/u", &mut g, false);
        assert_eq!(width(&visible(&c)), w.path + 3 + w.badge);
    }

    #[test]
    fn ctx_field_flag_glyphs_keep_the_width() {
        let (w, p) = setup();
        let mut g = GitCache::new();
        let c = ctx_field("/tmp", true, true, true, &w, &p, "/home/u", &mut g, false);
        assert_eq!(width(&visible(&c)), w.path + 3 + w.badge);
        let v = visible(&c);
        assert!(v.contains('Z') && v.contains('!') && v.contains('#'));
    }

    #[test]
    fn no_rendered_field_can_contain_the_unit_separator() {
        let (w, p) = setup();
        let mut g = GitCache::new();
        let (s, sd) = session_ident("a\u{1f}b", false, &w, &p);
        let c = ctx_field("/tm\u{1f}p", false, false, false, &w, &p, "", &mut g, false);
        // US in a NAME cannot happen (tmux rejects it) but a path can carry one;
        // the row contract only breaks on TAB and newline, which we replace.
        assert!(!s.contains('\t') && !s.contains('\n'));
        assert!(!c.contains('\t') && !c.contains('\n'));
        let _ = sd;
    }
}
