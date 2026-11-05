//! Agents: what an AI coding agent's pane tells tmux, shown in the command
//! field -- `claude working 2m Project review and suggestions`.
//!
//! A port of bash `agent_of` and `cmd_field` (see the
//! "Agents" section of scripts/interdimux.sh for the why of every rule).  The
//! Claude registry is read by bash, once per list, and arrives here as the
//! fifth input section; this module only merges it into the row.

use std::collections::HashMap;
use std::sync::OnceLock;

use crate::format::format_command;
use crate::palette::{Palette, RST};
use crate::proc::is_idle_shell;
use crate::text::age_of;
use crate::titles;

/// Recognised by argv0's basename (bash AGENT_KNOWN).
const KNOWN: &[&str] = &[
    "claude",
    "codex",
    "gemini",
    "qwen",
    "opencode",
    "amp",
    "goose",
    "crush",
    "kiro-cli",
    "kiro-cli-chat",
    "aider",
    "copilot",
    "cursor-agent",
];
/// Installed as a script an interpreter runs (bash AGENT_SCRIPTS).
const SCRIPTS: &[&str] = &["codex", "gemini", "qwen", "copilot", "crush", "aider"];

#[derive(PartialEq, Eq, Clone, Copy)]
pub enum ShowTitle {
    /// titles a rule knows (an agent's too: see DEFAULT_TITLE_RULES)
    Known,
    All,
    Off,
}

pub struct Config {
    /// Native config distinguishes explicit user suppression from generic
    /// built-in fallbacks; gather3 keeps its supplied rules authoritative.
    pub native_user_rule_count: Option<usize>,
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
    /// what sets the parts of an agent row apart (bash already normalised
    /// @interdimux-agent-separator); None is `off`, a blank alone
    pub separator: Option<String>,
}

/// One registry record: the pane shell's pid (empty: unchecked), the state
/// word, and since when (epoch seconds).
pub struct Record {
    pub sid: String,
    pub word: String,
    pub since: i64,
}
pub type Registry = HashMap<String, Record>;

/// Rule text with each line that is not UTF-8 left out whole: what bash
/// title_ruleset hands over already, and never a lossy U+FFFD, which would
/// make the line another rule.  One Latin-1 byte in the user's file used to
/// empty the whole variable here, the built-in rules with it (review R02).
fn utf8_lines(b: &[u8]) -> String {
    b.split(|&c| c == b'\n')
        .filter_map(|l| std::str::from_utf8(l).ok())
        .collect::<Vec<_>>()
        .join("\n")
}
fn env_lines(k: &str) -> String {
    use std::os::unix::ffi::OsStrExt;
    utf8_lines(std::env::var_os(k).unwrap_or_default().as_bytes())
}

impl Config {
    /// From the environment bash hands over; every value is already
    /// normalised there, and these defaults are bash's.
    pub fn from_env(host: &str, host_short: &str) -> Self {
        let var = crate::env_text;
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
                if w.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
                {
                    known.push(w.to_string());
                    scripts.push(w.to_string());
                }
            }
        }
        Config {
            native_user_rule_count: None,
            show_title,
            title_max,
            known,
            scripts,
            keep_args: var("INTERDIMUX_AGENT_ARGS") == "on",
            state: var("INTERDIMUX_AGENT_STATE") != "off",
            host: host.to_string(),
            host_short: host_short.to_string(),
            rules: titles::parse(&env_lines("INTERDIMUX_TITLE_RULESET")),
            state_opts: var("INTERDIMUX_STATE_OPTS")
                .split([' ', '\t', '\n'])
                .filter(|w| !w.is_empty())
                .map(str::to_string)
                .collect(),
            separator: match var("INTERDIMUX_AGENT_SEPARATOR").as_str() {
                "off" => None,
                "" => Some("∣".to_string()),
                v => Some(v.to_string()),
            },
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
    // a package's own file, run by path (`node …/codex/bin/codex.js`)
    let wb = [".js", ".mjs", ".cjs"]
        .iter()
        .find_map(|e| wb.strip_suffix(e))
        .unwrap_or(wb);
    if cfg.scripts.iter().any(|k| k == wb) {
        return Some((wb.to_string(), &r1[w1.len()..]));
    }
    if wb == "npx" || wb == "npx-cli" {
        return npx_agent(&r1[w1.len()..], cfg);
    }
    None
}

/// Packages npx runs an agent from (bash NPX_AGENTS).
const NPX_AGENTS: &[(&str, &str)] = &[
    ("@google/gemini-cli", "gemini"),
    ("@openai/codex", "codex"),
    ("@anthropic-ai/claude-code", "claude"),
    ("@qwen-code/qwen-code", "qwen"),
    ("@github/copilot", "copilot"),
];

