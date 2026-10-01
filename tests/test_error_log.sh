#!/usr/bin/env bash
#
# What reaches the error log, and the status line, when something fails.
#
# The navigator sends its stderr to a file and, when it exits, reports the
# first line on the status line and appends the whole file to errors.log
# (--doctor's "the navigator has logged N error(s)").  Three ways a failure
# used to leave no trace at all:
#
#   * BUG-60  a child of fzf's binds -- the --list a ^r, ^/, a resize or an
#             action's reload runs -- has /dev/null for stderr (fzf gives a
#             reload, transform or execute-silent child nothing else), so a
#             reload that failed was neither shown nor logged
#   * BUG-104 an error whose first line was blank was dropped whole: the
#             reporter stopped at the empty line before it reached the log
#   * BUG-106 fzf itself failing or being killed (exit 2, 137) looked exactly
#             like Esc: no message, no entry
#
# The navigator runs in a pane of an outer server with TMUX pointing at the
# server under test, as in tests/test_doctor.sh; fzf is either the real one or
# a stand-in on PATH that fails on cue.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-errlog-test-$$"
OUTER="${SOCK}-o"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-errlog.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  tmux -L "$SOCK" kill-server 2>/dev/null || true
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
wait_for() { # $1 = a command that must succeed [, $2 = tenths of a second]
  local i
  for i in $(seq 1 "${2:-100}"); do eval "$1" && return 0; sleep 0.1; done
  return 1
}

echo "interdimux error-log tests"
echo

tmux -f /dev/null -L "$SOCK" new-session -d -s one -x 120 -y 30
tmux -L "$SOCK" set -g default-command 'bash --norc --noprofile -i'
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=one:' -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state" XDG_CACHE_HOME="$TMPD/cache"
export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_HYDRATE=off
LOG="$XDG_STATE_HOME/interdimux/errors.log"
msgs() { tmux -L "$SOCK" show-messages 2>/dev/null || true; }

# --- a child of the binds appends to the navigator's error file ---------------------
# Measured by what lands in the file the navigator exports, with the child's own
# stderr pointed at a second file -- fzf hands it /dev/null, which would hide
# the difference.  A dump that cannot be read is the --list failure on cue.
F="$TMPD/nav.err" G="$TMPD/child.err"
: > "$F"; : > "$G"
INTERDIMUX_ERR_FILE="$F" INTERDIMUX_DUMP_IN="$TMPD/no-such.dump" \
  bash "$SCRIPT" --list >/dev/null 2>"$G" || true
if grep -q 'INTERDIMUX_DUMP_IN: cannot read' "$F"; then
  report "a failing --list reports into the navigator's error file" pass
else
  report "a failing --list reports into the navigator's error file" fail
  ERRORS+="    file: '$(cat "$F")'  own stderr: '$(cat "$G")'"$'\n'
fi
# ...and only while that file exists: a child that outlives the navigator, whose
# exit removed it, must not recreate it -- it has its own stderr to fall back on
rm -f "$F"; : > "$G"
INTERDIMUX_ERR_FILE="$F" INTERDIMUX_DUMP_IN="$TMPD/no-such.dump" \
  bash "$SCRIPT" --list >/dev/null 2>"$G" || true
if [ ! -e "$F" ] && grep -q 'cannot read' "$G"; then
  report "...but does not recreate it once the navigator has gone" pass
else
  report "...but does not recreate it once the navigator has gone" fail
fi

# The previews are left alone: fzf shows a preview's stderr IN the preview,
# where it is already visible.  Which file a mode's stderr is, read from /proc
# by a stand-in tmux the mode runs (its parent is the mode's bash).  Linux only.
if [ -r "/proc/$$/fd/2" ] && command -v readlink >/dev/null 2>&1; then
  mkdir -p "$TMPD/fdbin"
  cat > "$TMPD/fdbin/tmux" <<STUB
