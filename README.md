# interdimux

A portal gun for your tmux sessions.

`interdimux` is a fuzzy tmux navigator for quickly jumping between sessions, windows, and panes with a fast keyboard-driven workflow.

## Features

- Fuzzy switching between sessions, windows, and panes in a single list
- Dashboard menu for easy access to all features
- tmux popup integration (no new terminal needed)
- Live preview of target pane contents (toggle with `Ctrl-/`)
- Metadata: current command, working directory, attached state, active markers
- Git branch display (`‹branch›` badge) with detached HEAD support
- SSH-aware display: highlights `user@host` for SSH/mosh connections
- Editor-aware display: highlights the filename for vim, nvim, emacs, etc.
- Panes only shown for multi-pane windows (keeps the list clean)
- Kill sessions/windows/panes and rename sessions/windows inline
- Zoom/unzoom panes, swap windows/panes, detach sessions, send keys to panes
- Create new sessions from a directory picker
- Dynamic context header — keybinding hints change based on selection type
- Dedicated modes for kill, rename, zoom, swap, detach, and send operations
- Configurable key binding, popup size, and preview toggle

## Dependencies

- `tmux` >= 3.2 (for popup support)
- `fzf` >= 0.38
- `bash` >= 4.0
- `fd` or `find` (for directory picker)
- `zoxide` (optional — feeds the directory picker's recent tier)

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

A fuzzy menu that provides access to all features:

- **Switch** — Navigate & jump to target
- **New Session** — Create session from directory
- **Rename** — Rename a session or window
- **Kill** — Remove sessions, windows, or panes
- **Zoom** — Toggle pane zoom
- **Swap** — Swap windows or panes
- **Detach** — Detach clients from session
- **Send Keys** — Send a command to a pane

Select an action to launch the corresponding tool. Action modes open the navigator with a modified prompt — `Enter` performs the action on the selected target, and the list reloads so you can repeat. Press `Esc` when done.

### Navigator (`prefix + f`)

The fuzzy navigator for quick switching, with shortcut keys for power users:

| Key | Action |
|---|---|
| `Enter` | Switch to the selected target |
| `Ctrl-x` | Kill the selected session, window, or pane |
| `Ctrl-e` | Rename the selected session or window |
| `Ctrl-o` | Open directory picker to create a new session |
| `Ctrl-z` | Toggle zoom on the selected pane |
| `Ctrl-s` | Swap the selected window or pane |
| `Ctrl-d` | Detach clients from the selected session |
| `Ctrl-t` | Send a command to the selected pane |
| `Ctrl-/` | Toggle preview pane |
| `Ctrl-r` | Reload the list |
| `Esc` | Cancel |

The header dynamically updates to show only the relevant keybindings for the currently focused item (session, window, or pane).

### Directory picker (`Ctrl-o` / dashboard "New Session")

Creates (or switches to) a session from a directory. The list has three tiers:

- `★` recent — directories you created sessions from before (plus, when [zoxide](https://github.com/ajeetdsouza/zoxide) is installed, your most frecent zoxide dirs)
- `◆` projects — directories containing a project marker (`.git`, `package.json`, `Cargo.toml`, `go.mod`, …)
- `·` plain directories

By default the configured project directories (see `@interdimux-project-dirs`) are scanned one level deep. To go deeper:

| Key | Action |
|---|---|
| `Enter` | Create a session from the selected directory (or switch to it if one exists) |
| `Ctrl-f` | Deep search — re-scan using the current query. Path-style queries (`work/api`, `~/Desktop/proj`, `/abs/path`) are resolved as paths, including partially typed ones; name fragments (`aftermath`) match directory names case-insensitively at any depth (up to 2× scan depth). `~/Library` is skipped when searching from `$HOME` |
| `Ctrl-g` | Browse into the highlighted directory |
| `Ctrl-r` | Reset to the default view |
| `Esc` | Cancel |

The preview shows project type, git branch/status/last commit, a README excerpt, and the directory contents. Session names are derived from the directory basename; when two projects share a basename, the new session is disambiguated with the parent directory name.

### Tree display

```
▸ * my-project  (3 wins) [a]
  ├─ * 0:editor    nvim main.c    ~/code/proj     ‹feature-x›
  ├─   1:shell     zsh            ~/code/proj     ‹feature-x›
  └─   2:remote    ssh user@host  ~/code/proj
    │  ├─   .0     tail           ~/code/proj
    │  └─   .1     zsh            ~/code/proj
▸   other-session  (1 wins)
  └─   0:main      zsh            ~/
```

- `▸` session header
- `├─` / `└─` tree branches for windows and panes
- `│` continuation lines connect panes to their parent window
- `*` marks the current target
- `[a]` marks attached sessions
- `‹branch›` git branch badge (purple) for directories inside a git repo
- SSH connections show `user@host` highlighted in blue
- Editors show the filename highlighted in green
- Panes only shown for multi-pane windows

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
# (default: off)
set -g @interdimux-dirs-live-search 'off'

# Colon-separated extra project markers, added to the built-in list
# (.git, package.json, Cargo.toml, go.mod, ...)
set -g @interdimux-project-markers 'Move.toml:deno.json'
```

## TODO
- [ ] implement plugins system to define custom actions
  - [ ] once implemented, convert current actions to plugins system

## License

MIT
