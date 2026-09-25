//! Rules: how a pane's title, or an option an agent plugin published for it,
//! becomes a state word and a description.  bash owns the rule text
//! (DEFAULT_TITLE_RULES plus the user's @interdimux-title-rules file) and
//! hands it over whole as INTERDIMUX_TITLE_RULESET; this is bash
//! `load_title_rules`, `title_rule_r`, `option_rule_r`, `title_text_r` and
//! `title_glyph_r`, rule for rule.
//!
//!   APPS      STATE  DESC  PATTERN     a title rule
//!   @OPTIONS  STATE  DESC  PATTERN     an option rule
//!
//! PATTERN is literal text anchored at both ends in which each `*` captures,
//! greedily from the left -- what POSIX's leftmost-longest subexpression rule
//! gives the ERE bash compiles it to.  A leading `%spin` matches one braille
//! spinner glyph.

use crate::proc::sanitize;

pub struct Rule {
    /// an option rule: `apps` names tmux options
    opt: bool,
    apps: String,
    state: String,
    desc: String,
    spin: bool,
    /// the literal pieces between the `*`s: n stars, n + 1 pieces
    parts: Vec<String>,
}

pub struct Hit {
    pub state: String,
    pub desc: String,
}

/// Split off the next blank-separated word (bash `read` with IFS whitespace).
fn word(s: &str) -> (&str, &str) {
    let s = s.trim_start_matches(' ');
    match s.find(' ') {
        Some(i) => (&s[..i], &s[i..]),
        None => (s, ""),
    }
}

pub fn parse(text: &str) -> Vec<Rule> {
    let mut rules = Vec::new();
    for line in text.split('\n') {
        let line = line.replace(['\t', '\r'], " ");
        let (apps, r) = word(&line);
        let (state, r) = word(r);
        let (desc, r) = word(r);
        let pat = r.trim_matches(' ');
        if pat.is_empty() || apps.starts_with('#') {
            continue;
        }
        let (spin, pat) = match pat.strip_prefix("%spin") {
            Some(p) => (true, p),
            None => (false, pat),
        };
        rules.push(Rule {
            opt: apps.starts_with('@'),
            apps: apps.to_string(),
            state: state.to_string(),
            desc: desc.to_string(),
            spin,
            parts: pat.split('*').map(str::to_string).collect(),
        });
    }
    rules
}

/// Match `t` against the pieces, each star taking as much as it can while the
/// rest still matches.  Returns the captures.
///
/// In linear time: the pattern is literals L0 * L1 * ... * Ln, anchored at
/// both ends, so L0 is a prefix and Ln a suffix, and the first star is longest
/// when L1 sits as far right as the pieces after it allow.  Placing the middle
/// pieces from the right, each at its LAST occurrence that ends before the
/// piece after it (and starts after L0), gives every piece its rightmost
/// possible place at once, and the captures are the gaps: what POSIX's
/// leftmost-longest rule gives bash's ERE, and what a search trying every end
/// of every star, longest first, finds.  That search was the old code (kept in
/// the tests, which compare the two), and it backtracked: a title of 1,600
/// `a:` under the default `*:*:* - "*"*` remote-shell rule took 12 s to fail
/// (review R01).
fn capture(parts: &[String], t: &str) -> Option<Vec<String>> {
    let n = parts.len();
    let first = parts[0].as_str();
    if n == 1 {
        return (t == first).then(Vec::new);
    }
    let last = parts[n - 1].as_str();
    if !t.starts_with(first) || !t.ends_with(last) || first.len() + last.len() > t.len() {
        return None;
    }
    let lo = first.len();
    // where each piece starts; all on char boundaries (a match of a str is)
    let mut at = vec![0; n];
    at[n - 1] = t.len() - last.len();
    for j in (1..n - 1).rev() {
        at[j] = lo + t[lo..at[j + 1]].rfind(parts[j].as_str())?;
    }
    let mut caps = Vec::with_capacity(n - 1);
    let mut from = lo;
    for j in 1..n {
        caps.push(t[from..at[j]].to_string());
        from = at[j] + parts[j].len();
    }
    Some(caps)
}

fn is_spinner(c: char) -> bool {
    ('\u{2800}'..='\u{28ff}').contains(&c)
}

