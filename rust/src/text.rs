//! Width and path helpers.
//!
//! INTENTIONAL DIVERGENCE FROM BASH: bash pads columns by *character count*
//! (`${#var}`), so a CJK or emoji name — two terminal cells per character —
//! misaligns every column to its right.  This uses real display width.  For
//! ASCII input the two are identical, which is what lets the byte-comparison
//! harness still validate the port; for wide characters this is simply correct
//! where bash was not.

use unicode_segmentation::UnicodeSegmentation;
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

    // Common command/path labels need no Unicode boundary table at all.
    if s.bytes().all(|byte| (b' '..=b'~').contains(&byte)) {
        return format!("{}…", &s[..budget]);
    }

    // Find a fitting prefix of complete grapheme clusters, measuring the whole
    // prefix because terminal width is not additive across Unicode codepoints.
    // Cutting at char boundaries can change an emoji's appearance ("❤️" to
    // "❤"), split a flag, or detach a skin-tone modifier or combining mark.
    //
    // Prefix width is non-decreasing, so the search is sound; and since only
    // measured-fitting prefixes are ever accepted, a pathological sequence can
    // make the result shorter but never wider than the budget.
    let bounds: Vec<usize> = s.grapheme_indices(true).map(|(i, _)| i).collect();
    format!("{}…", &s[..prefix_index(s, &bounds, budget)])
}

fn prefix_index(s: &str, bounds: &[usize], budget: usize) -> usize {
    let (mut lo, mut hi) = (0usize, bounds.len());
    while lo + 1 < hi {
        let mid = (lo + hi) / 2;
        if width(&s[..bounds[mid]]) <= budget {
            lo = mid;
        } else {
            hi = mid;
        }
    }

    // Malformed source text can itself end a grapheme with a dangling joiner.
    // Drop that whole grapheme rather than joining it to the added ellipsis.
    while lo > 0 && s[..bounds[lo]].ends_with('\u{200d}') {
        lo -= 1;
    }
    bounds[lo]
}

/// Keep the end of a plain label or path, using a leading ellipsis when it
/// exceeds the viewport. Unlike trim_path, this also bounds a long basename.
pub(crate) fn truncate_left(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    if width(s) <= max {
        return s.to_owned();
    }
    if max == 1 {
        return "…".into();
    }
    let budget = max - 1;
    if s.bytes().all(|byte| (b' '..=b'~').contains(&byte)) {
        return format!("…{}", &s[s.len() - budget..]);
    }
    let mut start = s.len();
    let mut cells = 0;
    for (index, cluster) in s.grapheme_indices(true).rev() {
        let next = cells + width(cluster);
        if next > budget {
            break;
        }
        start = index;
        cells = next;
    }
    // Whole-string width can differ from the sum of grapheme widths. Check
    // the actual retained suffix as well, without cutting inside a cluster.
    while width(&s[start..]) > budget {
        start += s[start..].graphemes(true).next().unwrap().len();
    }
    format!("…{}", &s[start..])
}

