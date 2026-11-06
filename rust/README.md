# imux — the shared interdimux core

The Rust core supplies shared data processing, rendering, and a persistent
fzf navigator for tmux and Rex. The existing tmux integration also uses it to
parse dumps, size columns, resolve commands and git branches, and render rows.
That processing was ~181 ms of in-process Bash before the Rust implementation.

    cargo build --release --locked      # -> target/release/imux

## Shared navigator

`imux pick --backend tmux|rex` starts fzf, owns the native target records for
the invocation, and activates the selected session, window, or pane. Both
backends use the same Rust model, palette presentation, fzf process control,
selection, and cancellation behavior. Collection and native activation are
adapters. The shared navigator requires fzf 0.74 or newer; the existing full
tmux frontend retains its separate fzf version gates.

```sh
# Inside tmux; origin and socket defaults come from the tmux environment.
./target/release/imux pick --backend tmux

# Inspect candidate rows without opening fzf or switching a target.
./target/release/imux list --backend tmux

# Rex's Lua binding supplies the exact initiating client and origin IDs.
./target/release/imux pick --backend rex \
  --client CLIENT_ID --session SESSION_ID --window WINDOW_ID --block BLOCK_ID
```

Rex runs the navigator in a floating terminal created by its Lua binding.
`--block` identifies the originating pane; `--picker-block` identifies the
temporary picker and defaults to `REX_BLOCK`. Pass `--server ENDPOINT` when
selecting a Rex server explicitly. Standalone invocation uses the official CLI
for collection and activation. Hosted invocation instead accepts `--snapshot
FILE --result FILE`: it reads the coordinator's snapshot and atomically writes
one versioned selection, cancellation, or error result, without starting Rex's
CLI. Neither path requires tmux, Python, or jq.

Direct numbered Rex jumps collect only the session catalog and MRU history,
preserving the picker's ordering and hidden-session rules without inspecting
every terminal. A direct next-agent shortcut that finds no match leaves focus
alone and skips the activation CLI call.

To open the hosted float from the Rex CLI, pass the persistent app's full ID
as an action argument (find it with `rex client ls`):

```sh
rex do interdimux -s SESSION_ID -b BLOCK_ID client_id=APP_CLIENT_ID
```

Rex's `-C` option routes queued client actions, but a configuration action's
`ctx.client_id` still identifies the calling CLI. Interdimux requires the
explicit `client_id` argument for CLI launches so its detached coordinator
can restore focus after that CLI exits. App key bindings and palette actions
supply their app identity automatically. The same argument applies to the
dashboard, action modes, next-agent action, and optional session-jump actions.

Tmux also accepts `--client CLIENT_TTY`, `--block %PANE`, and
`--socket SOCKET_PATH`. Launchers should pass the initiating client explicitly
when more than one client is attached. Defaults use `INTERDIMUX_CLIENT`,
`TMUX_PANE`, and the socket in `TMUX`. The `list` command takes the same backend
and origin options as `pick` and does not activate targets.

The shared navigator now includes scoped raw filtering, previews, directory
discovery, find-or-create, rename, confirmed close, zoom, swap, send, and
refresh. `Ctrl+g` opens its actions menu and health information. `Alt+n`,
`Alt+v`, and `Alt+h` create a window or split right/down. It keeps the same fzf
process, query, and row position across in-place actions. Opaque tokens are
never reused after refresh; removed objects cannot silently become new ones.
The TPM plugin continues to open its original Bash frontend by default. The
shared command is opt-in for tmux during this migration. See the key table in
the main README.

Native frontends read `INTERDIMUX_*` environment settings. They do not import
tmux's `@interdimux-*` options; those continue to configure the TPM frontend.
Set the corresponding environment values for Rex's server or native tmux
launcher. `INTERDIMUX_SHOW_PREVIEW=on` is accepted as the legacy spelling of
`INTERDIMUX_PREVIEW=on`; an explicit `INTERDIMUX_PREVIEW` takes precedence.

`INTERDIMUX_THEME=auto` (the default) follows Rex's terminal colors and keeps
the warm profile for native tmux. Set `terminal` or `warm` to choose explicitly.
The terminal profile inherits foreground/background, uses Gruvbox Material
orange (`#e78a4e`) for the primary accent and ANSI indices for other colors,
including previews, nested dialogs and the dashboard. Selection uses
a block pointer and bold text, preserving column colors and the terminal
background. `INTERDIMUX_COLOR_ACCENT`,
`INTERDIMUX_COLOR_PATH`, `INTERDIMUX_COLOR_GIT`, `INTERDIMUX_COLOR_SSH`,
`INTERDIMUX_COLOR_EDITOR`, `INTERDIMUX_COLOR_DANGER`, `INTERDIMUX_COLOR_TREE`
and `INTERDIMUX_COLOR_SEPARATOR` override individual accents with `#rrggbb`,
`0`–`255`, or `-1`/`default`. Invalid overrides use the profile default. The
original TPM frontend retains its existing palette and tmux options.

