#!/usr/bin/env bash
#
# The dashboard's Agents entry (review AGENT-12): prefix+g says how many agents
# are waiting on you, and choosing it opens the navigator on them.
#
#   * the count is of PANES whose state is `approve` or `input`, by the same
#     rules the rows are drawn with: Claude's registry, then the options agent
#     plugins publish, then the title -- including the rows' own exceptions (an
#     idle shell shows no state whatever option it carries; a session
#     @interdimux-hide keeps out of the navigator is not counted)
#   * each pane once: a session group and a linked window show it again
#     (review R06), and an agent started by a relative path (`./codex`) counts
#     like any other (review R12)
#   * none waiting greys the entry out and drops its key, as Jobs does; one
#     says `1 needs you` (review R28)
#   * its key opens the navigator in the agents view: fzf matches exactly the
#     waiting panes -- not a working agent whose description says `Approve`,
#     nor a window called `input-x` (review R03) -- and Enter goes to one;
#     `approve` keeps its danger colour there (review R28)
#   * the fzf fallback dashboard (short clients, tmux < 3.4) says the count too
#   * editing its query creates no session (review R05), and with nothing
#     waiting, Enter on the unmatched query creates none either
#
# Everything is RENDERED: display-menu needs an attached client, so an outer
# private server's pane attaches to an inner one, and the menu and the popup
# are captured off the outer pane (the harness of tests/test_dashboard.sh).
# The agents are real processes: titles set with OSC 0 the way codex sets
# them, a registry record written the way Claude writes it, options set the
# way plugins set them.  Both servers are private; the user's is never touched,
# and neither is ~/.claude (INTERDIMUX_CLAUDE_DIR) or ~/.config (XDG_*).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-dashag-$$"
IN="$SOCK-i" OUT="$SOCK-o"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-dashag.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$IN" kill-server 2>/dev/null || true
  tmux -L "$OUT" kill-server 2>/dev/null || true
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

echo "interdimux dashboard Agents entry tests"
echo

if [ ! -r /proc/self/stat ]; then
  echo "  (skipped: needs /proc for the registry's pid check)"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi
fzf_minor=$(fzf --version 2>/dev/null | awk '{print $1}' | cut -d. -f2)
if [ "${fzf_minor:-0}" -lt 74 ]; then
  echo "  (skipped: the navigator assertions need fzf >= 0.74, found ${fzf_minor:-?})"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

# Everything the servers and their run-shell children see: no user config, no
# real registry.  Exported BEFORE the servers start, so it is their global
# environment -- which is what the menu's run-shell hands --launch.
unset TMUX TMUX_PANE
export XDG_CONFIG_HOME="$TMPD/config" XDG_STATE_HOME="$TMPD/state" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_CLAUDE_DIR="$TMPD/claude-home"
export INTERDIMUX_SHOW_DIRS=off INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_PREVIEW=off
mkdir -p "$INTERDIMUX_CLAUDE_DIR/sessions"

# Launchers: each sets its title as the agent does, then becomes the process
# whose argv the row resolves.
cat > "$TMPD/claude" <<'EOF'
#!/usr/bin/env bash
printf '\033]0;✳ Fix the parser\007'
exec -a claude sleep 997
EOF
cat > "$TMPD/codex" <<'EOF'
#!/usr/bin/env bash
printf '\033]0;[ ! ] Action Required | Add tests | proj\007'
exec perl -e '$0 = "node /opt/lib/node_modules/@openai/codex/bin/codex resume"; sleep 996'
EOF
# The native build: argv0 is codex itself, so #{pane_current_command} names
# the app and only its title says it waits.
cat > "$TMPD/codex-native" <<'EOF'
#!/usr/bin/env bash
printf '\033]0;[ . ] Action Required | Fix the build | proj\007'
exec -a codex sleep 990
EOF
# A codex built from source, started by a relative path: tmux strips the
# directory only from an argv0 that starts with '/', so its
# #{pane_current_command} is `./codex` (review R12).
cat > "$TMPD/codex-rel" <<'EOF'
#!/usr/bin/env bash
printf '\033]0;[ ! ] Action Required | Relative build | proj\007'
exec -a ./codex sleep 988
EOF
# Decoys for the query (review R03): a WORKING codex whose description says
# Approve, and (below) a window called input-x.
cat > "$TMPD/codex-busy" <<'EOF'
#!/usr/bin/env bash
printf '\033]0;\342\240\213 Approve button styling | app\007'
exec -a codex sleep 987
EOF
# A wrapper script that publishes a state for a tool (the README's recipe):
# to tmux the pane runs `sh`, and the row shows the command under it.
cat > "$TMPD/wrapper" <<'EOF'
sleep 995
echo done
EOF
chmod +x "$TMPD/claude" "$TMPD/codex" "$TMPD/codex-native" "$TMPD/codex-rel" "$TMPD/codex-busy"