#!/bin/sh
readlink "/proc/\$PPID/fd/2" >> "$TMPD/fd2.log" 2>/dev/null
exec $(command -v tmux) "\$@"
STUB
  chmod +x "$TMPD/fdbin/tmux"
  fd2_of() { # $@ = the mode and its arguments -> the stderrs its tmux calls saw
    : > "$F"; : > "$TMPD/fd2.log"
    PATH="$TMPD/fdbin:$PATH" INTERDIMUX_ERR_FILE="$F" \
      bash "$SCRIPT" "$@" >/dev/null 2>"$G" </dev/null || true
    sort -u "$TMPD/fd2.log"
  }
  out=$(fd2_of --list)
  if grep -qxF "$F" <<< "$out"; then
    report "control: --list runs with the navigator's error file as stderr" pass
  else
    report "control: --list runs with the navigator's error file as stderr" fail
    ERRORS+="    saw: $(tr '\n' ' ' <<< "$out")"$'\n'
  fi
  out=$(fd2_of --preview 'S:one')
  if [ -n "$out" ] && ! grep -qxF "$F" <<< "$out"; then
    report "--preview keeps the stderr fzf gave it" pass
  else
    report "--preview keeps the stderr fzf gave it" fail
    ERRORS+="    saw: $(tr '\n' ' ' <<< "$out")"$'\n'
  fi
fi

# --- end to end: a reload that fails is reported when the navigator exits ------------
# The list comes from a dump (INTERDIMUX_DUMP_IN), which every child inherits, so
# deleting it makes exactly the reloads fail: the first frame renders, ^r then
# runs a --list that cannot read it.
fzf_minor=$(fzf --version 2>/dev/null | awk '{print $1}' | cut -d. -f2)
if [ "${fzf_minor:-0}" -ge 53 ]; then
  cp "$SCRIPT_DIR/rust/tests/corpus/basic.dump" "$TMPD/nav.dump"
  rm -f "$LOG"
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 120 -y 30 \
    "env TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' XDG_STATE_HOME='$XDG_STATE_HOME' \
         XDG_DATA_HOME='$XDG_DATA_HOME' INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=$fzf_minor \
         INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_DUMP_IN='$TMPD/nav.dump' \
         bash '$SCRIPT'; echo NAV-EXITED; sleep 30"
  screen() { tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null || true; }
  if wait_for 'screen | grep -q bravo' 150; then
    rm -f "$TMPD/nav.dump"
    tmux -L "$OUTER" send-keys -t '=drv:' C-r
    # the reload has run once the rows are gone
    wait_for '! screen | grep -q bravo' 100 || true
    tmux -L "$OUTER" send-keys -t '=drv:' Escape
    wait_for 'screen | grep -q NAV-EXITED' 100 || true
    wait_for 'grep -q "cannot read" "$LOG" 2>/dev/null' 50 || true
    if grep -q 'INTERDIMUX_DUMP_IN: cannot read' "$LOG" 2>/dev/null; then
      report "a ^r reload that fails reaches errors.log" pass
    else
      report "a ^r reload that fails reaches errors.log" fail
      ERRORS+="    log: $( (cat "$LOG" 2>/dev/null || true) | head -3 | tr '\n' '|')"$'\n'
    fi
    if grep -q 'interdimux: interdimux: INTERDIMUX_DUMP_IN: cannot read' <<< "$(msgs)"; then
      report "...and is announced on the status line" pass
    else
      report "...and is announced on the status line" fail
    fi
  else
    report "the navigator draws its first frame from the dump" fail
    ERRORS+="    screen: $(screen | grep -v '^ *$' | head -3 | tr '\n' '|')"$'\n'
  fi
  tmux -L "$OUTER" kill-server 2>/dev/null || true
fi

# --- the navigator with a stand-in fzf --------------------------------------------------
# Each stand-in answers --version like a real fzf, and otherwise does one thing
# that a real fzf does when it fails.
stub_fzf() { # $1 = name, $2 = the body run in place of fzf
  mkdir -p "$TMPD/$1"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo "0.74.0 (stub)"; exit 0 ;; esac\ncat >/dev/null\n%s\n' \
    "$2" > "$TMPD/$1/fzf"
  chmod +x "$TMPD/$1/fzf"
}
run_nav() { # $1 = the stand-in's name
  rm -f "$LOG"
  PATH="$TMPD/$1:$PATH" timeout 20 bash "$SCRIPT" </dev/null >/dev/null 2>&1 || true
}

