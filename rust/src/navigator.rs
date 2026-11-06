//! One picker controller for every backend. fzf owns matching; Rust owns rows and targets.
use std::io::{self, IsTerminal, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};

use crate::model::{Row, Snapshot, Target};
use crate::rex::RexContext;
use crate::tmux_backend::{self, TmuxContext};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub(crate) enum Mode {
    #[default]
    Switch,
    Close,
    Rename,
    Zoom,
    Swap,
    Detach,
    Send,
    Directories,
    Schedule,
    Jobs,
    Health,
    Agents,
    Dashboard,
}
impl Mode {
    pub(crate) fn parse(value: &str) -> Result<Self, String> {
        Ok(match value {
            "" | "switch" => Self::Switch,
            "kill" | "close" => Self::Close,
            "rename" => Self::Rename,
            "zoom" => Self::Zoom,
            "swap" => Self::Swap,
            "detach" => Self::Detach,
            "send" => Self::Send,
            "dirs" | "directories" => Self::Directories,
            "schedule" => Self::Schedule,
            "jobs" => Self::Jobs,
            "doctor" | "health" => Self::Health,
            "agents" => Self::Agents,
            "dashboard" => Self::Dashboard,
            _ => return Err(format!("Unknown picker mode {value:?}")),
        })
    }
    pub(crate) fn operation(self) -> Option<&'static str> {
        match self {
            Self::Close => Some("close"),
            Self::Rename => Some("rename"),
            Self::Zoom => Some("zoom"),
            Self::Swap => Some("swap"),
            Self::Detach => Some("detach"),
            Self::Send => Some("send"),
            Self::Schedule => Some("schedule"),
            _ => None,
        }
    }
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Switch => "Switch",
            Self::Close => "Close",
            Self::Rename => "Rename",
            Self::Zoom => "Zoom",
            Self::Swap => "Swap",
            Self::Detach => "Detach",
            Self::Send => "Send",
            Self::Directories => "New session",
            Self::Schedule => "Schedule",
            Self::Jobs => "Jobs",
            Self::Health => "Health",
            Self::Agents => "Agents",
            Self::Dashboard => "Dashboard",
        }
    }
}

fn mode(args: &[String]) -> Result<Mode, String> {
    if let Some(pair) = args.windows(2).find(|a| a[0] == "--mode") {
        return Mode::parse(&pair[1]);
    }
    if crate::env_text("INTERDIMUX_VIEW") == "agents" {
        return Ok(Mode::Agents);
    }
    Mode::parse(&crate::env_text("INTERDIMUX_MODE"))
}

pub(crate) fn agent_states(args: &[String]) -> Result<Vec<String>, String> {
    let value = args
        .windows(2)
        .find(|a| a[0] == "--agent-states")
        .map(|a| a[1].as_str())
        .unwrap_or(crate::native_agents::DEFAULT_ATTENTION);
    crate::native_agents::states(value)
}

pub(crate) fn hide(snapshot: &mut Snapshot) {
    let patterns = crate::env_text("INTERDIMUX_HIDE");
    if patterns.trim().is_empty() {
        return;
    }
    snapshot.sessions.retain(|s| {
        s.key == snapshot.current.session_key
            || !patterns
                .split_whitespace()
                .any(|p| crate::startup::glob(p, &s.name))
    });
    let keys: std::collections::HashSet<_> =
        snapshot.sessions.iter().map(|s| s.key.as_str()).collect();
    snapshot
        .windows
        .retain(|w| keys.contains(w.session_key.as_str()));
    snapshot
        .panes
        .retain(|p| keys.contains(p.session_key.as_str()));
}

/// Keep filesystem/process enrichment and recent-directory discovery out of
/// resize, preview-layout and mode-change events. The controller replaces this
/// value whenever it accepts a new backend snapshot.
pub(crate) struct PreparedRows {
    presentation: crate::presentation::Prepared,
    directories: Vec<crate::projects::Directory>,
    directory_widths: (usize, usize),
    home: String,
    agents: Option<Vec<crate::native_agents::Agent>>,
}

impl PreparedRows {
    pub(crate) fn new(snapshot: &Snapshot) -> Self {
        let directories = crate::projects::cached_directories(snapshot);
        let home = crate::env_text("HOME");
        let mut directory_widths = (0, 0);
        for directory in directories.iter().filter(|d| d.existing_session.is_none()) {
            directory_widths.0 = directory_widths
                .0
                .max(4 + crate::text::width(&crate::native_agents::plain(&directory.label)));
            directory_widths.1 = directory_widths.1.max(crate::text::width(
                &crate::native_agents::plain(&crate::text::tildify(&directory.path, &home)),
            ));
        }
        Self {
            presentation: crate::presentation::Prepared::new(snapshot),
            directories,
            directory_widths,
            home,
            agents: None,
        }
    }

