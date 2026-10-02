#!/usr/bin/env bash
#
# Tests for directory-picker session naming (--session-name-for).
#
# Verifies that same-named projects in different directories get
# disambiguated session names instead of silently reusing an existing
# session, while picking the same directory again reuses its session.
#
# Also: directories whose names tmux reads specially, opened through
# --connect-dir (see "Odd basenames" below).
#
# Uses a dedicated tmux server socket so tests don't interfere with the
# user's live session.

set -euo pipefail

# A UTF-8 locale for the non-ASCII name below: in the C locale tmux turns
# every byte of one into '_'.
export LC_ALL=C.UTF-8 LANG=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-names-test-$$"
OUTER="${SOCK}-outer"
TMPDIR_TEST="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-names-test-XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

# OUTER first: it holds the client attached to $SOCK.
cleanup() {
  tmux -L "$OUTER" kill-server 2>/dev/null || true
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

# Every pane a plain bash: no rc file may move a cwd these tests wait on.
SHELL_CMD='bash --norc --noprofile -i'
tmux_cmd new-session -d -s bootstrap -x 80 -y 24 -c "$TMPDIR_TEST" "$SHELL_CMD"
tmux_cmd set -g default-command "$SHELL_CMD"
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
# Odd basenames, through --connect-dir
# ---------------------------------------------------------------------------
#
# What a directory's name can hold that tmux reads specially: '.' and ':'
# (target separators, which the name rewrites to '-'), all digits (an index,
# where a target takes one), '$N' (a session ID to tmux, with '=' or without),
# '#' (format-expanded by new-session -s), a quote, a space, non-ASCII, and a
# leading '-' (an option, on a command line).  Each must get one stable name,
# and the same directory opened twice must give ONE session: a name that does
# not round-trip creates another session on every Enter, and one that matches
# the wrong session switches into another project's.
#
# The expected names are written out, not derived.  '$9' comes early, while no
# session has the ID $9, and is opened once more at the end, when one does.
#
# The script runs directly against the private server, with HOME and the XDG
# directories inside the fixture: --connect-dir records each directory in the
# recent list (and in zoxide, off here).  A client is attached, and "lands on
# it" is the session tmux says that client shows, not what the script says.
ODD=(
  'my.proj|my-proj'
  '$9|$9'
  'a:b|a-b'
  '3|3'
  '$1|$1'
  'we#ird|we#ird'
  "it's|it's"
  'has space|has space'
  '日本|日本'
  '-dash|-dash'
)
ODD_ENV=(
  TMUX="$(tmux_cmd display-message -p '#{socket_path}'),99999,0"
  HOME="$TMPDIR_TEST/home" XDG_CONFIG_HOME="$TMPDIR_TEST/config"
  XDG_DATA_HOME="$TMPDIR_TEST/data" XDG_STATE_HOME="$TMPDIR_TEST/state"
  INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_HYDRATE=off
)
mkdir -p "$TMPDIR_TEST/home"
imux() { env -u TMUX_PANE "${ODD_ENV[@]}" bash "$SCRIPT" "$@"; }
# "ID NAME", one per session, in one collation for comm
sessions() { tmux -L "$SOCK" list-sessions -F '#{session_id} #{session_name}' | LC_ALL=C sort; }
wait_until() { # $1 = tenths of a second, $2.. = a command that must succeed
  local n="$1" i; shift
  for i in $(seq 1 "$n"); do "$@" && return 0; sleep 0.1; done
  return 1
}
pane_at() { [ "$(tmux -L "$SOCK" display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null)" = "$2" ]; }
# From the client table: display-message -c only picks the client that shows
# the message, and evaluates the format against the current pane -- taken from
# an inherited TMUX_PANE, which on a young server names a pane here too.
client_on() {
  [ "$(tmux -L "$SOCK" list-clients -F '#{client_name} #{session_id}' 2>/dev/null \
       | awk -v c="$CLIENT" '$1 == c { print $2 }')" = "$1" ]
}
# Opens $1 with --connect-dir from bootstrap.  Sets RC, NEW (the sessions that
# appeared) and GONE (the ones that disappeared or were renamed).
open_dir() {
  local before after
  tmux -L "$SOCK" switch-client -c "$CLIENT" -t bootstrap
  before=$(sessions)
  RC=0; imux --connect-dir "$1" >/dev/null 2>&1 || RC=$?
  after=$(sessions)
  NEW=$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
  GONE=$(LC_ALL=C comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
}

tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 100 -y 30 \
  "env -u TMUX -u TMUX_PANE tmux -L '$SOCK' attach -t bootstrap"
CLIENT=""
for _ in $(seq 1 100); do
  CLIENT=$(tmux -L "$SOCK" list-clients -F '#{client_name}' 2>/dev/null | head -1)
  [ -n "$CLIENT" ] && break
  sleep 0.1
done

echo
echo "odd basenames, through --connect-dir"
if [ -z "$CLIENT" ]; then
  report "setup: a client is attached to the test server" fail
fi
nine_id=""
for row in ${CLIENT:+"${ODD[@]}"}; do
  base="${row%%|*}" want="${row#*|}"
  dir="$TMPDIR_TEST/odd/$base"
  mkdir -p "$dir"

  n1=$(imux --session-name-for "$dir"); n2=$(imux --session-name-for "$dir")
  if [ "$n1" = "$want" ] && [ "$n2" = "$want" ]; then
    report "'$base' is named '$want'" pass
  else
    report "'$base' is named '$want' (got: '$n1', then '$n2')" fail
  fi

  open_dir "$dir"
  id="${NEW%% *}"
  if [ "$RC" = 0 ] && [ -z "$GONE" ] && [ "$NEW" = "$id $want" ] \
     && wait_until 100 pane_at "$id" "$dir" && wait_until 20 client_on "$id"; then
    report "...the first open creates that one session, in it, and lands on it" pass
  else
    report "...the first open creates that one session, in it, and lands on it" fail
    ERRORS+="    '$base': rc=$RC new=[$NEW] gone=[$GONE]"$'\n'
  fi
  [ "$base" = '$9' ] && nine_id="$id"

  open_dir "$dir"
  if [ "$RC" = 0 ] && [ -z "$NEW" ] && [ -z "$GONE" ] && wait_until 20 client_on "$id"; then
    report "...the second creates and renames nothing, and lands on it again" pass
  else
    report "...the second creates and renames nothing, and lands on it again" fail
    ERRORS+="    '$base': rc=$RC new=[$NEW] gone=[$GONE]"$'\n'
  fi

  n3=$(imux --session-name-for "$dir")
  if [ "$n3" = "$want" ]; then
    report "...and the name stays '$want'" pass
  else
    report "...and the name stays '$want' (got: '$n3')" fail
  fi
done

# Session ID $9 is now another directory's, so "=$9" names THAT session to
# tmux.  The session named '$9' is still found by its name.
if [ -n "$nine_id" ]; then
  other=$(tmux -L "$SOCK" display-message -p -t '$9' '#{session_name}' 2>/dev/null || true)
  if [ -n "$other" ] && [ "$other" != '$9' ] && [ "$nine_id" != '$9' ]; then
    open_dir "$TMPDIR_TEST/odd/\$9"
    if [ "$RC" = 0 ] && [ -z "$NEW" ] && [ -z "$GONE" ] && wait_until 20 client_on "$nine_id"; then
      report "'\$9', once session ID \$9 is '$other', still opens its own session" pass
    else
      report "'\$9', once session ID \$9 is '$other', still opens its own session" fail
      ERRORS+="    rc=$RC new=[$NEW] gone=[$GONE]"$'\n'
    fi
  else
    report "setup: session ID \$9 exists and is not the session '\$9' (it is '$other')" fail
  fi
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
