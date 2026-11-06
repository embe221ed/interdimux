//! Experimental, UI-neutral JSON-lines service for the native macOS picker.
//!
//! Only open/refresh collect Rex state. Queries use one persistent, two-thread
//! matcher and full metadata, independent of terminal rendering or fzf. Fixture
//! mode is deliberately incapable of activating anything on a real server.

use crate::model::{Snapshot, Target};
use crate::rex::{self, RexContext};
use nucleo::pattern::{CaseMatching, Normalization};
use nucleo::{Config, Nucleo};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

#[path = "mac_picker_actions.rs"]
mod actions;
#[path = "mac_picker_dashboard.rs"]
mod dashboard;
#[path = "mac_picker_directories.rs"]
mod directories;

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum SearchField {
    #[default]
    All,
    Name,
    Path,
    Command,
}

impl SearchField {
    fn requested(request: &Value, current: Self) -> Result<Self, String> {
        request
            .get("search_field")
            .map(|value| {
                value
                    .as_str()
                    .ok_or_else(|| "search_field must be a string".to_owned())
                    .and_then(Self::parse)
            })
            .transpose()
            .map(|field| field.unwrap_or(current))
    }
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "all" => Ok(Self::All),
            "name" => Ok(Self::Name),
            "path" => Ok(Self::Path),
            "command" => Ok(Self::Command),
            _ => Err("search_field must be all, name, path, or command".into()),
        }
    }
    fn column(self) -> usize {
        self as usize
    }
    fn label(self) -> &'static str {
        ["all", "name", "path", "command"][self.column()]
    }
}

const MAX_ROWS: usize = 100;
const MAX_REQUEST: usize = 64 * 1024;
const MAX_QUERY: usize = 4096;
const DISCOVER_CLIENTS: &str = r#"
local identity, identity_error = rex.call('server.whoami', {})
if not identity then error(identity_error, 0) end
local peer = identity.principal
-- run_script supplies the actual child identity. A forwarded Unix principal
-- alone does not prove that this companion and the app are on the same Mac.
if not peer or peer.kind ~= 'peer' or peer.transport ~= 'unix'
    or peer.pid ~= imux_collector_pid or peer.uid ~= imux_collector_uid
    or (peer.path ~= nil and (type(peer.path) ~= 'table' or next(peer.path) ~= nil)) then
  error('The native picker currently requires a direct local Rex server', 0)
end
local result, err = rex.call('client.list', { kinds = { 'app' } })
if not result then error(err, 0) end
return result
"#;

#[derive(Clone, Debug, Default)]
struct Candidate {
    id: String,
    parent_id: Option<String>,
    kind: String,
    title: String,
    name: String,
    subtitle: String,
    detail: String,
    path: String,
    current: bool,
    search: String,
    name_search: String,
    command_search: String,
    target: Option<Target>,
    pane_target: Option<Target>,
    pane_id: Option<String>,
    combined: bool,
    agent_state: Option<String>,
    agent_name: Option<String>,
    operations: Vec<&'static str>,
    // Keep the warm main-list recents independent of explicit project browsing.
    main_recent: bool,
    directory_visible: bool,
}

impl Candidate {
    fn attention(&self) -> bool {
        matches!(self.agent_state.as_deref(), Some("approve" | "input"))
    }

    fn in_scope(&self, scope: &str) -> bool {
        (scope == "all" && (self.kind != "directory" || self.main_recent))
            || (scope == self.kind && (self.kind != "directory" || self.directory_visible))
            || (scope == "pane" && self.combined)
            || (scope == "attention" && self.attention())
    }

    fn activation_target(&self) -> Option<&Target> {
        self.pane_target.as_ref().or(self.target.as_ref())
    }

    fn action_selection(&self) -> Option<actions::ActionSelection> {
        Some(actions::ActionSelection {
            target: self.target.clone()?,
            pane_target: self.pane_target.clone(),
            title: self.title.clone(),
            name: self.name.clone(),
            path: self.path.clone(),
        })
    }

    fn available_operations(&self) -> Vec<&'static str> {
        if self.kind == "directory" {
            return vec!["preview"];
        }
        // Fixture menus exercise the same capability rules, but these synthetic
        // identities never enter activation or dispatch: fixture requests are
        // rejected before resolving any action selection.
        let target = self.target.clone().unwrap_or_else(|| Target::Rex {
            session_id: if self.kind == "session" {
                self.id.clone()
            } else {
                "fixture:session".into()
            },
            window_id: match self.kind.as_str() {
                "window" => Some(self.id.clone()),
                "pane" => Some(
                    self.parent_id
                        .clone()
                        .unwrap_or_else(|| "fixture:window".into()),
                ),
                _ => None,
            },
            block_id: (self.kind == "pane").then(|| self.id.clone()),
        });
        let mut pane_target = self.pane_target.clone();
        if self.target.is_none() && self.combined {
            if let Target::Rex {
                session_id,
                window_id,
                ..
            } = &target
            {
                pane_target = self.pane_id.as_ref().map(|id| Target::Rex {
                    session_id: session_id.clone(),
                    window_id: window_id.clone(),
                    block_id: Some(id.clone()),
                });
            }
        }
        actions::available(&actions::ActionSelection {
            target,
            pane_target,
            title: String::new(),
            name: String::new(),
            path: String::new(),
        })
    }

    fn value(&self, context_only: bool) -> Value {
        let operations = if context_only {
            &[][..]
        } else {
            self.operations.as_slice()
        };
        json!({"id":self.id,"kind":self.kind,"title":self.title,"name":self.name,
            "subtitle":self.subtitle,"path":self.path,"current":self.current,
            "parent_id":self.parent_id,"context_only":context_only,
            "pane_id":self.pane_id,"combined":self.combined,"detail":self.detail,
            "agent_state":self.agent_state,"agent_name":self.agent_name,"attention":self.attention(),
            "actions":operations})
    }
}

#[derive(Default)]
struct Hierarchy {
    parents: Vec<Option<usize>>,
    children: Vec<Vec<usize>>,
    roots: Vec<usize>,
    preorder: Vec<usize>,
}

impl Hierarchy {
    fn build(rows: &[Candidate], ids: &HashMap<String, usize>) -> Result<Self, String> {
        let mut tree = Self {
            parents: vec![None; rows.len()],
            children: vec![Vec::new(); rows.len()],
            roots: Vec::new(),
            preorder: Vec::with_capacity(rows.len()),
        };
        for (index, row) in rows.iter().enumerate() {
            if let Some(parent_id) = &row.parent_id {
                let parent = *ids
                    .get(parent_id)
                    .ok_or_else(|| format!("Picker parent {parent_id} does not exist"))?;
                tree.parents[index] = Some(parent);
                tree.children[parent].push(index);
            } else {
                tree.roots.push(index);
            }
        }
        // Validate before traversing; fixtures must never create a cycle or a
        // deep recursive walk. Missing parent_id retains the legacy flat form.
        let mut states = vec![0u8; rows.len()];
        let mut path = Vec::new();
        for start in 0..rows.len() {
            path.clear();
            let mut next = Some(start);
            while let Some(index) = next {
                match states[index] {
                    1 => return Err("Picker parent relationships contain a cycle".into()),
                    2 => break,
                    _ => {}
                }
                states[index] = 1;
                path.push(index);
                next = tree.parents[index];
            }
            for &index in &path {
                states[index] = 2;
            }
        }
        for (index, parent) in tree.parents.iter().enumerate() {
            if let Some(parent) = parent {
                if !matches!(
                    (rows[*parent].kind.as_str(), rows[index].kind.as_str()),
                    ("session", "window") | ("window", "pane")
                ) {
                    return Err("Picker parents must follow session → window → pane".into());
                }
            }
        }
        let mut stack: Vec<usize> = tree.roots.iter().rev().copied().collect();
        while let Some(index) = stack.pop() {
            tree.preorder.push(index);
            stack.extend(tree.children[index].iter().rev().copied());
        }
        Ok(tree)
    }
}

struct Picker {
    fixture: Option<PathBuf>,
    defaults: RexContext,
    context: Option<RexContext>,
    snapshot: Option<Snapshot>,
    rows: Vec<Candidate>,
    by_id: HashMap<String, usize>,
    hierarchy: Hierarchy,
    attention_count: usize,
    directories: directories::Browser,
    matcher: Nucleo<usize>,
    matcher_query: String,
    matcher_field: SearchField,
    search_field: SearchField,
    query: String,
    scope: String,
    opened: bool,
    allow_create: bool,
    create_generation: u64,
    pending_create: Option<(String, String)>,
    open_timing_ms: Value,
    dashboard: Value,
    terminal_tools_available: bool,
    action_filter: String,
}

fn empty_context() -> RexContext {
    RexContext {
        server: None,
        client_id: String::new(),
        session_id: String::new(),
        window_id: String::new(),
        block_id: String::new(),
        picker_block_id: None,
        origin_zoomed_block_id: None,
        snapshot_file: None,
        result_file: None,
    }
}

impl Picker {
    fn new(fixture: Option<PathBuf>, defaults: RexContext) -> Self {
        Self {
            fixture,
            defaults,
            context: None,
            snapshot: None,
            rows: Vec::new(),
            by_id: HashMap::new(),
            hierarchy: Hierarchy::default(),
            attention_count: 0,
            directories: directories::Browser::default(),
            matcher: Nucleo::new(Config::DEFAULT, Arc::new(|| {}), Some(2), 4),
            matcher_query: String::new(),
            matcher_field: SearchField::All,
            search_field: SearchField::All,
            query: String::new(),
            scope: "all".into(),
            opened: false,
            allow_create: true,
            create_generation: 0,
            pending_create: None,
            open_timing_ms: json!({}),
            dashboard: dashboard::counts(&[], 0),
            terminal_tools_available: false,
            action_filter: String::new(),
        }
    }

