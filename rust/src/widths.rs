//! Column sizing: measure the content, then squeeze to fit the popup.
//! Faithful port of bash `measure_widths` + `compute_widths`.

use crate::text::{tildify, width};

pub const IDENT_OV: usize = 6; // marker(1) + " ├─ "(4) + the space after the prefix(1)
pub const CMD_MIN: usize = 12;
pub const WIDTH_GUTTER: usize = 8;
const PFX_FLOOR: usize = 6;
const PFX_CEIL: usize = 16;
const WIN_FLOOR: usize = 8;
const WIN_CEIL: usize = 40;
const PATH_FLOOR: usize = 12;
/// How far the path may shrink to keep the git badge on screen.  Below this the
/// badge narrows a tier instead, and once even the narrowest does not fit it
/// goes, and the path gets the room back.
const PATH_KEEP: usize = 24;
const PATH_CEIL: usize = 44;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Widths {
    pub ident: usize,
    pub path: usize,
    pub badge: usize,
    pub pfx: usize,
    pub win: usize,
    /// The Z/!/# slot: a leading space plus one cell per flag, sized to the
    /// most flags any window carries, and 0 when no window has one.  It is its
    /// own column, NOT part of the badge, so a squeeze that drops the branch can
    /// never take the flags with it, and the flags sit at the same x on every row.
    pub flags: usize,
    /// Total width a session header row's identity field is padded to when the
    /// group rule is drawn.  Chosen so the session meta lands in the same column
    /// as the command field on child rows: ident + TAB + ctx.
    pub rule: usize,
}

/// Width of the context column: "│ " + path + flag slot + (" " + badge).
fn ctx_width(path: usize, flags: usize, badge: usize) -> usize {
    path + 2 + flags + if badge > 0 { badge + 1 } else { 0 }
}

#[derive(Debug, Default, Clone, Copy)]
pub struct Maxima {
    pub sess: usize,
    pub win: usize,
    pub path: usize,
    /// Most of Z / ! / # set on any one window (0..=3).
    pub flags: usize,
    /// Whether any window or pane row has a git branch to show.  Without one the
    /// badge column would be blank on every tree row, so it is not worth a
    /// single cell of path.
    pub branch: bool,
}

impl Maxima {
    pub fn observe_session(&mut self, name: &str) {
        self.sess = self.sess.max(width(name));
    }
    /// Window identity is rendered as "index:name".
    pub fn observe_window(&mut self, idx: &str, name: &str, path: &str, home: &str) {
        self.win = self.win.max(width(idx) + 1 + width(name));
        self.path = self.path.max(width(&tildify(path, home)));
    }
    pub fn observe_pane(&mut self, path: &str, home: &str) {
        self.path = self.path.max(width(&tildify(path, home)));
    }
    pub fn observe_flags(&mut self, zoomed: bool, bell: bool, activity: bool) {
        let n = usize::from(zoomed) + usize::from(bell) + usize::from(activity);
        self.flags = self.flags.max(n);
    }
    pub fn observe_branch(&mut self, branch: &str) {
        self.branch |= !branch.is_empty();
    }
}

