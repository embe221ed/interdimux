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
OUTER="${SOCK}-o0" OUTER_N=0   # a new outer server per launch: see new_outer
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-errlog.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  local i
  for (( i = 0; i <= OUTER_N; i++ )); do tmux -L "${SOCK}-o$i" kill-server 2>/dev/null || true; done
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  # the socket files too: tmux leaves them behind after kill-server
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"
  for (( i = 0; i <= OUTER_N; i++ )); do rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/${SOCK}-o$i"; done
  rm -rf "$TMPD"
}
trap cleanup EXIT

# Each launch gets a NEW outer server rather than killing one and re-creating
# it on the same socket: kill-server returns while the old server is still
# exiting, its socket still open, and a new-session that connects then fails
# with "server exited unexpectedly" (or lands in the dying server and vanishes
# with it).
new_outer() {
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  OUTER_N=$((OUTER_N + 1)); OUTER="${SOCK}-o$OUTER_N"
}

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
else
  echo "  (skipped which stderr each mode runs with: needs /proc/<pid>/fd and readlink)"
fi

# --- end to end: a reload that fails is reported when the navigator exits ------------
# The list comes from a dump (INTERDIMUX_DUMP_IN), which every child inherits, so
# deleting it makes exactly the reloads fail: the first frame renders, ^r then
# runs a --list that cannot read it.
fzf_minor=$(fzf --version 2>/dev/null | awk '{print $1}' | cut -d. -f2)
if [ "${fzf_minor:-0}" -ge 53 ]; then
  cp "$SCRIPT_DIR/rust/tests/corpus/basic.dump" "$TMPD/nav.dump"
  rm -f "$LOG"
  new_outer
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
    # once: the mode's message already starts "interdimux: ", and the status
    # line's prefix is not added to it a second time
    m=$(msgs)
    if grep -q 'interdimux: INTERDIMUX_DUMP_IN: cannot read' <<< "$m" \
       && ! grep -q 'interdimux: interdimux:' <<< "$m"; then
      report "...and is announced on the status line, named once" pass
    else
      report "...and is announced on the status line, named once" fail
      ERRORS+="    messages: $( (grep 'interdimux:' <<< "$m" || true) | head -3 | tr '\n' '|')"$'\n'
    fi
  else
    report "the navigator draws its first frame from the dump" fail
    ERRORS+="    screen: $(screen | grep -v '^ *$' | head -3 | tr '\n' '|')"$'\n'
  fi
  tmux -L "$OUTER" kill-server 2>/dev/null || true

  # ^o under an LC_ALL that names a locale that is not installed, as an ssh
  # session forwards one.  Every bash warns once as it starts, and the
  # directory picker's producer started with the navigator's error file as
  # its stderr: each ^o put the warning on the status line and in errors.log.
  # Nothing fails here, so nothing may be reported.
  cp "$SCRIPT_DIR/rust/tests/corpus/basic.dump" "$TMPD/nav.dump"
  mkdir -p "$TMPD/locproj/alpha" "$TMPD/locproj/beta"
  rm -f "$LOG"
  before=$(msgs | grep -c 'interdimux:' || true)
  new_outer
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 120 -y 30 \
    "env TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' XDG_STATE_HOME='$XDG_STATE_HOME' \
         XDG_DATA_HOME='$XDG_DATA_HOME' INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=$fzf_minor \
         INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_DUMP_IN='$TMPD/nav.dump' \
         INTERDIMUX_PROJECT_DIRS='$TMPD/locproj' LC_ALL=xx_XX.UTF-8 \
         bash '$SCRIPT' 2>/dev/null; echo NAV-EXITED; sleep 30"
  if wait_for 'screen | grep -q bravo' 150; then
    tmux -L "$OUTER" send-keys -t '=drv:' C-o
    if wait_for 'screen | grep -q "locproj/beta"' 100; then
      tmux -L "$OUTER" send-keys -t '=drv:' Escape
      wait_for 'screen | grep -q bravo' 100 || true
      tmux -L "$OUTER" send-keys -t '=drv:' Escape
      wait_for 'screen | grep -q NAV-EXITED' 100 || true
      if [ ! -e "$LOG" ] && [ "$(msgs | grep -c 'interdimux:' || true)" = "$before" ]; then
        report "^o under a missing LC_ALL reports nothing" pass
      else
        report "^o under a missing LC_ALL reports nothing" fail
        ERRORS+="    log: $( (cat "$LOG" 2>/dev/null || true) | head -3 | tr '\n' '|')"$'\n'
      fi
    else
      report "setup: ^o lists the project dirs under a missing LC_ALL" fail
      ERRORS+="    screen: $(screen | grep -v '^ *$' | head -3 | tr '\n' '|')"$'\n'
    fi
  else
    report "the navigator draws its first frame under a missing LC_ALL" fail
  fi
  tmux -L "$OUTER" kill-server 2>/dev/null || true
