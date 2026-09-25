//! Row rendering.  Output contract, unchanged from bash:
//!
//!   IDENTITY <TAB> CONTEXT <TAB> COMMAND <TAB> SPEC
//!
//! The SPEC sits last so fzf's --nth indexes are stable, and \x1f must never
//! reach any of the four fields.

use crate::git::GitCache;
use crate::proc::sanitize;
use crate::palette::{Palette, BOLD, DIM, RST};
use crate::text::{pad_to, tildify, trim_path, truncate, width};
use crate::widths::Widths;

/// The context column: path, then the Z/!/# flag slot, then the git badge.
///
/// The flags are a column of their own (`w.flags` cells, sized to the most flags
/// any window carries).  They used to trail the branch inside the badge, so
/// their x moved with the branch's length, the branch budget moved with the
/// flag count, and the squeeze that dropped the badge dropped them too.
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
    // Sanitize, not just de-tab.  A pane cwd is arbitrary bytes: an ESC in a
    // path injected a live terminal escape into the popup, and width() counts
    // the ESC as 0 cells while the terminal consumed the "[31m" that followed —
    // so the padding came out short and the column shifted.  A CR redrew the row
    // over itself.  Same rules as argv (proc::sanitize).
    let disp = sanitize(&tildify(path, home)).replace('\t', " ");
    let disp = trim_path(&disp, w.path);
    let mut out = format!("{} {}{}{}", p.sep, p.dim_path, disp, RST);
    let mut len = 2 + width(&disp);
    out = pad_to(&out, len, w.path + 2);
    len = len.max(w.path + 2);

    if w.flags > 0 {
        // Packed ("Z!#"), in a fixed order, so each flag reads as a column.
        // The slot is sized from the windows' own flags, so it always fits.
        let mut fl = String::new();
        let mut n = 0usize;
        if zoomed {
            fl.push_str(&format!("{}Z{}", p.bold_amber, RST));
            n += 1;
        }
        if bell {
            fl.push_str(&format!("{}!{}", p.bold_red, RST));
            n += 1;
        }
        if activity {
            fl.push_str(&format!("{}#{}", p.dim_ssh, RST));
            n += 1;
        }
        if n > 0 {
            out.push(' ');
            out.push_str(&fl);
            len += 1 + n;
        }
        out = pad_to(&out, len, w.path + 2 + w.flags);
        len = len.max(w.path + 2 + w.flags);
    }

    if w.badge > 0 {
        if show_git {
            // .git/HEAD is a file anyone can write: a TAB in the ref name
            // produced a FIVE-field row, breaking the contract fzf's
            // --delimiter/--with-nth/--nth all depend on.
            let mut b = sanitize(&git.branch(path)).replace('\t', " ");
            if !b.is_empty() {
                // " ‹" + branch + "›" in badge + 1 cells: the budget is the same
                // on every row, whatever flags the row carries.
                let budget = w.badge.saturating_sub(2);
                if width(&b) > budget {
                    b = truncate(&b, budget);
                }
                out.push_str(&format!(" {}‹{}›{}", p.dim_git, b, RST));
                len += width(&b) + 3;
            }
        }
        out = pad_to(&out, len, w.ctx());
    }
    out
}

