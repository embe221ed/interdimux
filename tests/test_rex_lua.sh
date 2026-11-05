#!/usr/bin/env bash
# Run Rex's mocked API suites through the regular test/CI runner. No app needed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUA_BIN=${INTERDIMUX_LUA_BIN:-lua}
if ! command -v "$LUA_BIN" >/dev/null 2>&1; then
  printf '  (skipped: Lua is unavailable; install Lua 5.4 or newer)\n'
  printf 'Results: 0 passed, 0 failed\n'
  exit 0
fi

passed=0 failed=0
for suite in "$ROOT"/tests/rex_*.lua; do
  if output=$("$LUA_BIN" "$suite" "$ROOT" 2>&1); then
    printf '  passed: %s\n' "${suite##*/}"
    passed=$((passed + 1))
  else
    printf '  FAILED: %s\n%s\n' "${suite##*/}" "$output"
    failed=$((failed + 1))
  fi
done
printf 'Results: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