    fn replace(&mut self, mut rows: Vec<Candidate>) -> Result<(), String> {
        rows.sort_by_key(|row| row.kind == "directory");
        let mut ids = HashMap::with_capacity(rows.len());
        for (index, row) in rows.iter().enumerate() {
            if row.id.is_empty() || ids.insert(row.id.clone(), index).is_some() {
                return Err("Picker records must have distinct, nonempty IDs".into());
            }
        }
        let hierarchy = Hierarchy::build(&rows, &ids)?;
        let mut rows = collapse_single_panes(rows, &hierarchy);
        for row in &mut rows {
            row.operations = row.available_operations();
        }
        let ids: HashMap<_, _> = rows
            .iter()
            .enumerate()
            .map(|(i, row)| (row.id.clone(), i))
            .collect();
        let hierarchy = Hierarchy::build(&rows, &ids)?;
        let attention_count = rows
            .iter()
            .filter(|row| row.attention())
            .filter_map(|row| row.pane_id.as_deref())
            .collect::<HashSet<_>>()
            .len();
        self.matcher.restart(true);
        let injector = self.matcher.injector();
        for (index, row) in rows.iter().enumerate() {
            injector.push(index, |_, columns| {
                columns[0] = row.search.as_str().into();
                columns[1] = row.name_search.as_str().into();
                columns[2] = row.path.as_str().into();
                columns[3] = row.command_search.as_str().into();
            });
        }
        self.rows = rows;
        self.by_id = ids;
        self.hierarchy = hierarchy;
        self.attention_count = attention_count;
        self.dashboard = dashboard::counts(&self.rows, attention_count);
        Ok(())
    }

    fn open(&mut self, request: &Value) -> Result<(), String> {
        let started = Instant::now();
        // A failed reopen must not leave activation pointed at the previous
        // app client, even if its old rows remain visible in the frontend.
        self.opened = false;
        self.context = None;
        self.snapshot = None;
        self.query.clear();
        self.scope = "all".into();
        self.search_field = SearchField::All;
        self.action_filter.clear();
        self.directories = directories::Browser::default();
        self.allow_create = true;
        self.pending_create = None;
        self.open_timing_ms = json!({});
        self.terminal_tools_available = false;
        if let Some(path) = &self.fixture {
            let rows = read_fixture(path)?;
            self.directories.fixture_catalog = rows
                .iter()
                .filter(|row| row.kind == "directory")
                .cloned()
                .collect();
            let index_started = Instant::now();
            self.replace(rows)?;
            self.open_timing_ms["index"] = json!(millis(index_started));
        } else {
            let mut context = self.defaults.clone();
            if let Some(value) = request.get("context") {
                if !value.is_object() {
                    return Err("open.context must be an object".into());
                }
                for (key, dest) in [
                    ("client_id", &mut context.client_id),
                    ("session_id", &mut context.session_id),
                    ("window_id", &mut context.window_id),
                    ("block_id", &mut context.block_id),
                ] {
                    if let Some(value) = value.get(key) {
                        *dest = value.as_str().ok_or("Context IDs must be strings")?.into();
                    }
                }
            }
            let collect_started = Instant::now();
            let (clients, snapshot) = rex::collect_native(&context, DISCOVER_CLIENTS)?;
            context.client_id = choose_client(&clients, &context.client_id)?;
            self.open_timing_ms["client_snapshot"] = json!(millis(collect_started));
            let mut rows = snapshot_rows_timed(&snapshot, &mut self.open_timing_ms);
            let projects_started = Instant::now();
            let mut recent =
                directories::candidates(crate::projects::cached_directories(&snapshot));
            for row in &mut recent {
                row.main_recent = true;
            }
            rows.extend(recent);
            self.open_timing_ms["projects"] = json!(millis(projects_started));
            let index_started = Instant::now();
            self.replace(rows)?;
            self.open_timing_ms["index"] = json!(millis(index_started));
            self.snapshot = Some(snapshot);
            self.context = Some(context);
            self.update_terminal_tools();
        }
        self.opened = true;
        self.open_timing_ms["total"] = json!(millis(started));
        Ok(())
    }

    fn refresh(&mut self) -> Result<(), String> {
        if let Some(path) = &self.fixture {
            let rows = read_fixture(path)?;
            let catalog = rows
                .iter()
                .filter(|row| row.kind == "directory")
                .cloned()
                .collect();
            self.replace(rows)?;
            self.directories.fixture_catalog = catalog;
        } else {
            let snapshot = rex::collect(self.context.as_ref().ok_or("Open the picker first")?)?;
            let mut rows = snapshot_rows(&snapshot);
            rows.extend(
                self.rows
                    .iter()
                    .filter(|row| row.kind == "directory")
                    .cloned(),
            );
            self.replace(rows)?;
            self.snapshot = Some(snapshot);
            self.update_terminal_tools();
        }
        Ok(())
    }

    fn update_terminal_tools(&mut self) {
        self.terminal_tools_available = self
            .context
            .as_ref()
            .zip(self.snapshot.as_ref())
            .is_some_and(|(context, snapshot)| dashboard::origin(context, snapshot).is_ok());
    }

