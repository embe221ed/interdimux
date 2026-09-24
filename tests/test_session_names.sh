#!/usr/bin/env bash
#
# Tests for directory-picker session naming (--session-name-for).
#
# Verifies that same-named projects in different directories get
# disambiguated session names instead of silently reusing an existing
# session, while picking the same directory again reuses its session.
#
# Uses a dedicated tmux server socket so tests don't interfere with the
# user's live session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-names-test-$$"
TMPDIR_TEST="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-names-test-XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

tmux_cmd() {
  # -f /dev/null: keep the test server hermetic (see test_list_format.sh)
  tmux -f /dev/null -L "$SOCK" "$@"
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

# Resolve a session name inside the test tmux server (run-shell makes the
# script talk to the right server) and capture the output via a file.
name_for() {
  local dir="$1"
  local out_file="$TMPDIR_TEST/name_out"
  tmux_cmd run-shell "bash '$SCRIPT' --session-name-for '$dir' > '$out_file'" 2>/dev/null || true
  head -1 "$out_file"
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

mkdir -p "$TMPDIR_TEST/alpha/api" "$TMPDIR_TEST/beta/api" "$TMPDIR_TEST/gamma/api"

# A session is found by where its pane IS, and tmux lists a new pane before
# /proc has its cwd.  So each new session is waited for until tmux reports the
# directory it was started in (physical, as /proc has it), rather than for a
# fixed half second.
cwd_is() { # $1 = session, $2 = directory
  local want i
  want=$(cd "$2" && pwd -P)
  for i in $(seq 1 100); do
    [ "$(tmux_cmd display-message -p -t "=$1:" '#{pane_current_path}' 2>/dev/null)" = "$want" ] && return 0
    sleep 0.1
  done
  echo "  (session $1 never reported its cwd $want)" >&2
  return 1
}

tmux_cmd new-session -d -s bootstrap -x 80 -y 24 -c "$TMPDIR_TEST"
cwd_is bootstrap "$TMPDIR_TEST" || true

echo "interdimux session-name tests"
echo

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# No conflict: plain basename
got=$(name_for "$TMPDIR_TEST/alpha/api")
if [ "$got" = "api" ]; then
  report "fresh name uses directory basename" pass
else
  report "fresh name uses directory basename (got: $got)" fail
fi

# Create the session, then resolving the same dir reuses the name
tmux_cmd new-session -d -s api -c "$TMPDIR_TEST/alpha/api" -x 80 -y 24
cwd_is api "$TMPDIR_TEST/alpha/api" || true
got=$(name_for "$TMPDIR_TEST/alpha/api")
if [ "$got" = "api" ]; then
  report "same directory reuses existing session name" pass
else
  report "same directory reuses existing session name (got: $got)" fail
fi

# Different dir with the same basename gets the parent-prefixed name
got=$(name_for "$TMPDIR_TEST/beta/api")
if [ "$got" = "beta-api" ]; then
  report "same basename, different dir gets parent prefix" pass
else
  report "same basename, different dir gets parent prefix (got: $got)" fail
fi

# Occupy the parent-prefixed name with yet another dir → numeric suffix
tmux_cmd new-session -d -s beta-api -c "$TMPDIR_TEST/beta/api" -x 80 -y 24
cwd_is beta-api "$TMPDIR_TEST/beta/api" || true
got=$(name_for "$TMPDIR_TEST/gamma/api")
if [ "$got" = "gamma-api" ]; then
  report "third same-named project gets its own parent prefix" pass
else
  report "third same-named project gets its own parent prefix (got: $got)" fail
fi

# Parent prefix also taken by a foreign dir → numeric suffix fallback
tmux_cmd new-session -d -s gamma-api -c "$TMPDIR_TEST/alpha" -x 80 -y 24
cwd_is gamma-api "$TMPDIR_TEST/alpha" || true
got=$(name_for "$TMPDIR_TEST/gamma/api")
if [ "$got" = "api-2" ]; then
  report "taken parent prefix falls back to numeric suffix" pass
else
  report "taken parent prefix falls back to numeric suffix (got: $got)" fail
fi

# Existing parent-prefixed session for the same dir is reused
got=$(name_for "$TMPDIR_TEST/beta/api")
if [ "$got" = "beta-api" ]; then
  report "parent-prefixed session reused for its own dir" pass
else
  report "parent-prefixed session reused for its own dir (got: $got)" fail
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
