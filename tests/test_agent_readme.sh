#!/usr/bin/env bash
#
# What README "Agents and pane titles" promises, run as it is written, on a
# private tmux server, in BOTH renderers where rows are involved:
#
#   1. the wrapper recipe (taken out of the README itself, not copied here):
#      `working` while the tool runs; at the prompt, after the tool ends --
#      normally or by Ctrl-C -- the pane option is gone, so a later program
#      in the same pane shows no state
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
tool_runs() {
  local p c
  for p in /proc/[0-9]*; do
    c=$(tr '\0' ' ' 2>/dev/null < "$p/cmdline") || continue
    [[ "$c" == *"$TMPD/bin/my-agent"* ]] && return 0
  done
  return 1
}
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
rows_all "while the tool runs, the row says so" wr "sh wrap-agent working"
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

for rust in $RENDERERS; do
  label="bash"; [ "$rust" = on ] && label="rust"
  [ ! -s "$TMPD/err.$rust" ] && report "$label: nothing on stderr" pass \
    || { report "$label: nothing on stderr" fail; ERRORS+="$(head -3 "$TMPD/err.$rust")"$'\n'; }
done

echo
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