/// DESC for these captures and the whole text `t`.
fn expand(tpl: &str, caps: &[String], t: &str) -> String {
    match tpl {
        "-" => String::new(),
        "=" => t.to_string(),
        tpl => {
            let mut out = String::new();
            let mut it = tpl.chars().peekable();
            while let Some(c) = it.next() {
                match (c, it.peek()) {
                    ('$', Some(&d)) if ('1'..='9').contains(&d) => {
                        it.next();
                        let n = d as usize - '1' as usize;
                        out.push_str(caps.get(n).map(String::as_str).unwrap_or(""));
                    }
                    _ => out.push(c),
                }
            }
            out
        }
    }
}

/// Strip a leading spinner glyph when the rule asks for one.
fn despin(spin: bool, s: &str) -> Option<&str> {
    if !spin {
        return Some(s);
    }
    match s.chars().next() {
        Some(c) if is_spinner(c) => Some(&s[c.len_utf8()..]),
        _ => None,
    }
}

/// The option rules over a pane's published options: one value per name in
/// `names`, in order, each ended by GS (an empty value is an unset option).
/// The first state an option rule gives, and the first description.
pub fn apply_options(rules: &[Rule], names: &[String], opts: &str) -> (String, String) {
    let (mut state, mut desc) = (String::new(), String::new());
    let mut val: std::collections::HashMap<&str, &str> = Default::default();
    for (n, v) in names.iter().zip(opts.split('\u{1d}')) {
        if !v.is_empty() {
            val.insert(n.as_str(), v);
        }
    }
    if val.is_empty() {
        return (state, desc);
    }
    for r in rules.iter().filter(|r| r.opt) {
        for o in r.apps.split(',') {
            let o = o.strip_prefix('@').unwrap_or(o);
            let whole = match val.get(o) {
                Some(v) if !o.is_empty() => *v,
                _ => continue,
            };
            let v = match despin(r.spin, whole) {
                Some(v) => v,
                None => continue,
            };
            let caps = match capture(&r.parts, v) {
                Some(c) => c,
                None => continue,
            };
            if state.is_empty() && r.state != "-" {
                state = r.state.clone();
            }
            if desc.is_empty() {
                desc = expand(&r.desc, &caps, whole);
            }
            break;
        }
        if !state.is_empty() && !desc.is_empty() {
            break;
        }
    }
    (state, desc)
}

/// The first title rule for `name` whose pattern matches title text `t`.
pub fn apply(rules: &[Rule], name: &str, t: &str) -> Option<Hit> {
    for r in rules.iter().filter(|r| !r.opt) {
        if r.apps != "*" && !r.apps.split(',').any(|a| !a.is_empty() && a == name) {
            continue;
        }
        let s = match despin(r.spin, t) {
            Some(s) => s,
            None => continue,
        };
        let caps = match capture(&r.parts, s) {
            Some(c) => c,
            None => continue,
        };
        let state = if r.state == "-" { String::new() } else { r.state.clone() };
        return Some(Hit { state, desc: expand(&r.desc, &caps, t) });
    }
    None
}

