//! Agents: what an AI coding agent's pane tells tmux, shown in the command
//! field -- `claude working 2m Project review and suggestions`.
//!
//! A port of bash `agent_of` and `cmd_field` (see the
//! "Agents" section of scripts/interdimux.sh for the why of every rule).  The
//! Claude registry is read by bash, once per list, and arrives here as the
//! fifth input section; this module only merges it into the row.

use std::collections::HashMap;

use crate::format::format_command;
use crate::palette::{Palette, RST};
use crate::proc::is_idle_shell;
use crate::text::age_of;
use crate::titles;

/// Recognised by argv0's basename (bash AGENT_KNOWN).
const KNOWN: &[&str] = &[
    "claude", "codex", "gemini", "qwen", "opencode", "amp", "goose", "crush", "kiro-cli",
    "kiro-cli-chat", "aider", "copilot", "cursor-agent",
];
/// Installed as a script an interpreter runs (bash AGENT_SCRIPTS).
const SCRIPTS: &[&str] = &["codex", "gemini", "qwen", "copilot", "crush", "aider"];

#[derive(PartialEq, Eq, Clone, Copy)]
pub enum ShowTitle {
    /// titles of agents and of apps a rule knows
    Known,
    All,
    Off,
}

pub struct Config {
    pub show_title: ShowTitle,
    pub title_max: usize,
    pub known: Vec<String>,
    pub scripts: Vec<String>,
    pub keep_args: bool,
    pub state: bool,
    pub host: String,
    pub host_short: String,
    pub rules: Vec<titles::Rule>,
    /// the option names whose values a pane line carries, in order
    pub state_opts: Vec<String>,
}

/// One registry record: the pane shell's pid (empty: unchecked), the state
/// word, and since when (epoch seconds).
pub struct Record {
    pub sid: String,
    pub word: String,
    pub since: i64,
}
pub type Registry = HashMap<String, Record>;

impl Config {
    /// From the environment bash hands over; every value is already
    /// normalised there, and these defaults are bash's.
    pub fn from_env(host: &str, host_short: &str) -> Self {
        let var = |k: &str| std::env::var(k).unwrap_or_default();
        let show_title = match var("INTERDIMUX_SHOW_TITLE").as_str() {
            "all" => ShowTitle::All,
            "off" => ShowTitle::Off,
            _ => ShowTitle::Known,
        };
        let title_max = title_max(&var("INTERDIMUX_TITLE_MAX"));
        let names = var("INTERDIMUX_AGENTS");
        let (mut known, mut scripts): (Vec<String>, Vec<String>) = if names == "off" {
            (vec![], vec![])
        } else {
            (
                KNOWN.iter().map(|s| s.to_string()).collect(),
                SCRIPTS.iter().map(|s| s.to_string()).collect(),
            )
        };
        if names != "off" {
            for w in names.split([' ', '\t', '\n']).filter(|w| !w.is_empty()) {
                if w.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-') {
                    known.push(w.to_string());
                    scripts.push(w.to_string());
                }
            }
        }
        Config {
            show_title,
            title_max,
            known,
            scripts,
            keep_args: var("INTERDIMUX_AGENT_ARGS") == "on",
            state: var("INTERDIMUX_AGENT_STATE") != "off",
            host: host.to_string(),
            host_short: host_short.to_string(),
            rules: titles::parse(&var("INTERDIMUX_TITLE_RULESET")),
            state_opts: var("INTERDIMUX_STATE_OPTS")
                .split([' ', '\t', '\n'])
                .filter(|w| !w.is_empty())
                .map(str::to_string)
                .collect(),
        }
    }

    /// Anything to do at all (bash AGENT_ON).
    fn on(&self) -> bool {
        self.show_title != ShowTitle::Off || self.state || !self.known.is_empty()
    }
}

/// @interdimux-title-max as bash normalises it: digits only (anything else is
/// the default, 40), read as DECIMAL whatever the leading zeros, and clamped to
/// 8..=200 -- a number too long to parse is more than 200.  bash hands over
/// the value it normalised, so this matters only for a value set straight in
/// the environment, where the two renderers must still agree.
fn title_max(v: &str) -> usize {
    if v.is_empty() || !v.bytes().all(|b| b.is_ascii_digit()) {
        return 40;
    }
    let d = v.trim_start_matches('0');
    if d.len() > 3 {
        return 200;
    }
    d.parse::<usize>().unwrap_or(0).clamp(8, 200)
}

