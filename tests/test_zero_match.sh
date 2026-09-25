#!/usr/bin/env bash
#
# The zero-match state: a query that matches nothing.  Enter creates a session
# there (find-or-create), so two things have to hold, in every mode the
# navigator can run in:
#
#   the bar says so   - "create <query> in <dir>", not a row's hints.  It used
#                       to, only with raw mode on: with raw off, or on any fzf
#                       below 0.74, the `focus` bind fired after the `result`
#                       bind that announced the create and overwrote it with
#                       the generic "enter switch …" ladder (on fzf >= 0.63 its
#                       bg-cancel also killed the announcement outright).  So
#                       the bar promised a switch while Enter created a session.
#   the row keys don't act
#                     - in raw mode the rows stay on screen, dimmed, with the
#                       cursor on one of them, and fzf ran ^x/^e/^z against it:
#                       a kill dialog for a session the query had excluded, and
#                       ^z zoomed one with no dialog at all.
#
# The modes are real fzf code paths, picked with INTERDIMUX_FZF_MINOR on the
# installed fzf (>= 0.74 accepts every tier's flags): the bg- inline path, the
# synchronous inline path (< 0.63, a header), the fallback path that re-execs
# --footer-for (< 0.51, or a user-supplied --with-shell), and raw on and off.
#
# Needs a real client: send-keys writes to a pane's pty rather than driving
# fzf, so an outer tmux runs the picker and the picker lists an inner server.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-zero-test-$$"
OUTER="" OUTERS=()   # a fresh outer server per launch, see new_outer
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-zero.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

# OUTER first: it owns the pane the navigator runs in, and the navigator talks
# to $SOCK.
cleanup() {
  local o
  for o in ${OUTERS[@]+"${OUTERS[@]}"}; do tmux -L "$o" kill-server 2>/dev/null || true; done
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$TMPD"
}
trap cleanup EXIT

# Each launch gets a NEW outer server rather than killing and re-creating one
# on the same socket: under load the old server can still be shutting down when
# the next new-session connects, and that failure takes the suite down.
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

echo "interdimux zero-match tests"
echo

fzf_minor=$(fzf --version 2>/dev/null | awk '{print $1}' | cut -d. -f2)
if [ "${fzf_minor:-0}" -lt 74 ]; then
  echo "  (skipped: needs fzf >= 0.74 to emulate every tier, found ${fzf_minor:-?})"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

# --- the fixture ---------------------------------------------------------------
# Every pane runs `sleep`, so the command column (which --nth matches) is known
# and no shell rc can put arbitrary text in it: nothing below contains a `q`.
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
    printf 'export FZF_DEFAULT_OPTS=\n'
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
screen() { tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | plain || true; }
keys()   { tmux -L "$OUTER" send-keys -t '=drv:' "$@"; }

# Wait for the screen to STOP changing and print it.  The bar is written by
# transforms that may run in the background, so "the text appeared" is not "the
# text stayed": the defect this suite guards was a second write landing after
# the first.  Settled = the same capture for 1.2 s running; bounded at 10 s.
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
# The prompt line carries the query; the count on it says the search is done.
wait_query() { # $1 = query, $2 = regex the prompt line must also match
  local i
  for i in $(seq 1 100); do
    screen | head -1 | grep -F -- "❯ $1" | grep -qE -- "${2:-.}" && return 0
    sleep 0.1
  done
  return 1
}
wait_text() { # $1 = fixed string
  local i
  for i in $(seq 1 100); do
    screen | grep -qF -- "$1" && return 0
    sleep 0.1
  done
  return 1
}

# --- the bar at zero matches, in every mode ------------------------------------
USER_SHELL="export INTERDIMUX_FZF_OPTS=\"--with-shell='bash -c'\""
MODES=(
  "raw on|export INTERDIMUX_RAW=on"
  "raw off|export INTERDIMUX_RAW=off"
  "fzf 0.62 tier: synchronous inline, a header|export INTERDIMUX_FZF_MINOR=62"
  "fzf 0.50 tier: the --footer-for fallback|export INTERDIMUX_FZF_MINOR=50"
  "user --with-shell, raw off|$USER_SHELL INTERDIMUX_RAW=off"
  "user --with-shell, raw on|$USER_SHELL INTERDIMUX_RAW=on"
)
for m in "${MODES[@]}"; do
  label="${m%%|*}" env_line="${m#*|}"
  if ! launch "$env_line"; then
    report "[$label] the navigator opens" fail
    continue
  fi
  # `bet` matches beta; the q is the keystroke that empties the list -- the
  # transition is where the two binds race, so it must be ONE keystroke.
  keys 'bet'
  wait_query 'bet' ' [1-9][0-9]*/' || true
  keys 'q'
  wait_query 'betq' ' 0/' || true
  s=$(settle)
  if printf '%s' "$s" | grep -qF 'create betq in' && ! printf '%s' "$s" | grep -qF 'enter switch'; then
    report "[$label] the keystroke that empties the list leaves the create announcement" pass
  else
    report "[$label] the keystroke that empties the list leaves the create announcement" fail
    ERRORS+="    bar: $(printf '%s\n' "$s" | grep -E 'create|enter|switch' | head -1 | sed 's/^ *//')"$'\n'
  fi
  # A further keystroke that is still fruitless must re-describe the NEW query:
  # on the fallback path nothing but a `zero` bind sees it (focus does not fire
  # again, the current item is still none).
  keys 'z'
  wait_query 'betqz' ' 0/' || true
  s=$(settle)
  if printf '%s' "$s" | grep -qF 'create betqz in'; then
    report "[$label] a further fruitless keystroke re-describes the new query" pass
  else
    report "[$label] a further fruitless keystroke re-describes the new query" fail
    ERRORS+="    bar: $(printf '%s\n' "$s" | grep -E 'create|enter|switch' | head -1 | sed 's/^ *//')"$'\n'
  fi
  # ...and the row hints come back with the matches, the zero-match
  # announcement ("create bet in <dir>") gone.  From fzf 0.63 the bar also
  # names what alt-enter would make while a query is typed ("M-⏎ create bet",
  # review UX-54: no " in <dir>"); below that it must not appear at all.
  keys BSpace BSpace
  wait_query 'bet' ' [1-9][0-9]*/' || true
  s=$(settle)
  case "$env_line" in
    *FZF_MINOR=5[0-9]*|*FZF_MINOR=6[0-2]*)
      printf '%s' "$s" | grep -qF 'enter switch' && ! printf '%s' "$s" | grep -qF 'create bet' ;;
    *)
      printf '%s' "$s" | grep -qF 'enter switch' && printf '%s' "$s" | grep -qF 'M-⏎ create bet' \
        && ! printf '%s' "$s" | grep -qF 'create bet in' ;;
  esac && ok=1 || ok=0
  if [ "$ok" = 1 ]; then
    report "[$label] the row hints return with the matches" pass
  else
    report "[$label] the row hints return with the matches" fail
    ERRORS+="    bar: $(printf '%s\n' "$s" | grep -E 'create|enter|switch' | tail -1 | sed 's/^ *//')"$'\n'
  fi
  tmux -L "$OUTER" kill-server 2>/dev/null || true
