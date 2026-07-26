#!/usr/bin/env bash
#
# Run every test suite and total the results.
#
# SEQUENTIALLY, on purpose.  Each suite drives a real tmux server with real
# panes, and several assertions are about what a pane *displays* within a
# bounded wait.  Running them concurrently made three suites fail that all
# passed alone — not flakiness in the code under test, just the box being busy.
# The suites are only a few minutes end to end; keep them serial.
#
#   tests/run_all.sh                 # everything, including the Rust tests
#   tests/run_all.sh raw sched       # only suites whose name matches
#   IMUX_SKIP_RUST=1 tests/run_all.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'

total_p=0 total_f=0 failed=()
started=$SECONDS

# --- Rust first: it is fast, and if the binary is broken every shell suite
# --- that exercises the picker will fail in a confusing way downstream.
if [ "${IMUX_SKIP_RUST:-0}" != 1 ] && [ $# -eq 0 ] && command -v cargo >/dev/null 2>&1; then
  printf '%s==> rust%s\n' "$BOLD" "$RST"
  if out=$(cd rust && cargo test --release 2>&1); then
    n=$(printf '%s' "$out" | awk '/^test result: ok\./ {s += $4} END {print s+0}')
    printf '  %s✓%s %d rust tests\n\n' "$GREEN" "$RST" "$n"
    total_p=$((total_p + n))
  else
    printf '%s\n' "$out" | tail -25 | sed 's/^/  /'
    printf '  %s✗%s cargo test failed\n\n' "$RED" "$RST"
    failed+=("rust")
    total_f=$((total_f + 1))
  fi
fi

for t in tests/test_*.sh; do
  name=$(basename "$t" .sh); name=${name#test_}
  if [ $# -gt 0 ]; then
    match=0
    for pat in "$@"; do case "$name" in *"$pat"*) match=1 ;; esac; done
    [ "$match" = 1 ] || continue
  fi

  printf '%s==> %s%s\n' "$BOLD" "$name" "$RST"
  t0=$SECONDS
  out=$(timeout 600 bash "$t" 2>&1); rc=$?
  dt=$((SECONDS - t0))

  line=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -m1 '^Results:')
  p=$(printf '%s' "$line" | awk '{print $2}'); f=$(printf '%s' "$line" | awk '{print $4}')

  if [ -z "$line" ]; then
    # no Results line at all means the suite died before finishing — that is a
    # failure even if it printed passing assertions on the way down
    printf '%s\n' "$out" | tail -20 | sed 's/^/  /'
    printf '  %s✗%s suite did not finish (exit %d)\n\n' "$RED" "$RST" "$rc"
    failed+=("$name"); total_f=$((total_f + 1)); continue
  fi

  total_p=$((total_p + p)); total_f=$((total_f + f))
  if [ "$f" -eq 0 ] && [ "$rc" -eq 0 ]; then
    printf '  %s✓%s %d passed %s(%ds)%s\n\n' "$GREEN" "$RST" "$p" "$DIM" "$dt" "$RST"
  else
    printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '✗|FAIL|timed out' | sed 's/^/  /'
    printf '  %s✗%s %d passed, %d failed %s(%ds)%s\n\n' "$RED" "$RST" "$p" "$f" "$DIM" "$dt" "$RST"
    failed+=("$name")
  fi
done

printf '%s%d passed, %d failed%s  %s(%ds total)%s\n' \
  "$BOLD" "$total_p" "$total_f" "$RST" "$DIM" "$((SECONDS - started))" "$RST"
if [ ${#failed[@]} -gt 0 ]; then
  printf 'failing suites: %s\n' "${failed[*]}"
  exit 1
fi