tin() { tmux -L "$IN" "$@"; }

# The inner server, attached from the outer one's pane.  The attach is the
# outer pane's command, so the outer pane's size is the inner client's.
tmux -f /dev/null -L "$OUT" new-session -d -s drv -x 110 -y 40 \
  "tmux -f /dev/null -L '$IN' new-session -s host -c '$TMPD' 'exec sleep 999'"
for _ in $(seq 1 100); do tin list-clients 2>/dev/null | grep -q . && break; sleep 0.05; done
tin set -g @interdimux-hide 'hidden-*'

tin new-session -d -s work -x 110 -y 38 -n cl -c "$TMPD" "exec '$TMPD/claude'"
tin new-window -d -t '=work:' -n cx -c "$TMPD" "exec '$TMPD/codex'"
tin new-window -d -t '=work:' -n cn -c "$TMPD" "exec '$TMPD/codex-native'"
tin new-window -d -t '=work:' -n qq -c "$TMPD" "exec sleep 994"
tin split-window -d -t '=work:qq' -c "$TMPD" "exec sleep 993"          # inactive pane
tin new-window -d -t '=work:' -n busy -c "$TMPD" "exec sleep 992"
tin new-window -d -t '=work:' -n idle -c "$TMPD" "exec bash --norc --noprofile -i"
tin new-window -d -t '=work:' -n wrap -c "$TMPD" "exec sh '$TMPD/wrapper'"
tin new-window -d -t '=work:' -n rel -c "$TMPD" "exec '$TMPD/codex-rel'"
tin new-session -d -s hidden-x -x 110 -y 38 -c "$TMPD" "exec sleep 991"
# Every pane of `work` again, in a session group, and the native codex's
# window linked into one more session: list-panes -a prints those panes once
# per session that holds them.
tin new-session -d -s view -t '=work'
tin new-session -d -s lnk -x 110 -y 38 -c "$TMPD" "exec sleep 985"
tin link-window -d -s '=work:cn' -t '=lnk:'
# The decoys, in the session made last: the most recent, so it is listed
# first, where the old query's best match -- and the cursor -- fell on them.
tin new-session -d -s deco -x 110 -y 38 -n ab -c "$TMPD" "exec '$TMPD/codex-busy'"
tin new-window -d -t '=deco:' -n input-x -c "$TMPD" "exec sleep 986"

pane_of() { tin display-message -p -t "$1" '#{pane_id}'; }
QQ1=$(tin list-panes -t '=work:qq' -F '#{pane_index} #{pane_id}' | awk '$1 == 1 { print $2 }')
tin set -p -t "$QQ1" @agent_state input                       # a hook's input, on an inactive pane
tin set -p -t "$(pane_of '=work:busy')" @pane_status running  # tmux-agent-sidebar: working
tin set -p -t "$(pane_of '=work:idle')" @agent_state approve  # an idle shell: no state, as on its row
tin set -p -t "$(pane_of '=work:wrap')" @agent_state approve  # a wrapper script: counted
tin set -p -t "$(pane_of '=hidden-x:')" @agent_state approve  # a hidden session: not counted