done

# --- raw mode: the row keys do nothing at zero matches ---------------------------
# The discriminator is positive, so it needs no "wait and see nothing happened":
# the guarded key writes its own bar text, and a dialog would have replaced it.
if launch "export INTERDIMUX_RAW=on"; then
  keys 'qqqj'
  wait_query 'qqqj' ' 0/' || true
  settle > /dev/null
  cur=$(screen | grep -m1 '▌' || true)

  keys C-x
  if wait_text 'no row to kill'; then
    report "raw, zero matches: ^x says there is nothing to kill" pass
  else
    report "raw, zero matches: ^x says there is nothing to kill" fail
  fi
  if screen | grep -q 'Kill '; then
    report "raw, zero matches: ^x opens no kill dialog" fail
    ERRORS+="    cursor was on: $(printf '%s' "$cur" | sed 's/  */ /g')"$'\n'
    keys Escape
  else
    report "raw, zero matches: ^x opens no kill dialog" pass
  fi

  keys C-e
  if wait_text 'no row to rename' && ! screen | grep -q 'Rename '; then
    report "raw, zero matches: ^e opens no rename dialog" pass
  else
    report "raw, zero matches: ^e opens no rename dialog" fail
    screen | grep -q 'Rename ' && keys Escape
  fi

  # ^z has no dialog at all, so it is the one that used to act silently: put
  # the cursor on one of beta's (dimmed) pane rows and check tmux itself.
  for _i in $(seq 1 20); do
    screen | grep -m1 '▌' | grep -q '╴ beta 0\.' && break
    keys Down
    sleep 0.1
  done
  z0=$(tmux -L "$SOCK" display-message -p -t '=beta:0' '#{window_zoomed_flag}')
  keys C-z
  if wait_text 'no row to zoom'; then
    z1=$(tmux -L "$SOCK" display-message -p -t '=beta:0' '#{window_zoomed_flag}')
    if [ "$z0" = 0 ] && [ "$z1" = 0 ]; then
      report "raw, zero matches: ^z on a dimmed pane row zooms nothing" pass
    else
      report "raw, zero matches: ^z on a dimmed pane row zooms nothing ($z0 -> $z1)" fail
    fi
  else
    report "raw, zero matches: ^z on a dimmed pane row zooms nothing (no guard text)" fail
  fi
  if tmux -L "$SOCK" has-session -t '=alpha' 2>/dev/null \
     && tmux -L "$SOCK" has-session -t '=beta' 2>/dev/null \
     && tmux -L "$SOCK" has-session -t '=gamma' 2>/dev/null; then
    report "raw, zero matches: every session is still there" pass
  else
    report "raw, zero matches: every session is still there" fail
  fi

  # The control: with a match under the cursor the same keys still act.  Clear
  # the query, stand on a pane row of beta, and zoom it for real.
  keys C-u
  wait_query '' ' [1-9][0-9]*/' || true
  for _i in $(seq 1 20); do
    screen | grep -m1 '▌' | grep -q '╴ beta 0\.' && break
    keys Down
    sleep 0.1
  done
  keys C-z
  zoomed=""
  for _i in $(seq 1 50); do
    zoomed=$(tmux -L "$SOCK" display-message -p -t '=beta:0' '#{window_zoomed_flag}')
    [ "$zoomed" = 1 ] && break
    sleep 0.1
  done
  [ "$zoomed" = 1 ] && report "raw, with a match: ^z still zooms the row under the cursor" pass \
                    || report "raw, with a match: ^z still zooms the row under the cursor" fail
  keys C-x
  if wait_text "Kill "; then
    report "raw, with a match: ^x still opens its dialog" pass
    keys n
  else
    report "raw, with a match: ^x still opens its dialog" fail
  fi
  tmux -L "$OUTER" kill-server 2>/dev/null || true
else
  report "the navigator opens in raw mode" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