fn is_bidi(c: char) -> bool {
    matches!(c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{200e}' | '\u{200f}')
}

fn is_status_glyph(c: char) -> bool {
    is_spinner(c) || c == '\u{2733}' || ('\u{25d0}'..='\u{25d3}').contains(&c)
}

fn is_vs(c: char) -> bool {
    c == '\u{fe0e}' || c == '\u{fe0f}'
}

/// A title's text before any rule sees it (bash title_text_r).
pub fn text(t: &str) -> String {
    let t: String = sanitize(t).chars().filter(|&c| !is_bidi(c)).collect();
    t.trim_matches(' ').to_string()
}

/// One leading status glyph dropped, with its selector and blanks (bash
/// title_glyph_r).
pub fn glyph(t: &str) -> String {
    let mut t = t.trim_start_matches(' ');
    if let Some(c) = t.chars().next() {
        if is_vs(c) {
            t = t[c.len_utf8()..].trim_start_matches(' ');
        }
    }
    if let Some(c) = t.chars().next() {
        if is_status_glyph(c) {
            t = &t[c.len_utf8()..];
            if let Some(v) = t.chars().next() {
                if is_vs(v) {
                    t = &t[v.len_utf8()..];
                }
            }
            t = t.trim_start_matches(' ');
        }
    }
    t.trim_end_matches(' ').to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn caps(p: &str, t: &str) -> Option<Vec<String>> {
        let parts: Vec<String> = p.split('*').map(str::to_string).collect();
        capture(&parts, t)
    }

    #[test]
    fn stars_capture_greedily_from_the_left_and_patterns_are_anchored() {
        assert_eq!(caps("* | *", "a | b | c"), Some(vec!["a | b".into(), "c".into()]));
        assert_eq!(caps("x*", "xyz"), Some(vec!["yz".into()]));
        assert_eq!(caps("x*", "axyz"), None);
        assert_eq!(caps("abc", "abc"), Some(vec![]));
        assert_eq!(caps("abc", "abcd"), None);
        assert_eq!(caps("*", ""), Some(vec!["".into()]));
        assert_eq!(caps("[ ! ] A*", "[ ! ] A b"), Some(vec![" b".into()]));
        assert_eq!(caps("✦ *", "✦ Working…"), Some(vec!["Working…".into()]));
        // every ERE special is literal, a backslash first of all
        assert_eq!(caps("a\\b(*)", "a\\b(x)"), Some(vec!["x".into()]));
        assert_eq!(caps("a\\b", "ab"), None);
        assert_eq!(caps("^.$|?+{}[]", "^.$|?+{}[]"), Some(vec![]));
    }

    /// The matcher this replaced: every end of every star, longest first.
    /// Exponential on a title that almost matches, and the definition the
    /// linear one has to agree with.
    fn capture_backtrack(parts: &[String], t: &str) -> Option<Vec<String>> {
        let rest = t.strip_prefix(parts[0].as_str())?;
        if parts.len() == 1 {
            return if rest.is_empty() { Some(vec![]) } else { None };
        }
        let mut ends: Vec<usize> = rest.char_indices().map(|(i, _)| i).collect();
        ends.push(rest.len());
        for &e in ends.iter().rev() {
            if let Some(mut more) = capture_backtrack(&parts[1..], &rest[e..]) {
                let mut caps = vec![rest[..e].to_string()];
                caps.append(&mut more);
                return Some(caps);
            }
        }
        None
    }

    /// xorshift64*: the same cases on every run, no dependency
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 >> 12;
            self.0 ^= self.0 << 25;
            self.0 ^= self.0 >> 27;
            self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
        }
        fn below(&mut self, n: usize) -> usize {
            (self.next() % n as u64) as usize
        }
        fn text(&mut self, alphabet: &[&str], max: usize) -> String {
            let n = self.below(max + 1);
            (0..n).map(|_| alphabet[self.below(alphabet.len())]).collect()
        }
    }

    #[test]
    fn the_linear_matcher_captures_exactly_what_the_backtracking_one_did() {
        // A small alphabet, so that pieces recur and overlap in the titles:
        // that is where a placement can go wrong.  Multibyte on purpose.
        let alphabet = ["a", "b", ":", " ", "é", "中"];
        let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
        let (mut cases, mut hits) = (0, 0);
        for _ in 0..200_000 {
            let stars = rng.below(5);
            let parts: Vec<String> = (0..=stars).map(|_| rng.text(&alphabet, 2)).collect();
            // half the titles are built from the pattern, so that many match
            let t = if rng.below(2) == 0 {
                rng.text(&alphabet, 12)
            } else {
                let mut t = String::new();
                for (i, p) in parts.iter().enumerate() {
                    if i > 0 {
                        t.push_str(&rng.text(&alphabet, 4));
                    }
                    t.push_str(p);
                }
                t
            };
            let want = capture_backtrack(&parts, &t);
            assert_eq!(capture(&parts, &t), want, "pattern {:?} title {:?}", parts.join("*"), t);
            cases += 1;
            hits += want.is_some() as usize;
        }
        // the comparison is only as good as its matches
        assert!(hits > cases / 5, "{} matches in {} cases", hits, cases);
    }

    #[test]
    fn pieces_at_both_ends_are_anchored_and_never_overlap() {
        assert_eq!(caps("a*a", "a"), None);
        assert_eq!(caps("a*a", "aa"), Some(vec!["".into()]));
        assert_eq!(caps("ab*ba", "aba"), None);
        assert_eq!(caps("*:*", ":"), Some(vec!["".into(), "".into()]));
        // two stars in a row: the first takes it all
        assert_eq!(caps("x**y", "xaby"), Some(vec!["ab".into(), "".into()]));
        assert_eq!(caps("*a*a*", "aaaa"), Some(vec!["aa".into(), "".into(), "".into()]));
        assert_eq!(caps("é*中", "é中中"), Some(vec!["中".into()]));
    }

    #[test]
    fn a_title_that_almost_matches_costs_linear_time() {
        // The default remote-shell rule against 1,600 `a:` and no ` - "`: the
        // backtracking matcher took 12 s on this (release build).
        let parts: Vec<String> = "*:*:* - \"*\"*".split('*').map(str::to_string).collect();
        let t = "a:".repeat(1600);
        let t0 = std::time::Instant::now();
        assert_eq!(capture(&parts, &t), None);
        let long = format!("{} - \"{}\"x", "a:".repeat(20_000), "b".repeat(20_000));
        assert!(capture(&parts, &long).is_some());
        let spent = t0.elapsed();
        assert!(spent < std::time::Duration::from_millis(500), "{:?}", spent);
    }

    #[test]
    fn the_first_matching_rule_for_the_app_wins() {
        let rules = parse(
            "# comment\n\
             codex\tapprove  $1  [ ! ] Action Required | * | *\n\
             codex working $1 %spin * | *\n\
             codex - $1 * | *\n\
             codex - - *\n\
             *   -  =  *@*\n",
        );
        let a = |n: &str, t: &str| apply(&rules, n, t).map(|h| (h.state, h.desc));
        assert_eq!(a("codex", "[ ! ] Action Required | Add tests | app"), Some(("approve".into(), "Add tests".into())));
        assert_eq!(a("codex", "⠋ Fix | app"), Some(("working".into(), "Fix".into())));
        assert_eq!(a("codex", "Fix | app"), Some(("".into(), "Fix".into())));
        assert_eq!(a("codex", "app"), Some(("".into(), "".into())));
        assert_eq!(a("docker", "root@3f2a: /app"), Some(("".into(), "root@3f2a: /app".into())));
        assert_eq!(a("docker", "plain"), None);
    }

    #[test]
    fn option_rules_give_the_first_state_and_the_first_description() {
        let rules = parse(
            "codex working - *\n\
             @pane_status working - running\n\
             @pane_wait_reason approve - permission_prompt\n\
             @pane_status input - waiting\n\
             @a,@b done - 1\n\
             @agent_desc - = *\n",
        );
        let names: Vec<String> =
            ["pane_status", "pane_wait_reason", "a", "b", "agent_desc"].iter().map(|s| s.to_string()).collect();
        // values by position, each ended by GS
        let o = |vals: [&str; 5]| {
            let s: String = vals.iter().map(|v| format!("{}\u{1d}", v)).collect();
            apply_options(&rules, &names, &s)
        };
        assert_eq!(o(["running", "", "", "", ""]), ("working".into(), "".into()));
        // the reason's rule comes first, whatever order tmux sent them in
        assert_eq!(o(["waiting", "permission_prompt", "", "", ""]), ("approve".into(), "".into()));
        assert_eq!(o(["waiting", "", "", "", ""]), ("input".into(), "".into()));
        assert_eq!(o(["", "", "", "1", "Fix it"]), ("done".into(), "Fix it".into()));
        assert_eq!(o(["", "", "0", "", ""]), ("".into(), "".into()));
        assert_eq!(apply_options(&rules, &names, ""), ("".into(), "".into()));
        // fewer values than names (a line cut in the field): the rest unset
        assert_eq!(apply_options(&rules, &names, "running\u{1d}"), ("working".into(), "".into()));
        // a title rule never reads options, and an option rule never a title
        assert!(apply(&rules, "pane_status", "running").is_none());
    }

    #[test]
    fn a_template_mixes_text_and_captures() {
        let rules = parse("x - [$2]$1$9$ *:*\n");
        let h = apply(&rules, "x", "a:b").unwrap();
        assert_eq!(h.desc, "[b]a$");
    }

    #[test]
    fn titles_lose_padding_bidi_and_one_status_glyph() {
        assert_eq!(text("  gemini ready      "), "gemini ready");
        assert_eq!(text("a\u{202e}b"), "ab");
        assert_eq!(glyph("✳ Project review"), "Project review");
        assert_eq!(glyph("◐\u{fe0e} qwen task"), "qwen task");
        assert_eq!(glyph("\u{fe0e} task"), "task");
        assert_eq!(glyph("✳ ✳ x"), "✳ x");
        assert_eq!(glyph("x ✳"), "x ✳");
    }
}