    fn results(&mut self, id: u64, started: Instant) -> Result<Value, String> {
        self.pending_create = None;
        // Scope-only changes and repeated queries reuse the completed match.
        // Appended input can narrow prior results; deletions/replacements must
        // rescore all candidates or previously excluded rows would disappear.
        if self.query != self.matcher_query || self.search_field != self.matcher_field {
            if self.search_field != self.matcher_field {
                self.matcher.pattern.reparse(
                    self.matcher_field.column(),
                    "",
                    CaseMatching::Smart,
                    Normalization::Smart,
                    false,
                );
            }
            self.matcher.pattern.reparse(
                self.search_field.column(),
                &self.query,
                CaseMatching::Smart,
                Normalization::Smart,
                self.search_field == self.matcher_field
                    && self.query.starts_with(&self.matcher_query),
            );
            self.matcher_query.clone_from(&self.query);
            self.matcher_field = self.search_field;
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.matcher.tick(5).running {
            if Instant::now() > deadline {
                return Err("Matching timed out; shorten the query".into());
            }
        }
        let in_scope = |row: &&Candidate| {
            row.in_scope(&self.scope)
                && (self.action_filter.is_empty()
                    || row.operations.contains(&self.action_filter.as_str()))
        };
        let total = self.rows.iter().filter(in_scope).count();
        let mut ranked = Vec::with_capacity(self.matcher.snapshot().matched_item_count() as usize);
        let mut projects = Vec::new();
        let mut ranks = vec![usize::MAX; self.rows.len()];
        for item in self.matcher.snapshot().matched_items(..) {
            let index = *item.data;
            let row = &self.rows[index];
            if in_scope(&row) {
                if row.kind == "directory" {
                    projects.push(index);
                } else {
                    ranked.push(index);
                }
            }
        }
        // A project is a useful fallback, but Enter should keep selecting a
        // matching live target even when its fuzzy score is slightly lower.
        ranked.extend(projects);
        for (rank, &index) in ranked.iter().enumerate() {
            ranks[index] = rank;
        }
        let matched = ranked.len();
        // An empty query preserves MRU sessions and original tab/pane order,
        // even when the source lists all tabs before listing any panes.
        let empty_query = self.matcher.snapshot().pattern().is_empty();
        let order = if empty_query {
            &self.hierarchy.preorder
        } else {
            &ranked
        };
        let mut included = vec![false; self.rows.len()];
        let mut remaining = MAX_ROWS;
        let mut chain = Vec::with_capacity(3);
        for &index in order {
            if ranks[index] == usize::MAX {
                continue;
            }
            chain.clear();
            let mut next = Some(index);
            while let Some(index) = next {
                if included[index] {
                    break;
                }
                chain.push(index);
                next = self.hierarchy.parents[index];
            }
            if chain.len() <= remaining {
                remaining -= chain.len();
                for &index in &chain {
                    included[index] = true;
                }
            }
            if remaining == 0 {
                break;
            }
        }
        let mut preferred_id = order
            .iter()
            .copied()
            .find(|&index| included[index] && ranks[index] != usize::MAX)
            .map(|index| self.rows[index].id.clone());
        // Rank a group by its best descendant match. Sorting only the included
        // siblings keeps response work bounded while preserving contiguous trees.
        let mut best = ranks.clone();
        for &index in self.hierarchy.preorder.iter().rev() {
            if let Some(parent) = self.hierarchy.parents[index] {
                best[parent] = best[parent].min(best[index]);
            }
        }
        let siblings = |indices: &[usize]| {
            let mut indices: Vec<usize> =
                indices.iter().copied().filter(|&i| included[i]).collect();
            if !empty_query {
                indices.sort_by_key(|&i| best[i]);
            }
            indices.reverse();
            indices
        };
        let mut stack = siblings(&self.hierarchy.roots);
        let mut rows = Vec::with_capacity(MAX_ROWS - remaining);
        let mut shown_matches = 0;
        while let Some(index) = stack.pop() {
            let context_only = ranks[index] == usize::MAX;
            if !context_only {
                shown_matches += 1;
            }
            rows.push(self.rows[index].value(context_only));
            stack.extend(siblings(&self.hierarchy.children[index]));
        }
        if matched == 0
            && self.allow_create
            && self.scope == "all"
            && self.action_filter.is_empty()
            && matches!(self.search_field, SearchField::All | SearchField::Name)
        {
            if let Some(label) = creation_label(&self.query) {
                self.create_generation = self
                    .create_generation
                    .checked_add(1)
                    .ok_or("Restart the picker before creating a session")?;
                let target_id = format!("create:{}", self.create_generation);
                rows.push(
                    Candidate {
                        id: target_id.clone(),
                        kind: "create".into(),
                        title: format!("Create “{label}”"),
                        name: label,
                        detail: "New session · Enter to create or reuse this project".into(),
                        ..Candidate::default()
                    }
                    .value(false),
                );
                preferred_id = Some(target_id.clone());
                self.pending_create = Some((target_id, self.query.clone()));
            }
        }
        let mut dashboard = self.dashboard.clone();
        dashboard["terminal_tools_available"] = json!(self.terminal_tools_available);
        Ok(json!({"id":id,"type":"results","rows":rows,"total":total,
            "matched":matched,"shown_matches":shown_matches,"preferred_id":preferred_id,
            "attention_count":self.attention_count,
            "query":self.query,"scope":self.scope,"search_field":self.search_field.label(),
            "action_filter":self.action_filter,
            "directories_base":self.directories.base,"directories_loaded":self.directories.loaded,
            "directories_deep":self.directories.deep,
            "can_create":self.pending_create.is_some(),"open_timing_ms":self.open_timing_ms,
            "dashboard":dashboard,
            "elapsed_ms":started.elapsed().as_secs_f64()*1000.0}))
    }

    fn request(&mut self, request: &Value) -> Value {
        let id = request["id"].as_u64();
        let result = id
            .ok_or_else(|| "Request id must be an unsigned integer".into())
            .and_then(|id| self.handle(id, request));
        result.unwrap_or_else(|message: String| json!({"id":id,"type":"error","message":message}))
    }

    fn action_selection(
        &self,
        id: Option<&Value>,
    ) -> Result<Option<actions::ActionSelection>, String> {
        let id = match id {
            None | Some(Value::Null) => return Ok(None),
            Some(Value::String(id)) => id,
            _ => return Err("Action target IDs must be strings".into()),
        };
        self.by_id
            .get(id)
            .and_then(|&index| self.rows[index].action_selection())
            .map(Some)
            .ok_or_else(|| "The selected target is no longer available; refresh the picker".into())
    }

    fn handle(&mut self, id: u64, request: &Value) -> Result<Value, String> {
        let started = Instant::now();
        let operation = request["type"]
            .as_str()
            .ok_or("Request type must be a string")?;
        if operation == "open" {
            self.open(request)?;
            return self.results(id, started);
        }
        if !self.opened {
            return Err("Open the picker first".into());
        }
        if matches!(
            operation,
            "query" | "refresh" | "directories" | "action" | "dashboard_action"
        ) {
            // Even a rejected new query invalidates the prior create choice.
            self.pending_create = None;
        }
        match operation {
            "dashboard_action" => {
                if self.fixture.is_some() {
                    return Err("Fixture mode never performs Rex dashboard actions".into());
                }
                let operation = request["operation"]
                    .as_str()
                    .ok_or("Choose a dashboard action")?;
                let mut response = dashboard::run(
                    self.context.as_ref().ok_or("Open the picker first")?,
                    self.snapshot.as_ref().ok_or("Refresh the picker first")?,
                    operation,
                )?;
                let response_object = response
                    .as_object_mut()
                    .ok_or("Invalid dashboard response")?;
                response_object.insert("id".into(), json!(id));
                response_object.insert("type".into(), json!("action_done"));
                response_object.insert("operation".into(), json!(operation));
                Ok(response)
            }
            "query" => {
                let query = request["query"].as_str().ok_or("query must be a string")?;
                if query.len() > MAX_QUERY {
                    return Err("Query exceeds 4096 bytes".into());
                }
                let scope = match request.get("scope") {
                    Some(value) => value.as_str().ok_or("scope must be a string")?,
                    None => "all",
                };
                if !matches!(
                    scope,
                    "all" | "session" | "window" | "pane" | "attention" | "directory"
                ) {
                    return Err(
                        "scope must be all, session, window, pane, attention, or directory".into(),
                    );
                }
                let field = SearchField::requested(request, self.search_field)?;
                let action_filter = request
                    .get("action_filter")
                    .map(|value| value.as_str().ok_or("action_filter must be a string"))
                    .transpose()?
                    .unwrap_or("");
                if !matches!(
                    action_filter,
                    "" | "rename" | "close" | "swap" | "zoom" | "send"
                ) {
                    return Err(
                        "action_filter must be empty, rename, close, swap, zoom, or send".into(),
                    );
                }
                let allow_create = request
                    .get("allow_create")
                    .map(|value| value.as_bool().ok_or("allow_create must be a boolean"))
                    .transpose()?
                    .unwrap_or(true);
                self.query = query.into();
                self.scope = scope.into();
                self.search_field = field;
                self.allow_create = allow_create;
                self.action_filter = action_filter.into();
                self.results(id, started)
            }
            "refresh" => {
                self.refresh()?;
                self.results(id, started)
            }
            "directories" => {
                let field = SearchField::requested(request, self.search_field)?;
                let query = request
                    .get("query")
                    .map(|v| v.as_str().ok_or("query must be a string"))
                    .transpose()?
                    .unwrap_or(&self.query);
                if query.len() > MAX_QUERY {
                    return Err("Query exceeds 4096 bytes".into());
                }
                let query = query.to_owned();
                let (browser, entries) = self.directories.load(
                    self.snapshot.as_ref(),
                    &self.rows,
                    request,
                    &query,
                    self.fixture.is_some(),
                )?;
                let mut rows: Vec<_> = self
                    .rows
                    .iter()
                    .filter(|row| row.kind != "directory")
                    .cloned()
                    .collect();
                // Browsing/deep scans replace only the Projects view. Keep
                // cached recents available in All without exposing every scan
                // descendant there or losing roots after entering a child.
                let recents: HashMap<_, _> = self
                    .rows
                    .iter()
                    .filter(|row| row.kind == "directory" && row.main_recent)
                    .map(|row| (row.id.as_str(), row))
                    .collect();
                let mut entries = entries;
                let mut visible = HashSet::with_capacity(entries.len());
                for row in &mut entries {
                    visible.insert(row.id.clone());
                    row.directory_visible = true;
                    row.main_recent = recents.contains_key(row.id.as_str());
                }
                rows.extend(entries);
                rows.extend(
                    self.rows
                        .iter()
                        .filter(|row| {
                            row.kind == "directory" && row.main_recent && !visible.contains(&row.id)
                        })
                        .cloned()
                        .map(|mut row| {
                            row.directory_visible = false;
                            row
                        }),
                );
                self.replace(rows)?;
                self.directories = browser;
                self.scope = "directory".into();
                self.action_filter.clear();
                self.search_field = field;
                self.query = if request.get("query").is_none()
                    && (request["reset"] == true
                        || request["parent"] == true
                        || request.get("base_id").is_some())
                {
                    String::new()
                } else {
                    query
                };
                self.results(id, started)
            }
            "preview" => {
                let target_id = request["target_id"]
                    .as_str()
                    .ok_or("target_id must be a string")?;
                let lines = request
                    .get("lines")
                    .map(|v| {
                        v.as_u64()
                            .filter(|n| (1..=200).contains(n))
                            .ok_or("Preview lines must be between 1 and 200")
                    })
                    .transpose()?
                    .unwrap_or(80);
                let row = self
                    .by_id
                    .get(target_id)
                    .map(|&i| &self.rows[i])
                    .ok_or("The selected target is no longer available; refresh the picker")?;
                let text = if self.fixture.is_some() || row.kind == "directory" {
                    format!(
                        "{}\n{}\n{}\n{}",
                        row.title,
                        row.path,
                        row.detail,
                        if self.fixture.is_some() {
                            "Fixture preview — no Rex connection or filesystem reads"
                        } else {
                            "Enter opens or reuses a project session"
                        }
                    )
                } else {
                    let selected = row.action_selection().ok_or("Select a Rex target")?;
                    let data = actions::run(
                        self.context.as_ref().ok_or("Open the picker first")?,
                        self.snapshot.as_ref().ok_or("Refresh the picker first")?,
                        Some(&selected),
                        None,
                        &json!({"operation":"preview","lines":lines}),
                    )?;
                    data["text"]
                        .as_str()
                        .ok_or("No preview text was returned")?
                        .to_owned()
                };
                Ok(
                    json!({"id":id,"type":"preview","target_id":target_id,"text":text.lines().take(lines as usize).collect::<Vec<_>>().join("\n")}),
                )
            }
            "activate" => {
                let target_id = request["target_id"]
                    .as_str()
                    .ok_or("target_id must be a string")?;
                if let Some((pending_id, query)) = &self.pending_create {
                    if pending_id == target_id {
                        if self.fixture.is_some() {
                            return Err("Fixture mode never activates Rex targets".into());
                        }
                        let query = query.clone();
                        // Consume before dispatch: a repeated Enter cannot
                        // submit the same create choice a second time.
                        self.pending_create = None;
                        actions::run(
                            self.context.as_ref().ok_or("Open the picker first")?,
                            self.snapshot.as_ref().ok_or("Refresh the picker first")?,
                            None,
                            None,
                            &json!({"operation":"create-session","value":query}),
                        )?;
                        return Ok(json!({"id":id,"type":"activated"}));
                    }
                }
                let row = self
                    .by_id
                    .get(target_id)
                    .map(|index| &self.rows[*index])
                    .ok_or("The selected target is no longer available; refresh the picker")?;
                if self.fixture.is_some() {
                    return Err("Fixture mode never activates Rex targets".into());
                }
                if row.kind == "directory" {
                    actions::open_directory(
                        self.context.as_ref().ok_or("Open the picker first")?,
                        self.snapshot.as_ref().ok_or("Refresh the picker first")?,
                        &row.path,
                    )?;
                    return Ok(json!({"id":id,"type":"activated"}));
                }
                let target = row
                    .activation_target()
                    .ok_or("Fixture mode never activates Rex targets")?;
                // The existing Lua activation checks exact session/window/block
                // membership immediately before focus; cached IDs are not proof.
                rex::activate(
                    self.context.as_ref().ok_or("Open the picker first")?,
                    target,
                )?;
                Ok(json!({"id":id,"type":"activated"}))
            }
            "action" => {
                if self.fixture.is_some() {
                    return Err("Fixture mode never performs Rex actions".into());
                }
                if request["operation"] == "preview"
                    && request["target_id"]
                        .as_str()
                        .and_then(|id| self.by_id.get(id))
                        .is_some_and(|&index| self.rows[index].kind == "directory")
                {
                    let mut preview = json!({"type":"preview","target_id":request["target_id"]});
                    if let Some(lines) = request.get("lines") {
                        preview["lines"] = lines.clone();
                    }
                    let data = self.handle(id, &preview)?;
                    return Ok(
                        json!({"id":id,"type":"action_done","operation":"preview", "text":data["text"],"close_picker":false,"refresh":false}),
                    );
                }
                let selected = self.action_selection(request.get("target_id"))?;
                let secondary = self.action_selection(request.get("destination_id"))?;
                let mut response = actions::run(
                    self.context.as_ref().ok_or("Open the picker first")?,
                    self.snapshot
                        .as_ref()
                        .ok_or("Refresh the picker before using actions")?,
                    selected.as_ref(),
                    secondary.as_ref(),
                    request,
                )?;
                let response_object = response.as_object_mut().ok_or("Invalid action response")?;
                response_object.insert("id".into(), json!(id));
                response_object.insert("type".into(), json!("action_done"));
                response_object.insert("operation".into(), request["operation"].clone());
                Ok(response)
            }
            _ => Err(format!("Unknown picker request: {operation}")),
        }
    }
}

fn choose_client(clients: &Value, requested: &str) -> Result<String, String> {
    let clients = clients["clients"]
        .as_array()
        .ok_or("Rex client list is missing its clients array")?;
    let connected: Vec<&str> = clients
        .iter()
        .filter(|client| client["connection_state"] != "lost")
        // The companion is local-only. A crafted URL must not bypass the
        // launcher's checks and route focus to an iOS app or another Mac.
        .filter(|client| {
            client["info"]["kind"] == "app"
                && client["info"]["platform"] == "macos"
                && client["principal"]["kind"] == "peer"
                && client["principal"]["transport"] == "unix"
                && match client["principal"].get("path") {
                    None | Some(Value::Null) => true,
                    Some(Value::Array(path)) => path.is_empty(),
                    _ => false,
                }
        })
        .filter_map(|client| client["client_id"].as_str())
        .filter(|id| !id.is_empty())
        .collect();
    if !requested.is_empty() {
        return connected
            .iter()
            .find(|id| **id == requested)
            .map(|id| (*id).to_owned())
            .ok_or_else(|| "The requested client must be a connected local macOS Rex app".into());
    }
    match connected.as_slice() {
        [client] => Ok((*client).into()),
        [] => Err("No local macOS Rex app client is connected".into()),
        _ => Err("Multiple Rex apps are connected; launch the picker from the intended app".into()),
    }
}

fn clean(text: &str) -> String {
    text.chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect()
}

fn collapse_single_panes(mut rows: Vec<Candidate>, tree: &Hierarchy) -> Vec<Candidate> {
    let mut removed = vec![false; rows.len()];
    for index in 0..rows.len() {
        if rows[index].kind != "window" || tree.children[index].len() != 1 {
            continue;
        }
        let child = tree.children[index][0];
        if rows[child].kind != "pane" {
            continue;
        }
        // Move the pane's metadata into its tab without changing the tab's
        // identity or semantic target used by rename/close/swap operations.
        let (window, pane) = if index < child {
            let (before, after) = rows.split_at_mut(child);
            (&mut before[index], &mut after[0])
        } else {
            let (before, after) = rows.split_at_mut(index);
            (&mut after[0], &mut before[child])
        };
        window.combined = true;
        window.pane_id = pane.pane_id.take().or_else(|| Some(pane.id.clone()));
        window.pane_target = pane.target.take();
        window.agent_state = pane.agent_state.take();
        window.agent_name = pane.agent_name.take();
        window.current |= pane.current;
        if !pane.path.is_empty() {
            window.path = std::mem::take(&mut pane.path);
        }
        let mut detail = Vec::with_capacity(2);
        for value in [pane.title.as_str(), pane.detail.as_str()] {
            if !value.is_empty() && value != window.title && !detail.contains(&value) {
                detail.push(value);
            }
        }
        window.detail = detail.join(" · ");
        window.search.push(' ');
        window.search.push_str(&pane.search);
        window.name_search.push(' ');
        window.name_search.push_str(&pane.name_search);
        window.command_search = std::mem::take(&mut pane.command_search);
        removed[child] = true;
    }
    rows.into_iter()
        .enumerate()
        .filter_map(|(i, row)| (!removed[i]).then_some(row))
        .collect()
}

/// Only lexical work on keystrokes. Resolution/stat/zoxide happens after Enter
/// through the same shared create-session path used by the terminal picker.
fn creation_label(query: &str) -> Option<String> {
    let pattern = nucleo::pattern::Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);
    if pattern.atoms.is_empty() || pattern.atoms.iter().any(|atom| atom.negative) {
        return None;
    }
    let label = crate::projects::words(query).ok()?;
    let name = if label.contains('/') {
        std::path::Path::new(&label).file_name()?.to_str()?
    } else {
        &label
    };
    (!name.is_empty() && name.len() <= 160).then_some(label)
}

