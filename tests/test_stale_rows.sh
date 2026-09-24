#!/usr/bin/env bash
#
# A window row whose window has closed must not act on the window that took
# its NUMBER as a NAME.
#
# A row names its window by index ("W:st:3"), and spec_target turns that into
# "=st:=3".  The '=' stops tmux's prefix and glob matching, but not its exact
# NAME fallback: once index 3 has closed, "=st:=3" finds a window CALLED "3",
# wherever it sits.  --action compares the indices tmux answers with, and says
# the row is gone.  The preview, Enter and the swap picker's destination did
# not: the preview showed that other window's screen under the row for st:3,
# Enter switched to it, and a swap swapped with it.
#
# The list is a snapshot, so a stale row is routine: open the picker, and close
# a window from another client before choosing.  Each case below builds that
# snapshot for real -- the row is listed while its window exists, which is
# then killed while the picker is open.
#
# Oracles are tmux's own state: which window the client is on afterwards, what
# is at each index, what the server logged.  Enter and the swap picker need a
# real terminal for fzf, so an outer tmux holds it and types into it, and a
# second outer pane holds a real client of the server under test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-stale-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-stale.XXXXXX")" && pwd -P)"
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
I() { tmux -L "$SOCK" "$@"; }    # the server under test
O() { tmux -L "$OUTER" "$@"; }   # the terminals: a client of it, and the picker
wait_for() { # $1 = a command that must succeed, $2 = tenths of a second (default 150)
  local i
  for i in $(seq 1 "${2:-150}"); do eval "$1" && return 0; sleep 0.1; done
  return 1
}
screen() { { O capture-pane -p -t "=$1:" 2>/dev/null || true; } | sed 's/\x1b\[[0-9;]*m//g'; }
windows() { I list-windows -t '=st:' -F '#{window_index}:#{window_name}' 2>/dev/null | tr '\n' ' '; }

echo "interdimux stale-row tests"
echo

# st: window 3 is the row's; window 7 is NAMED "3", the one a stale "=st:=3"
# falls back to.  automatic-rename off, or the names become the command.
I -f /dev/null new-session -d -s home -x 120 -y 30 -c "$TMPD" 'sleep 99999'
I set -g automatic-rename off
I new-session -d -s st -n zero -x 120 -y 30 -c "$TMPD" "printf 'WINDOW-ZERO\n'; sleep 99999"
new_three() { I new-window -d -t '=st:3' -n target-three -c "$TMPD" "printf 'WINDOW-THREE\n'; sleep 99999"; }
new_three
I new-window -d -t '=st:5' -n five-live -c "$TMPD" "printf 'WINDOW-FIVE\n'; sleep 99999"
# a second pane in 5, NOT the active one: its command is the only 88888 anywhere,
# so it is the query that picks that pane's row alone
I split-window -d -t '=st:=5' -c "$TMPD" "printf 'PANE-FIVE-ONE\n'; sleep 88888"
I new-window -d -t '=st:7' -n 3 -c "$TMPD" "printf 'WINDOW-SEVEN\n'; sleep 99999"
I select-window -t '=st:=0'
export TMUX="$(I display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(I list-panes -t '=home:' -F '#{pane_id}' | head -1)"
export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off INTERDIMUX_HYDRATE=off INTERDIMUX_SHOW_PREVIEW=off
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state" XDG_CACHE_HOME="$TMPD/cache"
unset INTERDIMUX_CLIENT
for m in 3:WINDOW-THREE 7:WINDOW-SEVEN 5.1:PANE-FIVE-ONE; do
  wait_for "I capture-pane -p -t '=st:=${m%%:*}' 2>/dev/null | grep -q '${m#*:}'" \
    || { echo "  setup: window ${m%%:*} never drew ${m#*:}"; exit 1; }
done

preview() { bash "$SCRIPT" --preview "$1" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }

# --- the preview ------------------------------------------------------------------
case "$(preview 'W:st:3')" in
  *WINDOW-THREE*) report "control: the preview of st:3 shows window 3 while it exists" pass ;;
  *) report "control: the preview of st:3 shows window 3 while it exists" fail ;;
esac

I kill-window -t '=st:=3'
# The trap is set: tmux's own resolution of the row's target is now window 7.
if [ "$(I display-message -p -t '=st:=3' '#{window_index}' 2>/dev/null)" = 7 ]; then
  report "premise: with index 3 gone, tmux resolves '=st:=3' to the window named 3" pass
else
  report "premise: with index 3 gone, tmux resolves '=st:=3' to the window named 3" fail
fi

for spec in W:st:3 P:st:3:0; do
  out=$(preview "$spec")
  case "$out" in
    *WINDOW-SEVEN*) report "the preview of a stale $spec does not show the window named 3" fail
                    ERRORS+="$(printf '%s\n' "$out" | grep -v '^ *$' | head -3 | sed 's/^/      /')"$'\n' ;;
    *) report "the preview of a stale $spec does not show the window named 3" pass ;;
  esac
  head1=$(printf '%s\n' "$out" | head -1)
  case "$head1" in
    *'? · ?'*) report "...and its header says it knows nothing about it" pass ;;
    *) report "...and its header says it knows nothing about it (got: $head1)" fail ;;
  esac
done
for spec in W:st:7 P:st:7:0; do
  case "$(preview "$spec")" in
    *WINDOW-SEVEN*) report "control: the preview of the live $spec still shows it" pass ;;
    *) report "control: the preview of the live $spec still shows it" fail ;;
  esac