# Claude's registry: a permission prompt, as Claude writes it.
CL_PID=$(tin display-message -p -t '=work:cl' '#{pane_pid}')
CL_PANE=$(pane_of '=work:cl')
settled() {
  [ "$(tin display-message -p -t '=work:cx' '#{pane_title}')" = "[ ! ] Action Required | Add tests | proj" ] || return 1
  [ "$(tin display-message -p -t '=work:cn' '#{pane_current_command}')" = codex ] || return 1
  [[ "$(tin display-message -p -t '=work:cn' '#{pane_title}')" == "[ . ] Action Required"* ]] || return 1
  [ "$(tin display-message -p -t '=work:rel' '#{pane_current_command}')" = ./codex ] || return 1
  [[ "$(tin display-message -p -t '=work:rel' '#{pane_title}')" == "[ ! ] Action Required"* ]] || return 1
  [[ "$(tin display-message -p -t '=deco:ab' '#{pane_title}')" == *"Approve button styling"* ]] || return 1
  [[ "$(tr '\0' ' ' < "/proc/$CL_PID/cmdline")" == "claude "* ]] || return 1
  [[ "$(tr '\0' ' ' < "/proc/$(tin display-message -p -t '=work:cx' '#{pane_pid}')/cmdline")" == node* ]] || return 1
  [ -n "$(cat "/proc/$(tin display-message -p -t '=work:wrap' '#{pane_pid}')/task/"*/children 2>/dev/null)" ] || return 1
}
for _ in $(seq 1 100); do settled && break; sleep 0.05; done
settled && report "the agents settled (titles set, argv final)" pass \
        || report "the agents settled (titles set, argv final)" fail
read -r -a _st < "/proc/$CL_PID/stat"
printf '{"pid":%s,"sessionId":"x","cwd":"/tmp","startedAt":1,"procStart":"%s","version":"2.1.281","kind":"interactive","entrypoint":"cli","tmux":"t:@1.%s","name":"n","status":"waiting","waitingFor":"permission prompt","statusUpdatedAt":%s}' \
  "$CL_PID" "${_st[21]}" "$CL_PANE" "$(( $(date +%s) * 1000 ))" > "$INTERDIMUX_CLAUDE_DIR/sessions/$CL_PID.json"

# Waiting: claude (registry: approve), codex (its title, via `node`: approve),
# the native codex (its title), the relative-path codex (its title), qq's
# inactive pane (@agent_state input) and the wrapper (@agent_state approve).
# Not: busy (working), the working codex whose description says Approve, the
# idle shell, input-x, the hidden session -- and not the group's or the link's
# second sight of the same panes.
WANT=6
# The panes that wait, by id: where Enter from the agents view must land.
WAITING=" $(pane_of '=work:cl') $(pane_of '=work:cx') $(pane_of '=work:cn') $(pane_of '=work:rel') $QQ1 $(pane_of '=work:wrap') "

SOCKP=$(tin display-message -p '#{socket_path}')
HOSTPANE=$(pane_of '=host:')
CLIENT=$(tin list-clients -F '#{client_name}' | head -1)
screen() { tmux -L "$OUT" capture-pane -t '=drv:' -p 2>/dev/null; }
wait_for() { # $1 = ERE the outer pane must show; up to ~12 s
  local i
  for i in $(seq 1 80); do screen | grep -qE "$1" && return 0; sleep 0.15; done
  return 1
}
wait_gone() {
  local i
  for i in $(seq 1 80); do screen | grep -qE "$1" || return 0; sleep 0.15; done
  return 1
}
# prefix+g, the way the binding runs it: the pressing pane and client, and
# every option read from the (inner) server.
dashboard() { # $@ = extra env
  env TMUX="$SOCKP,99999,0" TMUX_PANE="$HOSTPANE" INTERDIMUX_CLIENT="$CLIENT" "$@" \
    bash "$SCRIPT" --dashboard-launch >/dev/null 2>&1 &
}
menu_row() { screen | grep -F "$1" | head -1 || true; }

# --- the entry, with the count ------------------------------------------------
dashboard
wait_for 'Switch' || true
row=$(menu_row 'Agents')
if [[ "$row" == *"Agents ($WANT need you)"*"(e)"* ]]; then
  report "the menu says 'Agents ($WANT need you)' with its key (e)" pass
else
  report "the menu says 'Agents ($WANT need you)' with its key (row: '$row')" fail
  ERRORS+="$(screen | grep -v '^ *$' | head -24 | sed 's/^/      /' || true)"$'\n'
fi

