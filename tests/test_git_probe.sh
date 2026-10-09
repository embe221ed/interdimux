#!/usr/bin/env bash
#
# The bash renderer looks for git branches only where the answer can matter.
#
# Whether ANY row has a branch decides one thing in the squeeze: whether the
# path gives up cells (down to PATH_KEEP) to keep the git badge.  measure_widths
# used to find out up front, at every width -- walking each window's and pane's
# cwd up to / until one had a branch, which on a tree with none is every
# directory of every path -- although at most widths the badge either fits or
# goes whatever the answer.  At an 80-column popup it can never matter (the
# identity column alone is too wide), and main had never probed git there at
# all.  The walk now runs only when the squeeze would keep the badge for a
# branch.  (review #11)
#
# What is observed is a read: the pane sits in a git worktree, whose `.git` is a
# FILE the walk has to open, with its access time set days back so the kernel
# (relatime) records the next read.  A control at a width where the badge is
# drawn proves the read is visible here; where it is not (noatime), the case
# is skipped rather than passed.  The layout itself must not move: the rows
# are compared with the Rust core's, which answers the same question its own
# way, at widths either side of where the answer counts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-gitprobe-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-gitprobe.XXXXXX")"
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

wait_for() { # $1 = description, $2.. = a command that must succeed
  local desc="$1"; shift
  local i
  for i in $(seq 1 150); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "  (timed out waiting for: $desc)" >&2
  return 1
}

echo "interdimux git-probe tests (bash renderer)"
echo

export LC_ALL=C.UTF-8 LANG=C.UTF-8

# --- bench: one window, in a worktree of a repository on branch `feat` --------
# A long session and window name, so the identity column alone leaves no room
# for the badge at 80 columns: there, it goes whether or not a row has a branch.
H="$TMPD/home"
LONG="$H/some/deeper/path/for/the/long/column"   # ~40 cells: it can shrink for a badge
mkdir -p "$H/repo.git" "$H/wt" "$H/plain" "$LONG" "$TMPD/data"
printf 'ref: refs/heads/feat\n' > "$H/repo.git/HEAD"
printf 'gitdir: %s\n' "$H/repo.git" > "$H/wt/.git"
GITFILE="$H/wt/.git"

PANECMD='sleep 99999'
tmux -f /dev/null -L "$SOCK" new-session -d -s a-rather-long-session-name \
  -n a-very-long-window-name-for-the-squeeze -x 200 -y 50 -c "$H/wt" "$PANECMD"
tmux -L "$SOCK" new-window -d -t '=a-rather-long-session-name:' -n plain -c "$H/plain" "$PANECMD"
tmux -L "$SOCK" new-window -d -t '=a-rather-long-session-name:' -n long -c "$LONG" "$PANECMD"
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=a-rather-long-session-name:0' -F '#{pane_id}' | head -1)"
export HOME="$H" XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_SHOW_DIRS=off INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_GIT_BRANCH=on
export INTERDIMUX_SHOW_PREVIEW=off INTERDIMUX_NOW="$(date +%s)"
wait_for "the panes' cwds" sh -c "tmux -L '$SOCK' list-panes -a -F '#{pane_current_path}' | grep -qx '$LONG'"

list() { # $1 = on|off (the Rust core), $2 = FZF_COLUMNS
  INTERDIMUX_USE_RUST="$1" FZF_COLUMNS="$2" bash "$SCRIPT" --list 2>/dev/null
}
atime() { stat -c %X "$1" 2>/dev/null || stat -f %a "$1"; }
# field 2 (the context column) of the row whose spec is $2
ctx_of() { printf '%s\n' "$1" | awk -F'\t' -v s="$2" '$4 == s { print $2 }'; }
age() { touch -a -d '-3 days' "$1" 2>/dev/null || touch -a -t "$(date -v-3d +%Y%m%d%H%M 2>/dev/null)" "$1"; }

# --- 1. at 80 columns the branch is never looked for -----------------------------
age "$GITFILE"; before=$(atime "$GITFILE")
out80=$(list off 80)
after80=$(atime "$GITFILE")
case "$out80" in
  *'‹'*) report "precondition: no badge fits at 80 columns" fail ;;
  *W:a-rather-long-session-name:0*) report "precondition: no badge fits at 80 columns" pass ;;
  *) report "precondition: the list rendered at 80 columns (got: $out80)" fail ;;
esac

# control: where the badge IS drawn, the renderer reads that very file
age "$GITFILE"; before200=$(atime "$GITFILE")
out200=$(list off 200)
after200=$(atime "$GITFILE")
case "$out200" in
  *'‹feat›'*) report "control: at 200 columns the worktree's branch is drawn" pass ;;
  *) report "control: at 200 columns the worktree's branch is drawn (got: $out200)" fail ;;
esac
if [ "$after200" = "$before200" ]; then
  echo "  (skipped: reads do not update access times on this filesystem)"
elif [ "$after80" = "$before" ]; then
  report "at 80 columns the worktree's .git is never read" pass
else
  report "at 80 columns the worktree's .git is never read" fail
  ERRORS+="     access time moved from $before to $after80"$'\n'
fi

