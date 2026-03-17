# interdimux

A portal gun for your tmux sessions.

`interdimux` is a fuzzy tmux navigator for quickly jumping between sessions, windows, and panes with a fast keyboard-driven workflow.

## Features

- Fuzzy switching between sessions, windows, and panes in a single list
- tmux popup integration (no new terminal needed)
- Live preview of target pane contents
- Metadata: current command, working directory, attached state, active markers
- Panes only shown for multi-pane windows (keeps the list clean)
- Reload list with `ctrl-r` without leaving the selector
- Configurable key binding, popup size, and preview toggle

## Dependencies

- `tmux` >= 3.2 (for popup support)
- `fzf`

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

Press `prefix + f` (default) to open the navigator popup.

- Type to fuzzy-filter targets
- `Enter` to switch to the selected target
- `Ctrl-r` to reload the list
- `Esc` to cancel

The list shows a tree:

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
# Key binding (default: f)
set -g @interdimux-key 'f'

# Popup dimensions (default: 80% x 60%)
set -g @interdimux-popup-width '80%'
set -g @interdimux-popup-height '60%'

# Preview pane (default: on)
set -g @interdimux-show-preview 'on'

# Show full command line with arguments (default: on)
# Set to 'off' to show only the command name (faster for many panes)
set -g @interdimux-show-full-command 'on'
```

## License

MIT