    pub(crate) fn rows(
        &mut self,
        snapshot: &Snapshot,
        width: usize,
        mode: Mode,
        states: &[String],
    ) -> Vec<Row> {
        let (mut rows, budgets) = self.presentation.rows_and_widths(width, self.directory_widths);
        append_directories(&mut rows, &self.directories, &self.home, budgets);
        if mode == Mode::Agents {
            let agents = self
                .agents
                .get_or_insert_with(|| crate::native_agents::collect(snapshot, states));
            for row in &mut rows {
                row.identity.truncate(row.identity.trim_end().len());
            }
            crate::native_agents::mark_rows(&mut rows, agents);
            for row in &mut rows {
                let identity = crate::text::truncate_ansi(&row.identity, budgets.0);
                row.identity =
                    crate::text::pad_to(&identity, crate::text::ansi_width(&identity), budgets.0);
            }
        }
        rows
    }
}

#[cfg(test)]
pub(crate) fn rows(snapshot: &Snapshot, width: usize, mode: Mode, states: &[String]) -> Vec<Row> {
    PreparedRows::new(snapshot).rows(snapshot, width, mode, states)
}

// Presentation fields already contain SGR colors and measured padding. Escape
// sequences occupy no cells; retain the padding while measuring visible text.
#[cfg(test)]
fn field_width(field: &str) -> usize {
    let mut plain = String::with_capacity(field.len());
    let mut chars = field.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            if chars.next() == Some('[') {
                for next in chars.by_ref() {
                    if ('@'..='~').contains(&next) {
                        break;
                    }
                }
            }
        } else {
            plain.push(c);
        }
    }
    crate::text::width(&plain)
}

fn append_directories(
    rows: &mut Vec<Row>,
    directories: &[crate::projects::Directory],
    home: &str,
    budgets: (usize, usize, usize),
) {
    if directories.is_empty() {
        return;
    }
    let (identity_width, context_width, command_width) = budgets;
    let description = format!(
        "{}{}{}",
        crate::palette::NativeTheme::from_env().muted,
        crate::text::truncate("recent directory", command_width),
        crate::palette::RST,
    );
    for directory in directories {
        if directory.existing_session.is_some() {
            continue;
        }
        let identity = crate::text::truncate(
            &format!("  ⌁ {}", crate::native_agents::plain(&directory.label)),
            identity_width,
        );
        let path = crate::text::truncate_left(
            &crate::native_agents::plain(&crate::text::tildify(&directory.path, home)),
            context_width.saturating_sub(2),
        );
        let context = crate::text::truncate(&format!("│ {path}"), context_width);
        rows.push(Row {
            identity: crate::text::pad_to(&identity, crate::text::width(&identity), identity_width),
            context: crate::text::pad_to(&context, crate::text::width(&context), context_width),
            command: description.clone(),
            target: Target::Directory {
                path: directory.path.clone(),
            },
        });
    }
}

enum Backend {
    Tmux(TmuxContext),
    Rex(RexContext),
}

#[cfg(unix)]
impl crate::interactive::Adapter for Backend {
    fn live_snapshot(&self) -> Option<PathBuf> {
        if crate::env_text("INTERDIMUX_LIVE_REFRESH") == "off" {
            return None;
        }
        let Self::Rex(ctx) = self else { return None };
        let path = ctx.snapshot_file.as_ref()?;
        let marker = std::fs::read(path.parent()?.join("live.json")).ok()?;
        let marker: serde_json::Value = serde_json::from_slice(&marker).ok()?;
        (marker["version"] == 1).then(|| path.clone())
    }
    fn workspace(&self) -> Option<PathBuf> {
        match self {
            Self::Rex(ctx) => ctx
                .result_file
                .as_ref()
                .and_then(|p| p.parent().map(|p| p.to_path_buf())),
            Self::Tmux(_) => None,
        }
    }
    fn cached(&self) -> Result<Snapshot, String> {
        self.collect()
    }
    fn refresh(&self) -> Result<Snapshot, String> {
        match self {
            Self::Tmux(ctx) => tmux_backend::collect(ctx),
            Self::Rex(ctx) => crate::rex::refresh(ctx),
        }
    }
    fn action(
        &self,
        operation: &str,
        target: Option<&Target>,
        args: &serde_json::Value,
    ) -> Result<serde_json::Value, String> {
        let result = match self {
            Self::Tmux(ctx) => crate::tmux_actions::action(ctx, operation, target, args),
            Self::Rex(ctx) => crate::rex::action(ctx, operation, target, args),
        };
        if operation != "health" {
            if let Err(error) = &result {
                crate::diagnostics::record(
                    &format!("{}/{}", self.backend_name(), operation),
                    error,
                );
            }
        }
        result
    }
    fn activate(&self, target: &Target) -> Result<(), String> {
        let result = Backend::activate(self, target);
        if let Err(error) = &result {
            crate::diagnostics::record(&format!("{}/activate", self.backend_name()), error);
        }
        result
    }
    fn backend_name(&self) -> &'static str {
        match self {
            Self::Tmux(_) => "tmux",
            Self::Rex(_) => "rex",
        }
    }
}