# --- 2. the rows are what they were: the Rust core draws the same ---------------
# Somewhere in 100..160 the long path can give up cells to keep the badge, and
# only there does the answer change the layout; the Rust core still asks the
# question up front, as bash did.  The sweep has to cross that band, or it
# would pass with the question never asked: the control is that it contains
# both a width where the long path is cut to keep a badge and one where the
# badge is gone.
if [ -x "$BIN" ]; then
  bad="" kept=0 dropped=0
  for w in 40 60 80 $(seq 100 3 160) 200; do
    b=$(list off "$w"); r=$(list on "$w")
    [ -n "$b" ] && [ "$b" = "$r" ] || bad+=" $w"
    # the worktree window's badge, and the long window's path column
    badge=$(ctx_of "$b" 'W:a-rather-long-session-name:0')
    path=$(ctx_of "$b" 'W:a-rather-long-session-name:2')
    case "$badge" in
      *'‹feat›'*) case "$path" in *'…'*) kept=1 ;; esac ;;   # the path cut for it
      *) dropped=1 ;;
    esac
  done
  if [ "$kept" = 1 ] && [ "$dropped" = 1 ]; then
    report "control: the sweep crosses the widths where a branch decides the layout" pass
  else
    report "control: the sweep crosses the widths where a branch decides the layout (kept=$kept dropped=$dropped)" fail
  fi
  [ -z "$bad" ] && report "bash and the Rust core render the same rows at every width" pass \
                || report "bash and the Rust core render the same rows at every width (differ at:$bad)" fail
else
  echo "  (skipped the comparison: $BIN not built)"
fi

# --- 3. each directory is asked for a .git once per list ---------------------
# Eight windows of one session in sibling directories, no repository anywhere
# below $H/w.  Every cwd's walk passes through $H/w, $H, ... and /; a walk that
# reaches a directory an earlier one went through takes its answer, so $H/w's
# .git is looked up once (a stat for -d and one for -f) however many cwds sit
# under it -- not eight times (review BUG-108).  At 95 columns the
# 16-character session name, the 8-cell window floor and the 31-cell path leave
# the path just enough to give up for the 16-cell badge, so the squeeze asks
# whether any row has a branch: the walk that, on a tree with no branch at all,
# used to cost a full walk per cwd.  (At 94 the badge is one cell short and
# goes without asking.)  At 200 columns the badge is drawn and every row asks
# for its own branch.  The control is that $H/w's .git is looked up at all.
if ! command -v strace >/dev/null 2>&1 || ! strace -f -qq -o /dev/null true 2>/dev/null; then
  echo "  (skipped the lookup count: needs strace, and permission to trace a child)"
else
  US=$'\x1f' RS=$'\x1e'
  {
    printf 'infra-deploy-s01%s1700000000%s8%s%s%s\n' "$US" "$US" "$US" "$US" "$H/w"
    printf '%s\n' "$RS"
    for w in 0 1 2 3 4 5 6 7; do
      mkdir -p "$H/w/s1/abcdefghijklmnopqrs/win$w"
      printf 'infra-deploy-s01%s%s%swin%s%s%s%szsh%s%s%s1%s0%s000\n' "$US" "$w" "$US" "$w" "$US" \
        "$([ "$w" = 0 ] && echo 1 || echo 0)" "$US" "$US" "$H/w/s1/abcdefghijklmnopqrs/win$w" "$US" "$US" "$US"
    done
    printf '%s\n%s\n' "$RS" "$RS"
    printf 'infra-deploy-s01%s0%s0\n' "$US" "$US"
    printf '%s\n' "$RS"
  } > "$TMPD/tree.dump"
  for w in 95 200; do
    INTERDIMUX_DUMP_IN="$TMPD/tree.dump" INTERDIMUX_USE_RUST=off FZF_COLUMNS="$w" \
      strace -f -qq -e trace=%file -o "$TMPD/trace.$w" bash "$SCRIPT" --list > "$TMPD/rows.$w" 2>/dev/null || true
    rows=$(grep -c 'W:infra-deploy-s01:' "$TMPD/rows.$w" || true)
    looks=$(grep -cF "\"$H/w/.git\"" "$TMPD/trace.$w" || true)
    if [ "$rows" = 8 ] && [ "$looks" -ge 1 ] && [ "$looks" -le 2 ]; then
      report "at $w columns, eight cwds under one directory look up its .git once" pass
    else
      report "at $w columns, eight cwds under one directory look up its .git once (rows=$rows lookups=$looks)" fail
    fi
  done
  # The Rust core walks the same way, with one stat for both tests: a
  # directory's .git is looked up once per list (it was twice per cwd, 16).
  if [ -x "$BIN" ]; then
    INTERDIMUX_DUMP_IN="$TMPD/tree.dump" INTERDIMUX_USE_RUST=on INTERDIMUX_BIN="$BIN" FZF_COLUMNS=200 \
      strace -f -qq -e trace=%file -o "$TMPD/trace.rust" bash "$SCRIPT" --list > "$TMPD/rows.rust" 2>/dev/null || true
    rows=$(grep -c 'W:infra-deploy-s01:' "$TMPD/rows.rust" || true)
    looks=$(grep -cF "\"$H/w/.git\"" "$TMPD/trace.rust" || true)
    rust=$(grep -c 'execve(".*imux"' "$TMPD/trace.rust" || true)
    if [ "$rows" = 8 ] && [ "$rust" -ge 1 ] && [ "$looks" = 1 ]; then
      report "the Rust core: eight cwds under one directory stat its .git once" pass
    else
      report "the Rust core: eight cwds under one directory stat its .git once (rows=$rows core=$rust lookups=$looks)" fail
    fi
  else
    echo "  (skipped the Rust core's lookup count: $BIN not built)"
  fi
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
