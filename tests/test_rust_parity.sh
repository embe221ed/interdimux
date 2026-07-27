#!/usr/bin/env bash
#
# The Rust core and the bash renderer must produce byte-identical rows.
#
# bash keeps its own renderer as the fallback for anyone without the binary, so
# the two implementations have to stay in step.  This sweeps the configuration
# space that changes the output — column widths, preview on/off, git badges,
# full-command resolution, MRU vs index ordering, directory rows — and diffs
# them, with a bash-vs-bash control on every case so a churning bench cannot
# produce a false pass.
#
# Skips cleanly when the binary has not been built.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-parity-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-parity.XXXXXX")"
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

echo "interdimux rust/bash parity tests"
echo

if [ ! -x "$BIN" ]; then
  echo "  (skipped: $BIN not built — run 'cargo build --release' in rust/)"
  echo
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# --- bench: mixed shapes, plus names and paths that have broken things before -
PANECMD='bash --norc --noprofile -c "sleep 99999 & wait"'
tmux -f /dev/null -L "$SOCK" new-session -d -s q01 -x 200 -y 50 -c "$SCRIPT_DIR" "$PANECMD"
for i in 02 03 04 05 06 07 08; do
  tmux -L "$SOCK" new-session -d -s "q$i" -x 200 -y 50 -c "$SCRIPT_DIR" "$PANECMD"
done
for i in 01 02 03 04 05 06 07 08; do
  tmux -L "$SOCK" new-window  -d -t "=q$i:" -c "$SCRIPT_DIR" "$PANECMD"
  tmux -L "$SOCK" split-window -d -t "=q$i:1" -c "$SCRIPT_DIR" "$PANECMD" 2>/dev/null || true
done
# shapes the uniform panes miss
tmux -L "$SOCK" new-window -d -t '=q01:' -n fg -c "$SCRIPT_DIR"
tmux -L "$SOCK" send-keys  -t '=q01:fg' 'sleep 900' Enter
tmux -L "$SOCK" new-window -d -t '=q01:' -n idle -c "$SCRIPT_DIR"
tmux -L "$SOCK" new-session -d -s 'has space'   -x 200 -y 50 -c "$SCRIPT_DIR" "$PANECMD"
tmux -L "$SOCK" new-session -d -s 'has"quote'   -x 200 -y 50 -c "$SCRIPT_DIR" "$PANECMD"
tmux -L "$SOCK" new-session -d -s 'a-very-long-session-name-that-will-be-truncated' \
     -x 200 -y 50 -c "$SCRIPT_DIR" "$PANECMD"
deep="$TMPD/a/very/deep/nested/directory/structure/for/path/trimming"
mkdir -p "$deep"
tmux -L "$SOCK" new-session -d -s deep -x 200 -y 50 -c "$deep" "$PANECMD"

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=q01:1' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export XDG_DATA_HOME="$TMPD/data"
mkdir -p "$XDG_DATA_HOME/interdimux"
mkdir -p "$TMPD/rustproj" && printf '[package]\n' > "$TMPD/rustproj/Cargo.toml"
mkdir -p "$TMPD/gitproj/.git" && printf 'ref: refs/heads/parity-branch\n' > "$TMPD/gitproj/.git/HEAD"
printf '%s\n%s\n' "$TMPD/rustproj" "$TMPD/gitproj" > "$XDG_DATA_HOME/interdimux/recent_dirs"
sleep 4

rows=$(INTERDIMUX_USE_RUST=off bash "$SCRIPT" --list 2>/dev/null | wc -l)
if [ "$rows" -ge 30 ]; then
  report "bench built ($rows rows)" pass
else
  report "bench built ($rows rows, expected >= 30)" fail
fi

# --- the sweep ----------------------------------------------------------------
# Each case: a label and the env that distinguishes it.
run_case() {
  local label="$1"; shift
  local b1="$TMPD/b1" b2="$TMPD/b2" r="$TMPD/r"
  env "$@" INTERDIMUX_USE_RUST=off bash "$SCRIPT" --list > "$b1" 2>/dev/null || true
  env "$@"                        bash "$SCRIPT" --list > "$r"  2>/dev/null || true
  env "$@" INTERDIMUX_USE_RUST=off bash "$SCRIPT" --list > "$b2" 2>/dev/null || true
  if ! cmp -s "$b1" "$b2"; then
    report "$label — CONTROL FAILED (bash vs bash differs; bench churning)" fail
    return
  fi
  if cmp -s "$b1" "$r"; then
    report "$label" pass
  else
    report "$label" fail
    ERRORS+="$(diff <(sed 's/\x1b\[[0-9;]*m//g' "$b1") <(sed 's/\x1b\[[0-9;]*m//g' "$r") | head -6 || true)"$'\n'
  fi
}

