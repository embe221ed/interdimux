#!/usr/bin/env bash
#
# tests/run_all.sh itself: a skip is reported as a skip, never as a pass.
#
# A suite that skipped itself whole ends "Results: 0 passed, 0 failed", and
# run_all.sh used to total that as a green tick.  Partial skips -- an old bash
# that is not there, zsh not installed -- left no trace in the total at all.
# That is how the bash-floor suite went unrun in CI, and how bash 4.4 and 5.0
# still were.  IMUX_STRICT=1, which CI sets, makes any skip fail the run.
#
# Run against a copy of run_all.sh in a tree of stand-in suites with known
# output, so every count here is written out rather than measured.  No tmux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-runall.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

echo "interdimux run_all tests"
echo

# --- the stand-in tree -------------------------------------------------------------
mkdir -p "$TMPD/tree/tests"
cp "$SCRIPT_DIR/tests/run_all.sh" "$TMPD/tree/tests/"
suite() { # $1 = name, then its output lines; the last argument is its exit status
  local f="$TMPD/tree/tests/test_$1.sh" rc
  shift
  rc="${*: -1}"
  {
    printf '#!/usr/bin/env bash\n'
    while [ $# -gt 1 ]; do printf 'printf "%%s\\n" %q\n' "$1"; shift; done
    printf 'exit %s\n' "$rc"
  } > "$f"
}
suite pass_one  '  ✓ one' '  ✓ two' '' 'Results: 2 passed, 0 failed' 0
suite skip_all  '  (skipped: needs fzf >= 0.74, found 44)' '' 'Results: 0 passed, 0 failed' 0
suite skip_some '  ✓ three' '  (skipped bash 4.4: not in $INTERDIMUX_OLD_BASH_DIR)' \
                '  - zsh -c (skipped: zsh is not installed)' \
                '  (the Rust core is not built: its half is skipped)' \
                '' 'Results: 3 passed, 0 failed' 0
suite fails     '  ✗ four' '' 'Results: 0 passed, 1 failed' 1

# $1.. = run_all.sh's arguments, with IMUX_STRICT=$STRICT when that is set (and
# never what this run inherited: CI sets it).  Sets RC and OUT, with colours
# stripped and every duration read as "Ns": durations are whole seconds of the
# wall clock, so not always 0 even for these.
run() {
  local -a e=(env -u IMUX_STRICT -u IMUX_RENDERER IMUX_SKIP_RUST=1)
  [ -z "$STRICT" ] || e+=(IMUX_STRICT="$STRICT")
  RC=0
  OUT=$(cd "$TMPD/tree" && "${e[@]}" bash tests/run_all.sh "$@" 2>&1) || RC=$?
  OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g; s/([0-9][0-9]*s)/(Ns)/; s/([0-9][0-9]*s total)/(Ns total)/')
}
has() { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }

# --- a whole skip and a partial one are reported, and do not fail by default ----------
STRICT="" run pass_one skip_all skip_some
[ "$RC" = 0 ] && report "skips alone do not fail a default run" pass \
              || report "skips alone do not fail a default run (exit $RC)" fail
has '  ○ SKIPPED (Ns)' && ! has '  ✓ 0 passed (Ns)' \
  && report "a suite that ran nothing is SKIPPED, not a green 0 passed" pass \
  || report "a suite that ran nothing is SKIPPED, not a green 0 passed" fail
has '  (skipped: needs fzf >= 0.74, found 44)' \
  && report "...and says why, in the suite's own words" pass \
  || report "...and says why, in the suite's own words" fail
has '  ✓ 3 passed, 3 skipped (Ns)' \
  && report "a partial skip is counted next to the passes: three skip lines, three forms" pass \
  || report "a partial skip is counted next to the passes: three skip lines, three forms" fail
has '  - zsh -c (skipped: zsh is not installed)' \
  && report "...and each skipped case is listed" pass \
  || report "...and each skipped case is listed" fail
has '5 passed, 0 failed  (Ns total)' \
  && report "the total line is unchanged: a skip adds no pass" pass \
  || report "the total line is unchanged: a skip adds no pass" fail
has 'skipping suites: skip_all skip_some(3)' \
  && report "every skipping suite is named under the total" pass \
  || report "every skipping suite is named under the total" fail

# --- IMUX_STRICT=1 --------------------------------------------------------------------
STRICT=1 run pass_one skip_all skip_some
[ "$RC" = 1 ] && has 'IMUX_STRICT=1: a skip is a failure here' \
  && report "IMUX_STRICT=1: any skip fails the run" pass \
  || report "IMUX_STRICT=1: any skip fails the run (exit $RC)" fail
STRICT=1 run skip_some
[ "$RC" = 1 ] && report "...a partial one too" pass || report "...a partial one too (exit $RC)" fail
STRICT=1 run pass_one
[ "$RC" = 0 ] && ! has 'IMUX_STRICT=1: a skip is a failure here' \
  && report "...and a run with no skip still passes" pass \
  || report "...and a run with no skip still passes (exit $RC)" fail

# --- every skip note the real suites print is one it counts -----------------------------
# run_all.sh knows a skip by the word "skipped" in a note starting "  (" or
# "  - ".  A note of that shape on stdout that does not say it was a skip
# IMUX_STRICT never saw: "(the Rust core is not built: only the bash renderer
# is checked)" in seven suites read as nothing at all.  Read from the suites'
# source, since most such paths never run where the tools are all there.
# Notes on stderr are a failed wait's diagnostics, beside its failure, and the
# container case's note is a stated choice (test_title_apps.sh says why).
uncounted=$(cd "$SCRIPT_DIR" && grep -n -E "(echo|printf)[^\"']*[\"']  (\(|- )" tests/test_*.sh \
  | grep -v -e 'skipped' -e '>&2' -e 'INTERDIMUX_TEST_DOCKER=off' || true)
if [ -z "$uncounted" ]; then
  report "every skip note a suite prints says \"skipped\", so run_all.sh counts it" pass
else
  report "every skip note a suite prints says \"skipped\", so run_all.sh counts it" fail
  printf '%s\n' "$uncounted" | sed 's/^/      /'
fi

# --- what was there before stays -------------------------------------------------------
STRICT="" run fails pass_one
[ "$RC" = 1 ] && has 'failing suites: fails' && has '  ✗ 0 passed, 1 failed (Ns)' \
  && report "a failing suite still fails the run, by name" pass \
  || report "a failing suite still fails the run, by name (exit $RC)" fail
STRICT="" run pass
if has '==> pass_one' && ! has '==> skip_all' && ! has '==> fails'; then
  report "names on the command line still pick the suites, by substring" pass
else
  report "names on the command line still pick the suites, by substring" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