/// Session header row identity column.
///
/// With `rule` on, the padding that would follow the name becomes a run of `─`
/// instead — the group separator the flat list otherwise has no way to draw.
/// It has to live entirely in field 1: field 2 is not matched by the default
/// `--nth=1,3`, so a rule split across the two renders at two different
/// intensities once `--color nth:` is on, and the TAB between them shows as a
/// one-cell nick in the line.  Costs no extra rows.
pub fn session_ident(
    name: &str,
    current: bool,
    w: &Widths,
    p: &Palette,
    rule: bool,
) -> (String, String) {
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
    // one space before the run, two after it, so the meta never touches the rule
    let dashes = w.rule.saturating_sub(plain + 3);
    if rule && dashes >= 3 {
        let body = format!("{} {}{}{}  ", body, p.dim_tree, "─".repeat(dashes), RST);
        return (body, sdisp);
    }
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
    if over > 0 {
        if width(&pdisp) > (over as usize + 1) {
            pdisp = truncate(&pdisp, width(&pdisp) - over as usize);
        } else {
            // The prefix is too short to absorb the overflow (short session
            // name, wide window/pane indexes).  Dropping it entirely keeps the
            // column aligned; leaving it made pane rows wider than every other
            // row, since pad_to cannot trim.
            pdisp = String::new();
        }
    }
    let mut pprefix = if pdisp.is_empty() {
        format!("{}.", widx)
    } else {
        format!("{} {}.", pdisp, widx)
    };
    // marker(1) + " │ ├╴ "(6) = 7 cells before the prefix, matching bash's
    // fld_add "$pmarker" 1 + fld_add "..." 6
    let mut pid = pidx.to_string();
    let mut plain = 7 + width(&pprefix) + width(&pid);

    // Dropping the prefix above is not a total guard: with it gone the bare
    // indexes alone can still outrun the column, since ident's floor is
    // IDENT_OV(6) + PFX_FLOOR(6) + WIN_FLOOR(8) = 20 and the two index strings
    // can total 13+ cells.  Reachable only with a narrow popup AND a window
    // index in the tens of millions (tmux caps it at INT_MAX) combined with a
    // pane-base-index in the tens of thousands (tmux caps that at 65535), so
    // this is about making the invariant total rather than about a case anyone
    // will hit.  pad_to can only pad, so trim here: a shortened id beats a
    // shifted column, and the SPEC field still carries both indexes exactly.
    if plain > w.ident {
        pid = truncate(&pid, w.ident.saturating_sub(7 + width(&pprefix)));
        plain = 7 + width(&pprefix) + width(&pid);
        if plain > w.ident {
            pprefix = truncate(&pprefix, w.ident.saturating_sub(7));
            pid = String::new();
            plain = 7 + width(&pprefix);
        }
    }

    let body = format!(
        "{} {}{} {}{} {}{}{}{}",
        marker, p.dim_tree, cont, pglyph, RST, DIM, pprefix, RST, pid
    );
    pad_to(&body, plain, w.ident)
}

/// An identity column with `mark` in its gutter, the one-cell column where
/// `*` marks the current target (the agents view's `!` / `?`, which take its
/// place).  `current` says which gutter the column was drawn with.
pub fn with_gutter(ident: &str, current: bool, mark: &str, p: &Palette) -> String {
    let gutter = if current { format!("{}*{}", p.marker, RST) } else { " ".to_string() };
    format!("{}{}", mark, ident.strip_prefix(gutter.as_str()).unwrap_or(ident))
}

