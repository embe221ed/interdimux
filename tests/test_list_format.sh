#!/usr/bin/env bash
#
# Tests for the navigator list output (--list).
#
# Verifies the display contract the fzf integration depends on:
#   - every row has exactly 4 tab-separated fields with the SPEC last
#   - MRU ordering: most recently active sessions first, the current
#     session moved to the end
#   - INTERDIMUX_ORDER=index preserves tmux's native (alphabetical) order
#   - window/pane rows carry their session name (search context)
#   - pane rows appear only for multi-pane windows
#
# Uses a dedicated tmux server socket so tests don't interfere with the
# user's live session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-list-test-$$"
OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/interdimux-list-out.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -f "$OUT_FILE"
}
trap cleanup EXIT

tmux_cmd() {
  tmux -L "$SOCK" "$@"
}

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1))
    printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: $name"$'\n'
    printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

# Run --list inside the test server from charlie's pane (making charlie
# the "current" session), ANSI codes stripped.
run_list() {
  local extra_env="${1:-}"
  tmux_cmd run-shell -t "=charlie:0" \
    "$extra_env bash '$SCRIPT' --list > '$OUT_FILE'" 2>/dev/null || true
  sed $'s/\x1b\\[[0-9;]*m//g' "$OUT_FILE"
}

# Session name of each session row, in order (the driver session is
# test plumbing — its position is timing-dependent, so it is excluded)
session_order() {
  awk -F'\t' '$4 ~ /^S:/ { sub(/^S:/, "", $4); print $4 }' | grep -v '^driver$'
}

# ---------------------------------------------------------------------------
# Setup: alpha (multi-pane), bravo, charlie — attached in a staggered
# order (via a nested client running in the driver session's pane tty)
# so the MRU order (bravo, alpha, charlie-last) differs from the
# alphabetical index order (alpha, bravo, charlie).
# ---------------------------------------------------------------------------

tmux_cmd new-session -d -s alpha -x 120 -y 30
tmux_cmd split-window -t "=alpha:0" -h
tmux_cmd new-session -d -s bravo -x 120 -y 30
tmux_cmd new-session -d -s charlie -x 120 -y 30
tmux_cmd new-session -d -s driver -x 120 -y 30 /bin/sh
sleep 0.5

# Attach (then detach) a real client to alpha, then bravo — this is the
# only reliable way to advance #{session_last_attached} headlessly.
visit() {
  tmux_cmd send-keys -t "=driver:0" "TMUX= tmux -L '$SOCK' attach -t '=$1'" Enter
  sleep 1.2
  tmux_cmd detach-client -s "=$1" 2>/dev/null || true
  sleep 0.3
}
visit alpha
visit bravo

echo "interdimux --list format tests"
echo

out=$(run_list)

# ---------------------------------------------------------------------------
# Field structure
# ---------------------------------------------------------------------------

bad_fields=$(printf '%s\n' "$out" | awk -F'\t' 'NF != 4 { print }')
if [ -z "$bad_fields" ]; then
  report "every row has exactly 4 tab-separated fields" pass
else
  report "every row has exactly 4 tab-separated fields" fail
fi

bad_specs=$(printf '%s\n' "$out" | awk -F'\t' '$4 !~ /^[SWP]:/ { print }')
if [ -z "$bad_specs" ]; then
  report "every row ends with a S:/W:/P: spec field" pass
else
  report "every row ends with a S:/W:/P: spec field" fail
fi

# ---------------------------------------------------------------------------
# Ordering
# ---------------------------------------------------------------------------

order=$(printf '%s\n' "$out" | session_order | tr '\n' ' ')
if [ "$order" = "bravo alpha charlie " ]; then
  report "MRU order: recent first, current session last (got: $order)" pass
else
  report "MRU order: recent first, current session last (got: $order)" fail
fi

out_index=$(run_list "INTERDIMUX_ORDER=index")
order=$(printf '%s\n' "$out_index" | session_order | tr '\n' ' ')
if [ "$order" = "alpha bravo charlie " ]; then
  report "index order keeps tmux native order (got: $order)" pass
else
  report "index order keeps tmux native order (got: $order)" fail
fi

# ---------------------------------------------------------------------------
# Row content
# ---------------------------------------------------------------------------

if printf '%s\n' "$out" | awk -F'\t' '$4 == "W:bravo:0"' | grep -q 'bravo'; then
  report "window rows carry their session name" pass
else
  report "window rows carry their session name" fail
fi

if printf '%s\n' "$out" | grep -q $'\tP:alpha:0:'; then
  report "multi-pane window lists its panes" pass
else
  report "multi-pane window lists its panes" fail
fi

if printf '%s\n' "$out" | grep -q $'\tP:bravo:'; then
  report "single-pane windows list no panes" fail
else
  report "single-pane windows list no panes" pass
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
