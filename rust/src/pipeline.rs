//! Shared data-to-row pipeline for every navigator backend.

use std::process::Child;

use crate::git::GitCache;
use crate::model::{Pane, Row, Snapshot, Target, Window};
use crate::palette::{Palette, RST};
use crate::proc::Resolver;
use crate::text::{age_of, truncate, width};
use crate::widths::Maxima;
use crate::{agent, dirs, palette, render, widths};

pub(crate) struct RenderOptions {
    pub home: String,
    pub palette: Palette,
    pub show_git: bool,
    pub show_full: bool,
    pub preview_on: bool,
    pub mru: bool,
    pub cols: usize,
    pub session_rule: bool,
    pub now: i64,
    pub agents_view: bool,
    pub show_dirs: bool,
    pub dirs_limit: usize,
    pub agent_config: agent::Config,
}

impl RenderOptions {
    pub(crate) fn from_env(snapshot: &Snapshot) -> Self {
        Self {
            home: env_or("HOME", ""),
            palette: Palette::from_env(),
            show_git: env_is("INTERDIMUX_SHOW_GIT_BRANCH", "on"),
            show_full: env_is("INTERDIMUX_SHOW_FULL_COMMAND", "on"),
            preview_on: env_is("INTERDIMUX_SHOW_PREVIEW", "on"),
            mru: env_or("INTERDIMUX_ORDER", "mru") == "mru",
            cols: env_or("INTERDIMUX_COLS", "80").parse().unwrap_or(80),
            session_rule: env_is("INTERDIMUX_SESSION_RULE", "on"),
            now: env_or("INTERDIMUX_NOW", "0").parse().unwrap_or(0),
            agents_view: env_is("INTERDIMUX_VIEW", "agents"),
            show_dirs: env_is("INTERDIMUX_SHOW_DIRS", "on"),
            dirs_limit: env_or("INTERDIMUX_DIRS_LIMIT", "15").parse().unwrap_or(15),
            agent_config: agent::Config::from_env(
                &snapshot.current.host,
                &snapshot.current.host_short,
            ),
        }
    }
}

fn env_is(name: &str, want: &str) -> bool {
    crate::env_text(name) == want
}
fn env_or(name: &str, default: &str) -> String {
    match crate::env_text(name) {
        v if !v.is_empty() => v,
        _ => default.to_string(),
    }
}

#[cfg(test)]
pub(crate) fn render_rows(snapshot: &Snapshot, options: &RenderOptions) -> Vec<Row> {
    let mut rows = Vec::new();
    render_snapshot(snapshot, options, |row| rows.push(row));
    rows
}

#[cfg(test)]
pub(crate) fn render_snapshot(snapshot: &Snapshot, options: &RenderOptions, emit: impl FnMut(Row)) {
    let zoxide = if options.show_dirs {
        dirs::start_zoxide()
    } else {
        None
    };
    render_snapshot_with_zoxide(snapshot, options, zoxide, emit);
}

