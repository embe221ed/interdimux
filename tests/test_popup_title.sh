#!/usr/bin/env bash
#
# The popup's frame title names the session you are in, and a session name is
# DATA there, never a format (review SEC-05).
#
# The title is a tmux format at two places: display-popup expands its -T, and
# the baked prefix+f binding is a `run-shell -C`, which expands its whole
# command once more before display-popup ever sees it.  connect_dir stores a
# directory's name verbatim (esc_fmt), so a project directory named
#
#     x#(tmux set -g @pwned yes)
#
# became a session whose name RAN AS A SHELL COMMAND on every prefix+f and every
# --launch in that session -- reproduced on tmux 3.7b, and the title then showed
# the command's output where the name should be.  The tamer case is the same
# bug: a session named g#Sh (typed as g##Sh) was titled "gg#Shh".
#
# The oracles are what tmux actually drew -- the popup is opened in a real
# client (an outer tmux attached to the one under test) and the frame read back
# -- and a server option the injected command would have set.  prefix+f is a
# real key press through that client: send-keys to the inner pane would never
# reach the key table.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-ptitle-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-ptitle.XXXXXX")"
TMPD="$(cd "$TMPD" && pwd -P)"
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
screen() { tmux -L "$OUTER" capture-pane -p -t '=drv:' 2>/dev/null; }
# the line of the outer screen that holds the popup's title, if one is drawn
title_line() { screen | grep -m1 'interdimux ·' || true; }

echo "interdimux popup-title tests"
echo

T -f /dev/null new-session -d -s home -x 130 -y 40 -c "$TMPD"
T set -g default-command 'bash --norc --noprofile -i'
export TMUX="$(T display-message -p '#{socket_path}'),99999,0"
unset TMUX_PANE INTERDIMUX_CLIENT
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state" XDG_CONFIG_HOME="$TMPD/config"
export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off

tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 130 -y 40 \
  "TMUX= TERM=xterm-256color tmux -L $SOCK attach -t home"
wait_for '[ -n "$(T list-clients 2>/dev/null)" ]' || { echo "no client attached"; exit 1; }

pwned() { T show -gv @pwned 2>/dev/null || true; }

# The injected command addresses THIS suite's server, by name: a directory name
# cannot hold a '/', and the socket name has no '.' or ':' for tmux to rewrite.
EVIL="x#(tmux -L $SOCK set -g @pwned yes)"
mkdir -p "$TMPD/$EVIL"
bash "$SCRIPT" --connect-dir "$TMPD/$EVIL" >/dev/null 2>&1 || true
if T list-sessions -F '#{session_name}' | grep -qxF "$EVIL"; then
  report "a '#(...)' directory becomes a session of that exact name (precondition)" pass
else
  report "a '#(...)' directory becomes a session of that exact name (precondition)" fail
  ERRORS+="    sessions: $(T list-sessions -F '#{session_name}' | tr '\n' '|')"$'\n'
fi
# connect_dir switched the one client to it; every title below is for this one
wait_for '[ "$(T display-message -p "#{client_session}" 2>/dev/null)" = "$EVIL" ]' || true
EVIL_PANE=$(T list-panes -t "=$EVIL:" -F '#{pane_id}' 2>/dev/null | head -1 || true)

