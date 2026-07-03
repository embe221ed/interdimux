#!/usr/bin/env bash
#
# Tests for the directory picker list generation (--dirs-list).
#
# Covers:
#   - default mode: recent tier, project/plain classification, dead-dir
#     pruning from the recent list
#   - deep mode: literal path resolution (relative / tilde), partial
#     path completion via ancestor walk, substring matching
#   - scan mode: existing dir and parent fallback
#   - trailing-slash normalization and dedup across tiers
#   - zoxide merge (via a stubbed zoxide binary)
#   - INTERDIMUX_RECENT_LIMIT and INTERDIMUX_SCAN_DEPTH options
#
# Runs against a fixture HOME, so it never touches the user's data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
# pwd -P: finders return physical paths, so the fixture must not sit
# behind a symlink (/tmp → /private/tmp on macOS)
TMPDIR_TEST="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-dirs-test-XXXXXX")" && pwd -P)"
FIX_HOME="$TMPDIR_TEST/home"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1))
    printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: $name"$'\n'
    printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

# Run --dirs-list with the fixture environment, ANSI codes stripped.
# Extra env assignments may be passed as VAR=value arguments before "--".
dirs_list() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  [ "${1:-}" = "--" ] && shift
  env -i \
    PATH="$PATH" \
    HOME="$FIX_HOME" \
    XDG_DATA_HOME="$FIX_HOME/.local/share" \
    TMUX="$TMPDIR_TEST/no-such-socket,0,0" \
    INTERDIMUX_PROJECT_DIRS="$FIX_HOME/work" \
    INTERDIMUX_USE_ZOXIDE=off \
    ${envs[@]+"${envs[@]}"} \
    bash "$SCRIPT" --dirs-list "$@" 2>/dev/null \
    | sed $'s/\x1b\\[[0-9;]*m//g'
}

# First tab-separated field (the spec/path column) of each line
specs() {
  cut -f1
}

# ---------------------------------------------------------------------------
# Setup: fixture directory tree
# ---------------------------------------------------------------------------
#
# home/
#   Desktop/
#     proj_alpha/ (.git)        nested_one/deep_two/deeper_three/
#     plain_dir/
#   work/                        <- search path
#     api/ (.git)
#     tools/
#       api/ (.git)

setup() {
  mkdir -p "$FIX_HOME/Desktop/proj_alpha/.git"
  mkdir -p "$FIX_HOME/Desktop/proj_alpha/nested_one/deep_two/deeper_three"
  mkdir -p "$FIX_HOME/Desktop/plain_dir"
  mkdir -p "$FIX_HOME/work/api/.git"
  mkdir -p "$FIX_HOME/work/tools/api/.git"
  mkdir -p "$FIX_HOME/work/tools/CamelProj/.git"
  mkdir -p "$FIX_HOME/Library/Caches/junkproj"
  mkdir -p "$FIX_HOME/.local/share/interdimux"

  # Recent list: one live dir, one dead dir
  {
    echo "$FIX_HOME/Desktop/proj_alpha"
    echo "$FIX_HOME/Desktop/deleted_dir"
  } > "$FIX_HOME/.local/share/interdimux/recent_dirs"

  # zoxide stub: emits one live dir and one dead dir
  mkdir -p "$TMPDIR_TEST/bin"
  cat > "$TMPDIR_TEST/bin/zoxide" <<EOF
#!/bin/sh
printf '%s\n' "$FIX_HOME/work/tools" "$FIX_HOME/gone_dir"
EOF
  chmod +x "$TMPDIR_TEST/bin/zoxide"
}

echo "interdimux --dirs-list tests"
echo

setup

# ---------------------------------------------------------------------------
# Default mode
# ---------------------------------------------------------------------------

out=$(dirs_list)

if [ "$(echo "$out" | head -1 | specs)" = "$FIX_HOME/Desktop/proj_alpha" ] \
   && echo "$out" | head -1 | grep -q '★'; then
  report "default: recent dir listed first with ★" pass
else
  report "default: recent dir listed first with ★" fail
fi

if echo "$out" | specs | grep -qx "$FIX_HOME/Desktop/deleted_dir"; then
  report "default: dead recent dir is not listed" fail
else
  report "default: dead recent dir is not listed" pass
fi

if echo "$out" | grep "work/api" | grep -q '◆'; then
  report "default: project root tagged ◆" pass
else
  report "default: project root tagged ◆" fail
fi

if echo "$out" | grep "work/tools" | grep -q '·'; then
  report "default: plain dir tagged ·" pass
else
  report "default: plain dir tagged ·" fail
fi

# ---------------------------------------------------------------------------
# Deep mode: literal path resolution
# ---------------------------------------------------------------------------

out=$(dirs_list -- --deep 'Desktop/proj_alpha')
if echo "$out" | specs | grep -qx "$FIX_HOME/Desktop/proj_alpha/nested_one/deep_two/deeper_three"; then
  report "deep: relative path query scans nested dirs" pass
else
  report "deep: relative path query scans nested dirs" fail
fi

# shellcheck disable=SC2088  # literal tilde is the point of this test
out=$(dirs_list -- --deep '~/Desktop/proj_alpha')
if echo "$out" | specs | grep -qx "$FIX_HOME/Desktop/proj_alpha/nested_one"; then
  report "deep: tilde path query resolves" pass
