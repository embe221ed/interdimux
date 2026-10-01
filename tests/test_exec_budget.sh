#!/usr/bin/env bash
#
# What the navigator and the callbacks fzf runs while you type and move
# EXECUTE, counted -- the budget a change to them has to justify (review
# TEST-33).  A 15-35% slowdown went unnoticed across 49 merges because nothing
# counted: one was an `rm` exec added before the first frame, the rest a fork
# here and a tmux client there, each too small to see by hand.
#
# Two counters, neither of them a clock, so a loaded machine cannot move them:
#
#   * the commands it runs.  PATH is a directory of shims and nothing else:
#     each logs its name and execs the real tool, so every exec is counted, and
#     a tool the script needs that the list below lacks fails loudly (each case
#     also checks that stderr stayed empty).  fzf is a stand-in that logs FZF,
#     drains the list and cancels; zoxide one that logs and offers nothing;
#     there is no fd, so the directory finder is find everywhere.
#   * bash's own forks.  BASH_ENV turns on xtrace into a file, with $BASHPID
#     in PS4, so every subshell, command substitution and pipeline member that
#     runs a line of the script shows up under a pid of its own; the count is
#     the number of distinct pids (the script itself is one).  Measured equal
#     on bash 4.3, 4.4, 5.0, 5.1 and 5.2.  The two sides of a pipeline trace
#     at once, and a long line goes out in more than one write(2), so another
#     process's line can land inside it: the trace is opened for APPEND (or
#     it lands ON it), and a pid is counted wherever its mark is, not only at
#     the start of a line (1 run in ~50 lost one otherwise).
#
# COUNTS, not order: in the bash renderer `sort` runs on the left of the
# pipeline at the moment fzf is exec'd on the right.
#
# The numbers are budgets.  A change that needs one more exec or fork on these
# paths raises the number here, in the same commit, and says why.
#
# Each run gets the popup's environment (options primed, versions pinned) and
# no controlling terminal (setsid), so term_cols has no tty to `stty`: under a
# real popup that is one exec, memoised, before the first frame.  A callback
# also gets the FZF_* sizes fzf exports to its children.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-execbudget-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-execbudget.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

SOCK_PATH=""
# kill-server leaves the socket file behind (tmux 3.7b): remove it by name
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -f ${SOCK_PATH:+"$SOCK_PATH"}; rm -rf "$TMPD"; }
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

echo "interdimux exec-budget tests"
echo

SETSID=$(command -v setsid || true)
if [ -z "$SETSID" ] || ! "$SETSID" -w true 2>/dev/null; then
  echo "  (skipped: needs util-linux setsid -w, to run without a controlling terminal)"
  echo
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

REALBASH=$(command -v bash)
LOG="$TMPD/log"
SHIMS="$TMPD/shims"
mkdir -p "$SHIMS" "$TMPD/home" "$TMPD/run" "$TMPD/data"
chmod 700 "$TMPD/run"

