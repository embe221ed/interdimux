//! Golden-dump renderer tests.
//!
//! The binary reads the tmux dumps on stdin, so the entire layout surface can be
//! tested with no tmux server, no pty, and no timing — feed a recorded dump, diff
//! the rendered rows against a checked-in expectation.
//!
//! This exists because the shell suites cannot cover layout properly: they need a
//! live server, and this project's history includes two assertions that passed
//! *vacuously* against zero rows and a whole harness that was silently dead for
//! months. A byte-exact expectation cannot pass vacuously.
//!
//! To update expectations after an intentional rendering change:
//!
//!     IMUX_BLESS=1 cargo test --test golden
//!
//! then read the diff in `git diff` before committing it. Blessing without
//! reading the diff defeats the point of the test.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn corpus_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/corpus")
}

/// Render one dump under a fully pinned environment, so the only variable is the
/// renderer itself. Everything time-, host-, or config-dependent is fixed here.
fn render(dump: &str, extra: &[(&str, &str)]) -> String {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_imux"));
    cmd.arg("gather")
        .env_clear()
        .env("HOME", "/home/u")
        .env("PATH", "/usr/bin:/bin")
        // a fixed "now" so the age column ("3d", "2h") is deterministic
        .env("INTERDIMUX_NOW", "1700086400")
        .env("INTERDIMUX_COLS", "120")
        .env("INTERDIMUX_SHOW_PREVIEW", "off")
        // /proc resolution and git reads depend on the host, so pin them off:
        // this test is about layout, and proc.rs / git.rs have their own units.
        .env("INTERDIMUX_SHOW_FULL_COMMAND", "off")
        .env("INTERDIMUX_SHOW_GIT_BRANCH", "off")
        .env("INTERDIMUX_SHOW_DIRS", "off")
        .env("INTERDIMUX_ORDER", "mru")
        // pinned to the shipped default, so the goldens describe what users see
        .env("INTERDIMUX_SESSION_RULE", "on")
        .env("INTERDIMUX_COLOR_ACCENT", "173")
        .env("INTERDIMUX_COLOR_PATH", "180")
        .env("INTERDIMUX_COLOR_GIT", "140")
        .env("INTERDIMUX_COLOR_SSH", "109")
        .env("INTERDIMUX_COLOR_EDITOR", "150")
        .env("INTERDIMUX_COLOR_DANGER", "167")
        .env("INTERDIMUX_COLOR_TREE", "240")
        .env("INTERDIMUX_COLOR_SEPARATOR", "245");
    for (k, v) in extra {
        cmd.env(k, v);
    }
    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("spawn imux");
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(dump.as_bytes())
        .expect("write dump");
    let out = child.wait_with_output().expect("run imux");
    assert!(out.status.success(), "imux exited {:?}", out.status);
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// Like `render`, but tolerates a deliberate rejection: the binary exits 3 when
/// the input framing is not exactly four RS-separated sections, so that bash
/// falls back to its own renderer rather than showing a mis-framed list.
fn try_render(dump: &str) -> (Option<i32>, String) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_imux"))
        .arg("gather")
        .env_clear()
        .env("HOME", "/home/u")
        .env("PATH", "/usr/bin:/bin")
        .env("INTERDIMUX_NOW", "1700086400")
        .env("INTERDIMUX_COLS", "120")
        .env("INTERDIMUX_SHOW_FULL_COMMAND", "off")
        .env("INTERDIMUX_SHOW_GIT_BRANCH", "off")
        .env("INTERDIMUX_SHOW_DIRS", "off")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn imux");
    child.stdin.as_mut().unwrap().write_all(dump.as_bytes()).ok();
    let out = child.wait_with_output().expect("run imux");
    (out.status.code(), String::from_utf8_lossy(&out.stdout).into_owned())
}