/// Yield readable spans and SGR spans without allocating per character. The
/// picker supplies sanitized SGR-only text; discard other terminal commands
/// defensively instead of forwarding cursor movement or OSC strings.
fn ansi_piece<'a>(remaining: &mut &'a str) -> Option<(&'a str, bool)> {
    while !remaining.is_empty() {
        let input = *remaining;
        let bytes = input.as_bytes();
        if bytes[0] == b'\x1b' {
            if bytes.get(1) == Some(&b'[') {
                let end = bytes[2..]
                    .iter()
                    .position(|byte| (b'@'..=b'~').contains(byte))
                    .map(|index| index + 3)
                    .unwrap_or(bytes.len());
                *remaining = &input[end..];
                if bytes.get(end.wrapping_sub(1)) == Some(&b'm')
                    && bytes[2..end - 1]
                        .iter()
                        .all(|byte| byte.is_ascii_digit() || matches!(byte, b';' | b':'))
                {
                    return Some((&input[..end], true));
                }
            } else if matches!(bytes.get(1), Some(b']' | b'P' | b'X' | b'^' | b'_')) {
                let mut end = 2;
                while end < bytes.len() {
                    if bytes[end] == b'\x07' {
                        end += 1;
                        break;
                    }
                    if bytes[end] == b'\x1b' && bytes.get(end + 1) == Some(&b'\\') {
                        end += 2;
                        break;
                    }
                    end += 1;
                }
                *remaining = &input[end..];
            } else {
                let count = if matches!(
                    bytes.get(1),
                    Some(b'(' | b')' | b'*' | b'+' | b'-' | b'.' | b'/')
                ) {
                    3
                } else {
                    2
                };
                let end = input
                    .char_indices()
                    .nth(count)
                    .map_or(input.len(), |(index, _)| index);
                *remaining = &input[end..];
            }
        } else if input.chars().next().unwrap().is_control() {
            *remaining = &input[input.chars().next().unwrap().len_utf8()..];
        } else {
            let end = input
                .char_indices()
                .find(|(_, character)| character.is_control())
                .map_or(input.len(), |(index, _)| index);
            *remaining = &input[end..];
            return Some((&input[..end], false));
        }
    }
    None
}

/// Visible terminal cells of a styled label; SGR between Unicode codepoints
/// must not split the grapheme used for measuring an emoji or combining text.
pub(crate) fn ansi_width(s: &str) -> usize {
    let mut remaining = s;
    if s.is_ascii() {
        let mut cells = 0;
        while let Some((piece, sgr)) = ansi_piece(&mut remaining) {
            if !sgr {
                cells += piece.len();
            }
        }
        return cells;
    }
    if !s.chars().any(char::is_control) {
        return width(s);
    }
    let mut plain = String::with_capacity(s.len());
    while let Some((piece, sgr)) = ansi_piece(&mut remaining) {
        if !sgr {
            plain.push_str(piece);
        }
    }
    width(&plain)
}

/// Clip styled text at the same grapheme boundary as plain truncation. Preserve
/// SGR for the retained prefix, then reset any retained style after the ellipsis.
pub(crate) fn truncate_ansi(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    if !s.chars().any(char::is_control) {
        return truncate(s, max);
    }
    let mut plain = String::with_capacity(s.len());
    let mut remaining = s;
    while let Some((piece, sgr)) = ansi_piece(&mut remaining) {
        if !sgr {
            plain.push_str(piece);
        }
    }
    if plain.is_empty() {
        return String::new();
    }
    let clipped = width(&plain) > max;
    let keep = if clipped {
        truncate(&plain, max).len() - '…'.len_utf8()
    } else {
        plain.len()
    };
    let mut output = String::with_capacity(s.len().min(keep.saturating_add(64)));
    let mut remaining = s;
    let mut copied = 0;
    let mut styled = false;
    while let Some((piece, sgr)) = ansi_piece(&mut remaining) {
        if sgr {
            output.push_str(piece);
            styled = true;
        } else {
            let available = keep - copied;
            if clipped && piece.len() >= available {
                output.push_str(&piece[..available]);
                break;
            }
            output.push_str(piece);
            copied += piece.len();
        }
    }
    if clipped {
        output.push('…');
        if styled {
            output.push_str("\x1b[0m");
        }
    }
    output
}

/// A snapshot's styled label, parsed once for repeated viewport changes.
/// Retain grapheme boundaries across SGR spans: styling can change in the middle
/// of an emoji, and neither parsing nor truncating a span separately is safe.
pub(crate) struct PreparedAnsi {
    text: String,
    plain: String,
    // End offsets in plain and styled text for each readable span.
    spans: Vec<(usize, usize)>,
    bounds: Vec<usize>,
    cells: usize,
    first_style: Option<usize>,
}

