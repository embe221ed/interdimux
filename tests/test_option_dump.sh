#!/usr/bin/env bash
#
# The cold option dump: what a run that was NOT handed its options (prefix+g's
# dashboard, --jump, --connect-dir, the CLI, tmux < 3.4) reads from tmux.
#
#   * every option survives a multi-line value before it (BUG-27).  The dump
#     joins all @interdimux-* values with US and was split by `read -a`, which
#     stops at the first newline -- and @interdimux-startup-command is
#     multi-line by design.  Two lines there kept only the first, and left hide,
#     raw, the agent options and everything else after it in OPT_MAP at their
#     defaults: a hidden session came back;
#   * @interdimux-project-dirs is read like every other option (BUG-78): at the
#     scope of the pane the run is for, so a per-session override applies, and
#     from the environment in a primed child, which asks tmux nothing for it.
#     It used to be the one option read on its own, with `show-option -g`.
#
# Against a private server (tmux -L), with a fixture HOME and XDG dirs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-optdump-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-optdump.XXXXXX")" && pwd -P)"
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
# $1 = name, $2 = got, $3 = wanted
same() {
  if [ "$2" = "$3" ]; then report "$1" pass
  else report "$1" fail; ERRORS+="      wanted: [$3]"$'\n'"      got:    [$2]"$'\n'; fi
}
I() { tmux -L "$SOCK" "$@"; }

echo "interdimux option dump tests"
echo

export LANG=C.UTF-8 LC_ALL=C.UTF-8
mkdir -p "$TMPD/home" "$TMPD/config/interdimux" "$TMPD/data" "$TMPD/state"
I -f /dev/null new-session -d -s demo -x 120 -y 30
# connect_dir creates its own sessions: pin their shell, or they source the
# user's rc.
I set -g default-command 'bash --norc --noprofile -i'
I new-session -d -s gone1
I new-session -d -s gone2
export TMUX="$(I display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(I list-panes -t '=demo:' -F '#{pane_id}' | head -1)"
export HOME="$TMPD/home" XDG_CONFIG_HOME="$TMPD/config" XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_USE_ZOXIDE=off
# Cold on purpose: nothing below is primed unless it says so.
unset INTERDIMUX_OPTS_PRIMED INTERDIMUX_STARTUP_COMMAND INTERDIMUX_HIDE INTERDIMUX_PROJECT_DIRS

# The session rows --list draws for the hidden sessions.  The current session
# (demo) is never hidden, so it is not one of them.
gone_rows() { # $1 = on|off (the Rust core)
  local out
  out=$(INTERDIMUX_USE_RUST="$1" bash "$SCRIPT" --list 2>/dev/null) || true
  printf '%s\n' "$out" | awk -F'\t' '$NF ~ /^S:gone/ { print $NF }' | sort | tr '\n' ' '
}

# --- 1. a two-line startup command ------------------------------------------
I set -g @interdimux-hide 'gone*'
I set -g @interdimux-startup-command 'echo ONE'
same "control: with a one-line startup command, @interdimux-hide hides" "$(gone_rows off)" ""

I set -g @interdimux-startup-command "echo LINE''_ONE"$'\n'"echo LINE''_TWO"
# What tmux holds is the two lines, or this tests nothing.
same "control: tmux holds the startup command as two lines" \
  "$(I show-option -gqv @interdimux-startup-command | wc -l | tr -d ' ')" 2
renderers=(off)
[ -x "$SCRIPT_DIR/rust/target/release/imux" ] && renderers+=(on)
for r in "${renderers[@]}"; do
  label=bash; [ "$r" = on ] && label=rust
  same "[$label] after a two-line startup command, @interdimux-hide still hides" "$(gone_rows "$r")" ""
done

# ...and the value itself arrives whole: a new session runs both lines.  The
# output lines, not the echoed commands ('' splits each word as typed).
mkdir -p "$TMPD/home/twoline"
bash "$SCRIPT" --connect-dir "$TMPD/home/twoline" >/dev/null 2>&1 || true
out=""
for _i in $(seq 1 150); do
  out=$(I capture-pane -p -t '=twoline:' 2>/dev/null | tr -d '\r') || out=""
  printf '%s\n' "$out" | grep -qx LINE_TWO && break
  sleep 0.1
done
if printf '%s\n' "$out" | grep -qx LINE_ONE && printf '%s\n' "$out" | grep -qx LINE_TWO; then
  report "a two-line @interdimux-startup-command runs both lines in a new session" pass
else
  report "a two-line @interdimux-startup-command runs both lines in a new session" fail
  ERRORS+="      pane: $(printf '%s' "$out" | grep -v '^$' | tail -4 | tr '\n' '|')"$'\n'
fi
I set -gu @interdimux-startup-command
I set -gu @interdimux-hide

# --- 2. @interdimux-project-dirs, at the pane's scope -------------------------
mkdir -p "$TMPD/glob/globproj" "$TMPD/sess/sessproj"
# The search roots a --dirs-list drew, as the directories' names.
dirs_rows() {
  local out
  out=$(bash "$SCRIPT" --dirs-list 2>/dev/null) || true
  printf '%s\n' "$out" | awk -F'\t' '$NF ~ /(glob|sess)proj$/ { sub(/.*\//, "", $NF); print $NF }' | sort | tr '\n' ' '
}
I set -g @interdimux-project-dirs "$TMPD/glob"
same "control: the global @interdimux-project-dirs is searched" "$(dirs_rows)" "globproj "
I set -t '=demo:' @interdimux-project-dirs "$TMPD/sess"
same "a session's own @interdimux-project-dirs overrides the global one" "$(dirs_rows)" "sessproj "

# A primed child (the navigator's ctrl-o picker and its reloads) takes it from
# the environment, as it does every other option, even when it is empty: it
# does not ask tmux.  A tmux earlier on PATH logs every command it is given.
mkdir -p "$TMPD/logbin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/tmux-calls"\nexec %s "$@"\n' "$TMPD" "$(command -v tmux)" > "$TMPD/logbin/tmux"
chmod +x "$TMPD/logbin/tmux"
: > "$TMPD/tmux-calls"
got=$(PATH="$TMPD/logbin:$PATH" INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_PROJECT_DIRS="" dirs_rows)
calls=$(grep -c 'project-dirs' "$TMPD/tmux-calls" || true)
same "a primed --dirs-list asks tmux nothing about project-dirs" "$calls" 0
# Forwarded empty means unset: the default roots, of which the fixture has none.
same "...and an empty forwarded value means the default roots" "$got" ""

# A prefix+f binding baked by an older version primes the popup without the
# variable at all, until tmux next loads the plugin: that still finds the
# user's directories, as it did before the option was forwarded.
I set -t '=demo:' -u @interdimux-project-dirs
got=$(INTERDIMUX_OPTS_PRIMED=1 dirs_rows)
same "a primed run that was not handed project-dirs still reads it from tmux" "$got" "globproj "
I set -gu @interdimux-project-dirs

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
