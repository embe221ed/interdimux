#!/usr/bin/env bash
#
# What prefix+g's agent count costs (review R08).
#
# The dashboard counts the agents waiting on you before display-menu can draw,
# in bash, in a fresh process.  agent_state_r -- the rows' own state logic --
# is the expensive part of a pane, and it used to run for every pane whose app
# had ANY title rule.  ssh, docker, kubectl and the other remote shells have
# title rules (they say where the shell is), none with a state, and Claude's
# say only `working`: each such pane paid a title parse and match for a count
# it could never reach, ~0.7 ms apiece, and every shell's default title (the
# host name) loaded the whole rule index (~5 ms) first.
#
# So this suite watches the calls, not a clock (timings on a shared box are
# noise): bash -x traces --dashboard-launch, and the assertions read which
# panes reached agent_state_r and whether the rule index was loaded at all.
#   * only a pane whose state could be approve or input gets there: here the
#     two waiting codex panes and the node pane (an interpreter is named by
#     its script, so it is resolved first) -- no ssh, docker or shell pane,
#     no Claude whose registry record says it is working, and no second
#     sighting of a pane through a session group;
#   * a server of shells and remote panes never loads the rule index;
#   * and the count is still right: display-menu's own arguments carry it --
#     each pane once, though a session group lists the agents twice (review
#     R06); a codex started as `./codex`, whose #{pane_current_command} keeps
#     the `./` (review R12); `1 needs you` (review R28); and an app only the
#     user's own title rules can put in approve.
# The apps the default rules can put in approve or input are spelled out in
# the script (DEFAULT_AW_CAN, read without loading the rules); the first check
# holds that list to the rules themselves, read here with awk.
#
# display-menu needs an attached client, so an outer private server's pane
# attaches to an inner one (the harness of tests/test_dashboard_agents.sh); a
# PATH tmux in front of the real one logs display-menu's arguments and draws
# nothing.  Both servers are private; the user's is never touched, and neither
# is ~/.claude (INTERDIMUX_CLAUDE_DIR) or ~/.config (XDG_*).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-dashcnt-$$"
IN="$SOCK-i" OUT="$SOCK-o"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-dashcnt.XXXXXX")" && pwd -P)"
REAL_TMUX="$(command -v tmux)"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  "$REAL_TMUX" -L "$IN" kill-server 2>/dev/null || true
  "$REAL_TMUX" -L "$OUT" kill-server 2>/dev/null || true
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

echo "interdimux dashboard agent count cost tests"
echo

if [ ! -r /proc/self/stat ]; then
  echo "  (skipped: needs /proc for the registry's pid check)"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

unset TMUX TMUX_PANE
export XDG_CONFIG_HOME="$TMPD/config" XDG_STATE_HOME="$TMPD/state" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_CLAUDE_DIR="$TMPD/claude-home"
mkdir -p "$INTERDIMUX_CLAUDE_DIR/sessions" "$TMPD/shim"

cat > "$TMPD/shim/tmux" <<EOF
#!/bin/sh
case "\$1" in
  display-menu|display-popup) printf '%s\n' "\$@" >> "$TMPD/menu.log"; exit 0 ;;
esac
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$TMPD/shim/tmux"

mk() { # name, title (no single quote), argv0, seconds
  cat > "$TMPD/$1" <<EOF
#!/usr/bin/env bash
printf '\\033]0;%s\\007' '$2'
exec -a '$3' sleep $4
EOF
  chmod +x "$TMPD/$1"
}
mk ssh1   'deploy@web1: ~/app'                       ssh    979
mk dock1  'root@3f2a9c1b: /var/lib'                  docker 978
mk codex1 '[ ! ] Action Required | Add tests | proj' codex  977
mk codexr '[ ! ] Action Required | Relative | proj'  ./codex 973
mk claude1 '✳ Fix the parser'                        claude 976
cat > "$TMPD/node1" <<'EOF'
#!/usr/bin/env bash
exec perl -e '$0 = "node /srv/app/server.js"; sleep 975'
EOF
chmod +x "$TMPD/node1"