impl PreparedAnsi {
    pub(crate) fn new(source: &str) -> Self {
        let mut text = String::with_capacity(source.len());
        let mut plain = String::with_capacity(source.len());
        // Native identities typically have five readable spans. Reserving once
        // avoids several small reallocations per row while building a snapshot.
        let mut spans = Vec::with_capacity(8);
        let mut first_style = None;
        let mut remaining = source;
        while let Some((piece, sgr)) = ansi_piece(&mut remaining) {
            if sgr {
                first_style.get_or_insert(text.len());
                text.push_str(piece);
            } else {
                text.push_str(piece);
                plain.push_str(piece);
                spans.push((plain.len(), text.len()));
            }
        }
        if plain.is_empty() {
            text.clear();
        }
        let cells = width(&plain);
        let bounds = if plain.is_ascii() {
            Vec::new()
        } else {
            let mut bounds = Vec::with_capacity(plain.len().min(128));
            bounds.extend(plain.grapheme_indices(true).map(|(index, _)| index));
            bounds
        };
        Self {
            text,
            plain,
            spans,
            bounds,
            cells,
            first_style,
        }
    }

    pub(crate) fn truncate(&self, max: usize) -> (String, usize) {
        if max == 0 {
            return (String::new(), 0);
        }
        if self.cells <= max {
            return (self.text.clone(), self.cells);
        }
        let keep = if self.bounds.is_empty() {
            max - 1
        } else {
            prefix_index(&self.plain, &self.bounds, max - 1)
        };
        let index = self
            .spans
            .partition_point(|&(plain_end, _)| plain_end < keep);
        let (plain_end, styled_end) = self.spans[index];
        let end = styled_end - (plain_end - keep);
        let mut text = String::with_capacity(end + 7);
        text.push_str(&self.text[..end]);
        text.push('…');
        if self.first_style.map_or(false, |style| style < end) {
            text.push_str("\x1b[0m");
        }
        // Adding an ellipsis after a dangling joiner is prevented by prefix_index.
        let cells = width(&self.plain[..keep]) + 1;
        (text, cells)
    }
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
    if !home.is_empty() && home.chars().all(|c| c == '/') {
        return path
            .strip_prefix('/')
            .map(|rest| {
                if rest.is_empty() {
                    "~".into()
                } else {
                    format!("~/{rest}")
                }
            })
            .unwrap_or_else(|| path.to_owned());
    }
    let home = home.trim_end_matches('/');
    if !home.is_empty() {
        if path == home {
            return "~".into();
        }
        if let Some(rest) = path
            .strip_prefix(home)
            .and_then(|rest| rest.strip_prefix('/'))
        {
            return format!("~/{rest}");
        }
    }
    path.to_string()
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
    fn left_truncation_keeps_the_end_and_handles_zero_and_one_cell_limits() {
        assert_eq!(truncate_left("/very/long/component", 10), "…component");
        assert_eq!(truncate_left("abcdef", 4), "…def");
        assert_eq!(truncate_left("abcdef", 0), "");
        assert_eq!(truncate_left("abcdef", 1), "…");
        assert_eq!(truncate_left("abcdef\u{200b}", 1), "…");
        assert_eq!(truncate_left("abc", 3), "abc");
        assert_eq!(truncate_left("", 0), "");
        assert_eq!(truncate_left("prefix/日本語", 5), "…本語");
    }