# BUG-104: the error's first line is blank.  Exit 130, which is Esc, so nothing
# but the text itself can make the report.
stub_fzf blankfirst "printf '\\n\\nimux-test: an error after blank lines\\n' >&2; exit 130"
run_nav blankfirst
if grep -q 'imux-test: an error after blank lines' "$LOG" 2>/dev/null; then
  report "an error that starts with a blank line still reaches errors.log" pass
else
  report "an error that starts with a blank line still reaches errors.log" fail
fi
if grep -q 'interdimux: imux-test: an error after blank lines' <<< "$(msgs)"; then
  report "...and its first real line is the status-line message" pass
else
  report "...and its first real line is the status-line message" fail
fi

# BUG-106: fzf failing says nothing itself -- an exit 2, or killed outright.
stub_fzf exit2 'exit 2'
run_nav exit2
if grep -q '^fzf exited with status 2$' "$LOG" 2>/dev/null; then
  report "fzf exiting 2 is logged with its status" pass
else
  report "fzf exiting 2 is logged with its status" fail
  ERRORS+="    log: $( (cat "$LOG" 2>/dev/null || true) | tr '\n' '|')"$'\n'
fi
if grep -q 'interdimux: fzf exited with status 2' <<< "$(msgs)"; then
  report "...and announced on the status line" pass
else
  report "...and announced on the status line" fail
fi
stub_fzf killed 'kill -9 $$'
run_nav killed
if grep -q '^fzf exited with status 137$' "$LOG" 2>/dev/null; then
  report "fzf killed by a signal is logged with its status" pass
else
  report "fzf killed by a signal is logged with its status" fail
fi
# ...and the ordinary exits stay silent: Esc (130), and a query that matched
# nothing (1) with no query to create from
for st in 130 1 0; do
  stub_fzf "rc$st" "exit $st"
  run_nav "rc$st"
  if [ ! -e "$LOG" ]; then
    report "fzf exiting $st logs nothing" pass
  else
    report "fzf exiting $st logs nothing" fail
    ERRORS+="    log: $(tr '\n' '|' < "$LOG")"$'\n'
  fi
done

# A reload's error and then the navigator's own, in one file: the navigator's
# line must not land on top of the child's.  The real fzf, killed once ^r has
# failed; it is found by the dump path in its environment.  Linux only.
if [ "${fzf_minor:-0}" -ge 53 ] && [ -r "/proc/$$/environ" ] && command -v pgrep >/dev/null 2>&1; then
  cp "$SCRIPT_DIR/rust/tests/corpus/basic.dump" "$TMPD/nav2.dump"
  rm -f "$LOG"
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 120 -y 30 \
    "env TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' XDG_STATE_HOME='$XDG_STATE_HOME' \
         XDG_DATA_HOME='$XDG_DATA_HOME' INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=$fzf_minor \
         INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_DUMP_IN='$TMPD/nav2.dump' \
         bash '$SCRIPT'; echo NAV-EXITED; sleep 30"
  screen() { tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null || true; }
  nav_fzf() {
    local p
    for p in $(pgrep -x fzf || true); do
      tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qxF "INTERDIMUX_DUMP_IN=$TMPD/nav2.dump" \
        && printf '%s\n' "$p"
    done
    return 0
  }
  if wait_for 'screen | grep -q bravo' 150; then
    rm -f "$TMPD/nav2.dump"
    tmux -L "$OUTER" send-keys -t '=drv:' C-r
    wait_for '! screen | grep -q bravo' 100 || true
    for p in $(nav_fzf); do kill -9 "$p" 2>/dev/null || true; done
    wait_for 'screen | grep -q NAV-EXITED' 100 || true
    wait_for 'grep -q "status 137" "$LOG" 2>/dev/null' 50 || true
    if grep -q 'INTERDIMUX_DUMP_IN: cannot read' "$LOG" 2>/dev/null \
       && grep -q '^fzf exited with status 137$' "$LOG" 2>/dev/null; then
      report "a reload's error and then fzf's death are both logged intact" pass
    else
      report "a reload's error and then fzf's death are both logged intact" fail
      ERRORS+="    log: $( (cat "$LOG" 2>/dev/null || true) | head -4 | tr '\n' '|')"$'\n'
    fi
  else
    report "the navigator draws its first frame from the dump (2)" fail
  fi
  tmux -L "$OUTER" kill-server 2>/dev/null || true
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
