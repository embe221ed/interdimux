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
# The session rule is a second layout regime: it moves the meta into the command
# column when there is one, and switches itself off when the squeeze runs out of
# room.  Both renderers have to agree about WHICH regime they are in.
run_case "session rule off"             INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SESSION_RULE=off
run_case "custom palette (hex)"         INTERDIMUX_SHOW_DIRS=off INTERDIMUX_COLOR_ACCENT='#e78a4e' INTERDIMUX_COLOR_PATH='#d8a657'
run_case "palette inherit (-1)"         INTERDIMUX_SHOW_DIRS=off INTERDIMUX_COLOR_ACCENT=-1 INTERDIMUX_COLOR_TREE=default

# widths are the most output-sensitive input: sweep the popup geometry
# 40/44/52 sit BELOW the width where the squeeze still fits a command column,
# which is exactly where the session rule turns itself off — the regime boundary
# is the interesting place for two renderers to disagree.
for cols in 40 44 52 60 80 100 120 160 200 260; do
  run_case "width ${cols} cols" INTERDIMUX_SHOW_DIRS=off FZF_COLUMNS="$cols"
done
for cols in 80 120 200; do
  run_case "width ${cols} cols + preview" INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_PREVIEW=on FZF_COLUMNS="$cols"
done

# --- locale: neither renderer may depend on it ---------------------------------
#
# This suite was developed under C.UTF-8 and passed 30/30 there while failing
# 20/30 on an ordinary desktop, which is as close to useless as a parity suite
# gets.  The cause: the MRU key is `session_last_attached`, which has one-second
# resolution, so ties are routine — and GNU sort breaks a tie with its
# "last-resort comparison", which compares the WHOLE LINE under the user's
# collation.  The Rust core sorts stably and keeps tmux's order.  glibc's en_US
# ignores punctuation at the first collation level, so `has space` and
# `has"quote` compare as `hasspace` vs `hasquote` and swap; under C.UTF-8 they
# do not.  Both of those names are in the bench above, which is why it showed up
# at all.
#
# The locale is chosen by PROBING for the property that matters — a collation
# that differs from C's — rather than by parsing `locale -a`, whose spelling
# varies (`en_US.utf8` vs `en_US.UTF-8`) and whose presence does not imply the
# collation is actually different.
collation_differs() { # $1 = locale name
  local c alt
  c=$(printf 'has space\nhas"quote\n' | LC_ALL=C sort 2>/dev/null | head -1)
  alt=$(printf 'has space\nhas"quote\n' | LC_ALL="$1" sort 2>/dev/null | head -1)
  [ -n "$alt" ] && [ "$c" != "$alt" ]
}
ALT_LOCALE=""
for _l in en_US.UTF-8 en_US.utf8 en_GB.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 C.UTF-8; do
  if collation_differs "$_l"; then ALT_LOCALE="$_l"; break; fi
done
# The BASELINE is probed too, not hardcoded.  `C.UTF-8` does not exist on macOS —
# setlocale falls back to `C` there, so a hardcoded baseline would silently be
# comparing something other than what it says it is.  Both members of the pair
# have to be locales this box actually has.
BASE_LOCALE=C
for _l in C.UTF-8 C.utf8; do
  if [ "$(LC_ALL="$_l" locale charmap 2>/dev/null)" = "UTF-8" ]; then BASE_LOCALE="$_l"; break; fi
done

# The `-s` itself, asserted structurally and unconditionally.  Everything below
# needs a second locale to exist, and on a musl or C-only box none does — which
# would silently take the whole regression suite for this fix with it (measured:
# 31 assertions instead of 36, exit 0, with the `-s` also removed).  This one
# assertion cannot be skipped, and it covers BOTH sort sites — the kill-fallback
# MRU hop is not reachable from any case below.
unstable=$(grep -n "sort .*-k1,1nr" "$SCRIPT" | grep -v 'sort -s' || true)
if [ -z "$unstable" ]; then
  report "every MRU sort is stable (-s), including the kill-fallback hop" pass
else
  report "every MRU sort is stable (-s), including the kill-fallback hop" fail
  ERRORS+="$(printf '%s\n' "$unstable" | sed 's/^/     /')"$'\n'
fi

if [ -z "$ALT_LOCALE" ]; then
  # An echo, not a passing assertion: a skip dressed as a ✓ is how a suite comes
  # to report success for work it did not do.
  echo "  (skipped the locale cases: no installed locale collates differently from C)"
else
  report "comparing $BASE_LOCALE against $ALT_LOCALE, whose collation differs" pass

  # The direct regression: the two renderers must still agree under it.
  run_case "collation locale ($ALT_LOCALE)"          INTERDIMUX_SHOW_DIRS=off LC_ALL="$ALT_LOCALE"
  run_case "collation locale + dir rows"             INTERDIMUX_SHOW_DIRS=on INTERDIMUX_USE_ZOXIDE=off LC_ALL="$ALT_LOCALE"
  run_case "collation locale, index ordering"        INTERDIMUX_SHOW_DIRS=off INTERDIMUX_ORDER=index LC_ALL="$ALT_LOCALE"

  # ...and the stronger statement, which is the one that would have caught this
  # even with a single renderer: the OUTPUT itself must not move with the
  # locale.  Checked for each renderer separately, so a divergence names which.
  # The clock is PINNED across the pair.  Unlike run_case, this comparison has no
  # bash-vs-bash control to notice churn, and the rows carry age_of's token, which
  # flips at 90 s and then every 60 s — so a boundary landing between the two
  # renders would be reported as a locale failure.  INTERDIMUX_NOW is the seam the
  # renderer already exposes for exactly this (see the comment above age_of).
  _pin=$(date +%s)
  for _r in "rust:" "bash:INTERDIMUX_USE_RUST=off"; do
    _label="${_r%%:*}"; _env="${_r#*:}"
    _c="$TMPD/loc_c" _a="$TMPD/loc_alt"
    # shellcheck disable=SC2086
    env $_env INTERDIMUX_SHOW_DIRS=off INTERDIMUX_NOW="$_pin" LC_ALL="$BASE_LOCALE" bash "$SCRIPT" --list > "$_c" 2>/dev/null || true
    # shellcheck disable=SC2086
    env $_env INTERDIMUX_SHOW_DIRS=off INTERDIMUX_NOW="$_pin" LC_ALL="$ALT_LOCALE" bash "$SCRIPT" --list > "$_a" 2>/dev/null || true
    if [ ! -s "$_c" ]; then
      report "the $_label renderer produced rows to compare across locales" fail
    elif cmp -s "$_c" "$_a"; then
      report "the $_label renderer renders identically under $BASE_LOCALE and $ALT_LOCALE" pass
    else
      report "the $_label renderer renders identically under $BASE_LOCALE and $ALT_LOCALE" fail
      ERRORS+="$(diff <(sed 's/\x1b\[[0-9;]*m//g' "$_c") <(sed 's/\x1b\[[0-9;]*m//g' "$_a") | head -6 || true)"$'\n'
    fi
  done
fi

# The directory PICKER's tiers are still locale-collated (`sort -u` in
# emit_sorted_tiers) and deliberately so: that list has no second
# implementation to disagree with, and sorting a user's directory names by their
# own collation is the behaviour they want.  Only the tmux tree is pinned.

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