fn check(case: &str, extra: &[(&str, &str)]) {
    let dir = corpus_dir();
    let dump = std::fs::read_to_string(dir.join(format!("{}.dump", case)))
        .unwrap_or_else(|e| panic!("read {}.dump: {}", case, e));
    let got = render(&dump, extra);
    let exp_path = dir.join(format!("{}.expected", case));

    if std::env::var("IMUX_BLESS").is_ok() {
        std::fs::write(&exp_path, &got).expect("bless");
        return;
    }
    let want = std::fs::read_to_string(&exp_path).unwrap_or_else(|_| {
        panic!(
            "missing {}.expected — run IMUX_BLESS=1 cargo test --test golden, then READ the diff",
            case
        )
    });
    if got != want {
        // Show the first differing line with escapes visible; a raw dump of ANSI
        // is unreadable in test output.
        let vis = |s: &str| s.replace('\x1b', "\\e").replace('\t', "\\t");
        let (g, w): (Vec<_>, Vec<_>) = (got.lines().collect(), want.lines().collect());
        for i in 0..g.len().max(w.len()) {
            let (a, b) = (g.get(i).copied().unwrap_or("<missing>"), w.get(i).copied().unwrap_or("<missing>"));
            if a != b {
                panic!(
                    "{}: row {} differs\n  want: {}\n  got : {}",
                    case, i + 1, vis(b), vis(a)
                );
            }
        }
        panic!("{}: output differs in length ({} vs {} rows)", case, g.len(), w.len());
    }
}

#[test]
fn basic_tree() {
    check("basic", &[]);
}

/// The case bash gets wrong: it pads by character count, so a two-cell glyph
/// shifts every column to its right. The expectation encodes correct behaviour.
#[test]
fn wide_characters() {
    check("cjk", &[]);
}

/// Zero and unparseable ages, names with spaces and quotes, an over-long name,
/// a deep path, and every window flag set at once.
#[test]
fn hostile_input() {
    check("hostile", &[]);
}

/// Emoji whose CLUSTER width is not the sum of its characters' widths: a VS16
/// presentation sequence (per-char 1, drawn 2), a ZWJ pair (per-char 4, drawn 2),
/// a four-person family (per-char 8, drawn 2) and a keycap.  The pre-existing
/// `cjk` fixture uses a rocket, which per-char measurement already gets right —
/// so nothing in the corpus exercised this until now.
#[test]
fn emoji_clusters() {
    check("emoji", &[]);
}

/// Indexes at tmux's own ceilings: window index near INT_MAX, pane index at the
/// pane-base-index limit of 65535.  Together they are wider than the identity
/// column's floor even after the session prefix has been dropped, so the pane
/// rows used to run past every other row — pad_to can only pad.
///
/// 52 columns specifically: measured, the identity column is 24 cells at >= 60
/// and everything fits, but 20 cells at <= 56, where `7 + "2147483000." + "65535"`
/// = 23 overflows.  Without the clamp this dump renders 20/20/20/23/23.
#[test]
fn indexes_at_tmux_ceilings() {
    check("bigindex", &[("INTERDIMUX_COLS", "52")]);
}

#[test]
fn empty_server_renders_nothing() {
    let out = render(&std::fs::read_to_string(corpus_dir().join("empty.dump")).unwrap(), &[]);
    assert!(out.is_empty(), "expected no rows, got {:?}", out);
}

#[test]
fn sessions_without_windows() {
    check("sessions-only", &[]);
}

/// Layout must hold at every width, not just the one the goldens pin.
#[test]
fn every_row_keeps_the_four_field_contract() {
    let dumps = ["basic", "cjk", "hostile", "emoji", "bigindex", "sessions-only"];
    for case in dumps {
        let dump = std::fs::read_to_string(corpus_dir().join(format!("{}.dump", case))).unwrap();
        for cols in [40, 60, 80, 100, 120, 160, 200, 300] {
            let out = render(&dump, &[("INTERDIMUX_COLS", &cols.to_string())]);
            for (i, line) in out.lines().enumerate() {
                let fields: Vec<&str> = line.split('\t').collect();
                assert_eq!(
                    fields.len(), 4,
                    "{} @ {} cols, row {}: {} fields, not 4: {:?}",
                    case, cols, i + 1, fields.len(), line
                );
                let spec = fields[3];
                assert!(
                    spec.starts_with("S:") || spec.starts_with("W:")
                        || spec.starts_with("P:") || spec.starts_with("D:"),
                    "{} @ {} cols, row {}: bad spec {:?}", case, cols, i + 1, spec
                );
            }
        }
    }
}