impl Backend {
    fn collect(&self) -> Result<Snapshot, String> {
        match self {
            Self::Tmux(ctx) => tmux_backend::collect(ctx),
            Self::Rex(ctx) => crate::rex::collect(ctx),
        }
    }
    fn activate(&self, target: &Target) -> Result<(), String> {
        match self {
            Self::Tmux(ctx) => tmux_backend::activate(ctx, target),
            Self::Rex(ctx) => crate::rex::activate(ctx, target),
        }
    }
    fn restore(&self) -> Result<(), String> {
        match self {
            Self::Tmux(_) => Ok(()),
            Self::Rex(ctx) => crate::rex::restore(ctx),
        }
    }
    fn disposable_terminal(&self) -> bool {
        match self {
            Self::Rex(ctx) => {
                ctx.result_file.is_some()
                    || ctx
                        .picker_block_id
                        .as_ref()
                        .map_or(false, |id| id != &ctx.block_id)
            }
            Self::Tmux(_) => false,
        }
    }
    fn report_error(&self, message: &str) {
        if let Self::Rex(ctx) = self {
            if let Err(error) = crate::rex::report_error(ctx, message) {
                eprintln!("imux: cannot report picker completion: {error}");
            }
        }
    }
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|s| !s.is_empty())
}

pub(crate) fn preview_enabled() -> bool {
    env("INTERDIMUX_PREVIEW")
        .or_else(|| env("INTERDIMUX_SHOW_PREVIEW"))
        .as_deref()
        == Some("on")
}

fn terminal_columns() -> Option<usize> {
    // Match fzf's real terminal size without launching a size-probing process.
    #[cfg(any(target_os = "macos", target_os = "linux", target_os = "freebsd"))]
    {
        #[repr(C)]
        struct Size {
            rows: u16,
            columns: u16,
            x: u16,
            y: u16,
        }
        extern "C" {
            fn ioctl(
                fd: std::os::raw::c_int,
                request: std::os::raw::c_ulong,
                ...
            ) -> std::os::raw::c_int;
        }
        #[cfg(any(target_os = "macos", target_os = "freebsd"))]
        let request = 0x4008_7468;
        #[cfg(target_os = "linux")]
        let request = 0x5413;
        let mut size = Size {
            rows: 0,
            columns: 0,
            x: 0,
            y: 0,
        };
        // SAFETY: TIOCGWINSZ writes a winsize (four u16 fields) to this pointer.
        if unsafe { ioctl(2, request, &mut size) } == 0 && size.columns > 0 {
            return Some(usize::from(size.columns));
        }
    }
    None
}

fn parse(args: &[String]) -> Result<Backend, String> {
    let mut backend = None;
    let mut client = None;
    let mut session = None;
    let mut window = None;
    let mut block = None;
    let mut picker = env("REX_BLOCK");
    let mut server = None;
    let mut socket = None;
    let mut origin_zoom = None;
    let mut snapshot_file = None;
    let mut result_file = None;
    let mut args = args.iter();
    while let Some(flag) = args.next() {
        let value = args
            .next()
            .ok_or_else(|| format!("{flag} needs a value"))?
            .clone();
        match flag.as_str() {
            "--backend" => backend = Some(value),
            "--client" => client = Some(value),
            "--session" => session = Some(value),
            "--window" => window = Some(value),
            "--block" => block = Some(value),
            "--picker-block" => picker = Some(value),
            "--server" => server = Some(value),
            "--socket" => socket = Some(value),
            "--origin-zoom" => origin_zoom = Some(value),
            "--snapshot" => snapshot_file = Some(PathBuf::from(value)),
            "--result" => result_file = Some(PathBuf::from(value)),
            "--mode" | "--agent-states" => {}
            _ => return Err(format!("unknown picker option: {flag}")),
        }
    }
    match backend.as_deref() {
        Some("tmux") => Ok(Backend::Tmux(TmuxContext {
            client: client.or_else(|| env("INTERDIMUX_CLIENT")),
            block: block.or_else(|| env("TMUX_PANE")),
            socket,
        })),
        Some("rex") => Ok(Backend::Rex(RexContext {
            server,
            client_id: client
                .or_else(|| env("REX_CLIENT"))
                .ok_or("Rex requires --client with the originating app's ID")?,
            session_id: session.ok_or("Rex requires --session with the origin session ID")?,
            window_id: window.ok_or("Rex requires --window with the origin window ID")?,
            block_id: block.ok_or("Rex requires --block with the origin pane ID")?,
            picker_block_id: picker,
            origin_zoomed_block_id: origin_zoom,
            snapshot_file,
            result_file,
        })),
        _ => Err("choose an explicit --backend tmux or --backend rex".into()),
    }
}