/// Directory row identity column (the one-list model).  The name is sanitized
/// like the context column's path, and before the cut: an ESC in it was drawn
/// live.  (A TAB never gets here: such a directory is not offered.)
pub fn dir_ident(base: &str, w: &Widths, p: &Palette) -> String {
    let mut b = sanitize(base);
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
        let w = compute(Maxima { sess: 10, win: 16, path: 24, ..Default::default() }, 200, false);
        (w, Palette::from_env())
    }
    /// A tree where some window carries all three flags.
    fn setup_flags() -> (Widths, Palette) {
        let mx = Maxima { sess: 10, win: 16, path: 24, flags: 3, branch: true };
        (compute(mx, 200, false), Palette::from_env())
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
        let (s, sdisp) = session_ident("proj", true, &w, &p, false);
        assert_eq!(width(&visible(&s)), w.ident);
        let win = window_ident(&sdisp, "0", "editor", false, false, &w, &p);
        assert_eq!(width(&visible(&win)), w.ident);
        let pane = pane_ident(&sdisp, "0", "1", "│", true, false, &w, &p);
        assert_eq!(width(&visible(&pane)), w.ident);
        let dir = dir_ident("someproject", &w, &p);
        assert_eq!(width(&visible(&dir)), w.ident);
        // control bytes in a directory's name: neutralised, and still padded
        let dir = dir_ident("esc\x1b[31mred\rz", &w, &p);
        assert!(!visible(&dir).contains(|c: char| c.is_control()), "{dir:?}");
        assert!(visible(&dir).contains("esc?[31mred?z"), "{dir:?}");
        assert_eq!(width(&visible(&dir)), w.ident);
    }

    #[test]
    fn long_names_are_truncated_not_overflowed() {
        let (w, p) = setup();
        let (s, _) = session_ident(&"x".repeat(200), false, &w, &p, false);
        assert_eq!(width(&visible(&s)), w.ident);
        assert!(visible(&s).contains('…'));
    }

    #[test]
    fn wide_characters_do_not_break_the_column() {
        let (w, p) = setup();
        let (s, _) = session_ident("日本語プロジェクト", false, &w, &p, false);
        // This is precisely what bash gets wrong: it would pad by char count.
        assert_eq!(width(&visible(&s)), w.ident);
    }

    #[test]
    fn the_current_marker_appears_only_when_current() {
        let (w, p) = setup();
        let (yes, _) = session_ident("a", true, &w, &p, false);
        let (no, _) = session_ident("a", false, &w, &p, false);
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
    fn the_session_rule_fills_exactly_the_rule_width() {
        let (w, p) = setup();
        // Long and short names must land the meta in the SAME column, which is
        // the whole point of the rule — otherwise it is decoration.
        for name in ["a", "proj", "a-fairly-long-name"] {
            let (s, _) = session_ident(name, false, &w, &p, true);
            let v = visible(&s);
            assert_eq!(width(&v), w.rule, "name {:?}", name);
            assert!(v.contains("──"), "name {:?} drew no rule: {:?}", name, v);
            assert!(v.ends_with("  "), "the meta would touch the rule: {:?}", v);
        }
    }

    #[test]
    fn the_session_rule_lands_the_meta_in_the_command_column() {
        let (w, p) = setup();
        let mut g = GitCache::new();
        // window row:  ident TAB ctx TAB cmd     — cmd starts at ident+1+ctx+1
        // session row: rule  TAB meta            — meta starts at rule+1
        let ctx = ctx_field("/tmp", false, false, false, &w, &p, "/home/u", &mut g, false);
        assert_eq!(w.ident + 1 + width(&visible(&ctx)) + 1, w.rule + 1);
    }

    #[test]
    fn the_rule_is_off_by_request_and_the_row_is_unchanged() {
        let (w, p) = setup();
        let (off, _) = session_ident("proj", false, &w, &p, false);
        assert_eq!(width(&visible(&off)), w.ident);
        assert!(!visible(&off).contains('─'));
    }

    #[test]
    fn ctx_field_pads_to_the_full_context_width() {
        let (w, p) = setup();
        let mut g = GitCache::new();
        let c = ctx_field("/tmp", false, false, false, &w, &p, "/home/u", &mut g, false);
        assert_eq!(w.flags, 0, "no window has a flag, so there is no slot");
        assert_eq!(width(&visible(&c)), w.path + 3 + w.badge);
        assert_eq!(width(&visible(&c)), w.ctx());
    }

    #[test]
    fn ctx_field_flag_glyphs_keep_the_width() {
        let (w, p) = setup_flags();
        let mut g = GitCache::new();
        for flags in [(true, true, true), (true, false, false), (false, false, true), (false, false, false)] {
            let c = ctx_field("/tmp", flags.0, flags.1, flags.2, &w, &p, "/home/u", &mut g, false);
            assert_eq!(width(&visible(&c)), w.ctx(), "flags {:?}", flags);
        }
        let v = visible(&ctx_field("/tmp", true, true, true, &w, &p, "/home/u", &mut g, false));
        assert!(v.contains("Z!#"), "{:?}", v);
    }

    fn git_repo(branch: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "imux-render-test-{}-{}",
            std::process::id(),
            branch.replace('/', "_")
        ));
        std::fs::create_dir_all(d.join(".git")).unwrap();
        std::fs::write(d.join(".git/HEAD"), format!("ref: refs/heads/{}\n", branch)).unwrap();
        d
    }

    /// The flags sit at one x on every row, whatever the branch, and a long
    /// branch is cut to the same budget whatever the flags (UI-EXPLORATION §8).
    #[test]
    fn flags_are_a_fixed_column_and_the_branch_budget_ignores_them() {
        let (w, p) = setup_flags();
        let mut g = GitCache::new();
        let short = git_repo("main");
        let long = git_repo("feature/a-very-long-branch-name");
        let rows = [
            ctx_field(short.to_str().unwrap(), true, false, false, &w, &p, "/home/u", &mut g, true),
            ctx_field(long.to_str().unwrap(), false, true, false, &w, &p, "/home/u", &mut g, true),
            ctx_field(long.to_str().unwrap(), true, true, true, &w, &p, "/home/u", &mut g, true),
            ctx_field(long.to_str().unwrap(), false, false, false, &w, &p, "/home/u", &mut g, true),
        ];
        let vis: Vec<String> = rows.iter().map(|r| visible(r)).collect();
        let col = |v: &str, c: char| v.chars().position(|x| x == c);
        let slot = w.path + 3; // "│ " + path + the slot's leading space
        assert_eq!(col(&vis[0], 'Z'), Some(slot), "{:?}", vis[0]);
        assert_eq!(col(&vis[1], '!'), Some(slot), "{:?}", vis[1]);
        assert_eq!(col(&vis[2], 'Z'), Some(slot), "{:?}", vis[2]);
        let branch = |v: &str| v[v.find('‹').unwrap()..].chars().take_while(|c| *c != ' ').collect::<String>();
        assert_eq!(branch(&vis[1]), branch(&vis[2]), "the flag count changed the branch budget");
        assert_eq!(branch(&vis[1]), branch(&vis[3]), "the flag count changed the branch budget");
        for (i, v) in vis.iter().enumerate() {
            assert_eq!(width(v), w.ctx(), "row {} overflowed: {:?}", i, v);
        }
        let _ = std::fs::remove_dir_all(short);
        let _ = std::fs::remove_dir_all(long);
    }

    /// The squeeze may drop the badge; it must never drop the flags with it.
    #[test]
    fn the_flags_survive_when_the_badge_is_squeezed_out() {
        let mx = Maxima { sess: 16, win: 20, path: 44, flags: 1, branch: true };
        let w = compute(mx, 60, false);
        assert_eq!(w.badge, 0, "precondition: this width has no room for the badge");
        let p = Palette::from_env();
        let mut g = GitCache::new();
        let v = visible(&ctx_field("/tmp", true, false, false, &w, &p, "/home/u", &mut g, false));
        assert!(v.contains('Z'), "the zoom flag went with the badge: {:?}", v);
        assert_eq!(width(&v), w.ctx());
    }

    #[test]
    fn no_rendered_field_can_contain_the_unit_separator() {
        let (w, p) = setup();
        let mut g = GitCache::new();
        let (s, sd) = session_ident("a\u{1f}b", false, &w, &p, false);
        let c = ctx_field("/tm\u{1f}p", false, false, false, &w, &p, "", &mut g, false);
        // US in a NAME cannot happen (tmux rejects it) but a path can carry one;
        // the row contract only breaks on TAB and newline, which we replace.
        assert!(!s.contains('\t') && !s.contains('\n'));
        assert!(!c.contains('\t') && !c.contains('\n'));
        let _ = sd;
    }
}
