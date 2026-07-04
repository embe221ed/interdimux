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
  (name / path / cmd / all, fzf >= 0.58)
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
- Live preview with a title line (target, command, path) and a window
  summary for sessions (toggle with `Ctrl-/`)
- Metadata: window count, attached marker `●`, last-used age, zoomed `Z` /
  bell `!` / activity `#` flags, current-target markers
- Git branch display (`‹branch›` badge) with detached HEAD support
- SSH-aware display: highlights `user@host` for SSH/mosh connections
- Editor-aware display: highlights the filename for vim, nvim, emacs, etc.
- Panes only shown for multi-pane windows (keeps the list clean)
- Columns sized to the popup width; panes/windows aligned across the tree
- Create new sessions from a directory picker
- Dynamic context header — keybinding hints change based on selection type
- Dedicated modes for kill, rename, zoom, swap, detach, and send operations
- Configurable key binding, popup size, ordering, preview, and extra fzf flags

## Dependencies

- `tmux` >= 3.2 — popups; >= 3.3 adds popup titles, >= 3.4 the native
  dashboard menu, >= 3.6 live border accents
- `fzf` >= 0.40 — newer versions unlock extra polish automatically
  (0.52 full-line highlight, 0.58 match-scope cycling, 0.61 ghost text)
- `bash` >= 4.0
- `fd` or `find` (for directory picker)
- `zoxide` (optional — feeds the recent tier and find-or-create)

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
menu on tmux >= 3.4 (one keypress per action: `s`, `n`, `r`, `k`, `w`,
`z`, `d`, `t`), or as a compact fzf menu on older tmux:

- **Switch** — Navigate & jump to target
- **New session** — Create session from directory
- **Rename** — Rename a session or window
- **Kill** — Remove sessions, windows, or panes
- **Swap** — Swap windows or panes
- **Zoom** — Toggle pane zoom
- **Detach** — Detach clients from session
- **Send keys** — Send a command to a pane

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
| `Ctrl-]` | Cycle the match scope: name / path / cmd / all (fzf >= 0.58) |
| `Ctrl-/` | Toggle preview pane |
| `Ctrl-r` | Reload the list |
| `Esc` | Cancel |

The header dynamically updates to show only the relevant keybindings for the currently focused item (session, window, or pane).

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

### Directory picker (`Ctrl-o` / dashboard "New Session")

Creates (or switches to) a session from a directory. The list has three tiers:

- `★` recent — directories you created sessions from before (plus, when [zoxide](https://github.com/ajeetdsouza/zoxide) is installed, your most frecent zoxide dirs)
- `◆` projects — directories containing a project marker (`.git`, `package.json`, `Cargo.toml`, `go.mod`, …)
- `·` plain directories

By default the configured project directories (see `@interdimux-project-dirs`) are scanned one level deep. To go deeper:

| Key | Action |
|---|---|
| `Enter` | Create a session from the selected directory (or switch to it if one exists) |
| `Ctrl-f` | Deep search — re-scan using the current query. Path-style queries (`work/api`, `~/Desktop/proj`, `/abs/path`) are resolved as paths, including partially typed ones; name fragments (`aftermath`) match directory names case-insensitively at any depth (up to 2× scan depth). `~/Library` is skipped when searching from `$HOME`. The query is cleared once the results load, so every match is visible even when its displayed path is shortened |
| `Ctrl-g` | Browse into the highlighted directory |
| `Ctrl-r` | Reset to the default view |
| `Esc` | Cancel |

The preview shows project type, git branch/status/last commit, a README excerpt, and the directory contents. Session names are derived from the directory basename; when two projects share a basename, the new session is disambiguated with the parent directory name.

### Tree display

```
  ▸ my-project             3 win ● 2h
* ├─ my-project 0:editor   │ ~/code/proj    ‹feature-x›    nvim main.c
  ├─ my-project 1:shell    │ ~/code/proj    ‹feature-x›    zsh
  └─ my-project 2:remote   │ ~/code/proj                   ssh user@host
    ├╴ my-project 2.0      │ ~/code/proj                   tail -f app.log
    └╴ my-project 2.1      │ ~/code/proj                   zsh
  ▸ other-session          1 win 3d
  └─ other-session 0:main  │ ~                              zsh
```

- `▸` session header with window count, attached marker `●`, and last-used age
- `├─` / `└─` tree branches for windows; `├╴` / `└╴` for panes
- Window/pane rows carry their (dimmed) session name, so rows stay
  identifiable while filtering and compound queries work
- `*` marks the current target
- `‹branch›` git branch badge (purple) for directories inside a git repo
- `Z` / `!` / `#` flags mark zoomed, bell, and activity windows
- SSH connections show `user@host` highlighted in blue
- Editors show the filename highlighted in green
- Panes only shown for multi-pane windows
- Column widths adapt to the popup width

## Configuration

All options are set via tmux options in `~/.tmux.conf`:

```tmux
# Navigator key binding (default: f)
set -g @interdimux-key 'f'

# Dashboard key binding (default: g)
set -g @interdimux-dashboard-key 'g'

# Popup dimensions (default: 80% x 75%)
set -g @interdimux-popup-width '80%'
set -g @interdimux-popup-height '75%'

# Preview pane (default: on)
set -g @interdimux-show-preview 'on'

# Show full command line with arguments (default: on)
# Set to 'off' to show only the command name (faster for many panes)
set -g @interdimux-show-full-command 'on'

# Show git branch in tree display (default: on)
set -g @interdimux-show-git-branch 'on'

# Session ordering: 'mru' (most recently used first, current session
# last) or 'index' (tmux native order)  (default: mru)
set -g @interdimux-order 'mru'

# Extra fzf flags appended to every picker (advanced; applied after the
# built-in theme so your colors win)
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
```

## TODO
- [ ] implement plugins system to define custom actions
  - [ ] once implemented, convert current actions to plugins system

See [docs/IDEAS.md](docs/IDEAS.md) for the researched UX/UI improvement
backlog (prioritized, with effort estimates and fzf/tmux version gates).

## License

MIT
