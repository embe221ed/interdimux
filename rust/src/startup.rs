//! Resolve project startup commands only after an explicit create action.
//! Files are configuration text, never evaluated here; each returned line is
//! literal shell input for the newly created session's first pane.

use std::fs::{self, OpenOptions};
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Source {
    Config(PathBuf),
    Project(PathBuf),
    Global,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Plan {
    pub source: Source,
    pub lines: Vec<String>,
}

// Explicit creation can read configuration, but never block opening a FIFO or
// read a device as a startup script. A complete bounded file is required.
fn read_regular(path: &Path) -> Option<String> {
    if crate::projects::excluded_network(&path.to_string_lossy()) {
        return None;
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        #[cfg(target_os = "linux")]
        options.custom_flags(0x800);
        #[cfg(not(target_os = "linux"))]
        options.custom_flags(0x4);
    }
    let mut file = options.open(path).ok()?;
    if !file.metadata().ok()?.is_file() {
        return None;
    }
    let mut bytes = Vec::new();
    file.by_ref().take(262145).read_to_end(&mut bytes).ok()?;
    if bytes.len() > 262144 {
        return None;
    }
    String::from_utf8(bytes).ok()
}

fn lines(text: &str) -> Vec<String> {
    text.split('\n')
        .map(|line| line.strip_suffix('\r').unwrap_or(line))
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect()
}

#[derive(Debug)]
enum ClassItem {
    Range(char, char),
    Named(String),
}
#[derive(Debug)]
enum Atom {
    Star,
    Any,
    Literal(char),
    Class(bool, Vec<ClassItem>),
}
fn atoms(pattern: &str) -> Vec<Atom> {
    let chars: Vec<_> = pattern.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        match chars[i] {
            '*' => out.push(Atom::Star),
            '?' => out.push(Atom::Any),
            '\\' if i + 1 < chars.len() => {
                i += 1;
                out.push(Atom::Literal(chars[i]));
            }
            '[' => {
                let mut j = i + 1;
                let negated = matches!(chars.get(j), Some('!' | '^'));
                if negated {
                    j += 1;
                }
                let start = j;
                let mut ranges = Vec::new();
                while j < chars.len() && (chars[j] != ']' || j == start) {
                    if chars[j] == '[' && chars.get(j + 1) == Some(&':') {
                        if let Some(end) = (j + 2..chars.len().saturating_sub(1))
                            .find(|k| chars[*k] == ':' && chars[*k + 1] == ']')
                        {
                            ranges.push(ClassItem::Named(chars[j + 2..end].iter().collect()));
                            j = end + 2;
                            continue;
                        }
                    }
                    if chars[j] == '\\' && j + 1 < chars.len() {
                        j += 1;
                    }
                    let first = chars[j];
                    j += 1;
                    if chars.get(j) == Some(&'-') && chars.get(j + 1).is_some_and(|c| *c != ']') {
                        j += 1;
                        if chars[j] == '\\' && j + 1 < chars.len() {
                            j += 1;
                        }
                        ranges.push(ClassItem::Range(first, chars[j]));
                        j += 1;
                    } else {
                        ranges.push(ClassItem::Range(first, first));
                    }
                }
                if j < chars.len() && !ranges.is_empty() {
                    out.push(Atom::Class(negated, ranges));
                    i = j;
                } else {
                    out.push(Atom::Literal('['));
                }
            }
            c => out.push(Atom::Literal(c)),
        }
        i += 1;
    }
    out
}
fn class_matches(item: &ClassItem, c: char) -> bool {
    match item {
        ClassItem::Range(a, b) => *a <= c && c <= *b,
        ClassItem::Named(name) => match name.as_str() {
            "alnum" => c.is_alphanumeric(),
            "alpha" => c.is_alphabetic(),
            "ascii" => c.is_ascii(),
            "blank" => matches!(c, ' ' | '\t'),
            "cntrl" => c.is_control(),
            "digit" => c.is_ascii_digit(),
            "graph" => !c.is_control() && !c.is_whitespace(),
            "lower" => c.is_lowercase(),
            "print" => !c.is_control(),
            "punct" => c.is_ascii_punctuation(),
            "space" => c.is_whitespace(),
            "upper" => c.is_uppercase(),
            "word" => c.is_alphanumeric() || c == '_',
            "xdigit" => c.is_ascii_hexdigit(),
            _ => false,
        },
    }
}
pub(crate) fn glob(pattern: &str, text: &str) -> bool {
    let pattern = atoms(pattern);
    let text: Vec<_> = text.chars().collect();
    let (mut p, mut t, mut checkpoint) = (0, 0, 0);
    let mut star = None;
    while t < text.len() {
        let matches = match pattern.get(p) {
            Some(Atom::Star) => {
                star = Some(p);
                p += 1;
                checkpoint = t;
                continue;
            }
            Some(Atom::Any) => true,
            Some(Atom::Literal(c)) => *c == text[t],
            Some(Atom::Class(negated, ranges)) => {
                ranges.iter().any(|item| class_matches(item, text[t])) != *negated
            }
            None => false,
        };
        if matches {
            p += 1;
            t += 1;
        } else if let Some(previous) = star {
            checkpoint += 1;
            t = checkpoint;
            p = previous + 1;
        } else {
            return false;
        }
    }
    while matches!(pattern.get(p), Some(Atom::Star)) {
        p += 1;
    }
    p == pattern.len()
}
fn escape_glob(value: &str) -> String {
    let mut out = String::new();
    for c in value.chars() {
        if matches!(c, '*' | '?' | '[' | ']' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}
fn pattern_matches(pattern: &str, dir: &str, home: &str) -> bool {
    if pattern == "~" || pattern.starts_with("~/") {
        let rest = &pattern[1..];
        if glob(
            &format!("{}{rest}", escape_glob(home.trim_end_matches('/'))),
            dir,
        ) {
            return true;
        }
        if !crate::projects::excluded_network(home) {
            if let Ok(physical) = fs::canonicalize(home) {
                return glob(
                    &format!("{}{rest}", escape_glob(&physical.to_string_lossy())),
                    dir,
                );
            }
        }
        false
    } else {
        glob(pattern, dir)
    }
}
fn configured(text: &str, dir: &str, home: &str) -> Option<String> {
    for line in text.split('\n') {
        let line = line.trim_start();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (pattern, command) = if let Some((pattern, command)) = line.split_once('\t') {
            (pattern.trim_end(), command.trim_start())
        } else if let Some(index) = line.find(char::is_whitespace) {
            (&line[..index], line[index..].trim_start())
        } else {
            continue;
        };
        if !pattern.is_empty() && !command.is_empty() && pattern_matches(pattern, dir, home) {
            return Some(command.to_owned());
        }
    }
    None
}
fn planned(dir: &Path, home: &str, config: &Path, fallback: &str, enabled: bool) -> Option<Plan> {
    if !enabled || crate::projects::excluded_network(&dir.to_string_lossy()) {
        return None;
    }
    let physical = fs::canonicalize(dir).ok();
    let dir = physical.as_deref().unwrap_or(dir);
    if crate::projects::excluded_network(&dir.to_string_lossy()) {
        return None;
    }
    if let Some(command) =
        read_regular(config).and_then(|text| configured(&text, &dir.to_string_lossy(), home))
    {
        let lines = lines(&command);
        if !lines.is_empty() {
            return Some(Plan {
                source: Source::Config(config.into()),
                lines,
            });
        }
    }
    let project = dir.join(".interdimux-startup");
    if let Some(text) = read_regular(&project) {
        let lines = lines(text.trim());
        if !lines.is_empty() {
            return Some(Plan {
                source: Source::Project(project),
                lines,
            });
        }
    }
    let lines = lines(fallback);
    if lines.is_empty() {
        None
    } else {
        Some(Plan {
            source: Source::Global,
            lines,
        })
    }
}
pub(crate) fn plan(dir: &str) -> Option<Plan> {
    let home = crate::env_text("HOME");
    let base = match crate::env_text("XDG_CONFIG_HOME") {
        value if !value.is_empty() => PathBuf::from(value),
        _ => Path::new(&home).join(".config"),
    };
    planned(
        Path::new(dir),
        &home,
        &base.join("interdimux/startup.conf"),
        &crate::env_text("INTERDIMUX_STARTUP_COMMAND"),
        crate::env_text("INTERDIMUX_HYDRATE") != "off",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Fixture {
        root: PathBuf,
        home: PathBuf,
        config: PathBuf,
        project: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "imux-startup-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let home = root.join("h[ome]");
            let config = root.join("config/startup.conf");
            let project = home.join("work/api-v2");
            fs::create_dir_all(config.parent().unwrap()).unwrap();
            fs::create_dir_all(&project).unwrap();
            Self {
                root,
                home,
                config,
                project,
            }
        }
        fn plan(&self, fallback: &str) -> Option<Plan> {
            planned(
                &self.project,
                self.home.to_str().unwrap(),
                &self.config,
                fallback,
                true,
            )
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn globs_match_unicode_paths_slashes_classes_and_literal_escapes() {
        for (pattern, text) in [
            ("*/api*", "/work/a/b/api-v2"),
            ("?/日本語", "界/日本語"),
            ("api[0-9]", "api2"),
            ("[!a-c]", "z"),
            ("[[:digit:]][[:alpha:]]", "2a"),
            ("literal\\*", "literal*"),
            ("[abc", "[abc"),
            ("[\\]]", "]"),
        ] {
            assert!(glob(pattern, text), "{pattern:?}: {text:?}");
        }
        for (pattern, text) in [
            ("api?", "api"),
            ("[!a-c]", "b"),
            ("[[:digit:]]", "x"),
            ("a*b", "a/xx/c"),
        ] {
            assert!(!glob(pattern, text), "{pattern:?}: {text:?}");
        }
    }
    #[test]
    fn first_config_match_wins_before_project_and_global_without_expanding_home_glob_bytes() {
        let f = Fixture::new();
        fs::write(
            &f.config,
            "# ignored\n~/work/api*    echo CONFIG\n~/work/*    echo SECOND\n",
        )
        .unwrap();
        fs::write(f.project.join(".interdimux-startup"), "echo PROJECT").unwrap();
        assert_eq!(
            f.plan("echo GLOBAL"),
            Some(Plan {
                source: Source::Config(f.config.clone()),
                lines: vec!["echo CONFIG".into()]
            })
        );
        fs::write(&f.config, "~/elsewhere* echo NO\n").unwrap();
        assert_eq!(f.plan("echo GLOBAL").unwrap().lines, ["echo PROJECT"]);
        fs::remove_file(f.project.join(".interdimux-startup")).unwrap();
        assert_eq!(f.plan("echo GLOBAL").unwrap().source, Source::Global);
    }
    #[test]
    fn tab_patterns_spaces_indentation_and_crlf_keep_exact_command_text() {
        let f = Fixture::new();
        let dir = f.home.join("My Projects/web");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            &f.config,
            "  ~/My Projects/*\t   echo kept # shell comment\r\n",
        )
        .unwrap();
        let plan = planned(&dir, f.home.to_str().unwrap(), &f.config, "", true).unwrap();
        assert_eq!(plan.lines, ["echo kept # shell comment"]);
        fs::write(
            f.project.join(".interdimux-startup"),
            "\r\n  echo ONE\r\n\r\nC-c\r\n\tprintf TWO\r\n",
        )
        .unwrap();
        assert_eq!(
            f.plan("").unwrap().lines,
            ["echo ONE", "C-c", "\tprintf TWO"]
        );
    }
    #[test]
    fn only_a_leading_home_token_expands_and_shell_syntax_is_data() {
        let f = Fixture::new();
        fs::write(
            &f.config,
            "$HOME/work/* echo WRONG\n~someone/work/* echo WRONG\n",
        )
        .unwrap();
        let marker = f.root.join("must-not-exist");
        let command = format!("$(touch {})", marker.display());
        fs::write(f.project.join(".interdimux-startup"), &command).unwrap();
        assert_eq!(f.plan("").unwrap().lines, [command]);
        assert!(!marker.exists());
        assert_eq!(
            configured(
                "~\techo HOME\n",
                f.home.to_str().unwrap(),
                f.home.to_str().unwrap()
            )
            .as_deref(),
            Some("echo HOME")
        );
    }
    #[test]
    #[cfg(unix)]
    fn tilde_matches_physical_home_when_home_is_a_symlink() {
        let f = Fixture::new();
        let logical = f.root.join("logical");
        std::os::unix::fs::symlink(&f.home, &logical).unwrap();
        fs::write(&f.config, "~/work/* echo MATCH\n").unwrap();
        assert_eq!(
            planned(&f.project, logical.to_str().unwrap(), &f.config, "", true)
                .unwrap()
                .lines,
            ["echo MATCH"]
        );
    }
    #[test]
    fn disabled_hydration_and_empty_sources_produce_no_plan() {
        let f = Fixture::new();
        fs::write(&f.config, "* echo RUN\n").unwrap();
        assert!(planned(
            &f.project,
            f.home.to_str().unwrap(),
            &f.config,
            "echo GLOBAL",
            false
        )
        .is_none());
        fs::write(&f.config, "# comments only\n").unwrap();
        fs::write(f.project.join(".interdimux-startup"), "\r\n \t\n").unwrap();
        assert!(f.plan("").is_none());
    }
    #[test]
    fn startup_sources_must_be_complete_regular_utf8_files() {
        let f = Fixture::new();
        fs::write(&f.config, vec![b'x'; 262145]).unwrap();
        fs::write(f.project.join(".interdimux-startup"), b"echo good\n\xff").unwrap();
        assert_eq!(f.plan("echo fallback").unwrap().lines, ["echo fallback"]);
        assert!(
            read_regular(&f.project).is_none(),
            "directories cannot be scripts"
        );
    }
    #[test]
    #[cfg(unix)]
    fn a_fifo_startup_source_never_blocks_or_executes() {
        let f = Fixture::new();
        let fifo = f.project.join(".interdimux-startup");
        let output = std::process::Command::new("mkfifo")
            .arg(&fifo)
            .output()
            .unwrap();
        assert!(output.status.success());
        let before = std::time::Instant::now();
        assert_eq!(f.plan("echo fallback").unwrap().lines, ["echo fallback"]);
        assert!(before.elapsed() < std::time::Duration::from_secs(1));
    }
}
