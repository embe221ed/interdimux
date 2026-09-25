#!/usr/bin/env bash
#
# What README "Agents and pane titles" promises, run as it is written, on a
# private tmux server, in BOTH renderers where rows are involved:
#
#   1, 2. the wrapper recipe (taken out of the README itself, not copied
#      here): `working` while the tool runs; at the prompt, after the tool
#      ends -- normally (1) or by Ctrl-C (2) -- the pane option is gone, so a
#      later program in the same pane shows no state
#   3. stale titles: under a shell that sets no title, the next docker row
#      shows the prompt of a container that has gone (the README says it
#      cannot help that); under one that titles its prompt with the README's
#      PS1 line (taken out of the README), it does not
#   4. the preview of an agent's row names the agent, as the row does, and
#      has the arguments the row drops (`codex resume <id>` for an npm codex
#      whose tmux name is `node`), cut to the preview's width
#   5. Claude's registry: on Linux a record is believed only while its pid is
#      that process and runs in that pane; without /proc (the seam
#      INTERDIMUX_REGISTRY_NO_PROC=1 takes the macOS path here) only that the
#      pid is alive -- what the README says of each
#
# Expected rows are written out here, not computed by either renderer; the
# authority for the option is tmux's own `show -pv`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-agentreadme-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-agentreadme.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"
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
# $1 = what, $2 = got, $3 = want
same() { if [ "$2" = "$3" ]; then report "$1" pass; else report "$1 (got: '$2', want: '$3')" fail; fi; }

echo "interdimux: the README's agent promises, as written"
echo

RENDERERS="off"
[ -x "$BIN" ] && RENDERERS="off on"
[ -x "$BIN" ] || echo "  (the Rust core is not built: only the bash renderer is checked)"

unset TMUX TMUX_PANE
tm() { tmux -f /dev/null -L "$SOCK" "$@"; }

# Poll (never a fixed sleep): $1 = tries of 50 ms, rest = the condition.  It
# never fails the script: the assertion after it says what was not reached.
wait_for() {
  local n="$1" i; shift
  for (( i = 0; i < n; i++ )); do "$@" && return 0; sleep 0.05; done
  return 0
}

