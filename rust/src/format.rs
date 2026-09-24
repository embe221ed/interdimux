//! Smart command formatting: highlight the ssh host, or the file an editor has
//! open; dim an idle shell; show argv0 (and an interpreter's script) by its
//! basename.  A faithful port of bash `format_command`, including its
//! flag-skipping tables and its "last positional wins" behaviour.

use crate::palette::{Palette, RST};
use crate::proc::is_shell;

/// ssh/mosh flags that consume the following argument.
fn ssh_flag_takes_value(w: &str) -> bool {
    matches!(
        w,
        "-b" | "-c" | "-D" | "-E" | "-e" | "-F" | "-I" | "-i" | "-J" | "-L" | "-l" | "-m"
            | "-O" | "-o" | "-p" | "-Q" | "-R" | "-S" | "-W" | "-w"
    )
}

/// Editor flags that consume the following argument.
fn editor_flag_takes_value(w: &str) -> bool {
    matches!(w, "-u" | "-U" | "-s" | "-S" | "-p" | "-c" | "--cmd" | "--listen")
}

fn is_editor(base: &str) -> bool {
    matches!(
        base,
        "vim" | "nvim" | "vi" | "nano" | "emacs" | "code" | "hx" | "helix" | "micro"
            | "kate" | "gedit" | "subl"
    )
}

/// Interpreters whose first argument, when it is a path, is the script they
/// run.  Mirrors bash INTERPRETERS_PATTERN
/// `^(python[0-9.]*|lua[0-9.]*|node|nodejs|ruby|perl|php)$`, plus the shells.
fn is_interpreter(base: &str) -> bool {
    let versioned = |stem: &str| {
        base.strip_prefix(stem)
            .is_some_and(|v| v.chars().all(|c| c.is_ascii_digit() || c == '.'))
    };
    versioned("python")
        || versioned("lua")
        || matches!(base, "node" | "nodejs" | "ruby" | "perl" | "php")
        || is_shell(base)
}