else
  echo "  (skipped the end-to-end reports: the navigator logs its errors from fzf 0.53 on)"
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
run_nav() { # $1 = the stand-in's name [, $2 = keep: append to the log as it is]
  [ "${2:-}" = keep ] || rm -f "$LOG"
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

# --- the log is capped when it is written (UX-17) -----------------------------------
# It only ever grew.  Past 64 KB the writer keeps the newest 50 entries, and of
# those only as many of the newest as fit in 32 KB, so that it does not trim
# again on every later error.
seed_log() { # $1 = entries, $2 = characters of text in each
  local i pad
  printf -v pad '%*s' "$2" ''; pad="${pad// /x}"
  mkdir -p "${LOG%/*}"
  for (( i = 1; i <= $1; i++ )); do
    printf '== 2026-01-01 00:00:00 navigator stderr\nseeded-%03d %s\n' "$i" "$pad"
  done > "$LOG"
}
seed_log 200 400          # ~88 KB, the newest 50 ~23 KB
run_nav exit2 keep
n=$(grep -c '^== ' "$LOG" 2>/dev/null || true)
if [ "$n" = 50 ] && ! grep -q '^seeded-151 ' "$LOG" && grep -q '^seeded-152 ' "$LOG"; then
  report "a log past 64 KB is cut to its newest 50 entries" pass
else
  report "a log past 64 KB is cut to its newest 50 entries (has $n)" fail
fi
if [ "$(tail -n 1 "$LOG")" = 'fzf exited with status 2' ]; then
  report "...the new one last" pass
else
  report "...the new one last" fail
fi
seed_log 60 1200          # ~74 KB, the newest 50 ~62 KB
run_nav exit2 keep
n=$(grep -c '^== ' "$LOG" 2>/dev/null || true)
size=$(wc -c < "$LOG")
if [ "$size" -le 32768 ] && [ "$n" -ge 20 ] && [ "$(tail -n 1 "$LOG")" = 'fzf exited with status 2' ] \
   && grep -q '^seeded-060 ' "$LOG"; then
  report "...or as many of the newest as fit in 32 KB" pass
else
  report "...or as many of the newest as fit in 32 KB (has $n, $size bytes)" fail
fi
run_nav exit2 keep
[ "$(grep -c '^== ' "$LOG" 2>/dev/null || true)" = $(( n + 1 )) ] \
  && report "...so the next error is appended, not trimmed again" pass \
  || report "...so the next error is appended, not trimmed again" fail
seed_log 60 10            # ~3 KB
run_nav exit2 keep
n=$(grep -c '^== ' "$LOG" 2>/dev/null || true)
[ "$n" = 61 ] \
  && report "a small log keeps every entry" pass \
  || report "a small log keeps every entry (has $n)" fail
rm -f "$LOG"

# A reload's error and then the navigator's own, in one file: the navigator's
# line must not land on top of the child's.  The real fzf, killed once ^r has
# failed; it is found by the dump path in its environment.  Linux only.
if [ "${fzf_minor:-0}" -ge 53 ] && [ -r "/proc/$$/environ" ] && command -v pgrep >/dev/null 2>&1; then
  cp "$SCRIPT_DIR/rust/tests/corpus/basic.dump" "$TMPD/nav2.dump"
  rm -f "$LOG"
  new_outer
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
else
  echo "  (skipped a reload's error then fzf's death: needs fzf >= 0.53, /proc/<pid>/environ and pgrep)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
