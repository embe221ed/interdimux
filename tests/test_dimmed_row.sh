#!/usr/bin/env bash
#
# Raw mode: a dimmed row is never a target.
#
# With raw mode on, a query dims the rows it does not match instead of removing
# them, and Up/Down still walk the cursor onto them.  The README promises that
# a dimmed row is never acted on, and at zero matches that held -- the row keys
# only said so (tests/test_zero_match.sh).  But with a match anywhere else,
# every key acted on the dimmed row under the cursor: ^x opened a kill dialog
# for a session the query had excluded, ^z zoomed a dimmed pane with no dialog
# at all, and Enter switched to it.
#
# fzf exports FZF_RAW to its children in raw mode: 1 when the current row
# matches, 0 when it does not -- or when there is no current row, which
# FZF_CURRENT_ITEM tells apart.  The keys dispatch on it inside fzf, so the
# guarded key writes its own bar text, and that text is the positive
# discriminator: a dialog would have replaced the screen, and an accepted Enter
# would have closed the picker.
#
# Both callback paths: the inline one (fzf runs the snippets in `sh -c`) and
# the fallback one (the user's own --with-shell, here bash).
#
# Needs a real client: send-keys writes to a pane's pty rather than driving
# fzf, so an outer tmux runs the picker and the picker lists an inner server.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-dimrow-test-$$"
OUTER="" OUTERS=()   # a fresh outer server per launch, see new_outer
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-dimrow.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  local o
  for o in ${OUTERS[@]+"${OUTERS[@]}"}; do tmux -L "$o" kill-server 2>/dev/null || true; done
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$TMPD"
}
trap cleanup EXIT

new_outer() {
  [ -n "$OUTER" ] && tmux -L "$OUTER" kill-server 2>/dev/null || true
  OUTER="${SOCK}-o$(( ${#OUTERS[@]} + 1 ))"
  OUTERS+=("$OUTER")
}

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

echo "interdimux dimmed-row tests"
echo

fzf_minor=$(fzf --version 2>/dev/null | awk '{print $1}' | cut -d. -f2)
if [ "${fzf_minor:-0}" -lt 74 ]; then
  echo "  (skipped: raw mode needs fzf >= 0.74, found ${fzf_minor:-?})"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

# --- the fixture ---------------------------------------------------------------
# Every pane runs `sleep`, and --nth matches the identity and command columns
# only, so `gam` matches gamma's two rows and nothing of alpha's or beta's.
mkdir -p "$TMPD/cwd" "$TMPD/home" "$TMPD/state" "$TMPD/data"
tmux -f /dev/null -L "$SOCK" new-session -d -s alpha -x 120 -y 24 -c "$TMPD/cwd" 'sleep 3600'
tmux -L "$SOCK" new-session -d -s beta  -x 120 -y 24 -c "$TMPD/cwd" 'sleep 3600'
tmux -L "$SOCK" split-window -t '=beta:0' -c "$TMPD/cwd" 'sleep 3601'
tmux -L "$SOCK" new-session -d -s gamma -x 120 -y 24 -c "$TMPD/cwd" 'sleep 3600'
INNER_TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
INNER_PANE="$(tmux -L "$SOCK" list-panes -t '=alpha:0' -F '#{pane_id}' | head -1)"

launch() { # $1 = extra `export …` line (may be empty)
  local sh="$TMPD/launch.sh" i
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export TMUX=%q TMUX_PANE=%q HOME=%q\n' "$INNER_TMUX" "$INNER_PANE" "$TMPD/home"
    printf 'export XDG_STATE_HOME=%q XDG_DATA_HOME=%q\n' "$TMPD/state" "$TMPD/data"
    printf 'export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_FZF_MINOR=74\n'
    printf 'export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_PREVIEW=off\n'
    printf 'export INTERDIMUX_ORDER=index INTERDIMUX_RAW=on FZF_DEFAULT_OPTS=\n'
    printf '%s\n' "$1"
    printf 'bash %q\n' "$SCRIPT"
  } > "$sh"
  chmod +x "$sh"
  new_outer
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 120 -y 24 "$sh; sleep 45"
  for i in $(seq 1 150); do
    screen | grep -q '▸ gamma' && return 0
    sleep 0.1
  done
  return 1
}
screen()  { tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | plain || true; }
keys()    { tmux -L "$OUTER" send-keys -t '=drv:' "$@"; }
cur_row() { { screen | grep -m1 '▌' || true; } | sed 's/  */ /g'; }
# The same capture for 1.2 s running (bounded at 10 s).
settle() {
  local i same=0 prev="" cur
  for i in $(seq 1 100); do
    cur=$(screen)
    if [ "$cur" = "$prev" ]; then
      same=$((same + 1))
      [ "$same" -ge 12 ] && break
    else
      same=0; prev="$cur"
    fi
    sleep 0.1
  done
  printf '%s' "$cur"
}
wait_query() { # $1 = query, $2 = regex the prompt line must also match
  local i
  for i in $(seq 1 100); do
    screen | head -1 | grep -F -- "❯ $1" | grep -qE -- "${2:-.}" && return 0
    sleep 0.1
  done
  return 1
}
wait_text() { # $1 = fixed text that must appear on screen (bounded)
  local i
  for i in $(seq 1 100); do
    screen | grep -qF -- "$1" && return 0
    sleep 0.1
  done
  return 1
}
wait_cursor() { # $1 = fixed text the cursor row must contain (bounded)
  local i
  for i in $(seq 1 100); do
    [[ "$(cur_row)" == *"$1"* ]] && return 0
    sleep 0.05
  done
  return 1
}
# The bar goes back to the row's hints: move off the row and back.  Then the
# next guarded key's text is new on screen, not a leftover.
reset_bar() { # $1 = row the cursor must be back on
  keys Down; wait_cursor '▸ gamma' || true
  keys Up;   wait_cursor "$1" || true
  wait_text 'enter switch' || true
}
DIMMSG='this row does not match'