pub(crate) fn render_snapshot_with_zoxide(
    snapshot: &Snapshot,
    options: &RenderOptions,
    zoxide: Option<Child>,
    mut emit: impl FnMut(Row),
) {
    let mut sessions: Vec<_> = snapshot.sessions.iter().collect();
    let windows = &snapshot.windows;
    let panes = &snapshot.panes;
    let registry = &snapshot.registry;
    let home = &options.home;
    let p = &options.palette;
    let show_git = options.show_git;
    let show_full = options.show_full;
    let preview_on = options.preview_on;
    let mru = options.mru;
    let cols = options.cols;
    let session_rule = options.session_rule;
    let now = options.now;
    let agents_view = options.agents_view;
    let acfg = &options.agent_config;
    let current_session = snapshot.current.session_key.as_str();
    let current_window = snapshot.current.window_key.as_str();
    let current_pane = snapshot.current.pane_key.as_str();
    // ---- measure + compute widths -----------------------------------------
    // Branches are looked up here, before the widths, because whether any row
    // HAS one decides whether the badge is worth path cells.  The cache makes
    // the emit loop's lookups free, so this is the same I/O as before.
    let mut git = GitCache::new();
    let mut mx = Maxima::default();
    for s in &sessions {
        mx.observe_session(&s.name);
    }
    for w in windows {
        mx.observe_window(&w.ordinal, &w.name, &w.path, &home);
        mx.observe_flags(w.zoomed, w.bell, w.activity);
        if show_git {
            mx.observe_branch(&git.branch(&w.path));
        }
    }
    for pn in panes {
        mx.observe_pane(&pn.path, &home);
        if show_git {
            mx.observe_branch(&git.branch(&pn.path));
        }
    }
    let w = widths::compute(mx, cols, preview_on);

    // ---- MRU: most recent first, the CURRENT session moved to the END ------
    // (so Enter on an empty query toggles back to the previous session)
    if mru {
        sessions.sort_by(|a, b| b.last.cmp(&a.last));
        if let Some(i) = sessions.iter().position(|s| s.key == current_session) {
            let c = sessions.remove(i);
            sessions.push(c);
        }
    }

    // ---- group -------------------------------------------------------------
    let mut wins_by_sess: std::collections::HashMap<&str, Vec<&Window>> = Default::default();
    for x in windows {
        wins_by_sess
            .entry(x.session_key.as_str())
            .or_default()
            .push(x);
    }
    let mut panes_by_win: std::collections::HashMap<(&str, &str), Vec<&Pane>> = Default::default();
    for x in panes {
        panes_by_win
            .entry((x.session_key.as_str(), x.window_key.as_str()))
            .or_default()
            .push(x);
    }

    // ---- emit --------------------------------------------------------------
    let mut res = Resolver::new();
    let mut session_dirs: std::collections::HashSet<String> = Default::default();

    let mut marked: std::collections::HashSet<String> = Default::default();
    let cmd_field =
        |cmd: &str, pid: u32, pn: Option<&&Pane>, r: &mut Resolver| -> (String, String) {
            let raw = if show_full {
                r.full_command(pid, cmd)
            } else {
                cmd.replace('\t', " ")
            };
            let (id, opts, title) = pn
                .map(|x| (x.agent_id.as_str(), x.opts.as_str(), x.title.as_str()))
                .unwrap_or(("", "", ""));
            agent::command_field(&raw, pid, id, title, opts, &acfg, &registry, &p, now)
        };

    for s in &sessions {
        // A directory that already has a session is not offered as a D: row:
        // its start directory, and (below) its active window's cwd.
        if !s.path.is_empty() {
            session_dirs.insert(s.path.clone());
        }
        let is_cur = s.key == current_session;
        let (ident, sdisp_full) = render::session_ident(&s.name, is_cur, &w, &p, session_rule);
        let age = age_of(s.last, now);
        let meta = render::session_meta(&s.window_count, s.attached, &age, &p);
        emit(Row {
            identity: ident,
            context: meta,
            command: String::new(),
            target: s.target.clone(),
        });

        let ws = match wins_by_sess.get(s.key.as_str()) {
            Some(v) => v,
            None => continue,
        };
        // the session-name prefix carried on child rows, truncated to PFX_W
        let mut sdisp = sdisp_full.clone();
        if width(&sdisp) > w.pfx {
            sdisp = truncate(&sdisp, w.pfx);
        }

        for (i, x) in ws.iter().enumerate() {
            let last = i + 1 == ws.len();
            let cont = if last { " " } else { "│" };
            let wcur = is_cur && x.key == current_window;
            if x.active && !x.path.is_empty() {
                session_dirs.insert(x.path.clone());
            }
            let mut ident = render::window_ident(&sdisp, &x.ordinal, &x.name, last, wcur, &w, &p);
            let ctx = render::ctx_field(
                &x.path, x.zoomed, x.bell, x.activity, &w, &p, &home, &mut git, show_git,
            );
            // the window row speaks for its active pane: its id, options, title
            let ap = panes_by_win
                .get(&(x.session_key.as_str(), x.key.as_str()))
                .and_then(|ps| ps.iter().rev().find(|pn| pn.active));
            let (cmd, state) = cmd_field(&x.cmd, x.pid, ap, &mut res);
            let pane_rows = x.pane_count > 1
                && panes_by_win.contains_key(&(x.session_key.as_str(), x.key.as_str()));
            // ...on the window row only where no pane rows follow to carry it
            if agents_view && !pane_rows {
                let id = ap.map(|pn| pn.agent_id.as_str()).unwrap_or("");
                if let Some(m) = agent::view_mark(&state, id, &mut marked, &p) {
                    ident = render::with_gutter(&ident, wcur, &m, &p);
                }
            }
            emit(Row {
                identity: ident,
                context: ctx,
                command: cmd,
                target: x.target.clone(),
            });

            if x.pane_count > 1 {
                if let Some(ps) = panes_by_win.get(&(x.session_key.as_str(), x.key.as_str())) {
                    for (j, pn) in ps.iter().enumerate() {
                        let plast = j + 1 == ps.len();
                        let pcur = wcur && pn.key == current_pane;
                        let mut ident = render::pane_ident(
                            &sdisp,
                            &x.ordinal,
                            &pn.ordinal,
                            cont,
                            plast,
                            pcur,
                            &w,
                            &p,
                        );
                        let ctx = render::ctx_field(
                            &pn.path, false, false, false, &w, &p, &home, &mut git, show_git,
                        );
                        let (cmd, state) = cmd_field(&pn.cmd, pn.pid, Some(pn), &mut res);
                        if agents_view {
                            if let Some(m) = agent::view_mark(&state, &pn.agent_id, &mut marked, &p)
                            {
                                ident = render::with_gutter(&ident, pcur, &m, &p);
                            }
                        }
                        emit(Row {
                            identity: ident,
                            context: ctx,
                            command: cmd,
                            target: pn.target.clone(),
                        });
                    }
                }
            }
        }
    }

    // ---- directory rows (the one-list model) -------------------------------
    if options.show_dirs {
        // A malformed limit falls back to the default, matching bash: it now
        // normalises the numeric options up front (a junk value used to make
        // `[ -ge ]` print "integer expression expected" onto the popup), so
        // "off" here would be the two renderers disagreeing again -- this time
        // with the Rust one silently dropping every directory row.
        let limit = options.dirs_limit;
        // ...under whatever spelling (Canon::canon_dir, as bash's emit_dir_rows).
        let mut canon = dirs::Canon::default();
        let taken: std::collections::HashSet<String> =
            session_dirs.iter().map(|s| canon.canon_dir(s)).collect();
        let mut n = 0;
        for d in dirs::candidates(zoxide) {
            if n >= limit {
                break;
            }
            if d.contains('\t') || session_dirs.contains(&d) || taken.contains(&canon.canon_dir(&d))
            {
                continue;
            }
            let base = d.rsplit('/').next().unwrap_or(&d);
            let base = if base.is_empty() { d.as_str() } else { base };
            let ident = render::dir_ident(base, &w, &p);
            let ctx = render::ctx_field(&d, false, false, false, &w, &p, &home, &mut git, show_git);
            let badge = match dirs::project_type(&d) {
                Some(t) => format!("{}{}{}", palette::DIM, t, RST),
                None => String::new(),
            };
            emit(Row {
                identity: ident,
                context: ctx,
                command: badge,
                target: Target::Directory { path: d },
            });
            n += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Current, Session};

    fn target(session: &str, window: Option<&str>, pane: Option<&str>) -> Target {
        Target::Rex {
            session_id: session.into(),
            window_id: window.map(str::to_owned),
            block_id: pane.map(str::to_owned),
        }
    }

    #[test]
    fn duplicate_labels_and_ordinals_never_merge_targets_or_current_markers() {
        let mut snapshot = Snapshot::default();
        let mut expected = Vec::new();
        for key in ["one", "two"] {
            let window_key = format!("window:{}", key);
            let session_target = target(key, None, None);
            let window_target = target(key, Some(&window_key), None);
            expected.push(session_target.clone());
            expected.push(window_target.clone());
            snapshot.sessions.push(Session {
                key: key.into(),
                name: "same label".into(),
                window_count: "1".into(),
                attached: false,
                last: 0,
                path: String::new(),
                target: session_target,
            });
            snapshot.windows.push(Window {
                key: window_key.clone(),
                session_key: key.into(),
                ordinal: "1".into(),
                name: "same window".into(),
                active: true,
                cmd: String::new(),
                path: String::new(),
                pane_count: 2,
                pid: 0,
                zoomed: false,
                bell: false,
                activity: false,
                target: window_target,
            });
            for ordinal in ["1", "2"] {
                let pane_key = format!("pane:{}:{}", key, ordinal);
                let pane_target = target(key, Some(&window_key), Some(&pane_key));
                expected.push(pane_target.clone());
                snapshot.panes.push(Pane {
                    key: pane_key,
                    session_key: key.into(),
                    window_key: window_key.clone(),
                    ordinal: ordinal.into(),
                    name: String::new(),
                    active: ordinal == "1",
                    cmd: "same pane".into(),
                    path: String::new(),
                    pid: 0,
                    agent_id: String::new(),
                    title: String::new(),
                    opts: String::new(),
                    target: pane_target,
                });
            }
        }
        snapshot.current = Current {
            session_key: "two".into(),
            window_key: "window:two".into(),
            pane_key: "pane:two:1".into(),
            ..Current::default()
        };
        let mut options = RenderOptions::from_env(&snapshot);
        options.mru = false;
        options.show_dirs = false;
        options.show_full = false;
        options.show_git = false;
        options.agents_view = false;
        let rows = render_rows(&snapshot, &options);
        assert_eq!(
            rows.iter().map(|r| r.target.clone()).collect::<Vec<_>>(),
            expected
        );
        let marked: Vec<_> = rows
            .iter()
            .enumerate()
            .filter_map(|(i, r)| r.identity.contains('*').then_some(i))
            .collect();
        assert_eq!(marked, [4, 5, 6]);
    }
}
