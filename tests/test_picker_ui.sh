#!/usr/bin/env bash
#
# Picker prompts: what the UI says about the state you are in.
#
# Both assertions are about a prompt because a prompt is what the eye is on
# while typing, and in both cases the header could not carry the message:
#
#   * the directory picker's ^f and ^g already own the header via
#     transform-header, so a `result` bind restoring a default would clobber
#     the "deep search"/"browse" header they had just set
#   * the swap picker's header is the keybinding hint line
#
# Needs a real client: a prompt lives in a rendered UI, and send-keys writes to
# a pane's pty rather than driving fzf, so an outer tmux types into an inner one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-pickerui-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-pui.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  tmux -L "$OUTER" kill-server 2>/dev/null || true
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

echo "interdimux picker prompt tests"
echo

fzf_minor=$(fzf --version 2>/dev/null | awk '{print $1}' | cut -d. -f2)
if [ "${fzf_minor:-0}" -lt 51 ]; then
  echo "  (skipped: the empty-state prompt needs FZF_MATCH_COUNT, fzf >= 0.51)"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

mkdir -p "$TMPD/data/interdimux" "$TMPD/onlydir"
printf '%s\n' "$TMPD/onlydir" > "$TMPD/data/interdimux/recent_dirs"

tmux -f /dev/null -L "$SOCK" new-session -d -s alpha -x 120 -y 30
tmux -L "$SOCK" new-window -d -t '=alpha:' -n second
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=alpha:0' -F '#{pane_id}' | head -1)"

drive() { # $1.. = args to the script; opens it under a real client
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 120 -y 30 \
    "env TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' XDG_DATA_HOME='$TMPD/data' \
         INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
         INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_PROJECT_DIRS='$TMPD' \
         bash '$SCRIPT' $*; sleep 15"
  local i
  for i in $(seq 1 80); do
    tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | grep -q '❯' && return 0
    sleep 0.1
  done
  return 1
}
prompt() { tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -m1 '❯'; }
# wait for the prompt to satisfy a pattern rather than sleeping a fixed time
prompt_until() { # $1 = grep pattern
  local i out=""
  for i in $(seq 1 60); do
    out=$(prompt)
    printf '%s' "$out" | grep -q "$1" && break
    sleep 0.1
  done
  printf '%s' "$out"
}

# --- the directory picker's empty state (IDEAS #28) --------------------------------
if drive --dirs; then
  report "the directory picker opens" pass
else
  report "the directory picker opens" fail
  echo; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

before=$(prompt)
case "$before" in
  *'new session ❯'*) report "it starts with the normal prompt" pass ;;
  *) report "it starts with the normal prompt (got: $before)" fail ;;
esac

tmux -L "$OUTER" send-keys -t '=drv:' 'zzzznothingmatchesthis'
empty=$(prompt_until '∅')
case "$empty" in
  *'∅ nothing matched'*) report "a fruitless query says so, and says ^r resets" pass ;;
  *) report "a fruitless query says so, and says ^r resets (got: $empty)" fail
     ERRORS+="    $empty"$'\n' ;;
esac

tmux -L "$OUTER" send-keys -t '=drv:' C-u
back=$(prompt_until 'new session')
case "$back" in
  *'new session ❯'*) report "...and the prompt recovers when matches return" pass ;;
  *) report "...and the prompt recovers when matches return (got: $back)" fail ;;
esac
tmux -L "$OUTER" send-keys -t '=drv:' Escape 2>/dev/null || true

# --- the swap picker names its source ----------------------------------------------
# The destination list looks exactly like the navigator's, so a picker headed
# only "swap with ❯" gave no way to tell which end had already been chosen.
if drive --action swap "'W:alpha:0'"; then
  p=$(prompt)
  case "$p" in
    *"swap window 'alpha:0' with ❯"*) report "the swap picker names the source window" pass ;;
    *) report "the swap picker names the source window (got: $p)" fail
       ERRORS+="    $p"$'\n' ;;
  esac
else
  report "the swap picker opens" fail
fi
tmux -L "$OUTER" send-keys -t '=drv:' Escape 2>/dev/null || true

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
