#!/usr/bin/env bash
#
# Agent rows, end to end, in BOTH renderers: real processes in a real (private)
# tmux server, their titles set the way agents set them (OSC 0), Claude's
# session registry written the way Claude writes it, and state published as a
# pane option the way agent plugins publish it.
#
#   * an npm install is named by the agent: `node …/bin/codex` reads `codex`
#   * a title rule turns codex's `[ ! ] Action Required | <thread> | <project>`
#     into `approve` and the thread
#   * Claude's registry record gives the state and its age -- but only while
#     its pid is still that process (procStart) and its session is the pane's
#     shell (a record for a dead pid, or naming another pane, is not believed)
#   * a registry key file is never opened (chmod 000: no error either)
#   * an option a plugin set (@pane_status) gives a state to any row
#   * a title no rule knows shows only under @interdimux-show-title all
#   * the host name, tmux's default title, is never shown
#
# The corpus (rust/tests/corpus/agents.dump) pins the rows byte for byte; this
# suite proves the live plumbing feeds them: the batched query, the registry
# read, /proc resolution.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-agents-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-agents.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; chmod -R u+rw "$TMPD" 2>/dev/null || true; rm -rf "$TMPD"; }
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

tmux_cmd() { tmux -f /dev/null -L "$SOCK" "$@"; }

echo "interdimux agent row tests"
echo

if [ ! -r /proc/self/stat ]; then
  echo "  (skipped: needs /proc for the registry's pid check)"
  echo
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# Launchers.  Each sets its title with a raw OSC 0, as the agents do, then
# becomes the long-running process whose argv the row resolves.
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
cat > "$TMPD/gemini" <<'EOF'
#!/usr/bin/env bash
exec perl -e '$0 = "node /opt/lib/node_modules/@google/gemini-cli/bundle/gemini --yolo"; sleep 995'
EOF
cat > "$TMPD/titled" <<'EOF'
#!/usr/bin/env bash
printf '\033]0;Quarterly numbers\007'
exec sleep 994
EOF
chmod +x "$TMPD"/claude "$TMPD"/codex "$TMPD"/gemini "$TMPD"/titled

tmux_cmd new-session -d -s t -x 200 -y 40 -c "$TMPD" "exec '$TMPD/claude'"
tmux_cmd rename-window -t '=t:0' cl
tmux_cmd new-window -d -t '=t:' -n cx -c "$TMPD" "exec '$TMPD/codex'"
tmux_cmd new-window -d -t '=t:' -n gm -c "$TMPD" "exec '$TMPD/gemini'"
tmux_cmd new-window -d -t '=t:' -n op -c "$TMPD" "exec sleep 993"
tmux_cmd new-window -d -t '=t:' -n ti -c "$TMPD" "exec '$TMPD/titled'"
tmux_cmd set -p -t '=t:op' @pane_status running

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=t:0' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_SHOW_FULL_COMMAND=on INTERDIMUX_SHOW_GIT_BRANCH=off
export INTERDIMUX_ORDER=index INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off
export XDG_CONFIG_HOME="$TMPD/config" XDG_STATE_HOME="$TMPD/state" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_CLAUDE_DIR="$TMPD/claude-home"

wopt() { tmux -L "$SOCK" display-message -p -t "=t:$1" "$2"; }

# Settled when each launcher has become its final process and set its title.
settled() {
  [ "$(wopt cl '#{pane_title}')" = "✳ Fix the parser" ] || return 1
  [[ "$(wopt cx '#{pane_title}')" == "[ ! ] Action Required"* ]] || return 1
  [ "$(wopt ti '#{pane_title}')" = "Quarterly numbers" ] || return 1
  [[ "$(tr '\0' ' ' < "/proc/$(wopt cl '#{pane_pid}')/cmdline")" == "claude "* ]] || return 1
  [[ "$(tr '\0' ' ' < "/proc/$(wopt cx '#{pane_pid}')/cmdline")" == node* ]] || return 1
  [[ "$(tr '\0' ' ' < "/proc/$(wopt gm '#{pane_pid}')/cmdline")" == node* ]] || return 1
}
for _ in $(seq 1 100); do settled && break; sleep 0.05; done
settled && report "the panes settled (titles set, argv final)" pass \
        || report "the panes settled (titles set, argv final)" fail

# --- Claude's registry, as Claude writes it: one line, no trailing newline ---
NOW=1800000000
export INTERDIMUX_NOW="$NOW"
REG="$INTERDIMUX_CLAUDE_DIR/sessions"
mkdir -p "$REG"
CL_PID=$(wopt cl '#{pane_pid}') CL_PANE=$(wopt cl '#{pane_id}') CX_PANE=$(wopt cx '#{pane_id}')
read -r -a _st < "/proc/$CL_PID/stat"
CL_START="${_st[21]}"   # field 22; comm is `sleep`, no blank, so the index holds
record() { # $1 pid, $2 procStart, $3 pane, $4 status, $5 waitingFor, $6 seconds ago
  printf '{"pid":%s,"sessionId":"x","cwd":"/tmp","startedAt":1,"procStart":"%s","version":"2.1.281","kind":"interactive","entrypoint":"cli","tmux":"t:@1.%s","name":"n","status":"%s","waitingFor":"%s","statusUpdatedAt":%s}' \
    "$1" "$2" "$3" "$4" "$5" "$(( (NOW - $6) * 1000 ))"
}
record "$CL_PID" "$CL_START" "$CL_PANE" waiting "permission prompt" 300 > "$REG/$CL_PID.json"
# a dead pid claiming the codex pane: must not be believed
record 999999 1 "$CX_PANE" busy "" 10 > "$REG/999999.json"
# the key file Claude keeps next to each record: never opened
printf 'secret' > "$REG/$CL_PID.0123456789abcdef.key"
chmod 000 "$REG/$CL_PID.0123456789abcdef.key"