/// `npx [options] <package>[@version] [args]`: npm runs the package's bin as
/// a grandchild, so the row is npx's argv and the package names the agent
/// (bash npx_agent).
fn npx_agent<'a>(rest: &'a str, cfg: &Config) -> Option<(String, &'a str)> {
    let mut pos = 0;
    let mut pkg: Option<&str> = None;
    let mut skip = false;
    let w = loop {
        let r = &rest[pos..];
        let t = r.trim_start_matches(' ');
        if t.is_empty() {
            return None;
        }
        let w = t.split(' ').next().unwrap_or("");
        pos += r.len() - t.len() + w.len();
        if skip {
            pkg = Some(w);
            skip = false;
            continue;
        }
        match w {
            "-p" | "--package" => {
                skip = true;
                continue;
            }
            "-c" | "--call" => return None,
            _ => {}
        }
        if let Some(p) = w.strip_prefix("--package=") {
            pkg = Some(p);
            continue;
        }
        if w.starts_with('-') {
            continue;
        }
        break w;
    };
    let spec = pkg.unwrap_or(w);
    // `pkg@version`: from the last '@' that is not the scope's leading one
    let name = match spec.get(1..).and_then(|s| s.rfind('@')) {
        Some(i) => &spec[..i + 1],
        None => spec,
    };
    if let Some((_, a)) = NPX_AGENTS.iter().find(|(p, _)| *p == name) {
        return Some((a.to_string(), &rest[pos..]));
    }
    if pkg.is_some() && cfg.known.iter().any(|k| k == w) {
        return Some((w.to_string(), &rest[pos..]));
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
    desc == tag
        || desc
            .strip_prefix(tag.as_str())
            .is_some_and(|r| r.starts_with(' '))
}

/// The command a title's word would name: its basename -- or nothing, for a
/// word with a ':' before its last '/', which is a prompt
/// (`deploy@web1:/etc/ssh`, `host:~/ssh`) and no command path, whatever its
/// last directory is called (bash cmd_field's `*:*/*`).
fn cmd_base(w: &str) -> &str {
    match (w.find(':'), w.rfind('/')) {
        (Some(c), Some(s)) if c < s => "",
        _ => basename(w),
    }
}

/// A description that only repeats the row: the app's own name, tmux's
/// default title (the host name), a prompt of this host, or -- from a preexec
/// hook -- the command line itself.
fn repeats_row(desc: &str, name: &str, raw: &str, cfg: &Config) -> bool {
    if desc == name
        || desc == cfg.host
        || desc == cfg.host_short
        || this_host_prompt(desc, &cfg.host_short)
    {
        return true;
    }
    let a0 = raw.split(' ').next().unwrap_or("");
    let b = basename(a0);
    let b = b.strip_prefix('-').unwrap_or(b);
    let mut w = "";
    for x in desc.split(' ').filter(|x| !x.is_empty()) {
        w = x;
        // a prefix that is itself argv0: `sudo docker run ...` on a sudo row
        if !cmd_base(x).is_empty() && cmd_base(x) == b {
            break;
        }
        if x.contains('=')
            || matches!(
                x,
                "sudo"
                    | "env"
                    | "nohup"
                    | "exec"
                    | "time"
                    | "command"
                    | "builtin"
                    | "noglob"
                    | "nice"
            )
        {
            continue;
        }
        break;
    }
    let after = &raw[a0.len()..];
    // unstripped, as bash's `case "$b"` sees it: `-node` is no interpreter
    let r = if crate::format::is_interpreter(basename(a0)) {
        after
            .strip_prefix(' ')
            .unwrap_or(after)
            .split(' ')
            .next()
            .unwrap_or("")
    } else {
        ""
    };
    let cw = cmd_base(w);
    !cw.is_empty() && (cw == b || (!r.is_empty() && cw == basename(r)))
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

/// The command field of a window or pane row (bash cmd_field), and the state
/// word it shows (empty when none) -- which the agents view marks the row by
/// (bash agent_mark_r).
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
) -> (String, String) {
    command_field_inner(
        raw,
        pid,
        pane,
        title,
        opts,
        cfg,
        reg,
        p,
        now,
        NativeTitle::default(),
    )
}

#[derive(Clone, Copy, Default)]
pub struct NativeTitle<'a> {
    /// A verified foreground-owned conversation/task title.
    pub current: bool,
    /// An explicit foreground program report; messages stay secondary.
    pub reported: bool,
    /// A second verified explicit title if the primary OSC text is generic.
    pub alternate: Option<&'a str>,
}

