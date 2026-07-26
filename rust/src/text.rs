//! Width and path helpers.
//!
//! INTENTIONAL DIVERGENCE FROM BASH: bash pads columns by *character count*
//! (`${#var}`), so a CJK or emoji name — two terminal cells per character —
//! misaligns every column to its right.  This uses real display width.  For
//! ASCII input the two are identical, which is what lets the byte-comparison
//! harness still validate the port; for wide characters this is simply correct
//! where bash was not.

use unicode_width::UnicodeWidthStr;

/// Terminal cells occupied by `s`.  Control characters count as zero, matching
/// how a terminal actually renders them.
///
/// Measured over the WHOLE STRING, not summed per character.  A cluster's width
/// is not the sum of its chars' widths, and the per-char sum was wrong in both
/// directions.  Checked against tmux 3.7b's own grid (`printf` into a pane, then
/// read `#{cursor_x}`), which is the authority here because tmux is what parses
/// fzf's output into cells:
///
///     sequence           tmux   per-char   whole-string
///     heart/check/keycap   2        1           2       (U+FE0F presentation)
///     man-technologist     2        4           2       (ZWJ)
///     family               2        8           2       (ZWJ x3)
///     rocket/flag/CJK      =        =           =
///
/// So a window named with a VS16 symbol shifted every column to its right by one
/// cell, and a ZWJ sequence by two the other way.  Plain wide emoji, flags, CJK
/// and combining latin were already correct -- which is why the corpus, whose
/// only emoji is a rocket, never caught it.
pub fn width(s: &str) -> usize {
    UnicodeWidthStr::width(s)
}

/// Truncate to at most `max` display cells, appending `…` when it had to cut.
/// Mirrors bash's `${v:0:n-1}…`, but in cells rather than characters.
pub fn truncate(s: &str, max: usize) -> String {
    if width(s) <= max {
        return s.to_string();
    }
    if max == 0 {
        return String::new();
    }
    let budget = max - 1; // room for the ellipsis

    // Longest char-boundary prefix that fits, found by binary search over the
    // boundaries and measured as a STRING each time.  Growing char by char and
    // summing widths is what the old code did, and it cuts inside a cluster:
    // "man + ZWJ" measures the same 2 cells as the whole "man-technologist", so
    // the joiner looked free and was kept while the char after it was not.
    //
    // Prefix width is non-decreasing, so the search is sound; and since only
    // measured-fitting prefixes are ever accepted, a pathological sequence can
    // make the result shorter but never wider than the budget.
    let bounds: Vec<usize> = s.char_indices().map(|(i, _)| i).collect();
    let (mut lo, mut hi) = (0usize, bounds.len());
    while lo + 1 < hi {
        let mid = (lo + hi) / 2;
        if width(&s[..bounds[mid]]) <= budget {
            lo = mid;
        } else {
            hi = mid;
        }
    }

    // Never strand a joiner or a variation selector on the ellipsis: cutting
    // after the ZWJ left U+200D immediately before U+2026, which a terminal is
    // free to render as anything.
    let mut out = &s[..bounds[lo]];
    while let Some(c) = out.chars().next_back() {
        if matches!(c, '\u{200d}' | '\u{fe0f}' | '\u{fe0e}') {
            out = &out[..out.len() - c.len_utf8()];
        } else {
            break;
        }
    }
    format!("{}…", out)
}

/// Pad `s` (whose visible width is `plain`) out to `target` cells.
pub fn pad_to(s: &str, plain: usize, target: usize) -> String {
    if plain >= target {
        s.to_string()
    } else {
        let mut out = String::with_capacity(s.len() + (target - plain));
        out.push_str(s);
        out.extend(std::iter::repeat(' ').take(target - plain));
        out
    }
}

