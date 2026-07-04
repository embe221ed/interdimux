#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read user options with defaults.  All other configuration is read by
# the script itself at popup time (env override → tmux option → default),
# so no env plumbing is needed here.
interdimux_key=$(tmux show-option -gqv @interdimux-key)
interdimux_key="${interdimux_key:-f}"

dashboard_key=$(tmux show-option -gqv @interdimux-dashboard-key)
dashboard_key="${dashboard_key:-g}"

# prefix + f — open the navigator (the script owns popup size and chrome)
tmux bind-key "$interdimux_key" run-shell -b \
  "bash '$CURRENT_DIR/scripts/interdimux.sh' --launch switch"

# prefix + g — open the dashboard (native menu on tmux >= 3.4)
tmux bind-key "$dashboard_key" run-shell -b \
  "bash '$CURRENT_DIR/scripts/interdimux.sh' --dashboard-launch"