fn millis(started: Instant) -> f64 {
    started.elapsed().as_secs_f64() * 1000.0
}

fn snapshot_rows(snapshot: &Snapshot) -> Vec<Candidate> {
    snapshot_rows_timed(snapshot, &mut json!({}))
}

fn snapshot_rows_timed(snapshot: &Snapshot, timing: &mut Value) -> Vec<Candidate> {
    let agents_started = Instant::now();
    let agents: HashMap<_, _> = crate::native_agents::collect(snapshot, &[])
        .into_iter()
        .map(|agent| (agent.key.clone(), agent))
        .collect();
    timing["agents"] = json!(millis(agents_started));
    let rows_started = Instant::now();
    let sessions: HashMap<_, _> = snapshot
        .sessions
        .iter()
        .map(|s| (s.key.as_str(), s))
        .collect();
    let windows: HashMap<_, _> = snapshot
        .windows
        .iter()
        .map(|w| (w.key.as_str(), w))
        .collect();
    let mut ordered_sessions: Vec<_> = snapshot.sessions.iter().collect();
    ordered_sessions.sort_by_key(|session| std::cmp::Reverse(session.last));
    let ranks: HashMap<_, _> = ordered_sessions
        .iter()
        .enumerate()
        .map(|(i, s)| (s.key.as_str(), i))
        .collect();
    let mut rows =
        Vec::with_capacity(snapshot.sessions.len() + snapshot.windows.len() + snapshot.panes.len());
    for session in ordered_sessions {
        rows.push((
            ranks[session.key.as_str()],
            Candidate {
                id: session.key.clone(),
                parent_id: None,
                kind: "session".into(),
                title: session.name.clone(),
                name: session.name.clone(),
                subtitle: format!("{} tabs", session.window_count),
                detail: String::new(),
                path: session.path.clone(),
                current: snapshot.current.session_key == session.key,
                search: format!("{} {}", session.name, session.path),
                name_search: session.name.clone(),
                command_search: String::new(),
                target: Some(session.target.clone()),
                pane_target: None,
                pane_id: None,
                combined: false,
                agent_state: None,
                agent_name: None,
                operations: Vec::new(),
                ..Candidate::default()
            },
        ));
    }
    for window in &snapshot.windows {
        let session = sessions
            .get(window.session_key.as_str())
            .map_or("", |s| s.name.as_str());
        rows.push((
            *ranks
                .get(window.session_key.as_str())
                .unwrap_or(&usize::MAX),
            Candidate {
                id: window.key.clone(),
                parent_id: Some(window.session_key.clone()),
                kind: "window".into(),
                title: window.name.clone(),
                name: window.name.clone(),
                subtitle: format!("{session} · {}", window.cmd),
                detail: String::new(),
                path: window.path.clone(),
                current: snapshot.current.window_key == window.key,
                search: format!("{} {} {} {}", window.name, session, window.cmd, window.path),
                name_search: format!("{} {session}", window.name),
                command_search: window.cmd.clone(),
                target: Some(window.target.clone()),
                pane_target: None,
                pane_id: None,
                combined: false,
                agent_state: None,
                agent_name: None,
                operations: Vec::new(),
                ..Candidate::default()
            },
        ));
    }
    for pane in &snapshot.panes {
        let session = sessions
            .get(pane.session_key.as_str())
            .map_or("", |s| s.name.as_str());
        let window = windows
            .get(pane.window_key.as_str())
            .map_or("", |w| w.name.as_str());
        let metadata = snapshot.pane_metadata.get(&pane.key);
        let command = metadata
            .map(|m| m.command_line.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or(&pane.cmd);
        let title = if !pane.title.is_empty() {
            &pane.title
        } else if !pane.name.is_empty() {
            &pane.name
        } else {
            &pane.cmd
        };
        let agent = agents.get(&pane.key);
        rows.push((
            *ranks.get(pane.session_key.as_str()).unwrap_or(&usize::MAX),
            Candidate {
                id: pane.key.clone(),
                parent_id: Some(pane.window_key.clone()),
                kind: "pane".into(),
                title: title.clone(),
                name: pane.name.clone(),
                subtitle: format!("{session} · {window} · {command}"),
                detail: command.to_owned(),
                path: pane.path.clone(),
                current: snapshot.current.pane_key == pane.key,
                search: format!(
                    "{title} {} {session} {window} {command} {} {} {}",
                    pane.name,
                    pane.path,
                    agent.map_or("", |a| a.name.as_str()),
                    agent.map_or("", |a| a.state.as_str())
                ),
                target: Some(pane.target.clone()),
                name_search: format!("{title} {} {session} {window}", pane.name),
                command_search: format!(
                    "{command} {title} {} {}",
                    agent.map_or("", |a| a.name.as_str()),
                    agent.map_or("", |a| a.state.as_str())
                ),
                pane_target: None,
                pane_id: Some(pane.key.clone()),
                combined: false,
                agent_state: agent.map(|a| a.state.clone()).filter(|s| !s.is_empty()),
                agent_name: agent.map(|a| a.name.clone()),
                operations: Vec::new(),
                ..Candidate::default()
            },
        ));
    }
    rows.sort_by_key(|(rank, _)| *rank);
    let rows = rows
        .into_iter()
        .map(|(_, mut row)| {
            row.title = clean(&row.title);
            row.subtitle = clean(&row.subtitle);
            row.detail = clean(&row.detail);
            row.path = clean(&row.path);
            row.search = clean(&row.search);
            row.name_search = clean(&row.name_search);
            row.command_search = clean(&row.command_search);
            row
        })
        .collect();
    timing["rows"] = json!(millis(rows_started));
    rows
}

fn read_fixture(path: &PathBuf) -> Result<Vec<Candidate>, String> {
    let bytes = fs::read(path)
        .map_err(|error| format!("Cannot read fixture {}: {error}", path.display()))?;
    let value: Value =
        serde_json::from_slice(&bytes).map_err(|error| format!("Invalid fixture JSON: {error}"))?;
    let values = value["rows"]
        .as_array()
        .ok_or("Fixture must contain a rows array")?;
    let mut rows = Vec::with_capacity(values.len());
    let mut ids = HashSet::new();
    for value in values {
        let id = value["id"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or("Fixture row requires an id")?;
        if !ids.insert(id) {
            return Err(format!("Duplicate fixture ID: {id}"));
        }
        let kind = value["kind"]
            .as_str()
            .ok_or("Fixture row requires a kind")?;
        if !matches!(kind, "session" | "window" | "pane" | "directory") {
            return Err(format!("Invalid fixture kind: {kind}"));
        }
        let parent_id = match value.get("parent_id") {
            None | Some(Value::Null) => None,
            Some(Value::String(parent)) if !parent.is_empty() => Some(parent.clone()),
            _ => return Err("Fixture parent_id must be a nonempty string or null".into()),
        };
        let title = clean(
            value["title"]
                .as_str()
                .ok_or("Fixture row requires a title")?,
        );
        let subtitle = clean(value["subtitle"].as_str().unwrap_or(""));
        let detail = clean(value["detail"].as_str().unwrap_or(""));
        let path = clean(value["path"].as_str().unwrap_or(""));
        let agent_state = match value.get("agent_state") {
            None | Some(Value::Null) => None,
            Some(Value::String(state))
                if matches!(
                    state.as_str(),
                    "approve" | "input" | "working" | "idle" | "done" | "error"
                ) =>
            {
                Some(state.clone())
            }
            _ => return Err("Fixture agent_state must be a known state or null".into()),
        };
        let agent_name = value["agent_name"].as_str().map(clean);
        let search = value["search"].as_str().map(clean).unwrap_or_else(|| {
            format!(
                "{title} {} {subtitle} {detail} {path} {} {} {}",
                value["name"].as_str().unwrap_or(""),
                value["command"].as_str().unwrap_or(""),
                agent_name.as_deref().unwrap_or(""),
                agent_state.as_deref().unwrap_or("")
            )
        });
        rows.push(Candidate {
            id: id.into(),
            parent_id,
            kind: kind.into(),
            name: clean(value["name"].as_str().unwrap_or(&title)),
            title,
            subtitle,
            detail,
            path,
            current: value["current"].as_bool().unwrap_or(false),
            search,
            name_search: value["search_name"].as_str().map(clean).unwrap_or_else(|| {
                format!(
                    "{} {}",
                    value["title"].as_str().unwrap_or(""),
                    value["name"].as_str().unwrap_or("")
                )
            }),
            command_search: value["command"].as_str().map(clean).unwrap_or_else(|| {
                if value["detail"].as_str().unwrap_or("").is_empty() {
                    clean(value["subtitle"].as_str().unwrap_or(""))
                } else {
                    clean(value["detail"].as_str().unwrap_or(""))
                }
            }),
            target: None,
            pane_target: None,
            pane_id: (kind == "pane").then(|| id.to_owned()),
            combined: false,
            agent_state,
            agent_name,
            operations: Vec::new(),
            main_recent: kind == "directory" && value["recent"] != false,
            directory_visible: kind == "directory",
        });
    }
    Ok(rows)
}

pub(crate) fn serve(args: &[String]) -> Result<(), String> {
    let mut defaults = empty_context();
    let mut fixture = None;
    let mut arguments = args.iter();
    while let Some(argument) = arguments.next() {
        let value = arguments
            .next()
            .ok_or_else(|| format!("Missing value for {argument}"))?;
        match argument.as_str() {
            "--fixture" => fixture = Some(PathBuf::from(value)),
            "--client" => defaults.client_id = value.clone(),
            "--session" => defaults.session_id = value.clone(),
            "--window" => defaults.window_id = value.clone(),
            "--block" => defaults.block_id = value.clone(),
            "--server" => defaults.server = Some(value.clone()),
            _ => return Err(format!("Unknown macos-serve option: {argument}")),
        }
    }
    let mut picker = Picker::new(fixture, defaults);
    let stdin = io::stdin();
    let stdout = io::stdout();
    run_protocol(&mut picker, &mut stdin.lock(), &mut stdout.lock())
}

fn run_protocol(
    picker: &mut Picker,
    input: &mut impl BufRead,
    output: &mut impl Write,
) -> Result<(), String> {
    let mut line = Vec::new();
    loop {
        line.clear();
        // Bound a malformed sender before allocating an unbounded line. Once
        // over the limit close the stream rather than parse a truncated action.
        let mut bounded = io::Read::take(&mut *input, (MAX_REQUEST + 1) as u64);
        let count = bounded
            .read_until(b'\n', &mut line)
            .map_err(|e| format!("Cannot read picker request: {e}"))?;
        if count == 0 {
            return Ok(());
        }
        let response = if count > MAX_REQUEST {
            json!({"id":null,"type":"error","message":"Picker request exceeds 64 KiB"})
        } else {
            match serde_json::from_slice::<Value>(&line) {
                Ok(request) => picker.request(&request),
                Err(error) => {
                    json!({"id":null,"type":"error","message":format!("Invalid request JSON: {error}")})
                }
            }
        };
        serde_json::to_writer(&mut *output, &response)
            .map_err(|e| format!("Cannot write picker response: {e}"))?;
        output
            .write_all(b"\n")
            .and_then(|_| output.flush())
            .map_err(|e| format!("Cannot flush picker response: {e}"))?;
        if count > MAX_REQUEST {
            return Ok(());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(1);

    struct Fixture(PathBuf);

    impl Fixture {
        fn new(rows: Value) -> Self {
            let path = std::env::temp_dir().join(format!(
                "imux-native-picker-{}-{}.json",
                std::process::id(),
                NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
            ));
            let fixture = Self(path);
            fixture.write(rows);
            fixture
        }

        fn write(&self, rows: Value) {
            fs::write(&self.0, json!({"rows":rows}).to_string()).unwrap();
        }

        fn picker(&self) -> Picker {
            Picker::new(Some(self.0.clone()), empty_context())
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.0);
        }
    }

    fn query(picker: &mut Picker, text: &str, scope: &str) -> Value {
        picker.request(&json!({"id":2,"type":"query","query":text,"scope":scope}))
    }

    fn result_ids(result: &Value) -> Vec<&str> {
        result["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row["id"].as_str().unwrap())
            .collect()
    }

    #[test]
    fn mac_picker_dashboard_totals_cover_full_tree_and_combined_panes() {
        let mut rows = vec![json!({"id":"s","kind":"session","title":"workspace"})];
        for index in 0..150 {
            rows.push(json!({"id":format!("w{index}"),"kind":"window","parent_id":"s","title":format!("tab {index}")}));
            rows.push(json!({"id":format!("p{index}"),"kind":"pane","parent_id":format!("w{index}"),"title":format!("pane {index}"),
                "agent_state":if index < 30 {"approve"} else {"working"}}));
        }
        rows.push(
            json!({"id":"project","kind":"directory","title":"project","path":"/Network/no-probe"}),
        );
        let fixture = Fixture::new(json!(rows));
        let mut picker = fixture.picker();
        let opened = picker.request(&json!({"id":1,"type":"open"}));
        assert_eq!(opened["rows"].as_array().unwrap().len(), MAX_ROWS);
        let expected = json!({"sessions":1,"tabs":150,"panes":150,"attention":30,"projects":1,"terminal_tools_available":false});
        assert_eq!(opened["dashboard"], expected);
        let filtered = query(&mut picker, "^no-match$", "attention");
        assert_eq!(filtered["matched"], 0);
        assert_eq!(filtered["dashboard"], expected);
        for operation in ["next-agent", "schedule", "jobs", "health"] {
            let denied =
                picker.request(&json!({"id":3,"type":"dashboard_action","operation":operation}));
            assert_eq!(denied["type"], "error");
            assert!(denied["message"].as_str().unwrap().contains("Fixture mode"));
        }
        fixture.write(json!([]));
        let refreshed = picker.request(&json!({"id":4,"type":"refresh"}));
        assert_eq!(
            refreshed["dashboard"],
            json!({"sessions":0,"tabs":0,"panes":0,"attention":0,"projects":0,"terminal_tools_available":false})
        );
    }

    #[test]
    fn mac_picker_action_filters_keep_context_exclude_projects_and_survive_refresh() {
        let fixture = Fixture::new(json!([
            {"id":"s","kind":"session","title":"work"},
            {"id":"w","kind":"window","parent_id":"s","title":"terminal"},
            {"id":"p","kind":"pane","parent_id":"w","title":"needle"},
            {"id":"dir","kind":"directory","title":"needle project","path":"/Network/no-probe"}
        ]));
        let mut picker = fixture.picker();
        picker.request(&json!({"id":1,"type":"open"}));
        for action in ["rename", "close", "swap", "zoom", "send"] {
            let result = picker.request(&json!({"id":2,"type":"query","query":"needle","scope":"all","action_filter":action}));
            assert_eq!(result["action_filter"], action);
            assert_eq!(result["matched"], 1);
            assert_eq!(result_ids(&result), ["s", "w"]);
            assert_eq!(result["rows"][0]["context_only"], true);
            assert_eq!(result["rows"][1]["combined"], true);
            assert_eq!(result["dashboard"]["projects"], 1);
        }
        for invalid in [json!("delete"), json!(false)] {
            let response = picker
                .request(&json!({"id":3,"type":"query","query":"needle","action_filter":invalid}));
            assert_eq!(response["type"], "error");
            assert_eq!(picker.action_filter, "send");
        }
        let refresh = picker.request(&json!({"id":4,"type":"refresh"}));
        assert_eq!(refresh["action_filter"], "send");
        assert_eq!(result_ids(&refresh), ["s", "w"]);
        let suppressed = picker
            .request(&json!({"id":5,"type":"query","query":"brand new","action_filter":"rename"}));
        assert_eq!(suppressed["can_create"], false);
        assert!(result_ids(&suppressed).is_empty());
        let cleared = query(&mut picker, "needle", "all");
        assert_eq!(cleared["action_filter"], "");
        assert!(result_ids(&cleared).contains(&"dir"));
        picker.request(&json!({"id":6,"type":"query","query":"","action_filter":"swap"}));
        let reopen = picker.request(&json!({"id":7,"type":"open"}));
        assert_eq!(reopen["action_filter"], "");
    }

    #[test]
    fn mac_picker_main_search_prioritizes_live_targets_and_keeps_warm_recents() {
        let fixture = Fixture::new(json!([
            {"id":"recent","kind":"directory","title":"needle","path":"/Network/no-probe/needle"},
            {"id":"live","kind":"pane","title":"xxneedle"},
            {"id":"child","kind":"directory","title":"child","path":"/Network/no-probe/needle/child","recent":false}
        ]));
        let mut picker = fixture.picker();
        let opened = picker.request(&json!({"id":1,"type":"open"}));
        assert_eq!(result_ids(&opened), ["live", "recent"]);
        assert_eq!(opened["total"], 2);
        let matched = query(&mut picker, "needle", "all");
        assert_eq!(matched["preferred_id"], "live");
        assert_eq!(result_ids(&matched), ["live", "recent"]);
        assert_eq!(matched["can_create"], false);
        fs::remove_file(&fixture.0).unwrap();
        let browsed =
            picker.request(&json!({"id":3,"type":"directories","base_id":"child","query":""}));
        assert_eq!(result_ids(&browsed), ["child"]);
        assert_eq!(
            result_ids(&query(&mut picker, "", "all")),
            ["live", "recent"]
        );
        assert_eq!(result_ids(&query(&mut picker, "", "directory")), ["child"]);
        // Exact cached project identity remains available even after browsing
        // into its child, without re-reading the removed fixture or history.
        let recent = query(&mut picker, "'Network/no-probe/needle", "all");
        assert_eq!(recent["preferred_id"], "recent");
        assert_eq!(recent["can_create"], false);
    }

    #[test]
    fn mac_picker_create_choices_are_lexical_scoped_and_generation_bound() {
        let fixture = Fixture::new(json!([]));
        let mut picker = fixture.picker();
        picker.request(&json!({"id":1,"type":"open"}));
        fs::remove_file(&fixture.0).unwrap();
        let created = query(&mut picker, "'new\\ project$", "all");
        assert_eq!(created["type"], "results");
        assert_eq!(created["matched"], 0);
        assert_eq!(created["shown_matches"], 0);
        assert_eq!(created["can_create"], true);
        assert_eq!(created["rows"][0]["kind"], "create");
        assert_eq!(created["rows"][0]["name"], "new project");
        let first = created["preferred_id"].as_str().unwrap().to_owned();
        assert_eq!(picker.pending_create.as_ref().unwrap().1, "'new\\ project$");
        let denied = picker.request(&json!({"id":3,"type":"activate","target_id":first}));
        assert!(denied["message"]
            .as_str()
            .unwrap()
            .contains("never activates"));
        let second = query(&mut picker, "new project", "all");
        assert_ne!(second["preferred_id"], first);
        let stale = picker.request(&json!({"id":4,"type":"activate","target_id":first}));
        assert!(stale["message"]
            .as_str()
            .unwrap()
            .contains("no longer available"));
        for text in [
            "",
            " ",
            "'",
            "^",
            "$",
            "!",
            "!excluded",
            "wanted !excluded",
            "a | b",
            "bad\nname",
        ] {
            let result = query(&mut picker, text, "all");
            assert_eq!(result["can_create"], false, "{text:?}");
            assert!(result_ids(&result).is_empty(), "{text:?}");
        }
        for scope in ["session", "window", "pane", "attention", "directory"] {
            assert_eq!(
                query(&mut picker, "new project", scope)["can_create"],
                false
            );
        }
        for field in ["path", "command"] {
            let result = picker.request(&json!({"id":5,"type":"query","query":"new project","scope":"all","search_field":field}));
            assert_eq!(result["can_create"], false);
        }
        let suppressed = picker.request(&json!({"id":6,"type":"query","query":"new project","search_field":"name","allow_create":false}));
        assert_eq!(suppressed["can_create"], false);
        let allowed = picker
            .request(&json!({"id":7,"type":"query","query":"new project","search_field":"name"}));
        assert_eq!(allowed["can_create"], true);
        assert_eq!(
            picker.request(
                &json!({"id":8,"type":"query","query":"new project","allow_create":"false"})
            )["type"],
            "error"
        );
        assert!(picker.pending_create.is_none());
        assert!(creation_label(&"x".repeat(161)).is_none());
        // Long path hints are still cheap lexical work; nonexistent paths and
        // network-looking input do not trigger filesystem probes while typing.
        assert!(creation_label(&format!("/Network/{}/project", "x".repeat(200))).is_some());
    }

    #[test]
    fn mac_picker_matcher_exact_unicode_suffix_and_literal_whitespace_regression() {
        use nucleo::pattern::Pattern;
        let mut matcher = nucleo::Matcher::new(Config::DEFAULT);
        let mut buffer = Vec::new();
        for (haystack, query, expected) in [
            ("/workspace/開発/4999", "'開発/4999", true),
            ("/workspace/開発/4999", "'4999", true),
            ("/workspace/開発/4999", "4999$", true),
            ("/workspace/開発/4999", "^/workspace/開発/4999$", true),
            ("/workspace/開発/4999", "!'4999", false),
            ("/workspace/開発/4999", "'4999\\ ", false),
            ("/workspace/開発/4999", "4999\\ $", false),
            ("/workspace/開発/4999 ", "4999\\ $", true),
            ("/workspace/4999", "'4999", true),
            ("/workspace/東京/9", "'9", true),
            ("/workspace/東京/other", "'4999", false),
        ] {
            let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);
            let haystack = nucleo::Utf32Str::new(haystack, &mut buffer);
            assert_eq!(
                pattern.score(haystack, &mut matcher).is_some(),
                expected,
                "query {query:?}"
            );
        }
    }

    #[test]
    fn mac_picker_field_switching_uses_independent_cached_columns() {
        let fixture = Fixture::new(json!([
            {"id":"name","kind":"pane","title":"needle","path":"/other","command":"other"},
            {"id":"path","kind":"pane","title":"other","path":"/needle","command":"other"},
            {"id":"command","kind":"pane","title":"other","path":"/other","command":"needle","search":"other needle"}
        ]));
        let mut picker = fixture.picker();
        picker.request(&json!({"id":1,"type":"open"}));
        fs::remove_file(&fixture.0).unwrap();
        for (field, expected) in [
            ("name", "name"),
            ("path", "path"),
            ("command", "command"),
            ("path", "path"),
            ("name", "name"),
        ] {
            let result = picker.request(&json!({"id":2,"type":"query","query":"needle","scope":"pane","search_field":field}));
            assert_eq!(result["search_field"], field);
            assert_eq!(result["matched"], 1);
            assert_eq!(result["preferred_id"], expected);
        }
        let all =
            picker.request(&json!({"id":3,"type":"query","query":"needle","search_field":"all"}));
        assert_eq!(all["matched"], 3);
        assert_eq!(
            picker
                .request(&json!({"id":4,"type":"query","query":"needle","search_field":"invalid"}))
                ["type"],
            "error"
        );
    }

    #[test]
    fn mac_picker_fixture_projects_browse_and_preview_never_touch_filesystem_or_rex() {
        let fixture = Fixture::new(json!([
            {"id":"pane","kind":"pane","title":"terminal"},
            {"id":"root","kind":"directory","title":"workspace","path":"/Network/never-probe/workspace"},
            {"id":"child","kind":"directory","title":"東京","path":"/Network/never-probe/workspace/東京"},
            {"id":"nested","kind":"directory","title":"nested","path":"/Network/never-probe/workspace/東京/nested"},
            {"id":"other","kind":"directory","title":"other","path":"/Network/never-probe/other"}
        ]));
        let mut picker = fixture.picker();
        let opened = picker.request(&json!({"id":1,"type":"open"}));
        assert_eq!(opened["total"], 5);
        assert_eq!(opened["directories_loaded"], false);
        assert_eq!(query(&mut picker, "", "directory")["matched"], 4);
        assert!(
            !picker.directories.loaded,
            "queries must never initiate discovery"
        );
        fs::remove_file(&fixture.0).unwrap();
        let root = picker
            .request(&json!({"id":2,"type":"directories","reset":true,"search_field":"name"}));
        assert_eq!(root["directories_loaded"], true);
        assert_eq!(root["search_field"], "name");
        let child = picker
            .request(&json!({"id":3,"type":"directories","base_id":"root","search_field":"path"}));
        assert_eq!(result_ids(&child), ["root", "child"]);
        assert_eq!(child["directories_base"], "/Network/never-probe/workspace");
        assert_eq!(child["search_field"], "path");
        let deep =
            picker.request(&json!({"id":4,"type":"directories","deep":true,"query":"nested"}));
        assert_eq!(deep["directories_deep"], true);
        assert_eq!(result_ids(&deep), ["nested"]);
        let parent = picker.request(&json!({"id":5,"type":"directories","parent":true}));
        assert_eq!(parent["directories_base"], "/Network/never-probe");
        assert_eq!(result_ids(&parent), ["root", "other"]);
        assert_eq!(parent["query"], "");
        let preview =
            picker.request(&json!({"id":6,"type":"preview","target_id":"root","lines":80}));
        assert_eq!(preview["type"], "preview");
        assert!(preview["text"]
            .as_str()
            .unwrap()
            .contains("no Rex connection or filesystem reads"));
        assert_eq!(
            picker.request(&json!({"id":7,"type":"activate","target_id":"root"}))["type"],
            "error"
        );
        assert_eq!(
            picker.request(&json!({"id":8,"type":"preview","target_id":"stale"}))["type"],
            "error"
        );
        assert_eq!(
            picker.request(&json!({"id":9,"type":"preview","target_id":"root","lines":201}))
                ["type"],
            "error"
        );
        assert_eq!(
            picker.request(&json!({"id":10,"type":"directories","reset":true,"parent":true}))
                ["type"],
            "error"
        );
        assert_eq!(
            picker.request(&json!({"id":11,"type":"directories","search_field":"invalid"}))["type"],
            "error"
        );
    }

    fn tree_rows() -> Value {
        // Source deliberately lists every tab before every pane. Duplicate
        // display names must never merge groups or become selection keys.
        json!([
            {"id":"s1","kind":"session","title":"same project"},
            {"id":"s2","kind":"session","title":"same project"},
            {"id":"w1","kind":"window","parent_id":"s1","title":"same tab"},
            {"id":"w2","kind":"window","parent_id":"s1","title":"same tab"},
            {"id":"w3","kind":"window","parent_id":"s2","title":"same tab"},
            {"id":"p1","kind":"pane","parent_id":"w1","title":"xxneedle"},
            {"id":"p2","kind":"pane","parent_id":"w2","title":"xneedle"},
            {"id":"p3","kind":"pane","parent_id":"w3","title":"needle"},
            {"id":"spare1","kind":"pane","parent_id":"w1","title":"other"},
            {"id":"spare2","kind":"pane","parent_id":"w2","title":"other"},
            {"id":"spare3","kind":"pane","parent_id":"w3","title":"other"}
        ])
    }

    #[test]
    fn mac_picker_combined_rows_keep_pane_search_scopes_and_attention_once() {
        let fixture = Fixture::new(json!([
            {"id":"s","kind":"session","title":"work"},
            {"id":"w","kind":"window","parent_id":"s","title":"editor"},
            {"id":"p","kind":"pane","parent_id":"w","title":"Refactor 日本語 parser",
                "detail":"codex --resume task-42","path":"/workspace/deep/review","agent_state":"approve","agent_name":"Codex"}
        ]));
        let mut picker = fixture.picker();
        let result = picker.request(&json!({"id":1,"type":"open"}));
        assert_eq!(result_ids(&result), ["s", "w"]);
        assert_eq!(result["attention_count"], 1);
        let row = &result["rows"][1];
        assert_eq!(row["kind"], "window");
        assert_eq!(row["pane_id"], "p");
        assert_eq!(row["combined"], true);
        assert_eq!(row["name"], "editor");
        assert!(row["actions"].as_array().unwrap().contains(&json!("send")));
        assert!(row["actions"]
            .as_array()
            .unwrap()
            .contains(&json!("rename")));
        assert!(row["detail"].as_str().unwrap().contains("日本語"));
        assert!(row["detail"].as_str().unwrap().contains("codex --resume"));
        assert_eq!(row["path"], "/workspace/deep/review");
        for scope in ["window", "pane", "attention"] {
            let scoped = query(&mut picker, "", scope);
            assert_eq!(scoped["total"], 1, "scope {scope}");
            assert_eq!(scoped["matched"], 1);
            assert_eq!(scoped["shown_matches"], 1);
            assert_eq!(scoped["preferred_id"], "w");
            assert_eq!(scoped["rows"][1]["context_only"], false);
        }
        for needle in ["日本語", "task-42", "deep/review"] {
            assert_eq!(query(&mut picker, needle, "pane")["preferred_id"], "w");
        }
        for operation in ["close", "send", "create-session", "preview"] {
            let denied = picker.request(&json!({"id":9,"type":"action","operation":operation,
                "target_id":"w","value":"literal input","confirmed":true}));
            assert_eq!(denied["id"], 9);
            assert_eq!(denied["type"], "error");
            assert!(denied["message"]
                .as_str()
                .unwrap()
                .contains("never performs Rex actions"));
        }
    }

    #[test]
    fn mac_picker_attention_uses_verified_states_and_counts_combined_and_split_once() {
        let fixture = Fixture::new(json!([]));
        let mut windows = Vec::new();
        let mut metadata = serde_json::Map::new();
        for (id, state, kind, owner_pid, owner_name) in [
            ("approve", "blocked", "permission", 42, "bash"),
            ("question", "blocked", "question", 42, "bash"),
            ("idle", "idle", "", 42, "bash"),
            ("done", "done", "", 42, "bash"),
            ("error", "error", "", 42, "bash"),
            ("working", "working", "", 42, "bash"),
            ("old-pid", "blocked", "permission", 99, "bash"),
            ("old-name", "blocked", "permission", 42, "other"),
        ] {
            let block = format!("block:{id}");
            let mut blocks =
                vec![json!({"block_id":block,"label":"approve input misleading label"})];
            if id == "question" {
                blocks.push(json!({"block_id":"block:spare","label":"idle shell"}));
            }
            windows.push(
                json!({"window_id":format!("window:{id}"),"label":format!("tab {id}"),
                "layers":[{"blocks":blocks}]}),
            );
            metadata.insert(
                block,
                json!({
                    "foreground":{"pid":42,"name":"bash","argv0":"bash"},
                    "program_status":{"records":[{"state":state,"kind":kind,"title":"Task status",
                        "app":if id == "question" {"custom-agent"} else {"codex"},
                        "owner":{"pid":owner_pid,"name":owner_name}}]}
                }),
            );
        }
        fs::write(
            &fixture.0,
            json!({"version":1,
                "sessions":[{"session_id":"session:tasks","label":"tasks"}],
                "views":{"session:tasks":{"windows":windows}},"metadata":metadata
            })
            .to_string(),
        )
        .unwrap();
        let mut context = empty_context();
        context.snapshot_file = Some(fixture.0.clone());
        let snapshot = rex::collect(&context).unwrap();
        let mut picker = Picker::new(None, empty_context());
        picker.replace(snapshot_rows(&snapshot)).unwrap();
        picker.opened = true;
        let attention = query(&mut picker, "", "attention");
        assert_eq!(attention["total"], 2);
        assert_eq!(attention["matched"], 2);
        assert_eq!(attention["shown_matches"], 2);
        assert_eq!(attention["attention_count"], 2);
        assert_eq!(
            result_ids(&attention),
            [
                "session:tasks",
                "window:approve",
                "window:question",
                "block:question"
            ]
        );
        assert_eq!(attention["rows"][1]["agent_state"], "approve");
        assert_eq!(attention["rows"][1]["combined"], true);
        assert_eq!(attention["rows"][2]["context_only"], true);
        assert_eq!(attention["rows"][3]["agent_state"], "input");
        for id in ["idle", "done", "error", "working", "old-pid", "old-name"] {
            assert!(!picker.rows[picker.by_id[&format!("window:{id}")]].attention());
        }
        for id in ["old-pid", "old-name"] {
            assert!(picker.rows[picker.by_id[&format!("window:{id}")]]
                .agent_state
                .is_none());
        }
        assert_eq!(
            query(&mut picker, "no-such-task", "attention")["attention_count"],
            2
        );
    }

    #[test]
    fn mac_picker_tree_preorder_and_scopes_keep_contextual_ancestors() {
        let fixture = Fixture::new(tree_rows());
        let mut picker = fixture.picker();
        let opened = picker.request(&json!({"id":1,"type":"open"}));
        assert_eq!(
            result_ids(&opened),
            ["s1", "w1", "p1", "spare1", "w2", "p2", "spare2", "s2", "w3", "p3", "spare3"]
        );
        assert_eq!(opened["shown_matches"], 11);
        assert_eq!(opened["preferred_id"], "s1");
        assert!(opened["rows"]
            .as_array()
            .unwrap()
            .iter()
            .all(|row| row["context_only"] == false));

        let panes = query(&mut picker, "", "pane");
        assert_eq!(result_ids(&panes), result_ids(&opened));
        assert_eq!(panes["total"], 6);
        assert_eq!(panes["matched"], 6);
        assert_eq!(panes["shown_matches"], 6);
        assert_eq!(panes["preferred_id"], "p1");
        for row in panes["rows"].as_array().unwrap() {
            assert_eq!(row["context_only"], row["kind"] != "pane");
        }

        let tabs = query(&mut picker, "", "window");
        assert_eq!(result_ids(&tabs), ["s1", "w1", "w2", "s2", "w3"]);
        assert_eq!(tabs["shown_matches"], 3);
        assert_eq!(tabs["preferred_id"], "w1");
        assert_eq!(tabs["rows"][1]["parent_id"], "s1");
        assert_eq!(result_ids(&query(&mut picker, "", "session")), ["s1", "s2"]);
    }

    #[test]
    fn mac_picker_tree_groups_follow_best_descendant_and_prefer_actual_match() {
        let fixture = Fixture::new(tree_rows());
        let mut picker = fixture.picker();
        picker.request(&json!({"id":1,"type":"open"}));
        let result = query(&mut picker, "needle", "pane");
        assert_eq!(
            result_ids(&result),
            ["s2", "w3", "p3", "s1", "w2", "p2", "w1", "p1"]
        );
        assert_eq!(result["preferred_id"], "p3");
        assert_eq!(result["matched"], 3);
        assert_eq!(result["shown_matches"], 3);
        assert_eq!(result["rows"][0]["context_only"], true);
        assert_eq!(result["rows"][2]["context_only"], false);
        let only = query(&mut picker, "^needle$", "all");
        assert_eq!(result_ids(&only), ["s2", "w3", "p3"]);
        assert_eq!(only["preferred_id"], "p3");
        assert_eq!(only["matched"], 1);
        let empty = picker.request(&json!({"id":9,"type":"query","query":"no-such-match","scope":"all","allow_create":false}));
        assert!(result_ids(&empty).is_empty());
        assert_eq!(empty["matched"], 0);
        assert_eq!(empty["shown_matches"], 0);
        assert_eq!(empty["preferred_id"], Value::Null);
    }

    #[test]
    fn mac_picker_tree_cap_never_orphans_matches_or_miscounts_context() {
        let mut rows = Vec::new();
        for index in 0..40 {
            rows.extend([
                json!({"id":format!("s{index}"),"kind":"session","title":"project"}),
                json!({"id":format!("w{index}"),"parent_id":format!("s{index}"),"kind":"window","title":"tab"}),
                json!({"id":format!("p{index}"),"parent_id":format!("w{index}"),"kind":"pane","title":"needle"}),
                json!({"id":format!("spare{index}"),"parent_id":format!("w{index}"),"kind":"pane","title":"other"}),
            ]);
        }
        let fixture = Fixture::new(json!(rows));
        let mut picker = fixture.picker();
        let opened = picker.request(&json!({"id":1,"type":"open"}));
        assert_eq!(opened["rows"].as_array().unwrap().len(), MAX_ROWS);
        assert_eq!(opened["shown_matches"], MAX_ROWS);
        assert_eq!(opened["matched"], 160);
        let result = query(&mut picker, "needle", "pane");
        assert_eq!(result["matched"], 40);
        assert_eq!(result["shown_matches"], 33);
        assert_eq!(result["preferred_id"], "p0");
        assert_eq!(result["rows"].as_array().unwrap().len(), 99);
        let mut preceding = HashSet::new();
        for row in result["rows"].as_array().unwrap() {
            if let Some(parent) = row["parent_id"].as_str() {
                assert!(preceding.contains(parent), "orphan row: {row}");
            }
            preceding.insert(row["id"].as_str().unwrap());
        }
    }

    #[test]
    fn mac_picker_tree_rejects_cycles_missing_parents_and_wrong_levels() {
        for invalid in [
            json!([{"id":"p","kind":"pane","title":"pane","parent_id":"missing"}]),
            json!([{"id":"s","kind":"session","title":"session","parent_id":"s"}]),
            json!([{"id":"s","kind":"session","title":"session","parent_id":"w"},
                   {"id":"w","kind":"window","title":"tab","parent_id":"s"}]),
            json!([{"id":"s","kind":"session","title":"session"},
                   {"id":"p","kind":"pane","title":"pane","parent_id":"s"}]),
            json!([{"id":"s","kind":"session","title":"session","parent_id":42}]),
        ] {
            let fixture = Fixture::new(invalid);
            let mut picker = fixture.picker();
            assert_eq!(
                picker.request(&json!({"id":1,"type":"open"}))["type"],
                "error"
            );
        }
        let fixture = Fixture::new(json!([
            {"id":"tab","kind":"window","title":"flat tab"},
            {"id":"pane","kind":"pane","title":"flat pane","parent_id":null}
        ]));
        let mut picker = fixture.picker();
        let result = picker.request(&json!({"id":1,"type":"open"}));
        assert_eq!(result_ids(&result), ["tab", "pane"]);
        assert!(result["rows"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["parent_id"].is_null()));
    }

    #[test]
    fn mac_picker_real_snapshot_preserves_mru_then_tab_pane_preorder() {
        let fixture = Fixture::new(json!([]));
        let window = |id: &str, pane: &str| {
            json!({"window_id":id,"label":"tab","layers":[
            {"kind":"tiled","blocks":[{"block_id":pane,"label":"pane"}]}]})
        };
        let mut split = window("window:a", "block:a");
        split["layers"][0]["blocks"]
            .as_array_mut()
            .unwrap()
            .push(json!({"block_id":"block:a2","label":"second pane"}));
        fs::write(&fixture.0, json!({"version":1,
            "sessions":[{"session_id":"session:old","label":"old"},{"session_id":"session:new","label":"new"}],
            "views":{
                "session:old":{"windows":[split,window("window:b","block:b")]},
                "session:new":{"windows":[window("window:c","block:c")]}
            },"metadata":{},"mru":{"session:old":1,"session:new":2}
        }).to_string()).unwrap();
        let mut context = empty_context();
        context.snapshot_file = Some(fixture.0.clone());
        let snapshot = rex::collect(&context).unwrap();
        let mut picker = Picker::new(None, empty_context());
        picker.replace(snapshot_rows(&snapshot)).unwrap();
        let result = picker.results(1, Instant::now()).unwrap();
        assert_eq!(
            result_ids(&result),
            [
                "session:new",
                "window:c",
                "session:old",
                "window:a",
                "block:a",
                "block:a2",
                "window:b",
            ]
        );
        assert_eq!(result["rows"][1]["pane_id"], "block:c");
        assert_eq!(result["rows"][1]["combined"], true);
        assert_eq!(result["rows"][4]["parent_id"], "window:a");
        assert!(result["rows"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["current"] == false));
        let combined = &picker.rows[picker.by_id["window:b"]];
        let selected = combined.activation_target();
        assert_eq!(
            selected,
            Some(&Target::Rex {
                session_id: "session:old".into(),
                window_id: Some("window:b".into()),
                block_id: Some("block:b".into())
            })
        );
        assert_eq!(
            combined.target,
            Some(Target::Rex {
                session_id: "session:old".into(),
                window_id: Some("window:b".into()),
                block_id: None
            })
        );
        assert!(!picker.by_id.contains_key("block:b"));
        let action = combined.action_selection().unwrap();
        assert_eq!(Some(action.target), combined.target);
        assert_eq!(action.pane_target.as_ref(), combined.activation_target());
    }

    #[test]
    fn mac_picker_protocol_waits_for_open_and_recovers_after_invalid_json() {
        let fixture =
            Fixture::new(json!([{"id":"one","kind":"pane","title":"quoted \"title\"\n"}]));
        let mut picker = fixture.picker();
        let mut output = Vec::new();
        run_protocol(&mut picker, &mut io::Cursor::new(b""), &mut output).unwrap();
        assert!(
            output.is_empty(),
            "there must be no unsolicited initialization response"
        );
        let input = b"{\"id\":1,\"type\":\"query\",\"query\":\"\"}\ninvalid\n{\"id\":3,\"type\":\"open\"}\n{\"id\":4,\"type\":\"query\",\"query\":\"title\"}\n";
        run_protocol(&mut picker, &mut io::Cursor::new(input), &mut output).unwrap();
        let responses: Vec<Value> = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(responses.len(), 4);
        assert_eq!(responses[0]["id"], 1);
        assert_eq!(responses[0]["type"], "error");
        assert_eq!(responses[1]["id"], Value::Null);
        assert_eq!(responses[2]["id"], 3);
        assert_eq!(responses[2]["rows"][0]["title"], "quoted \"title\" ");
        assert_eq!(responses[3]["matched"], 1);
    }

    #[test]
    fn mac_picker_ranks_matches_and_searches_full_unicode_metadata() {
        let fixture = Fixture::new(json!([
            {"id":"other","kind":"pane","title":"xalpha"},
            {"id":"exact","kind":"pane","title":"alpha"},
            {"id":"unicode","kind":"window","title":"Café 開発 👩‍💻","path":"/very/long/path/unique-suffix"},
            {"id":"hidden","kind":"session","title":"display","search":"full untruncated metadata"}
        ]));
        let mut picker = fixture.picker();
        assert_eq!(picker.request(&json!({"id":1,"type":"open"}))["matched"], 4);
        assert_eq!(query(&mut picker, "alpha", "all")["rows"][0]["id"], "exact");
        assert_eq!(query(&mut picker, "alphabet", "all")["matched"], 0);
        assert_eq!(query(&mut picker, "alpha", "all")["matched"], 2);
        assert_eq!(query(&mut picker, "", "all")["matched"], 4);
        for text in ["cafe", "開発", "👩‍💻", "unique-suffix"] {
            let result = query(&mut picker, text, "all");
            assert_eq!(result["matched"], 1, "query: {text}");
            assert_eq!(result["rows"][0]["id"], "unicode");
        }
        assert_eq!(
            query(&mut picker, "untruncated", "all")["rows"][0]["id"],
            "hidden"
        );
        let scoped = query(&mut picker, "alpha", "window");
        assert_eq!(scoped["total"], 1);
        assert_eq!(scoped["matched"], 0);
    }

    #[test]
    fn mac_picker_caps_results_without_losing_total_or_matches() {
        let rows: Vec<Value> = (0..5000)
            .map(|index| {
                json!({"id":format!("id-{index}"),
            "kind":"pane","title":format!("project-{index:04}")})
            })
            .collect();
        let fixture = Fixture::new(json!(rows));
        let mut picker = fixture.picker();
        let result = picker.request(&json!({"id":55,"type":"open"}));
        assert_eq!(result["id"], 55);
        assert_eq!(result["total"], 5000);
        assert_eq!(result["matched"], 5000);
        assert_eq!(result["rows"].as_array().unwrap().len(), MAX_ROWS);
        assert_eq!(result["rows"][0]["id"], "id-0");
        assert_eq!(
            query(&mut picker, "project-4999", "pane")["rows"][0]["id"],
            "id-4999"
        );
        // Querying never rereads the fixture or performs a Rex request.
        fs::remove_file(&fixture.0).unwrap();
        assert_eq!(query(&mut picker, "project-4999", "pane")["matched"], 1);
    }

    #[test]
    fn mac_picker_refresh_removes_stale_targets_and_fixture_never_activates() {
        let fixture = Fixture::new(json!([{"id":"old","kind":"pane","title":"old"}]));
        let mut picker = fixture.picker();
        picker.request(&json!({"id":1,"type":"open"}));
        let response = picker.request(&json!({"id":2,"type":"activate","target_id":"old"}));
        assert!(response["message"]
            .as_str()
            .unwrap()
            .contains("never activates"));
        fixture.write(json!([{"id":"new","kind":"pane","title":"new"}]));
        let refreshed = picker.request(&json!({"id":3,"type":"refresh"}));
        assert_eq!(refreshed["rows"][0]["id"], "new");
        let stale = picker.request(&json!({"id":4,"type":"activate","target_id":"old"}));
        assert!(stale["message"]
            .as_str()
            .unwrap()
            .contains("no longer available"));
        fs::write(&fixture.0, b"invalid").unwrap();
        assert_eq!(
            picker.request(&json!({"id":5,"type":"open"}))["type"],
            "error"
        );
        assert_eq!(
            query(&mut picker, "", "all")["message"],
            "Open the picker first"
        );
    }

    #[test]
    fn mac_picker_rejects_ambiguous_or_disconnected_clients() {
        let local = |id: &str| {
            json!({"client_id":id,"info":{"kind":"app","platform":"macos"},
            "principal":{"kind":"peer","transport":"unix"}})
        };
        let mut old = local("old");
        old["connection_state"] = json!("lost");
        let clients = json!({"clients":[local("one"),local("two"),old]});
        assert!(choose_client(&clients, "")
            .unwrap_err()
            .contains("Multiple"));
        assert_eq!(choose_client(&clients, "two").unwrap(), "two");
        assert!(choose_client(&clients, "old").is_err());
        assert!(choose_client(&clients, "unknown").is_err());
        assert_eq!(
            choose_client(&json!({"clients":[local("one")]}), "").unwrap(),
            "one"
        );
        assert!(choose_client(&json!({"clients":[]}), "").is_err());
        let mut nonlocal = Vec::new();
        let mut ios = local("ios");
        ios["info"]["platform"] = json!("ios");
        nonlocal.push(ios);
        let mut remote = local("remote");
        remote["principal"]["transport"] = json!("tcp");
        nonlocal.push(remote);
        let mut forwarded = local("forwarded");
        forwarded["principal"]["path"] = json!(["login-server"]);
        nonlocal.push(forwarded);
        let mut cli = local("cli");
        cli["info"]["kind"] = json!("cli");
        nonlocal.push(cli);
        for client in nonlocal {
            let clients = json!({"clients":[local("one"),client]});
            assert_eq!(choose_client(&clients, "").unwrap(), "one");
            assert!(choose_client(&clients, client["client_id"].as_str().unwrap()).is_err());
        }
        let mut direct = local("direct");
        direct["principal"]["path"] = json!([]);
        assert_eq!(
            choose_client(&json!({"clients":[direct]}), "").unwrap(),
            "direct"
        );
    }

    #[test]
    fn mac_picker_rejects_invalid_scope_duplicate_ids_and_oversized_requests() {
        let fixture = Fixture::new(json!([{"id":"one","kind":"pane","title":"one"}]));
        let mut picker = fixture.picker();
        picker.request(&json!({"id":1,"type":"open"}));
        assert_eq!(query(&mut picker, "", "invalid")["type"], "error");
        assert_eq!(
            picker.request(&json!({"id":2,"type":"query","query":"","scope":1}))["type"],
            "error"
        );
        assert_eq!(
            query(&mut picker, &"x".repeat(MAX_QUERY + 1), "all")["type"],
            "error"
        );
        assert_eq!(
            picker.request(&json!({"id":-1,"type":"refresh"}))["type"],
            "error"
        );
        fixture.write(json!([{"id":"one","kind":"pane","title":"one"},{"id":"one","kind":"pane","title":"two"}]));
        assert_eq!(
            picker.request(&json!({"id":3,"type":"refresh"}))["type"],
            "error"
        );
        let mut output = Vec::new();
        run_protocol(
            &mut picker,
            &mut io::Cursor::new(vec![b'x'; MAX_REQUEST + 500]),
            &mut output,
        )
        .unwrap();
        let response: Value = serde_json::from_slice(&output).unwrap();
        assert!(response["message"].as_str().unwrap().contains("64 KiB"));
    }
}