tin() { "$REAL_TMUX" -L "$IN" "$@"; }
"$REAL_TMUX" -f /dev/null -L "$OUT" new-session -d -s drv -x 110 -y 40 \
  "'$REAL_TMUX' -f /dev/null -L '$IN' new-session -s host -c '$TMPD' 'exec sleep 999'"
for _ in $(seq 1 100); do tin list-clients 2>/dev/null | grep -q . && break; sleep 0.05; done

tin new-session -d -s rem -x 110 -y 38 -c "$TMPD" "exec '$TMPD/ssh1'"
for _ in 1 2 3; do tin new-window -d -t '=rem:' -c "$TMPD" "exec '$TMPD/ssh1'"; done
tin new-window -d -t '=rem:' -c "$TMPD" "exec '$TMPD/dock1'"
tin new-window -d -t '=rem:' -c "$TMPD" "exec bash --norc --noprofile -i"
tin new-window -d -t '=rem:' -c "$TMPD" "exec bash --norc --noprofile -i"
tin new-window -d -t '=rem:' -n cl -c "$TMPD" "exec '$TMPD/claude1'"
tin new-session -d -s ag -x 110 -y 38 -n cx -c "$TMPD" "exec '$TMPD/codex1'"
tin new-window -d -t '=ag:' -n cr -c "$TMPD" "exec '$TMPD/codexr'"
tin new-window -d -t '=ag:' -n nd -c "$TMPD" "exec '$TMPD/node1'"
tin new-session -d -s grp -t '=ag'             # every ag pane, listed again

# --- DEFAULT_AW_CAN is what the default rules say --------------------------------
rules_apps=$(awk "/^DEFAULT_TITLE_RULES='/ { on = 1; next } on && /^'\$/ { exit }
                  on && \$1 !~ /^#/ && \$1 !~ /^@/ && (\$2 == \"approve\" || \$2 == \"input\") { print \$1 }" "$SCRIPT" |
             tr ',' '\n' | grep . | sort -u | tr '\n' ' ')
listed=$(sed -n "s/^DEFAULT_AW_CAN='\\(.*\\)'\$/\\1/p" "$SCRIPT" | tr ' ' '\n' | grep . | sort -u | tr '\n' ' ')
if [ -n "$rules_apps" ] && [ "$rules_apps" = "$listed" ]; then
  report "DEFAULT_AW_CAN names exactly the apps a default rule puts in approve/input ($listed)" pass
else
  report "DEFAULT_AW_CAN names exactly the apps a default rule puts in approve/input (rules: '$rules_apps', listed: '$listed')" fail
fi

pane_of() { tin display-message -p -t "$1" '#{pane_id}'; }
CX=$(pane_of '=ag:cx') CR=$(pane_of '=ag:cr') ND=$(pane_of '=ag:nd') CL=$(pane_of '=rem:cl')
CL_PID=$(tin display-message -p -t '=rem:cl' '#{pane_pid}')
settled() {
  local w
  for w in 0 1 2 3; do
    [ "$(tin display-message -p -t "=rem:$w" '#{pane_title}')" = 'deploy@web1: ~/app' ] || return 1
  done
  [ "$(tin display-message -p -t '=ag:cx' '#{pane_title}')" = '[ ! ] Action Required | Add tests | proj' ] || return 1
  [ "$(tin display-message -p -t '=ag:cr' '#{pane_title}')" = '[ ! ] Action Required | Relative | proj' ] || return 1
  [ "$(tin display-message -p -t '=ag:cr' '#{pane_current_command}')" = ./codex ] || return 1
  [[ "$(tr '\0' ' ' < "/proc/$CL_PID/cmdline")" == "claude "* ]] || return 1
  [[ "$(tr '\0' ' ' < "/proc/$(tin display-message -p -t '=ag:nd' '#{pane_pid}')/cmdline")" == node* ]] || return 1
}
for _ in $(seq 1 100); do settled && break; sleep 0.05; done
settled && report "the panes settled (titles set, argv final)" pass \
        || report "the panes settled (titles set, argv final)" fail