# --- the recipe, out of the README ------------------------------------------------
# The ```sh block that sets @agent_state working, its indent dropped.
mkdir -p "$TMPD/bin"
awk '/^   ```sh$/ { inb = 1; buf = ""; next }
     inb && /^   ```$/ { if (buf ~ /@agent_state working/) { printf "%s", buf; found = 1; exit } inb = 0; next }
     inb { sub(/^   /, ""); buf = buf $0 "\n" }
     END { exit !found }' "$SCRIPT_DIR/README.md" > "$TMPD/wrap-agent" \
  && report "the README has the wrapper recipe" pass \
  || report "the README has the wrapper recipe" fail
# The tool it wraps: one that ends when you answer it, and dies on Ctrl-C.
printf '#!/bin/sh\nread -r _answer\n' > "$TMPD/bin/my-agent"
chmod +x "$TMPD/bin/my-agent"

# An interactive shell that sets no title, as the README's "plain bash".
tm new-session -d -s t -n wr -x 200 -y 40 -c "$TMPD" \
  "env PATH='$TMPD/bin':\"\$PATH\" PS1='\$ ' bash --norc --noprofile -i"
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=t:wr' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_SHOW_FULL_COMMAND=on INTERDIMUX_SHOW_GIT_BRANCH=off
export INTERDIMUX_ORDER=index INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off
export XDG_CONFIG_HOME="$TMPD/config" XDG_STATE_HOME="$TMPD/state" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_CLAUDE_DIR="$TMPD/claude-home"

pcc()   { tmux -L "$SOCK" display-message -p -t "=t:$1" '#{pane_current_command}'; }
state() { tmux -L "$SOCK" show -pqv -t "=t:wr" @agent_state; }
is_cmd()   { [ "$(pcc "$1")" = "$2" ]; }
is_state() { [ "$(state)" = "$1" ]; }
# the tool is running (its shebang makes it `/bin/sh <path>`): the wrapper is
# past its `set`, and a Ctrl-C now reaches both
tool_runs() { ps -eo args= 2>/dev/null | grep -F "$TMPD/bin/my-agent" >/dev/null; }
tool_gone() { ! tool_runs; }

# $1 = on|off (the Rust core), $2 = window name: that window row's command field
row() {
  local idx
  idx=$(tmux -L "$SOCK" display-message -p -t "=t:$2" '#{window_index}')
  INTERDIMUX_USE_RUST="$1" bash "$SCRIPT" --list 2> "$TMPD/err.$1" \
    | awk -F'\t' -v s="W:t:$idx" '$4 == s { print $3 }' | sed 's/\x1b\[[0-9;]*m//g'
}
rows_all() { # $1 = what, $2 = window, $3 = want
  local rust label
  for rust in $RENDERERS; do
    label="bash"; [ "$rust" = on ] && label="rust"
    same "$label: $1" "$(row "$rust" "$2")" "$3"
  done
}

wait_for 200 is_cmd wr bash
same "the shell is at its prompt" "$(pcc wr)" bash

# --- 1. the wrapper, ended by its tool --------------------------------------------
tm send-keys -t '=t:wr' -l "sh $TMPD/wrap-agent"; tm send-keys -t '=t:wr' Enter
wait_for 200 is_state working; wait_for 200 tool_runs
same "while the tool runs, the pane says working" "$(state)" working
rows_all "while the tool runs, the row says so" wr "sh wrap-agent ∣ working"
tm send-keys -t '=t:wr' -l "done"; tm send-keys -t '=t:wr' Enter
wait_for 200 tool_gone; wait_for 200 is_cmd wr bash; wait_for 200 is_state ""
same "the tool answered and gone: the option is unset" "$(state)" ""
rows_all "at the prompt the row shows no state" wr "bash"
tm send-keys -t '=t:wr' -l "sleep 300"; tm send-keys -t '=t:wr' Enter
wait_for 200 is_cmd wr sleep
rows_all "a later program in the pane shows no state" wr "sleep 300"
tm send-keys -t '=t:wr' C-c
wait_for 200 is_cmd wr bash

# --- 2. the wrapper, ended by Ctrl-C ----------------------------------------------
tm send-keys -t '=t:wr' -l "sh $TMPD/wrap-agent"; tm send-keys -t '=t:wr' Enter
wait_for 200 is_state working; wait_for 200 tool_runs
same "running again: working" "$(state)" working
tm send-keys -t '=t:wr' C-c
wait_for 200 tool_gone; wait_for 200 is_cmd wr bash; wait_for 200 is_state ""
same "Ctrl-C: the option is unset all the same" "$(state)" ""
tm send-keys -t '=t:wr' -l "sleep 301"; tm send-keys -t '=t:wr' Enter
wait_for 200 is_cmd wr sleep
rows_all "a later program after a Ctrl-C shows no state" wr "sleep 301"
tm send-keys -t '=t:wr' C-c
wait_for 200 is_cmd wr bash

# --- 3. a gone container's prompt, and the PS1 line that keeps it off ------------
awk '/^```sh$/ { inb = 1; buf = ""; next }
     inb && /^```$/ { if (buf ~ /PS1=/) { printf "%s", buf; found = 1; exit } inb = 0; next }
     inb { buf = buf $0 "\n" }
     END { exit !found }' "$SCRIPT_DIR/README.md" > "$TMPD/rc" \
  && report "the README has the PS1 line" pass \
  || report "the README has the PS1 line" fail
tm new-window -d -t '=t:' -n plain -c "$TMPD" "env -u PROMPT_COMMAND PS1='\$ ' bash --norc --noprofile -i"
tm new-window -d -t '=t:' -n titled -c "$TMPD" "env -u PROMPT_COMMAND PS1='\$ ' bash --rcfile '$TMPD/rc' --noprofile -i"
wait_for 200 is_cmd plain bash; wait_for 200 is_cmd titled bash
title() { tmux -L "$SOCK" display-message -p -t "=t:$1" '#{pane_title}'; }
is_title() { [ "$(title "$1")" = "$2" ]; }
fired() { [ -e "$TMPD/fired.$1" ]; }
GONE='root@96fecc5c832f: /srv/app'
# bash's \u@\h: \w -- \w with the home directory as ~
LOCAL_W="$TMPD"; case "$LOCAL_W" in "$HOME"/*) LOCAL_W="~${LOCAL_W#"$HOME"}" ;; esac
LOCAL="$(id -un)@${HOSTNAME%%.*}: $LOCAL_W"
for w in plain titled; do
  # what a container's shell leaves in the title when it exits, then the
  # shell's prompt again
  tm send-keys -t "=t:$w" -l "printf '\\033]0;%s\\007' '$GONE'; : > '$TMPD/fired.$w'"
  tm send-keys -t "=t:$w" Enter
  wait_for 200 fired "$w"
done
wait_for 200 is_title plain "$GONE"; wait_for 200 is_title titled "$LOCAL"
same "plain bash keeps the container's title" "$(title plain)" "$GONE"
same "the README's PS1 line titles the pane with this host's prompt" "$(title titled)" "$LOCAL"
for w in plain titled; do
  tm send-keys -t "=t:$w" -l "(exec -a docker sleep 302)"; tm send-keys -t "=t:$w" Enter
done
wait_for 200 is_cmd plain docker; wait_for 200 is_cmd titled docker
rows_all "plain bash: the next docker row shows the gone container (the documented limit)" plain "docker 302 ∣ $GONE"
rows_all "the PS1 line: the next docker row does not" titled "docker 302"
tm send-keys -t '=t:plain' C-c; tm send-keys -t '=t:titled' C-c

# --- 4. the preview of an agent's row -------------------------------------------
# argv set the way an npm launcher's reads (perl's $0), and a native claude
# with its resume arguments; a plain sleep beside them
tm new-window -d -t '=t:' -n cx -c "$TMPD" \
  "exec perl -e '\$0 = \"node /opt/lib/node_modules/@openai/codex/bin/codex resume 0199a1b2-aaaa\"; sleep 996'"
tm new-window -d -t '=t:' -n cl -c "$TMPD" \
  "exec perl -e '\$0 = \"claude --resume 7f3c2a10 --model opus\"; sleep 995'"
tm new-window -d -t '=t:' -n sl -c "$TMPD" "exec sleep 994"
argv_is() { # $1 = window, $2 = the start of its argv
  local pid
  pid=$(tmux -L "$SOCK" display-message -p -t "=t:$1" '#{pane_pid}')
  [[ "$(ps -o args= -p "$pid" 2>/dev/null)" == "$2"* ]]
}
wait_for 200 argv_is cx "node /opt"; wait_for 200 argv_is cl "claude --resume"
wait_for 200 is_cmd sl sleep
same "tmux calls the npm codex node" "$(pcc cx)" node
PV_PATH="$TMPD"; case "$PV_PATH" in "$HOME"/*) PV_PATH="~${PV_PATH#"$HOME"}" ;; esac
preview() { # $1 = window, $2 = the preview's width: its first three lines
  local idx
  idx=$(tmux -L "$SOCK" display-message -p -t "=t:$1" '#{window_index}')
  FZF_PREVIEW_COLUMNS="$2" bash "$SCRIPT" --preview "W:t:$idx" 2>> "$TMPD/err.preview" \
    | sed 's/\x1b\[[0-9;]*m//g' | head -3
}
pv_line() { printf '%s\n' "$1" | sed -n "${2}p"; }
widx() { tmux -L "$SOCK" display-message -p -t "=t:$1" '#{window_index}'; }
RULE78=$(printf '%*s' 78 '' | sed 's/ /─/g')
out=$(preview cx 80)
same "preview, npm codex: the header names codex" "$(pv_line "$out" 1)" "t:$(widx cx)  codex · $PV_PATH"
same "preview, npm codex: the arguments the row drops" "$(pv_line "$out" 2)" "codex resume 0199a1b2-aaaa"
same "preview, npm codex: then the rule" "$(pv_line "$out" 3)" "$RULE78"
out=$(preview cl 80)
same "preview, claude: its resume arguments" "$(pv_line "$out" 2)" "claude --resume 7f3c2a10 --model opus"
out=$(preview cx 16)
same "preview, narrow: the line is cut to the width" "$(pv_line "$out" 2)$(pv_line "$out" 3)" "codex resume 0199a1b2-aaaa"
same "preview, narrow: ...14 characters a line" "$(pv_line "$out" 2)" "codex resume 0"
out=$(preview sl 80)
same "preview, not an agent: tmux's name and no extra line" \
  "$(pv_line "$out" 1)|$(pv_line "$out" 2)" "t:$(widx sl)  sleep · $PV_PATH|$RULE78"
[ ! -s "$TMPD/err.preview" ] && report "preview: nothing on stderr" pass \
  || { report "preview: nothing on stderr" fail; ERRORS+="$(head -3 "$TMPD/err.preview")"$'\n'; }

# --- 5. the registry with and without /proc --------------------------------------
tm new-window -d -t '=t:' -n np -c "$TMPD" "exec sleep 993"
wait_for 200 is_cmd np sleep
NOW=1800000000
export INTERDIMUX_NOW="$NOW"
REG="$INTERDIMUX_CLAUDE_DIR/sessions"
mkdir -p "$REG"
NP_PANE=$(tmux -L "$SOCK" display-message -p -t '=t:np' '#{pane_id}')
SL_PANE=$(tmux -L "$SOCK" display-message -p -t '=t:sl' '#{pane_id}')
SL_PID=$(tmux -L "$SOCK" display-message -p -t '=t:sl' '#{pane_pid}')
sleep 0 & DEAD=$!; wait "$DEAD" || true
record() { # $1 pid, $2 procStart, $3 pane: waiting on a permission, 5 minutes
  printf '{"pid":%s,"sessionId":"x","cwd":"/tmp","startedAt":1,"procStart":"%s","version":"2.1.281","kind":"interactive","entrypoint":"cli","tmux":"t:@9.%s","name":"n","status":"waiting","waitingFor":"permission prompt","statusUpdatedAt":%s}' \
    "$1" "$2" "$3" "$(( (NOW - 300) * 1000 ))"
}
# a live pid that is not this pane's, with a start time that is not its own:
# what a reused pid, or a claude of another server with the same %N, looks like
record "$SL_PID" 1 "$NP_PANE" > "$REG/$SL_PID.json"
# a pid that is gone, for the sleep pane
record "$DEAD" 1 "$SL_PANE" > "$REG/$DEAD.json"
if [ -r /proc/self/stat ]; then
  rows_all "/proc: a record whose pid is another process is not believed" np "sleep 993"
  rows_all "/proc: a record whose pid is gone is not believed" sl "sleep 994"
fi
export INTERDIMUX_REGISTRY_NO_PROC=1
rows_all "no /proc: a live pid is all it takes (README)" np "sleep 993 ∣ approve 5m"
rows_all "no /proc: a record whose pid is gone is still not believed" sl "sleep 994"
unset INTERDIMUX_REGISTRY_NO_PROC INTERDIMUX_NOW

for rust in $RENDERERS; do
  label="bash"; [ "$rust" = on ] && label="rust"
  [ ! -s "$TMPD/err.$rust" ] && report "$label: nothing on stderr" pass \
    || { report "$label: nothing on stderr" fail; ERRORS+="$(head -3 "$TMPD/err.$rust")"$'\n'; }
done

echo
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
