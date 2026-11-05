//! Configuration and local agent records shared by the native frontends.
//! The legacy gather3 wire path keeps receiving its already assembled config.
use crate::{
    agent,
    model::{Snapshot, Target},
    titles,
};
use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::path::{Path, PathBuf};

const LEGACY_RULES: &str = include_str!("../../scripts/interdimux-list.sh");

fn expand(value: &str) -> PathBuf {
    let home = crate::env_text("HOME");
    if value == "~" {
        home.into()
    } else if let Some(rest) = value.strip_prefix("~/") {
        Path::new(&home).join(rest)
    } else {
        value.into()
    }
}

fn read_regular(path: &Path, limit: usize) -> Option<Vec<u8>> {
    if unprobeable(path) {
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
    file.by_ref()
        .take((limit + 1) as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    (bytes.len() <= limit).then_some(bytes)
}

fn unprobeable(path: &Path) -> bool {
    let text = path.to_string_lossy();
    text.starts_with("//")
        || ["/Network", "/net"]
            .iter()
            .any(|prefix| path.starts_with(prefix))
        || crate::mounts::is_remote(&text)
}

fn default_rules() -> &'static str {
    LEGACY_RULES
        .split_once("DEFAULT_TITLE_RULES='")
        .map(|(_, rest)| rest.split_once("\n'\n").map_or(rest, |(rules, _)| rules))
        .unwrap_or("")
}

fn user_rules(path: &Path) -> String {
    let Some(bytes) = read_regular(path, 1_048_576) else {
        return String::new();
    };
    let bytes = bytes.split(|b| *b == 0).next().unwrap_or(&[]);
    bytes
        .split(|b| *b == b'\n')
        .filter_map(|line| std::str::from_utf8(line).ok())
        .collect::<Vec<_>>()
        .join("\n")
}

fn state_options(text: &str) -> Vec<String> {
    let mut names = Vec::new();
    for line in text.lines() {
        let fields: Vec<_> = line.split_whitespace().take(4).collect();
        if fields.len() != 4 || !fields[0].starts_with('@') {
            continue;
        }
        for value in fields[0].split(',') {
            let Some(value) = value.strip_prefix('@') else {
                continue;
            };
            if !value.is_empty()
                && value
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
                && !names.iter().any(|n| n == value)
            {
                names.push(value.to_owned());
            }
        }
    }
    names
}

pub(crate) fn agent_config(host: &str, host_short: &str) -> agent::Config {
    let config = agent::Config::from_env(host, host_short);
    // An explicit assembled ruleset remains authoritative (as in gather3).
    if std::env::var_os("INTERDIMUX_TITLE_RULESET").is_some() {
        return config;
    }
    let explicit = crate::env_text("INTERDIMUX_TITLE_RULES");
    let path = if !explicit.is_empty() {
        expand(&explicit)
    } else {
        let base = crate::env_text("XDG_CONFIG_HOME");
        if base.is_empty() {
            expand("~/.config/interdimux/titles")
        } else {
            Path::new(&base).join("interdimux/titles")
        }
    };
    let user = user_rules(&path);
    assemble_rules(
        config,
        &user,
        std::env::var_os("INTERDIMUX_STATE_OPTS").is_none(),
    )
}

fn assemble_rules(mut config: agent::Config, user: &str, infer_options: bool) -> agent::Config {
    let text = format!("{user}\n{}", default_rules());
    config.native_user_rule_count = Some(titles::parse(user).len());
    config.rules = titles::parse(&text);
    if infer_options {
        config.state_opts = state_options(&text);
    }
    config
}

pub(crate) fn option_format(config: &agent::Config) -> String {
    config
        .state_opts
        .iter()
        .filter(|s| {
            !s.is_empty()
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
        })
        .map(|name| format!("#{{=128;s/[\u{1d}\u{1e}\u{1f}\n]/?/:@{name}}}\u{1d}"))
        .collect()
}

fn process_identity(pid: u32, proc_start: &Value, pane_pid: u32) -> bool {
    #[cfg(target_os = "linux")]
    {
        let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) else {
            return false;
        };
        let Some((_, tail)) = stat.rsplit_once(')') else {
            return false;
        };
        let fields: Vec<_> = tail.split_whitespace().collect();
        let start = proc_start
            .as_str()
            .map(str::to_owned)
            .or_else(|| proc_start.as_u64().map(|n| n.to_string()));
        return fields.get(19).copied() == start.as_deref()
            && (pid == pane_pid
                || fields.get(3).and_then(|s| s.parse::<u32>().ok()) == Some(pane_pid));
    }
    #[cfg(target_os = "macos")]
    {
        let _ = proc_start;
        return match (
            crate::macproc::group_ids(pid),
            crate::macproc::group_ids(pane_pid),
        ) {
            (Some((group, _)), Some((_, foreground))) => group > 0 && group == foreground,
            _ => false,
        };
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = (pid, proc_start, pane_pid);
        false
    }
}

