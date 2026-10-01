//! Smart command formatting: highlight the ssh host, or the file an editor has
//! open; dim an idle shell; show argv0 (and an interpreter's script) by its
//! basename.  A faithful port of bash `format_command`, including its
//! flag-skipping tables.

use crate::palette::{Palette, RST};
use crate::proc::{is_idle_shell, is_shell};

/// Does the ssh/mosh flag word `w` (it starts with `-`) consume the following
/// argument?  mosh's long options that take a value do.  Short flags are read
/// as getopt reads them: bundled, and the first letter that takes a value takes
/// the REST of the word (`-p2222`, `-oX=no`), or the next word when it is the
/// last letter (`-NL 8080:h:80`, `-vp 2222`).  Since the host is the first word
/// left over, a value this misses becomes the host (review BUG-36).  The same
/// rule as the `case` in bash `format_command`.
fn ssh_flag_takes_value(w: &str) -> bool {
    if let Some(long) = w.strip_prefix("--") {
        return matches!(
            long,
            "client" | "server" | "predict" | "port" | "family" | "ssh" | "bind-server"
                | "experimental-remote-ip"
        );
    }
    let letters = &w[1..];
    let takes_value = |c: char| "BbcDEeFIiJLlmOoPpQRSWw".contains(c);
    // ASCII letters, so "is the last" is a byte test
    letters.find(takes_value).is_some_and(|i| i + 1 == letters.len())
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
/// run: python and lua, each with an optional version of ASCII digits and
/// dots, node nodejs ruby perl php, and the shells.  Mirrors the `case` in bash
/// `format_command`.
pub fn is_interpreter(base: &str) -> bool {
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

    // The host is the FIRST word that is neither a flag nor a flag's value:
    // `ssh [options] destination [command [argument ...]]`, and whatever follows
    // the destination is the remote command (review BUG-36).
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
                break;
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
    if is_idle_shell(cmd) {
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
    }

    /// The destination is the first positional; what follows it is the remote
    /// command, which used to take the label (review BUG-36).
    #[test]
    fn a_remote_command_does_not_take_the_hosts_place() {
        assert_eq!(plain("ssh a b"), "ssh a");
        assert_eq!(plain("ssh box tail -f /var/log/x"), "ssh box");
        assert_eq!(plain("ssh -l alice host uptime"), "ssh host");
        assert_eq!(plain("ssh -o StrictHostKeyChecking=no user@h1 sudo -i"), "ssh user@h1");
        assert_eq!(plain("mosh me@box -- htop"), "mosh me@box");
    }

    /// With the first positional as the host, every flag value the table
    /// misses takes the label.  Bundled short flags whose last letter takes a
    /// value (a tunnel's `-NL`, `-vp`), `-B` and `-P`, and mosh's long options
    /// must all give it back to the host, as they did when the last word won
    /// (review BUG-36).
    #[test]
    fn flag_values_in_any_spelling_are_not_the_host() {
        assert_eq!(plain("ssh -NL 8080:localhost:80 user@host"), "ssh user@host");
        assert_eq!(plain("ssh -fNL 5432:db:5432 bastion"), "ssh bastion");
        assert_eq!(plain("ssh -ND 1080 proxyhost"), "ssh proxyhost");
        assert_eq!(plain("ssh -vp 2222 host"), "ssh host");
        assert_eq!(plain("ssh -Ap 22 host ls"), "ssh host");
        assert_eq!(plain("ssh -B eth0 host"), "ssh host");
        assert_eq!(plain("ssh -P mytag host"), "ssh host");
        // the value is the rest of the word: the next word is the host
        assert_eq!(plain("ssh -p2222 host"), "ssh host");
        assert_eq!(plain("ssh -oStrictHostKeyChecking=no host"), "ssh host");
        assert_eq!(plain("ssh -pL host"), "ssh host");
        // flags that take nothing, bundled
        assert_eq!(plain("ssh -At jump"), "ssh jump");
        assert_eq!(plain("ssh -46 host"), "ssh host");
        assert_eq!(plain("mosh --port 60001 host"), "mosh host");
        assert_eq!(plain("mosh --port=60001 host"), "mosh host");
        assert_eq!(plain("mosh --ssh ssh host"), "mosh host");
        assert_eq!(plain("mosh --predict always host"), "mosh host");
        assert_eq!(plain("mosh --no-init host"), "mosh host");
        // nothing left over: no host, so the plain command shows
        assert_eq!(plain("ssh -L"), "ssh -L");
        assert_eq!(plain("ssh --"), "ssh --");
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
