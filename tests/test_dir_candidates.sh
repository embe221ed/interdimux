#!/usr/bin/env bash
#
# Which directories the pickers offer, from the recent list and zoxide.
#
# A directory whose name is not valid UTF-8 is offered by NEITHER renderer:
# fzf hands a selection back with every invalid byte replaced by U+FFFD, so such
# a row names a directory that does not exist and can never be opened.  The Rust
# core already dropped it (by accident: it tested is_dir() on the lossy string);
# the bash renderer listed it -- so the list depended on whether the binary was
# built.  A valid non-ASCII name must of course still be offered.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-dircand-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-dircand.XXXXXX")" && pwd -P)"
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

echo "interdimux directory-candidate tests"
echo

BAD="$TMPD/fx/nonutf8-"$'\377'"z"          # \377 can never start a UTF-8 sequence
ACCENT="$TMPD/fx/caf"$'\xc3\xa9'           # valid UTF-8: must still be offered
ZBAD="$TMPD/fx/zoxide-"$'\xc3'"x"          # a truncated sequence, via zoxide
mkdir -p "$BAD" "$ACCENT" "$ZBAD" "$TMPD/fx/zgood" "$TMPD/home" "$TMPD/data/interdimux" "$TMPD/bin"
printf '%s\n' "$BAD" "$ACCENT" > "$TMPD/data/interdimux/recent_dirs"
# zoxide stub: one directory it would offer, one whose name is not UTF-8
printf '#!/bin/sh\nprintf "%%s\\n" "%s" "%s"\n' "$ZBAD" "$TMPD/fx/zgood" > "$TMPD/bin/zoxide"
chmod +x "$TMPD/bin/zoxide"

tmux -f /dev/null -L "$SOCK" new-session -d -s bench -x 200 -y 50 -c "$TMPD/home" 'sleep 99999'
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=bench:0' -F '#{pane_id}' | head -1)"
export HOME="$TMPD/home" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_SHOW_DIRS=on INTERDIMUX_PROJECT_DIRS="$TMPD/nowhere"
wait_for "--list to produce rows" sh -c "bash '$SCRIPT' --list 2>/dev/null | grep -q ."

# D: specs of --list, one renderer at a time.  $1 = on|off (INTERDIMUX_USE_RUST)
d_rows() {
  # LC_ALL=C for awk: the bytes under test are not UTF-8, which is the point
  INTERDIMUX_USE_RUST="$1" bash "$SCRIPT" --list 2>/dev/null \
    | LC_ALL=C awk -F'\t' '$4 ~ /^D:/ { print substr($4, 3) }'
}

renderers="off"
if [ -x "$BIN" ]; then renderers="on off"; else echo "  (rust binary not built: bash renderer only)"; fi

for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)
  for zox in off on; do
    got=$(PATH="$TMPD/bin:$PATH" INTERDIMUX_USE_ZOXIDE="$zox" d_rows "$r")
    ctx="$label renderer, zoxide $zox"
    if printf '%s\n' "$got" | grep -qxF "$ACCENT"; then
      report "$ctx: a valid non-ASCII recent dir is offered" pass
    else
      report "$ctx: a valid non-ASCII recent dir is offered" fail
    fi
    if printf '%s\n' "$got" | grep -qaF "nonutf8-"; then
      report "$ctx: a non-UTF-8 recent dir is not offered" fail
    else
      report "$ctx: a non-UTF-8 recent dir is not offered" pass
    fi
    if [ "$zox" = on ]; then
      if printf '%s\n' "$got" | grep -qxF "$TMPD/fx/zgood" && ! printf '%s\n' "$got" | grep -qaF "zoxide-"; then
        report "$ctx: zoxide's valid dir is offered, its non-UTF-8 one is not" pass
      else
        report "$ctx: zoxide's valid dir is offered, its non-UTF-8 one is not" fail
      fi
    fi
  done
done

# The directory picker (ctrl-o) reads the same list through load_recent_dirs.
got=$(PATH="$TMPD/bin:$PATH" INTERDIMUX_USE_ZOXIDE=on bash "$SCRIPT" --dirs-list 2>/dev/null | cut -f3)
if printf '%s\n' "$got" | grep -qxF "$ACCENT" && ! printf '%s\n' "$got" | grep -qaF -e "nonutf8-" -e "zoxide-"; then
  report "--dirs-list: the valid dir is listed, the non-UTF-8 ones are not" pass
else
  report "--dirs-list: the valid dir is listed, the non-UTF-8 ones are not" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
