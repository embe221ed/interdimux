#!/usr/bin/env bash
#
# gather_targets issues its four tmux queries as ONE command list, with the
# sections separated by RS (\x1e).  Two things have to hold:
#
#   1. the batched result is identical to the separate-query result
#   2. an RS that appears INSIDE a field is detected and falls back
#
# (2) is not hypothetical: tmux rejects RS in session and window names, but a
# pane's working directory can legitimately contain one.  An extra field shifts
# every later section, which truncates a path AND drops the current-row marker
# — silently, on every row.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-batch-test-$$"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-batch.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$WORKDIR"; }
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

echo "interdimux gather-batching tests"
echo

tmux_cmd new-session -d -s b1 -x 200 -y 50 -c "$SCRIPT_DIR"
tmux_cmd new-window  -d -t '=b1:' -n two -c "$SCRIPT_DIR"
tmux_cmd split-window -d -t '=b1:two' -c "$SCRIPT_DIR"
tmux_cmd new-session -d -s b2 -x 200 -y 50 -c "$SCRIPT_DIR"

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=b1:0' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_SHOW_FULL_COMMAND=off INTERDIMUX_SHOW_GIT_BRANCH=off
export INTERDIMUX_ORDER=mru INTERDIMUX_USE_ZOXIDE=off
sleep 2

batched=$(bash "$SCRIPT" --list 2>/dev/null)
separate=$(INTERDIMUX_NO_BATCH=1 bash "$SCRIPT" --list 2>/dev/null)

if [ "$batched" = "$separate" ]; then
  report "batched output matches separate queries" pass
else
  report "batched output matches separate queries" fail
  ERRORS+="$(diff <(printf '%s\n' "$separate") <(printf '%s\n' "$batched") | head -6)"$'\n'
fi

marker_count=$(printf '%s\n' "$batched" | sed 's/\x1b\[[0-9;]*m//g' | grep -c '^\*' || true)
if [ "$marker_count" -ge 1 ]; then
  report "current-row marker survives batching ($marker_count rows)" pass
else
  report "current-row marker survives batching (found none)" fail
fi

# Only ONE tmux invocation should be needed for the queries.  (A cold run also
# dumps options, so prime that away to isolate the gather.)
if command -v strace >/dev/null 2>&1; then
  tr_out="$WORKDIR/trace"
  INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_SHOW_PREVIEW=off INTERDIMUX_POPUP_WIDTH=80% \
    strace -f -e trace=execve -o "$tr_out" bash "$SCRIPT" --list >/dev/null 2>&1 || true
  n=$(grep -c 'execve("[^"]*/tmux"' "$tr_out" || true)
  if [ "$n" -eq 1 ]; then
    report "the gather costs exactly one tmux invocation" pass
  else
    report "the gather costs exactly one tmux invocation (got $n)" fail
  fi
else
  echo "  (skipped exec-count check: no strace)"
fi

# --- the RS-in-a-field guard -------------------------------------------------
rsdir="$WORKDIR/$(printf 'dir\036rs')"
mkdir -p "$rsdir"
tmux_cmd new-window -d -t '=b1:' -n rsw -c "$rsdir"
sleep 2

rs_batched=$(bash "$SCRIPT" --list 2>/dev/null)
rs_separate=$(INTERDIMUX_NO_BATCH=1 bash "$SCRIPT" --list 2>/dev/null)

if [ "$rs_batched" = "$rs_separate" ]; then
  report "an RS inside a pane path falls back instead of corrupting rows" pass
else
  report "an RS inside a pane path falls back instead of corrupting rows" fail
  ERRORS+="$(diff <(printf '%s\n' "$rs_separate") <(printf '%s\n' "$rs_batched") | head -8)"$'\n'
fi

bad=$(printf '%s\n' "$rs_batched" | awk -F'\t' 'NF != 4 { print }')
if [ -z "$bad" ]; then
  report "rows keep 4 fields even with an RS in a path" pass
else
  report "rows keep 4 fields even with an RS in a path" fail
fi

marker_count=$(printf '%s\n' "$rs_batched" | sed 's/\x1b\[[0-9;]*m//g' | grep -c '^\*' || true)
if [ "$marker_count" -ge 1 ]; then
  report "current-row marker survives an RS in a path" pass
else
  report "current-row marker survives an RS in a path (found none)" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