/// Shorten a path to fit `max` cells by dropping leading components:
/// `/a/b/c/d` -> `/…/c/d`.  A faithful port of bash `trim_path`.
pub fn trim_path(path: &str, max: usize) -> String {
    if width(path) <= max {
        return path.to_string();
    }
    let (prefix, rest) = if let Some(r) = path.strip_prefix("~/") {
        ("~/", r)
    } else if let Some(r) = path.strip_prefix('/') {
        ("/", r)
    } else {
        ("", path)
    };
    let ellipsis = "…/";
    let budget = max
        .saturating_sub(width(prefix))
        .saturating_sub(width(ellipsis));

    // Grow the tail one component at a time while it still fits, exactly as the
    // bash loop does (it always keeps at least the last component).
    let comps: Vec<&str> = rest.split('/').collect();
    let mut result = String::new();
    for (i, comp) in comps.iter().enumerate().rev() {
        if result.is_empty() {
            result = comp.to_string();
            if i == 0 {
                break;
            }
            continue;
        }
        let candidate = format!("{}/{}", comp, result);
        if width(&candidate) <= budget {
            result = candidate;
        } else {
            break;
        }
    }
    if width(&result) > budget && budget > 1 {
        result = truncate(&result, budget);
    }
    format!("{}{}{}", prefix, ellipsis, result)
}

/// Replace `$HOME` with `~`, anchored at the start only.
pub fn tildify(path: &str, home: &str) -> String {
    if !home.is_empty() && path.starts_with(home) {
        format!("~{}", &path[home.len()..])
    } else {
        path.to_string()
    }
}