fn columns() -> usize {
    env("INTERDIMUX_COLS")
        .and_then(|s| s.parse().ok())
        .filter(|n| *n > 0)
        .or_else(terminal_columns)
        // The new float can have a different grid than the launching pane.
        // COLUMNS is only a fallback; fzf also prefers the real tty size.
        .or_else(|| {
            env("COLUMNS")
                .and_then(|s| s.parse().ok())
                .filter(|n| *n > 0)
        })
        .unwrap_or(80)
}

fn chooser_options(_snapshot: &Snapshot, keep_screen: bool) -> Vec<String> {
    let mut options: Vec<String> = [
        "--ansi", "--delimiter=\t", "--with-nth=1..3", "--nth=1..3", "--tabstop=1", "--tiebreak=index",
        "--layout=reverse", "--height=100%", "--no-multi", "--style=minimal",
        // Rows are already complete before fzf starts. Avoid an empty first
        // finder frame and keep one physical screen line per target.
        "--sync", "--border=none", "--padding=0", "--gap=0", "--no-wrap", "--no-hscroll",
        "--prompt=❯ ", "--ghost=Search sessions, windows and panes", "--info=inline-right",
        "--no-separator", "--highlight-line", "--pointer=▌", "--marker=●", "--scrollbar=│",
        "--footer=Enter switch · Esc close", "--footer-border=none",
        "--bind=ctrl-n:down,ctrl-p:up,tab:down,shift-tab:up,change:first",
    ].iter().map(|s| (*s).to_owned()).collect();
    options.push(crate::palette::NativeTheme::from_env().fzf_color());
    if keep_screen {
        // Only disposable Rex terminals retain fzf's final frame. An inline
        // tmux command must still restore the caller's terminal screen.
        options.push("--no-clear".into());
    }
    options
}

/// Parse configured argv without evaluating shell substitutions or commands.
pub(crate) fn fzf_options(value: &str) -> Result<(Vec<String>, Vec<String>), String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote = None;
    let mut escaped = false;
    let mut started = false;
    for c in value.chars() {
        if escaped {
            word.push(c);
            escaped = false;
            started = true;
            continue;
        }
        if c == '\\' && quote != Some('\'') {
            escaped = true;
            started = true;
            continue;
        }
        if let Some(q) = quote {
            if c == q {
                quote = None
            } else {
                word.push(c)
            }
            started = true;
            continue;
        }
        if c == '\'' || c == '"' {
            quote = Some(c);
            started = true
        } else if c.is_whitespace() {
            if started {
                words.push(std::mem::take(&mut word));
                started = false
            }
        } else {
            word.push(c);
            started = true
        }
    }
    if quote.is_some() || escaped {
        return Err("INTERDIMUX_FZF_OPTS has an unfinished quote or escape".into());
    }
    if started {
        words.push(word)
    }
    let mut accepted = Vec::new();
    let mut ignored = Vec::new();
    let mut iter = words.into_iter();
    while let Some(word) = iter.next() {
        let flag = word.split('=').next().unwrap_or("");
        if matches!(
            flag,
            "--filter"
                | "-f"
                | "--expect"
                | "--print-query"
                | "--accept-nth"
                | "--nth"
                | "--with-nth"
                | "--delimiter"
                | "--tabstop"
                | "-d"
                | "--read0"
                | "--print0"
                | "--multi"
                | "-m"
                | "--height"
                | "--min-height"
                | "--listen"
                | "--listen-unsafe"
                | "--walker"
                | "--preview"
                | "--preview-window"
                | "--layout"
                | "--no-clear"
                | "--clear"
        ) {
            let needs_value = matches!(
                flag,
                "--filter"
                    | "-f"
                    | "--expect"
                    | "--accept-nth"
                    | "--nth"
                    | "--with-nth"
                    | "--delimiter"
                    | "--tabstop"
                    | "-d"
                    | "--height"
                    | "--min-height"
                    | "--walker"
                    | "--preview"
                    | "--preview-window"
                    | "--layout"
            );
            if !word.contains('=') && needs_value {
                let _ = iter.next();
            }
            ignored.push(flag.into());
        } else {
            accepted.push(word)
        }
    }
    Ok((accepted, ignored))
}

fn write_rows(mut out: impl Write, rows: &[Row]) -> io::Result<()> {
    for (index, row) in rows.iter().enumerate() {
        writeln!(
            out,
            "{}\t{}\t{}\timux:{}",
            row.identity, row.context, row.command, index
        )?;
    }
    Ok(())
}

fn accepted_index(output: &[u8], row_count: usize) -> Result<Option<usize>, String> {
    let selected = std::str::from_utf8(output)
        .map_err(|_| "fzf returned invalid UTF-8")?
        .trim_end_matches(['\r', '\n']);
    if selected.is_empty() {
        return Ok(None);
    }
    let token = selected
        .rsplit_once('\t')
        .map(|(_, token)| token)
        .ok_or("fzf returned no target token")?;
    let index: usize = token
        .strip_prefix("imux:")
        .ok_or("fzf returned an invalid target token")?
        .parse()
        .map_err(|_| "fzf returned an invalid target index")?;
    if index >= row_count {
        return Err("fzf returned an unknown target".into());
    }
    Ok(Some(index))
}

