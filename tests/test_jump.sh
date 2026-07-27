#!/usr/bin/env bash
#
# --jump N: switch to the Nth session in the picker's own ordering.
#
# The whole value of the feature is that the number is a promise — press the
# same key, land in the same place — so the assertions are about agreement
# between what the picker WOULD show and where the jump LANDS, never against a
# hardcoded session name.
#
# The keypress half needs a real client: send-keys writes to a pane's pty and
# never reaches tmux's key table, so an outer tmux types into a client attached
# to the server under test.
#
# It also pins down a trap that made the first implementation wrong: `run-shell`
# does NOT derive TMUX_PANE from the pressing client. It passes the tmux
# SERVER's global environment, which holds whatever TMUX_PANE the process that
# started the server exported. A server started from inside another tmux carries
# a pane id that does not exist in it, tmux resolves `-t` against that
# arbitrarily rather than failing, and the current-session detection — which is
# what parks the current session last — silently answers for the wrong session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-jump-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-jump.XXXXXX")"
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

echo "interdimux --jump tests"
echo

tmux -f /dev/null -L "$SOCK" new-session -d -s aaa -x 120 -y 30
for n in bbb ccc ddd; do
  tmux -L "$SOCK" new-session -d -s "$n" -x 120 -y 30
  sleep 0.3   # distinct session_activity, so the MRU order is not a tie
done
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=aaa:' -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off

order() { # the session names the picker would show, in order
  bash "$SCRIPT" --list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
    | awk -F'\t' '$4 ~ /^S:/ { print substr($4, 3) }'
}
nth() { order | sed -n "${1}p"; }
attached() { tmux -L "$SOCK" list-clients -F '#{client_session}' 2>/dev/null | head -1; }

# --- the ordering promise, in-process -----------------------------------------
tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 120 -y 30 \
  "TMUX= tmux -L $SOCK attach -t aaa"
for _i in $(seq 1 60); do [ -n "$(attached)" ] && break; sleep 0.1; done

if [ -n "$(attached)" ]; then
  report "a client is attached to drive switches" pass
else
  report "a client is attached to drive switches" fail
  echo; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# The current session is parked last under MRU, so it must NOT be #1.
cur=$(tmux -L "$SOCK" display-message -p -t "$TMUX_PANE" '#S')
if [ "$(nth 1)" != "$cur" ]; then
  report "the current session is not #1 (it is parked last under MRU)" pass
else
  report "the current session is not #1 (it is parked last under MRU)" fail
  ERRORS+="    order: $(order | tr '\n' ' ')"$'\n'
fi

for n in 1 2 3; do
  want=$(nth "$n")
  bash "$SCRIPT" --jump "$n" >/dev/null 2>&1 || true
  for _i in $(seq 1 40); do [ "$(attached)" = "$want" ] && break; sleep 0.1; done
  got=$(attached)
  if [ "$got" = "$want" ]; then
    report "--jump $n lands on the Nth session the picker shows ($got)" pass
  else
    report "--jump $n lands on the Nth session the picker shows" fail
    ERRORS+="    want $want, got $got; order: $(order | tr '\n' ' ')"$'\n'
  fi
done

# --- bad input is refused, not guessed at ---------------------------------------
for bad in "" abc 0 -1 2.5; do
  if bash "$SCRIPT" --jump "$bad" >/dev/null 2>&1; then
    report "--jump '$bad' is refused" fail
  else
    report "--jump '$bad' is refused" pass
  fi
done

before=$(attached)
if bash "$SCRIPT" --jump 999 >/dev/null 2>&1; then
  report "--jump past the end is refused" fail
else
  report "--jump past the end is refused" pass
fi
if [ "$(attached)" = "$before" ]; then
  report "...and changes nothing" pass
else
  report "...and changes nothing" fail
fi

# --- @interdimux-jump-keys installs root-table bindings, opt-in -------------------
if tmux -L "$SOCK" list-keys -T root 2>/dev/null | grep -q -- '--jump'; then
  report "no jump keys are bound before the option is set" fail
else
  report "no jump keys are bound before the option is set" pass
fi

tmux -L "$SOCK" set -g @interdimux-jump-keys 'M-1 M-2 M-3'
bash "$SCRIPT" --bind-keys
n_bound=$(tmux -L "$SOCK" list-keys -T root 2>/dev/null | grep -c -- '--jump' || true)
if [ "$n_bound" = 3 ]; then
  report "@interdimux-jump-keys binds one root-table key per position" pass
else
  report "@interdimux-jump-keys binds one root-table key per position (got $n_bound)" fail
fi

# --- THE KEYPRESS PATH, against a deliberately stale server TMUX_PANE -------------
# Compare against the order computed IN THE KEYPRESS CONTEXT, not this shell's:
# the two differ precisely when the pane id is wrong, which is the bug.
tmux -L "$SOCK" set-environment -g TMUX_PANE '%99999'
tmux -L "$SOCK" bind-key -n M-9 run-shell -b \
  "TMUX_PANE=#{pane_id} bash '$SCRIPT' --list > '$TMPD/ctx.txt' 2>&1"

ctx_nth() { # the Nth session as the keypress context sees it
  rm -f "$TMPD/ctx.txt"
  tmux -L "$OUTER" send-keys -t '=drv:' M-9
  local i
  for i in $(seq 1 60); do [ -s "$TMPD/ctx.txt" ] && break; sleep 0.1; done
  sed 's/\x1b\[[0-9;]*m//g' "$TMPD/ctx.txt" \
    | awk -F'\t' '$4 ~ /^S:/ { print substr($4, 3) }' | sed -n "${1}p"
}

for k in 1 2; do
  want=$(ctx_nth "$k")
  tmux -L "$OUTER" send-keys -t '=drv:' "M-$k"
  for _i in $(seq 1 40); do [ "$(attached)" = "$want" ] && break; sleep 0.1; done
  got=$(attached)
  if [ -n "$want" ] && [ "$got" = "$want" ]; then
    report "pressing M-$k lands on session #$k even with a stale server TMUX_PANE ($got)" pass
  else
    report "pressing M-$k lands on session #$k even with a stale server TMUX_PANE" fail
    ERRORS+="    want '$want', got '$got'"$'\n'
  fi
done

# ...and the binding really does carry the pane id, rather than trusting the
# server environment it would otherwise inherit
if tmux -L "$SOCK" list-keys -T root 2>/dev/null | grep -- '--jump 1' | grep -q 'TMUX_PANE=#{pane_id}'; then
  report "the jump binding passes the pressing client's pane explicitly" pass
else
  report "the jump binding passes the pressing client's pane explicitly" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
