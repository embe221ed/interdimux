#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$CURRENT_DIR/scripts/interdimux.sh"

# The script installs its own bindings (--bind-keys).  On tmux >= 3.4 that
# binds prefix+f straight to display-popup via `run-shell -bC`, so opening the
# picker spawns no shell and no launcher process; below 3.4 it installs the
# original run-shell binding.  Either way the keys come from
# @interdimux-key / @interdimux-dashboard-key.
#
# If that fails for any reason, fall back here so the plugin is never left
# with no bindings at all.
if ! bash "$SCRIPT" --bind-keys 2>/dev/null; then
  interdimux_key=$(tmux show-option -gqv @interdimux-key)
  interdimux_key="${interdimux_key:-f}"
  dashboard_key=$(tmux show-option -gqv @interdimux-dashboard-key)
  dashboard_key="${dashboard_key:-g}"

  # run-shell FORMAT-EXPANDS its argument, so a '#' in the install path is eaten
  # at keypress ('#f' and '#S' are formats) and the binding silently does
  # nothing.  '##' is tmux's escape.  The quoted pattern is required: a bare '#'
  # in ${var//#/…} is the match-at-start anchor.
  sq="${SCRIPT//\'/\'\\\'\'}"
  fmt="${sq//'#'/##}"

  tmux bind-key "$interdimux_key" run-shell -b \
    "bash '$fmt' --launch switch"
  tmux bind-key "$dashboard_key" run-shell -b \
    "bash '$fmt' --dashboard-launch"
fi