/// The fifth input section: `<%pane>US<sid>US<word>US<since>` per line.
pub fn parse_registry(raw: &str) -> Registry {
    let mut reg = Registry::new();
    for l in raw.lines() {
        if !l.starts_with('%') || !l.contains('\u{1f}') {
            continue;
        }
        let mut f = l.splitn(4, '\u{1f}');
        let pane = f.next().unwrap_or("").to_string();
        let sid = f.next().unwrap_or("").to_string();
        let word = f.next().unwrap_or("").to_string();
        let since = f.next().unwrap_or("");
        let since = if !since.is_empty() && since.bytes().all(|b| b.is_ascii_digit()) {
            since.parse().unwrap_or(0)
        } else {
            0
        };
        reg.insert(pane, Record { sid, word, since });
    }
    reg
}

fn basename(s: &str) -> &str {
    s.rsplit('/').next().unwrap_or(s)
}

/// Is argv an agent?  (name, the arguments after what names it)
pub fn agent_of<'a>(s: &'a str, cfg: &Config) -> Option<(String, &'a str)> {
    if cfg.known.is_empty() {
        return None;
    }
    let a0 = s.split(' ').next().unwrap_or("");
    let b = basename(a0);
    let after = &s[a0.len()..];
    if !b.is_empty() && cfg.known.iter().any(|k| k == b) {
        return Some((b.to_string(), after));
    }
    if a0.contains("/claude/versions/") {
        return Some(("claude".to_string(), after));
    }
    let interp = matches!(b, "node" | "nodejs")
        || b.strip_prefix("python")
            .is_some_and(|v| v.chars().all(|c| c.is_ascii_digit() || c == '.'));
    if !interp {
        return None;
    }
    let r1 = after.strip_prefix(' ').unwrap_or(after);
    let w1 = r1.split(' ').next().unwrap_or("");
    let wb = basename(w1);
    if wb.is_empty() || w1.starts_with('-') {
        return None;
    }
    if cfg.scripts.iter().any(|k| k == wb) {
        return Some((wb.to_string(), &r1[w1.len()..]));
    }
    None
}

/// A prompt of this host (the same test in bash cmd_field): `@host`
/// where the name ends -- at the end or at a character a host name cannot
/// hold, so `web` is not `web-7d4b9c` -- or fish's `[host]` head, the name cut
/// to 10 characters, on its prompt and command lines alike.
fn this_host_prompt(desc: &str, hs: &str) -> bool {
    if hs.is_empty() {
        return false;
    }
    let at = format!("@{}", hs);
    let mut from = 0;
    while let Some(k) = desc[from..].find(&at) {
        let end = from + k + at.len();
        match desc[end..].chars().next() {
            None => return true,
            Some(c) if !(c.is_ascii_alphanumeric() || c == '_' || c == '-') => return true,
            _ => {}
        }
        // past this '@' (one byte, so still a char boundary)
        from += k + 1;
    }
    let tag = format!("[{}]", hs.chars().take(10).collect::<String>());
    desc == tag || desc.strip_prefix(tag.as_str()).is_some_and(|r| r.starts_with(' '))
}

/// A description that only repeats the row: the app's own name, tmux's
/// default title (the host name), a prompt of this host, or -- from a preexec
/// hook -- the command line itself.
fn repeats_row(desc: &str, name: &str, raw: &str, cfg: &Config) -> bool {
    if desc == name || desc == cfg.host || desc == cfg.host_short || this_host_prompt(desc, &cfg.host_short) {
        return true;
    }
    let a0 = raw.split(' ').next().unwrap_or("");
    let b = basename(a0);
    let b = b.strip_prefix('-').unwrap_or(b);
    let mut w = "";
    for x in desc.split(' ').filter(|x| !x.is_empty()) {
        w = x;
        // a prefix that is itself argv0: `sudo docker run ...` on a sudo row
        if basename(x) == b {
            break;
        }
        if x.contains('=')
            || matches!(
                x,
                "sudo" | "env" | "nohup" | "exec" | "time" | "command" | "builtin" | "noglob" | "nice"
            )
        {
            continue;
        }
        break;
    }
    let after = &raw[a0.len()..];
    // unstripped, as bash's `case "$b"` sees it: `-node` is no interpreter
    let r = if crate::format::is_interpreter(basename(a0)) {
        after.strip_prefix(' ').unwrap_or(after).split(' ').next().unwrap_or("")
    } else {
        ""
    };
    basename(w) == b || (!r.is_empty() && basename(w) == basename(r))
}

fn cap(s: String, max: usize) -> String {
    if s.chars().count() > max {
        let mut t: String = s.chars().take(max - 1).collect();
        t.push('…');
        t
    } else {
        s
    }
}