/// Native callers may promote an agent's current conversation title to the
/// primary label. The caller must first verify the title belongs to the
/// foreground process; a terminal can retain a previous program's OSC title.
/// An alternate must likewise be a verified explicit title, not a status message.
/// The legacy formatter never takes this path.
#[allow(clippy::too_many_arguments)]
pub fn native_command_field(
    raw: &str,
    pid: u32,
    pane: &str,
    title: &str,
    opts: &str,
    cfg: &Config,
    reg: &Registry,
    p: &Palette,
    now: i64,
    native: NativeTitle<'_>,
) -> (String, String) {
    command_field_inner(raw, pid, pane, title, opts, cfg, reg, p, now, native)
}

// The Claude/Codex rules used by the Bash frontend, with meaningful bare
// owner-verified titles accepted too. An explicit caller rule always wins,
// including one that deliberately suppresses a title.
fn native_title_rules() -> &'static [titles::Rule] {
    static RULES: OnceLock<Vec<titles::Rule>> = OnceLock::new();
    RULES.get_or_init(|| {
        titles::parse(
            "claude - - ✳ Claude Code\n\
         claude - - Claude Code\n\
         claude working $1 ◐ *\n\
         claude working $1 ◑ *\n\
         claude working $1 %spin *\n\
         claude - $1 ✳ *\n\
         codex approve $1 [ ! ] Action Required | * | *\n\
         codex approve $1 [ . ] Action Required | * | *\n\
         codex approve - [ ! ] Action Required*\n\
         codex approve - [ . ] Action Required*\n\
         codex approve $1 ● [ ! ] Action Required | * | *\n\
         codex approve $1 ● [ . ] Action Required | * | *\n\
         codex approve - ● [ ! ] Action Required*\n\
         codex approve - ● [ . ] Action Required*\n\
         codex working $1 %spin * | *\n\
         codex working $1 %spin *\n\
         codex - $1 * | *",
        )
    })
}

fn native_title_text(value: &str) -> String {
    let text = titles::text(titles::head(value));
    text.chars()
        .map(|c| match c {
            '\u{061c}' | '\u{2028}' | '\u{2029}' => ' ',
            _ => c,
        })
        .collect::<String>()
        .trim()
        .to_owned()
}

fn generic_native_title(desc: &str, name: &str, raw: &str, cfg: &Config) -> bool {
    if desc.is_empty()
        || desc.eq_ignore_ascii_case(name)
        || ["Claude Code", "Codex", "Codex CLI", "OpenAI Codex"]
            .iter()
            .any(|generic| desc.eq_ignore_ascii_case(generic))
        || repeats_row(desc, name, raw, cfg)
    {
        return true;
    }
    // Rex may not supply the host's textual name. Still reject a conventional
    // shell prompt such as user@host:~/project or host: /project.
    let mut words = desc.split_whitespace();
    let first = words.next().unwrap_or("");
    if let Some((host, path)) = first.rsplit_once(':') {
        let path = if path.is_empty() {
            words.next().unwrap_or("")
        } else {
            path
        };
        if !host.is_empty()
            && !host.contains('/')
            && (path.starts_with('/') || path.starts_with('~'))
        {
            return true;
        }
    }
    false
}

fn native_title_candidate(title: &str, name: &str, raw: &str, cfg: &Config) -> (titles::Hit, bool) {
    let text = native_title_text(title);
    if text.is_empty() {
        return (
            titles::Hit {
                state: String::new(),
                desc: text,
            },
            false,
        );
    }
    let user_count = cfg
        .native_user_rule_count
        .unwrap_or(cfg.rules.len())
        .min(cfg.rules.len());
    let custom = titles::apply(&cfg.rules[..user_count], name, &text);
    let suppressed = custom.as_ref().is_some_and(|hit| hit.desc.is_empty());
    let mut hit = custom
        .or_else(|| {
            titles::apply(&cfg.rules[user_count..], name, &text)
                // Codex's legacy catch-all rejects unrecognised, potentially
                // stale titles. Rex proves ownership, so bare task titles are
                // useful here. Other apps' explicit generic-title rules stay.
                .filter(|hit| name != "codex" || !hit.desc.is_empty() || !hit.state.is_empty())
        })
        .or_else(|| titles::apply(native_title_rules(), name, &text))
        .unwrap_or(titles::Hit {
            state: String::new(),
            desc: text,
        });
    hit.desc = native_title_text(&titles::glyph(&hit.desc));
    if generic_native_title(&hit.desc, name, raw, cfg) {
        hit.desc.clear();
    }
    (hit, suppressed)
}

