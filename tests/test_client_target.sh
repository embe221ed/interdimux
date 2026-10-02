#!/usr/bin/env bash
#
# Which CLIENT does the picker act on?
#
# Everything the script does to "the current client" -- switch-client on Enter,
# the kill dialog's border repaint, the popup a dashboard entry opens -- used to
# let tmux decide, and tmux decides by ACTIVITY: the attached client that
# pressed a key most recently.  Keys typed into a popup or a menu never count as
# activity (tmux hands them to the overlay first), so once the picker was open,
# one keystroke on another terminal attached to the same session made THAT one
# the current client:
#
#   * Enter switched the other terminal, and left yours where it was
#   * ctrl-x's danger repaint -- a display-popup with no -E -- opened a SHELL
#     popup on the other terminal and blocked there, so the kill dialog never
#     appeared on yours
#
# And the dashboard's entries dropped the pressing pane: run-shell hands its job
# the SERVER's global TMUX_PANE, which on a server started from inside another
# tmux is a pane id that does not exist here.  Every picker opened from prefix+g
# then resolved its options, its title and its current row against nothing.
#
# All of it needs real clients and real key presses (send-keys to a pane never
# reaches tmux's key table), so each case runs an inner server under test and an
# outer one whose panes hold `tmux attach` clients to it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BASE="interdimux-client-test-$$"
PASS=0
FAIL=0
ERRORS=""
SOCK="" OUTER=""