Native action modes use `pick --mode switch|kill|rename|zoom|swap|send|dirs|agents|schedule|jobs|doctor|dashboard`.
Enter repeats the selected action; Escape ends the mode. The dashboard provides
the same entries with counts and backend capability checks. Agent views use
exact shared state records, retain the tree and support the ordinary scopes.
Attention defaults to `approve,input,error,done,idle`: blocking requests, failed
or completed responses, and agents ready for your next message. Working agents
and agents with no reported state are excluded. The dashboard count, Agents
picker and next-agent shortcut use the same definition. `pick --agent-states`
and direct modes' `--states` can narrow it; `approve,input` selects only blocking
requests. The unfiltered `agents` listing still includes all known agent states.
Contextual hints follow the current target and width. Directory suggestions in
the main list come only from bounded recent history; scans and zoxide queries
remain explicit actions.

```sh
imux agents --backend rex [ORIGIN_OPTIONS] --count --states approve,input
imux agent-next --backend rex [ORIGIN_OPTIONS]
imux jump --backend rex [ORIGIN_OPTIONS] 2
imux connect-dir --backend rex [ORIGIN_OPTIONS] ~/code/project
imux session-name-for --backend rex [ORIGIN_OPTIONS] ~/code/project
imux send-in --backend rex [ORIGIN_OPTIONS] 30 . 'make test'
imux send-at --backend rex [ORIGIN_OPTIONS] '17:30' block:ID 'C-c'
imux jobs list
imux jobs cancel ID
imux jobs output ID
imux doctor --backend rex [ORIGIN_OPTIONS]
imux doctor --ack
```

Replace `[ORIGIN_OPTIONS]` with the client/session/window/pane flags above;
tmux uses its corresponding flags. These direct commands also accept their
legacy `--agents`, `--agent-next`, `--jump`, `--connect-dir`, `--send-in`,
`--send-at`, `--sched-list` and `--sched-cancel` spellings. `jobs --backend ...`
opens the job manager; `jobs list` prints JSON records.

Native scheduling is a shared one-shot Rust worker and private versioned store
under `${XDG_STATE_HOME:-~/.local/state}/interdimux/jobs/`. Workers detach from the
picker's terminal. Resolved times support relative shorthand, clocks, tomorrow
and ISO dates; additional `at` time expressions can be parsed when `at` exists
without submitting an OS job. Cancellation is checked again at the atomic
delivery claim. Guards bind a job to the original server incarnation and one
native pane; sends never focus the app or broadcast. `sent` means input was
delivered, not that the shell command finished. Logs describe delivery, while
command output stays in the target pane. Jobs interrupted by machine shutdown
are reported instead of being automatically replayed. The legacy Bash queue is
separate and keeps its existing `at` behavior.

Health checks include backend capabilities, configuration, and retained native
errors in `interdimux/errors.log`. `doctor --ack` marks the existing errors as
seen without deleting history; a later failure becomes a problem again.

New sessions use `startup.conf`, `.interdimux-startup`, then
`INTERDIMUX_STARTUP_COMMAND`; `INTERDIMUX_HYDRATE=off` disables delivery. Every
line is literal text, including strings resembling key names. Existing
sessions are activated without repeating startup commands. Custom project
markers and shared recent/zoxide history follow the original directory picker.

### Rex hosting

The host integration belongs to interdimux at `integrations/rex.lua`. Load it
from Rex's configuration with the checkout path:

```lua
local interdimux_root = "/path/to/interdimux"
dofile(interdimux_root .. "/integrations/rex.lua").setup {
  root = interdimux_root,
  dashboard_ui = "terminal", -- Ctrl+b g opens the dedicated hotkey menu
}
```

The default `dashboard_ui="terminal"` opens a dedicated grouped hotkey menu
with no search field. It runs before any navigator tree is created, so Escape
or `q` returns directly to the originating pane. Selecting a tool starts its
existing shared Rust mode. The terminal dashboard is also available with
`imux pick --mode dashboard`.

The optional `dashboard_ui="native"` binds `Ctrl+b g` directly to Rex's command palette
(`Cmd+Shift+P`). Interdimux actions have an `Interdimux:` title prefix, an
Interdimux category, and `imux` search keywords. It is the app-wide palette;
the installed API exposes no initial query or custom-palette provider.
No terminal or Rust picker starts behind the palette; dismissal returns to the
original pane. Choosing a tool launches its existing shared Rust mode.