run_case "defaults"                     INTERDIMUX_SHOW_DIRS=off
run_case "full command resolution on"   INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_FULL_COMMAND=on
run_case "full command resolution off"  INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_FULL_COMMAND=off
# Force the ps backend on BOTH sides: rust's ps snapshot vs bash's ps table.
# On Linux this is the only case that exercises the ps backend (the default
# uses /proc); on macOS/BSD it is what every open runs.
run_case "full command via ps backend"  INTERDIMUX_SHOW_DIRS=off INTERDIMUX_FORCE_PS=1 INTERDIMUX_SHOW_FULL_COMMAND=on
run_case "git badges on"                INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_GIT_BRANCH=on
run_case "git badges off"               INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_GIT_BRANCH=off
run_case "preview on (half width)"      INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_PREVIEW=on
run_case "index ordering"               INTERDIMUX_SHOW_DIRS=off INTERDIMUX_ORDER=index
run_case "directory rows on"            INTERDIMUX_SHOW_DIRS=on INTERDIMUX_USE_ZOXIDE=off
run_case "directory rows + git"         INTERDIMUX_SHOW_DIRS=on INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_GIT_BRANCH=on
run_case "custom palette (hex)"         INTERDIMUX_SHOW_DIRS=off INTERDIMUX_COLOR_ACCENT='#e78a4e' INTERDIMUX_COLOR_PATH='#d8a657'
run_case "palette inherit (-1)"         INTERDIMUX_SHOW_DIRS=off INTERDIMUX_COLOR_ACCENT=-1 INTERDIMUX_COLOR_TREE=default

# widths are the most output-sensitive input: sweep the popup geometry
for cols in 60 80 100 120 160 200 260; do
  run_case "width ${cols} cols" INTERDIMUX_SHOW_DIRS=off FZF_COLUMNS="$cols"
done
for cols in 80 120 200; do
  run_case "width ${cols} cols + preview" INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_PREVIEW=on FZF_COLUMNS="$cols"
done

# --- failure modes: the binary must never turn into an empty picker ---------
broken="$TMPD/broken"; printf '#!/bin/sh\nexit 7\n' > "$broken"; chmod +x "$broken"
silent="$TMPD/silent"; printf '#!/bin/sh\nexit 0\n' > "$silent"; chmod +x "$silent"
want=$(INTERDIMUX_USE_RUST=off INTERDIMUX_SHOW_DIRS=off bash "$SCRIPT" --list 2>/dev/null | wc -l)
got_b=$(INTERDIMUX_BIN="$broken" INTERDIMUX_SHOW_DIRS=off bash "$SCRIPT" --list 2>/dev/null | wc -l)
got_s=$(INTERDIMUX_BIN="$silent" INTERDIMUX_SHOW_DIRS=off bash "$SCRIPT" --list 2>/dev/null | wc -l)
[ "$got_b" = "$want" ] && report "a failing binary falls back to bash ($got_b rows)" pass \
                       || report "a failing binary falls back to bash (got $got_b, want $want)" fail
[ "$got_s" = "$want" ] && report "a silent binary falls back to bash ($got_s rows)" pass \
                       || report "a silent binary falls back to bash (got $got_s, want $want)" fail

# A pane cwd is arbitrary bytes on Linux; invalid UTF-8 must degrade one path,
# not blank the whole list.
bad=$(printf 'a\x1fb\x1f1\x1f\n\x1e\n\x1e\n\x1e\n' | "$BIN" gather 2>/dev/null | wc -l)
badu=$(printf 'a\x1fb\x1f1\x1f\xff\xfe\n\x1e\n\x1e\n\x1e\n' | "$BIN" gather 2>/dev/null | wc -l)
[ "$badu" = "$bad" ] && report "invalid UTF-8 input still renders its row" pass \
                     || report "invalid UTF-8 input still renders its row (got $badu, want $bad)" fail

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
