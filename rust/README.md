# imux — the interdimux core

The heavy half of interdimux: parsing the tmux dumps, sizing the columns,
resolving commands and git branches, and rendering the rows. This is the part
that was ~181 ms of in-process bash.

    cargo build --release      # -> target/release/imux

`scripts/interdimux.sh` picks the binary up automatically from
`rust/target/release/imux`. Set `INTERDIMUX_BIN=/path/to/imux` to use one
installed elsewhere — for the popups, in the tmux server's environment
(`tmux set-environment -g INTERDIMUX_BIN …`) — or `INTERDIMUX_USE_RUST=off` to
force the bash renderer. A binary whose output is not rows is not trusted: the
list falls back to bash.

The plugin runs that build itself. When cargo is on the tmux server's PATH (or
in `$CARGO_HOME/bin`, `~/.cargo/bin` by default) and the binary is missing or
older than `src/` or `Cargo.toml`, `interdimux.tmux` starts it as a tmux job
(`run-shell -b`), so loading the plugin never waits for it. It is niced,
`--locked` so the checkout's `Cargo.lock` is never rewritten, and has
`CARGO_TARGET_DIR` pinned to `rust/target`. One build at a time (a lock in
`target/`), output in `$XDG_STATE_HOME/interdimux/build.log`, and a status-line
message at the end. A failed build is remembered in `target/` with the cargo it
failed on (path and `--version`) and not repeated on every load: it runs again
once `src/`, `Cargo.toml` or `Cargo.lock` is newer than that failure or cargo
reports another version, and otherwise a day later, without a second message.
`set -g @interdimux-autobuild off` turns it off; it is not
done at all when `INTERDIMUX_BIN` names a binary or `INTERDIMUX_USE_RUST=off`,
since the in-repo build would not be used.

**Rebuild after every update.** Neither TPM's update nor a `git pull` builds
anything; the plugin's own build catches up on the next load when cargo is
there, and a binary named by `INTERDIMUX_BIN` is never rebuilt for you. A
binary that speaks another protocol than the script (below) is refused rather
than trusted: the list falls back to the bash renderer, and the status line and
`$XDG_STATE_HOME/interdimux/errors.log` (which `--doctor` reports) say once
which binary it was and how to rebuild it. One built from older sources that
speak the same protocol is used, and renders as those sources did: only the
build in `rust/target` is compared with `src/`.

## The boundary

**bash owns tmux and config. The binary owns rendering.**

bash performs the single batched tmux query, reads Claude Code's session
registry, resolves every option (env → tmux option → built-in default), and
pipes five sections in on stdin separated by RS (`\x1e`) lines, in the order
sessions / windows / panes / current-target / Claude registry:

* the first four are the tmux query. A pane line ends in `#{pane_id}`,
  `#{pane_title}` and the values of the pane options agent plugins publish —
  one per name in `INTERDIMUX_STATE_OPTS`, in order, each ended by GS
  (`\x1d`), an unset option an empty value. They are last, so a line tmux
  cut short keeps its row;
* the fifth is the registry as `claude_registry_r` read it, one live session
  per line: `<%pane>US<sid>US<word>US<since>` (the pane's shell pid, empty
  when unchecked; a state word; epoch seconds). The binary never opens
  `~/.claude` itself.

Every option is passed explicitly, as `INTERDIMUX_*` variables — the binary
must never re-derive a default, or it will disagree with the bash fallback
whenever an option is unset. Two of them are data, not settings:
`INTERDIMUX_TITLE_RULESET`, the whole rule text (the user's
`@interdimux-title-rules` file, then `DEFAULT_TITLE_RULES`), which `src/titles.rs`
parses exactly as bash does; and `INTERDIMUX_STATE_OPTS`, the option names
whose values the pane lines carry.

The subcommand is the protocol's version: `imux gather3` (`PROTOCOL` in
`src/main.rs`, `IMUX_PROTO` in the script). Bump both with any change to the
framing or to the position of a field. A binary that does not know the name
exits 2 with nothing on stdout — an extra argument or an environment variable
would only be ignored by an old build — so a script and a binary that disagree
on the framing fail closed, in either direction, to the bash renderer. A stale
build of the same protocol is not caught: it renders its own version's layout.

bash keeps its own renderer, so the plugin works with no binary at all.
`tests/test_rust_parity.sh` diffs the two across the configuration space that
changes output, with a bash-vs-bash control on every case.

## Intentional divergences

bash pads columns by *character count*, so a CJK or emoji name — two terminal
cells per character — misaligns every column to its right. The binary uses real
display width. Identical for ASCII, correct where bash was not.

A pane cwd that is not valid UTF-8 is displayed differently: bash writes the raw
byte, the binary U+FFFD. Display only — a window or pane row's spec is its
session and index, never its path. A *directory* row is different, because its
spec IS the path, and fzf hands a selection back with every invalid byte
replaced by U+FFFD: such a row could never be opened. So both renderers skip a
recent/zoxide directory whose name is not valid UTF-8, rather than offer it.

## Measured

Interleaved A/B, same script, binary on vs forced off (9 reps, medians):

| rows | bash total / first row | imux total / first row | speedup |
|---|---|---|---|
| 12  | 37 ms / 26 ms  | 22 ms / 20 ms | 1.7× / 1.3× |
| 57  | 80 ms / 34 ms  | 25 ms / 24 ms | 3.2× / 1.4× |
| 147 | 172 ms / 51 ms | 34 ms / 31 ms | 5.1× / 1.6× |
| 297 | 362 ms / 96 ms | 54 ms / 46 ms | 6.7× / 2.1× |
| 497 | 535 ms / 124 ms| 69 ms / 49 ms | 7.8× / 2.5× |

First-row gains are smaller than total because both pay the same fixed costs —
bash startup and the ~15 ms tmux query, which is IPC and identical in any
language. Note that at 497 rows the binary finishes the *entire* list (69 ms)
faster than bash produces its *first row* (124 ms).
