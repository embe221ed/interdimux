#!/usr/bin/env bash
#
# Which terminal does an "interdimux: ..." status message land on?
#
# A display-message without -c lets tmux pick the client, and from a popup or a
# run-shell it picks the attached client with the latest keypress.  Keys typed
# into a popup or a menu do not count, so one keystroke on ANOTHER terminal
# attached to the same session makes that terminal the one tmux picks: the
# popup that failed closed with nothing shown, and the other terminal got the
# explanation.  imux_msg passes the pressing client (INTERDIMUX_CLIENT) as -c;
# three messages on the navigator's own paths bypassed it:
#
#   * find-or-create's "could not create a session from '...'"
#   * "cannot create a scratch file in ..." (the navigator cannot start)
#   * _report_stderr, the navigator's one-line report of its own stderr
#
# Each case runs with client B having the latest keypress and INTERDIMUX_CLIENT
# naming client A.  The oracle is tmux's message log (show-messages), which
# records each status message under the client that displayed it -- and records
# the text after format expansion, so it also shows what a '#' became.
#
# Real clients need real terminals: an outer server's panes run `tmux attach`
# to the server under test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-msgclient-test-$$"
OUTER="${SOCK}-o"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-msgclient.XXXXXX")" && pwd -P)"
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
I() { tmux -L "$SOCK" "$@"; }    # the server under test
O() { tmux -L "$OUTER" "$@"; }   # the one whose panes are its clients
wait_for() { # $1 = a command that must succeed; bounded poll, no fixed sleep
  local i
  for i in $(seq 1 ${2:-100}); do eval "$1" && return 0; sleep 0.1; done
  return 1
}

echo "interdimux status-message client tests"
echo

I -f /dev/null new-session -d -s demo -x 110 -y 30
I set -g default-command 'bash --norc --noprofile -i'
I respawn-pane -k -t '=demo:' 'bash --norc --noprofile -i'
O -f /dev/null new-session -d -s A -x 110 -y 30 "TMUX= tmux -L $SOCK attach -t demo"
O new-session -d -s B -x 110 -y 30 "TMUX= tmux -L $SOCK attach -t demo"
if ! wait_for '[ "$(I list-clients | wc -l)" = 2 ]'; then
  report "setup: two clients attach" fail
  echo; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
CA=$(O display-message -p -t '=A:' '#{pane_tty}')
CB=$(O display-message -p -t '=B:' '#{pane_tty}')

# B presses a key; once the pane has echoed it, tmux has counted it as B's
# activity (that happens before the key reaches the pane).
O send-keys -t '=B:' -l mq
wait_for "I capture-pane -p -t '=demo:' | grep -q mq" || true

# Control: left to itself, tmux now picks B -- so a message that reaches A below
# got there because it named A, not by luck.
got=$(I display-message -p '#{client_name}' 2>/dev/null || true)
[ "$got" = "$CB" ] \
  && report "control: with B's key the latest, tmux's own pick is B" pass \
  || report "control: with B's key the latest, tmux's own pick is B (got '$got', B is '$CB')" fail

export TMUX="$(I display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(I list-panes -t '=demo:' -F '#{pane_id}' | head -1)"
export INTERDIMUX_CLIENT="$CA"
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state" XDG_CACHE_HOME="$TMPD/cache"
export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_HYDRATE=off

# The client each logged message with this exact text was shown on.
shown_on() { # $1 = the message text as tmux logged it
  { I show-messages 2>/dev/null || true; } \
    | awk -v want="message: $1" 'index($0, want) { i = index($0, ": "); rest = substr($0, i + 2); split(rest, a, " "); print a[1] }'
}
last_msgs() { { I show-messages 2>/dev/null || true; } | grep 'message:' | tail -3 | sed 's/^/      /'; }
check_on_a() { # $1 = label, $2 = the start of the logged text ('#'-free)
  local label="$1" text="$2" where
  wait_for '[ -n "$(shown_on "$text")" ]' 50 || true
  where=$(shown_on "$text" | sort -u | tr '\n' ' ')
  if [ "$where" = "$CA " ]; then
    report "$label: shown on the client that asked" pass
  else
    report "$label: shown on the client that asked" fail
    ERRORS+="    shown on: '${where}' (A is $CA, B is $CB)"$'\n'"$(last_msgs)"$'\n'
  fi
}
check_text() { # $1 = label, $2 = the whole text as it must be logged
  if [ -n "$(shown_on "$2")" ]; then
    report "$1" pass
  else
    report "$1" fail
    ERRORS+="    want: $2"$'\n'"$(last_msgs)"$'\n'
  fi
}

# --- find-or-create that cannot create anything -------------------------------------
rc=0; bash "$SCRIPT" --create-from-query '' >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] && report "control: find-or-create on an empty query fails" pass \
              || report "control: find-or-create on an empty query fails (rc=$rc)" fail
check_on_a "find-or-create's failure" "interdimux: could not create a session from ''"

# --- the navigator has nowhere to put its scratch files --------------------------------
# No runtime dir, a TMPDIR and a state dir that cannot exist ('#S' in them, which
# must come out as written).
rc=0
env -u XDG_RUNTIME_DIR TMPDIR="/proc/imux-none#S" XDG_STATE_HOME="/proc/imux-none#S" \
  timeout 20 bash "$SCRIPT" </dev/null >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] && report "control: the navigator stops without a scratch file" pass \
              || report "control: the navigator stops without a scratch file (rc=$rc)" fail
check_on_a "the scratch-file error" "interdimux: cannot create a scratch file in /proc/imux-none"
check_text "...naming the directories as they are ('#S' included)" \
  "interdimux: cannot create a scratch file in /proc/imux-none#S or /proc/imux-none#S/interdimux (see --doctor)"

# --- the navigator reports its own stderr ----------------------------------------------
# A stand-in fzf that fails the way a bad @interdimux-fzf-opts does: a line on
# stderr and a non-zero exit.  The line carries a '#S', which must reach the
# status line as written -- not as the session's name, and not doubled.
mkdir -p "$TMPD/bin"
cat > "$TMPD/bin/fzf" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in --version) echo "0.74.0 (stub)"; exit 0 ;; esac
cat >/dev/null
echo 'stub-fzf: unknown option #S-flag' >&2
exit 2
STUB
chmod +x "$TMPD/bin/fzf"
PATH="$TMPD/bin:$PATH" timeout 20 bash "$SCRIPT" </dev/null >/dev/null 2>&1 || true
if grep -q 'stub-fzf: unknown option' "$TMPD/state/interdimux/errors.log" 2>/dev/null; then
  report "control: the navigator saw the stand-in fzf's error" pass
else
  report "control: the navigator saw the stand-in fzf's error" fail
fi
check_on_a "the navigator's stderr report" "interdimux: stub-fzf: unknown option "
check_text "...with its '#S' as written, neither expanded nor doubled" \
  "interdimux: stub-fzf: unknown option #S-flag"

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
