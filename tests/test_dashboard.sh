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
  local w="$1" h="$2" vnum="${3:-}" i
  local out="$SOCK-o-$w-$h${vnum:+-$vnum}" in="$SOCK-i-$w-$h${vnum:+-$vnum}"
  tmux -f /dev/null -L "$out" new-session -d -s drv -x "$w" -y "$h" \
    "tmux -f /dev/null -L '$in' new-session -s host" 2>/dev/null || return 0
  for i in $(seq 1 80); do
    tmux -L "$in" list-clients >/dev/null 2>&1 && break
    sleep 0.15
  done
  env -u TMUX_PANE \
      TMUX="$(tmux -L "$in" display-message -p '#{socket_path}' 2>/dev/null),99999,0" \
      INTERDIMUX_OPTS_PRIMED=1 ${vnum:+INTERDIMUX_TMUX_VNUM=$vnum} \
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

# Render prefix+g, press one of its keys, and echo what the popup behind it
# draws.  The menu command runs on the INNER server via run-shell, so that child
# gets the inner server's environment rather than this one's — it re-reads its
# options and re-probes fzf, which is slower but is also exactly what a real
# keypress does.
dash_pick() {
  local w="$1" h="$2" key="$3" want="$4" i
  # Split from the line above on purpose: bash creates every name in a `local`
  # list before evaluating any of the assignments, so referring to `key` in the
  # same statement reads it as unset under `set -u`.
  local out="$SOCK-p-o-$key" in="$SOCK-p-i-$key"
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
  for i in $(seq 1 80); do
    tmux -L "$out" capture-pane -t '=drv:' -p 2>/dev/null | grep -q 'Switch' && break
    sleep 0.15
  done
  tmux -L "$out" send-keys -t '=drv:' "$key" 2>/dev/null || true
  for i in $(seq 1 160); do
    tmux -L "$out" capture-pane -t '=drv:' -p 2>/dev/null | grep -q "$want" && break
    sleep 0.15
  done
  tmux -L "$out" capture-pane -t '=drv:' -p 2>/dev/null
  tmux -L "$in" kill-server 2>/dev/null || true
  tmux -L "$out" kill-server 2>/dev/null || true
}

# --- the surface exists at every size ---------------------------------------
#
# The two heights that matter are the ones either side of the menu's cutoff, so
# they are DERIVED from the guard rather than written down — the last time they
# were literals the cutoff moved and the comment went stale while the test kept
# passing.
MR=$(grep -oE '^ *MENU_ROWS=[0-9]+' "$SCRIPT" | head -1 | grep -oE '[0-9]+' || true)
MR="${MR:-17}"
for size in "90 40" "90 $MR" "90 $((MR - 1))" "90 10" "40 30" "40 12"; do
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

# The cutoff itself, from both sides.  This is the assertion that would have
# caught the original dead key: the menu must appear at exactly MENU_ROWS and
# must NOT be attempted one row below it.
cap=$(dash_capture 90 "$MR" || true)
if printf '%s\n' "$cap" | grep -q '(s)' && ! printf '%s\n' "$cap" | grep -q 'interdimux ❯'; then
  report "at exactly MENU_ROWS ($MR) the native menu is drawn" pass
else
  report "at exactly MENU_ROWS ($MR) the native menu is drawn" fail
  ERRORS+="$(printf '%s\n' "$cap" | head -4 | sed 's/^/      /')"$'\n'
fi
cap=$(dash_capture 90 "$((MR - 1))" || true)
if printf '%s\n' "$cap" | grep -q 'interdimux ❯'; then
  report "one row below it the fallback takes over, rather than nothing at all" pass
else
  report "one row below it the fallback takes over, rather than nothing at all" fail
  ERRORS+="$(printf '%s\n' "$cap" | head -4 | sed 's/^/      /')"$'\n'
fi

# --- the Health entry --------------------------------------------------------
# It is in both dashboards or it is unreachable from one of them.
cap=$(dash_capture 90 40 || true)
printf '%s\n' "$cap" | grep -q 'Health' \
  && report "the native menu offers Health" pass \
  || report "the native menu offers Health" fail
# At MENU_ROWS-1 — the tallest client that still takes the fallback — all the
# entries fit without scrolling.  Below that fzf scrolls and the entries added
# LAST go off-screen, which is what the popup-height comment in the source warns
# about; they are still reachable by typing, so that is cramped rather than
# broken.
cap=$(dash_capture 90 "$((MR - 1))" || true)
printf '%s\n' "$cap" | grep -q 'Health' \
  && report "the fzf fallback offers Health too" pass \
  || report "the fzf fallback offers Health too" fail