fn record_word(record: &Value) -> Option<&'static str> {
    match record["status"].as_str()? {
        "busy" => Some("working"),
        "idle" | "shell" => Some("idle"),
        "waiting" => Some(match record["waitingFor"].as_str() {
            Some("permission prompt" | "worker request" | "sandbox request") => "approve",
            _ => "input",
        }),
        _ => None,
    }
}

fn claude_command(raw: &str) -> bool {
    let first = raw.split_whitespace().next().unwrap_or("");
    Path::new(first)
        .file_name()
        .and_then(|s| s.to_str())
        .is_some_and(|s| matches!(s, "claude" | "claude.exe"))
        || raw.contains("/claude/versions/")
        || raw.contains("/@anthropic-ai/claude-code/")
}

fn registry_at(snapshot: &mut Snapshot, directory: &Path) {
    registry_at_with(snapshot, directory, process_identity);
}

fn registry_at_with(
    snapshot: &mut Snapshot,
    directory: &Path,
    verify: impl Fn(u32, &Value, u32) -> bool,
) {
    let mut resolver = crate::proc::Resolver::new();
    let local_claude: Vec<_> = snapshot
        .panes
        .iter()
        .filter(|p| {
            snapshot
                .pane_metadata
                .get(&p.key)
                .map_or(false, |m| m.local)
                && !snapshot.registry.contains_key(&p.agent_id)
                && p.pid > 0
                && {
                    let supplied = snapshot
                        .pane_metadata
                        .get(&p.key)
                        .map(|m| m.command_line.as_str())
                        .unwrap_or("");
                    claude_command(&p.cmd) || claude_command(supplied) || {
                        let version = p.cmd.chars().next().is_some_and(|c| c.is_ascii_digit())
                            && p.cmd.contains('.');
                        (version || matches!(p.cmd.as_str(), "node" | "nodejs" | "bun" | "cli.js"))
                            && claude_command(&resolver.full_command(p.pid, &p.cmd))
                    }
                }
        })
        .collect();
    if local_claude.is_empty() || unprobeable(directory) {
        return;
    }
    // Rex already reports the foreground PID. Read those exact records rather
    // than enumerating unrelated/stale sessions before the first frame.
    let mut files: Vec<_> = local_claude
        .iter()
        .filter(|p| matches!(p.target, Target::Rex { .. }))
        .map(|p| directory.join(format!("{}.json", p.pid)))
        .collect();
    if local_claude
        .iter()
        .any(|p| matches!(p.target, Target::TmuxNative { .. }))
    {
        if let Ok(entries) = fs::read_dir(directory) {
            files.extend(
                entries
                    .take(4096)
                    .filter_map(Result::ok)
                    .map(|entry| entry.path()),
            );
        }
    }
    files.sort();
    files.dedup();
    let mut read = 0usize;
    let mut records = Vec::new();
    for path in files {
        let Some(name) = path.file_name() else {
            continue;
        };
        let name = name.to_string_lossy();
        let Some(stem) = name.strip_suffix(".json") else {
            continue;
        };
        if stem.is_empty() || !stem.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let Some(bytes) = read_regular(&path, 65_536) else {
            continue;
        };
        read += bytes.len();
        if read > 2_097_152 {
            break;
        }
        let Ok(record) = serde_json::from_slice::<Value>(&bytes) else {
            continue;
        };
        if record["kind"] != "interactive" {
            continue;
        }
        let Some(pid) = record["pid"].as_u64().and_then(|n| u32::try_from(n).ok()) else {
            continue;
        };
        if pid.to_string() != stem {
            continue;
        }
        let Some(word) = record_word(&record) else {
            continue;
        };
        for pane in &local_claude {
            let matches = match &pane.target {
                Target::Rex { .. } => {
                    pid == pane.pid && verify(pid, &record["procStart"], pane.pid)
                }
                Target::TmuxNative {
                    pane_id: Some(id), ..
                } => {
                    record["tmux"]
                        .as_str()
                        .and_then(|v| v.rsplit_once('%'))
                        .map_or(false, |(_, n)| format!("%{n}") == *id)
                        && verify(pid, &record["procStart"], pane.pid)
                }
                _ => false,
            };
            if matches {
                records.push((
                    pane.agent_id.clone(),
                    agent::Record {
                        sid: String::new(),
                        word: word.into(),
                        since: record["statusUpdatedAt"].as_i64().unwrap_or(0) / 1000,
                    },
                ));
            }
        }
    }
    for (id, record) in records {
        snapshot.registry.entry(id).or_insert(record);
    }
}

