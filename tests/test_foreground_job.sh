#!/usr/bin/env bash
#
# The COMMAND column names the pane's foreground job where it is hard to find:
# behind a process whose name mimics /proc syntax.  Every case runs on both
# renderers and both process backends.
#
#   hostile comm   The foreground job is found through each child's process
#                  group, read from /proc/<pid>/stat, where the comm field is
#                  parenthesised but may hold ") " and blanks itself.  The
#                  bash reader was rewritten for speed (review #29); a process
#                  named `x) S 1 2 3 4 5` is one whose fields a careless parse
#                  takes from inside its name.
#
# Assertions are on the exact bytes of the COMMAND field against escapes written
# out here from the SGR spec, for a palette value used nowhere else in a row.
# The expected command is the one this suite typed; the process table says when
# the pane has reached the state under test.

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
RST=$'\033[0m'
export INTERDIMUX_COLOR_ACCENT=208 INTERDIMUX_COLOR_TREE=66

SH='bash --norc --noprofile'          # no rc: nothing of the host's shell setup
SLEEP_BIN="$(command -v sleep)"

# A process named like the inside of a stat line: `pid (x) S 1 2 3 4 5) S ...`.
# comm is the basename the kernel was asked to exec, so a symlink names it.
HOSTILE='x) S 1 2 3 4 5'
ln -s "$SLEEP_BIN" "$TMPD/$HOSTILE"

tmux_cmd new-session -d -s t -x 200 -y 40 -n base -c "$TMPD" "exec $SH -i"
tmux_cmd new-window -d -t '=t:' -n hostile -c "$TMPD" "exec $SH -i"

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=t:base' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_SHOW_FULL_COMMAND=on INTERDIMUX_SHOW_GIT_BRANCH=off
export INTERDIMUX_ORDER=index INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off

# --- driving the panes, by what the kernel and tmux report ---------------------
pane_pid() { tmux -L "$SOCK" display-message -p -t "=t:$1" '#{pane_pid}'; }
kids() {  # pid -> "pid args" of each direct child
  ps -eo ppid=,pid=,args= | awk -v p="$1" '$1 == p { $1 = ""; sub(/^ /, ""); print }'
}
wait_for() {  # label, command...: poll up to ~20 s
  local label="$1" i; shift
  for i in $(seq 1 200); do "$@" && return 0; sleep 0.1; done
  echo "  (warning: never reached: $label)" >&2
  return 1
}

# hostile: a background job, then a pipeline whose leader exits at once, so the
# foreground group names no live child and each child's stat is read
tmux_cmd send-keys -t '=t:hostile' "sleep 645 & true | './$HOSTILE' 646" Enter
settled() {
  [ "$(kids "$(pane_pid hostile)" | cut -d' ' -f2- | sort | tr '\n' ,)" \
    = "./$HOSTILE 646,sleep 645," ]
}
wait_for "hostile: the pipeline running" settled || :

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

  expect "$label: a foreground job whose name mimics a stat line is found" \
    "$(cmd_in "$out" hostile)" "${ACCENT}x) S 1 2 3 4 5 646${RST}"
done

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