# --- the guard's constant tracks the menu it guards --------------------------
#
# The one with teeth for the future: add an eleventh entry, forget to bump
# MENU_ROWS, and the dead key comes back on exactly one client height — the
# hardest kind of regression to notice.
menu_block=$(awk "/tmux display-menu -x C -y C/,/^  else$/" "$SCRIPT")
entries=$(printf '%s\n' "$menu_block" | grep -c 'run-shell -b' || true)
seps=$(printf '%s\n' "$menu_block" | grep -cE "^ +'' " || true)
want=$(( entries + seps + 2 ))
have=$(grep -oE '^ *MENU_ROWS=[0-9]+' "$SCRIPT" | head -1 | grep -oE '[0-9]+' || true)

if [ -n "$have" ] && [ "$have" = "$want" ]; then
  report "MENU_ROWS ($have) matches the menu it guards ($entries entries + $seps separators + 2 borders)" pass
else
  report "MENU_ROWS ($have) matches the menu it guards (wanted $want: $entries entries + $seps separators + 2 borders)" fail
fi

# --- Health actually opens, and shows the report -------------------------------
# The entry is only worth having if the key reaches the report; a menu row that
# opens an empty popup is worse than no row.
cap=$(dash_pick 100 40 h 'interdimux doctor' || true)
if printf '%s\n' "$cap" | grep -q 'interdimux doctor'; then
  report "the Health key opens the report in a popup" pass
else
  report "the Health key opens the report in a popup" fail
  ERRORS+="$(printf '%s\n' "$cap" | grep -v '^ *$' | head -5 | sed 's/^/      /')"$'\n'
fi
if printf '%s\n' "$cap" | grep -qE 'health ❯|recheck'; then
  report "...paged, so a report longer than the popup can be read" pass
else
  report "...paged, so a report longer than the popup can be read" fail
fi

# --- the fallback popup's height tracks its own item list ----------------------
# The same shape as the MENU_ROWS check, and for the same reason: the entry added
# LAST is the one a too-short popup scrolls off, so the constant has to move with
# the list.  The 5 is measured — border(2) + prompt + the rule under it + the
# hint bar — and confirmed by rendering: 11 entries fit at -h 16 and not at 15.
items_block=$(awk '/^  items=\$\(printf/,/\)$/' "$SCRIPT")
fb_entries=$(printf '%s\n' "$items_block" | grep -cE '^ +"[a-z]+" +"' || true)
fb_have=$(grep -oE '_pop_w=[0-9]+ _pop_h=[0-9]+' "$SCRIPT" | grep -oE '_pop_h=[0-9]+' | grep -oE '[0-9]+' || true)
fb_want=$(( fb_entries + 5 ))
if [ -n "$fb_have" ] && [ "$fb_entries" -ge 10 ] && [ "$fb_have" = "$fb_want" ]; then
  report "the fallback popup height ($fb_have) fits its $fb_entries entries exactly" pass
else
  report "the fallback popup height ($fb_have) fits its $fb_entries entries (wanted $fb_want)" fail
fi

