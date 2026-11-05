//! Shared search scopes. Changing a scope never re-collects the backend.

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum Scope {
    Name,
    Path,
    Command,
    All,
    #[default]
    NameCommand,
}

impl Scope {
    pub(crate) fn nth(self) -> &'static str {
        match self {
            Self::Name => "1",
            Self::Path => "2",
            Self::Command => "3",
            Self::All => "1,2,3",
            Self::NameCommand => "1,3",
        }
    }

    pub(crate) fn from_nth(nth: &str) -> Option<Self> {
        match nth {
            "1" => Some(Self::Name),
            "2" => Some(Self::Path),
            "3" => Some(Self::Command),
            "1,2,3" => Some(Self::All),
            "1,3" => Some(Self::NameCommand),
            _ => None,
        }
    }

    pub(crate) fn next(self) -> Self {
        match self {
            Self::NameCommand => Self::Name,
            Self::Name => Self::Path,
            Self::Path => Self::Command,
            Self::Command => Self::All,
            Self::All => Self::NameCommand,
        }
    }

    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Name => "name",
            Self::Path => "path",
            Self::Command => "cmd",
            Self::All => "all",
            Self::NameCommand => "name+cmd",
        }
    }

    pub(crate) fn prompt(self) -> String {
        format!("{} ❯ ", self.label())
    }

    /// A controller may return these native actions over fzf's UI connection.
    /// There is no shell work on a query change or a search-scope repaint.
    pub(crate) fn actions(self) -> String {
        format!(
            "change-nth({})+change-prompt({})",
            self.nth(),
            self.prompt()
        )
    }
}

/// Direct fzf cycling for callers which do not need to update the prompt.
#[cfg(test)]
pub(crate) const CYCLE_ACTION: &str = "change-nth(1|2|3|1,2,3|1,3)";

/// Display columns are identity, path and command, with a hidden native token
/// after them. fzf calculates --nth against --with-nth's transformed fields.
pub(crate) fn options(scope: Scope, raw: bool) -> Vec<String> {
    let mut options = vec![
        "--delimiter=\t".into(),
        "--with-nth=1..3".into(),
        format!("--nth={}", scope.nth()),
        format!("--prompt={}", scope.prompt()),
        // A full identity can exceed the viewport. Freezing it prevents fzf
        // from revealing matches in either its suffix or later columns.
        "--freeze-left=0".into(),
        "--color=fg:dim,nth:regular,fg+:regular:bold".into(),
    ];
    if raw {
        options.extend([
            "--raw".into(),
            "--gutter-raw= ".into(),
            "--color=nomatch:#7c6f64:strip:dim".into(),
        ]);
    }
    options
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::process::{Command, Stdio};

    #[test]
    fn cycles_every_legacy_scope_and_returns_to_default() {
        let expected = ["1,3", "1", "2", "3", "1,2,3", "1,3"];
        let mut scope = Scope::default();
        for nth in expected {
            assert_eq!(scope.nth(), nth);
            assert_eq!(Scope::from_nth(nth), Some(scope));
            assert!(scope.actions().contains(&scope.prompt()));
            scope = scope.next();
        }
        assert_eq!(Scope::from_nth("4"), None);
    }

    #[test]
    fn raw_scope_options_never_launch_callbacks_or_hide_deep_matches() {
        let configured = options(Scope::default(), true);
        assert!(configured.contains(&"--nth=1,3".into()));
        assert!(configured.contains(&"--freeze-left=0".into()));
        assert!(configured.contains(&"--raw".into()));
        assert!(!configured
            .iter()
            .any(|o| o.contains("transform") || o.contains("execute") || o == "--no-hscroll"));
        assert!(!options(Scope::Path, false).iter().any(|o| o == "--raw"));
        assert_eq!(CYCLE_ACTION, "change-nth(1|2|3|1,2,3|1,3)");
    }

    #[test]
    fn real_fzf_searches_only_selected_visible_columns_and_never_target_tokens() {
        let fzf = std::env::var("INTERDIMUX_FZF_BIN").unwrap_or_else(|_| "fzf".into());
        let Ok(version) = Command::new(&fzf).arg("--version").output() else {
            eprintln!("Skipping search scope integration: fzf is unavailable");
            return;
        };
        if !version.status.success() {
            return;
        }
        for scope in [
            Scope::Name,
            Scope::Path,
            Scope::Command,
            Scope::All,
            Scope::NameCommand,
        ] {
            for (query, expected) in [
                (
                    "namesentinel",
                    matches!(scope, Scope::Name | Scope::All | Scope::NameCommand),
                ),
                ("pathsentinel", matches!(scope, Scope::Path | Scope::All)),
                (
                    "commandsentinel",
                    matches!(scope, Scope::Command | Scope::All | Scope::NameCommand),
                ),
                ("secrettargettoken", false),
            ] {
                let mut child = Command::new(&fzf)
                    .args(options(scope, false))
                    .arg(format!("--filter='{query}"))
                    .env_remove("FZF_DEFAULT_OPTS")
                    .env_remove("FZF_DEFAULT_OPTS_FILE")
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .spawn()
                    .unwrap();
                child
                    .stdin
                    .take()
                    .unwrap()
                    .write_all(b"namesentinel\t/pathsentinel\tcommandsentinel\tsecrettargettoken\n")
                    .unwrap();
                let output = child.wait_with_output().unwrap();
                assert!(
                    matches!(output.status.code(), Some(0 | 1)),
                    "{}",
                    String::from_utf8_lossy(&output.stderr)
                );
                assert_eq!(
                    !output.stdout.is_empty(),
                    expected,
                    "scope={scope:?}, query={query}"
                );
                if expected {
                    assert!(
                        output.stdout.ends_with(b"\tsecrettargettoken\n"),
                        "selection must preserve the exact hidden token"
                    );
                }
            }
        }
    }
}
