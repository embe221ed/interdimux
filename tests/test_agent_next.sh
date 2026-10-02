#!/usr/bin/env bash
#
# --agent-next: switch to the next agent that needs you, and the opt-in prefix
# key for it, @interdimux-agent-next-key (review AGENT-10).
#
#   * from a pane that is not one of them, the first in --agents order: the
#     approval that has waited longest, in whichever session;
#   * from one of them, the one AFTER it, wrapping -- so repeated presses
#     visit A, B, C, A, where "the first that is not the current pane" would
#     go back and forth between A and B and never reach C;
#   * STATES picks which ones (approve,input by default); a word that is no
#     state is refused with exit 2;
#   * with none, the status line says "no agent needs you" and the client
#     stays where it is;
#   * the key: unset, --bind-keys binds nothing for it; set, prefix+<key>
#     runs it for the pressing client and pane, and --doctor knows the option
#     and checks the key as it checks the others.
#
# The keypress half needs a real client: an outer private server types into a
# client attached to the server under test (the harness of tests/test_jump.sh).
# The agents are fakes (`exec -a`, pane options, registry records written here
# into INTERDIMUX_CLAUDE_DIR, never ~/.claude).  Where the client lands is
# tmux's own answer (list-clients), compared with pane ids written out here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-agentnext-test-$$"
OUTER="$SOCK-outer"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-agentnext.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$OUTER"
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
same() { if [ "$2" = "$3" ]; then report "$1" pass; else report "$1 (got: '$2', want: '$3')" fail; fi; }

echo "interdimux --agent-next tests"
echo

if [ ! -r /proc/self/stat ]; then
  echo "  (skipped: needs /proc for the registry's pid check)"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

unset TMUX TMUX_PANE
export LC_ALL=C.UTF-8 LANG=C.UTF-8
# The server under test starts from this environment, and so does every
# run-shell a key runs there: the registry and the config dirs are fixtures.
export XDG_CONFIG_HOME="$TMPD/config" XDG_STATE_HOME="$TMPD/state" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_CLAUDE_DIR="$TMPD/claude-home"
mkdir -p "$INTERDIMUX_CLAUDE_DIR/sessions"

mk() { # name, title (no single quote), argv0, seconds
  cat > "$TMPD/$1" <<EOF
#!/usr/bin/env bash
printf '\\033]0;%s\\007' '$2'
exec -a '$3' sleep $4
EOF
  chmod +x "$TMPD/$1"
}
mk claudeA '✳ Fix the parser' claude 979
mk claudeB '✳ Review the API' claude 978
mk plain   'whatever'         sleep  977

tin() { tmux -L "$SOCK" "$@"; }
tin -f /dev/null new-session -d -s home -x 100 -y 30 -c "$TMPD" "exec bash --norc --noprofile -i"
tin set -g default-command 'bash --norc --noprofile -i'
tin new-session -d -s aa -x 100 -y 30 -c "$TMPD" "exec bash --norc --noprofile -i"
tin new-window -d -t '=aa:' -n cb -c "$TMPD" "exec '$TMPD/claudeB'"
tin new-window -d -t '=aa:' -n in -c "$TMPD" "exec '$TMPD/plain'"
tin new-session -d -s zz -x 100 -y 30 -c "$TMPD" "exec bash --norc --noprofile -i"
tin new-window -d -t '=zz:' -n ca -c "$TMPD" "exec '$TMPD/claudeA'"
tin new-window -d -t '=zz:' -n wk -c "$TMPD" "exec '$TMPD/plain'"
tin set -p -t '=aa:in' @agent_state input
tin set -p -t '=zz:wk' @agent_state working

pane_of() { tin display-message -p -t "$1" '#{pane_id}'; }
A=$(pane_of '=zz:ca') B=$(pane_of '=aa:cb') C=$(pane_of '=aa:in') W=$(pane_of '=zz:wk')
HOME_P=$(pane_of '=home:')
argv_is() { [[ "$(tr '\0' ' ' < "/proc/$(tin display-message -p -t "$1" '#{pane_pid}')/cmdline")" == "$2 "* ]]; }
for _ in $(seq 1 100); do argv_is '=zz:ca' claude && argv_is '=aa:cb' claude && break; sleep 0.05; done

