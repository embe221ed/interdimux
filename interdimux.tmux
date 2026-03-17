#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read user options with defaults
interdimux_key=$(tmux show-option -gqv @interdimux-key)
interdimux_key="${interdimux_key:-f}"

popup_width=$(tmux show-option -gqv @interdimux-popup-width)
popup_width="${popup_width:-80%}"

popup_height=$(tmux show-option -gqv @interdimux-popup-height)
popup_height="${popup_height:-75%}"

show_preview=$(tmux show-option -gqv @interdimux-show-preview)
show_preview="${show_preview:-on}"

show_full_command=$(tmux show-option -gqv @interdimux-show-full-command)
show_full_command="${show_full_command:-on}"

# Register the key binding — prefix + key opens the popup
tmux bind-key "$interdimux_key" run-shell -b \
  "tmux popup -w '$popup_width' -h '$popup_height' -E \
    'INTERDIMUX_SHOW_PREVIEW=$show_preview INTERDIMUX_SHOW_FULL_COMMAND=$show_full_command $CURRENT_DIR/scripts/interdimux.sh'"