    #[test]
    fn left_truncation_preserves_complete_suffix_graphemes() {
        for cluster in ["❤️", "👍🏽", "🇵🇱", "👨‍💻", "👨‍👩‍👧‍👦", "1️⃣", "a\u{301}"]
        {
            let source = format!("long-prefix/{cluster}");
            assert_eq!(
                truncate_left(&source, width(cluster) + 1),
                format!("…{cluster}")
            );
            assert_eq!(truncate_left(&source, width(cluster)), "…");
            for max in 0..width(&source) {
                let clipped = truncate_left(&source, max);
                assert!(width(&clipped) <= max, "{source:?} at {max}: {clipped:?}");
                let suffix = clipped.strip_prefix('…').unwrap_or(&clipped);
                assert!(source.ends_with(suffix));
                let start = source.len() - suffix.len();
                assert!(
                    start == source.len()
                        || source
                            .grapheme_indices(true)
                            .any(|(index, _)| index == start)
                );
            }
        }
    }

    #[test]
    fn ansi_width_ignores_sgr_and_measures_graphemes_across_style_boundaries() {
        assert_eq!(ansi_width("\x1b[31mabc\x1b[0m"), 3);
        assert_eq!(ansi_width("\x1b[38;2;1;2;3m日本\x1b[0m"), 4);
        assert_eq!(ansi_width("\x1b[1m👨\x1b[38:2::1:2:3m‍💻\x1b[0m"), 2);
        assert_eq!(ansi_width("a\x1b[31m\u{301}\x1b[0m"), 1);
        assert_eq!(ansi_width("\x1b[0m"), 0);
    }

    #[test]
    fn ansi_truncation_keeps_prefix_colors_and_resets_after_the_ellipsis() {
        let red = "\x1b[31mabcdef\x1b[0m";
        assert_eq!(truncate_ansi(red, 0), "");
        assert_eq!(truncate_ansi(red, 1), "\x1b[31m…\x1b[0m");
        assert_eq!(truncate_ansi(red, 4), "\x1b[31mabc…\x1b[0m");
        assert_eq!(truncate_ansi(red, 6), red);
        assert_eq!(truncate_ansi("abc", 2), "a…");
        assert_eq!(truncate_ansi("\x1b[0m", 2), "");
        assert_eq!(
            truncate_ansi("\x1b[31mab\x1b[34mcdef\x1b[0m", 3),
            "\x1b[31mab…\x1b[0m"
        );
    }

    #[test]
    fn ansi_truncation_never_splits_colored_unicode_clusters() {
        for cluster in ["❤️", "👍🏽", "🇵🇱", "👨‍💻", "1️⃣", "a\u{301}", "日本"]
        {
            let source = format!("\x1b[32m{cluster}\x1b[1mmore\x1b[0m");
            assert_eq!(
                truncate_ansi(&source, width(cluster) + 1),
                format!("\x1b[32m{cluster}…\x1b[0m")
            );
            for max in 0..12 {
                assert!(ansi_width(&truncate_ansi(&source, max)) <= max);
            }
        }
        let split_emoji = "\x1b[32m👨\x1b[1m‍💻more\x1b[0m";
        assert_eq!(truncate_ansi(split_emoji, 3), "\x1b[32m👨\x1b[1m‍💻…\x1b[0m");
        assert_eq!(truncate_ansi(split_emoji, 2), "\x1b[32m…\x1b[0m");
    }

    #[test]
    fn measured_ansi_clipping_reports_actual_cells_including_short_grapheme_cuts() {
        for source in [
            "plain text",
            "\x1b[31mascii\x1b[0m",
            "\x1b[32m👨\x1b[1m‍💻wide 日本語\x1b[0m",
            "\x1b[31m❤️👍🏽🇵🇱e\u{301}end\x1b[0m",
            "\x1b]0;title\x07\x1b[2Jab\ncd\x1b[31m",
            "\x1b[0m",
        ] {
            for budget in 0..24 {
                let (text, cells) = PreparedAnsi::new(source).truncate(budget);
                assert_eq!(cells, ansi_width(&text), "{source:?} at {budget}");
                assert!(cells <= budget, "{source:?} at {budget}");
            }
        }
        // A two-cell grapheme cannot fill a two-cell budget with an ellipsis;
        // reporting the budget instead of the actual width would misalign it.
        assert_eq!(PreparedAnsi::new("\x1b[31m日本\x1b[0m").truncate(2).1, 1);
    }

