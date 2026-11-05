//! Backend-neutral navigation records. Keys group records; labels never select targets.

use crate::agent;
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum Target {
    TmuxLegacy {
        spec: String,
    },
    TmuxNative {
        session_id: String,
        window_id: Option<String>,
        pane_id: Option<String>,
    },
    Rex {
        session_id: String,
        window_id: Option<String>,
        block_id: Option<String>,
    },
    Directory {
        path: String,
    },
}

#[derive(Default)]
pub(crate) struct Snapshot {
    pub sessions: Vec<Session>,
    pub windows: Vec<Window>,
    pub panes: Vec<Pane>,
    pub current: Current,
    pub registry: agent::Registry,
    /// Optional facts supplied by the backend, keyed by the pane's grouping key.
    pub pane_metadata: HashMap<String, PaneMetadata>,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct PaneMetadata {
    /// This pane sees the same process and filesystem namespace as this core.
    pub local: bool,
    /// The terminal's own home, including for a remote pane.
    pub home: String,
    /// An authoritative display command; it is never evaluated as shell code.
    pub command_line: String,
    /// Some("") means the backend already knows there is no branch.
    pub git_branch: Option<String>,
    /// An explicit foreground program report, rather than a heuristic OSC title.
    pub reported_title: bool,
    /// A conversation/task title owned by the current foreground process.
    pub current_title: bool,
    /// A verified explicit program title, used if the OSC title is generic.
    pub alternate_title: Option<String>,
    /// Native status verified against the terminal's current foreground owner.
    pub program_status: Option<ProgramStatus>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ProgramStatus {
    pub state: String,
    pub progress: Option<u8>,
    pub title: String,
    pub message: String,
    pub app: String,
    pub task_id: String,
    pub since: i64,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct Current {
    pub session_key: String,
    pub window_key: String,
    pub pane_key: String,
    pub host: String,
    pub host_short: String,
}

#[derive(Debug, Clone)]
pub(crate) struct Session {
    pub key: String,
    pub name: String,
    pub window_count: String,
    pub attached: bool,
    pub last: i64,
    pub path: String,
    pub target: Target,
}

#[derive(Debug, Clone)]
pub(crate) struct Window {
    pub key: String,
    pub session_key: String,
    pub ordinal: String,
    pub name: String,
    pub active: bool,
    pub cmd: String,
    pub path: String,
    pub pane_count: usize,
    pub pid: u32,
    pub zoomed: bool,
    pub bell: bool,
    pub activity: bool,
    pub target: Target,
}

#[derive(Debug, Clone)]
pub(crate) struct Pane {
    pub key: String,
    pub session_key: String,
    pub window_key: String,
    pub ordinal: String,
    /// The backend's human label, independent of its running process.
    pub name: String,
    pub active: bool,
    pub cmd: String,
    pub path: String,
    pub pid: u32,
    pub agent_id: String,
    pub title: String,
    pub opts: String,
    pub target: Target,
}

#[derive(Debug, Clone)]
pub(crate) struct Row {
    pub identity: String,
    pub context: String,
    pub command: String,
    pub target: Target,
}