fn native_title_choice(
    title: &str,
    alternate_title: Option<&str>,
    name: &str,
    raw: &str,
    cfg: &Config,
) -> titles::Hit {
    let (mut primary, suppressed) = native_title_candidate(title, name, raw, cfg);
    if primary.desc.is_empty() && !suppressed {
        if let Some(alternate) = alternate_title {
            let (fallback, _) = native_title_candidate(alternate, name, raw, cfg);
            primary.desc = fallback.desc;
            if primary.state.is_empty() {
                primary.state = fallback.state;
            }
        }
    }
    primary
}

#[allow(clippy::too_many_arguments)]
fn command_field_inner(
    raw: &str,
    pid: u32,
    pane: &str,
    title: &str,
    opts: &str,
    cfg: &Config,
    reg: &Registry,
    p: &Palette,
    now: i64,
    native: NativeTitle<'_>,
) -> (String, String) {
    let fc = format_command(raw, p).0;
    if !cfg.on() || fc.is_empty() || is_idle_shell(raw) {
        return (fc, String::new());
    }
    let agent = agent_of(raw, cfg);
    let native_title = native.current && agent.is_some() && cfg.show_title != ShowTitle::Off;
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
    // published (an option), not a title: bash AS_PUBD
    let mut pubd = false;
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
        pubd = true;
    } else if native.reported && !native.current && !title.is_empty() {
        // A validated program message is published text, like @agent_desc,
        // rather than an ordinary OSC title for heuristic rules to interpret.
        desc = native_title_text(title);
        known = true;
        pubd = true;
    } else if native_title {
        let hit = native_title_choice(title, native.alternate, name, raw, cfg);
        known = true;
        desc = hit.desc;
        if cfg.state && state.is_empty() && !hit.state.is_empty() {
            state = hit.state;
            agent_row = true;
        }
    } else if !title.is_empty() {
        let t = titles::text(titles::head(title));
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
        ShowTitle::Known if !known => desc.clear(),
        _ => {}
    }
    if !desc.is_empty() {
        // published text is shown as published: only a bare repeat of the
        // name goes (a title can be stale, or a copy of the command line)
        let repeat = if pubd {
            desc == name
        } else if native_title {
            desc = native_title_text(&desc);
            generic_native_title(&desc, name, raw, cfg)
        } else {
            repeats_row(&desc, name, raw, cfg)
        };
        if repeat {
            desc.clear();
        }
        desc = cap(
            desc,
            if native_title && !pubd {
                titles::CAP
            } else {
                cfg.title_max
            },
        );
    }
    if !agent_row && desc.is_empty() {
        // agent_row is set wherever a state is, so there is none here
        return (fc, String::new());
    }
    // The parts -- the command, the state with its age, the description --
    // each set off by the separator (bash cmd_field): `claude ∣ working 2m ∣
    // Project review`.  An agent's kept arguments stay with its name.
    let mut st = String::new();
    if !state.is_empty() {
        let col = match state.as_str() {
            "approve" | "error" => &p.bold_red,
            "input" => &p.bold_amber,
            _ => &p.dim_tree,
        };
        st = format!("{}{}{}", col, &state, RST);
        // no age under a minute: `approve now Fix the parser` read as an order
        let age = age_of(since, now);
        if !age.is_empty() && age != "now" {
            st.push_str(&format!(" {}{}{}", p.dim_tree, age, RST));
        }
    }
    let title_primary = native_title && !pubd && !desc.is_empty();
    let dsc = if title_primary || desc.is_empty() {
        String::new()
    } else {
        format!("{}{}{}", p.dim_edit, desc, RST)
    };
    let mut field = if title_primary {
        format!("{}{}{}", p.dim_edit, desc, RST)
    } else {
        match &agent {
            None => fc,
            Some((n, r)) => {
                let rest = if (!st.is_empty() || !dsc.is_empty()) && !cfg.keep_args {
                    ""
                } else {
                    *r
                };
                format!("{}{}{}{}", p.dim_cmd, n, rest, RST)
            }
        }
    };
    let bar = match &cfg.separator {
        Some(g) => format!(" {}{}{} ", p.sep_col, g, RST),
        None => " ".to_string(),
    };
    for part in [&st, &dsc] {
        if !part.is_empty() {
            field.push_str(&bar);
            field.push_str(part);
        }
    }
    (field, state)
}