fn choose(
    rows: &[Row],
    snapshot: Snapshot,
    prepared: PreparedRows,
    backend: &Backend,
    keep_screen: bool,
    mode: Mode,
    states: Vec<String>,
) -> Result<(Option<usize>, bool), String> {
    if rows.is_empty() {
        return Ok((None, false));
    }
    let fzf = env("INTERDIMUX_FZF_BIN").unwrap_or_else(|| "fzf".into());
    let mut command = Command::new(fzf);
    command
        .args(chooser_options(&snapshot, keep_screen))
        .args(fzf_options(&crate::env_text("INTERDIMUX_FZF_OPTS"))?.0)
        // Keep global user fzf callbacks from changing the switching-only contract.
        .env_remove("FZF_DEFAULT_OPTS")
        .env_remove("FZF_DEFAULT_OPTS_FILE")
        .env_remove("FZF_DEFAULT_COMMAND")
        .env_remove("FZF_CURRENT_ITEM")
        .env_remove("FZF_RAW")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    if keep_screen && std::env::var_os("ESCDELAY").is_none() {
        // Rex sends complete local key events; do not hold a lone Escape for
        // fzf's default 100 ms. Preserve an explicitly configured preference.
        command.env("ESCDELAY", "10");
    }
    #[cfg(unix)]
    let (output, final_done) = crate::interactive::run(
        backend,
        snapshot,
        prepared,
        rows,
        &mut command,
        columns(),
        mode,
        states,
    )?;
    #[cfg(not(unix))]
    let (output, final_done) = {
        let mut child = command
            .spawn()
            .map_err(|e| format!("cannot start fzf: {e}"))?;
        let input = child.stdin.take().ok_or("fzf has no input stream")?;
        // Drain selection output while feeding candidates: early acceptance of a
        // long row must not deadlock two full pipes on a large snapshot.
        let (output, written) = std::thread::scope(|scope| {
            let writer = scope.spawn(move || write_rows(input, rows));
            let output = child.wait_with_output().map_err(|e| format!("fzf: {e}"));
            let written = writer
                .join()
                .map_err(|_| "fzf input writer failed".to_owned())?;
            Ok::<_, String>((output?, written))
        })?;
        if let Err(e) = written {
            if e.kind() != io::ErrorKind::BrokenPipe {
                return Err(e.to_string());
            }
        }
        (output, false)
    };
    if final_done {
        return Ok((None, true));
    }
    match output.status.code() {
        Some(1 | 130) => Ok((None, false)),
        Some(0) => accepted_index(&output.stdout, rows.len()).map(|index| (index, false)),
        status => Err(format!("fzf failed with status {status:?}")),
    }
}

fn configure_theme(backend: &Backend) -> Result<(), String> {
    let configured = crate::env_text("INTERDIMUX_THEME");
    let resolved = match configured.as_str() {
        "" | "auto" => {
            if matches!(backend, Backend::Rex(_)) {
                "terminal"
            } else {
                "warm"
            }
        }
        "terminal" | "warm" => configured.as_str(),
        _ => return Err("INTERDIMUX_THEME must be auto, terminal or warm".into()),
    };
    // Resolve before starting workers. fzf's helper processes inherit this
    // choice, keeping every modal and preview on the initiating backend's theme.
    std::env::set_var("INTERDIMUX_THEME", resolved);
    Ok(())
}

pub(crate) fn run(args: &[String], list_only: bool) -> Result<(), String> {
    let backend = parse(args)?;
    configure_theme(&backend)?;
    let result = run_backend(&backend, list_only, mode(args)?, agent_states(args)?);
    if !list_only {
        if let Err(error) = &result {
            backend.report_error(error);
        }
    }
    result
}

