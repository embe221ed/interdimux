#!/usr/bin/env bash
#
# The command line, and the guards at the navigator's front door.
#
#   * --help / -h / --version answer anywhere — outside tmux, with nothing on
#     PATH — instead of falling through into the navigator.
#   * An argument no mode takes is refused with exit 2.  It used to fall into the
#     navigator: from a terminal that opened the picker, from a script it failed
#     there, appended a bogus entry to errors.log and turned --doctor red.
#   * A helper binary whose output is not a row list is not allowed to BE the
#     picker; the list falls back to the bash renderer.
#
# The navigator is detected with a stand-in fzf that only logs that it started:
# with the fzf version pinned, nothing else in the script runs fzf, so its log is
# the oracle for "the navigator ran".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-cli-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-cli.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  chmod -R u+w "$TMPD" 2>/dev/null || true
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
check() { if eval "$2"; then report "$1" pass; else report "$1" fail; fi; }

echo "interdimux command-line and startup-guard tests"
echo

export LC_ALL=C.UTF-8 LANG=C.UTF-8
# A pane that prints nothing, so the session's activity time — which the rows'
# age column is computed from — holds still between two renders compared below.
tmux -f /dev/null -L "$SOCK" new-session -d -s cli -x 120 -y 40 'sleep 900'
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_USE_ZOXIDE=off

STUB="$TMPD/stub"
mkdir -p "$STUB"
# It also complains on stderr, the way the real fzf does with no terminal to draw
# on — which is what put a bogus "navigator stderr" entry in the error log every
# time an unknown mode fell through.
printf '#!/bin/sh\necho started >> "%s/fzf.log"\necho "stub fzf: no terminal" >&2\nexit 2\n' "$TMPD" > "$STUB/fzf"
chmod +x "$STUB/fzf"
nav_ran() { [ -s "$TMPD/fzf.log" ]; }
# $@ = the script's arguments.  Sets RC, OUT and ERR; stdin is not a tty, as
# from a script or run-shell.
run() {
  rm -f "$TMPD/fzf.log"
  RC=0
  OUT=$(PATH="$STUB:$PATH" timeout 20 bash "$SCRIPT" "$@" </dev/null 2>"$TMPD/err") || RC=$?
  ERR=$(cat "$TMPD/err")
}

# --- the control: no argument IS the navigator ------------------------------------
# Without this, every "the navigator did not run" below could be a broken stub.
run
check "control: with no argument the navigator runs (the stub fzf started)" nav_ran

# --- unknown modes are refused -------------------------------------------------------
for arg in --sched-lsit --bogus doctor --doctr; do
  rm -f "$XDG_STATE_HOME/interdimux/errors.log"
  run "$arg"
  check "'$arg' exits 2 (got $RC)" '[ "$RC" = 2 ]'
  check "...says it is an unknown mode" 'case "$ERR" in *"unknown mode"*"$arg"*) true ;; *) false ;; esac'
  check "...and does not start the navigator" '! nav_ran'
  check "...or write the error log" '[ ! -e "$XDG_STATE_HOME/interdimux/errors.log" ]'
done

# --- --help / -h / --version --------------------------------------------------------
for arg in --help -h; do
  run "$arg"
  check "$arg exits 0" '[ "$RC" = 0 ]'
  check "...prints the modes (--doctor, --send-at)" \
    'case "$OUT" in *--doctor*--send-at*) true ;; *) false ;; esac'
  check "...and does not start the navigator" '! nav_ran'
done
# Anywhere: outside tmux, and with nothing on PATH at all — where someone
# reading about the plugin types it, before anything is installed.
OUT=$(env -u TMUX PATH=/nonexistent "$BASH" "$SCRIPT" --help 2>&1) && RC=0 || RC=$?
check "--help works outside tmux with an empty PATH" \
  '[ "$RC" = 0 ] && case "$OUT" in *--doctor*) true ;; *) false ;; esac'
OUT=$(env -u TMUX PATH=/nonexistent "$BASH" "$SCRIPT" --version 2>&1) && RC=0 || RC=$?
check "--version prints 'interdimux X.Y.Z' there too (got: $OUT)" \
  '[ "$RC" = 0 ] && [[ "$OUT" =~ ^interdimux\ [0-9]+\.[0-9]+\.[0-9]+$ ]]'

# --- a helper binary that is not imux ---------------------------------------------------
# INTERDIMUX_BIN accepts any executable, and whatever one printed on exit 0 used
# to become the entire list.  Now it must be a row list or the bash renderer
# takes over — so the list must be the bash renderer's rows: the same targets,
# in the same order (the spec column, which no clock or width moves), and none
# of the impostor's output.
specs() { printf '%s\n' "$1" | awk -F'\t' '{ print $NF }'; }
printf '#!/bin/sh\necho "hello from not-imux"\n' > "$TMPD/hello"; chmod +x "$TMPD/hello"
want=$(INTERDIMUX_USE_RUST=off INTERDIMUX_SHOW_DIRS=off bash "$SCRIPT" --list 2>/dev/null || true)
for pair in "$TMPD/hello:hello from not-imux" "/bin/echo:gather"; do
  bin="${pair%%:*}" junk="${pair#*:}"
  [ -x "$bin" ] || continue
  got=$(INTERDIMUX_BIN="$bin" INTERDIMUX_SHOW_DIRS=off bash "$SCRIPT" --list 2>/dev/null || true)
  check "INTERDIMUX_BIN=$bin: the list is the bash renderer's rows" \
    '[ -n "$want" ] && [ "$(specs "$got")" = "$(specs "$want")" ]'
  check "...and not a line of what it printed ('$junk')" \
    '! printf "%s\n" "$got" | grep -qxF "$junk"'
done
# ...while a row list DOES pass straight through — a wrapper around the real
# helper that appends one row no renderer could produce, so its presence proves
# the helper's own output was used.
if [ -x "$SCRIPT_DIR/rust/target/release/imux" ]; then
  printf '#!/bin/sh\n"%s" "$@"\nprintf "zz\\tmarker\\t\\tS:zz-only-from-the-helper\\n"\n' \
    "$SCRIPT_DIR/rust/target/release/imux" > "$TMPD/wrapped"
  chmod +x "$TMPD/wrapped"
  got=$(INTERDIMUX_BIN="$TMPD/wrapped" INTERDIMUX_SHOW_DIRS=off bash "$SCRIPT" --list 2>/dev/null || true)
  check "the real helper's rows still pass straight through" \
    'case "$got" in *S:zz-only-from-the-helper*) true ;; *) false ;; esac'
else
  echo "  (skipped the pass-through case: no release binary built)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