# Claude's registry: A and B wait for a permission, A since longer -- though
# its session is listed after B's, it comes first.
record() { # window, statusUpdatedAt
  local pane pid st
  pane=$(pane_of "$1"); pid=$(tin display-message -p -t "$1" '#{pane_pid}')
  read -r -a st < "/proc/$pid/stat"
  printf '{"pid":%s,"sessionId":"x","cwd":"/tmp","startedAt":1,"procStart":"%s","version":"2.1.281","kind":"interactive","entrypoint":"cli","tmux":"t:@1.%s","name":"n","status":"waiting","waitingFor":"permission prompt","statusUpdatedAt":%s}' \
    "$pid" "${st[21]}" "$pane" "$2" > "$INTERDIMUX_CLAUDE_DIR/sessions/$pid.json"
}
record '=zz:ca' 1700000000000
record '=aa:cb' 1700000600000

tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 100 -y 30 \
  "TMUX= tmux -L $SOCK attach -t home"
client() { tin list-clients -F '#{client_name}' 2>/dev/null | head -1; }
for _ in $(seq 1 100); do [ -n "$(client)" ] && break; sleep 0.05; done
CLIENT=$(client)
if [ -n "$CLIENT" ]; then
  report "a client is attached to drive the switches" pass
else
  report "a client is attached to drive the switches" fail
  echo; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
at() { tin list-clients -F '#{pane_id}' 2>/dev/null | head -1; }   # the client's pane
wait_at() { local i; for i in $(seq 1 60); do [ "$(at)" = "$1" ] && return 0; sleep 0.05; done; return 1; }

export TMUX="$(tin display-message -p '#{socket_path}'),99999,0"
# As the key binding runs it: the pressing client and the pane it is in.
next() { TMUX_PANE="$(at)" INTERDIMUX_CLIENT="$CLIENT" bash "$SCRIPT" --agent-next "$@" 2>"$TMPD/err"; }

# --- the cycle -------------------------------------------------------------------------
same "the client starts at home" "$(at)" "$HOME_P"
for step in "A:$A" "B:$B" "C:$C" "A:$A"; do
  rc=0; next || rc=$?
  wait_at "${step#*:}" || :
  same "--agent-next goes on to ${step%%:*} (exit $rc)" "$(at)" "${step#*:}"
done

tin switch-client -c "$CLIENT" -t "$W"; wait_at "$W" || :
next || :; wait_at "$A" || :
same "from an agent that does not need you (working), the first: A" "$(at)" "$A"

tin switch-client -c "$CLIENT" -t "$HOME_P"; wait_at "$HOME_P" || :
next input || :; wait_at "$C" || :
same "--agent-next input: only the one asking" "$(at)" "$C"
next working || :; wait_at "$W" || :
same "--agent-next working: any state can be asked for" "$(at)" "$W"

for bad in bogus approve,nope; do
  rc=0; next "$bad" || rc=$?
  same "--agent-next '$bad' is refused with exit 2" "$rc" 2
done
grep -q 'usage: --agent-next' "$TMPD/err" && report "...saying how it is used" pass \
                                           || report "...saying how it is used" fail

