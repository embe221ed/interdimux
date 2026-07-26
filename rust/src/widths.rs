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
const PATH_CEIL: usize = 44;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Widths {
    pub ident: usize,
    pub path: usize,
    pub badge: usize,
    pub pfx: usize,
    pub win: usize,
}

#[derive(Debug, Default, Clone, Copy)]
pub struct Maxima {
    pub sess: usize,
    pub win: usize,
    pub path: usize,
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

    // Squeeze to fit.  The dim session prefix is redundant so it shrinks first;
    // then the git badge, snapped straight to 0 (never left at 1..3, which would
    // make the badge slice degenerate); then the path; the window name last.
    let mut guard = 0;
    loop {
        let ctx = if badge > 0 { path + 3 + badge } else { path + 2 };
        if ident + ctx + 2 + CMD_MIN <= avail {
            break;
        }
        guard += 1;
        if guard > 400 {
            break;
        }
        if pfx > PFX_FLOOR {
            pfx -= 1;
            ident -= 1;
        } else if badge > 0 {
            badge = 0;
        } else if path > PATH_FLOOR {
            path -= 1;
        } else if win > WIN_FLOOR {
            win -= 1;
            ident -= 1;
        } else {
            break;
        }
    }
    Widths { ident, path, badge, pfx, win }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(sess: usize, win: usize, path: usize) -> Maxima {
        Maxima { sess, win, path }
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

    #[test]
    fn the_prefix_shrinks_before_anything_else() {
        let wide = compute(m(16, 20, 40), 200, false);
        let tight = compute(m(16, 20, 40), 110, false);
        assert!(tight.pfx < wide.pfx, "prefix should shrink first");
        assert_eq!(tight.win, wide.win, "window name is protected");
    }

    #[test]
    fn the_badge_snaps_to_zero_never_to_a_degenerate_width() {
        for cols in 40..=200 {
            let w = compute(m(16, 30, 44), cols, false);
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
                let w = compute(m(40, 60, 90), cols, preview);
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
    }
}
