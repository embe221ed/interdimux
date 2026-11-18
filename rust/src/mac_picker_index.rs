//! Local search columns survive remote publications. Physical row indices for
//! local sessions and projects stay stable until the next local refresh.
use super::{collapse_single_panes, Candidate, Hierarchy, Picker, SESSION_NAME_BONUS};
use nucleo::pattern::AtomKind;
use nucleo::{Config, Matcher, Nucleo};
use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

#[derive(Default)]
struct RowSet {
    rows: Vec<Candidate>,
    ids: HashMap<String, usize>,
    tree: Hierarchy,
}

impl RowSet {
    fn prepare(mut rows: Vec<Candidate>) -> Result<Self, String> {
        let mut ids = HashMap::with_capacity(rows.len());
        for (index, row) in rows.iter().enumerate() {
            if row.id.is_empty() || ids.insert(row.id.clone(), index).is_some() {
                return Err("Picker records must have distinct, nonempty IDs".into());
            }
        }
        let mut tree = Hierarchy::build(&rows, &ids)?;
        if rows
            .iter()
            .enumerate()
            .any(|(index, row)| row.kind == "window" && tree.children[index].len() == 1)
        {
            rows = collapse_single_panes(rows, &tree);
            ids.clear();
            ids.extend(rows.iter().enumerate().map(|(i, row)| (row.id.clone(), i)));
            tree = Hierarchy::build(&rows, &ids)?;
        }
        for row in &mut rows {
            row.operations = row.available_operations();
        }
        Ok(Self { rows, ids, tree })
    }
}

fn index_rows(matcher: &mut Nucleo<usize>, rows: &[Candidate], offset: usize) {
    matcher.restart(true);
    let injector = matcher.injector();
    for (index, row) in rows.iter().enumerate() {
        injector.push(offset + index, |_, columns| {
            columns[0] = row.search.as_str().into();
            columns[1] = row.name_search.as_str().into();
            columns[2] = row.path.as_str().into();
            columns[3] = row.command_search.as_str().into();
        });
    }
}

impl Picker {
    pub(super) fn replace(&mut self, rows: Vec<Candidate>) -> Result<(), String> {
        let (mut local, remote) = if rows.iter().any(|row| row.remote_session.is_some()) {
            rows.into_iter()
                .partition(|row| row.remote_session.is_none())
        } else {
            (rows, Vec::new())
        };
        local.sort_by_key(|row| row.kind == "directory");
        let local = RowSet::prepare(local)?;
        let remote = RowSet::prepare(remote)?;
        if remote.ids.keys().any(|id| local.ids.contains_key(id)) {
            return Err("Picker records must have distinct, nonempty IDs".into());
        }

        self.local_len = local.rows.len();
        self.directory_count = local
            .rows
            .iter()
            .rev()
            .take_while(|r| r.kind == "directory")
            .count();
        self.attention_count = local
            .rows
            .iter()
            .filter(|row| row.attention())
            .filter_map(|row| row.pane_id.as_deref())
            .collect::<HashSet<_>>()
            .len();
        self.dashboard = super::dashboard::counts(&local.rows, self.attention_count);
        index_rows(&mut self.matcher, &local.rows, 0);
        self.rows = local.rows;
        self.by_id = local.ids;
        self.hierarchy = local.tree;
        self.install_remote_rows(remote);
        Ok(())
    }

    pub(super) fn replace_remote_rows(&mut self, rows: Vec<Candidate>) -> Result<(), String> {
        let remote = RowSet::prepare(rows)?;
        if remote
            .ids
            .keys()
            .any(|id| self.by_id.get(id).is_some_and(|&i| i < self.local_len))
        {
            return Err("Picker records must have distinct, nonempty IDs".into());
        }
        self.install_remote_rows(remote);
        Ok(())
    }

    fn install_remote_rows(&mut self, remote: RowSet) {
        let offset = self.local_len;
        if self.rows.len() == offset && remote.rows.is_empty() {
            self.remote_matcher = None;
            return;
        }
        if remote.rows.is_empty() {
            self.remote_matcher = None;
        } else {
            let matcher = self
                .remote_matcher
                .get_or_insert_with(|| Nucleo::new(Config::DEFAULT, Arc::new(|| {}), Some(1), 4));
            matcher.pattern.clone_from(&self.matcher.pattern);
            index_rows(matcher, &remote.rows, offset);
        }

        for row in self.rows.drain(offset..) {
            self.by_id.remove(&row.id);
        }
        self.rows.extend(remote.rows);
        self.by_id
            .extend(remote.ids.into_iter().map(|(id, i)| (id, offset + i)));

        let tree = &mut self.hierarchy;
        tree.parents.truncate(offset);
        tree.children.truncate(offset);
        tree.parents.extend(
            remote
                .tree
                .parents
                .into_iter()
                .map(|p| p.map(|i| i + offset)),
        );
        tree.children
            .extend(remote.tree.children.into_iter().map(|mut children| {
                for i in &mut children {
                    *i += offset;
                }
                children
            }));
        // The blank picker shows local sessions, remote sessions, then projects.
        // Both traversal vectors end in the same standalone directory roots.
        for (order, new) in [
            (&mut tree.roots, remote.tree.roots),
            (&mut tree.preorder, remote.tree.preorder),
        ] {
            let end = order.len() - self.directory_count;
            let start = order[..end].partition_point(|&index| index < offset);
            order.splice(start..end, new.into_iter().map(|i| offset + i));
        }
    }
}