/// The command field of a window or pane row (bash cmd_field).
#[allow(clippy::too_many_arguments)]
pub fn command_field(
    raw: &str,
    pid: u32,
    pane: &str,
    title: &str,
    opts: &str,
    cfg: &Config,
    reg: &Registry,
    p: &Palette,
    now: i64,
) -> String {
    let fc = format_command(raw, p).0;
    if !cfg.on() || fc.is_empty() || is_idle_shell(raw) {
        return fc;
    }
    let agent = agent_of(raw, cfg);
    let a0 = raw.split(' ').next().unwrap_or("");
    let b0 = basename(a0);
    let name: &str = match &agent {
        Some((n, _)) => n.as_str(),
        None => b0.strip_prefix('-').unwrap_or(b0),
    };
    let mut agent_row = agent.is_some();
    let mut state = String::new();
    let mut since = 0i64;
    if cfg.state && !pane.is_empty() {
        if let Some(r) = reg.get(pane) {
            if r.sid.is_empty() || r.sid == pid.to_string() {
                state = r.word.clone();
                since = r.since;
                agent_row = true;
            }
        }
    }
    let mut desc = String::new();
    let mut known = false;
    // then what a plugin or a hook published, then the title
    let mut odesc = String::new();
    if opts.chars().any(|c| c != '\u{1d}') {
        let (os, od) = titles::apply_options(&cfg.rules, &cfg.state_opts, opts);
        if cfg.state && state.is_empty() && !os.is_empty() {
            state = os;
            agent_row = true;
        }
        odesc = titles::text(&od);
        if !odesc.is_empty() {
            agent_row = true;
        }
    }
    if !odesc.is_empty() {
        desc = odesc;
        known = true;
    } else if !title.is_empty() {
        let t = titles::text(title);
        match titles::apply(&cfg.rules, name, &t) {
            Some(h) => {
                known = true;
                desc = h.desc;
                if cfg.state && state.is_empty() && !h.state.is_empty() {
                    state = h.state;
                    agent_row = true;
                }
            }
            None => desc = t,
        }
        desc = titles::glyph(&desc);
    }
    match cfg.show_title {
        ShowTitle::Off => desc.clear(),
        ShowTitle::Known if !known && !agent_row => desc.clear(),
        _ => {}
    }
    if !desc.is_empty() {
        if repeats_row(&desc, name, raw, cfg) {
            desc.clear();
        }
        desc = cap(desc, cfg.title_max);
    }
    if !agent_row && desc.is_empty() {
        return fc;
    }
    let mut extra = String::new();
    if !state.is_empty() {
        let col = match state.as_str() {
            "approve" | "error" => &p.bold_red,
            "input" => &p.bold_amber,
            _ => &p.dim_tree,
        };
        extra.push_str(&format!(" {}{}{}", col, &state, RST));
        let age = age_of(since, now);
        if !age.is_empty() {
            extra.push_str(&format!(" {}{}{}", p.dim_tree, age, RST));
        }
    }
    if !desc.is_empty() {
        extra.push_str(&format!(" {}{}{}", p.dim_edit, desc, RST));
    }
    let (name, rest) = match &agent {
        None => return format!("{}{}", fc, extra),
        Some((n, r)) => (n.as_str(), *r),
    };
    let rest = if !extra.is_empty() && !cfg.keep_args { "" } else { rest };
    if extra.is_empty() {
        format!("{}{}{}{}", p.dim_cmd, name, rest, RST)
    } else if !rest.is_empty() {
        format!("{}{}{}{}{}{}{}", p.dim_cmd, name, RST, extra, p.dim_cmd, rest, RST)
    } else {
        format!("{}{}{}{}", p.dim_cmd, name, RST, extra)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> Config {
        Config {
            show_title: ShowTitle::Known,
            title_max: 40,
            known: KNOWN.iter().map(|s| s.to_string()).collect(),
            scripts: SCRIPTS.iter().map(|s| s.to_string()).collect(),
            keep_args: false,
            state: true,
            host: "box.example.com".into(),
            host_short: "box".into(),
            rules: vec![],
            state_opts: vec![],
        }
    }

    #[test]
    fn agents_are_named_by_what_they_are() {
        let c = cfg();
        let n = |s: &str| agent_of(s, &c).map(|a| (a.0, a.1.to_string()));
        assert_eq!(n("claude --resume x"), Some(("claude".into(), " --resume x".into())));
        assert_eq!(n("/home/u/.local/share/claude/versions/2.1.281 -c"), Some(("claude".into(), " -c".into())));
        assert_eq!(n("node /home/u/.nvm/v/bin/codex resume"), Some(("codex".into(), " resume".into())));
        assert_eq!(n("python3.12 /home/u/.local/bin/aider --model x"), Some(("aider".into(), " --model x".into())));
        // not the script word, or not an agent script
        assert_eq!(n("node --inspect /x/codex"), None);
        assert_eq!(n("node /x/server.js"), None);
        assert_eq!(n("pythonw /x/aider"), None);
        assert_eq!(n("vim codex"), None);
        // `off` recognises nothing
        let mut off = cfg();
        off.known.clear();
        off.scripts.clear();
        assert!(agent_of("claude", &off).is_none());
    }

    #[test]
    fn titles_that_repeat_the_row_are_recognised() {
        let c = cfg();
        assert!(repeats_row("box", "", "sleep 3", &c));
        assert!(repeats_row("u@box:~/x", "", "sleep 3", &c));
        assert!(repeats_row("sleep 30 && echo done", "", "sleep 30", &c));
        assert!(repeats_row("FOO=1 sudo make -j8", "", "make -j8", &c));
        assert!(repeats_row("python3 ./manage.py runserver", "", "/usr/bin/python3 /h/manage.py runserver", &c));
        assert!(!repeats_row("notes.md - NVIM", "", "nvim notes.md", &c));
    }

    #[test]
    fn a_prompt_of_this_host_is_where_the_host_name_ends() {
        // host_short is "box"
        let c = cfg();
        let r = |d: &str, raw: &str| repeats_row(d, "", raw, &c);
        // this host: bash skel, Fedora/oh-my-zsh, a domain, mc's [user@host]
        assert!(r("u@box: ~/x", "ssh web1"));
        assert!(r("u@box:~/x", "ssh web1"));
        assert!(r("u@box.example.com:~", "ssh web1"));
        assert!(r("mc [u@box]:/work", "screen"));
        assert!(r("u@box", "ssh web1"));
        // another host whose name starts with this one's
        assert!(!r("root@box-7d4b9c: /app", "kubectl"));
        assert!(!r("u@box2:~", "ssh box2"));
        assert!(!r("u@boxer_1:~", "docker"));
        // ...unless this host's prompt is in there as well, after it
        assert!(r("root@box-2: /x - \"u@box:/tmp\"", "tmux"));
        // fish over ssh heads prompts and command lines with [host], cut to 10
        assert!(r("[box] ~/x", "ssh web1"));
        assert!(r("[box] ssh web1 ~/x", "ssh web1"));
        assert!(!r("[web1] ~/x", "ssh web1"));
        assert!(!r("[boxer] ~/x", "ssh boxer"));
        let mut long = cfg();
        long.host_short = "krootabulon".into();
        assert!(repeats_row("[krootabulo] ssh me@remote ~", "", "ssh me@remote", &long));
        assert!(!repeats_row("[krootabulon] ~", "", "ssh me@remote", &long));
        // no host name known: nothing is this host's
        let mut none = cfg();
        none.host_short.clear();
        assert!(!repeats_row("u@:~", "", "ssh web1", &none));
        assert!(!repeats_row("[] ~", "", "ssh web1", &none));
    }

    #[test]
    fn a_command_line_is_recognised_when_its_prefix_is_argv0() {
        let c = cfg();
        // the row is sudo itself: its preexec line starts with it
        assert!(repeats_row("sudo docker run --rm -it ubuntu bash", "", "sudo docker run --rm -it ubuntu bash", &c));
        assert!(repeats_row("time make -j8", "", "/usr/bin/time make -j8", &c));
        // a prefix that is not argv0 is still skipped
        assert!(repeats_row("sudo docker run -v /a:/b img@sha256:ab bash", "", "docker run", &c));
        assert!(!repeats_row("sudo root@3f2a: /", "", "docker exec -it 3f2a bash", &c));
    }

    #[test]
    fn title_max_is_read_as_bash_reads_it() {
        // decimal, whatever the leading zeros (bash arithmetic would read octal)
        assert_eq!(title_max("040"), 40);
        assert_eq!(title_max("09"), 9);
        assert_eq!(title_max("0040"), 40);
        assert_eq!(title_max("000000000000000000000050"), 50);
        // clamped, and a number too long to parse is over the top
        assert_eq!(title_max("000"), 8);
        assert_eq!(title_max("7"), 8);
        assert_eq!(title_max("201"), 200);
        assert_eq!(title_max("99999999999999999999999"), 200);
        // anything else is the default
        assert_eq!(title_max(""), 40);
        assert_eq!(title_max("4O"), 40);
        assert_eq!(title_max("+40"), 40);
    }

    #[test]
    fn the_cap_counts_characters() {
        assert_eq!(cap("abcdefghij".into(), 8), "abcdefg…");
        assert_eq!(cap("abcdefgh".into(), 8), "abcdefgh");
    }
}