/// Direct modes use the same IDs, ordering and state rules as the picker.
pub(crate) fn run_mode(verb: &str, args: &[String]) -> Result<(), String> {
    if verb == "doctor" && args.iter().any(|a| a == "--ack") {
        println!("Acknowledged {} error(s)", crate::diagnostics::ack()?);
        return Ok(());
    }
    let mut backend_args = Vec::new();
    let mut words = Vec::new();
    let mut count = false;
    let mut wanted = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--" => {
                words.extend(iter.cloned());
                break;
            }
            "--count" => count = true,
            "--states" | "--agent-states" => {
                wanted = Some(iter.next().ok_or("--states needs a value")?.clone())
            }
            flag if flag.starts_with("--") => {
                backend_args.push(arg.clone());
                backend_args.push(
                    iter.next()
                        .ok_or_else(|| format!("{arg} needs a value"))?
                        .clone(),
                );
            }
            _ => words.push(arg.clone()),
        }
    }
    let backend = parse(&backend_args)?;
    configure_theme(&backend)?;
    let result = (|| {
        let mut snapshot = match (&backend, verb) {
            (Backend::Rex(ctx), "jump") => crate::rex::collect_sessions(ctx)?,
            _ => backend.collect()?,
        };
        hide(&mut snapshot);
        match verb {
            "send-in" | "send-at" => {
                if words.len() < 3 {
                    return Err(format!("{verb} requires WHEN TARGET COMMAND"));
                }
                let when = if verb == "send-in" {
                    format!(
                        "{}s",
                        words[0]
                            .parse::<u64>()
                            .map_err(|_| "send-in requires nonnegative seconds")?
                    )
                } else {
                    words[0].clone()
                };
                if words[1] == "." && matches!(&backend,Backend::Tmux(ctx) if ctx.block.is_none()) {
                    return Err(
                        "Target '.' requires --block or TMUX_PANE from the invoking pane".into(),
                    );
                }
                let target = resolve_target(&snapshot, &words[1])?;
                #[cfg(unix)]
                {
                    let descriptor = crate::interactive::Adapter::action(
                        &backend,
                        "schedule-target",
                        Some(&target),
                        &serde_json::json!({}),
                    )?;
                    let record = crate::jobs::schedule(&descriptor, &when, &words[2..].join(" "))?;
                    println!(
                        "{}\t{}\t{}",
                        record["id"].as_str().unwrap_or(""),
                        record["when"].as_str().unwrap_or(""),
                        record["label"].as_str().unwrap_or("")
                    );
                }
                Ok(())
            }
            "agents" | "agent-next" => {
                let fallback = if verb == "agent-next" {
                    crate::native_agents::DEFAULT_ATTENTION
                } else {
                    ""
                };
                let wanted = crate::native_agents::states(
                    wanted
                        .as_deref()
                        .or_else(|| words.first().map(String::as_str))
                        .unwrap_or(fallback),
                )?;
                let agents = crate::native_agents::collect(&snapshot, &wanted);
                if verb == "agent-next" {
                    if let Some(next) =
                        crate::native_agents::next(&agents, &snapshot.current.pane_key)
                    {
                        backend.activate(&next.target)?;
                    } else {
                        eprintln!("interdimux: no agent needs you");
                        // A direct shortcut never changed focus. Only a hosted
                        // or separate picker terminal needs cancellation.
                        if backend.disposable_terminal() {
                            backend.restore()?;
                        }
                    }
                } else if count {
                    println!("{}", agents.len());
                } else {
                    for a in agents {
                        let target = match &a.target {
                            Target::TmuxNative {
                                pane_id: Some(id), ..
                            } => id.clone(),
                            Target::Rex {
                                session_id,
                                block_id: Some(id),
                                ..
                            } => format!("{session_id}/{id}"),
                            _ => a.location.clone(),
                        };
                        println!(
                            "{}\t{}\t{}\t{}\t{}\t{}",
                            crate::native_agents::plain(&a.key),
                            crate::native_agents::plain(&target),
                            a.name,
                            if a.state.is_empty() { "-" } else { &a.state },
                            if a.since > 0 {
                                a.since.to_string()
                            } else {
                                "-".into()
                            },
                            a.command
                        );
                    }
                }
                Ok(())
            }
            "jump" => {
                let number = words
                    .first()
                    .ok_or("jump requires a one-based session number")?
                    .parse::<usize>()
                    .map_err(|_| "jump requires a one-based session number")?;
                if number == 0 {
                    return Err("jump is one-based".into());
                }
                let mut sessions: Vec<_> = snapshot.sessions.iter().collect();
                if crate::env_text("INTERDIMUX_ORDER") != "index" {
                    sessions.sort_by(|a, b| b.last.cmp(&a.last));
                    if let Some(i) = sessions
                        .iter()
                        .position(|s| s.key == snapshot.current.session_key)
                    {
                        let current = sessions.remove(i);
                        sessions.push(current);
                    }
                }
                backend.activate(
                    &sessions
                        .get(number - 1)
                        .ok_or_else(|| format!("No session #{number}"))?
                        .target,
                )
            }
            "connect-dir" | "session-name-for" => {
                let query = words.first().ok_or("This mode requires a directory")?;
                if crate::projects::query_directory(query).is_none() {
                    return Err(format!("The directory does not exist: {query:?}"));
                }
                let resolved = crate::projects::resolve(&snapshot, query)?;
                if verb == "session-name-for" {
                    println!("{}", resolved.name);
                    return Ok(());
                }
                if let Some(target) = resolved.existing_session {
                    backend.activate(&target)?;
                } else {
                    #[cfg(unix)]
                    {
                        let mut args = serde_json::json!({"name":resolved.name,"cwd":resolved.cwd});
                        if crate::interactive::Adapter::backend_name(&backend) == "tmux"
                            || crate::interactive::Adapter::workspace(&backend).is_some()
                            || snapshot.pane_metadata.values().any(|m| m.local)
                        {
                            if let Some(plan) = crate::startup::plan(&resolved.cwd) {
                                args["startup_lines"] = serde_json::json!(plan.lines);
                            }
                        }
                        let data =
                            crate::interactive::Adapter::action(&backend, "create", None, &args)?;
                        backend.activate(&crate::interactive::decode_target(
                            data.get("target").unwrap_or(&data),
                            crate::interactive::Adapter::backend_name(&backend),
                        )?)?;
                    }
                }
                crate::projects::record_use(&resolved.cwd);
                Ok(())
            }
            "doctor" => {
                #[cfg(unix)]
                {
                    let lines = crate::interactive::health_report(&backend, &snapshot);
                    for line in &lines {
                        println!("{line}");
                    }
                    if lines.iter().any(|s| s.starts_with("ERROR")) {
                        return Err("Health checks found errors".into());
                    }
                }
                Ok(())
            }
            other => {
                let launch = if other == "launch" {
                    words.first().map(String::as_str).unwrap_or("switch")
                } else {
                    other
                };
                run_snapshot(
                    &backend,
                    snapshot,
                    false,
                    Mode::parse(launch)?,
                    crate::native_agents::states(
                        wanted.as_deref().unwrap_or(crate::native_agents::DEFAULT_ATTENTION),
                    )?,
                )
            }
        }
    })();
    if let Err(error) = &result {
        backend.report_error(error)
    }
    result
}

