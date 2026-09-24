#!/usr/bin/env bash
#
# The kill-mode danger frame must be VISIBLE whatever the border line style.
#
# The danger cue is the popup border recoloured.  With popup-border-lines
# "padded" the border is made of spaces, so recolouring only its foreground
# drew red on nothing: the frame looked exactly like the normal one and the only
# red left was the title text.  tmux also drops every attribute from a popup
# border style (so `reverse` cannot help), which is why the padded frame gets
# the danger colour as its BACKGROUND and the title keeps a different colour on
# top of it -- a red-on-red title would be the same failure one row up.
#
# The authority is what tmux actually drew: the popup is opened in a real client
# (an outer tmux attached to the one under test) and the frame row is read back
# with its SGR codes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-dframe-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-dframe.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""
LPID=""

cleanup() {
  [ -n "$LPID" ] && kill "$LPID" 2>/dev/null || true
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$TMPD"
}
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}
T() { tmux -L "$SOCK" "$@"; }
wait_for() { # $1 = a command that must succeed; bounded poll, no fixed sleep
  local i
  for i in $(seq 1 ${2:-100}); do eval "$1" && return 0; sleep 0.1; done
  return 1
}

echo "interdimux danger-frame tests"
echo

# colour 160 is not the default danger colour, so a match cannot be a leftover
# from some other part of the palette
DANGER=160
T -f /dev/null new-session -d -s demo -x 100 -y 30
T set -g default-command 'bash --norc --noprofile -i'
T set -g @interdimux-color-danger "$DANGER"
T set -g popup-border-style 'bg=#eee0b7'
export TMUX="$(T display-message -p '#{socket_path}'),99999,0"
unset TMUX_PANE INTERDIMUX_CLIENT
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off

tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 100 -y 30 \
  "TMUX= TERM=xterm-256color tmux -L $SOCK attach -t demo"
wait_for '[ -n "$(T list-clients 2>/dev/null)" ]' || { echo "no client attached"; exit 1; }

# frame_row LINES -> the kill popup's title row as tmux drew it, SGR included
frame_row() {
  local lines="$1" row
  T set -g popup-border-lines "$lines"
  bash "$SCRIPT" --launch kill >/dev/null 2>&1 &
  LPID=$!
  wait_for "tmux -L '$OUTER' capture-pane -p -t '=drv:' | grep -q 'interdimux · kill'" || true
  row=$(tmux -L "$OUTER" capture-pane -p -t '=drv:' | grep -n 'interdimux · kill' | head -1 | cut -d: -f1 || true)
  if [ -n "$row" ]; then
    tmux -L "$OUTER" capture-pane -p -e -t '=drv:' | sed -n "${row}p"
  fi
  # close it: Escape quits the picker, which closes the popup
  tmux -L "$OUTER" send-keys -t '=drv:' Escape
  wait_for "! kill -0 $LPID 2>/dev/null" || kill "$LPID" 2>/dev/null || true
  wait "$LPID" 2>/dev/null || true
  LPID=""
  wait_for "! tmux -L '$OUTER' capture-pane -p -t '=drv:' | grep -q 'interdimux · kill'" || true
}

# --- padded: the frame itself turns red ------------------------------------------
row=$(frame_row padded)
if [ -z "$row" ]; then
  report "the kill popup opens (padded)" fail
else
  if printf '%s' "$row" | grep -q "48;5;${DANGER}m"; then
    report "with padded borders the frame is painted in the danger colour" pass
  else
    report "with padded borders the frame is painted in the danger colour" fail
    ERRORS+="    row: $(printf '%s' "$row" | cat -v | head -c 240 || true)"$'\n'
  fi
  if printf '%s' "$row" | grep -q "38;5;${DANGER}m"; then
    report "...and the title on it is not drawn in the same colour (red on red)" fail
    ERRORS+="    row: $(printf '%s' "$row" | cat -v | head -c 240 || true)"$'\n'
  else
    report "...and the title on it is not drawn in the same colour (red on red)" pass
  fi
fi

# --- a line style with glyphs: unchanged, the lines themselves are red -------------
row=$(frame_row rounded)
if [ -z "$row" ]; then
  report "the kill popup opens (rounded)" fail
else
  if printf '%s' "$row" | grep -q "38;5;${DANGER}m" && ! printf '%s' "$row" | grep -q "48;5;${DANGER}m"; then
    report "with rounded borders the lines are red and the background is left alone" pass
  else
    report "with rounded borders the lines are red and the background is left alone" fail
    ERRORS+="    row: $(printf '%s' "$row" | cat -v | head -c 240 || true)"$'\n'
  fi
fi

# --- none: no frame and no title, so the prompt carries the cue ------------------
# tmux draws nothing around the popup with "none", and no border style can show
# there -- so the kill picker's own prompt is drawn in the danger colour.  Read
# back from the screen: the `kill ❯` line as tmux drew it, SGR included.
prompt_row() { # $1 = popup-border-lines -> the kill picker's prompt line
  local row
  T set -g popup-border-lines "$1"
  bash "$SCRIPT" --launch kill >/dev/null 2>&1 &
  LPID=$!
  wait_for "tmux -L '$OUTER' capture-pane -p -t '=drv:' | grep -q 'kill ❯'" || true
  row=$(tmux -L "$OUTER" capture-pane -p -t '=drv:' | grep -n 'kill ❯' | head -1 | cut -d: -f1 || true)
  if [ -n "$row" ]; then
    tmux -L "$OUTER" capture-pane -p -e -t '=drv:' | sed -n "${row}p"
  fi
  tmux -L "$OUTER" send-keys -t '=drv:' Escape
  wait_for "! kill -0 $LPID 2>/dev/null" || kill "$LPID" 2>/dev/null || true
  wait "$LPID" 2>/dev/null || true
  LPID=""
  wait_for "! tmux -L '$OUTER' capture-pane -p -t '=drv:' | grep -q 'kill ❯'" || true
}
row=$(prompt_row none)
if [ -z "$row" ]; then
  report "the kill picker opens (none)" fail
else
  # the prompt's own text, not merely something on the row
  if printf '%s' "$row" | grep -q "38;5;${DANGER}mkill ❯"; then
    report "with no border the kill prompt is drawn in the danger colour" pass
  else
    report "with no border the kill prompt is drawn in the danger colour" fail
    ERRORS+="    row: $(printf '%s' "$row" | cat -v | head -c 240 || true)"$'\n'
  fi
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