done
case "$(preview 'P:st:5:1')" in
  *PANE-FIVE-ONE*) report "control: the preview of a live pane row shows that pane" pass ;;
  *) report "control: the preview of a live pane row shows that pane" fail ;;
esac

# --- Enter --------------------------------------------------------------------------
# One outer pane holds a real client of the server under test (on `home`); the
# navigator runs in another, switching THAT client (INTERDIMUX_CLIENT), as a
# popup opened from it would.
O -f /dev/null new-session -d -s cli -x 120 -y 30 "TMUX= tmux -L $SOCK attach -t home"
if ! wait_for '[ "$(I list-clients 2>/dev/null | wc -l)" = 1 ]'; then
  report "setup: a real client attaches" fail
  echo; echo "Results: $PASS passed, $FAIL failed"; printf '%s' "$ERRORS"; exit 1
fi
CL=$(I list-clients -F '#{client_name}')
where() { I list-clients -F '#{client_session}:#{window_index}.#{pane_index}' 2>/dev/null; }

# open NAME ARGS... -- the script in outer session NAME, on a real terminal;
# DONE-NAME is printed when it exits.  Waits for fzf's prompt.
open() {
  local name="$1"; shift
  O kill-session -t "=$name" 2>/dev/null || true
  O new-session -d -s "$name" -x 120 -y 30 -c "$TMPD" \
    "env TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' INTERDIMUX_CLIENT='$CL' \
         XDG_DATA_HOME='$TMPD/data' XDG_STATE_HOME='$TMPD/state' XDG_CACHE_HOME='$TMPD/cache' \
         INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
         INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off INTERDIMUX_HYDRATE=off \
         INTERDIMUX_SHOW_PREVIEW=off \
         bash '$SCRIPT' $*; echo DONE-$name; sleep 60"
  # 25 s: the first draw runs a whole gather, and the box may be busy
  wait_for "screen $name | grep -q 'five-live'" 250
}
# pick NAME QUERY -- type QUERY and wait until it matches exactly one row
pick() {
  O send-keys -t "=$1:" -l "$2"
  wait_for "screen $1 | grep -qE '❯ $2 .* 1/[0-9]+'" 100
}
enter() { # $1 = outer session; waits for the script to exit
  O send-keys -t "=$1:" Enter
  wait_for "screen $1 | grep -q 'DONE-$1'" 150
}
home() { I switch-client -c "$CL" -t '=home:' 2>/dev/null; wait_for '[ "$(where)" = home:0.0 ]' 50; }

# control: a live window row lands on that window
home
if open nav && pick nav five-live && enter nav; then
  got=$(where)
  [ "$got" = st:5.0 ] && report "control: Enter on a live window row lands on it" pass \
                      || report "control: Enter on a live window row lands on it (on $got)" fail
else
  report "control: Enter on a live window row lands on it (the picker did not run: $(screen nav | grep -m1 '❯'))" fail
fi

# control: a live pane row lands on that pane, not on its window's active one
home
if open nav && pick nav 'sleep 88888' && enter nav; then
  got=$(where)
  [ "$got" = st:5.1 ] && report "control: Enter on a live pane row lands on that pane" pass \
                      || report "control: Enter on a live pane row lands on that pane (on $got)" fail
else
  report "control: Enter on a live pane row lands on that pane (the picker did not run)" fail
fi

# the stale row: listed while window 3 exists, killed before Enter
home
new_three
I select-window -t '=st:=0'
if open nav && pick nav target-three; then
  I kill-window -t '=st:=3'
  if enter nav; then
    got=$(where)
    [ "$got" = home:0.0 ] && report "Enter on a stale window row goes nowhere, not to the window named 3" pass \
                          || report "Enter on a stale window row goes nowhere, not to the window named 3 (on $got)" fail
    if I show-messages 2>/dev/null | grep -qF "interdimux: window 'st:3' no longer exists"; then
      report "...and says the window no longer exists" pass
    else
      report "...and says the window no longer exists" fail
    fi
  else
    report "Enter on a stale window row (the picker did not exit)" fail
  fi
else
  report "Enter on a stale window row (the row could not be picked: $(screen nav | grep -m1 '❯'))" fail
fi

# --- the swap picker's destination ---------------------------------------------------
# Swap five-live with the row for st:3, which closes while the picker is open.
new_three
before=$(windows)
if open swp --action swap "'W:st:5'" && pick swp target-three; then
  I kill-window -t '=st:=3'
  if enter swp; then
    after=$(windows)
    if [ "$before" = "0:zero 3:target-three 5:five-live 7:3 " ] && [ "$after" = "0:zero 5:five-live 7:3 " ]; then
      report "a stale swap destination swaps nothing, not the window named 3" pass
    else
      report "a stale swap destination swaps nothing, not the window named 3" fail
      ERRORS+="      windows before: $before"$'\n'"      windows after:  $after"$'\n'
    fi
    if I show-messages 2>/dev/null | grep -qF "interdimux: window 'st:3' no longer exists, so nothing was swapped"; then
      report "...and says why" pass
    else
      report "...and says why" fail
    fi
  else
    report "a stale swap destination (the swap did not finish)" fail
  fi
else
  report "a stale swap destination (the row could not be picked: $(screen swp | grep -m1 '❯'))" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
