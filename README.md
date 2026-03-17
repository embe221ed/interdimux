# interdimux

A portal gun for your tmux sessions.

`interdimux` is a fuzzy tmux navigator for quickly jumping between sessions, windows, and panes with a fast keyboard-driven workflow.

## Features

- Fuzzy switching between sessions, windows, and panes in a single list
- Dashboard menu for easy access to all features
- tmux popup integration (no new terminal needed)
- Live preview of target pane contents
- Metadata: current command, working directory, attached state, active markers
- Panes only shown for multi-pane windows (keeps the list clean)
- Kill sessions/windows/panes and rename sessions/windows inline
- Create new sessions from a directory picker
- Dedicated kill and rename modes for batch operations
- Configurable key binding, popup size, and preview toggle

## Dependencies

- `tmux` >= 3.2 (for popup support)
- `fzf`
- `bash` >= 4.0
- `fd` or `find` (for directory picker)

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

A menu that provides access to all features:

```
  interdimux

   s  Switch          Navigate & jump to target
   n  New Session     Create session from directory
   r  Rename          Rename a session or window
   k  Kill            Remove sessions, windows, or panes

   q  quit    esc  back
```

Press a single key to launch the corresponding tool. Kill and rename modes open the navigator with a modified prompt — `Enter` performs the action on the selected target, and the list reloads so you can repeat. Press `Esc` when done.

### Navigator (`prefix + f`)

The fuzzy navigator for quick switching, with shortcut keys for power users:

| Key | Action |
|---|---|
| `Enter` | Switch to the selected target |
| `Ctrl-x` | Kill the selected session, window, or pane |
| `Ctrl-e` | Rename the selected session or window |
| `Ctrl-o` | Open directory picker to create a new session |
| `Ctrl-r` | Reload the list |
| `Esc` | Cancel |

### Tree display

```
▸ * my-project  (3 wins) [a]
  ├─ * 0:editor    nvim           ~/code/proj
  ├─   1:shell     zsh            ~/code/proj
  └─   2:logs      tail           ~/code/proj
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
- Panes only shown for multi-pane windows
- Full command with args shown inline (e.g. `vim -p file.c`, `ssh user@host`)

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

# Colon-separated list of directories to search for new sessions (ctrl-o)
# Defaults to ~/projects:~/code:~/src:~/repos:~/work:~/dev (whichever exist)
set -g @interdimux-project-dirs '~/projects:~/work'
```

## License

MIT