/// `avail` is the popup width already halved when the preview is open.
pub fn compute(m: Maxima, cols: usize, preview_on: bool) -> Widths {
    let mut avail = cols;
    if preview_on {
        avail /= 2;
    }
    let avail = avail.saturating_sub(WIDTH_GUTTER);

    let mut pfx = m.sess.clamp(PFX_FLOOR, PFX_CEIL);
    let mut win = m.win.clamp(WIN_FLOOR, WIN_CEIL);
    let mut path = m.path.clamp(PATH_FLOOR, PATH_CEIL);
    let flags = if m.flags > 0 { 1 + m.flags.min(3) } else { 0 };
    let mut badge = if avail >= 72 {
        16
    } else if avail >= 52 {
        14
    } else if avail >= 40 {
        10
    } else {
        0
    };
    let mut ident = IDENT_OV + pfx + win;

    // How many cells the row is over the popup, 0 when it fits.
    let over = |ident: usize, path: usize, badge: usize| {
        (ident + ctx_width(path, flags, badge) + 2 + CMD_MIN).saturating_sub(avail)
    };

    // Squeeze to fit.  The order is the point: what you TYPE outlasts what you
    // only READ.  fzf matches the identity column as displayed, so a session
    // prefix cut to "my-pr…" makes `my-project shell` match nothing; the path
    // and the branch are display-only.  So:
    //
    //   1. the path gives up cells down to PATH_KEEP to keep the git badge,
    //      and when that is not enough the badge narrows a tier (16, 14, 10)
    //      and the path tries again.  Only when even the 10-cell badge does not
    //      fit does it go — snapped straight to 0, never to a degenerate 1..3 —
    //      and the path keeps its cells.  Only while some row actually HAS a
    //      branch; a badge column that would be blank on every tree row is
    //      simply the first to go.
    //   2. the path, down to PATH_FLOOR
    //   3. the session prefix, down to PFX_FLOOR
    //   4. the window name, down to WIN_FLOOR
    //
    // The Z/!/# flags are never squeezed: they are their own slot, at most 4
    // cells, and they are the part of the context column you act on.  Any
    // deficit left after the floors lands on the flowing command column, which
    // fzf clips anyway.
    //
    // The narrower tiers matter on the most ordinary popup there is: 80% of a
    // 120-column terminal is avail 86, where one 16-character session name took
    // every badge off the list although a 14-cell one fitted (review BUG-108).
    let mut o = over(ident, path, badge);
    if badge > 0 && o > 0 {
        while badge > 0 && path.saturating_sub(PATH_KEEP) < o {
            badge = match badge {
                16 => 14,
                14 => 10,
                _ => 0,
            };
            o = over(ident, path, badge);
        }
        if badge > 0 && m.branch {
            path -= o;
        } else {
            badge = 0;
        }
    }
    let give = over(ident, path, badge).min(path.saturating_sub(PATH_FLOOR));
    path -= give;
    let give = over(ident, path, badge).min(pfx.saturating_sub(PFX_FLOOR));
    pfx -= give;
    ident -= give;
    let give = over(ident, path, badge).min(win.saturating_sub(WIN_FLOOR));
    win -= give;
    ident -= give;

    // The rule is a wide-terminal affordance: it works by moving the session
    // meta into the command column, so it is only right while that column still
    // exists.  Once the squeeze has run out of room — it stopped at the floors
    // rather than because everything fit — the meta would be clipped at
    // exactly the point the command already is, so the rule switches itself off
    // and session rows go back to the plain layout.  Measured: below ~49 popup
    // columns "2 win ● 2h" became "2 win…".
    let rule = if over(ident, path, badge) == 0 {
        ident + 1 + ctx_width(path, flags, badge)
    } else {
        0
    };
    Widths { ident, path, badge, pfx, win, flags, rule }
}