# Every external tool the script may run on these paths (and a few more, so
# that a new use is counted rather than "not found").  Not fd or fdfind.
for t in tmux sort sed head tail tr wc cat rm mkdir mktemp mv cp ln touch chmod \
         date stty ps uname id basename dirname readlink grep awk cut find git \
         timeout ls sleep env sh bash; do
  p=$(command -v "$t" 2>/dev/null) || continue
  case "$p" in /*) ;; *) continue ;; esac
  printf '#!/bin/sh\necho %s >> "%s"\nexec "%s" "$@"\n' "$t" "$LOG" "$p" > "$SHIMS/$t"
  chmod +x "$SHIMS/$t"
done
printf '#!/bin/sh\necho zoxide >> "%s"\nexit 0\n' "$LOG" > "$SHIMS/zoxide"
cat > "$SHIMS/fzf" <<FZF
#!$REALBASH
case " \$* " in *" --version "*) echo "0.74.3 (stub)"; exit 0 ;; esac
echo FZF >> "$LOG"
while IFS= read -r _; do :; done
exit 130
FZF
chmod +x "$SHIMS/zoxide" "$SHIMS/fzf"
printf 'BASH_XTRACEFD=19\nPS4=%s\nset -x\n' "'+@\${BASHPID}@ '" > "$TMPD/xtrace.rc"

# A small server: a session of three windows (one split), and another.
PC='exec sleep 900'
tmux -f /dev/null -L "$SOCK" new-session -d -s alpha -x 120 -y 30 -c "$TMPD/home" "$PC"
tmux -L "$SOCK" set -g automatic-rename off
tmux -L "$SOCK" new-window -d -t '=alpha:' -n two -c "$TMPD/home" "$PC"
tmux -L "$SOCK" split-window -d -t '=alpha:1' -c "$TMPD/home" "$PC"
tmux -L "$SOCK" new-window -d -t '=alpha:' -n three -c "$TMPD/home" "$PC"
tmux -L "$SOCK" new-session -d -s bravo -x 120 -y 30 -c "$TMPD/home" "$PC"
settled() {
  local l
  while IFS= read -r l; do [ "$l" = "cwd sleep" ] || return 1; done \
    < <(tmux -L "$SOCK" list-panes -a -F '#{?pane_current_path,cwd,nocwd} #{pane_current_command}' 2>/dev/null)
}
for _ in $(seq 1 100); do settled && break; sleep 0.1; done
SOCK_PATH="$(tmux -L "$SOCK" display-message -p '#{socket_path}')"
PANE="$(tmux -L "$SOCK" list-panes -t '=alpha:0' -F '#{pane_id}')"

# run RENDERER [VAR=value ...] -- ARGS: the script with ARGS, as the popup
# (no ARGS) or fzf would start it.  Sets TOOLS ("name=count ..." by name) and
# FORKS.
run() {
  local r="$1"; shift
  local -a extra=()
  while [ "$1" != -- ]; do extra+=("$1"); shift; done
  shift
  [ $# -gt 0 ] && extra=(FZF_COLUMNS=120 FZF_LINES=35 FZF_PREVIEW_COLUMNS=60 FZF_PREVIEW_LINES=30 ${extra[@]+"${extra[@]}"})
  : > "$LOG"; : > "$TMPD/trace"
  env -i HOME="$TMPD/home" XDG_RUNTIME_DIR="$TMPD/run" XDG_DATA_HOME="$TMPD/data" \
      PATH="$SHIMS" LANG=C.UTF-8 LC_ALL=C.UTF-8 BASH_ENV="$TMPD/xtrace.rc" \
      TMUX="$SOCK_PATH,99999,0" TMUX_PANE="$PANE" INTERDIMUX_OPTS_PRIMED=1 \
      INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_USE_RUST="$r" \
      ${extra[@]+"${extra[@]}"} \
      "$SETSID" -w "$REALBASH" "$SCRIPT" "$@" \
      < /dev/null > "$TMPD/out" 2> "$TMPD/err" 19>> "$TMPD/trace" || true
  TOOLS=$(LC_ALL=C sort "$LOG" | uniq -c | awk '{ printf "%s%s=%s", (NR > 1 ? " " : ""), $2, $1 }')
  FORKS=$(grep -aoE '\+@[0-9]+@ ' "$TMPD/trace" | grep -oE '[0-9]+' | LC_ALL=C sort -u | wc -l | tr -d ' ')
}

# check NAME WANT_TOOLS WANT_FORKS: the counts of the run just made
check() {
  local name="$1" want_tools="$2" want_forks="$3"
  if [ -s "$TMPD/err" ]; then
    report "$name: ran clean (stderr: $(head -c 200 "$TMPD/err" | tr '\n' ' '))" fail
    return
  fi
  if [ "$TOOLS" = "$want_tools" ]; then
    report "$name: runs ${want_tools:-nothing}" pass
  else
    report "$name: runs ${want_tools:-nothing} (got: ${TOOLS:-nothing})" fail
  fi
  if [ "$FORKS" = "$want_forks" ]; then
    report "$name: $want_forks bash process(es)" pass
  else
    report "$name: $want_forks bash process(es) (got $FORKS)" fail
  fi
}

renderers=(off); [ -x "$BIN" ] && renderers=(on off)
[ -x "$BIN" ] || echo "  (rust binary not built: bash renderer only)"

# --- the navigator: open, first list, cancel --------------------------------
for r in "${renderers[@]}"; do
  if [ "$r" = on ]; then
    label="Rust core"
    # the gather's one tmux query, the core's zoxide, the EXIT trap's rm, and
    # an rm of the core's mount-table file before fzf starts
    want="FZF=1 rm=2 tmux=1 zoxide=1" forks=8
  else
    label="bash renderer"
    # ...and the MRU sort
    want="FZF=1 rm=1 sort=1 tmux=1 zoxide=1" forks=10
  fi
  run "$r" -- ; check "navigator ($label)" "$want" "$forks"
done

# --- --list: every reload ----------------------------------------------------
# One tmux client for the whole gather (this was strace's job in
# test_gather_batch.sh, which CI could skip).
for r in "${renderers[@]}"; do
  if [ "$r" = on ]; then
    run on -- --list;  check "--list (Rust core)" "tmux=1 zoxide=1" 5
  else
    run off -- --list; check "--list (bash renderer)" "sort=1 tmux=1 zoxide=1" 7
  fi
done

# --- the callbacks fzf runs on every cursor move and keystroke ---------------
run on -- --preview 'S:alpha';     check "--preview of a session" "tmux=3" 12
run on -- --preview 'W:alpha:1';   check "--preview of a window" "tmux=2" 4
run on -- --preview 'P:alpha:1:1'; check "--preview of a pane" "tmux=2" 4
run on FZF_QUERY=api FZF_MATCH_COUNT=3 -- --footer-for 'W:alpha:1'
check "--footer-for, a query with matches" "tmux=1" 2
run on FZF_QUERY=newproj FZF_MATCH_COUNT=0 -- --footer-for 'W:alpha:1'
check "--footer-for, a query with none" "head=1 tmux=1 zoxide=1" 4
run on -- --describe-create newproj
check "--describe-create" "head=1 tmux=1 zoxide=1" 4
run on FZF_NTH=1 -- --scope-prompt
check "--scope-prompt" "" 1

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