# Claude's registry: working.  The registry speaks first, so nothing else can
# make this pane wait.
read -r -a _st < "/proc/$CL_PID/stat"
printf '{"pid":%s,"sessionId":"x","cwd":"/tmp","startedAt":1,"procStart":"%s","version":"2.1.281","kind":"interactive","entrypoint":"cli","tmux":"t:@1.%s","name":"n","status":"busy","statusUpdatedAt":%s}' \
  "$CL_PID" "${_st[21]}" "$CL" "$(( $(date +%s) * 1000 ))" > "$INTERDIMUX_CLAUDE_DIR/sessions/$CL_PID.json"

SOCKP=$(tin display-message -p '#{socket_path}')
HOSTPANE=$(pane_of '=host:')
CLIENT=$(tin list-clients -F '#{client_name}' | head -1)
# prefix+g, traced: the xtrace lands in $TMPD/trace, and LABEL is the Agents
# entry display-menu was given.
launch() {
  rm -f "$TMPD/menu.log"
  env PATH="$TMPD/shim:$PATH" PS4='+ ' TMUX="$SOCKP,99999,0" TMUX_PANE="$HOSTPANE" \
      INTERDIMUX_CLIENT="$CLIENT" bash -x "$SCRIPT" --dashboard-launch >/dev/null 2> "$TMPD/trace" || true
  LABEL=$(grep -m1 -E '^-?Agents' "$TMPD/menu.log" 2>/dev/null || true)
}
# The pane ids agent_state_r was called with (its first %N argument), sorted.
state_calls() {
  awk '$1 ~ /^\++$/ && $2 == "agent_state_r" {
         for (i = 3; i <= NF; i++) if ($i ~ /^%[0-9]+$/) { print $i; break } }' "$TMPD/trace" |
    sort | tr '\n' ' '
}

# --- waiting codexes among remote panes ----------------------------------------
launch
if [[ "$LABEL" == 'Agents (2 need you)' ]]; then
  report "the count is right, each pane once, ./codex too: 'Agents (2 need you)'" pass
else
  report "the count is right, each pane once, ./codex too: 'Agents (2 need you)' (got: '$LABEL')" fail
fi
want=$(printf '%s\n' "$CX" "$CR" "$ND" | sort | tr '\n' ' ')
got=$(state_calls)
if [ "$got" = "$want" ]; then
  report "only the codex and node panes reach agent_state_r, once each: no ssh, docker, shell, working Claude or group copy" pass
else
  report "only the codex and node panes reach agent_state_r, once each (called for: $got, want: $want)" fail
fi

# --- shells and remote panes only: the rule index is never loaded --------------
tin kill-window -t '=ag:cx'
tin kill-window -t '=ag:cr'
tin kill-window -t '=ag:nd'
launch
if [ "$LABEL" = '-Agents' ]; then
  report "with none waiting the entry is greyed out" pass
else
  report "with none waiting the entry is greyed out (got: '$LABEL')" fail
fi
n_load=$(grep -c '^+* load_title_rules$' "$TMPD/trace" || true)
got=$(state_calls)
if [ "$n_load" = 0 ] && [ -z "$got" ]; then
  report "shells and remote panes load no title rules and reach no agent_state_r" pass
else
  report "shells and remote panes load no title rules (loads: $n_load) and reach no agent_state_r (called for: $got)" fail
fi

# --- an app only the user's rules know ------------------------------------------
# The user's file comes first in the rule set; the skip must read it too.
mkdir -p "$XDG_CONFIG_HOME/interdimux"
printf 'sleepy  approve  -  Waiting on *\n' > "$XDG_CONFIG_HOME/interdimux/titles"
mk sleepy1 'Waiting on you' sleepy 974
tin new-window -d -t '=rem:' -n sl -c "$TMPD" "exec '$TMPD/sleepy1'"
for _ in $(seq 1 100); do
  [ "$(tin display-message -p -t '=rem:sl' '#{pane_title}')" = 'Waiting on you' ] &&
    [ "$(tin display-message -p -t '=rem:sl' '#{pane_current_command}')" = sleepy ] && break
  sleep 0.05
done
launch
if [ "$LABEL" = 'Agents (1 needs you)' ]; then
  report "a user rule's app is counted: 'Agents (1 needs you)'" pass
else
  report "a user rule's app is counted: 'Agents (1 needs you)' (got: '$LABEL')" fail
fi

printf '\nResults: %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"

exit "$FAIL"
