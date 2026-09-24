#!/usr/bin/env bash
#
# The COMMAND column names the pane's foreground job where it is hard to find:
# inside a nested shell, and behind a process whose name mimics /proc syntax.
# Every case runs on both renderers and both process backends.
#
#   nested shell   The user types `bash` (or `zsh -f`) in a pane, then a
#                  command in it.  Resolution used to stop one level down at
#                  the nested shell's own argv, `bash --norc --noprofile`, and
#                  the formatter then drew that busy shell as an idle one, in
#                  the tree colour, while tmux itself reported `sleep`
#                  (review #24).  A nested shell that is the tty's foreground
#                  group is at its own prompt, and is idle.  A shell running a
#                  script is a command, foreground or not, and nothing under
#                  it is shown.
#   hostile comm   The foreground job is found through each child's process
#                  group, read from /proc/<pid>/stat, where the comm field is
#                  parenthesised but may hold ") " and blanks itself.  The
#                  bash reader was rewritten for speed (review #29); a process
#                  named `x) S 1 2 3 4 5` is one whose fields a careless parse
#                  takes from inside its name.
#
# Assertions are on the exact bytes of the COMMAND field against escapes written
# out here from the SGR spec, for two palette values used nowhere else in a row.
# The expected command is the one this suite typed; the process table and tmux's
# own #{pane_current_command} say when a pane has reached the state under test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-fgjob-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-fgjob.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMPD"; }
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

echo "interdimux foreground-job tests"
echo

ACCENT=$'\033[38;5;208m'
TREE=$'\033[38;5;66m'
RST=$'\033[0m'
export INTERDIMUX_COLOR_ACCENT=208 INTERDIMUX_COLOR_TREE=66

SH='bash --norc --noprofile'          # no rc: nothing of the host's shell setup
SLEEP_BIN="$(command -v sleep)"
HAVE_ZSH=0; command -v zsh >/dev/null 2>&1 && HAVE_ZSH=1

# A process named like the inside of a stat line: `pid (x) S 1 2 3 4 5) S ...`.
# comm is the basename the kernel was asked to exec, so a symlink names it.
HOSTILE='x) S 1 2 3 4 5'
ln -s "$SLEEP_BIN" "$TMPD/$HOSTILE"
printf 'sleep 643\n' > "$TMPD/job.sh"

tmux_cmd new-session -d -s t -x 200 -y 40 -n base -c "$TMPD" "exec $SH -i"
for w in nested idle deep stopped script hostile; do
  tmux_cmd new-window -d -t '=t:' -n "$w" -c "$TMPD" "exec $SH -i"
done
[ "$HAVE_ZSH" = 1 ] && tmux_cmd new-window -d -t '=t:' -n zsh -c "$TMPD" "exec $SH -i"

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=t:base' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_SHOW_FULL_COMMAND=on INTERDIMUX_SHOW_GIT_BRANCH=off
export INTERDIMUX_ORDER=index INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off

# --- driving the panes, by what the kernel and tmux report ---------------------
cur_cmd() { tmux -L "$SOCK" display-message -p -t "=t:$1" '#{pane_current_command}'; }
pane_pid() { tmux -L "$SOCK" display-message -p -t "=t:$1" '#{pane_pid}'; }
kids() {  # pid -> "pid args" of each direct child
  ps -eo ppid=,pid=,args= | awk -v p="$1" '$1 == p { $1 = ""; sub(/^ /, ""); print }'
}
# The pid of the only child of $1 whose argv is exactly $2.
kid_pid() { kids "$1" | awk -v a="$2" '{ p = $1; $1 = ""; sub(/^ /, "") } $0 == a { print p; exit }'; }
# pgid == tpgid: the process leads the tty's foreground group
is_fg() {
  local ids
  ids=$(ps -o pgid=,tpgid= -p "$1" 2>/dev/null) || return 1
  set -- $ids
  [ "$#" = 2 ] && [ "$1" = "$2" ]
}
wait_for() {  # label, command...: poll up to ~20 s
  local label="$1" i; shift
  for i in $(seq 1 200); do "$@" && return 0; sleep 0.1; done
  echo "  (warning: never reached: $label)" >&2
  return 1
}

# Start a shell in a window's shell; NESTED = its pid, once it holds the tty.
NESTED=""
nest() {  # window, parent pid, argv of the shell to start
  tmux_cmd send-keys -t "=t:$1" "$3" Enter
  nested_ready() { NESTED=$(kid_pid "$2" "$3"); [ -n "$NESTED" ] && is_fg "$NESTED"; }
  wait_for "$1: $3 at its prompt" nested_ready "$1" "$2" "$3" || :
}

