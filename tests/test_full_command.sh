#!/usr/bin/env bash
#
# Full-command resolution: the COMMAND column must show what the user is
# actually running, and must never break the row contract.
#
# Regression cases, each of which silently broke a /proc-based prototype:
#
#   foreground cmd   tmux's #{pane_current_command} names the pane tty's
#                    FOREGROUND process group, so gating the "is it a shell?"
#                    test on it inverts exactly when a command IS running and
#                    every busy pane renders as "-zsh".  The test must derive
#                    it from the pane process's own argv.
#   backgrounded     `sleep X &` keeps the shell in the foreground -- this is
#                    the case that HIDES the inversion, so it is not sufficient
#                    on its own.
#   control chars    ps replaced NUL/newline with a space and every other
#                    non-printable with '?'.  Reading /proc raw loses that, and
#                    a newline in argv splits the row, detaching its SPEC field.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-fullcmd-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-fullcmd.XXXXXX")"
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

echo "interdimux full-command resolution tests"
echo

# A process that keeps whatever argv we give it and never exits on its own.
SLEEPER=""
if command -v python3 >/dev/null 2>&1; then
  SLEEPER="python3 -c \"import time; time.sleep(600)\""
elif command -v perl >/dev/null 2>&1; then
  SLEEPER="perl -e \"sleep 600\""
fi

# Use a shell with NO rc files.  The developer's real rc runs children of its
# own (pyenv-rehash here), and the resolver correctly reports THOSE as the
# pane's command while init is in flight — so the test would be asserting
# against the rc script, and under load it never settles at all.  This test is
# about command resolution, not about anyone's shell setup.
tmux_cmd new-session -d -s t -x 200 -y 40 -c "$SCRIPT_DIR" 'bash --norc --noprofile -i'
tmux_cmd send-keys -t '=t:0' 'sleep 600' Enter                      # FOREGROUND
tmux_cmd new-window -d -t '=t:' -n bg   -c "$SCRIPT_DIR" 'bash --norc --noprofile -i' 
tmux_cmd send-keys -t '=t:bg' 'sleep 601 &' Enter                   # backgrounded
tmux_cmd new-window -d -t '=t:' -n idle -c "$SCRIPT_DIR" 'bash --norc --noprofile -i'  # plain shell
tmux_cmd new-window -d -t '=t:' -n direct -c "$SCRIPT_DIR" 'sleep 602'   # no shell

if [ -n "$SLEEPER" ]; then
  # argv carrying a newline and a \x1f -- the two bytes that would corrupt a row
  printf '#!/bin/sh\nexec %s "$(printf %s)" "$(printf %s)"\n' \
    "$SLEEPER" "'a\\nb'" "'c\\037d'" > "$TMPD/weird.sh"
  chmod +x "$TMPD/weird.sh"
  tmux_cmd new-window -d -t '=t:' -n weird -c "$SCRIPT_DIR" "exec $TMPD/weird.sh"
fi

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=t:0' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_SHOW_FULL_COMMAND=on INTERDIMUX_SHOW_GIT_BRANCH=off
export INTERDIMUX_ORDER=index INTERDIMUX_USE_ZOXIDE=off

# Wait for the shells to finish initialising, not a fixed duration.  A shell
# mid-rc has a child of its own (here: pyenv-rehash), and the resolver correctly
# reports THAT as the pane's command — so sampling too early asserts against the
# rc script instead of the command under test.  Observed failing only inside a
# full-suite run, where the box is busiest.
wait_settled() {
  local i out
  for i in $(seq 1 200); do
    out=$(bash "$SCRIPT" --list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -F'\t' '{print $3}')
    # every pane we set up should have reached its final command.  The `weird`
    # one needs its own check: it is a /bin/sh wrapper that execs the sleeper,
    # so until the exec lands the resolver correctly reports the wrapper shell —
    # observed as "control chars are sanitized ps-style (got 'bash')", failing
    # only inside a full-suite run.  Its interpreter name is the tell.
    if printf '%s' "$out" | grep -q 'sleep 600' \
       && printf '%s' "$out" | grep -q 'sleep 601' \
       && printf '%s' "$out" | grep -q 'sleep 602' \
       && { [ -z "$SLEEPER" ] || printf '%s' "$out" | grep -q "${SLEEPER%% *}"; } \
       && ! printf '%s' "$out" | grep -q 'pyenv\|rehash'; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}