fn resolve_target(snapshot: &Snapshot, query: &str) -> Result<Target, String> {
    if query == "." {
        return snapshot
            .panes
            .iter()
            .find(|p| p.key == snapshot.current.pane_key)
            .map(|p| p.target.clone())
            .ok_or_else(|| {
                "The invoking pane no longer exists; provide an exact native pane ID".into()
            });
    }
    let mut candidates = Vec::new();
    for pane in &snapshot.panes {
        let native = match &pane.target {
            Target::Rex { block_id, .. } => block_id.as_deref(),
            Target::TmuxNative { pane_id, .. } => pane_id.as_deref(),
            _ => None,
        };
        if native == Some(query) || pane.key == query {
            candidates.push(pane.target.clone());
        }
    }
    for window in &snapshot.windows {
        if window.key == query {
            candidates.push(window.target.clone());
        }
    }
    for session in &snapshot.sessions {
        if session.key == query {
            candidates.push(session.target.clone());
        }
    }
    if candidates.is_empty() {
        for session in &snapshot.sessions {
            if session.name == query {
                candidates.push(session.target.clone());
            }
            for window in snapshot
                .windows
                .iter()
                .filter(|w| w.session_key == session.key)
            {
                if window.name == query
                    || format!("{}:{}", session.name, window.ordinal) == query
                    || format!("{}:{}", session.name, window.name) == query
                {
                    candidates.push(window.target.clone());
                }
                for pane in snapshot
                    .panes
                    .iter()
                    .filter(|p| p.session_key == session.key && p.window_key == window.key)
                {
                    if pane.name == query
                        || format!("{}:{}.{}", session.name, window.ordinal, pane.ordinal) == query
                        || (session.key == snapshot.current.session_key
                            && format!("{}.{}", window.ordinal, pane.ordinal) == query)
                    {
                        candidates.push(pane.target.clone());
                    }
                }
            }
        }
    }
    candidates.sort_by_key(|t| match t {
        Target::Rex { session_id, .. } | Target::TmuxNative { session_id, .. } => {
            usize::from(session_id != &snapshot.current.session_key)
        }
        _ => 0,
    });
    let mut identities = std::collections::HashSet::new();
    candidates.retain(|target| {
        let physical = match target {
            Target::TmuxNative {
                pane_id: Some(id), ..
            } => format!("pane:{id}"),
            _ => format!("{target:?}"),
        };
        identities.insert(physical)
    });
    match candidates.len() {
        0 => Err(format!("No target matches {query:?}")),
        1 => Ok(candidates.remove(0)),
        _ => Err(format!(
            "Target {query:?} is ambiguous; provide its exact native ID"
        )),
    }
}

fn run_backend(
    backend: &Backend,
    list_only: bool,
    mode: Mode,
    states: Vec<String>,
) -> Result<(), String> {
    run_snapshot(backend, backend.collect()?, list_only, mode, states)
}

fn run_snapshot(
    backend: &Backend,
    mut snapshot: Snapshot,
    list_only: bool,
    mut mode: Mode,
    states: Vec<String>,
) -> Result<(), String> {
    hide(&mut snapshot);
    if !list_only && mode == Mode::Dashboard {
        let attention = crate::native_agents::collect(&snapshot, &states);
        match crate::dashboard::choose(
            matches!(backend, Backend::Tmux(_)),
            attention.len(),
            backend.disposable_terminal(),
            columns(),
        )? {
            None => return backend.restore(),
            Some(crate::dashboard::Choice::Mode(selected)) => mode = selected,
            Some(crate::dashboard::Choice::NextAgent) => {
                return match crate::native_agents::next(&attention, &snapshot.current.pane_key) {
                    Some(next) => backend.activate(&next.target),
                    None => backend.restore(),
                };
            }
        }
    }
    let width = if preview_enabled() {
        columns().saturating_sub(1) / 2
    } else {
        columns()
    };
    let mut prepared = PreparedRows::new(&snapshot);
    let rows = prepared.rows(&snapshot, width.saturating_sub(3), mode, &states);
    if list_only {
        return write_rows(io::stdout().lock(), &rows).map_err(|e| e.to_string());
    }
    match choose(
        &rows,
        snapshot,
        prepared,
        backend,
        backend.disposable_terminal(),
        mode,
        states,
    ) {
        Ok((_, true)) => Ok(()),
        Ok((Some(index), false)) => backend.activate(&rows[index].target),
        Ok((None, false)) => backend.restore(),
        // Keep the error terminal focused until main's acknowledgement prompt.
        // Its normal close restores the previous layer afterward.
        Err(error) => Err(error),
    }
}