# nested: bash -> bash -> sleep 640
nest nested "$(pane_pid nested)" "$SH"; n1="$NESTED"
tmux_cmd send-keys -t '=t:nested' 'sleep 640' Enter
# idle: bash -> bash, at its prompt
nest idle "$(pane_pid idle)" "$SH"
# deep: bash -> bash -> bash -> sleep 641
nest deep "$(pane_pid deep)" "$SH"; nest deep "$NESTED" "$SH"; d2="$NESTED"
tmux_cmd send-keys -t '=t:deep' 'sleep 641' Enter
# stopped: bash -> bash -> sleep 644, stopped with ^Z: the nested shell is back
# at its prompt with a child of its own
nest stopped "$(pane_pid stopped)" "$SH"; s1="$NESTED"
tmux_cmd send-keys -t '=t:stopped' 'sleep 644' Enter
wait_for "stopped: sleep 644 running" eval '[ "$(cur_cmd stopped)" = sleep ]' || :
tmux_cmd send-keys -t '=t:stopped' C-z
# script: bash -> bash job.sh -> sleep 643, as a background job, so the script's
# shell is NOT the foreground group.  `bash job.sh` is still the command.
tmux_cmd send-keys -t '=t:script' 'bash job.sh &' Enter
# hostile: a background job, then a pipeline whose leader exits at once, so the
# foreground group names no live child and each child's stat is read
tmux_cmd send-keys -t '=t:hostile' "sleep 645 & true | './$HOSTILE' 646" Enter
# zsh: bash -> zsh -f -> sleep 642
if [ "$HAVE_ZSH" = 1 ]; then
  nest zsh "$(pane_pid zsh)" 'zsh -f'; z1="$NESTED"
  tmux_cmd send-keys -t '=t:zsh' 'sleep 642' Enter
fi

settled() {
  [ "$(kids "$n1" | cut -d' ' -f2-)" = 'sleep 640' ] && [ "$(cur_cmd nested)" = sleep ] || return 1
  [ "$(cur_cmd idle)" = bash ] || return 1
  [ "$(kids "$d2" | cut -d' ' -f2-)" = 'sleep 641' ] && [ "$(cur_cmd deep)" = sleep ] || return 1
  local sp; sp=$(kid_pid "$s1" 'sleep 644')
  [ -n "$sp" ] && [ "$(ps -o stat= -p "$sp" | cut -c1)" = T ] && is_fg "$s1" || return 1
  local jp; jp=$(kid_pid "$(pane_pid script)" 'bash job.sh')
  [ -n "$jp" ] && [ "$(kids "$jp" | cut -d' ' -f2-)" = 'sleep 643' ] \
    && is_fg "$(pane_pid script)" || return 1
  [ "$(kids "$(pane_pid hostile)" | cut -d' ' -f2- | sort | tr '\n' ,)" \
    = "./$HOSTILE 646,sleep 645," ] || return 1
  if [ "$HAVE_ZSH" = 1 ]; then
    [ "$(kids "$z1" | cut -d' ' -f2-)" = 'sleep 642' ] && [ "$(cur_cmd zsh)" = sleep ] || return 1
  fi
}
wait_for "every pane in its state" settled || :

cmd_in() {  # list output, window name -> that window's COMMAND field, raw bytes
  local idx
  idx=$(tmux -L "$SOCK" list-windows -t '=t:' -F '#{window_index} #{window_name}' \
        | awk -v n="$2" '$2 == n {print $1; exit}')
  printf '%s\n' "$1" | awk -F'\t' -v spec="W:t:$idx" '$4 == spec {print $3; exit}'
}
vis() { printf '%s' "$1" | cat -v; }
expect() {  # label, got, want
  if [ "$2" = "$3" ]; then
    report "$1" pass
  else
    report "$1 (got '$(vis "$2")', want '$(vis "$3")')" fail
  fi
}

# The first renderer is whatever the environment selects: the Rust core when it
# is built, unless tests/run_all.sh under IMUX_RENDERER=bash exported
# INTERDIMUX_USE_RUST=off, in which case every pass is the bash renderer.
if [ "${INTERDIMUX_USE_RUST:-on}" = off ]; then first="inherited bash renderer"
elif [ -x "$SCRIPT_DIR/rust/target/release/imux" ]; then first="rust renderer"
else first="default renderer (no binary built)"; fi
for cfg in "$first, default backend:" \
           "$first, ps backend:INTERDIMUX_FORCE_PS=1" \
           "bash renderer, default backend:INTERDIMUX_USE_RUST=off" \
           "bash renderer, ps backend:INTERDIMUX_USE_RUST=off INTERDIMUX_FORCE_PS=1"; do
  label="${cfg%%:*}"
  # shellcheck disable=SC2086
  out=$(env ${cfg#*:} bash "$SCRIPT" --list 2>/dev/null)

  expect "$label: a nested shell's foreground job is the command, in the accent" \
    "$(cmd_in "$out" nested)" "${ACCENT}sleep 640${RST}"
  expect "$label: two nested shells deep, still the foreground job" \
    "$(cmd_in "$out" deep)" "${ACCENT}sleep 641${RST}"
  if [ "$HAVE_ZSH" = 1 ]; then
    expect "$label: a nested zsh's foreground job is the command" \
      "$(cmd_in "$out" zsh)" "${ACCENT}sleep 642${RST}"
  fi
  expect "$label: a nested shell at its prompt is idle, dimmed" \
    "$(cmd_in "$out" idle)" "${TREE}bash${RST}"
  expect "$label: a nested shell at its prompt over a stopped job is idle" \
    "$(cmd_in "$out" stopped)" "${TREE}bash${RST}"
  expect "$label: a shell running a script is the command, not what it runs" \
    "$(cmd_in "$out" script)" "${ACCENT}bash job.sh${RST}"
  expect "$label: a foreground job whose name mimics a stat line is found" \
    "$(cmd_in "$out" hostile)" "${ACCENT}x) S 1 2 3 4 5 646${RST}"
done
[ "$HAVE_ZSH" = 1 ] || echo "  (skipped the nested-zsh cases: zsh is not installed)"

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