impl Widths {
    /// Width of the context column every child row pads to.
    pub fn ctx(&self) -> usize {
        ctx_width(self.path, self.flags, self.badge)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(sess: usize, win: usize, path: usize) -> Maxima {
        Maxima { sess, win, path, ..Default::default() }
    }
    /// The same, with a git branch on some row (so the badge is worth keeping).
    fn mb(sess: usize, win: usize, path: usize) -> Maxima {
        Maxima { branch: true, ..m(sess, win, path) }
    }
    fn avail(cols: usize, preview: bool) -> usize {
        (if preview { cols / 2 } else { cols }).saturating_sub(WIDTH_GUTTER)
    }
    fn row(w: &Widths) -> usize {
        w.ident + w.ctx() + 2 + CMD_MIN
    }

    #[test]
    fn wide_terminal_keeps_content_sized_columns() {
        let w = compute(m(10, 20, 30), 200, false);
        assert_eq!(w.pfx, 10);
        assert_eq!(w.win, 20);
        assert_eq!(w.path, 30);
        assert_eq!(w.badge, 16);
        assert_eq!(w.ident, IDENT_OV + 10 + 20);
    }

    #[test]
    fn maxima_are_clamped_to_their_ceilings() {
        let w = compute(m(100, 100, 100), 400, false);
        assert_eq!(w.pfx, PFX_CEIL);
        assert_eq!(w.win, WIN_CEIL);
        assert_eq!(w.path, PATH_CEIL);
    }

    #[test]
    fn maxima_are_clamped_to_their_floors() {
        let w = compute(m(1, 1, 1), 200, false);
        assert_eq!(w.pfx, PFX_FLOOR);
        assert_eq!(w.win, WIN_FLOOR);
        assert_eq!(w.path, PATH_FLOOR);
    }

    // The squeeze order used to be prefix FIRST, then the badge, then the path.
    // Both halves of that were wrong: the prefix is what fzf matches (so
    // `my-project shell` found nothing once it read "my-pr…"), and two cells of
    // path cost the whole branch badge and the Z/!/# flags with it.

    /// Review BUG-24: a 96-column popup, one 39-cell path in the tree.  The path
    /// has 15 cells above PATH_KEEP to give, and 4 are enough.
    #[test]
    fn the_path_gives_way_before_the_git_badge() {
        let w = compute(mb(6, 8, 39), 96, false);
        assert_eq!(w.badge, 16, "the badge was dropped: {:?}", w);
        assert_eq!(w.path, 35, "the path should give exactly the 4 cells needed: {:?}", w);
        assert_eq!(row(&w), avail(96, false), "not one cell wasted");
    }

    /// ...but only down to PATH_KEEP.  Past that the badge narrows a tier and
    /// the path tries again; only when even the 10-cell badge would starve the
    /// path does the badge go, and the path gets back everything it gave for it.
    #[test]
    fn the_badge_goes_when_keeping_it_would_starve_the_path() {
        // The badge widths on offer at a given width: the tier the popup allows
        // and the narrower ones (review BUG-108).
        let tiers = |a: usize| -> &'static [usize] {
            match a {
                72.. => &[16, 14, 10],
                52..=71 => &[14, 10],
                40..=51 => &[10],
                _ => &[],
            }
        };
        for (sess, win, path, flags) in
            [(10, 12, 44, 0), (16, 8, 31, 0), (16, 8, 31, 1), (14, 9, 26, 3), (16, 20, 18, 2)]
        {
            for cols in 0..=300 {
                for preview in [false, true] {
                    let mx = Maxima { flags, ..mb(sess, win, path) };
                    let w = compute(mx, cols, preview);
                    let a = avail(cols, preview);
                    let ctx = format!("{:?} cols={} preview={} -> {:?}", mx, cols, preview, w);
                    // The widest badge on offer that fits with the path cut no
                    // shorter than PATH_KEEP, counted cell by cell: the row is
                    // the identity, "│ ", the path, the flag slot, " " + badge,
                    // the TAB and the command's minimum.
                    let full_ident = IDENT_OV + sess.clamp(PFX_FLOOR, PFX_CEIL) + win.clamp(WIN_FLOOR, WIN_CEIL);
                    let slot = if flags > 0 { 1 + flags } else { 0 };
                    let fits = |b: usize| {
                        full_ident + 2 + path.min(PATH_KEEP) + slot + 1 + b + 2 + CMD_MIN <= a
                    };
                    let want = tiers(a).iter().copied().find(|&b| fits(b)).unwrap_or(0);
                    assert_eq!(w.badge, want, "not the widest badge that fits: {}", ctx);
                    if w.badge > 0 {
                        assert!(w.path >= PATH_KEEP.min(path), "kept the badge at a starved path: {}", ctx);
                        assert!(
                            w.path == path || row(&w) == a,
                            "the path gave more cells than the badge needed: {}", ctx
                        );
                    } else if w.path < path {
                        // the badge is gone and the path was trimmed: it must be
                        // trimmed only as far as the row needs, or it is at its floor
                        assert!(row(&w) == a || w.path == PATH_FLOOR, "wasted cells: {}", ctx);
                    }
                }
            }
        }
    }

    /// Review BUG-108: 80% of a 120-column terminal is a 94-column popup, avail
    /// 86.  A 16-character session name and the 8-cell window floor make the
    /// identity 30 cells, and a 31-cell path then left the 16-cell badge one
    /// cell short of PATH_KEEP -- and every row lost its branch, although a
    /// 14-cell badge at a 25-cell path fits exactly.  With a Z flag (a 2-cell
    /// slot) 14 is two cells short, and 10 fits at a 27-cell path.
    #[test]
    fn a_long_session_name_narrows_the_badge_instead_of_dropping_it() {
        let w = compute(mb(16, 8, 31), 94, false);
        assert_eq!((w.badge, w.path), (14, 25), "{:?}", w);
        assert_eq!(row(&w), avail(94, false), "not one cell wasted");
        let w = compute(Maxima { flags: 1, ..mb(16, 8, 31) }, 94, false);
        assert_eq!((w.badge, w.path), (10, 27), "{:?}", w);
        assert_eq!(row(&w), avail(94, false), "not one cell wasted");
        // the identity is untouched: the squeeze stopped at the first rung
        assert_eq!((w.pfx, w.win), (16, 8));
    }

    /// Review BUG-02: the prefix is matched as displayed, so it outlasts the
    /// display-only columns.  At an 80-column popup a 10-character name used to
    /// be cut to "my-pr…"; at 60 it now survives whole as well.
    #[test]
    fn the_matchable_prefix_outlasts_the_path_and_the_badge() {
        for cols in [60, 80, 100] {
            let w = compute(mb(10, 8, 44), cols, false);
            assert_eq!(w.pfx, 10, "cols={} cut the session prefix: {:?}", cols, w);
        }
    }

