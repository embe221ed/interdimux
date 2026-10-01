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
#   - fd: ignore files above a scan's root, and an fd too old for the flag
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

# Last tab-separated field (the spec/path column) of each line
specs() {
  cut -f3
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
# Deep mode: the whole result set, written out
# ---------------------------------------------------------------------------
#
# A deep search scans the subtree of every directory its query matched, all of
# them in one finder run (scan_roots, review PERF-08), and the checks above only
# ask whether a row or two is there: a depth off by one, or a match's subtree
# lost, passed them all.  So here each search's rows are listed in full, in
# order, by hand -- under find, and under fd when there is one.  SCAN_DEPTH is
# the default 3, so where a subtree stops is part of each answer.
#
# dp/
#   hq/                      <- $HOME
#     Library/Caches/junk/   pruned whenever $HOME itself is scanned
#     code/                  <- the search path
#       svc-a/  src/lib/deep/deeper/deepest
#               svc-inner/x/y/z        a match inside a match
#       other/svc-b/one/two/three/four
#             svc-b/.cache                     hidden, inside a match: never listed
#       tier/svc-c/alpha
#       .hidden/svc-hid                hidden: never listed
#   hqx/a/b/c/d              a sibling that matches "hq" too

DP="$TMPDIR_TEST/dp"
DH="$DP/hq"
mkdir -p "$DH/Library/Caches/junk" "$DH/code/svc-a/src/lib/deep/deeper/deepest" \
  "$DH/code/svc-a/svc-inner/x/y/z" "$DH/code/other/svc-b/one/two/three/four" \
  "$DH/code/other/svc-b/.cache" "$DH/code/tier/svc-c/alpha" "$DH/code/.hidden/svc-hid" \
  "$DP/hqx/a/b/c/d"

# A PATH of just the tools the picker runs: without fd in it, the finder is
# find.  fd (or Debian's fdfind) joins it for the second pass.
FINDBIN="$TMPDIR_TEST/findbin"
mkdir -p "$FINDBIN"
for t in bash sh env fzf sed sort find tmux cat head tail tr wc cut grep awk mkdir \
         mv rm cp ln touch chmod date stty uname id basename dirname readlink mktemp; do
  p=$(command -v "$t" 2>/dev/null) || continue
  case "$p" in /*) ln -s "$p" "$FINDBIN/$t" ;; esac
done
finders=("find:$FINDBIN")
for f in fd fdfind; do
  p=$(command -v "$f" 2>/dev/null) || continue
  case "$p" in /*) ;; *) continue ;; esac
  mkdir -p "$TMPDIR_TEST/fdbin"
  cp -P "$FINDBIN"/* "$TMPDIR_TEST/fdbin/"
  ln -s "$p" "$TMPDIR_TEST/fdbin/$f"
  finders+=("$f:$TMPDIR_TEST/fdbin")
  break
done
[ "${#finders[@]}" -gt 1 ] || echo "  (no fd or fdfind: the deep result sets under fd are skipped; find ran them)"

# deep_rows NAME BIN PROJECT_DIRS QUERY WANT...: --dirs-list --deep QUERY's
# spec column is exactly WANT, in order, and nothing went to stderr
deep_rows() {
  local name="$1" bin="$2" pdirs="$3" q="$4" got want
  shift 4
  got=$(env -i PATH="$bin" HOME="$DH" XDG_DATA_HOME="$TMPDIR_TEST/no-data" \
          TMUX="$TMPDIR_TEST/no-such-socket,0,0" INTERDIMUX_PROJECT_DIRS="$pdirs" \
          INTERDIMUX_USE_ZOXIDE=off \
          bash "$SCRIPT" --dirs-list --deep "$q" 2> "$TMPDIR_TEST/deep.err" | cut -f3)
  want=$(printf '%s\n' "$@")
  if [ "$got" = "$want" ] && [ ! -s "$TMPDIR_TEST/deep.err" ]; then
    report "$name" pass
  else
    report "$name" fail
    ERRORS+="$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -12 || true)"$'\n'
    ERRORS+="$(head -c 300 "$TMPDIR_TEST/deep.err")"
  fi
}

for fb in "${finders[@]}"; do
  fname="${fb%%:*}" fbin="${fb#*:}"

  # Every match's subtree to depth 3 -- but a match inside one already
  # scanned (svc-inner) is listed, not scanned again from itself, so its z,
  # four levels below svc-a, is not.  The hidden svc-hid is never a match.
  deep_rows "deep result set ($fname): a name fragment, with a match inside a match" \
    "$fbin" "$DH/code" svc \
    "$DH/code/other/svc-b" \
    "$DH/code/other/svc-b/one" \
    "$DH/code/other/svc-b/one/two" \
    "$DH/code/other/svc-b/one/two/three" \
    "$DH/code/svc-a" \
    "$DH/code/svc-a/src" \
    "$DH/code/svc-a/src/lib" \
    "$DH/code/svc-a/src/lib/deep" \
    "$DH/code/svc-a/svc-inner" \
    "$DH/code/svc-a/svc-inner/x" \
    "$DH/code/svc-a/svc-inner/x/y" \
    "$DH/code/tier/svc-c" \
    "$DH/code/tier/svc-c/alpha"

  # A path fragment: every directory whose path holds it, and their subtrees
  deep_rows "deep result set ($fname): a multi-component fragment" \
    "$fbin" "$DH/code" r/svc \
    "$DH/code/other/svc-b" \
    "$DH/code/other/svc-b/one" \
    "$DH/code/other/svc-b/one/two" \
    "$DH/code/other/svc-b/one/two/three" \
    "$DH/code/tier/svc-c" \
    "$DH/code/tier/svc-c/alpha"

  # A path being typed: its completion (src) is scanned, and so -- as a
  # path fragment -- is every directory whose path holds what was typed,
  # src/lib among them, which reaches deepest
  deep_rows "deep result set ($fname): a partly typed path" \
    "$fbin" "$DH/code" "$DH/code/svc-a/sr" \
    "$DH/code/svc-a/src" \
    "$DH/code/svc-a/src/lib" \
    "$DH/code/svc-a/src/lib/deep" \
    "$DH/code/svc-a/src/lib/deep/deeper" \
    "$DH/code/svc-a/src/lib/deep/deeper/deepest"

  # $HOME is a match itself: its subtree comes without ~/Library, and the
  # sibling that matches alongside it keeps its own depth
  deep_rows "deep result set ($fname): \$HOME as a match, ~/Library pruned" \
    "$fbin" "$DP" hq \
    "$DH" \
    "$DH/code" \
    "$DH/code/other" \
    "$DH/code/other/svc-b" \
    "$DH/code/svc-a" \
    "$DH/code/svc-a/src" \
    "$DH/code/svc-a/svc-inner" \
    "$DH/code/tier" \
    "$DH/code/tier/svc-c" \
    "$DP/hqx" \
    "$DP/hqx/a" \
    "$DP/hqx/a/b" \
    "$DP/hqx/a/b/c"
done

# ---------------------------------------------------------------------------
# fd and the ignore files ABOVE a scan's root (BUG-31)
# ---------------------------------------------------------------------------
# A dotfiles repo in $HOME whose .gitignore is `*`: fd applied it under every
# search root, and the scan came back empty with no hint why, while the find
# backend listed everything.  Only a root those files hide entirely is scanned
# without them, though.  Inside any other repo a browse, or a deep search,
# starts below the repo's .gitignore too, and must keep the directories it
# ignores (node_modules) out as it always has -- and so must a ~/.fdignore.
REAL_FD=$(command -v fd || command -v fdfind || true)
has_spec() { specs <<< "$1" | grep -qx "$FIX_HOME/$2"; }
if [ -z "$REAL_FD" ]; then
  printf '  - fd cases (skipped: no fd or fdfind on PATH)\n'
else
  mkdir -p "$FIX_HOME/.git"
  printf '*\n' > "$FIX_HOME/.gitignore"
  # The precondition, from fd itself: on its own it lists nothing here.
  ctl=$("$REAL_FD" --type d --max-depth 1 . "$FIX_HOME/work" 2>/dev/null || true)
  if [ -z "$ctl" ]; then
    report "control: fd alone honours \$HOME's .gitignore '*' under ~/work" pass
  else
    report "control: fd alone honours \$HOME's .gitignore '*' under ~/work" fail
  fi
  out=$(dirs_list)
  if echo "$out" | grep "work/api" | grep -q '◆' && echo "$out" | grep "work/tools" | grep -q '·'; then
    report "fd: \$HOME's .gitignore '*' does not empty the scan" pass
  else
    report "fd: \$HOME's .gitignore '*' does not empty the scan" fail
  fi
  out=$(dirs_list -- --deep 'camelproj')
  if has_spec "$out" work/tools/CamelProj; then
    report "fd: ...nor the deep search" pass
  else
    report "fd: ...nor the deep search" fail
  fi
  out=$(dirs_list -- --deep "$FIX_HOME/work/too")
  if has_spec "$out" work/tools/CamelProj; then
    report "fd: ...nor a partly typed path" pass
  else
    report "fd: ...nor a partly typed path" fail
  fi
  out=$(dirs_list -- --scan "$FIX_HOME/work/tools")
  if has_spec "$out" work/tools/CamelProj; then
    report "fd: ...nor a browse (^g)" pass
  else
    report "fd: ...nor a browse (^g)" fail
  fi

  # An fd too old for --no-ignore-parent (before 8.3) refuses the whole command
  # line -- status 1 from its old argument parser, 2 from the new one.  Here
  # that leaves the scan as it was, and the list still comes up.
  mkdir -p "$TMPDIR_TEST/oldfd"
  for rc in 1 2; do
    cat > "$TMPDIR_TEST/oldfd/fd" <<STUB
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = --no-ignore-parent ] && { echo "error: unexpected argument '\$a' found" >&2; exit $rc; }
done
exec "$REAL_FD" "\$@"
STUB
    chmod +x "$TMPDIR_TEST/oldfd/fd"
    out=$(dirs_list PATH="$TMPDIR_TEST/oldfd:$PATH" --)
    if has_spec "$out" Desktop/proj_alpha; then
      report "an fd that refuses --no-ignore-parent (status $rc) still lists" pass
    else
      report "an fd that refuses --no-ignore-parent (status $rc) still lists" fail
    fi
  done
  rm -rf "$FIX_HOME/.git" "$FIX_HOME/.gitignore"

  # A repo's own .gitignore, above a browse's or a deep search's root.  web2's
  # only subdirectory is one it ignores, so its browse finds nothing -- and
  # web2 is not hidden itself, so that is what it shows.
  mono="$FIX_HOME/work/mono"
  mkdir -p "$mono/.git" "$mono/services/web/src" "$mono/services/web/node_modules/dep" \
           "$mono/services/web2/node_modules"
  printf 'node_modules\n' > "$mono/.gitignore"
  # The control: without those files, fd WOULD list node_modules here.
  ctl=$("$REAL_FD" --no-ignore-parent --type d --max-depth 2 . "$mono/services" 2>/dev/null || true)
  if [[ "$ctl" == *node_modules* ]]; then
    report "control: fd lists node_modules below ~/work/mono/services without the repo's .gitignore" pass
  else
    report "control: fd lists node_modules below ~/work/mono/services without the repo's .gitignore" fail
  fi
  out=$(dirs_list -- --scan "$mono/services")
  if has_spec "$out" work/mono/services/web/src && [[ "$out" != *node_modules* ]]; then
    report "fd: a browse inside a repo keeps the directories it ignores out" pass
  else
    report "fd: a browse inside a repo keeps the directories it ignores out" fail
  fi
  out=$(dirs_list -- --deep 'services')
  if has_spec "$out" work/mono/services/web/src && [[ "$out" != *node_modules* ]]; then
    report "fd: ...and so does a deep search" pass
  else
    report "fd: ...and so does a deep search" fail
  fi
  out=$(dirs_list -- --scan "$mono/services/web2")
  if has_spec "$out" work/mono/services/web2 && [[ "$out" != *node_modules* ]]; then
    report "fd: ...even where it ignores every subdirectory there is" pass
  else
    report "fd: ...even where it ignores every subdirectory there is" fail
  fi
  rm -rf "$mono"

  # A deliberate ~/.fdignore, which needs no repo.
  printf 'node_modules\n' > "$FIX_HOME/.fdignore"
  mkdir -p "$FIX_HOME/work/tools/node_modules/dep"
  out=$(dirs_list -- --deep '')
  out2=$(dirs_list -- --scan "$FIX_HOME/work/tools")
  if has_spec "$out" work/tools/CamelProj && [[ "$out$out2" != *node_modules* ]]; then
    report "fd: a ~/.fdignore still applies to the deep search and a browse" pass
  else
    report "fd: a ~/.fdignore still applies to the deep search and a browse" fail
  fi
  rm -rf "$FIX_HOME/.fdignore" "$FIX_HOME/work/tools/node_modules"
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