# open_launch TITLE-TEXT -> --launch switch from the hostile session; the title
# line as drawn, once TITLE-TEXT is on screen (or whatever is there after 10 s)
open_launch() {
  TMUX_PANE="$EVIL_PANE" bash "$SCRIPT" --launch switch >/dev/null 2>&1 &
  LPID=$!
  wait_for "screen | grep -qF -- '$1'" || true
  TITLE=$(title_line)
}
# open_prefix_f TITLE-TEXT -> the same for a real prefix+f
open_prefix_f() {
  tmux -L "$OUTER" send-keys -t '=drv:' C-b
  wait_for '[ "$(T list-clients -F "#{client_key_table}" | head -1)" = prefix ]' 50 || true
  tmux -L "$OUTER" send-keys -t '=drv:' f
  wait_for "screen | grep -qF -- '$1'" || true
  TITLE=$(title_line)
}
# Escape quits the picker, which closes its popup; the next case starts clean
close_popup() {
  tmux -L "$OUTER" send-keys -t '=drv:' Escape
  if [ -n "$LPID" ]; then
    wait_for "! kill -0 $LPID 2>/dev/null" || kill "$LPID" 2>/dev/null || true
    wait "$LPID" 2>/dev/null || true
    LPID=""
  fi
  wait_for '! screen | grep -q "interdimux ·"' || true
}
# A '#(...)' job is started at expansion time, before the popup is drawn, and
# is asynchronous.  A synchronous run-shell queued behind it is a bounded wait
# for it to have finished, instead of a fixed sleep.
settle() { T run-shell 'true' 2>/dev/null || true; }

# --- --launch ---------------------------------------------------------------------
open_launch " interdimux · $EVIL "
settle
case "$TITLE" in
  *" interdimux · $EVIL "*) report "--launch: the title shows a '#(...)' session name verbatim" pass ;;
  *) report "--launch: the title shows a '#(...)' session name verbatim" fail
     ERRORS+="    drawn: [$TITLE]"$'\n' ;;
esac
if [ -z "$(pwned)" ]; then
  report "--launch: ...and the command in the name does not run" pass
else
  report "--launch: ...and the command in the name does not run" fail
fi
close_popup
T set -gu @pwned 2>/dev/null || true

# --- a real prefix+f --------------------------------------------------------------
bash "$SCRIPT" --bind-keys
open_prefix_f " interdimux · $EVIL "
settle
case "$TITLE" in
  *" interdimux · $EVIL "*) report "prefix+f: the title shows a '#(...)' session name verbatim" pass ;;
  *) report "prefix+f: the title shows a '#(...)' session name verbatim" fail
     ERRORS+="    drawn: [$TITLE]"$'\n' ;;
esac
if [ -z "$(pwned)" ]; then
  report "prefix+f: ...and the command in the name does not run" pass
else
  report "prefix+f: ...and the command in the name does not run" fail
fi
close_popup
T set -gu @pwned 2>/dev/null || true

# --- '#S' in a name is text too ------------------------------------------------------
# Typed as g##Sh, because tmux expands a name it is given; what is stored, and
# what the title must show, is g#Sh.  As a format it read "gg#Shh".
T rename-session -t "=$EVIL" 'g##Sh'
if T has-session -t '=g#Sh' 2>/dev/null; then
  open_launch ' interdimux · g#Sh '
  case "$TITLE" in
    *' interdimux · g#Sh '*) report "--launch: a session named g#Sh is titled g#Sh" pass ;;
    *) report "--launch: a session named g#Sh is titled g#Sh" fail; ERRORS+="    drawn: [$TITLE]"$'\n' ;;
  esac
  close_popup
  open_prefix_f ' interdimux · g#Sh '
  case "$TITLE" in
    *' interdimux · g#Sh '*) report "prefix+f: a session named g#Sh is titled g#Sh" pass ;;
    *) report "prefix+f: a session named g#Sh is titled g#Sh" fail; ERRORS+="    drawn: [$TITLE]"$'\n' ;;
  esac
  close_popup
else
  report "the session can be renamed to g#Sh (precondition)" fail
fi

# --- an ordinary name is unchanged -------------------------------------------------
T rename-session -t '=g#Sh' plain
open_prefix_f ' interdimux · plain '
case "$TITLE" in
  *' interdimux · plain '*) report "prefix+f: an ordinary session name is titled as before" pass ;;
  *) report "prefix+f: an ordinary session name is titled as before" fail; ERRORS+="    drawn: [$TITLE]"$'\n' ;;
esac
close_popup

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
exit 0