Build the release binary before using the binding, then run `rex config check`
and reload the running app with its **Reload Config** action (`rex -C CLIENT do
client.config.reload`). A server-only `rex config reload` can leave the Mac app
using a cached keymap for newly added shortcuts. The integration registers
`interdimux` and `ctrl+b>f`, captures the originating client/session/window/pane, and starts one
detached Rex CLI coordinator. That Lua coordinator supplies the snapshot and
opens a centered float. The terminal starts the binary directly with
`shell="none"` and login disabled, so it does not print a login banner. The
coordinator observes terminal completion to apply the selection and tear down
the float. Enter and Escape start no additional CLI process.

The float uses Rex's default font. A versioned `ready.json` gate waits only for
the initial snapshot to be written; it never waits for GUI ownership, font
changes, or stable-grid samples. Creating the float before collecting metadata
overlaps GUI startup with collection. Initial size hints use the origin window
and cached popup metrics, with exact reuse when the source geometry matches.
An optional background observer updates a bounded per-client size cache under
`${XDG_STATE_HOME:-~/.local/state}/interdimux/rex-picker-*.json`. On a cold cache
or changed geometry Rex may refit once; subsequent matching opens use its exact
grid. Observation errors cannot delay or dismiss the picker. Captured snapshots
without a gate still start immediately.

The finder retains its last frame until the disposable terminal closes.
Ordinary inline tmux invocation still restores the caller's original screen.
The UI uses a compact indented tree with one line per target. A single-pane
window is one combined row targeting that pane; multi-pane windows have
indented pane children. Search matches the displayed, width-limited fields.
Filtering does not recollect Rex state or scan project directories. Errors are published
to the coordinator before the acknowledgement prompt, but it waits for the
terminal program to exit before closing the float.

Explicit actions use a private framed Unix socket between a small helper and
the same Rust controller; fzf remains alive. The native Rex coordinator polls
only its private action mailbox, executes operations on its existing connection,
and publishes atomic responses and snapshots. Refresh asks for new data; normal
action reloads reuse the snapshot already published with that action. Preview
captures are bounded and briefly cached. Controller sockets block while idle.

Hosted Rex pickers refresh live by default. Native layout, process, directory,
title and program-status events update the open tree and preview, preserving
the query and the selected target while it still exists. Background row reloads
wait for a pause in typing. Bursts are coalesced
into at most four collections per second. A process or status change refreshes
only the affected pane's metadata; layout changes refresh the affected session
views while reusing existing pane metadata. New panes always collect fresh
metadata. Mutations refresh their affected sessions and merge any pending
terminal events; explicit refresh still recollects everything. Stale layout
revisions and the picker's own terminal events are ignored. There is no periodic
backend scan while idle, and each event uses the
existing coordinator connection. Rust checks the local snapshot file every
100 ms and updates fzf through a private Unix socket only after publication.
Set `INTERDIMUX_LIVE_REFRESH=off` in the Rex server environment to disable live
refresh; `Ctrl+r` still performs a full refresh. Standalone Rex and tmux
invocations retain explicit refresh.

The three fields are identity, path/context, and command. Name+command is the
default; `INTERDIMUX_MATCH_SCOPE=name|path|cmd|all|name+cmd` changes it.
Their maximum display widths are 40, 44, and 80 terminal cells, respectively,
and narrow layouts shrink those limits. Names and commands end in `…` when
clipped; paths begin with `…` so the tail stays visible. Unicode clusters and
colours are preserved. Search uses the displayed text; actions and previews
still receive the original records and native IDs.
`INTERDIMUX_RAW=off` uses ordinary filtering, and `INTERDIMUX_PREVIEW=on` opens
the preview initially. `INTERDIMUX_PROJECT_DIRS` supplies colon-separated
directory roots. Directory browsing and bounded deep scanning run only after
explicit actions; project previews show safe README excerpts and directory
entries. A matched session directory switches to that existing session.

Rex uses native program-status reports to show `approve`, `input`, `working`,
`idle`, `done`, and `error` through the same agent formatter as tmux. A reported owner
must match the foreground PID and name; stale reports are ignored. Hosted
agent rows use the current process's verified terminal conversation title as
the command field, followed by status. Explicit program-status titles are a
fallback; generic titles fall back to the process name. Message-only status
reports do not replace a conversation title. Terminal previews also show the
verified foreground program's task title, status message and percentage when
reported, including programs that are not coding agents. These details update
with native status events and stay within the preview's available space.
Hosted snapshots prove local
process provenance before reading argv or git metadata. Standalone collection
requires the server to identify its exact CLI process as a local Unix peer.
Rex MRU and explicit creation-directory associations persist under
`${XDG_STATE_HOME:-~/.local/state}/interdimux/rex-mru.json`.