/// \x1f is the internal tmux field delimiter and must never reach fzf.
#[test]
fn the_unit_separator_never_reaches_a_rendered_row() {
    for case in ["basic", "cjk", "hostile", "emoji"] {
        let dump = std::fs::read_to_string(corpus_dir().join(format!("{}.dump", case))).unwrap();
        let out = render(&dump, &[]);
        assert!(!out.contains('\u{1f}'), "{}: US leaked into the output", case);
    }
}

/// Malformed input must degrade, never panic — panic=abort means a panic is a
/// blank popup with no error.
#[test]
fn malformed_input_never_panics() {
    let cases: Vec<String> = vec![
        String::new(),
        "\u{1e}".into(),
        "\u{1e}\u{1e}\u{1e}\u{1e}\u{1e}".into(),
        "garbage with no separators at all".into(),
        "a\u{1f}b\u{1e}".into(),
        // fewer fields than the parser expects
        "1\u{1f}s\n\u{1e}\ns\u{1f}0\n\u{1e}\n\u{1e}\n".into(),
        // a huge field
        format!("1\u{1f}{}\u{1f}1\u{1f}\n\u{1e}\n\u{1e}\n\u{1e}\n", "x".repeat(10_000)),
        // NUL and control bytes
        "1\u{1f}a\u{0}b\u{1f}1\u{1f}\n\u{1e}\n\u{1e}\n\u{1e}\n".into(),
    ];
    for (i, c) in cases.iter().enumerate() {
        let (code, out) = try_render(c);
        // A signal (None) means it crashed; anything else is a controlled
        // outcome.  0 = rendered; 3 = framing rejected so bash falls back.
        assert!(
            matches!(code, Some(0) | Some(3)),
            "case {} exited {:?} (None = killed by a signal, i.e. a panic)", i, code
        );
        if code == Some(0) {
            assert!(
                out.lines().all(|l| l.split('\t').count() == 4),
                "case {} produced a malformed row: {:?}", i, out
            );
        } else {
            assert!(out.is_empty(), "case {} rejected the input but still printed rows", i);
        }
    }
}