# --- choosing it opens the navigator on those agents --------------------------
QRE='\^! \| \^\?'   # the agents view's query, `^! | ^?`, as an ERE
tmux -L "$OUT" send-keys -t '=drv:' e
if wait_for "interdimux · agents" && wait_for "$QRE"; then
  report "its key opens the navigator titled 'agents', the query typed" pass
else
  report "its key opens the navigator titled 'agents', the query typed" fail
  ERRORS+="$(screen | grep -v '^ *$' | head -8 | sed 's/^/      /' || true)"$'\n'
fi
# The rows that match are exactly the waiting panes, one row each -- not the
# working codex that says Approve, nor input-x, nor the window rows that
# repeat a waiting active pane, nor the group's or the link's copies: fzf's
# own count on the prompt line, once the list has loaded.
for _ in $(seq 1 60); do screen | grep -qE " $WANT/[0-9]+" && break; sleep 0.15; done
line=$(screen | grep -E "$QRE" | head -1 || true)
if [[ "$line" =~ \ $WANT/[0-9]+ ]]; then
  report "fzf matches $WANT rows: the waiting agents, one row each" pass
else
  report "fzf matches $WANT rows (prompt line: '$line')" fail
fi
# The state words keep their own colour here (review R28): fzf highlights
# what the query matched, and it matched the words, so `approve` came out in
# the highlight colour, not the danger red it has everywhere else.  tmux's own
# grid says which colour each `approve` has, on every row that matched (the
# ones marked in the gutter; raw mode dims the rest on purpose).  The danger
# colour is @interdimux-color-danger's default, 167.
cap=$(tmux -L "$OUT" capture-pane -e -p -t '=drv:' 2>/dev/null || true)
colours=$(printf '%s\n' "$cap" | perl -CS -ne '
  (my $t = $_) =~ s/\e\[[0-9;]*m//g;
  next unless $t =~ /\x{2502}[\x{258c} ]*[!?] /;      # border, pointer, then a mark
  while (/((?:\e\[[0-9;]*m)*)approve/g) { $n++; $r++ if $1 =~ /38;5;167[;m]/ }
  END { printf "%d %d", $n // 0, $r // 0 }')
if [ "${colours% *}" -gt 0 ] && [ "${colours% *}" = "${colours#* }" ]; then
  report "on the rows that match, 'approve' keeps its danger colour (${colours#* } of ${colours% *})" pass
else
  report "on the rows that match, 'approve' keeps its danger colour (${colours#* } of ${colours% *} do)" fail
fi
# Enter goes where the cursor is: tmux itself says which pane the client
# landed on, and it must be one that waits.
tmux -L "$OUT" send-keys -t '=drv:' Enter
wait_gone "interdimux · agents" || true
landed=""
for _ in $(seq 1 40); do
  landed=$(tin display-message -p -c "$CLIENT" '#{pane_id}' 2>/dev/null || true)
  [ -n "$landed" ] && [ "$landed" != "$HOSTPANE" ] && break
  sleep 0.1
done
if [ -n "$landed" ] && [[ "$WAITING" == *" $landed "* ]]; then
  report "the cursor starts on a waiting agent: Enter lands on one" pass
else
  report "the cursor starts on a waiting agent: Enter lands on one (landed on '$landed', waiting:$WAITING)" fail
fi
tin switch-client -c "$CLIENT" -t '=host:' 2>/dev/null || true

# --- editing the query makes no session -------------------------------------
# A word typed after the query leaves nothing matching; Enter there used to
# create `approve-|-input-qqq` in ~ (review R05).
before=$(tin list-sessions -F '#{session_name}' | sort | tr '\n' ' ')
env TMUX="$SOCKP,99999,0" TMUX_PANE="$HOSTPANE" INTERDIMUX_CLIENT="$CLIENT" \
  bash "$SCRIPT" --launch agents >/dev/null 2>&1 &
wait_for "$QRE" || true
for _ in $(seq 1 60); do screen | grep -qE " $WANT/[0-9]+" && break; sleep 0.15; done
tmux -L "$OUT" send-keys -t '=drv:' -l ' qqq'
if wait_for "$QRE qqq +0/[0-9]+"; then
  report "a word typed after the query leaves nothing matching" pass
else
  report "a word typed after the query leaves nothing matching" fail
  ERRORS+="$(screen | grep -v '^ *$' | head -3 | sed 's/^/      /' || true)"$'\n'
fi
if wait_for 'no waiting agent matches'; then
  report "...and the bar says no waiting agent matches, not what it would create" pass
else
  report "...and the bar says no waiting agent matches, not what it would create" fail
  ERRORS+="$(screen | grep -v '^ *$' | tail -3 | sed 's/^/      /' || true)"$'\n'
fi
tmux -L "$OUT" send-keys -t '=drv:' Enter
wait_gone "interdimux · agents" || true
after=$(tin list-sessions -F '#{session_name}' | sort | tr '\n' ' ')
if [ "$before" = "$after" ]; then
  report "...and Enter there creates no session" pass
else
  report "...and Enter there creates no session (before: $before after: $after)" fail
fi

# --- the fzf fallback says it too ---------------------------------------------
# tmux < 3.4 takes the fallback at any height.
dashboard INTERDIMUX_TMUX_VNUM=303
wait_for 'interdimux ❯' || true
row=$(menu_row 'Agents')
if [[ "$row" == *"$WANT agents need you"* ]]; then
  report "the fzf fallback lists Agents with '$WANT agents need you'" pass
else
  report "the fzf fallback lists Agents with the count (row: '$row')" fail
fi
tmux -L "$OUT" send-keys -t '=drv:' Escape
wait_gone 'interdimux ❯' || true

# --- one waiting: `needs` -----------------------------------------------------
tin kill-window -t '=work:cl'
tin kill-window -t '=work:cx'
tin kill-window -t '=work:cn'
tin kill-window -t '=work:wrap'
tin kill-window -t '=work:rel'
rm -f "$INTERDIMUX_CLAUDE_DIR/sessions/"*.json
dashboard
wait_for 'Switch' || true
row=$(menu_row 'Agents')
if [[ "$row" == *"Agents (1 needs you)"*"(e)"* ]]; then
  report "with one waiting the menu says 'Agents (1 needs you)'" pass
else
  report "with one waiting the menu says 'Agents (1 needs you)' (row: '$row')" fail
fi
tmux -L "$OUT" send-keys -t '=drv:' q
wait_gone 'Switch' || true

# --- nobody waiting: greyed out, no key ---------------------------------------
tin set -pu -t "$QQ1" @agent_state
dashboard
wait_for 'Switch' || true
row=$(menu_row 'Agents')
if [ -n "$row" ] && [[ "$row" != *"need you"* && "$row" != *"(e)"* ]]; then
  report "with none waiting the entry is there, greyed out, without its key" pass
else
  report "with none waiting the entry is there, greyed out, without its key (row: '$row')" fail
fi
tmux -L "$OUT" send-keys -t '=drv:' q
wait_gone 'Switch' || true

# --- ...and Enter on the unmatched query creates no session -------------------
# The query is a filter, not a name.  Opened directly, as the entry would.
before=$(tin list-sessions -F '#{session_name}' | sort | tr '\n' ' ')
env TMUX="$SOCKP,99999,0" TMUX_PANE="$HOSTPANE" INTERDIMUX_CLIENT="$CLIENT" \
  bash "$SCRIPT" --launch agents >/dev/null 2>&1 &
if wait_for "$QRE" && wait_for 'no agent is waiting on you'; then
  report "with none waiting the bar says no agent is waiting on you" pass
else
  report "with none waiting the bar says no agent is waiting on you" fail
  ERRORS+="$(screen | grep -v '^ *$' | tail -4 | sed 's/^/      /' || true)"$'\n'
fi
tmux -L "$OUT" send-keys -t '=drv:' Enter
# The popup's own border (its title), not the query: an execute() child takes
# fzf's screen over while it runs, so the query vanishes before a create would
# have finished.
wait_gone "interdimux · agents" || true
after=$(tin list-sessions -F '#{session_name}' | sort | tr '\n' ' ')
if [ "$before" = "$after" ]; then
  report "...and Enter there creates no session" pass
else
  report "...and Enter there creates no session (before: $before after: $after)" fail
fi

printf '\nResults: %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"

exit "$FAIL"