wait_settled || echo "  (warning: panes did not settle; assertions may be flaky)" >&2

out=$(bash "$SCRIPT" --list 2>/dev/null)
plain=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g')

cmd_for() {  # window name -> its COMMAND column
  local w="$1" idx
  idx=$(tmux -L "$SOCK" list-windows -t '=t:' -F '#{window_index} #{window_name}' \
        | awk -v n="$w" '$2 == n {print $1; exit}')
  printf '%s\n' "$plain" | awk -F'\t' -v spec="W:t:$idx" '$4 == spec {print $3; exit}'
}

# --- the inversion regression ------------------------------------------------
got=$(cmd_for 0 2>/dev/null || true)
[ -z "$got" ] && got=$(printf '%s\n' "$plain" | awk -F'\t' '$4 == "W:t:0" {print $3; exit}')
case "$got" in
  *"sleep 600"*) report "foreground command resolves to the command, not the shell" pass ;;
  *) report "foreground command resolves to the command, not the shell (got '$got')" fail ;;
esac

got=$(cmd_for bg)
case "$got" in
  *"sleep 601"*) report "backgrounded child still resolves" pass ;;
  *) report "backgrounded child still resolves (got '$got')" fail ;;
esac

got=$(cmd_for idle)
# the pane runs an explicit no-rc shell, so the resolved command is its full
# argv ("bash --norc --noprofile -i") rather than a bare "bash"
case "$got" in
  *bash*|*sh*) report "idle shell shows the shell itself" pass ;;
  *) report "idle shell shows the shell itself (got '$got')" fail ;;
esac

got=$(cmd_for direct)
case "$got" in
  *"sleep 602"*) report "pane with no shell shows its own command" pass ;;
  *) report "pane with no shell shows its own command (got '$got')" fail ;;
esac

# --- the row contract --------------------------------------------------------
bad=$(printf '%s\n' "$out" | awk -F'\t' 'NF != 4 { print }')
if [ -z "$bad" ]; then
  report "every row still has exactly 4 fields" pass
else
  report "every row still has exactly 4 fields" fail
fi

if printf '%s' "$out" | grep -q $'\x1f'; then
  report "no \\x1f reaches a rendered row" fail
else
  report "no \\x1f reaches a rendered row" pass
fi

if [ -n "$SLEEPER" ]; then
  got=$(cmd_for weird)
  if [ -n "$got" ]; then
    report "control-char argv still produces a row" pass
  else
    report "control-char argv still produces a row" fail
  fi
  # ps neutralizes control bytes in argv, but HOW is OS-specific: Linux ps maps
  # NUL/newline -> space and every other unprintable -> '?', while macOS/BSD ps
  # escapes to printable text instead (newline -> \012, 0x1f -> ^_).  Either way
  # no RAW row-breaker survives — that safety is enforced by the "4 fields" and
  # "no \x1f" checks above; here we only confirm the bytes were transformed and
  # not passed through verbatim.
  case "$got" in
    *'?'*|*'a b'*|*'\012'*|*'^_'*) report "control chars are neutralized ($(uname -s) ps-style)" pass ;;
    *) report "control chars are neutralized (got '$got')" fail ;;
  esac
else
  echo "  (skipped control-char cases: no python3/perl)"
fi

# --- both backends must agree ------------------------------------------------
# Force the ps backend and compare against whatever this host defaults to.
ps_out=$(INTERDIMUX_FORCE_PS=1 bash "$SCRIPT" --list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -F'\t' '{print $3"\t"$4}')
now_out=$(printf '%s\n' "$plain" | awk -F'\t' '{print $3"\t"$4}')
if [ "$ps_out" = "$now_out" ]; then
  report "/proc and ps backends resolve identically" pass
else
  report "/proc and ps backends resolve identically" fail
  ERRORS+="$(diff <(printf '%s\n' "$now_out") <(printf '%s\n' "$ps_out") | head -8)"$'\n'
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
