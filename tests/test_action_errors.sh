#!/usr/bin/env bash
#
# Action-layer robustness (IDEAS #22, #23).
#
#   #23 tmux's own error message must reach the user.  "duplicate session: two"
#       tells them what to do; "failed to rename" leaves them guessing, and the
#       real reason was being thrown away by 2>/dev/null.
#   #22 a dialog hides the cursor and, in kill mode, turns the popup border red.
#       Ctrl-C used to abandon both, leaving an invisible cursor behind a
#       permanently red frame.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-actionerr-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-actionerr.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMPD"; }
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

echo "interdimux action-error tests"
echo

tmux -f /dev/null -L "$SOCK" new-session -d -s one -x 100 -y 30
tmux -L "$SOCK" new-session -d -s two -x 100 -y 30
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=one:' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
sleep 1

# Drive the rename dialog: the initial value is pre-filled, so ctrl-u clears it,
# then we type the new name and press Enter.
# The dialogs draw with absolute cursor positioning and write with `>`, so each
# call truncates a plain file and only the last survives.  Render into a REAL
# pane instead and read the screen — which is also what the user actually sees.
run_rename() { # $1 = new name -> prints the rendered screen
  local newname="$1" in="$TMPD/in"
  printf '\025%s\n' "$newname" > "$in"     # ^U then the name then Enter
  tmux -L "$SOCK" kill-window -t '=one:dlg' 2>/dev/null || true
  local wid
  wid=$(tmux -L "$SOCK" new-window -d -P -F '#{window_id}' -t '=one:' -n dlg \
    "env INTERDIMUX_TTY_IN='$in' INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 \
         INTERDIMUX_TMUX_VNUM=307 TMUX_PANE='$TMUX_PANE' \
         bash '$SCRIPT' --action rename 'S:one'; sleep 3" 2>/dev/null) || return 0
  sleep 2.5
  # by WINDOW ID, not by session:name — a successful rename changes the session
  # name out from under us mid-flight, and the id is stable
  tmux -L "$SOCK" capture-pane -t "$wid" -p 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r' || true
}

# --- #23: the real reason, not a generic failure -------------------------------
out=$(run_rename 'two')
if printf '%s' "$out" | grep -q 'duplicate session'; then
  report "a rejected rename shows tmux's own reason" pass
else
  report "a rejected rename shows tmux's own reason" fail
  ERRORS+="    drew: $(printf '%s' "$out" | tr -s ' ' | tail -c 200)"$'\n'
fi
if printf '%s' "$out" | grep -q 'failed to rename'; then
  report "the generic message is no longer used when tmux explained itself" fail
else
  report "the generic message is no longer used when tmux explained itself" pass
fi
# the session must be unchanged after a rejected rename
if tmux -L "$SOCK" has-session -t '=one' 2>/dev/null; then
  report "a rejected rename leaves the session alone" pass
else
  report "a rejected rename leaves the session alone" fail
fi

# --- a rename that should succeed ----------------------------------------------
out=$(run_rename 'renamed-ok')
if tmux -L "$SOCK" has-session -t '=renamed-ok' 2>/dev/null; then
  report "a valid rename still works" pass
else
  report "a valid rename still works" fail
fi

# --- #22: the cleanup trap exists and restores both --------------------------
if grep -q "trap '_action_cleanup; exit 130' INT TERM" "$SCRIPT"; then
  report "the action handler traps INT/TERM" pass
else
  report "the action handler traps INT/TERM" fail
fi
if grep -q "trap '_action_cleanup' EXIT" "$SCRIPT"; then
  report "the action handler cleans up on every exit path" pass
else
  report "the action handler cleans up on every exit path" fail
fi
# the cleanup must show the cursor again and restore the border
_cleanup_body=$(sed -n '/_action_cleanup() {/,/^  }/p' "$SCRIPT")
printf '%s' "$_cleanup_body" | grep -q '25h' \
  && report "cleanup makes the cursor visible again" pass \
  || report "cleanup makes the cursor visible again" fail
printf '%s' "$_cleanup_body" | grep -q 'popup_accent' \
  && report "cleanup restores the popup border" pass \
  || report "cleanup restores the popup border" fail
printf '%s' "$_cleanup_body" | grep -q 'stty' \
  && report "cleanup restores the terminal mode input_dialog changed" pass \
  || report "cleanup restores the terminal mode input_dialog changed" fail

# --- regressions from the reliability hunt -------------------------------------

# Every action except zoom used to die with "tty_in: unbound variable" on a
# directory row, because the D: early-exit set only tty_out and set -u kills the
# process at the first read of the unbound one.  D: rows are on by default, so
# ctrl-x on one was an instant, silent death.
out=$(timeout 10 bash "$SCRIPT" --action kill 'D:/tmp' 2>&1) || true
if printf '%s' "$out" | grep -q 'unbound variable'; then
  report "an action on a directory row does not die on an unbound variable" fail
else
  report "an action on a directory row does not die on an unbound variable" pass
fi

# The cleanup trap calls popup_accent, which issues `display-popup` with no -E.
# Inside a popup that repaints it; with a client attached and NO popup open tmux
# OPENS one and blocks until a human dismisses it -- so every --action run
# outside a popup hung forever.
timeout 10 bash "$SCRIPT" --action zoom "P:one:0.0" >/dev/null 2>&1
if [ $? -eq 124 ]; then
  report "an action outside a popup does not hang" fail
else
  report "an action outside a popup does not hang" pass
fi

# tmux parses a leading '-' as a flag unless -- separates it.
_dash_ok=1
grep -q 'rename-session -t "$target" -- "$new_name"' "$SCRIPT" || _dash_ok=0
grep -q 'rename-window  -t "$target" -- "$new_name"' "$SCRIPT" || _dash_ok=0
grep -q 'send-keys -t "$t" -- "$send_cmd"' "$SCRIPT" || _dash_ok=0
[ "$_dash_ok" = 1 ] && report "user text is passed after -- so a leading dash is not a flag" pass \
                    || report "user text is passed after -- so a leading dash is not a flag" fail

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
