#!/usr/bin/env bash
#
# Tests for the "send keys" action broadcast behavior.
#
# Verifies that --action send broadcasts to ALL panes under the selected
# target:
#   - Session → all windows → all panes
#   - Window  → all panes in that window
#   - Pane    → just that single pane
#
# Uses a dedicated tmux server socket so tests don't interfere with the
# user's live session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-test-$$"
TMPDIR_TEST="/tmp/interdimux-test-$$"
PASS=0
FAIL=0
ERRORS=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

tmux_cmd() {
  # -f /dev/null: don't inherit the developer's ~/.tmux.conf (a user
  # `base-index 1` breaks every ":0" target used below)
  tmux -f /dev/null -L "$SOCK" "$@"
}

# Wait for a pane to contain a specific string (with timeout)
pane_contains() {
  local target="$1" pattern="$2" timeout="${3:-5}"
  local end=$(( SECONDS + timeout ))
  while [ "$SECONDS" -lt "$end" ]; do
    if tmux_cmd capture-pane -t "$target" -p 2>/dev/null | grep -qF "$pattern"; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# Run the send action inside the test tmux server.
#
# We use tmux run-shell so the script inherits the correct TMUX env and
# talks to the right server. Input is provided via a file that
# INTERDIMUX_TTY_IN points at; output goes to /dev/null.
run_send_action() {
  local spec="$1" cmd="$2"
  local input_file="$TMPDIR_TEST/input"

  printf '%s\n' "$cmd" > "$input_file"

  # run-shell executes synchronously inside the tmux server, so every key the
  # action sends has been sent when it returns.  No sleep: the checks poll the
  # panes for what arrives (pane_contains), and the one that asserts something
  # did NOT arrive waits for a sentinel instead (arrived_after).
  tmux_cmd run-shell \
    "INTERDIMUX_TTY_IN='$input_file' INTERDIMUX_TTY_OUT=/dev/null bash '$SCRIPT' --action send '$spec'" \
    2>/dev/null || true
}

# Keys reach a pane in the order they were sent.  Type a sentinel of our own
# into $1 and wait for it: once it is on screen, anything sent to that pane
# before it would be on screen too.  $2 = the sentinel.
arrived_after() {
  tmux_cmd send-keys -t "$1" "$2" 2>/dev/null || true
  pane_contains "$1" "$2"
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

# ---------------------------------------------------------------------------
# Setup: create a tmux server with known layout
# ---------------------------------------------------------------------------
#
# Session "test-sess":
#   Window 0 "win0": 2 panes (split)
#   Window 1 "win1": 1 pane
#
# Session "test-sess2":
#   Window 0 "single": 1 pane

setup() {
  cleanup
  mkdir -p "$TMPDIR_TEST"

  # A pinned shell, not the user's login shell and its rc files: what the
  # checks read is what that shell echoes and prints.
  local sh='bash --norc --noprofile -i'
  tmux_cmd new-session -d -s "test-sess" -n "win0" -x 120 -y 30 "$sh"
  tmux_cmd split-window -t "=test-sess:0" -h "$sh"
  tmux_cmd new-window -t "=test-sess" -n "win1" "$sh"
  tmux_cmd new-session -d -s "test-sess2" -n "single" -x 120 -y 30 "$sh"

  # Every shell is at its prompt (rather than a fixed second for them to start).
  local p i
  for p in "=test-sess:0.0" "=test-sess:0.1" "=test-sess:1.0" "=test-sess2:0.0"; do
    for i in $(seq 1 100); do
      tmux_cmd capture-pane -t "$p" -p 2>/dev/null | grep -q '\$ *$' && break
      sleep 0.1
    done
  done
}

# ---------------------------------------------------------------------------
# Test 1: send to a single pane (P spec) — only that pane receives it
# ---------------------------------------------------------------------------

test_send_single_pane() {
  local marker="SINGLEPANE_$$_$RANDOM"
  run_send_action "P:test-sess:1:0" "echo $marker"

  if pane_contains "=test-sess:1.0" "$marker"; then
    report "send to single pane (P spec)" "pass"
  else
    report "send to single pane (P spec)" "fail"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: send to a window with multiple panes (W spec)
#   → must reach ALL panes in that window
# ---------------------------------------------------------------------------

test_send_window_multi_pane() {
  local marker="WINBCAST_$$_$RANDOM"
  run_send_action "W:test-sess:0" "echo $marker"

  local ok=true
  pane_contains "=test-sess:0.0" "$marker" || ok=false
  pane_contains "=test-sess:0.1" "$marker" || ok=false

  if [ "$ok" = "true" ]; then
    report "send to window broadcasts to all panes (W spec)" "pass"
  else
    report "send to window broadcasts to all panes (W spec)" "fail"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: send to a window with a single pane (W spec)
# ---------------------------------------------------------------------------

test_send_window_single_pane() {
  local marker="WINSINGLE_$$_$RANDOM"
  run_send_action "W:test-sess:1" "echo $marker"

  if pane_contains "=test-sess:1.0" "$marker"; then
    report "send to single-pane window (W spec)" "pass"
  else
    report "send to single-pane window (W spec)" "fail"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: send to a session (S spec)
#   → must reach ALL panes in ALL windows of that session
# ---------------------------------------------------------------------------

test_send_session() {
  local marker="SESSBCAST_$$_$RANDOM"
  run_send_action "S:test-sess" "echo $marker"

  local ok=true
  # Window 0 has 2 panes
  pane_contains "=test-sess:0.0" "$marker" || ok=false
  pane_contains "=test-sess:0.1" "$marker" || ok=false
  # Window 1 has 1 pane
  pane_contains "=test-sess:1.0" "$marker" || ok=false

  if [ "$ok" = "true" ]; then
    report "send to session broadcasts to all windows and panes (S spec)" "pass"
  else
    report "send to session broadcasts to all windows and panes (S spec)" "fail"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: send to a session does NOT leak to other sessions
# ---------------------------------------------------------------------------

test_send_no_leak() {
  local marker="NOLEAK_$$_$RANDOM"
  run_send_action "S:test-sess" "echo $marker"

  # test-sess2 must NOT contain the marker.  Not "wait 2 s and look": the
  # sentinel below reaches that pane after anything the action sent it.
  if ! arrived_after "=test-sess2:0.0" "SENTINEL_$$"; then
    report "send to session does not leak to other sessions (the sentinel never arrived)" "fail"
  elif [[ "$(tmux_cmd capture-pane -t "=test-sess2:0.0" -p 2>/dev/null)" == *"$marker"* ]]; then
    report "send to session does not leak to other sessions" "fail"
  else
    report "send to session does not leak to other sessions" "pass"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

printf '\n\033[1mSend Keys Broadcast Tests\033[0m\n\n'

setup

test_send_single_pane
test_send_window_multi_pane
test_send_window_single_pane
test_send_session
test_send_no_leak

# same "Results: N passed, N failed" line as every other suite, so the runner
# can total them up instead of special-casing this one
printf '\nResults: %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"

exit "$FAIL"