pub(crate) fn hold_error() {
    if io::stdin().is_terminal() {
        eprint!("Press Enter to close the picker. ");
        let _ = io::stderr().flush();
        let mut line = String::new();
        let _ = io::stdin().read_line(&mut line);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn directory_columns_align_to_visible_cells_without_counting_colors() {
        let target = Target::Directory {
            path: "/existing".into(),
        };
        let mut rows = vec![Row {
            identity: format!("\x1b[1;38;2;212;190;152m界🚀\x1b[0m{}", " ".repeat(14)),
            context: format!("\x1b[38;5;180m│ /work\x1b[0m{}", " ".repeat(17)),
            command: "shell".into(),
            target,
        }];
        assert_eq!(field_width(&rows[0].identity), 18);
        assert_eq!(field_width(&rows[0].context), 24);
        // Session rules span the name and path columns; they are not a name
        // column width, even after their colors have been stripped.
        rows.push(Row {
            identity: format!("\x1b[2msession {}\x1b[0m", "─".repeat(90)),
            context: "2 win".into(),
            command: String::new(),
            target: Target::Rex {
                session_id: "session:heading".into(),
                window_id: None,
                block_id: None,
            },
        });
        append_directories(
            &mut rows,
            &[crate::projects::Directory {
                path: "/home/me/project".into(),
                label: "project".into(),
                project: None,
                existing_session: None,
            }],
            "/home/me",
            (18, 24, 20),
        );
        assert_eq!(field_width(&rows[2].identity), 18);
        assert_eq!(field_width(&rows[2].context), 24);
        assert!(rows[2].context.starts_with("│ ~/project"));
        assert_eq!(
            rows[2].target,
            Target::Directory {
                path: "/home/me/project".into()
            }
        );
    }

    #[test]
    fn overflowing_labels_do_not_pad_recent_directories_beyond_the_viewport() {
        let mut rows = vec![Row {
            identity: "x".repeat(300),
            context: "y".repeat(250),
            command: "shell".into(),
            target: Target::Directory {
                path: "/old".into(),
            },
        }];
        append_directories(
            &mut rows,
            &[crate::projects::Directory {
                path: "/new".into(),
                label: "new".into(),
                project: None,
                existing_session: None,
            }],
            "",
            (18, 24, 20),
        );
        assert_eq!(field_width(&rows[1].identity), 18);
        assert_eq!(field_width(&rows[1].context), 24);
        assert_eq!(rows[0].identity.len(), 300);
    }

    #[test]
    fn recent_directory_columns_are_bounded_and_keep_the_path_tail_and_target() {
        let path = format!("/very/long/{}/leaf-界", "parent/".repeat(20));
        let mut rows = Vec::new();
        append_directories(
            &mut rows,
            &[crate::projects::Directory {
                path: path.clone(),
                label: "Long directory name 🚀".repeat(10),
                project: None,
                existing_session: None,
            }],
            "",
            (14, 18, 8),
        );
        assert_eq!(field_width(&rows[0].identity), 14);
        assert_eq!(field_width(&rows[0].context), 18);
        assert!(field_width(&rows[0].command) <= 8);
        assert!(rows[0].context.starts_with("│ …"));
        assert!(rows[0].context.trim_end().ends_with("leaf-界"));
        assert_eq!(rows[0].target, Target::Directory { path });
    }

    #[test]
    fn backend_selection_is_explicit_even_when_nested() {
        assert!(parse(&[]).is_err());
        assert!(parse(&["--backend".into(), "rex".into()]).is_err());
        assert!(matches!(
            parse(&["--backend".into(), "tmux".into()]).unwrap(),
            Backend::Tmux(_)
        ));
    }
    #[test]
    fn selection_uses_hidden_token_not_duplicate_labels() {
        assert_eq!(
            accepted_index(b"same\tcontext\tshell\timux:1\n", 2).unwrap(),
            Some(1)
        );
        assert!(accepted_index(b"same\tcontext\tshell\timux:2\n", 2).is_err());
        assert!(accepted_index(b"same\tcontext\tshell\t1\n", 2).is_err());
        assert_eq!(accepted_index(b"", 2).unwrap(), None);
    }
}