cleanup() {
  local s
  for s in $(ls "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)" 2>/dev/null | grep "^$BASE" || true); do
    tmux -L "$s" kill-server 2>/dev/null || true
  done
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
I() { tmux -L "$SOCK" "$@"; }    # the server under test
O() { tmux -L "$OUTER" "$@"; }   # the one whose panes are its clients
screen() { { O capture-pane -p -t "=$1:" 2>/dev/null || true; } | sed 's/\x1b\[[0-9;]*m//g'; }
wait_for() { # $1 = a command that must succeed; bounded poll, no fixed sleep
  local i
  for i in $(seq 1 ${2:-100}); do eval "$1" && return 0; sleep 0.1; done
  return 1
}
client_of() { O display-message -p -t "=$1:" '#{pane_tty}'; }   # outer pane -> inner client name
session_of() { { I list-clients -F '#{client_name} #{client_session}' 2>/dev/null || true; } | awk -v c="$1" '$1==c {print $2}'; }

# setup NAME SESS_A SESS_B [ROWS] -- fresh servers; outer sessions A and B hold
# clients attached to SESS_A / SESS_B; the plugin's bindings are installed.
setup() {
  local name="$1" sa="$2" sb="$3" rows="${4:-30}" s
  cleanup
  SOCK="$BASE-$name" OUTER="$BASE-$name-o"
  I -f /dev/null new-session -d -s demo -x 110 -y 30
  I set -g default-command 'bash --norc --noprofile -i'
  I respawn-pane -k -t '=demo:' 'bash --norc --noprofile -i'
  for s in other alpha beta zzhidden; do I new-session -d -s "$s" -x 110 -y 30; done
  O -f /dev/null new-session -d -s A -x 110 -y "$rows" "TMUX= tmux -L $SOCK attach -t $sa"
  O new-session -d -s B -x 110 -y "$rows" "TMUX= tmux -L $SOCK attach -t $sb"
  wait_for '[ "$(I list-clients | wc -l)" = 2 ]' || return 1
  TMUX="$(I display-message -p '#{socket_path}'),99999,0" bash "$SCRIPT" --bind-keys
  CA=$(client_of A) CB=$(client_of B)
}
press() { O send-keys -t "=$1:" "${@:2}"; }

echo "interdimux client-targeting tests"
echo

# --- Enter switches the client that opened the picker ---------------------------
if setup enter demo demo; then
  press A C-b; press A f
  wait_for "screen A | grep -q '❯'" || true
  press A -l other
  # Not just the query echoed: the cursor on an `other` row, once fzf has
  # filtered.  Enter on the echo alone could take the row the cursor was on
  # before the filter ran (it did, now and then, under the bash renderer).
  wait_for "screen A | grep -q '❯ other'" || true
  wait_for "screen A | grep '▌' | grep -q other" || true
  # a keystroke on B; once the pane has echoed it, tmux has counted it as B's
  # activity (that happens before the key reaches the pane)
  press B -l zq
  wait_for "I capture-pane -p -t '=demo:' | grep -q zq" || true
  press A Enter
  wait_for '[ "$(session_of "$CA")" = other ] || [ "$(session_of "$CB")" = other ]' || true
  a=$(session_of "$CA") b=$(session_of "$CB")
  if [ "$a" = other ] && [ "$b" = demo ]; then
    report "Enter switches the client that opened the picker, after a key on another client" pass
  else
    report "Enter switches the client that opened the picker, after a key on another client" fail
    ERRORS+="    picker client on '$a', other client on '$b' (want other / demo)"$'\n'
  fi
else
  report "two clients attach for the Enter case" fail
fi

# --- ctrl-x's dialog and its border repaint stay on that client ----------------------
if setup ctrlx demo demo; then
  press A C-b; press A f
  wait_for "screen A | grep -q '❯'" || true
  press B -l kq
  wait_for "I capture-pane -p -t '=demo:' | grep -q kq" || true
  press A C-x
  # the danger repaint runs BEFORE the dialog draws, so once the dialog is on A
  # any popup it could have opened elsewhere is already there
  if wait_for "screen A | grep -q 'Kill '" 60; then
    report "ctrl-x's confirm dialog appears on the client that pressed it" pass
  else
    report "ctrl-x's confirm dialog appears on the client that pressed it" fail
  fi
  if screen B | grep -q 'interdimux ·'; then
    report "...and no popup opens on the other client" fail
    ERRORS+="$(screen B | grep -v '^ *$' | head -3 | sed 's/^/      /' || true)"$'\n'
  else
    report "...and no popup opens on the other client" pass
  fi
  press A n
else
  report "two clients attach for the ctrl-x case" fail
fi

# --- a dashboard entry carries the pressing pane and client --------------------------
# The server's global TMUX_PANE is foreign: a pane of the OTHER client's session
# (the menu case) or an id that does not exist here (the fallback case) -- what a
# server started from inside another tmux inherits, and what run-shell hands its
# jobs.  The launched picker reads its options through the pane it was given, so
# an option set on the pressing client's SESSION only takes effect if the entry
# carried the right pane: the hidden session showing up means it did not.
dash_case() { # $1 = case name, $2 = outer rows (a short client gets the fzf fallback)
  local cname="$1" rows="$2" what="$3" foreign="$4"
  if ! setup "$cname" alpha beta "$rows"; then report "two clients attach ($what)" fail; return; fi
  I set -t beta @interdimux-hide zzhidden
  [ "$foreign" = alpha ] && foreign=$(I list-panes -t '=alpha:' -F '#{pane_id}' | head -1)
  I set-environment -g TMUX_PANE "$foreign"
  press B C-b; press B g
  if ! wait_for "screen B | grep -q 'Switch'"; then
    report "prefix+g opens the dashboard ($what)" fail; return
  fi
  if [ "$rows" -lt 17 ]; then
    # the fzf fallback: Switch is its first entry
    press B Enter
  else
    press B s
  fi
  if wait_for "screen B | grep -q 'interdimux · beta'" 100; then
    report "the dashboard's Switch opens on the pressing client, titled with its session ($what)" pass
  else
    report "the dashboard's Switch opens on the pressing client, titled with its session ($what)" fail
    ERRORS+="$(screen B | grep -v '^ *$' | head -3 | sed 's/^/      /' || true)"$'\n'
  fi
  # rows are drawn once the list has loaded; wait for one we expect, so that the
  # absence below is about hiding and not about timing.  Then ask for the hidden
  # session by name: in a short popup its row could simply be off-screen, and a
  # query brings a matching row into view (filtered, or focused in raw mode).
  wait_for "screen B | grep -q 'alpha'" || true
  press B -l zzhid
  wait_for "screen B | grep -q '❯ zzhid'" || true
  if screen B | grep -q '❯ zzhid' && ! screen B | grep -q 'zzhidden'; then
    report "...and it read the pressing session's options (its @interdimux-hide applies) ($what)" pass
  else
    report "...and it read the pressing session's options (its @interdimux-hide applies) ($what)" fail
    ERRORS+="$(screen B | grep -E 'alpha|zzhidden' | head -3 | sed 's/^/      /' || true)"$'\n'
  fi
  # Only meaningful when the foreign pane belongs to the other client's session:
  # a pane id that resolves to nothing leaves tmux to pick by activity, which
  # lands on the pressing client anyway.
  if [ "$4" = alpha ]; then
    screen A | grep -q 'interdimux ·' \
      && report "...and nothing opens on the other client ($what)" fail \
      || report "...and nothing opens on the other client ($what)" pass
  fi
}
dash_case menu 30 "native menu" alpha
dash_case fallback 14 "fzf fallback" '%99999'

# Both clients on ONE session: the pane cannot tell them apart, only the client
# can.  B opens the menu, A presses a key, B picks Switch -- a menu key is not
# activity either, so left to tmux the picker opened on A.
if setup dashsame beta beta; then
  press B C-b; press B g
  wait_for "screen B | grep -q 'Switch'" || true
  press A -l mq
  wait_for "I capture-pane -p -t '=beta:' | grep -q mq" || true
  press B s
  if wait_for "screen B | grep -q 'interdimux · beta'" 100; then
    report "with both clients on one session, the dashboard's picker opens on the one that asked" pass
  else
    report "with both clients on one session, the dashboard's picker opens on the one that asked" fail
  fi
  screen A | grep -q 'interdimux ·' \
    && report "...and not on the other" fail \
    || report "...and not on the other" pass
else
  report "two clients attach for the shared-session dashboard case" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