/// Returns (rendered, plain_text) — plain is what the width maths must use.
pub fn format_command(cmd: &str, p: &Palette) -> (String, String) {
    if cmd.is_empty() {
        return (String::new(), String::new());
    }
    let name = cmd.split(' ').next().unwrap_or("");
    let base = name.rsplit('/').next().unwrap_or(name);
    let args: Vec<&str> = cmd.split(' ').skip(1).filter(|s| !s.is_empty()).collect();

    if base == "ssh" || base == "mosh" {
        let mut host = "";
        let mut skip = false;
        for w in &args {
            if skip {
                skip = false;
                continue;
            }
            if w.starts_with('-') {
                if ssh_flag_takes_value(w) {
                    skip = true;
                }
            } else {
                host = w;
            }
        }
        if !host.is_empty() {
            return (
                format!("{}{} {}{}{}", p.dim_cmd, base, p.dim_ssh, host, RST),
                format!("{} {}", base, host),
            );
        }
    }

    if is_editor(base) {
        let mut file = "";
        let mut skip = false;
        for w in &args {
            if skip {
                skip = false;
                continue;
            }
            if w.starts_with('-') {
                if editor_flag_takes_value(w) {
                    skip = true;
                }
            } else if w.starts_with('+') {
                // vim +line / +/pattern
            } else {
                file = w;
            }
        }
        if !file.is_empty() {
            let fname = file.rsplit('/').next().unwrap_or(file);
            return (
                format!("{}{} {}{}{}", p.dim_cmd, base, p.dim_edit, fname, RST),
                format!("{} {}", base, fname),
            );
        }
    }

    // An idle shell — the shell and nothing but its options: `-zsh`,
    // `/bin/bash`, `bash --norc -i`.  Its bare name, in the tree colour, so the
    // rows doing real work are the ones in the accent (IDEAS #10).  A shell
    // running something (`bash build.sh`, `sh -c …`) is real work.
    if is_shell(base) && args.iter().all(|w| w.starts_with('-')) {
        let name = base.strip_prefix('-').unwrap_or(base);
        return (format!("{}{}{}", p.dim_tree, name, RST), name.to_string());
    }

    // Everything else, with argv0 by its basename: `/usr/bin/python3 -c …`
    // spent nine of the column's cells on `/usr/bin/`.  An argv0 ending in '/'
    // has no basename and keeps the whole word.  An interpreter running a
    // script by path shows the script's basename too (`#!/usr/bin/python3` ->
    // `python3 tool.py`).  Only the word straight after argv0, never an option.
    let shown = if base.is_empty() { name } else { base };
    let mut rest = cmd[name.len()..].to_string();
    if is_interpreter(base) {
        if let Some(r1) = rest.strip_prefix(' ') {
            let w1 = r1.split(' ').next().unwrap_or("");
            let w1_base = w1.rsplit('/').next().unwrap_or(w1);
            if !w1.starts_with('-') && w1.contains('/') && !w1_base.is_empty() {
                rest = format!(" {}{}", w1_base, &r1[w1.len()..]);
            }
        }
    }
    let plain = format!("{}{}", shown, rest);
    (format!("{}{}{}", p.dim_cmd, plain, RST), plain)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pal() -> Palette {
        Palette::from_env()
    }

    fn plain(cmd: &str) -> String {
        format_command(cmd, &pal()).1
    }

    #[test]
    fn ssh_host_is_extracted() {
        assert_eq!(plain("ssh user@host"), "ssh user@host");
        assert_eq!(plain("ssh -p 2222 user@host"), "ssh user@host");
        assert_eq!(plain("mosh -o something box"), "mosh box");
    }

    #[test]
    fn ssh_flag_values_are_not_mistaken_for_the_host() {
        // -i takes a value; "key.pem" must not become the host
        assert_eq!(plain("ssh -i key.pem realhost"), "ssh realhost");
        // last positional wins, matching bash
        assert_eq!(plain("ssh a b"), "ssh b");
    }

    #[test]
    fn editor_file_is_basenamed() {
        assert_eq!(plain("nvim /a/b/main.rs"), "nvim main.rs");
        assert_eq!(plain("vim +42 notes.md"), "vim notes.md");
        assert_eq!(plain("nvim --cmd 'set x' file.txt"), "nvim file.txt");
    }

    #[test]
    fn path_qualified_editors_are_recognised() {
        assert_eq!(plain("/usr/bin/nvim x.rs"), "nvim x.rs");
    }

    #[test]
    fn a_bare_command_passes_through() {
        assert_eq!(plain("cargo watch -x run"), "cargo watch -x run");
        assert_eq!(plain(""), "");
        // spacing after argv0 is the command's own, and kept
        assert_eq!(plain("a  b"), "a  b");
    }

    // --- idle shells (IDEAS #10) ---------------------------------------------

    #[test]
    fn an_idle_shell_is_its_bare_name_in_the_tree_colour() {
        let p = pal();
        for (cmd, name) in [
            ("-zsh", "zsh"),
            ("zsh", "zsh"),
            ("/bin/bash", "bash"),
            ("-/bin/bash", "bash"),
            ("bash --norc --noprofile -i", "bash"),
            ("-login", "login"),
        ] {
            let (rendered, text) = format_command(cmd, &p);
            assert_eq!(text, name, "{:?}", cmd);
            assert_eq!(rendered, format!("{}{}{}", p.dim_tree, name, RST), "{:?}", cmd);
            assert!(!rendered.contains(p.dim_cmd.as_str()), "{:?} kept the accent", cmd);
        }
    }

    #[test]
    fn a_shell_doing_work_keeps_the_accent() {
        let p = pal();
        for cmd in ["bash build.sh", "sh -c make", "zsh -c exit"] {
            let (rendered, text) = format_command(cmd, &p);
            assert!(rendered.starts_with(p.dim_cmd.as_str()), "{:?}: {:?}", cmd, rendered);
            assert_eq!(text, cmd);
        }
        // the tree colour and the accent must really differ for the test above
        // to mean anything
        assert_ne!(p.dim_tree, p.dim_cmd);
    }

    // --- argv0 and scripts by their basename -------------------------------

    #[test]
    fn argv0_is_shown_by_its_basename() {
        assert_eq!(plain("/usr/bin/python3 -c x"), "python3 -c x");
        assert_eq!(plain("/bin/sleep 999"), "sleep 999");
        assert_eq!(plain("/usr/bin/htop"), "htop");
        assert_eq!(plain("./configure --prefix=/usr"), "configure --prefix=/usr");
        // editors and ssh with nothing to highlight still lose the path
        assert_eq!(plain("/usr/bin/nvim"), "nvim");
        // no basename: the whole word stays
        assert_eq!(plain("a/ b"), "a/ b");
        // a '/' in a later argument is not argv0's
        assert_eq!(plain("git log origin/main"), "git log origin/main");
    }

    #[test]
    fn an_interpreters_script_is_shown_by_its_basename() {
        assert_eq!(plain("/usr/bin/python3 /home/u/bin/tool.py -v"), "python3 tool.py -v");
        assert_eq!(plain("python3.12 ./manage.py runserver"), "python3.12 manage.py runserver");
        assert_eq!(plain("node /usr/lib/node_modules/npm/bin/npm-cli.js i"), "node npm-cli.js i");
        assert_eq!(plain("/bin/bash /opt/app/build.sh a/b"), "bash build.sh a/b");
        assert_eq!(plain("perl /x/y.pl"), "perl y.pl");
        assert_eq!(plain("lua5.4 a/b.lua"), "lua5.4 b.lua");
        // only the word right after argv0, and never an option
        assert_eq!(plain("python3 -u /x/tool.py"), "python3 -u /x/tool.py");
        assert_eq!(plain("python3 -m http.server"), "python3 -m http.server");
        assert_eq!(plain("perl -I/x/lib y.pl"), "perl -I/x/lib y.pl");
        // a script word with no basename stays whole
        assert_eq!(plain("bash /x/"), "bash /x/");
        // not an interpreter: its arguments are left alone
        assert_eq!(plain("cp /a/b /c/d"), "cp /a/b /c/d");
        assert_eq!(plain("pythonx /a/b"), "pythonx /a/b");
    }

    #[test]
    fn an_editor_with_no_file_is_not_specialised() {
        assert_eq!(plain("nvim"), "nvim");
        assert_eq!(plain("ssh"), "ssh");
    }

    #[test]
    fn rendered_output_wraps_in_escapes_but_plain_does_not() {
        let (rendered, plain) = format_command("nvim main.rs", &pal());
        assert!(rendered.contains("\x1b["), "should be coloured");
        assert!(!plain.contains("\x1b["), "plain must be escape-free for width maths");
        assert_eq!(plain, "nvim main.rs");
    }
}