/// The agents view's gutter mark for a row whose pane (`pane`, empty when
/// unknown) is in `state` (bash agent_mark_r): `!` for approve, `?` for input,
/// None for anything else -- or for a pane `marked` already holds, which an
/// earlier row of a session group or a linked window carried.
pub fn view_mark(
    state: &str,
    pane: &str,
    marked: &mut std::collections::HashSet<String>,
    p: &Palette,
) -> Option<String> {
    let m = match state {
        "approve" => format!("{}!{}", p.bold_red, RST),
        "input" => format!("{}?{}", p.bold_amber, RST),
        _ => return None,
    };
    if !pane.is_empty() && !marked.insert(pane.to_string()) {
        return None;
    }
    Some(m)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> Config {
        Config {
            native_user_rule_count: None,
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
            separator: Some("∣".to_string()),
        }
    }

    #[test]
    fn agents_are_named_by_what_they_are() {
        let c = cfg();
        let n = |s: &str| agent_of(s, &c).map(|a| (a.0, a.1.to_string()));
        assert_eq!(
            n("claude --resume x"),
            Some(("claude".into(), " --resume x".into()))
        );
        assert_eq!(
            n("/home/u/.local/share/claude/versions/2.1.281 -c"),
            Some(("claude".into(), " -c".into()))
        );
        assert_eq!(
            n("node /home/u/.nvm/v/bin/codex resume"),
            Some(("codex".into(), " resume".into()))
        );
        assert_eq!(
            n("python3.12 /home/u/.local/bin/aider --model x"),
            Some(("aider".into(), " --model x".into()))
        );
        // not the script word, or not an agent script
        assert_eq!(n("node --inspect /x/codex"), None);
        assert_eq!(n("node /x/server.js"), None);
        assert_eq!(n("pythonw /x/aider"), None);
        // a package's file run by path; npx and the package it runs
        assert_eq!(
            n("node /p/node_modules/@openai/codex/bin/codex.js resume"),
            Some(("codex".into(), " resume".into()))
        );
        assert_eq!(
            n("node /u/bin/npx @google/gemini-cli --yolo"),
            Some(("gemini".into(), " --yolo".into()))
        );
        assert_eq!(
            n("node /u/bin/npx -y @google/gemini-cli@latest"),
            Some(("gemini".into(), "".into()))
        );
        assert_eq!(
            n("node /u/bin/npx --package=@openai/codex codex exec x"),
            Some(("codex".into(), " exec x".into()))
        );
        assert_eq!(
            n("node /u/bin/npx -p @qwen-code/qwen-code qwen"),
            Some(("qwen".into(), "".into()))
        );
        assert_eq!(
            n("node /u/bin/npx -p something claude"),
            Some(("claude".into(), "".into()))
        );
        assert_eq!(n("node /u/bin/npx cowsay hi"), None);
        assert_eq!(n("node /u/bin/npx -c 'gemini'"), None);
        assert_eq!(n("node /u/bin/npx"), None);
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
        assert!(repeats_row(
            "python3 ./manage.py runserver",
            "",
            "/usr/bin/python3 /h/manage.py runserver",
            &c
        ));
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
        assert!(repeats_row(
            "[krootabulo] ssh me@remote ~",
            "",
            "ssh me@remote",
            &long
        ));
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
        assert!(repeats_row(
            "sudo docker run --rm -it ubuntu bash",
            "",
            "sudo docker run --rm -it ubuntu bash",
            &c
        ));
        assert!(repeats_row(
            "time make -j8",
            "",
            "/usr/bin/time make -j8",
            &c
        ));
        // a prefix that is not argv0 is still skipped
        assert!(repeats_row(
            "sudo docker run -v /a:/b img@sha256:ab bash",
            "",
            "docker run",
            &c
        ));
        assert!(!repeats_row(
            "sudo root@3f2a: /",
            "",
            "docker exec -it 3f2a bash",
            &c
        ));
    }

    #[test]
    fn a_rule_line_that_is_not_utf8_is_the_only_one_dropped() {
        let text = utf8_lines(b"# caf\xe9 rules\nfoo - = *\nbar - caf\xe9:$1 x*\n\ncodex - - *");
        assert_eq!(text, "foo - = *\n\ncodex - - *");
        let rules = titles::parse(&text);
        assert!(titles::apply(&rules, "foo", "x").is_some());
        assert!(titles::apply(&rules, "codex", "x").is_some());
        assert!(titles::apply(&rules, "bar", "xy").is_none());
        assert_eq!(utf8_lines(b"caf\xc3\xa9"), "caf\u{e9}");
    }

    #[test]
    fn a_prompt_whose_directory_is_named_like_the_app_is_no_command_line() {
        let c = cfg();
        // Fedora, Arch and oh-my-zsh put no blank after the colon
        assert!(!repeats_row("deploy@web1:/etc/ssh", "ssh", "ssh web1", &c));
        assert!(!repeats_row("deploy@web1:~/ssh", "ssh", "ssh web1", &c));
        assert!(!repeats_row("web1:/srv/ssh", "ssh", "ssh web1", &c));
        assert!(!repeats_row(
            "root@3f2a9c1b:/var/lib/docker",
            "docker",
            "docker exec -it 3f2a bash",
            &c
        ));
        // a command path is still one, and so is a colon after its last '/'
        assert!(repeats_row("/usr/bin/ssh web1", "ssh", "ssh web1", &c));
        assert!(repeats_row("ssh web1:/etc", "ssh", "ssh web1", &c));
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

    fn native_render(raw: &str, title: &str, cfg: &Config, prefer_title: bool) -> (String, String) {
        native_render_alternate(raw, title, cfg, prefer_title, None)
    }

    fn native_render_alternate(
        raw: &str,
        title: &str,
        cfg: &Config,
        prefer_title: bool,
        alternate: Option<&str>,
    ) -> (String, String) {
        let palette = Palette {
            dim_cmd: String::new(),
            bold_amber: String::new(),
            marker: String::new(),
            dim_path: String::new(),
            dim_ssh: String::new(),
            dim_edit: String::new(),
            dim_git: String::new(),
            dim_tree: String::new(),
            bold_red: String::new(),
            sep: String::new(),
            sep_col: String::new(),
        };
        let (field, state) = native_command_field(
            raw,
            123,
            "pane",
            title,
            "",
            cfg,
            &Registry::new(),
            &palette,
            1000,
            NativeTitle {
                current: prefer_title,
                alternate,
                ..NativeTitle::default()
            },
        );
        (field.replace(RST, ""), state)
    }

    #[test]
    fn native_codex_conversations_replace_executables_and_keep_state() {
        let c = cfg();
        for (title, name, state) in [
            (
                "⠸ Add Rex tmux keybindings | dotfiles",
                "Add Rex tmux keybindings",
                "working",
            ),
            (
                "⠏ Port tmux keybindings to rex | dotfiles",
                "Port tmux keybindings to rex",
                "working",
            ),
            ("A conversation name | dotfiles", "A conversation name", ""),
            ("Review requested changes", "Review requested changes", ""),
            (
                "⠴ Working without a project suffix",
                "Working without a project suffix",
                "working",
            ),
            (
                "[ ! ] Action Required | Review changes | dotfiles",
                "Review changes",
                "approve",
            ),
            (
                "● [ . ] Action Required | Review changes | dotfiles",
                "Review changes",
                "approve",
            ),
        ] {
            let expected = if state.is_empty() {
                name.into()
            } else {
                format!("{name} ∣ {state}")
            };
            assert_eq!(
                native_render("codex", title, &c, true),
                (expected, state.into()),
                "{title}"
            );
        }
    }

    #[test]
    fn native_claude_titles_and_interpreter_installs_use_the_conversation() {
        let c = cfg();
        for (raw, title, expected) in [
            ("claude", "✳ Fix floating picker", "Fix floating picker"),
            (
                "/home/u/.local/share/claude/versions/2.1.281 -c",
                "◐ Fix floating picker",
                "Fix floating picker ∣ working",
            ),
            (
                "node /p/node_modules/@openai/codex/bin/codex.js resume",
                "⠋ Fix floating picker | project",
                "Fix floating picker ∣ working",
            ),
            (
                "node /u/bin/npx @anthropic-ai/claude-code",
                "✳ Fix floating picker",
                "Fix floating picker",
            ),
            (
                "python3 /home/u/.local/bin/aider",
                "A useful agent conversation",
                "A useful agent conversation",
            ),
        ] {
            assert_eq!(native_render(raw, title, &c, true).0, expected, "{raw}");
        }
    }

    #[test]
    fn native_primary_titles_keep_long_searchable_text() {
        let mut c = cfg();
        c.title_max = 8;
        let title =
            "A conversation with a long distinctive label and a deeply searchable ending sentinel";
        assert_eq!(native_render("codex", title, &c, true).0, title);
        let capped = native_render("codex", &"界".repeat(300), &c, true).0;
        assert_eq!(capped.chars().count(), titles::CAP);
        assert!(
            !capped.contains('…'),
            "the safety input cap is not a display-width truncation"
        );
    }

    #[test]
    fn native_custom_rules_override_defaults_and_can_suppress_titles() {
        let mut c = cfg();
        c.rules = titles::parse("codex input Custom:$1 ⠸ * | *\nclaude - - ✳ *");
        assert_eq!(
            native_render("codex", "⠸ Repair picker | project", &c, true),
            ("Custom:Repair picker ∣ input".into(), "input".into()),
        );
        assert_eq!(
            native_render("claude", "✳ Repair picker", &c, true).0,
            "claude"
        );
    }

    #[test]
    fn native_generic_titles_and_shell_prompts_fall_back_to_the_command() {
        let mut c = cfg();
        // Prompt filtering also works when Rex knows a host ID but no name.
        c.host.clear();
        c.host_short.clear();
        for title in [
            "",
            "Codex",
            "Codex CLI",
            "OpenAI Codex",
            "codex --resume",
            "user@unknown:~/project",
            "unknown: /project",
            "[ ! ] Action Required",
        ] {
            let (field, _) = native_render("codex", title, &c, true);
            assert!(
                field == "codex" || field == "codex ∣ approve",
                "{title:?}: {field:?}"
            );
        }
        for title in ["Claude Code", "✳ Claude Code", "claude"] {
            assert_eq!(native_render("claude", title, &c, true).0, "claude");
        }
    }

    #[test]
    fn native_title_promotion_requires_current_ownership_and_honors_off() {
        let mut c = cfg();
        let title = "⠸ A stale conversation | project";
        assert_eq!(native_render("codex", title, &c, false).0, "codex");
        c.show_title = ShowTitle::Off;
        assert_eq!(native_render("codex", title, &c, true).0, "codex");
        // ShowTitle::Off means no native title parsing either; no synthetic
        // title-derived state should appear when the title is explicitly off.
        assert_eq!(
            native_render("codex", title, &c, true),
            native_render("codex", title, &c, false)
        );
    }

    #[test]
    fn native_nonagents_and_unverified_titles_preserve_legacy_formatting() {
        let mut c = cfg();
        c.show_title = ShowTitle::All;
        let p = Palette::from_env();
        let reg = Registry::new();
        for (raw, title) in [
            ("nvim README.md", "README.md - NVIM"),
            ("cargo test", "Running tests"),
            ("zsh", "user@box:~/project"),
            ("codex", "⠸ A stale conversation | project"),
        ] {
            let legacy = command_field(raw, 123, "pane", title, "", &c, &reg, &p, 1000);
            assert_eq!(
                native_command_field(
                    raw,
                    123,
                    "pane",
                    title,
                    "",
                    &c,
                    &reg,
                    &p,
                    1000,
                    NativeTitle::default()
                ),
                legacy,
            );
            if !raw.starts_with("codex") {
                assert_eq!(
                    native_command_field(
                        raw,
                        123,
                        "pane",
                        title,
                        "",
                        &c,
                        &reg,
                        &p,
                        1000,
                        NativeTitle {
                            current: true,
                            ..NativeTitle::default()
                        }
                    ),
                    legacy,
                );
            }
        }
    }

    #[test]
    fn native_primary_titles_cannot_inject_terminal_or_tsv_controls() {
        let c = cfg();
        let title = "Review\t日本語\n\u{1b}]52;c;unsafe\u{7}\u{202e}\u{061c}\u{2028}\u{2029}done";
        let (field, _) = native_render("codex", title, &c, true);
        assert!(field.contains("Review") && field.contains("日本語") && field.contains("done"));
        assert!(!field
            .chars()
            .any(|c| c.is_control()
                || matches!(c, '\u{202e}' | '\u{061c}' | '\u{2028}' | '\u{2029}')));
    }

    #[test]
    fn native_primary_titles_preserve_registry_state_and_age() {
        let c = cfg();
        let mut registry = Registry::new();
        registry.insert(
            "pane".into(),
            Record {
                sid: "123".into(),
                word: "approve".into(),
                since: 880,
            },
        );
        let p = Palette::from_env();
        for (raw, title) in [
            ("codex", "⠸ Repair picker | project"),
            ("claude", "✳ Repair picker"),
        ] {
            let (field, state) = native_command_field(
                raw,
                123,
                "pane",
                title,
                "",
                &c,
                &registry,
                &p,
                1000,
                NativeTitle {
                    current: true,
                    ..NativeTitle::default()
                },
            );
            assert_eq!(state, "approve");
            assert!(field.contains("Repair picker"));
            assert!(field.contains("approve") && field.contains("2m"));
            assert!(!field.contains(raw) && !field.contains("working"));
        }
    }

    #[test]
    fn native_generic_osc_titles_allow_a_verified_explicit_title_fallback() {
        let mut c = cfg();
        for (raw, primary, state) in [
            ("codex", "Codex", ""),
            ("claude", "✳ Claude Code", ""),
            ("codex", "user@unknown:~/project", ""),
            ("codex", "[ ! ] Action Required", "approve"),
        ] {
            let expected = if state.is_empty() {
                "Repair startup race".into()
            } else {
                format!("Repair startup race ∣ {state}")
            };
            assert_eq!(
                native_render_alternate(raw, primary, &c, true, Some("Repair startup race")),
                (expected, state.into()),
            );
        }
        assert_eq!(
            native_render_alternate(
                "codex",
                "⠸ Original conversation | project",
                &c,
                true,
                Some("Other task")
            )
            .0,
            "Original conversation ∣ working",
        );
        c.state = false;
        assert_eq!(
            native_render_alternate(
                "codex",
                "[ ! ] Action Required",
                &c,
                true,
                Some("Repair startup race")
            ),
            ("Repair startup race".into(), String::new()),
        );
    }

    #[test]
    fn native_fallback_titles_obey_custom_rule_suppression_and_rewriting() {
        let mut c = cfg();
        c.rules = titles::parse("codex - - Codex");
        assert_eq!(
            native_render_alternate("codex", "Codex", &c, true, Some("Repair startup race")).0,
            "codex",
            "an explicit suppression must not be bypassed by another source",
        );
        c.rules = titles::parse("codex input $1 task:*");
        assert_eq!(
            native_render_alternate("codex", "Codex", &c, true, Some("task:Repair startup race")),
            ("Repair startup race ∣ input".into(), "input".into()),
        );
        c.rules = titles::parse("codex - - task:*");
        assert_eq!(
            native_render_alternate("codex", "Codex", &c, true, Some("task:Repair startup race")).0,
            "codex",
        );
    }

    #[test]
    fn native_fallback_titles_receive_the_same_sanitization_and_visibility_rules() {
        let mut c = cfg();
        let fallback = "Repair\t日本語\u{1b}]52;c;unsafe\u{7}\u{202e}\u{061c}\u{2028}done";
        let (field, _) = native_render_alternate("codex", "Codex", &c, true, Some(fallback));
        assert!(field.contains("日本語") && field.contains("done"));
        assert!(!field
            .chars()
            .any(|c| c.is_control() || matches!(c, '\u{202e}' | '\u{061c}' | '\u{2028}')));
        c.show_title = ShowTitle::Off;
        assert_eq!(
            native_render_alternate("codex", "Codex", &c, true, Some(fallback)).0,
            "codex"
        );
        c.show_title = ShowTitle::Known;
        assert_eq!(
            native_render_alternate("codex", "Codex", &c, false, Some(fallback)).0,
            "codex"
        );
    }
    #[test]
    fn native_published_messages_are_secondary_without_relaxing_ordinary_osc_rules() {
        let mut c = cfg();
        c.rules = titles::parse("codex - - *\ncargo - - *");
        c.native_user_rule_count = Some(0);
        let p = Palette::from_env();
        let reg = Registry::new();
        for raw in ["codex", "cargo"] {
            let report = NativeTitle {
                reported: true,
                ..NativeTitle::default()
            };
            let (field, _) = native_command_field(
                raw,
                123,
                "pane",
                "Review requested changes",
                "",
                &c,
                &reg,
                &p,
                1000,
                report,
            );
            assert!(field.contains(raw) && field.contains("Review requested changes"));
            assert!(field.find(raw).unwrap() < field.find("Review requested changes").unwrap());
            assert!(!command_field(
                raw,
                123,
                "pane",
                "Review requested changes",
                "",
                &c,
                &reg,
                &p,
                1000
            )
            .0
            .contains("Review requested changes"));
            c.show_title = ShowTitle::Off;
            assert!(!native_command_field(
                raw,
                123,
                "pane",
                "Review requested changes",
                "",
                &c,
                &reg,
                &p,
                1000,
                report
            )
            .0
            .contains("Review requested changes"));
            c.show_title = ShowTitle::Known;
        }
        c.rules = titles::parse("codex - - *");
        c.native_user_rule_count = Some(1);
        assert!(!native_command_field(
            "codex",
            123,
            "pane",
            "Suppressed title",
            "",
            &c,
            &reg,
            &p,
            1000,
            NativeTitle {
                current: true,
                reported: true,
                alternate: None
            }
        )
        .0
        .contains("Suppressed title"));
    }
    #[test]
    fn native_published_secondary_messages_are_sanitized_and_description_capped() {
        let mut c = cfg();
        c.title_max = 16;
        let p = Palette::from_env();
        let text = "Review\t日本語\u{1b}]52;c;unsafe\u{7}\u{202e}\u{061c}done";
        let (field, _) = native_command_field(
            "codex",
            123,
            "pane",
            text,
            "",
            &c,
            &Registry::new(),
            &p,
            1000,
            NativeTitle {
                reported: true,
                ..NativeTitle::default()
            },
        );
        assert!(field.contains("Review") && field.contains('…'));
        assert!(
            !field.contains('\t')
                && !field.contains('\u{202e}')
                && !field.contains('\u{061c}')
                && !field.contains("\u{1b}]52")
        );
    }
}
