# interdimux

A portal gun for your tmux sessions.

`interdimux` is a fuzzy tmux navigator for quickly jumping between sessions, windows, and panes with a fast keyboard-driven workflow.

## Features

- Fuzzy switching between sessions, windows, and panes in a single list
- Most-recently-used ordering: the previous session sits on top (empty
  query + `Enter` = toggle between your two latest sessions); the current
  session is parked at the bottom
- Find-or-create: `Enter` on a query that matches nothing creates a session
  with that name (resolved as a path, then via zoxide, then under `$HOME`)
- Scoped fuzzy matching — queries match names and commands, not paths,
  padding, badges, or tree glyphs; cycle the scope with `Ctrl-]`
  (name / path / cmd / all / name+cmd, fzf >= 0.58). The searchable columns
  are the bright ones, and the bright band moves with the scope
- Session groups are ruled off, so a flat list still reads as a tree — at
  the cost of no extra rows
- Warm fzf theme matched to the list palette; popups inherit your
  `popup-border-style` / `popup-border-lines` settings, with titled
  frames on tmux >= 3.3 and a red frame during kill prompts and kill
  mode on tmux >= 3.6 (only the colour is overridden — your border
  lines and background are kept)
- Dashboard as a native tmux menu on tmux >= 3.4 (fzf menu fallback below)
- Proper confirmation dialogs (centered boxes, `y`/`n`/`esc`) instead of raw
  prompts; rename pre-fills the current name with readline editing
- Actions run in place — kill/rename/zoom/swap reload the list without
  restarting fzf, keeping your query and cursor
- Optional live preview with a title line (target, command, path) and a
  window summary for sessions — off by default, toggle with `Ctrl-/`
- Metadata: window count, attached marker `●`, last-used age, zoomed `Z` /
  bell `!` / activity `#` flags, current-target markers
- Git branch display (`‹branch›` badge) with detached HEAD support
- SSH-aware display: highlights `user@host` for SSH/mosh connections
- Editor-aware display: highlights the filename for vim, nvim, emacs, etc.
- Panes only shown for multi-pane windows (keeps the list clean)
- Columns sized to the actual content (longest name / window / path) and
  the popup width, so window names keep their space even under a long
  session name; panes/windows stay aligned across the tree
- Create new sessions from a directory picker
- Key hints in a footer, out of the anchor zone at the top, tiered to the
  width available instead of truncated — and they change with the selection
- A health check in the dashboard, `:checkhealth` style — a popup you can page,
  search and re-run, leading with the verdict
- Dedicated modes for kill, rename, zoom, swap, detach, and send operations
- Configurable key binding, popup size, ordering, preview, and extra fzf flags

## Dependencies

- **`tmux` >= 3.6 — a hard requirement, not a recommendation.** Every row is
  delimited with a raw US byte (`\x1f`) inside a `tmux -F` format, and tmux
  3.5a and older rewrite that byte as the four characters `\037`. The whole row
  then parses as one field, the session name comes out empty, and the picker is
  simply blank. Measured: 3.4 → 0 rows, 3.5a → 0 rows, 3.6 → works. Note that
  Ubuntu 24.04 ships 3.4 and Debian 13 ships 3.5a, so on those you want tmux
  from source or a backport.
- **`fzf` >= 0.74.** Older versions still open a working picker — every feature
  is version-gated and degrades on its own (0.52 full-line highlight, 0.58
  match-scope cycling, 0.61 ghost text, 0.63 the footer hint bar, 0.66 the scope
  highlight, 0.67 the frozen identity column, 0.74 raw filter mode) — but 0.74
  is the only version the test suite exercises, so anything older is untested
  rather than unsupported.
- `bash` >= 4.0
- A UTF-8 locale. The tree glyphs are multibyte and every column width is
  counted in cells; under `LC_ALL=C` the columns misalign. `--doctor` says so.
- `fd` or `find` (for directory picker)
- `at` (optional — the Schedule and Jobs entries; needs its job-runner enabled)
- `zoxide` (optional — feeds the recent tier and find-or-create)

CI builds tmux 3.7b and installs fzf 0.74 rather than using the distro packages,
for exactly these reasons — see [docs/CI.md](docs/CI.md).

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm)

Add to your `~/.tmux.conf`:

```tmux
set -g @plugin 'embe221ed/interdimux'
```

Then press `prefix + I` to install.

