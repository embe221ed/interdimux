//! Explicit directory discovery. Cached queries never enter this module.
use super::Candidate;
use crate::model::{Snapshot, Target};
use crate::projects::{self, Directory};
use serde_json::Value;
use std::path::Path;

#[derive(Clone, Default)]
pub(super) struct Browser {
    pub base: Option<String>,
    pub loaded: bool,
    pub deep: bool,
    pub fixture_catalog: Vec<Candidate>,
}

fn flag(request: &Value, key: &str) -> Result<bool, String> {
    request
        .get(key)
        .map(|v| {
            v.as_bool()
                .ok_or_else(|| format!("{key} must be a boolean"))
        })
        .transpose()
        .map(|v| v.unwrap_or(false))
}

impl Browser {
    pub fn load(
        &self,
        snapshot: Option<&Snapshot>,
        rows: &[Candidate],
        request: &Value,
        query: &str,
        fixture: bool,
    ) -> Result<(Self, Vec<Candidate>), String> {
        let reset = flag(request, "reset")?;
        let parent = flag(request, "parent")?;
        let deep = flag(request, "deep")?;
        let cached = flag(request, "cached")?;
        flag(request, "reload")?;
        let base_id = request
            .get("base_id")
            .map(|v| v.as_str().ok_or("base_id must be a string"))
            .transpose()?;
        if usize::from(reset) + usize::from(parent) + usize::from(base_id.is_some()) > 1 {
            return Err("Choose one of reset, parent, or base_id".into());
        }
        if cached && (deep || parent || base_id.is_some()) {
            return Err("Cached recents cannot be combined with browsing or deep scanning".into());
        }
        let mut next = self.clone();
        if reset || cached {
            next.base = None;
        }
        if parent {
            let base = next
                .base
                .as_ref()
                .ok_or("Already showing recent directories and project roots")?;
            next.base = Path::new(base)
                .parent()
                .map(|p| p.to_string_lossy().into_owned());
        }
        if let Some(id) = base_id {
            let row = rows
                .iter()
                .find(|row| row.id == id && row.kind == "directory")
                .ok_or("The directory is no longer available; reload projects")?;
            next.base = Some(row.path.clone());
        }
        let needle = query.to_lowercase();
        let entries = if fixture {
            // No filesystem operations, external processes or real history in
            // fixture mode, including explicit deep-scan and parent requests.
            self.fixture_catalog
                .iter()
                .filter(|row| {
                    next.base.as_deref().map_or(true, |base| {
                        row.path == base
                            || if deep {
                                Path::new(&row.path).starts_with(base)
                            } else {
                                Path::new(&row.path).parent() == Some(Path::new(base))
                            }
                    }) && (!deep || query.is_empty() || row.path.to_lowercase().contains(&needle))
                })
                .cloned()
                .collect()
        } else {
            let snapshot = snapshot.ok_or("Open the picker first")?;
            if let Some(base) = &next.base {
                next.base = Some(exact_path(base)?);
            }
            candidates(if cached {
                projects::cached_directories(snapshot)
            } else {
                projects::directories(snapshot, next.base.as_deref(), deep.then_some(query))
            })
        };
        next.loaded = true;
        next.deep = deep;
        Ok((next, entries))
    }
}

/// Recheck the exact cached path; never reinterpret a missing path as a session
/// name, invoke zoxide, or fall back to HOME. Called only on explicit actions.
pub(super) fn exact_path(path: &str) -> Result<String, String> {
    if !Path::new(path).is_absolute()
        || path.chars().any(char::is_control)
        || projects::excluded_network(path)
    {
        return Err("Choose an existing local directory".into());
    }
    let physical = std::fs::canonicalize(path)
        .map_err(|_| "This directory no longer exists; reload projects")?;
    let text = physical
        .to_str()
        .ok_or("The directory path is not valid Unicode")?;
    if projects::excluded_network(text) || !physical.is_dir() {
        return Err("Choose an existing local directory".into());
    }
    Ok(text.into())
}

pub(super) fn candidates(entries: Vec<Directory>) -> Vec<Candidate> {
    entries
        .into_iter()
        .map(|directory| {
            // A reversible byte encoding is stable and collision-free; the UI treats
            // it as opaque and sends it back instead of sending an editable path.
            let mut id = String::with_capacity(10 + directory.path.len() * 2);
            id.push_str("directory:");
            const HEX: &[u8] = b"0123456789abcdef";
            for byte in directory.path.bytes() {
                id.push(HEX[(byte >> 4) as usize] as char);
                id.push(HEX[(byte & 15) as usize] as char);
            }
            let detail = match (directory.project, directory.existing_session.is_some()) {
                (Some(project), true) => format!("{project} · existing session"),
                (Some(project), false) => project.into(),
                (None, true) => "Existing session".into(),
                (None, false) => "Local directory".into(),
            };
            Candidate {
                id,
                kind: "directory".into(),
                directory_visible: true,
                title: directory.label.clone(),
                name: directory.label.clone(),
                name_search: directory.label.clone(),
                search: format!("{} {} {detail}", directory.label, directory.path),
                path: directory.path.clone(),
                current: directory.existing_session.is_some(),
                detail,
                target: Some(Target::Directory {
                    path: directory.path,
                }),
                ..Candidate::default()
            }
        })
        .collect()
}
