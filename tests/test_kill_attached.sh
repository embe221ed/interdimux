#!/usr/bin/env bash
#
# ctrl-x with a client ATTACHED to what is being killed: no surprise detach.
#
# Destroying a session detaches every client on it (detach-on-destroy defaults
# to on), which ejects the user from tmux even though other sessions exist.  The
# README promises the kill workflow does not do that, and the session branch
# hops clients to the most recently used survivor first.  But killing the LAST
# window of a session -- or the last pane of its last window -- destroys the
# session too, and that path went straight to kill-window/kill-pane: ctrl-x on
# the only window of the session you were in dropped you out of tmux.
#
# None of this is visible without a real client, and every earlier kill test
# ran against a server nobody was attached to, where switch-client cannot fail
# and a detach cannot happen.  So an outer tmux attaches to the server under
# test, and the assertions read tmux's own client list.
#
# INTERDIMUX_TMUX_VNUM=302 keeps popup_accent out of it: outside a popup, a
# display-popup without -E OPENS one on the attached client and blocks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-killatt-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-killatt.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
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
client_sessions() { { T list-clients -F '#{client_session}' 2>/dev/null || true; } | sort | tr '\n' ' ' | sed 's/ $//'; }
wait_for() { # $1 = a command that must succeed; bounded poll, no fixed sleep
  local i
  for i in $(seq 1 80); do eval "$1" && return 0; sleep 0.1; done
  return 1
}

echo "interdimux kill-with-an-attached-client tests"
echo

# 'other' and 'third' are where a hop can land; 'third' also gives a kill that
# does NOT touch the client's session something to kill.
T -f /dev/null new-session -d -s other -x 120 -y 30
T set -g default-command 'bash --norc --noprofile -i'
T new-session -d -s third -x 120 -y 30
T new-session -d -s cur -x 120 -y 30
export TMUX="$(T display-message -p '#{socket_path}'),99999,0"
export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=302
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
unset INTERDIMUX_CLIENT

# A client attached to 'cur', from an outer tmux.  Also used to re-attach when a
# case (on a broken build) detached the last one, so one failure does not take
# every later case down with it.
attach_cur() {
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 120 -y 30 \
    "TMUX= tmux -L $SOCK attach -t cur"
  wait_for '[ "$(client_sessions)" = cur ]'
}
if attach_cur; then
  report "a client is attached to 'cur'" pass
else
  report "a client is attached to 'cur'" fail
  echo; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
CLIENT=$(T list-clients -F '#{client_name}' | head -1)

kill_y() { # $1 = spec -> kills it, answering y; prints the dialog text
  printf 'y' > "$TMPD/in"; : > "$TMPD/out"
  export TMUX_PANE; TMUX_PANE=$(T list-panes -t '=cur:' -F '#{pane_id}' 2>/dev/null | head -1 || true)
  INTERDIMUX_TTY_IN="$TMPD/in" INTERDIMUX_TTY_OUT="$TMPD/out" \
    timeout 20 bash "$SCRIPT" --action kill "$1" >/dev/null 2>&1 || true
  sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$TMPD/out" | tr -s ' ─│╭╮╰╯' ' '
}
# Put the client back on a fresh single-window 'cur'
reset_cur() {
  T kill-session -t '=cur' 2>/dev/null || true
  T new-session -d -s cur -x 120 -y 30
  if [ -z "$(client_sessions)" ]; then
    attach_cur || true
    CLIENT=$(T list-clients -F '#{client_name}' | head -1)
  fi
  T switch-client -c "$CLIENT" -t '=cur:' 2>/dev/null || true
  wait_for '[ "$(client_sessions)" = cur ]' || true
}
gone() { ! T has-session -t '=cur:' 2>/dev/null; }
# still attached, to a session that survived (which one is MRU's call)
hopped() { local cs; cs=$(client_sessions); [ -n "$cs" ] && [ "$cs" != cur ] && T has-session -t "=$cs:" 2>/dev/null; }

# --- a session row: the hop that was already there ----------------------------
kill_y 'S:cur' >/dev/null
wait_for gone || true
if gone && hopped; then
  report "killing the session you are in moves you to the next one" pass
else
  report "killing the session you are in moves you to the next one" fail
  ERRORS+="    clients on: [$(client_sessions)]"$'\n'
fi

# --- the only window of that session ------------------------------------------
reset_cur
out=$(kill_y 'W:cur:0')
wait_for gone || true
if gone && hopped; then
  report "killing the only window of your session keeps you in tmux, on the next session" pass
else
  report "killing the only window of your session keeps you in tmux, on the next session" fail
  ERRORS+="    clients on: [$(client_sessions)]"$'\n'
fi
if printf '%s' "$out" | grep -q 'session closes too'; then
  report "...and the confirm dialog said the session would close with it" pass
else
  report "...and the confirm dialog said the session would close with it" fail
  ERRORS+="    drew: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200 || true)"$'\n'
fi

# --- the only pane of the only window -------------------------------------------
reset_cur
kill_y 'P:cur:0:0' >/dev/null
wait_for gone || true
if gone && hopped; then
  report "killing the only pane of your session keeps you in tmux, on the next session" pass
else
  report "killing the only pane of your session keeps you in tmux, on the next session" fail
  ERRORS+="    clients on: [$(client_sessions)]"$'\n'
fi

# --- ...but nobody is moved when the session survives -------------------------------
reset_cur
T new-window -d -t '=cur:1'
out=$(kill_y 'W:cur:1')
wait_for "! T has-session -t '=cur:=1' 2>/dev/null" || true
if [ "$(client_sessions)" = cur ] && ! T has-session -t '=cur:=1' 2>/dev/null; then
  report "killing one of several windows leaves you where you are" pass
else
  report "killing one of several windows leaves you where you are" fail
  ERRORS+="    clients on: [$(client_sessions)]"$'\n'
fi
printf '%s' "$out" | grep -q 'session closes too' \
  && report "...and does not claim the session will close" fail \
  || report "...and does not claim the session will close" pass

[ -n "$(client_sessions)" ] || reset_cur
kill_y 'S:third' >/dev/null
wait_for "! T has-session -t '=third:' 2>/dev/null" || true
if [ "$(client_sessions)" = cur ] && ! T has-session -t '=third:' 2>/dev/null; then
  report "killing some other session leaves you where you are" pass
else
  report "killing some other session leaves you where you are" fail
  ERRORS+="    clients on: [$(client_sessions)]"$'\n'
fi

# --- a grouped session shares its windows -----------------------------------------
# Killing the last window of g1 empties its twin g2 as well, so a client on the
# TWIN goes down with it unless it is moved too.
[ -n "$(client_sessions)" ] || reset_cur
T new-session -d -s g1 -x 120 -y 30
T new-session -d -t g1 -s g2 -x 120 -y 30
T switch-client -c "$CLIENT" -t '=g2:' 2>/dev/null || true
wait_for '[ "$(client_sessions)" = g2 ]' || true
kill_y 'W:g1:0' >/dev/null
wait_for "! T has-session -t '=g2:' 2>/dev/null" || true
cs=$(client_sessions)
if [ -n "$cs" ] && [ "$cs" != g1 ] && [ "$cs" != g2 ] && ! T has-session -t '=g1:' 2>/dev/null; then
  report "a client on a grouped twin is moved off before the shared last window dies" pass
else
  report "a client on a grouped twin is moved off before the shared last window dies" fail
  ERRORS+="    clients on: [$cs]"$'\n'
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