    /// The whole ladder, as invariants over every width: each rung is spent only
    /// once the rungs before it are exhausted.
    #[test]
    fn each_rung_is_spent_only_after_the_ones_before_it() {
        for (sess, win, path) in [(16, 20, 44), (10, 8, 39), (40, 60, 90), (6, 8, 12)] {
            for branch in [false, true] {
                for cols in 0..=300 {
                    for preview in [false, true] {
                        let mx = Maxima { branch, ..m(sess, win, path) };
                        let w = compute(mx, cols, preview);
                        let full_pfx = sess.clamp(PFX_FLOOR, PFX_CEIL);
                        let full_win = win.clamp(WIN_FLOOR, WIN_CEIL);
                        let ctx = format!("{:?} cols={} preview={} -> {:?}", mx, cols, preview, w);
                        if w.pfx < full_pfx {
                            assert_eq!(w.path, PATH_FLOOR, "prefix cut before the path: {}", ctx);
                            assert_eq!(w.badge, 0, "prefix cut while the badge stayed: {}", ctx);
                        }
                        if w.win < full_win {
                            assert_eq!(w.pfx, PFX_FLOOR, "window cut before the prefix: {}", ctx);
                        }
                        if w.pfx < full_pfx || w.win < full_win {
                            // an identity cut is only ever as deep as needed
                            assert!(
                                row(&w) == avail(cols, preview)
                                    || (w.pfx == PFX_FLOOR && w.win == WIN_FLOOR),
                                "identity cut deeper than needed: {}", ctx
                            );
                        }
                    }
                }
            }
        }
    }

    /// With no branch on any row the badge column would be blank on every tree
    /// row: it must not cost a single cell of path.
    #[test]
    fn a_badge_with_nothing_to_show_costs_no_path() {
        let w = compute(m(6, 8, 39), 96, false);
        assert_eq!(w.badge, 0);
        assert_eq!(w.path, 39);
        // ...while at a width where it fits outright it stays, as it always did
        // (directory rows can still fill it)
        assert_eq!(compute(m(6, 8, 39), 200, false).badge, 16);
    }

    /// The Z/!/# flags have their own slot, so no squeeze can take them.
    #[test]
    fn the_flag_slot_survives_every_squeeze() {
        for (n, want) in [(0usize, 0usize), (1, 2), (2, 3), (3, 4), (9, 4)] {
            for cols in 0..=300 {
                for preview in [false, true] {
                    let mx = Maxima { flags: n, ..mb(16, 30, 44) };
                    let w = compute(mx, cols, preview);
                    assert_eq!(w.flags, want, "{} flags at cols={} preview={}", n, cols, preview);
                }
            }
        }
        // and the slot is part of the context column the rows pad to
        let w = compute(Maxima { flags: 1, ..mb(6, 8, 20) }, 200, false);
        assert_eq!(w.ctx(), w.path + 2 + 2 + w.badge + 1);
    }

    #[test]
    fn the_badge_snaps_to_zero_never_to_a_degenerate_width() {
        for cols in 40..=200 {
            let w = compute(mb(16, 30, 44), cols, false);
            assert!(
                w.badge == 0 || w.badge >= 10,
                "cols={} produced a degenerate badge width {}",
                cols,
                w.badge
            );
        }
    }

    #[test]
    fn preview_halves_the_available_width() {
        let off = compute(m(16, 30, 44), 200, false);
        let on = compute(m(16, 30, 44), 200, true);
        assert!(on.ident + on.path <= off.ident + off.path);
    }

    #[test]
    fn it_always_terminates_and_never_underflows() {
        for cols in 0..=300 {
            for preview in [false, true] {
                let w = compute(Maxima { flags: 3, ..mb(40, 60, 90) }, cols, preview);
                assert!(w.pfx >= PFX_FLOOR);
                assert!(w.win >= WIN_FLOOR);
                assert!(w.path >= PATH_FLOOR);
                assert!(w.ident >= IDENT_OV + PFX_FLOOR + WIN_FLOOR);
            }
        }
    }

    #[test]
    fn observers_track_the_maxima() {
        let mut mx = Maxima::default();
        mx.observe_session("short");
        mx.observe_session("a-much-longer-session");
        assert_eq!(mx.sess, "a-much-longer-session".len());
        mx.observe_window("12", "editor", "/home/u/x", "/home/u");
        assert_eq!(mx.win, 2 + 1 + 6);
        assert_eq!(mx.path, "~/x".len());
        mx.observe_flags(true, false, true);
        mx.observe_flags(false, true, false);
        assert_eq!(mx.flags, 2);
        mx.observe_branch("");
        assert!(!mx.branch);
        mx.observe_branch("main");
        mx.observe_branch("");
        assert!(mx.branch);
    }
}