PATHS=("inline" "fallback")
for path in "${PATHS[@]}"; do
  extra=""
  [ "$path" = fallback ] && extra="export INTERDIMUX_FZF_OPTS=\"--with-shell='bash -c'\""
  if ! launch "$extra"; then
    report "[$path] the navigator opens in raw mode" fail
    continue
  fi
  settle > /dev/null
  # `gam` lands the cursor on gamma, the best match; Up puts it on beta's last
  # pane row, which the query excluded.
  keys 'gam'
  wait_query 'gam' ' 2/' || true
  wait_cursor '▸ gamma' || true
  settle > /dev/null
  keys Up
  if ! wait_cursor '└╴ beta 0.1'; then
    report "[$path] Up puts the cursor on a dimmed row (fixture)" fail
    ERRORS+="    cursor on: $(cur_row)"$'\n'
    tmux -L "$OUTER" kill-server 2>/dev/null || true
    continue
  fi
  settle > /dev/null

  # ^z: no dialog, so it is the one that acts silently -- tmux is the oracle.
  z0=$(tmux -L "$SOCK" display-message -p -t '=beta:0' '#{window_zoomed_flag}')
  keys C-z
  if wait_text "$DIMMSG"; then
    z1=$(tmux -L "$SOCK" display-message -p -t '=beta:0' '#{window_zoomed_flag}')
    if [ "$z0" = 0 ] && [ "$z1" = 0 ]; then
      report "[$path] ^z on a dimmed pane row zooms nothing" pass
    else
      report "[$path] ^z on a dimmed pane row zooms nothing ($z0 -> $z1)" fail
    fi
  else
    report "[$path] ^z on a dimmed pane row zooms nothing (no guard text)" fail
    z1=$(tmux -L "$SOCK" display-message -p -t '=beta:0' '#{window_zoomed_flag}')
    [ "$z1" = 1 ] && tmux -L "$SOCK" resize-pane -Z -t '=beta:0' 2>/dev/null || true
  fi

  # ^x: the dialog would take the screen over.
  reset_bar '└╴ beta 0.1'
  keys C-x
  if wait_text "$DIMMSG" && ! screen | grep -qF 'Kill '; then
    report "[$path] ^x on a dimmed row opens no kill dialog" pass
  else
    report "[$path] ^x on a dimmed row opens no kill dialog" fail
    screen | grep -qF 'Kill ' && keys n
  fi

  # Enter: an accept would close the picker.
  reset_bar '└╴ beta 0.1'
  keys Enter
  if wait_text "$DIMMSG" && screen | grep -qF '▸ gamma'; then
    report "[$path] Enter on a dimmed row does not switch to it" pass
  else
    report "[$path] Enter on a dimmed row does not switch to it" fail
    ERRORS+="    screen: $(screen | head -3 | tr '\n' '|')"$'\n'
  fi

  if tmux -L "$SOCK" has-session -t '=alpha' 2>/dev/null \
     && tmux -L "$SOCK" has-session -t '=beta' 2>/dev/null \
     && [ "$(tmux -L "$SOCK" list-panes -t '=beta:0' | wc -l)" = 2 ]; then
    report "[$path] nothing was killed" pass
  else
    report "[$path] nothing was killed" fail
  fi

  # The control: under the same query, the MATCHING row still takes the keys.
  if screen | grep -qF '▸ gamma'; then
    keys Down
    wait_cursor '▸ gamma' || true
    keys C-e
    if wait_text "Rename "; then
      report "[$path] with a query, ^e on a matching row still opens its dialog" pass
      keys Escape
      for _i in $(seq 1 50); do screen | grep -qF 'Rename ' || break; sleep 0.1; done
    else
      report "[$path] with a query, ^e on a matching row still opens its dialog" fail
    fi
    wait_query 'gam' ' 2/' || true
    wait_cursor '▸ gamma' || true
    settle > /dev/null
    keys Enter
    gone=1
    for _i in $(seq 1 100); do screen | grep -qF '▸ gamma' || { gone=0; break; }; sleep 0.1; done
    [ "$gone" = 0 ] && report "[$path] with a query, Enter on a matching row still accepts it" pass \
                    || report "[$path] with a query, Enter on a matching row still accepts it" fail
  fi
  tmux -L "$OUTER" kill-server 2>/dev/null || true
done

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