### Manual

```bash
git clone https://github.com/embe221ed/interdimux.git ~/.tmux/plugins/interdimux
```

Add to your `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/interdimux/interdimux.tmux
```

Reload tmux:

```bash
tmux source-file ~/.tmux.conf
```

## Usage

There are two entry points:

### Dashboard (`prefix + g`)

A menu that provides access to all features — rendered as a native tmux
menu on tmux >= 3.4 (one keypress per action: `s`, `n`, `r`, `i`, `w`,
`z`, `d`, `t`, `a`, `o`, `h`), or as a compact fzf menu on older tmux:

- **Switch** (`s`) — Navigate & jump to target
- **New session** (`n`) — Create session from directory
- **Rename** (`r`) — Rename a session or window
- **Kill** (`i`) — Remove sessions, windows, or panes
- **Swap** (`w`) — Swap windows or panes
- **Zoom** (`z`) — Toggle pane zoom
- **Detach** (`d`) — Detach clients from session
- **Send keys** (`t`) — Send a command to a pane
- **Schedule** (`a`) — Run a command later, via `at`
- **Jobs** (`o`) — See and cancel scheduled commands
- **Health** (`h`) — Check the setup, like nvim's `:checkhealth`

`Kill` is drawn in the danger colour, and on tmux >= 3.4 an entry that cannot do
anything is greyed out and loses its key rather than opening a popup to say so:
`Jobs` when nothing is queued (it shows the count when something is), and both
scheduling entries when `at` is not installed.

Select an action to launch the corresponding tool. Action modes open the navigator with a modified prompt — `Enter` performs the action on the selected target, and the list reloads in place so you can repeat. Press `Esc` when done.

### Navigator (`prefix + f`)

The fuzzy navigator for quick switching, with shortcut keys for power users:

| Key | Action |
|---|---|
| `Enter` | Switch to the selected target — or create a session named after the query when nothing matches |
| `Ctrl-x` | Kill the selected session, window, or pane — killing the session you are attached to hops your client to the most recent other session first (no surprise detach) |
| `Ctrl-e` | Rename the selected session or window (pre-filled with the current name) |
| `Ctrl-o` | Open directory picker to create a new session |
| `Ctrl-z` | Toggle zoom on the selected pane |
| `Ctrl-s` | Swap the selected window or pane |
| `Ctrl-d` | Detach clients from the selected session |
| `Ctrl-t` | Send a command to the selected pane |
| `Ctrl-]` | Cycle the match scope: name / path / cmd / all / name+cmd (fzf >= 0.58). The prompt names the active scope |
| `Ctrl-/` | Toggle preview pane |
| `Ctrl-r` | Reload the list |
| `Esc` | Cancel |

The **hint bar sits at the bottom** and updates to show only the keybindings
that apply to the row you are on (session, window, or pane). It is at the bottom
because it is rewritten on every cursor move, and at the top that put moving text
exactly where the eye anchors while scrolling — lazygit, k9s and zellij all put
keys at the bottom for the same reason. It costs one list row, the same row the
old header was already spending.

It is also **tiered to the width available** rather than truncated. The full
session line is 73 cells and an 80-column terminal gives the bar about 61, so it
used to be cut from the right — which removed `^] scope`, the least discoverable
binding in the tool, first. Now the most obvious binding (`Enter`) is dropped
first and `^] scope` survives longest; below the narrowest tier the bar prints
nothing rather than something cut mid-word. It re-tiers live when you open the
preview or resize the client.

The popup title names the session you are in — the current row is marked in the
list, but that row scrolls out of view as soon as the list is longer than the
popup.

Two more things the picker does with what you can and cannot see:

- **The searchable columns are the bright ones.** With `Ctrl-]` on `name+cmd`
  (the default) the path column is dimmed; press `Ctrl-]` and the bright band
  moves to whatever the new scope matches. The prompt names the scope, but the
  rows show it. Turn it off with `@interdimux-scope-highlight 'off'`
  (needs fzf >= 0.66 — 0.65.1 fixed this exact pattern over coloured rows).
- **A long command scrolls without taking the row's identity with it.** Matching
  a token deep inside a full command line makes fzf scroll that row sideways;
  the identity column stays pinned, so you can still see which pane you are
  about to act on (needs fzf >= 0.67).