/// The invariant the whole column layout rests on: within one render, every
/// row's identity column occupies the SAME number of terminal cells. This is
/// what bash cannot guarantee — it pads by character count, so one CJK name
/// silently shifts every column on that row.
///
/// The oracle here is deliberately NOT the renderer's own `text::width`. It used
/// to be the identical expression — a per-char `UnicodeWidthChar` sum — which
/// made this test a tautology: it could not fail for any input the renderer
/// measured wrongly, and it duly passed while VS16 and ZWJ names shifted every
/// column to their right. Measuring by grapheme cluster is an independent
/// method, and it is the one that agrees with tmux's grid (verified against
/// `#{cursor_x}` on tmux 3.7b).
#[test]
fn identity_columns_all_have_equal_display_width() {
    fn visible_width(s: &str) -> usize {
        // strip SGR, then measure in cells
        let mut out = String::new();
        let mut esc = false;
        for c in s.chars() {
            if esc { if c == 'm' { esc = false } } else if c == '\x1b' { esc = true } else { out.push(c) }
        }
        // Independent of text::width: this walks clusters with its own rules and
        // only ever asks unicode-width for a single char's width.  Verified
        // against tmux 3.7b's `#{cursor_x}` on heart/check/keycap (2), ZWJ (2),
        // family (2), flag (2), rocket (2), CJK (4), combining latin (2), ascii.
        let ch: Vec<char> = out.chars().collect();
        let uw = |c: char| unicode_width::UnicodeWidthChar::width(c).unwrap_or(0);
        let is_ri = |c: char| ('\u{1f1e6}'..='\u{1f1ff}').contains(&c);
        let is_mark = |c: char| {
            ('\u{0300}'..='\u{036f}').contains(&c)
                || matches!(c, '\u{fe0f}' | '\u{fe0e}' | '\u{20e3}')
        };
        let mut cells = 0usize;
        let mut i = 0usize;
        while i < ch.len() {
            let mut w = uw(ch[i]);
            let mut j = i + 1;
            // two regional indicators are one flag
            if is_ri(ch[i]) && j < ch.len() && is_ri(ch[j]) {
                j += 1;
                w = 2;
            }
            loop {
                if j >= ch.len() {
                    break;
                }
                if is_mark(ch[j]) {
                    // U+FE0F requests emoji presentation, which is always wide
                    if ch[j] == '\u{fe0f}' {
                        w = w.max(2);
                    }
                    j += 1;
                } else if ch[j] == '\u{200d}' && j + 1 < ch.len() {
                    j += 2; // the joiner and whatever it joins stay in the cluster
                    w = w.max(2);
                } else {
                    break;
                }
            }
            cells += w;
            i = j;
        }
        cells
    }
    // The rule must actually be ON somewhere and OFF somewhere: an
    // implementation that never drew it would satisfy every assertion below.
    {
        let dump = std::fs::read_to_string(corpus_dir().join("basic.dump")).unwrap();
        let wide = render(&dump, &[("INTERDIMUX_COLS", "120"), ("INTERDIMUX_SESSION_RULE", "on")]);
        let tight = render(&dump, &[("INTERDIMUX_COLS", "40"), ("INTERDIMUX_SESSION_RULE", "on")]);
        let has_rule = |o: &str| {
            o.lines()
                .filter(|l| l.split('\t').nth(3).is_some_and(|s| s.starts_with("S:")))
                .any(|l| l.contains("──"))
        };
        assert!(has_rule(&wide), "the rule never drew at 120 cols");
        assert!(!has_rule(&tight), "the rule still drew at 40 cols, where the meta gets clipped");
    }

    for case in ["basic", "cjk", "hostile", "emoji", "bigindex"] {
        let dump = std::fs::read_to_string(corpus_dir().join(format!("{}.dump", case))).unwrap();
        // 52 is not decoration: the pane-id clamp only engages once the squeeze
        // loop has driven the identity column to its floor, which happens below
        // 60.  Sweeping only the wide widths would miss it entirely.  40 is
        // there for the session rule, whose dash run has to survive the floors.
        for cols in [40, 52, 60, 80, 120, 200] {
            for rule in ["on", "off"] {
                let out = render(
                    &dump,
                    &[("INTERDIMUX_COLS", &cols.to_string()), ("INTERDIMUX_SESSION_RULE", rule)],
                );
                // Session header rows are a SECOND column class once the group
                // rule is on: their identity field runs out to `rule` cells
                // rather than `ident`.  Both classes must still be internally
                // uniform, or one long session name shifts a whole group.
                let mut sess: Option<usize> = None;
                let mut child: Option<usize> = None;
                let mut ctx: Option<usize> = None;
                for (i, l) in out.lines().enumerate() {
                    let f: Vec<&str> = l.split('\t').collect();
                    let w = visible_width(f[0]);
                    let (slot, kind) = if f[3].starts_with("S:") {
                        (&mut sess, "session")
                    } else {
                        ctx = Some(visible_width(f[1]));
                        (&mut child, "child")
                    };
                    match *slot {
                        None => *slot = Some(w),
                        Some(first) => assert_eq!(
                            w, first,
                            "{} @ {} cols rule={}: {} row {} has a {}-cell identity column, the first has {} — columns are misaligned",
                            case, cols, rule, kind, i + 1, w, first
                        ),
                    }
                }
                match (rule, sess, child, ctx) {
                    // no rule: every row is one class again, exactly as before
                    ("off", Some(s), Some(c), _) => assert_eq!(
                        s, c,
                        "{} @ {} cols: with the rule off the session row must match the rest",
                        case, cols
                    ),
                    // The rule's whole purpose: the meta lands in the command
                    // column, i.e. ident + TAB + ctx.  Below the width where the
                    // squeeze stops fitting there IS no command column left, so
                    // the rule switches itself off and the row must be identical
                    // to the rule-off layout — those are the only two answers.
                    ("on", Some(s), Some(c), Some(x)) => assert!(
                        s == c + 1 + x || s == c,
                        "{} @ {} cols: the session row is {} cells, which is neither the \
                         command column ({}) nor the plain identity column ({})",
                        case, cols, s, c + 1 + x, c
                    ),
                    _ => {}
                }
            }
        }
    }
}