# --- ^r really re-runs the checks ---------------------------------------------
# The binding is the reason the popup is worth having over a one-shot print: you
# fix something and look again.  Asserted by CHANGING the server between the two
# renders — a capture that merely still contains the report would pass with the
# binding deleted.
recheck() {
  local i
  local out="$SOCK-rc-o" in="$SOCK-rc-i"
  tmux -f /dev/null -L "$out" new-session -d -s drv -x 100 -y 40 \
    "tmux -f /dev/null -L '$in' new-session -s host" 2>/dev/null || return 1
  for i in $(seq 1 80); do
    tmux -L "$in" list-clients >/dev/null 2>&1 && break
    sleep 0.15
  done
  env -u TMUX_PANE \
      TMUX="$(tmux -L "$in" display-message -p '#{socket_path}' 2>/dev/null),99999,0" \
      INTERDIMUX_OPTS_PRIMED=1 \
      bash "$SCRIPT" --dashboard-launch >/dev/null 2>&1 &
  for i in $(seq 1 80); do
    tmux -L "$out" capture-pane -t '=drv:' -p 2>/dev/null | grep -q 'Switch' && break
    sleep 0.15
  done
  tmux -L "$out" send-keys -t '=drv:' h 2>/dev/null || true
  for i in $(seq 1 160); do
    tmux -L "$out" capture-pane -t '=drv:' -p 2>/dev/null | grep -q 'interdimux doctor' && break
    sleep 0.15
  done
  # The marker is the problem COUNT in the verdict, on the report's third line —
  # the detail it comes from is near the bottom of a report that scrolls, and the
  # mere PRESENCE of the verdict says nothing, since this harness starts with
  # problems of its own (no key bindings, for one).  An invalid option adds
  # exactly one, so the number must go up.
  nprob() {
    tmux -L "$out" capture-pane -t '=drv:' -p 2>/dev/null \
      | grep -oE '[0-9]+ problems? need' | grep -oE '^[0-9]+' | head -1
  }
  RC_BEFORE=$(nprob || true)
  tmux -L "$in" set -g @interdimux-order sideways 2>/dev/null || true
  tmux -L "$out" send-keys -t '=drv:' C-r 2>/dev/null || true
  for i in $(seq 1 160); do
    [ "$(nprob || true)" != "$RC_BEFORE" ] && break
    sleep 0.15
  done
  RC_AFTER=$(nprob || true)
  tmux -L "$in" kill-server 2>/dev/null || true
  tmux -L "$out" kill-server 2>/dev/null || true
  return 0
}
RC_BEFORE="" RC_AFTER=""
recheck || true
if [ -n "$RC_BEFORE" ] && [ -n "$RC_AFTER" ] && [ "$RC_AFTER" -gt "$RC_BEFORE" ]; then
  report "^r re-runs the checks against the current state ($RC_BEFORE -> $RC_AFTER problems)" pass
else
  report "^r re-runs the checks against the current state (before='$RC_BEFORE' after='$RC_AFTER')" fail
fi

# --- the fallback popup's own height ------------------------------------------
# On tmux < 3.4 the fzf dashboard is taken at ANY client height, so its constant
# binds where the clamp does not: a client of 40 rows gets the popup at its full
# height, and an entry past that height is simply not on screen.  This is the
# only configuration in which _pop_h is observable at all — everywhere else the
# clamp to the client size hides it.
cap=$(dash_capture 100 40 303 || true)
if printf '%s\n' "$cap" | grep -q 'interdimux ❯'; then
  report "tmux < 3.4 takes the fzf dashboard even on a tall client" pass
else
  report "tmux < 3.4 takes the fzf dashboard even on a tall client" fail
fi
missing=""
for entry in Switch 'New session' Rename Kill Swap Zoom Detach 'Send keys' Schedule Jobs Health; do
  printf '%s\n' "$cap" | grep -q "$entry" || missing+=" $entry"
done
if [ -z "$missing" ]; then
  report "...and every entry fits in it, the last one included" pass
else
  report "...and every entry fits in it (off screen:$missing)" fail
fi

# --- what --doctor says about which dashboard you are about to get ------------
# The doctor suite cannot reach these arms: it attaches no client, so
# client_dim reads 0 and the report can only say it could not tell.  Here there
# are clients of known height.
doctor_dash() { # $1 = outer client rows -> the one line about the dashboard
  local h="$1" i
  local out="$SOCK-dd-o-$h" in="$SOCK-dd-i-$h"
  tmux -f /dev/null -L "$out" new-session -d -s drv -x 90 -y "$h" \
    "tmux -f /dev/null -L '$in' new-session -s host" 2>/dev/null || return 0
  for i in $(seq 1 80); do
    tmux -L "$in" list-clients >/dev/null 2>&1 && break
    sleep 0.15
  done
  env -u TMUX_PANE \
      TMUX="$(tmux -L "$in" display-message -p '#{socket_path}' 2>/dev/null),99999,0" \
      INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
      INTERDIMUX_AT_DAEMON=up \
      bash "$SCRIPT" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -iE 'native menu|falls back to the fzf popup|could not be checked' | head -1
  tmux -L "$in" kill-server 2>/dev/null || true
  tmux -L "$out" kill-server 2>/dev/null || true
}
# Heights, not exact rows: the inner client is one short of the outer pane
# because of tmux's own status line, so what is asserted is the BRANCH.
line=$(doctor_dash 40 || true)
case "$line" in
  *"native menu"*) report "--doctor tells a tall client it gets the native menu" pass ;;
  *) report "--doctor tells a tall client it gets the native menu (got: $line)" fail ;;
esac
line=$(doctor_dash 12 || true)
case "$line" in
  *"falls back to the fzf popup"*) report "...and a short one that it falls back" pass ;;
  *) report "...and a short one that it falls back (got: $line)" fail ;;
esac

printf '\nResults: %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"

exit "$FAIL"