# $1 = on|off (the Rust core), rest = extra env; prints "window<TAB>command"
# with colours stripped, window rows only
rows() {
  local rust="$1"; shift
  env INTERDIMUX_USE_RUST="$rust" "$@" bash "$SCRIPT" --list 2> "$TMPD/err.$rust" \
    | awk -F'\t' '$4 ~ /^W:/ { sub(/^W:t:/, "", $4); print $4 "\t" $3 }' \
    | sed 's/\x1b\[[0-9;]*m//g'
}
cmd_of() { printf '%s\n' "$1" | awk -F'\t' -v w="$2" '$1 == w { print $2 }'; }

for rust in off on; do
  if [ "$rust" = on ] && [ ! -x "$SCRIPT_DIR/rust/target/release/imux" ]; then
    echo "  (the Rust core is not built: its half is skipped)"
    continue
  fi
  label="bash"; [ "$rust" = on ] && label="rust"
  OUT=$(rows "$rust")
  idx() { tmux -L "$SOCK" display-message -p -t "=t:$1" '#{window_index}'; }
  got=$(cmd_of "$OUT" "$(idx cl)")
  [ "$got" = "claude approve 5m Fix the parser" ] \
    && report "$label: claude reads its registry state, age and title (and drops its args)" pass \
    || { report "$label: claude reads its registry state, age and title (got: $got)" fail; }
  got=$(cmd_of "$OUT" "$(idx cx)")
  [ "$got" = "codex approve Add tests" ] \
    && report "$label: an npm codex is named codex, its title says approve" pass \
    || report "$label: an npm codex is named codex, its title says approve (got: $got)" fail
  got=$(cmd_of "$OUT" "$(idx gm)")
  [ "$got" = "gemini --yolo" ] \
    && report "$label: an npm gemini with no title is named gemini, the host name title unshown" pass \
    || report "$label: an npm gemini with no title is named gemini (got: $got)" fail
  got=$(cmd_of "$OUT" "$(idx op)")
  [ "$got" = "sleep 993 working" ] \
    && report "$label: a plugin's @pane_status gives any row its state" pass \
    || report "$label: a plugin's @pane_status gives any row its state (got: $got)" fail
  got=$(cmd_of "$OUT" "$(idx ti)")
  [ "$got" = "sleep 994" ] \
    && report "$label: a title no rule knows is not shown by default" pass \
    || report "$label: a title no rule knows is not shown by default (got: $got)" fail
  got=$(cmd_of "$(rows "$rust" INTERDIMUX_SHOW_TITLE=all)" "$(idx ti)")
  [ "$got" = "sleep 994 Quarterly numbers" ] \
    && report "$label: ...and is under @interdimux-show-title all" pass \
    || report "$label: ...and is under @interdimux-show-title all (got: $got)" fail
  got=$(cmd_of "$(rows "$rust" INTERDIMUX_AGENT_ARGS=on)" "$(idx cx)")
  [ "$got" = "codex approve Add tests resume" ] \
    && report "$label: @interdimux-agent-args on keeps the arguments" pass \
    || report "$label: @interdimux-agent-args on keeps the arguments (got: $got)" fail
  got=$(cmd_of "$(rows "$rust" INTERDIMUX_AGENT_STATE=off INTERDIMUX_SHOW_TITLE=off INTERDIMUX_AGENTS=off)" "$(idx cx)")
  [ "$got" = "node codex resume" ] \
    && report "$label: with every agent option off the row is what it always was" pass \
    || report "$label: with every agent option off the row is what it always was (got: $got)" fail
  [ ! -s "$TMPD/err.$rust" ] \
    && report "$label: nothing on stderr (the unreadable key file was never opened)" pass \
    || { report "$label: nothing on stderr" fail; ERRORS+="$(head -3 "$TMPD/err.$rust")"$'\n'; }
done

# The same record, once its pid is another process: procStart no longer
# matches.  And one written for another pane: its session is not that pane's.
HAVE_RUST=off; [ -x "$SCRIPT_DIR/rust/target/release/imux" ] && HAVE_RUST=on
CL_IDX=$(tmux -L "$SOCK" display-message -p -t '=t:cl' '#{window_index}')
CX_IDX=$(tmux -L "$SOCK" display-message -p -t '=t:cx' '#{window_index}')
rm -f "$REG/999999.json"
for rust in off $([ "$HAVE_RUST" = on ] && echo on); do
  label="bash"; [ "$rust" = on ] && label="rust"
  record "$CL_PID" "$(( CL_START + 1 ))" "$CL_PANE" waiting "permission prompt" 300 > "$REG/$CL_PID.json"
  got=$(cmd_of "$(rows "$rust")" "$CL_IDX")
  [ "$got" = "claude Fix the parser" ] \
    && report "$label: a record whose procStart is not the process's is not believed" pass \
    || report "$label: a record whose procStart is not the process's is not believed (got: $got)" fail
  record "$CL_PID" "$CL_START" "$CX_PANE" busy "" 10 > "$REG/$CL_PID.json"
  got=$(cmd_of "$(rows "$rust")" "$CX_IDX")
  [ "$got" = "codex approve Add tests" ] \
    && report "$label: a record naming another pane than its own is not believed there" pass \
    || report "$label: a record naming another pane than its own is not believed there (got: $got)" fail
done

echo
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
