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
        // not a state word: no state (bash tr_parse); the rule still matches
        let state = match state {
            "approve" | "input" | "working" | "idle" | "done" | "error" => state,
            _ => "-",
        };
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
fn capture(parts: &[String], t: &str) -> Option<Vec<String>> {
    let first = &parts[0];
    let rest = t.strip_prefix(first.as_str())?;
    if parts.len() == 1 {
        return if rest.is_empty() { Some(vec![]) } else { None };
    }
    // candidate ends for this star, longest first, on char boundaries
    let mut ends: Vec<usize> = rest.char_indices().map(|(i, _)| i).collect();
    ends.push(rest.len());
    for &e in ends.iter().rev() {
        if let Some(mut more) = capture(&parts[1..], &rest[e..]) {
            let mut caps = vec![rest[..e].to_string()];
            caps.append(&mut more);
            return Some(caps);
        }
    }
    None
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
    fn a_state_that_is_not_a_state_word_is_none() {
        let rules = parse("x waiting $1 [?] *\nx Approve = !! *\nx done - ok\n");
        let a = |t: &str| apply(&rules, "x", t).map(|h| (h.state, h.desc));
        assert_eq!(a("[?] Pick one"), Some(("".into(), "Pick one".into())));
        assert_eq!(a("!! Now"), Some(("".into(), "!! Now".into())));
        assert_eq!(a("ok"), Some(("done".into(), "".into())));
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