    #[test]
    fn prepared_ansi_matches_safe_clipping_at_every_budget_and_style_boundary() {
        for plain in ["ascii", "日本語", "👨‍💻🇵🇱❤️👍🏽e\u{301}", "c\u{200d}tail"]
        {
            // Move SGR into every character boundary, including inside emoji
            // graphemes, rather than testing only neatly styled whole words.
            for index in plain
                .char_indices()
                .map(|(index, _)| index)
                .chain([plain.len()])
            {
                let source = format!(
                    "\x1b[32m{}\x1b[1m{}\x1b[0m",
                    &plain[..index],
                    &plain[index..]
                );
                let prepared = PreparedAnsi::new(&source);
                for budget in 0..=width(plain) + 2 {
                    let (actual, cells) = prepared.truncate(budget);
                    assert_eq!(
                        actual,
                        truncate_ansi(&source, budget),
                        "{source:?}, {budget}"
                    );
                    assert_eq!(cells, ansi_width(&actual));
                    assert!(cells <= budget);
                }
            }
        }
        for source in [
            "",
            "\x1b[31m",
            "\x1b]0;title\x07ab\x1b[2Jcd\x1b[",
            "abc\n\tdef",
        ] {
            let prepared = PreparedAnsi::new(source);
            for budget in 0..12 {
                let expected = truncate_ansi(source, budget);
                assert_eq!(
                    prepared.truncate(budget),
                    (expected.clone(), ansi_width(&expected))
                );
            }
        }
    }

    #[test]
    fn ansi_helpers_discard_non_sgr_terminal_commands_and_unfinished_sequences() {
        let source = "\x1b]0;invisible title\x07a\x1b[2Jb\x1bPignored\x1b\\c\n\x1b[31";
        assert_eq!(ansi_width(source), 3);
        assert_eq!(truncate_ansi(source, 20), "abc");
        assert_eq!(truncate_ansi(source, 2), "a…");
        for source in ["\x1b", "\x1b[", "\x1b]unterminated", "\x1bPunterminated"] {
            assert_eq!(ansi_width(source), 0);
            assert_eq!(truncate_ansi(source, 10), "");
        }
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
                    !matches!(
                        before,
                        Some('\u{200d}') | Some('\u{fe0f}') | Some('\u{fe0e}')
                    ),
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
    fn truncation_preserves_complete_emoji_and_combining_graphemes() {
        for cluster in ["❤️", "👍🏽", "🇵🇱", "👨‍💻", "👨‍👩‍👧‍👦", "1️⃣", "a\u{301}"]
        {
            let source = format!("{cluster}more");
            let cells = width(cluster);
            assert_eq!(truncate(&source, cells + 1), format!("{cluster}…"));
            assert_eq!(truncate(&source, cells), "…");
            for max in 0..width(&source) {
                let shortened = truncate(&source, max);
                assert!(width(&shortened) <= max);
                let prefix = shortened.strip_suffix('…').unwrap_or(&shortened);
                assert!(source
                    .grapheme_indices(true)
                    .any(|(index, _)| index == prefix.len()));
            }
        }
        assert_eq!(truncate("c\u{200d}tail", 2), "…");
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
        // A sibling with the same prefix is not inside this home directory.
        assert_eq!(
            tildify("/home/user/project", "/home/u"),
            "/home/user/project"
        );
        assert_eq!(tildify("/home/u-other", "/home/u"), "/home/u-other");
        assert_eq!(tildify("/home/u", "/home/u/"), "~");
        assert_eq!(tildify("/home/u/x", "/home/u/"), "~/x");
        assert_eq!(tildify("/tmp", ""), "/tmp");
        assert_eq!(tildify("/tmp", "/"), "~/tmp");
        assert_eq!(tildify("/", "/"), "~");
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