/// Compact age of an epoch timestamp: "now", "5m", "2h", "3d", "1w".
/// Empty for missing, zero, unparseable, or future timestamps.
pub fn age_of(ts: i64, now: i64) -> String {
    if ts <= 0 {
        return String::new();
    }
    // saturating: INTERDIMUX_NOW is parsed from the environment, and a hostile
    // or absurd value overflowed (debug: panic; release: a wrapped nonsense age)
    let d = now.saturating_sub(ts);
    if d < 0 {
        String::new()
    } else if d < 90 {
        "now".into()
    } else if d < 3600 {
        format!("{}m", d / 60)
    } else if d < 86400 {
        format!("{}h", d / 3600)
    } else if d < 604800 {
        format!("{}d", d / 86400)
    } else {
        format!("{}w", d / 604800)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_width_equals_char_count() {
        assert_eq!(width("hello"), 5);
        assert_eq!(width(""), 0);
    }

    #[test]
    fn wide_characters_count_two_cells() {
        // this is the bug bash has: it would call these 4 and 2
        assert_eq!(width("żółć"), 4); // combining-free latin, 1 cell each
        assert_eq!(width("日本"), 4); // 2 cells each
        assert_eq!(width("→"), 1);
    }

    #[test]
    fn truncate_appends_ellipsis_and_respects_cells() {
        assert_eq!(truncate("abcdef", 4), "abc…");
        assert_eq!(truncate("abc", 8), "abc");
        // a wide char must not be split into half a cell
        assert_eq!(truncate("日本語", 4), "日…");
    }

    #[test]
    fn emoji_presentation_and_zwj_sequences_measure_as_one_cluster() {
        // every expectation here is tmux 3.7b's own cursor position; the old
        // per-char sum gave 1, 1, 4 and 8 for the first four
        assert_eq!(width("\u{2764}\u{fe0f}"), 2);
        assert_eq!(width("1\u{fe0f}\u{20e3}"), 2);
        assert_eq!(width("\u{1f468}\u{200d}\u{1f4bb}"), 2);
        assert_eq!(
            width("\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}"),
            2
        );
        // ...and the ones that were already right stay right
        assert_eq!(width("\u{1f680}"), 2);
        assert_eq!(width("\u{1f1f5}\u{1f1f1}"), 2);
        assert_eq!(width("日本"), 4);
        assert_eq!(width("a\u{301}a\u{301}"), 2);
    }

    #[test]
    fn truncate_never_strands_a_joiner_on_the_ellipsis() {
        // A complete "man + ZWJ + laptop" in the output is fine -- the joiner is
        // part of the cluster.  What must never happen is a cut landing BETWEEN
        // them, leaving U+200D immediately before U+2026, which a terminal is
        // free to render as anything.  The old per-char code did exactly that:
        // it charged 2 for the man, 0 for the joiner (so the joiner looked free
        // and was kept) and then had no room for the laptop.
        let s = "aaaaaaaaaaaa\u{1f468}\u{200d}\u{1f4bb}tail";
        for max in 1..=20 {
            let out = truncate(s, max);
            let mut it = out.chars().rev();
            if it.next() == Some('…') {
                let before = it.next();
                assert!(
                    !matches!(before, Some('\u{200d}') | Some('\u{fe0f}') | Some('\u{fe0e}')),
                    "max={} left a dangling {:?} before the ellipsis: {:?}",
                    max,
                    before,
                    out
                );
            }
            assert!(width(&out) <= max.max(1), "max={} gave {:?}", max, out);
        }
    }

    #[test]
    fn truncate_output_always_fits_its_budget() {
        let samples = [
            "plain-ascii-name",
            "日本語のセッション",
            "\u{2764}\u{fe0f}heart",
            "\u{1f468}\u{200d}\u{1f4bb}dev",
            "\u{1f1f5}\u{1f1f1}\u{1f1f5}\u{1f1f1}",
            "a\u{301}combining",
            "\u{1f680}\u{1f680}\u{1f680}",
        ];
        for s in samples {
            for max in 0..24 {
                let out = truncate(s, max);
                assert!(
                    width(&out) <= max.max(1),
                    "truncate({:?}, {}) = {:?} is {} cells",
                    s,
                    max,
                    out,
                    width(&out)
                );
            }
        }
    }

    #[test]
    fn trim_path_drops_leading_components() {
        assert_eq!(trim_path("/a/b/c/d", 100), "/a/b/c/d");
        assert_eq!(trim_path("/home/u/code/project", 12), "/…/project");
        // budget = 14 - width("~/") - width("…/") = 10, so "nested/path" (11) does not fit.
        // Verified against the bash implementation, which returns the same.
        assert_eq!(trim_path("~/very/deep/nested/path", 14), "~/…/path");
        assert_eq!(trim_path("~/very/deep/nested/path", 18), "~/…/nested/path");
    }

    #[test]
    fn trim_path_keeps_last_component_even_when_oversized() {
        let out = trim_path("/a/averyveryverylongsinglecomponent", 12);
        assert!(out.starts_with("/…/"), "got {}", out);
        assert!(width(&out) <= 12 + 1, "got {} ({} cells)", out, width(&out));
    }

    #[test]
    fn tildify_is_prefix_anchored() {
        assert_eq!(tildify("/home/u/x", "/home/u"), "~/x");
        // must NOT rewrite an occurrence in the middle
        assert_eq!(tildify("/opt/home/u/x", "/home/u"), "/opt/home/u/x");
    }

    #[test]
    fn age_buckets_match_bash() {
        let now = 1_000_000i64;
        assert_eq!(age_of(0, now), "");
        assert_eq!(age_of(now + 50, now), ""); // future
        assert_eq!(age_of(now - 10, now), "now");
        assert_eq!(age_of(now - 89, now), "now");
        assert_eq!(age_of(now - 90, now), "1m");
        assert_eq!(age_of(now - 3599, now), "59m");
        assert_eq!(age_of(now - 3600, now), "1h");
        assert_eq!(age_of(now - 86400, now), "1d");
        assert_eq!(age_of(now - 604800, now), "1w");
    }

    #[test]
    fn pad_never_truncates() {
        assert_eq!(pad_to("ab", 2, 5), "ab   ");
        assert_eq!(pad_to("abcdef", 6, 3), "abcdef");
    }
}