else
  report "deep: tilde path query resolves" fail
fi

out=$(dirs_list -- --deep 'Desktop/proj_al')
if echo "$out" | specs | grep -qx "$FIX_HOME/Desktop/proj_alpha" \
   && echo "$out" | specs | grep -qx "$FIX_HOME/Desktop/proj_alpha/nested_one"; then
  report "deep: partial path completes via ancestor walk" pass
else
  report "deep: partial path completes via ancestor walk" fail
fi

out=$(dirs_list -- --deep 'api')
if echo "$out" | specs | grep -qx "$FIX_HOME/work/api" \
   && echo "$out" | specs | grep -qx "$FIX_HOME/work/tools/api"; then
  report "deep: substring matches beyond depth 1" pass
else
  report "deep: substring matches beyond depth 1" fail
fi

out=$(dirs_list -- --deep 'camelproj')
if echo "$out" | specs | grep -qx "$FIX_HOME/work/tools/CamelProj"; then
  report "deep: name fragment matches case-insensitively" pass
else
  report "deep: name fragment matches case-insensitively" fail
fi

# Searching from $HOME itself must skip ~/Library noise
out=$(dirs_list INTERDIMUX_PROJECT_DIRS="$FIX_HOME" -- --deep 'junkproj')
if echo "$out" | specs | grep -q "Library"; then
  report "deep: ~/Library pruned when scanning \$HOME" fail
else
  report "deep: ~/Library pruned when scanning \$HOME" pass
fi

out=$(dirs_list INTERDIMUX_PROJECT_DIRS="$FIX_HOME" -- --deep 'camelproj')
if echo "$out" | specs | grep -qx "$FIX_HOME/work/tools/CamelProj"; then
  report "deep: \$HOME scan still finds non-Library dirs" pass
else
  report "deep: \$HOME scan still finds non-Library dirs" fail
fi

# ---------------------------------------------------------------------------
# Scan mode
# ---------------------------------------------------------------------------

out=$(dirs_list -- --scan "$FIX_HOME/Desktop")
if echo "$out" | specs | grep -qx "$FIX_HOME/Desktop/proj_alpha" \
   && echo "$out" | specs | grep -qx "$FIX_HOME/Desktop/proj_alpha/nested_one"; then
  report "scan: existing dir scanned at depth 2" pass
else
  report "scan: existing dir scanned at depth 2" fail
fi

out=$(dirs_list -- --scan "$FIX_HOME/Desktop/proj")
if echo "$out" | specs | grep -qx "$FIX_HOME/Desktop/plain_dir"; then
  report "scan: nonexistent path falls back to parent" pass
else
  report "scan: nonexistent path falls back to parent" fail
fi

# ---------------------------------------------------------------------------
# Normalization and dedup
# ---------------------------------------------------------------------------

out=$(dirs_list -- --deep 'Desktop/proj_alpha')
if echo "$out" | specs | grep -q '/$'; then
  report "no trailing slashes in spec column" fail
else
  report "no trailing slashes in spec column" pass
fi

dupes=$(echo "$out" | specs | sort | uniq -d)
if [ -z "$dupes" ]; then
  report "no duplicate entries across tiers" pass
else
  report "no duplicate entries across tiers" fail
fi

# ---------------------------------------------------------------------------
# zoxide merge
# ---------------------------------------------------------------------------

out=$(dirs_list PATH="$TMPDIR_TEST/bin:$PATH" INTERDIMUX_USE_ZOXIDE=on --)
if echo "$out" | grep "work/tools" | grep -q '★'; then
  report "zoxide: live dir merged into recent tier" pass
else
  report "zoxide: live dir merged into recent tier" fail
fi

if echo "$out" | specs | grep -qx "$FIX_HOME/gone_dir"; then
  report "zoxide: dead dir filtered out" fail
else
  report "zoxide: dead dir filtered out" pass
fi

if [ "$(echo "$out" | specs | grep -cx "$FIX_HOME/work/tools")" = "1" ]; then
  report "zoxide: merged dir not duplicated by scan tier" pass
else
  report "zoxide: merged dir not duplicated by scan tier" fail
fi

# ---------------------------------------------------------------------------
# Config options
# ---------------------------------------------------------------------------

# Two live recent entries, limit 1 → only the first survives
{
  echo "$FIX_HOME/Desktop/proj_alpha"
  echo "$FIX_HOME/Desktop/plain_dir"
} > "$FIX_HOME/.local/share/interdimux/recent_dirs"

out=$(dirs_list INTERDIMUX_RECENT_LIMIT=1 --)
if [ "$(echo "$out" | grep -c '★')" = "1" ]; then
  report "option: INTERDIMUX_RECENT_LIMIT caps recent tier" pass
else
  report "option: INTERDIMUX_RECENT_LIMIT caps recent tier" fail
fi

out=$(dirs_list INTERDIMUX_SCAN_DEPTH=1 -- --deep 'Desktop/proj_alpha')
if echo "$out" | specs | grep -qx "$FIX_HOME/Desktop/proj_alpha/nested_one" \
   && ! echo "$out" | specs | grep -qx "$FIX_HOME/Desktop/proj_alpha/nested_one/deep_two"; then
  report "option: INTERDIMUX_SCAN_DEPTH limits deep scan" pass
else
  report "option: INTERDIMUX_SCAN_DEPTH limits deep scan" fail
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