Sessions are listed most-recently-used first, with the **current session
last** — so opening the navigator and pressing `Enter` toggles to the
previous session, and the current session's windows are one `↑` away
(the list cycles). Set `@interdimux-order 'index'` to keep tmux's native
order instead.

Fuzzy queries match the identity column (session/window/pane names —
window and pane rows carry their session name, so `proj edit` finds the
editor window of the *proj* session) and the command column. Paths, git
badges, and metadata are visible but not matched — press `Ctrl-]` to
cycle the scope when you *do* want to search by path.

### Numbered jumps (opt-in)

```tmux
set -g @interdimux-jump-keys 'M-1 M-2 M-3'
```

Binds one root-table key per position: `M-1` switches to session #1 in the
picker's own ordering, `M-2` to #2, and so on. Under the default MRU order #1
is the previous session, so this is a single keystroke to a fixed destination —
which is the point. A fuzzy query cannot promise that, and neither can a list
position that shifts as you type.

Off by default and you name the keys: claiming root-table keys in someone
else's tmux is not the plugin's to do. Note that a key you name is *taken* —
tmux offers no way to ask what it was bound to and restore it later.

The mode is also usable directly, for a different key layout or a different N:

```tmux
bind-key -n M-0 run-shell -b "TMUX_PANE=#{pane_id} bash ~/.tmux/plugins/interdimux/scripts/interdimux.sh --jump 4"
```

`TMUX_PANE=#{pane_id}` is required, not decoration: `run-shell` passes the tmux
*server's* global environment, not the pressing client's pane, so without it
the "which session am I in" question — and therefore the numbering — can be
answered for the wrong session.

### Directory picker (`Ctrl-o` / dashboard "New Session")

Creates (or switches to) a session from a directory. The list has three tiers:

- `★` recent — directories you created sessions from before (plus, when [zoxide](https://github.com/ajeetdsouza/zoxide) is installed, your most frecent zoxide dirs)
- `◆` projects — directories containing a project marker (`.git`, `package.json`, `Cargo.toml`, `go.mod`, …)
- `·` plain directories

A directory that already has a session is marked `▸` and shows which one, so
`Enter` there is visibly a switch rather than a create:

```
  ▸  ~/code/api          → api
  ★  ~/code/worker
  ◆  ~/code/tools        Rust
```

By default the configured project directories (see `@interdimux-project-dirs`) are scanned one level deep. To go deeper:

| Key | Action |
|---|---|
| `Enter` | Create a session from the selected directory (or switch to it if one exists) |
| `Ctrl-f` | Deep search — re-scan using the current query. Path-style queries (`work/api`, `~/Desktop/proj`, `/abs/path`) are resolved as paths, including partially typed ones; name fragments (`aftermath`) match directory names case-insensitively at any depth (up to 2× scan depth). `~/Library` is skipped when searching from `$HOME`. The query is cleared once the results load, so every match is visible even when its displayed path is shortened |
| `Ctrl-g` | Browse into the highlighted directory |
| `Ctrl-r` | Reset to the default view |
| `Esc` | Cancel |

When a query matches nothing the prompt says so and points at `Ctrl-r`, so a
fruitless deep search is not a blank panel with no visible way back.

The preview shows project type, git branch/status/last commit, a README excerpt, and the directory contents. Session names are derived from the directory basename; when two projects share a basename, the new session is disambiguated with the parent directory name.

### Tree display

```
  ▸ my-project ─────────────────────────────────────────── 3 win ● 2h
* ├─ my-project 0:editor   │ ~/code/proj    ‹feature-x›    nvim main.c
  ├─ my-project 1:shell    │ ~/code/proj    ‹feature-x›    zsh
  └─ my-project 2:remote   │ ~/code/proj                   ssh user@host
    ├╴ my-project 2.0      │ ~/code/proj                   tail -f app.log
    └╴ my-project 2.1      │ ~/code/proj                   zsh
  ▸ other-session ──────────────────────────────────────── 1 win 3d
  └─ other-session 0:main  │ ~                             zsh
```

- `▸` session header with window count, attached marker `●`, and last-used age
- The rule after a session name is the **group separator** — a flat list has no
  other way to show where one session's windows end. It costs no extra rows: it
  is the padding that was already there, and it ends where the command column
  begins, so a session's metadata lines up with its windows' commands. It turns
  itself off on a popup too narrow to have a command column, and entirely with
  `@interdimux-session-rule 'off'`
- `├─` / `└─` tree branches for windows; `├╴` / `└╴` for panes
- Window/pane rows carry their (dimmed) session name, so rows stay
  identifiable while filtering and compound queries work
- `*` marks the current target
- `‹branch›` git branch badge (purple) for directories inside a git repo
- `Z` / `!` / `#` flags mark zoomed, bell, and activity windows
- SSH connections show `user@host` highlighted in blue
- Editors show the filename highlighted in green
- Panes only shown for multi-pane windows
- Column widths adapt to the content and the popup width — the redundant
  session prefix shrinks first, window names are protected last

## Checking your setup

**`prefix + g`, then `h`** — the Health entry pages the report in a popup, `^r`
re-runs the checks after you fix something, `Esc` closes. Or from a shell:

```sh
bash ~/.tmux/plugins/interdimux/scripts/interdimux.sh --doctor
```

It opens with the verdict, because in a popup the first line is the one you
actually read:

```
interdimux doctor                                    23 ok, 2 warn, 1 problem
────────────────────────────────────────────────────────────────────────────
1 problem needs attention
```

Reports what tmux, fzf and interdimux itself can see: versions and the features
they gate, whether the Rust helper is built *and newer than its sources*, whether
the key bindings are actually installed, whether the state directories are
writable, whether your locale is UTF-8 (the tree glyphs and every column width
assume it), whether `sort -s` works (the session order is stable and locale-free
only because of it), whether `$FZF_DEFAULT_OPTS` contains a flag that moves fzf's
geometry without moving `FZF_COLUMNS` — which is what the columns are sized from
— and which of the two dashboards your client is tall enough for. Plus every
`@interdimux-*` option you have set, with its value checked.

That last part is the one worth running. tmux user options are free-form, so a
mistyped name is not an error to tmux — the setting simply never applies, with
nothing to tell you why:

```
✗ unknown option @interdimux-fzf-opt — did you mean @interdimux-fzf-opts?
✗ @interdimux-order = 'recent' — expected 'mru' or 'index'
✗ @interdimux-color-accent = '#ab' — a hex colour must be #rrggbb
```

Exits non-zero if anything is wrong, so it works in a health check.

It is also where past failures surface. The navigator sends its stderr to the
status line and to `$XDG_STATE_HOME/interdimux/errors.log` rather than to the
popup — anything written to a popup's stderr is painted over the rendered rows
and then vanishes with the popup, which is how several silent failures stayed
silent. `--doctor` reports the log and quotes the most recent entry.

A hide pattern that matches no session is called out too, and so is one whose
only match is the session you are in — that one never gets hidden, so the pattern
is doing nothing. `@interdimux-hide` is free-form, so a typo in it looks exactly
like a pattern whose session simply is not running: the list looks normal either
way.

## Configuration

All options are set via tmux options in `~/.tmux.conf`:

```tmux
# Navigator key binding (default: f)
set -g @interdimux-key 'f'

# Dashboard key binding (default: g)
set -g @interdimux-dashboard-key 'g'

# Numbered jumps: one root-table key per session position, in order.
# Off by default.  (default: unset)
set -g @interdimux-jump-keys 'M-1 M-2 M-3'

# Keep sessions out of the list: space-separated glob patterns matched
# against session names.  The session you are currently in is never
# hidden, and a hidden session is still reachable by typing its exact
# name (nothing matches, so find-or-create switches to it).
# (default: unset)
set -g @interdimux-hide 'scratch floax-*'

# Popup dimensions (default: 80% x 75%)
set -g @interdimux-popup-width '80%'
set -g @interdimux-popup-height '75%'

# Preview pane (default: off — toggle in-session with Ctrl-/)
set -g @interdimux-show-preview 'off'

# Show full command line with arguments (default: on)
# Set to 'off' to show only the command name (faster for many panes)
set -g @interdimux-show-full-command 'on'

# Show git branch in tree display (default: on)
set -g @interdimux-show-git-branch 'on'

# Draw the group rule after a session name (default: on).  Costs no extra
# rows, and switches itself off on a popup too narrow to keep a command
# column.  'off' restores the plain session header row.
set -g @interdimux-session-rule 'on'

# Dim the columns the current Ctrl-] scope does NOT search (default: on,
# fzf >= 0.66).  All-or-nothing: fzf cannot re-issue colours mid-session,
# so at the default 'name+cmd' scope the path column is permanently faint.
set -g @interdimux-scope-highlight 'on'

# Session ordering: 'mru' (most recently used first, current session
# last) or 'index' (tmux native order)  (default: mru)
set -g @interdimux-order 'mru'

# Extra fzf flags appended to every picker (advanced; applied after the
# built-in theme so your colors win).
#
# Two notes now the hints live at the bottom: your own `--header` no longer
# replaces them, it draws as well — so the picker spends a second chrome row.
# And a `--with-shell` of your own turns off the inline callbacks, which costs
# a process per cursor move (see docs/PERFORMANCE.md); everything still works.
set -g @interdimux-fzf-opts '--color=bg+:237'

# Colon-separated list of directories to search for new sessions (ctrl-o)
# Defaults to ~/projects:~/code:~/src:~/repos:~/work:~/dev (whichever exist)
set -g @interdimux-project-dirs '~/projects:~/work'

# Max entries shown in the recent tier of the directory picker (default: 10)
set -g @interdimux-recent-limit '10'

# How deep the directory picker's deep search (ctrl-f) scans (default: 3)
set -g @interdimux-scan-depth '3'

# Merge zoxide results into the recent tier when zoxide is installed (default: on)
set -g @interdimux-use-zoxide 'on'

# Re-run the deep search automatically as you type, instead of on ctrl-f
# (default: off).  The scanner does the matching in this mode — fzf's own
# fuzzy filtering is disabled so no result is hidden by path shortening.
set -g @interdimux-dirs-live-search 'off'

# Colon-separated extra project markers, added to the built-in list
# (.git, package.json, Cargo.toml, go.mod, ...)
set -g @interdimux-project-markers 'Move.toml:deno.json'

# Show recent/zoxide directories inline in the navigator as dim '+ name'
# rows, so Enter opens a project whether or not it already has a session
# (default: on).  They are listed after the tmux tree and never delay it.
set -g @interdimux-show-dirs 'on'

# How many directory rows to show (default: 15)
set -g @interdimux-dirs-limit '15'

# Run a startup command in sessions interdimux creates (default: on)
set -g @interdimux-hydrate 'on'

# Fallback startup command, used when nothing more specific matches
set -g @interdimux-startup-command 'nvim .'
```

### Scheduled keys

Send a command to a pane at a future time.

**From the dashboard:** `prefix + g`, then `a`. Pick the target in the usual
picker, type when, type the command. A window or session row narrows to that
window's *active* pane — a scheduled command fires into one pane, never
broadcast, because a fan-out you are not watching two hours later is a
different thing from one you are.

The confirmation screen shows the **resolved** absolute time, which is the
detail that matters: `1:10am` is tomorrow, and so is `13:00` typed at 13:31.
Press `u` there to undo. `prefix + g`, then `j` lists what is pending and
cancels with `Enter`.

The time field takes anything `at` understands, plus a relative shorthand:

| Typed | Means |
|-------|-------|
| `30s` `5m` `2h` `1d` | that far from now |
| `90` | 90 **minutes** (a bare 1–3 digit number is minutes) |
| `1730` | 17:30 — four digits are `at`'s own `HHMM` |
| `17:30` `1:10am` `noon tomorrow` `now + 2 hours` | passed to `at` verbatim |

The shorthand does not shadow anything `at` accepts: `at` rejects a bare
one-to-three digit number outright, and reads four digits as a clock time. If
`at` refuses the time, the field reopens with what you typed and **keeps the
command**, so a typo costs one keystroke rather than the whole entry.

**From the command line:**

```sh
# absolute or relative times — anything `at` understands
interdimux.sh --send-at "17:30"          '=work:1.0'  'make deploy'
interdimux.sh --send-at "now + 2 hours"  %5           'git pull'

# --send-in takes seconds; under a minute it uses tmux's own timer,
# because `at` has a hard one-minute floor
interdimux.sh --send-in 30  .  'echo back from lunch'

interdimux.sh --sched-list          # what's pending
interdimux.sh --sched-cancel 42     # drop one
```

The target is any tmux target (`%5`, `work:1.0`, `=name:`) or `.` for the
current pane, resolved to a pane id at submit time.

**Jobs refuse to fire if the tmux server has restarted.** Pane ids are recycled,
so `%0` after a restart is somebody else's pane — a scheduled `make deploy`
landing there is data loss, not a cosmetic bug. Each job records the server pid
and skips (with a message) rather than misfire.

Two more things worth knowing. interdimux uses its own `at` queue, so
`--sched-list` and `--sched-cancel` can never see or delete your unrelated `at`
jobs. And job output goes to
`~/.local/state/interdimux/scheduled.log` — the `at` daemon (`atd` on Linux,
`atrun` on macOS) mails it otherwise, which on a box with no MTA means it is
destroyed and the job merely *looks* like it never ran.

Sub-minute jobs use `run-shell -d`, which lives inside the tmux server: they are
lost if the server exits. `at` jobs survive a reboot.

`at`-backed jobs (anything ≥ 1 minute) only fire if the OS `at` daemon is
running. **macOS ships `atrun` disabled by default**, so a freshly scheduled job
queues but never runs; enable it once with
`sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.atrun.plist`
(Linux: `sudo systemctl enable --now atd`). Run `--doctor` to check — it reports
whether the job-runner is active.

### Startup commands

A session created by interdimux — from a directory row, from the `ctrl-o`
picker, or by find-or-create — can run a command as soon as it opens.
The first match wins:

1. **`~/.config/interdimux/startup.conf`** — `<glob><whitespace><command>`,
   one per line, `#` comments allowed. Put specific patterns first:

   ```
   ~/work/api*        make dev
   ~/code/*-cli       cargo watch -x run
   ~/notes            nvim index.md
   ```

2. **`.interdimux-startup`** in the directory itself — its contents are the
   command. Multiple lines are sent as separate commands, so this doubles as a
   small bootstrap script:

   ```sh
   nvim .
   ```

3. **`@interdimux-startup-command`** — the global fallback above.

The command is delivered with `send-keys`, so it appears at the prompt and
lands in your shell history exactly as if you had typed it. interdimux waits
for the new shell to finish initialising first, so nothing is echoed before
your prompt appears. Set `@interdimux-hydrate off` to disable.

A directory can also be bound straight to a key, skipping the picker:

```tmux
bind-key C-a run-shell -b "bash ~/.tmux/plugins/interdimux/scripts/interdimux.sh \
  --connect-dir ~/code/api"
```

### Colors

Every color is a tmux option. A value is a hex `#rrggbb`, a 256-color
index, or `-1` / `default` (inherit the terminal). The defaults reproduce
the built-in warm palette, so you only set what you want to change. Hex
values render as truecolor and need an RGB-capable terminal (`$COLORTERM`
= `truecolor`); the index defaults work everywhere.

```tmux
set -g @interdimux-color-accent  '#e78a4e'  # commands, marker, hint keys, prompt, titles
set -g @interdimux-color-path    '#d8a657'  # paths, fzf match highlight
set -g @interdimux-color-git     '#d3869b'  # ‹branch› badge
set -g @interdimux-color-ssh     '#7daea3'  # ssh host, activity flag
set -g @interdimux-color-editor  '#a9b665'  # editor filename
set -g @interdimux-color-success '#a9b665'  # ✓ marks, project-dir ◆
set -g @interdimux-color-danger  '#ea6962'  # kill accents, bell flag, danger border
set -g @interdimux-color-tree    '#6b665f'  # tree glyphs, fzf info
set -g @interdimux-color-separator '#504945' # the │ column separator
set -g @interdimux-color-query   '#ddc7a1'  # typed query text
set -g @interdimux-color-match-current '#e78a4e' # highlight on the current row
set -g @interdimux-color-current-bg '#32302f'    # current-line background
set -g @interdimux-color-header  '#8d877d'  # fzf header text
set -g @interdimux-color-border  '#504945'  # fzf borders / scrollbar
set -g @interdimux-color-menu-sel-fg '#282828'   # dashboard menu selection text
```

These pair with the popup border, which inherits your
`popup-border-style` / `popup-border-lines`. If you generate your dotfiles
with a theming tool, emit these options from your palette so interdimux
re-themes (light or dark) alongside the rest of your setup.

## TODO
- [ ] implement plugins system to define custom actions
  - [ ] once implemented, convert current actions to plugins system
- [x] fix issue with input popup (e.g. for rename) - rendered popup breaks once all characters are removed

See [docs/IDEAS.md](docs/IDEAS.md) for the researched UX/UI improvement
backlog (prioritized, with effort estimates and fzf/tmux version gates).

## License

MIT