pub(crate) fn merge_registry(snapshot: &mut Snapshot) {
    if crate::env_text("INTERDIMUX_AGENT_STATE") == "off" {
        return;
    }
    let custom = crate::env_text("INTERDIMUX_CLAUDE_DIR");
    let custom = if custom.is_empty() {
        crate::env_text("CLAUDE_CONFIG_DIR")
    } else {
        custom
    };
    let path = if custom.is_empty() {
        expand("~/.claude/sessions")
    } else {
        expand(&custom).join("sessions")
    };
    registry_at(snapshot, &path);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shares_legacy_builtins_and_valid_option_names() {
        let text = default_rules();
        let rules = titles::parse(text);
        assert!(rules.len() > 40);
        assert_eq!(
            titles::apply(&rules, "gemini", "✋ waiting").unwrap().state,
            "approve"
        );
        assert_eq!(
            titles::apply(&rules, "cursor-agent", "Fix cache")
                .unwrap()
                .desc,
            "Fix cache"
        );
        let options = state_options("@custom,@bad.x input - yes\n# ignored\n@custom done - done");
        assert_eq!(options, vec!["custom"]);
        assert!(state_options(text).contains(&"pane_wait_reason".to_owned()));
    }
    #[test]
    fn registry_states_match_legacy() {
        assert_eq!(
            record_word(&serde_json::json!({"status":"waiting","waitingFor":"sandbox request"})),
            Some("approve")
        );
        assert_eq!(
            record_word(&serde_json::json!({"status":"waiting","waitingFor":"input"})),
            Some("input")
        );
        assert_eq!(
            record_word(&serde_json::json!({"status":"shell"})),
            Some("idle")
        );
        assert_eq!(record_word(&serde_json::json!({"status":"unknown"})), None);
    }
    #[test]
    fn bounded_rule_reader_skips_invalid_lines_and_nonregular_files() {
        let root = std::env::temp_dir().join(format!("imux-native-config-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let file = root.join("titles");
        fs::write(
            &file,
            b"codex done $1 ok *\n\xffbad\nclaude input $1 ask *\0ignored",
        )
        .unwrap();
        let text = user_rules(&file);
        assert!(
            text.contains("ok *")
                && text.contains("ask *")
                && !text.contains("ignored")
                && !text.contains("bad")
        );
        assert!(user_rules(&root).is_empty());
        fs::remove_dir_all(root).unwrap();
    }
    fn config(user: &str) -> agent::Config {
        let mut c = agent::Config::from_env("box", "box");
        c.show_title = agent::ShowTitle::Known;
        c.state = true;
        c.known = ["claude", "codex", "qwen", "gemini"]
            .iter()
            .map(|s| (*s).into())
            .collect();
        assemble_rules(c, user, true)
    }
    fn field(c: &agent::Config, raw: &str, title: &str, alternate: Option<&str>) -> String {
        agent::native_command_field(
            raw,
            123,
            "pane",
            title,
            "",
            c,
            &agent::Registry::new(),
            &crate::palette::Palette::from_env(),
            1000,
            agent::NativeTitle {
                current: true,
                reported: false,
                alternate,
            },
        )
        .0
    }
    #[test]
    fn builtins_preserve_plain_verified_codex_titles_and_other_apps_generic_suppression() {
        let c = config("");
        assert_eq!(c.native_user_rule_count, Some(0));
        let codex = field(&c, "codex", "Repair startup race", None);
        assert!(codex.contains("Repair startup race") && !codex.contains("codex"));
        for (app, title) in [
            ("claude", "Claude Code"),
            ("claude", "✳ Claude Code"),
            ("qwen", "Qwen - project"),
        ] {
            assert!(
                !field(&c, app, title, None).contains(title),
                "generic {app} title must stay suppressed"
            );
            assert!(
                field(&c, app, title, Some("Useful task")).contains("Useful task"),
                "built-in suppression may allow a verified alternate"
            );
        }
    }
    #[test]
    fn actual_user_suppression_stops_fallback_and_user_rewrites_precede_builtins() {
        let c = config("codex - - *\n@custom input - yes");
        assert_eq!(c.native_user_rule_count, Some(2));
        assert!(
            !field(&c, "codex", "Repair startup race", Some("Alternate task")).contains("task")
        );
        let c = config("codex done Custom:$1 ⠸ * | *");
        let rendered = field(&c, "codex", "⠸ Repair startup race | project", None);
        assert!(rendered.contains("Custom:Repair startup race") && rendered.contains("done"));
        assert!(!rendered.contains("working"));
    }
    #[test]
    fn assembled_user_option_names_and_rules_share_the_same_validated_prefix() {
        let c = config("@custom,@bad.x input - yes\ncodex - - *\n");
        assert_eq!(c.native_user_rule_count, Some(2));
        assert_eq!(c.state_opts[0], "custom");
        let format = option_format(&c);
        assert!(
            format.contains("@custom")
                && format.contains("@agent_state")
                && !format.contains("bad.x")
        );
        let mut c = config("");
        c.state_opts = vec!["kept".into()];
        let c = assemble_rules(c, "@extra input - yes", false);
        assert_eq!(c.state_opts, ["kept"]);
    }

    static NEXT_REGISTRY: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    struct RegistryFixture(PathBuf);
    impl RegistryFixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "imux-registry-{}-{}",
                std::process::id(),
                NEXT_REGISTRY.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn write(&self, pid: u32, record: &Value) {
            fs::write(self.0.join(format!("{pid}.json")), record.to_string()).unwrap();
        }
    }
    impl Drop for RegistryFixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn registry_snapshot(command: &str) -> Snapshot {
        let target = Target::Rex {
            session_id: "s".into(),
            window_id: Some("w".into()),
            block_id: Some("p".into()),
        };
        let pane = crate::model::Pane {
            key: "p".into(),
            session_key: "s".into(),
            window_key: "w".into(),
            ordinal: "1".into(),
            name: "agent".into(),
            active: true,
            cmd: command.into(),
            path: String::new(),
            pid: 111,
            agent_id: "p".into(),
            title: String::new(),
            opts: String::new(),
            target,
        };
        let mut snapshot = Snapshot {
            panes: vec![pane],
            ..Snapshot::default()
        };
        snapshot.pane_metadata.insert(
            "p".into(),
            crate::model::PaneMetadata {
                local: true,
                ..crate::model::PaneMetadata::default()
            },
        );
        snapshot
    }
    fn registry_record(pid: u32) -> Value {
        serde_json::json!({"kind":"interactive","pid":pid,"procStart":"start","status":"waiting","waitingFor":"permission prompt","statusUpdatedAt":2000000})
    }
    #[test]
    fn rex_registry_uses_exact_foreground_file_validates_identity_and_handles_versioned_claude() {
        let f = RegistryFixture::new();
        f.write(111, &registry_record(111));
        f.write(222, &registry_record(222));
        let mut snapshot = registry_snapshot("2.1.281");
        snapshot.pane_metadata.get_mut("p").unwrap().command_line =
            "/home/u/.local/share/claude/versions/2.1.281 --resume".into();
        registry_at_with(&mut snapshot, &f.0, |pid, start, pane| {
            assert_eq!((pid, pane), (111, 111));
            assert_eq!(start, "start");
            true
        });
        assert_eq!(snapshot.registry["p"].word, "approve");
        assert_eq!(snapshot.registry["p"].since, 2000);
        snapshot.registry.clear();
        registry_at_with(&mut snapshot, &f.0, |_, _, _| false);
        assert!(
            snapshot.registry.is_empty(),
            "stale process identities must be ignored even when PID matches"
        );
        f.write(111, &registry_record(222));
        registry_at_with(&mut snapshot, &f.0, |_, _, _| {
            panic!("filename/PID mismatch must not reach validation")
        });
        assert!(snapshot.registry.is_empty());
    }
    #[test]
    fn native_program_status_is_preferred_and_codex_or_foreign_panes_do_not_scan_registry() {
        let f = RegistryFixture::new();
        f.write(111, &registry_record(111));
        let mut snapshot = registry_snapshot("claude");
        snapshot.registry.insert(
            "p".into(),
            agent::Record {
                sid: String::new(),
                word: "working".into(),
                since: 99,
            },
        );
        registry_at_with(&mut snapshot, &f.0, |_, _, _| {
            panic!("native program status is already authoritative")
        });
        assert_eq!(snapshot.registry["p"].word, "working");
        snapshot.registry.clear();
        snapshot.panes[0].cmd = "codex".into();
        registry_at_with(&mut snapshot, &f.0, |_, _, _| {
            panic!("Codex must not read Claude state")
        });
        assert!(snapshot.registry.is_empty());
        snapshot.panes[0].cmd = "claude".into();
        snapshot.pane_metadata.get_mut("p").unwrap().local = false;
        registry_at_with(&mut snapshot, &f.0, |_, _, _| {
            panic!("remote paths and processes are not local identity")
        });
        assert!(snapshot.registry.is_empty());
    }
    #[test]
    fn tmux_registry_requires_exact_native_pane_membership_and_live_process_identity() {
        let f = RegistryFixture::new();
        let mut record = registry_record(333);
        record["tmux"] = serde_json::json!("session:@0.%5");
        f.write(333, &record);
        let mut snapshot = registry_snapshot("claude");
        snapshot.panes[0].pid = 444;
        snapshot.panes[0].target = Target::TmuxNative {
            session_id: "$1".into(),
            window_id: Some("@0".into()),
            pane_id: Some("%5".into()),
        };
        registry_at_with(&mut snapshot, &f.0, |pid, _, pane| {
            pid == 333 && pane == 444
        });
        assert_eq!(snapshot.registry["p"].word, "approve");
        snapshot.registry.clear();
        record["tmux"] = serde_json::json!("other:@0.%6");
        f.write(333, &record);
        registry_at_with(&mut snapshot, &f.0, |_, _, _| {
            panic!("different tmux pane must not be accepted")
        });
        assert!(snapshot.registry.is_empty());
    }
    #[test]
    #[cfg(unix)]
    fn rex_registry_does_not_need_directory_enumeration_or_open_key_files() {
        use std::os::unix::fs::PermissionsExt;
        let f = RegistryFixture::new();
        f.write(111, &registry_record(111));
        let key = f.0.join("111.secret.key");
        assert!(std::process::Command::new("mkfifo")
            .arg(&key)
            .status()
            .unwrap()
            .success());
        fs::set_permissions(&f.0, fs::Permissions::from_mode(0o111)).unwrap();
        let mut snapshot = registry_snapshot("claude");
        registry_at_with(&mut snapshot, &f.0, |_, _, _| true);
        fs::set_permissions(&f.0, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(snapshot.registry["p"].word, "approve");
    }
    #[test]
    #[cfg(target_os = "linux")]
    fn linux_foreground_identity_requires_the_actual_process_start_time() {
        let pid = std::process::id();
        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).unwrap();
        let start = stat
            .rsplit_once(')')
            .unwrap()
            .1
            .split_whitespace()
            .nth(19)
            .unwrap();
        assert!(process_identity(pid, &Value::String(start.into()), pid));
        assert!(!process_identity(
            pid,
            &Value::String("not-the-start-time".into()),
            pid
        ));
    }
}