Rex zoom is applied after the float closes so focusing the picker cannot undo
it. Window swaps reorder tabs; pane swaps exchange panes. Both stay within one
Rex session. Rex has no tmux-style client detach. The native shared scheduler
supports both backends; the legacy tmux frontend retains its original queue.

Validation from the checkout root:

```sh
cargo test --manifest-path rust/Cargo.toml --locked
bash tests/test_rex_lua.sh
```

The Rust tests include real fzf in private PTYs and isolated native tmux servers.
No live Rex server is needed for that suite. Live Rex validation uses separate
disposable sessions; it never sends test input into existing user panes.
The regular test runner and Linux CI also run the Rex Lua suites, including
mailbox, geometry, lifecycle, history, bindings, event coalescing, incremental
snapshot costs and exact-target operations.

For reproducible rendering measurements, build both revisions in release mode,
then run on an otherwise idle machine:

```sh
python3 rust/tests/bench_native.py --baseline /tmp/before/imux \
  --candidate rust/target/release/imux --repetitions 20 --json /tmp/native-bench.json
cargo test --manifest-path rust/Cargo.toml --release --locked \
  presentation::tests::rendering_benchmark -- --ignored --nocapture
```

The PTY benchmark alternates the binaries, uses synthetic 12- and 500-pane
snapshots with owned local processes, and checks actual fzf frames for startup,
query filtering, live updates and resize. It records medians, p95s and raw
samples; timings do not gate CI. `--enrichment metadata` isolates rendering
from local process/Git enrichment. The ignored Rust benchmark separately
measures snapshot preparation and repeated rendering at several widths for
100/1,000 panes. Neither benchmark measures Rex GUI creation or GPU paint.

The November 2026 theme/rendering pass passed 360 Rust tests, eight Lua suites,
31 legacy corpus checks, and the Rust 1.74 unit suite. Light and dark palette
simulations covered captured fzf output for the picker, previews, dashboard and
dialogs. A release comparison used 20 alternating paired runs per fixture,
after two warmups per binary. All 80 measured runs passed their frame checks.
Median milliseconds on the development machine were:

| Visible result | 12 panes, before → after | 500 panes, before → after |
| --- | ---: | ---: |
| First frame | 42.4 → 42.4 | 56.2 → 55.1 |
| Query result | 8.6 → 7.5 | 11.4 → 12.4 |
| First live update | 589.3 → 96.7 | 615.1 → 125.9 |
| Steady live update | 91.7 → 101.5 | 125.0 → 120.5 |
| Complete resized layout | 33.6 → 32.9 | 47.6 → 44.3 |

The large first-update improvement comes from retrying an acknowledged typing
deferral promptly instead of waiting for the lost-command watchdog. Background
transforms keep collection out of fzf's synchronous input path. Ordinary startup,
query and steady-update timings remain broadly similar; the 100 ms snapshot
watcher also contributes to update latency. First-frame terminal output fell
by 12–14%. These figures exclude Rex GUI creation, producer event coalescing,
and GPU paint.

Five alternating in-process benchmark runs measured repeated rendering at
0.836 → 0.381 ms for 100 panes and 8.432 → 3.537 ms for 1,000 panes. Parsed ANSI
spans, grapheme boundaries and width maxima are cached per snapshot. Preparing
that cache costs more time and memory: preparation rose from 0.721 → 1.003 ms
and 6.405 → 9.281 ms respectively. Summing each run's preparation and rendering
medians gives about 13% lower initial processing time, while repeated rendering
is 55–58% faster. Local process/Git work is excluded from this CPU benchmark.

Earlier live Rex action/scheduling validation measured warm native popups at
about 119 ms median. A 10,000-record job history did not affect ordinary popup
startup; its explicit Jobs listing still takes about
550 ms. Changed-record detection cut idle CPU for 100 scheduled workers by 65%
without changing their quarter-second cancellation cadence. Direct action
modes collect one backend snapshot instead of two.

The binary defaults to `<root>/rust/target/release/imux`; `INTERDIMUX_BIN` or
the setup option `binary` can override it. `INTERDIMUX_FZF_BIN` selects fzf
explicitly. `INTERDIMUX_REX_BIN` selects the coordinator CLI and standalone Rex
transport; otherwise these search PATH and the installed Rex app bundle. The
coordinator uses native Lua APIs over its existing connection. The host adds
`/opt/homebrew/bin` and `/usr/local/bin` to the terminal's PATH. Environment
overrides must be visible to the Rex server, which reads the
configuration and creates the terminal. Errors remain visible until Enter.

## Existing tmux renderer integration

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

## Legacy gather3 boundary

For the existing tmux frontend, **Bash owns tmux and config; Rust owns
rendering**. The `pick` command additionally owns the shared navigator.

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
