//! Smart command formatting: highlight the ssh host, or the file an editor has
//! open.  A faithful port of bash `format_command`, including its flag-skipping
//! tables and its "last positional wins" behaviour.

use crate::palette::{Palette, RST};

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

    (format!("{}{}{}", p.dim_cmd, cmd, RST), cmd.to_string())
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
        assert_eq!(plain("-zsh"), "-zsh");
        assert_eq!(plain(""), "");
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