/// A stray RS inside a pane's cwd renumbers every later section: windows and
/// panes vanish and the current-row marker is lost.  tmux only rejects control
/// bytes in session and window NAMES, so this is reachable with a real
/// directory. The binary must REFUSE rather than render a mis-framed list.
#[test]
fn a_stray_record_separator_is_rejected_not_misparsed() {
    let good = "1700000000\u{1f}s\u{1f}1\u{1f}\n\u{1e}\n\u{1e}\n\u{1e}\ns\u{1f}0\u{1f}0\n";
    let (code, out) = try_render(good);
    assert_eq!(code, Some(0), "the well-formed control case must render");
    assert!(!out.is_empty());

    // the same dump with an extra RS, as a cwd containing \x1e would produce
    let bad = "1700000000\u{1f}s\u{1f}1\u{1f}\n\u{1e}\ns\u{1f}0\u{1f}w\u{1f}1\u{1f}zsh\u{1f}/home/u/we\u{1e}ird\u{1f}1\u{1f}0\u{1f}000\n\u{1e}\n\u{1e}\ns\u{1f}0\u{1f}0\n";
    let (code, out) = try_render(bad);
    assert_eq!(code, Some(3), "a stray RS must be rejected, not rendered");
    assert!(out.is_empty(), "a rejected input must print nothing");
}

/// A US inside a pane's cwd shifts every later field, which used to make
/// pane_pid attacker-chosen — a pid this process then reads from /proc.
#[test]
fn a_stray_unit_separator_drops_the_row_rather_than_shifting_fields() {
    // 10 fields where 9 are expected, because the path contains one US
    let bad = "1700000000\u{1f}s\u{1f}1\u{1f}\n\u{1e}\ns\u{1f}0\u{1f}w\u{1f}1\u{1f}zsh\u{1f}/home/u/x\u{1f}1\u{1f}1\u{1f}4242\u{1f}000\n\u{1e}\n\u{1e}\ns\u{1f}0\u{1f}0\n";
    let (code, out) = try_render(bad);
    assert_eq!(code, Some(0));
    // the session row survives; the malformed window row is dropped, not
    // rendered with fields read from the wrong positions
    assert!(out.contains("S:s"), "the session row should still render");
    assert!(!out.contains("4242"), "a shifted field must not be used as a pid");
    for l in out.lines() {
        assert_eq!(l.split('\t').count(), 4);
    }
}

/// Control bytes in a path must not reach the terminal: an ESC injected a live
/// escape sequence into the popup and silently broke the column maths.
#[test]
fn control_bytes_in_a_path_are_neutralised() {
    let dump = "1700000000\u{1f}s\u{1f}1\u{1f}\n\u{1e}\ns\u{1f}0\u{1f}w\u{1f}1\u{1f}zsh\u{1f}/home/u/e\u{1b}[31mvil\u{1f}1\u{1f}0\u{1f}000\n\u{1e}\n\u{1e}\ns\u{1f}0\u{1f}0\n";
    let (code, out) = try_render(dump);
    assert_eq!(code, Some(0));
    // the only ESCs left must be our own SGR colours, never one from the path
    assert!(!out.contains("\u{1b}[31m"), "a path injected its own escape: {:?}", out);
    assert!(!out.contains('\r'), "a CR in a path would redraw the row over itself");
}