#[derive(Clone, Copy)]
struct Hit<'a> {
    index: usize,
    columns: &'a [nucleo::Utf32String],
    bonus: bool,
}

// Both lists are already sorted. Find each insertion point from the last one,
// scoring only the candidates needed to bracket it. A single matching host
// among thousands of projects therefore costs logarithmically many scores.
fn merge<T: Copy, K: Ord>(left: Vec<T>, right: Vec<T>, key: &mut impl FnMut(&T) -> K) -> Vec<T> {
    if left.is_empty() {
        return right;
    }
    if right.is_empty() {
        return left;
    }
    let (short, long) = if left.len() < right.len() {
        (left, right)
    } else {
        (right, left)
    };
    let mut rest = long.as_slice();
    let mut merged = Vec::with_capacity(short.len() + rest.len());
    let mut short = short.as_slice();
    while !short.is_empty() && !rest.is_empty() {
        let hit = short[0];
        short = &short[1..];
        let needle = key(&hit);
        let mut end = 1;
        while end < rest.len() && key(&rest[end]) < needle {
            end *= 2;
        }
        let bracket = &rest[..rest.len().min(end + 1)];
        let split = bracket.partition_point(|item| key(item) < needle);
        merged.extend_from_slice(&rest[..split]);
        merged.push(hit);
        rest = &rest[split..];
    }
    merged.extend_from_slice(short);
    merged.extend_from_slice(rest);
    merged
}

pub(super) fn rank_matches(
    local: &Nucleo<usize>,
    remote: Option<&Nucleo<usize>>,
    rows: &[Candidate],
    scorer: &mut Matcher,
    prefer_session_names: bool,
    column: usize,
    in_scope: impl Fn(&Candidate) -> bool,
) -> Vec<usize> {
    let local = local.snapshot();
    let remote = remote.map(Nucleo::snapshot);
    let pattern = local.pattern();
    let has_projects = prefer_session_names
        && local
            .matched_items(..)
            .any(|item| rows[*item.data].kind == "directory" && in_scope(&rows[*item.data]));
    if !has_projects && remote.map_or(true, |s| s.matched_item_count() == 0) {
        return local
            .matched_items(..)
            .map(|item| *item.data)
            .filter(|&i| in_scope(&rows[i]))
            .collect();
    }
    let name = has_projects.then(|| {
        let mut name = pattern.column_pattern(column).clone();
        for atom in &mut name.atoms {
            if atom.kind == AtomKind::Fuzzy {
                atom.kind = AtomKind::Substring;
            }
        }
        name
    });

    // Nucleo already sorted each host index. A fixed bonus for contiguous
    // session names preserves order within each of these four runs.
    let mut runs: [[Vec<Hit>; 2]; 2] = Default::default();
    for (host, snapshot) in runs.iter_mut().zip(std::iter::once(local).chain(remote)) {
        for item in snapshot.matched_items(..) {
            let index = *item.data;
            let row = &rows[index];
            if !in_scope(row) {
                continue;
            }
            let bonus = row.kind == "session"
                && name.as_ref().is_some_and(|p| {
                    p.score(item.matcher_columns[1].slice(..), scorer)
                        .is_some_and(|s| s > 0)
                });
            host[usize::from(bonus)].push(Hit {
                index,
                columns: item.matcher_columns,
                bonus,
            });
        }
    }
    let mut key = |hit: &Hit<'_>| {
        let score = pattern.score(hit.columns, scorer).expect("completed match");
        let length: usize = hit.columns.iter().map(|col| col.len()).sum();
        // Original insertion order is local sessions, remote sessions, then projects.
        (
            Reverse(score + if hit.bonus { SESSION_NAME_BONUS } else { 0 }),
            !hit.bonus,
            length,
            rows[hit.index].kind == "directory",
            hit.index,
        )
    };
    let [[local, preferred_local], [remote, preferred_remote]] = runs;
    let ordinary = merge(local, remote, &mut key);
    let preferred = merge(preferred_local, preferred_remote, &mut key);
    merge(ordinary, preferred, &mut key)
        .into_iter()
        .map(|hit| hit.index)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::merge;

    #[test]
    fn one_remote_hit_among_many_projects_needs_only_logarithmic_rescoring() {
        let projects = (0..24_000).step_by(2).collect();
        let mut scores = 0;
        let merged = merge(projects, vec![19_999], &mut |&n| {
            scores += 1;
            n
        });
        assert!(merged.windows(2).all(|pair| pair[0] < pair[1]));
        assert_eq!(merged[10_000], 19_999);
        assert!(scores < 40, "scored {scores} items for one remote hit");
    }
}
