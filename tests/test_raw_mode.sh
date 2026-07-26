#!/usr/bin/env bash
#
# Raw filter mode (IDEAS #15) — non-matching rows stay on screen, dimmed, so the
# tree does not collapse as you type.
#
# The assertion that matters is the cursor one.  In raw mode EVERY row is still
# displayed and selectable, and nothing moves the cursor onto a match:
# `--bind=change:first` pins it to the first *displayed* row.  So you filter to
# one session, press ctrl-x, and kill whatever happened to be at the top of the
# list instead.  Verified during development: with --raw, typing "delta" left
# the cursor on "alpha" under BOTH change:first and change:best (the latter
# fires before the search completes).  Only `result:best` works.
#
# Needs a real client, because a cursor lives in a rendered UI: send-keys writes
# to a pane's pty and cannot drive fzf, so an outer tmux types into an inner one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-raw-test-$$"
PASS=0
FAIL=0
ERRORS=""

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

echo "interdimux raw-mode tests"
echo

fzf_minor=$(fzf --version 2>/dev/null | awk '{print $1}' | cut -d. -f2)
if [ "${fzf_minor:-0}" -lt 74 ]; then
  echo "  (skipped: raw mode needs fzf >= 0.74, found ${fzf_minor:-?})"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

tmux -f /dev/null -L "$SOCK" new-session -d -s aaa       -x 120 -y 30 -c "$SCRIPT_DIR"
tmux -L "$SOCK" new-session -d -s bbb       -x 120 -y 30 -c /tmp
tmux -L "$SOCK" new-session -d -s zzztarget -x 120 -y 30 -c /tmp
sleep 1

sockpath=$(tmux -L "$SOCK" display-message -p '#{socket_path}')
anchor=$(tmux -L "$SOCK" list-panes -t '=aaa:' -F '#{pane_id}' | head -1)

open_navigator() { # $1 = extra env
  tmux -L "$SOCK" kill-session -t drv 2>/dev/null || true
  tmux -L "$SOCK" new-session -d -s drv -x 140 -y 24 -c /tmp \
    "env TMUX='$sockpath,99999,0' TMUX_PANE='$anchor' INTERDIMUX_OPTS_PRIMED=1 \
         INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_SHOW_DIRS=off \
         INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_PREVIEW=off $1 \
         bash '$SCRIPT'"
  local i
  for i in $(seq 1 60); do
    tmux -L "$SOCK" capture-pane -t '=drv:' -p 2>/dev/null | grep -q '▸' && return 0
    sleep 0.2
  done
  return 1
}
screen()      { tmux -L "$SOCK" capture-pane -t '=drv:' -p 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }
cursor_row()  { screen | grep -m1 '▌' | sed 's/^ *//'; }
close_nav()   { tmux -L "$SOCK" send-keys -t '=drv:' Escape 2>/dev/null || true; sleep 0.5; }

# --- the critical one ----------------------------------------------------------
if open_navigator ""; then
  report "the navigator opens in raw mode" pass
else
  report "the navigator opens in raw mode" fail
  echo; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

before=$(cursor_row)
tmux -L "$SOCK" send-keys -t '=drv:' 'zzztarget'
sleep 2.5
after=$(cursor_row)

case "$after" in
  *zzztarget*) report "filtering moves the cursor ONTO a match (not row 0)" pass ;;
  *) report "filtering moves the cursor ONTO a match (not row 0)" fail
     ERRORS+="    before: $before"$'\n'"    after : $after"$'\n' ;;
esac

# non-matching rows must still be on screen — that is the whole point
n_rows=$(screen | grep -c '▸' || true)
if [ "$n_rows" -ge 3 ]; then
  report "non-matching rows stay visible, so the tree does not collapse ($n_rows sessions)" pass
else
  report "non-matching rows stay visible ($n_rows sessions shown, expected >= 3)" fail
fi

# fzf's raw-mode gutter is a SECOND option; blanking only --gutter left a ▖ on
# every non-current row
if [ "$(screen | grep -c '▖' || true)" -eq 0 ]; then
  report "the raw-mode gutter is blanked (no stray glyph on every row)" pass
else
  report "the raw-mode gutter is blanked (no stray glyph on every row)" fail
fi
close_nav

# --- raw off must still behave -------------------------------------------------
if open_navigator "INTERDIMUX_RAW=off"; then
  tmux -L "$SOCK" send-keys -t '=drv:' 'zzztarget'
  sleep 2.5
  after=$(cursor_row)
  case "$after" in
    *zzztarget*) report "with raw off, filtering still selects the match" pass ;;
    *) report "with raw off, filtering still selects the match (got: $after)" fail ;;
  esac
  # with raw off the non-matches really are gone
  n=$(screen | grep -c '▸' || true)
  [ "$n" -le 1 ] && report "with raw off, non-matches are filtered out" pass \
                 || report "with raw off, non-matches are filtered out ($n shown)" fail
  close_nav
else
  report "the navigator opens with raw off" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
