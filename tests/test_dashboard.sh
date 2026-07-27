#!/usr/bin/env bash
#
# prefix+g must produce a usable surface at EVERY client size.
#
# The failure this defends against is silent in both directions:
#
#   * `display-menu` taller than the client draws nothing and exits 0.  Verified
#     on tmux 3.7b: the 13-item dashboard appears on a 15-row client and does not
#     appear at all on a 14-row one.  No error, no message — prefix+g is simply a
#     dead key.  Menu height is items + 2 for the borders.
#   * `display-popup` does not clamp either; it fails with "height too large" and
#     draws nothing.  The limit is exactly the client's size — on a 14-row client
#     `-h 14` succeeds and `-h 15` errors.  So the fzf fallback, at a fixed
#     64x19, was the same dead key reached by the other path.
#
# Neither is visible from the source, and neither produces a diagnostic, so the
# only honest test renders the thing and looks.  display-menu needs an attached
# CLIENT, hence the pair of private servers: the outer one's pane runs an attach
# to the inner one, and the surface is captured off the outer pane.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-dash-$$"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  local s
  for s in $(tmux -L "$SOCK-list" list-sessions 2>/dev/null); do :; done
  # every server this suite starts is named from $SOCK, so sweep the family
  for s in $(ls "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)" 2>/dev/null | grep "^$SOCK" || true); do
    tmux -L "$s" kill-server 2>/dev/null || true
  done
}
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

echo "interdimux dashboard tests"
echo

# Render prefix+g on a client of the given size and echo the pane contents.
# TMUX_PANE is deliberately unset: it belongs to whatever server the test runner
# itself is in, and would not resolve against these private ones.
dash_capture() {
  local w="$1" h="$2" out="$SOCK-o-$w-$h" in="$SOCK-i-$w-$h" i
  tmux -f /dev/null -L "$out" new-session -d -s drv -x "$w" -y "$h" \
    "tmux -f /dev/null -L '$in' new-session -s host" 2>/dev/null || return 0
  for i in $(seq 1 80); do
    tmux -L "$in" list-clients >/dev/null 2>&1 && break
    sleep 0.15
  done
  env -u TMUX_PANE \
      TMUX="$(tmux -L "$in" display-message -p '#{socket_path}' 2>/dev/null),99999,0" \
      INTERDIMUX_OPTS_PRIMED=1 \
      bash "$SCRIPT" --dashboard-launch >/dev/null 2>&1 &
  # poll for the surface rather than sleeping a fixed amount
  for i in $(seq 1 80); do
    tmux -L "$out" capture-pane -t '=drv:' -p 2>/dev/null | grep -q 'Switch' && break
    sleep 0.15
  done
  tmux -L "$out" capture-pane -t '=drv:' -p 2>/dev/null
  tmux -L "$in" kill-server 2>/dev/null || true
  tmux -L "$out" kill-server 2>/dev/null || true
}

# --- the surface exists at every size ---------------------------------------
#
# 15 and 14 straddle the menu's exact cutoff, so they are the two that matter.
for size in "90 40" "90 15" "90 14" "90 10" "40 30" "40 12"; do
  set -- $size
  w="$1"; h="$2"
  cap=$(dash_capture "$w" "$h" || true)
  if printf '%s\n' "$cap" | grep -qE 'Switch|New session|Send keys'; then
    report "prefix+g draws something on a ${w}x${h} client" pass
  else
    report "prefix+g draws something on a ${w}x${h} client" fail
  fi
done

# The tall client must still get the NATIVE menu — the fallback is for when it
# cannot fit, not a replacement for it.
cap=$(dash_capture 90 40 || true)
if printf '%s\n' "$cap" | grep -q '(s)' && ! printf '%s\n' "$cap" | grep -q 'interdimux ❯'; then
  report "a tall client gets the native menu, not the fzf fallback" pass
else
  report "a tall client gets the native menu, not the fzf fallback" fail
fi

# ...and the short one must get the fallback, which scrolls and so always fits.
cap=$(dash_capture 90 12 || true)
if printf '%s\n' "$cap" | grep -q 'interdimux ❯'; then
  report "a short client falls back to the scrolling fzf menu" pass
else
  report "a short client falls back to the scrolling fzf menu" fail
fi

# --- the guard's constant tracks the menu it guards --------------------------
#
# The one with teeth for the future: add an eleventh entry, forget to bump
# MENU_ROWS, and the dead key comes back on exactly one client height — the
# hardest kind of regression to notice.
menu_block=$(awk '/tmux display-menu -x C -y C/,/--launch jobs/' "$SCRIPT")
entries=$(printf '%s\n' "$menu_block" | grep -c 'run-shell -b' || true)
seps=$(printf '%s\n' "$menu_block" | grep -cE "^ +'' " || true)
want=$(( entries + seps + 2 ))
have=$(grep -oE '^ *MENU_ROWS=[0-9]+' "$SCRIPT" | head -1 | grep -oE '[0-9]+' || true)

if [ -n "$have" ] && [ "$have" = "$want" ]; then
  report "MENU_ROWS ($have) matches the menu it guards ($entries entries + $seps separators + 2 borders)" pass
else
  report "MENU_ROWS ($have) matches the menu it guards (wanted $want: $entries entries + $seps separators + 2 borders)" fail
fi

printf '\nResults: %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"

exit "$FAIL"