# --- nobody waiting ----------------------------------------------------------------------
tin set -p -t '=aa:in' @agent_state working
rm -f "$INTERDIMUX_CLAUDE_DIR"/sessions/*.json
tin switch-client -c "$CLIENT" -t "$HOME_P"; wait_at "$HOME_P" || :
rc=0; next || rc=$?
same "with no agent waiting: exit 0" "$rc" 0
msgs=$(tin show-messages -t "$CLIENT" 2>/dev/null || true)
case "$msgs" in
  *'interdimux: no agent needs you'*) report "...the status line says 'no agent needs you'" pass ;;
  *) report "...the status line says 'no agent needs you'" fail ;;
esac
same "...and the client stays where it is" "$(at)" "$HOME_P"
record '=zz:ca' 1700000000000
record '=aa:cb' 1700000600000

# --- the key ------------------------------------------------------------------------------
bash "$SCRIPT" --bind-keys
keys=$(tin list-keys 2>/dev/null)
case "$keys" in
  *--agent-next*) report "unset, --bind-keys binds no key to --agent-next" fail ;;
  *) report "unset, --bind-keys binds no key to --agent-next" pass ;;
esac

KEY=A
if [ -z "$(tin list-keys -T prefix 2>/dev/null | awk -v k="$KEY" '$2 == "-T" && $3 == "prefix" && $4 == k')" ]; then
  report "premise: prefix+$KEY is not bound by default" pass
else
  report "premise: prefix+$KEY is not bound by default" fail
fi
tin set -g @interdimux-agent-next-key "$KEY"
bash "$SCRIPT" --bind-keys
# The whole table, matched by its key column: `list-keys -T prefix <key>`
# prints nothing on tmux 3.7b.
bound=$(tin list-keys -T prefix 2>/dev/null | awk -v k="$KEY" '$2 == "-T" && $3 == "prefix" && $4 == k' || true)
case "$bound" in
  *--agent-next*'TMUX_PANE'*|*'TMUX_PANE'*--agent-next*)
    case "$bound" in
      *'TMUX_PANE=#{pane_id}'*'INTERDIMUX_CLIENT=#{q:client_name}'*)
        report "set, prefix+$KEY runs --agent-next for the pressing pane and client" pass ;;
      *) report "set, prefix+$KEY runs --agent-next for the pressing pane and client ($bound)" fail ;;
    esac ;;
  *) report "set, prefix+$KEY runs --agent-next for the pressing pane and client ($bound)" fail ;;
esac

tin switch-client -c "$CLIENT" -t "$HOME_P"; wait_at "$HOME_P" || :
tmux -L "$OUTER" send-keys -t '=drv:' C-b "$KEY"
wait_at "$A" || :
same "pressing prefix+$KEY lands on A" "$(at)" "$A"
tmux -L "$OUTER" send-keys -t '=drv:' C-b "$KEY"
wait_at "$B" || :
same "...and again, on B" "$(at)" "$B"

# --- --doctor knows the option ----------------------------------------------------------
doctor() { bash "$SCRIPT" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; return 0; }
out=$(doctor)
case "$out" in
  *"✓ @interdimux-agent-next-key = '$KEY'"*) report "--doctor: the option is known, and its key fine" pass ;;
  *) report "--doctor: the option is known, and its key fine" fail ;;
esac
tin set -g @interdimux-agent-next-key 'xx'
out=$(doctor)
case "$out" in
  *"✗ @interdimux-agent-next-key = 'xx' — not a key tmux knows"*)
    report "--doctor: a key tmux cannot bind is a problem, as for the other keys" pass ;;
  *) report "--doctor: a key tmux cannot bind is a problem, as for the other keys" fail ;;
esac
case "$out" in
  *'unknown option @interdimux-agent-next-key'*) report "--doctor does not call it an unknown option" fail ;;
  *) report "--doctor does not call it an unknown option" pass ;;
esac

# --- the navigator's key, or the dashboard's -------------------------------------------
# --bind-keys binds the dashboard's key first and the navigator's last, so the
# opt-in key once took prefix+g from the dashboard without a word (and lost
# prefix+f to the navigator), while --doctor ticked both.  Neither is bound
# over now, and --doctor says why.  What each key runs is tmux's own table.
for pair in 'g:dashboard:--dashboard-launch' 'f:navigator:display-popup'; do
  k="${pair%%:*}" what="${pair#*:}"; runs="${what#*:}" what="${what%%:*}"
  tin set -g @interdimux-agent-next-key "$k"
  bash "$SCRIPT" --bind-keys
  bound=$(tin list-keys -T prefix 2>/dev/null | awk -v k="$k" '$2 == "-T" && $3 == "prefix" && $4 == k' || true)
  case "$bound" in
    *--agent-next*) report "agent-next-key $k: prefix+$k still opens the $what ($bound)" fail ;;
    *"$runs"*)      report "agent-next-key $k: prefix+$k still opens the $what" pass ;;
    *)              report "agent-next-key $k: prefix+$k still opens the $what ($bound)" fail ;;
  esac
  out=$(doctor)
  case "$out" in
    *"✗ @interdimux-agent-next-key = '$k' — prefix+$k opens the $what, so it is not bound to --agent-next"*)
      report "...and --doctor says that is why it is not bound" pass ;;
    *) report "...and --doctor says that is why it is not bound" fail ;;
  esac
done

# --- with the jump keys, and a key tmux escapes ---------------------------------
# --bind-keys reads @interdimux-jump-keys and this key in one tmux client, the
# second by name; by name tmux prints '#' as \#, so the raw value is read again
# and '#' is the key bound, next to the jump keys and not instead of them.
tin set -g @interdimux-jump-keys 'M-1 M-2'
tin set -g @interdimux-agent-next-key '#'
bash "$SCRIPT" --bind-keys
# (list-keys prints the key as \#, and `list-keys -T prefix '#'` finds nothing)
bound=$(tin list-keys -T prefix 2>/dev/null | awk '$4 == "\\#"' || true)
case "$bound" in
  *--agent-next*) report "agent-next-key '#' with jump keys set: prefix+# runs --agent-next" pass ;;
  *) report "agent-next-key '#' with jump keys set: prefix+# runs --agent-next ($bound)" fail ;;
esac
roots=$(tin list-keys -T root 2>/dev/null | grep -c -- '--jump [12]' || true)
same "...and both jump keys are still bound" "$roots" 2
tin set -gu @interdimux-jump-keys
tin set -gu @interdimux-agent-next-key

printf '\nResults: %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"

exit "$FAIL"
