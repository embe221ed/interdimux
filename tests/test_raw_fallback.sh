#!/usr/bin/env bash
#
# Raw mode on the FALLBACK callback path: a user's own --with-shell in
# @interdimux-fzf-opts (fzf >= 0.74).  The inline snippets are off there, so
# every bar update is a re-exec of this whole script (--footer-for), and the
# raw-mode `result` bind fires on every keystroke and every reload.
#
#   the cost   - that bind used to run, per keystroke, a synchronous
#                `<user shell> -c "sh -c '<guard>'"` (two shells) and then an
#                unconditional background --footer-for, although `focus`
#                already rewrites the bar whenever the row changes.  Only the
#                zero-match state needs `result` to touch the bar (the cursor
#                sits on a dimmed row and focus does not fire), so the guard
#                now asks for --footer-for itself, only at zero matches and on
#                the keystroke that leaves them; and it runs in the user's
#                shell directly when that is a POSIX-family shell.
#   the result - with those re-execs gone, the bar must still announce the
#                create at zero matches, re-describe each fruitless keystroke,
#                and bring the row hints back with the matches -- in bash, in
#                zsh, and (through the sh -c wrapper, kept for shells that may
#                not speak POSIX, like fish) in a shell it does not recognise.
#   the reload - ...and after a reload that leaves the cursor's row number
#                alone but slides a different KIND of row under it (a ^x that
#                takes a window down to one pane), where focus does not fire:
#                the bar must follow the row, not keep the killed one's hints.
#
# Oracle for the cost: every process is counted where it starts, by a `bash`
# and an `sh` on PATH that log their argv and fzf's environment and then exec
# the real ones.  Never the script's own view of what it forked.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-rawfb-test-$$"
OUTER="" OUTERS=()   # a fresh outer server per launch, see new_outer
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-rawfb.XXXXXX")"
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
skip() { printf '  - %s (skipped: %s)\n' "$1" "$2"; }
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

echo "interdimux raw-mode fallback-path tests"
echo

fzf_minor=$(fzf --version 2>/dev/null | awk '{print $1}' | cut -d. -f2)
if [ "${fzf_minor:-0}" -lt 74 ]; then
  echo "  (skipped: raw mode needs fzf >= 0.74, found ${fzf_minor:-?})"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

# --- the shims -------------------------------------------------------------------
# One log line per process start: program, FZF_KEY, FZF_QUERY, FZF_MATCH_COUNT,
# argv.  Real binaries by absolute path, so a shim never finds itself.
REAL_BASH=$(command -v bash) REAL_SH=$(command -v sh)
mkdir -p "$TMPD/shim"
LOG="$TMPD/exec.log"
: > "$LOG"
for prog in bash sh; do
  real="$REAL_BASH"; [ "$prog" = sh ] && real="$REAL_SH"
  cat > "$TMPD/shim/$prog" <<SHIM
#!$REAL_BASH
a="\$*"; a="\${a//\$'\n'/ }"
printf '%s\t%s\t%s\t%s\t%s\n' $prog "\${FZF_KEY-}" "\${FZF_QUERY-}" "\${FZF_MATCH_COUNT-}" "\$a" >> '$LOG'
exec '$real' "\$@"
SHIM
  chmod +x "$TMPD/shim/$prog"
done
# A shell the navigator cannot know speaks POSIX (it is bash underneath, so
# the wrapped guard still runs).
printf '#!%s\nexec %q "$@"\n' "$REAL_BASH" "$REAL_BASH" > "$TMPD/shim/mysh"
chmod +x "$TMPD/shim/mysh"

# --- the fixture -----------------------------------------------------------------
mkdir -p "$TMPD/cwd" "$TMPD/home" "$TMPD/state" "$TMPD/data"
tmux -f /dev/null -L "$SOCK" new-session -d -s alpha -x 120 -y 24 -c "$TMPD/cwd" 'sleep 3600'
tmux -L "$SOCK" new-session -d -s beta  -x 120 -y 24 -c "$TMPD/cwd" 'sleep 3600'
tmux -L "$SOCK" new-session -d -s gamma -x 120 -y 24 -c "$TMPD/cwd" 'sleep 3600'
INNER_TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
INNER_PANE="$(tmux -L "$SOCK" list-panes -t '=alpha:0' -F '#{pane_id}' | head -1)"

launch() { # $1 = the --with-shell value
  local sh="$TMPD/launch.sh" i
  {
    printf '#!%s\n' "$REAL_BASH"
    printf 'export TMUX=%q TMUX_PANE=%q HOME=%q\n' "$INNER_TMUX" "$INNER_PANE" "$TMPD/home"
    printf 'export XDG_STATE_HOME=%q XDG_DATA_HOME=%q\n' "$TMPD/state" "$TMPD/data"
    printf 'export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_FZF_MINOR=74\n'
    printf 'export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_PREVIEW=off\n'
    printf 'export INTERDIMUX_ORDER=index INTERDIMUX_RAW=on FZF_DEFAULT_OPTS=\n'
    printf 'export INTERDIMUX_FZF_OPTS=%q\n' "--with-shell='$1'"
    printf 'export PATH=%q\n' "$TMPD/shim:$PATH"
    printf '%q %q\n' "$REAL_BASH" "$SCRIPT"
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
cur_row() { { screen | grep -m1 '▌' || true; } | sed 's/  */ /g'; }
# The screen stopped changing: the same capture for 1.2 s running (bounded).
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
# Log lines after line $1 matching an awk condition over the fields
# (prog key query count argv).
log_after() { # $1 = line number, $2 = awk condition
  awk -F '\t' -v from="$1" "NR > from && ($2)" "$LOG"
}
wait_log() { # $1 = line number, $2 = awk condition
  local i
  for i in $(seq 1 100); do
    [ -n "$(log_after "$1" "$2")" ] && return 0
    sleep 0.1
  done
  return 1
}
GUARD='index($5, "INTERDIMUX_QUERY_STATE") > 0'
FOOTER='index($5, "--footer-for") > 0'

# --- the cost of a keystroke that keeps matching --------------------------------
# The cursor starts on row 1, alpha, and `a l p` narrow the query onto alpha:
# change:first and the guard's `best` both leave the cursor where it is, so
# `focus` never fires and nothing about the bar changes.  Any --footer-for in
# that stretch is the `result` bind's own.  Then Down, whose focus
# --footer-for is the marker that everything before it has been started.
if launch 'bash -c'; then
  settle > /dev/null
  mark=$(wc -l < "$LOG")
  for q in a al alp; do
    keys "${q: -1}"
    wait_query "$q" ' [1-9][0-9]*/' || true
  done
  wait_log "$mark" "$GUARD && \$3 == \"alp\"" || true
  if [[ "$(cur_row)" != *'▸ alpha'* ]]; then
    report "the cost case: the cursor stays on alpha while the query narrows (fixture)" fail
    ERRORS+="    cursor on: $(cur_row)"$'\n'
  else
    keys Down
    if wait_log "$mark" "$FOOTER && \$2 == \"down\""; then
      n=$(log_after "$mark" "$FOOTER && \$2 != \"down\"" | wc -l)
      if [ "$n" = 0 ]; then
        report "a keystroke that keeps matching re-execs no --footer-for" pass
      else
        report "a keystroke that keeps matching re-execs no --footer-for ($n processes for 3 keys)" fail
      fi
      n=$(log_after "$mark" "\$1 == \"sh\" && $GUARD" | wc -l)
      if [ "$n" = 0 ]; then
        report "under --with-shell='bash -c' the guard runs in bash, with no sh -c inside" pass
      else
        report "under --with-shell='bash -c' the guard runs in bash, with no sh -c inside ($n sh for 3 keys)" fail
      fi
      g=$(log_after "$mark" "\$1 == \"bash\" && $GUARD && \$2 != \"down\"" | wc -l)
      if [ "$g" -ge 3 ]; then
        report "...while the guard itself still ran on each keystroke ($g)" pass
      else
        report "...while the guard itself still ran on each keystroke ($g)" fail
      fi
    else
      report "Down re-execs --footer-for through focus (the marker)" fail
    fi
  fi
else
  report "the navigator opens under --with-shell='bash -c'" fail
fi

# --- the bar at zero matches, in each kind of shell ------------------------------
SHELLS=("bash -c" "mysh -c")
if command -v zsh >/dev/null 2>&1; then SHELLS+=("zsh -c"); else skip "zsh -c" "zsh is not installed"; fi
for ws in "${SHELLS[@]}"; do
  if ! launch "$ws"; then
    report "[$ws] the navigator opens" fail
    continue
  fi
  mark=$(wc -l < "$LOG")
  # The guard still moves the cursor: `bet` lands on beta.
  keys 'bet'
  wait_query 'bet' ' [1-9][0-9]*/' || true
  for _i in $(seq 1 50); do [[ "$(cur_row)" == *'▸ beta'* ]] && break; sleep 0.1; done
  [[ "$(cur_row)" == *'▸ beta'* ]] \
    && report "[$ws] typing a query still puts the cursor on its match" pass \
    || report "[$ws] typing a query still puts the cursor on its match" fail
  keys 'q'
  wait_query 'betq' ' 0/' || true
  s=$(settle)
  if printf '%s' "$s" | grep -qF 'create betq in' && ! printf '%s' "$s" | grep -qF 'enter switch'; then
    report "[$ws] the keystroke that empties the list announces the create" pass
  else
    report "[$ws] the keystroke that empties the list announces the create" fail
    ERRORS+="    bar: $(printf '%s\n' "$s" | grep -E 'create|enter|switch' | head -1 | sed 's/^ *//')"$'\n'
  fi
  keys 'z'
  wait_query 'betqz' ' 0/' || true
  s=$(settle)
  if printf '%s' "$s" | grep -qF 'create betqz in'; then
    report "[$ws] a further fruitless keystroke re-describes the new query" pass
  else
    report "[$ws] a further fruitless keystroke re-describes the new query" fail
  fi
  keys BSpace BSpace
  wait_query 'bet' ' [1-9][0-9]*/' || true
  s=$(settle)
  if printf '%s' "$s" | grep -qF 'enter switch' && ! printf '%s' "$s" | grep -qF 'create bet'; then
    report "[$ws] the row hints return with the matches" pass
  else
    report "[$ws] the row hints return with the matches" fail
  fi
  # The same round trip with the cursor never moving: on row 1, under a query
  # whose best match is row 1, change:first and `best` both leave it there, so
  # focus fires neither way and the keystroke that LEAVES zero matches is the
  # only thing that can put the row hints back.
  keys C-u
  wait_query '' ' [1-9][0-9]*/' || true
  keys 'alp'
  wait_query 'alp' ' [1-9][0-9]*/' || true
  keys 'q'
  wait_query 'alpq' ' 0/' || true
  s=$(settle)
  if printf '%s' "$s" | grep -qF 'create alpq in'; then
    keys BSpace
    wait_query 'alp' ' [1-9][0-9]*/' || true
    s=$(settle)
    if [[ "$(cur_row)" == *'▸ alpha'* ]] && printf '%s' "$s" | grep -qF 'enter switch' \
       && ! printf '%s' "$s" | grep -qF 'create alp'; then
      report "[$ws] the row hints return under an unmoved cursor" pass
    else
      report "[$ws] the row hints return under an unmoved cursor" fail
      ERRORS+="    cursor: $(cur_row)"$'\n'"    bar: $(printf '%s\n' "$s" | grep -E 'create|enter|switch' | head -1 | sed 's/^ *//')"$'\n'
    fi
  else
    report "[$ws] the create is announced for alpq (fixture)" fail
  fi
  # Which shell ran the guard: the unknown one keeps the sh -c wrapper.
  n=$(log_after "$mark" "\$1 == \"sh\" && $GUARD" | wc -l)
  case "$ws" in
    mysh*) [ "$n" -gt 0 ] && report "[$ws] an unknown shell still gets the guard through sh -c" pass \
                          || report "[$ws] an unknown shell still gets the guard through sh -c" fail ;;
    *)     [ "$n" = 0 ] && report "[$ws] the guard runs in the shell itself, no sh -c" pass \
                        || report "[$ws] the guard runs in the shell itself, no sh -c ($n)" fail ;;
  esac
  tmux -L "$OUTER" kill-server 2>/dev/null || true
done

# --- the bar after a reload that slides a new row type under the cursor ----------
# fzf fires `focus` only when the cursor's row NUMBER changes, and a reload
# keeps the number.  Kill the first of delta's two panes: the window is left
# with one pane, both pane rows go, and the row that slides under the unmoved
# cursor is gamma -- a session.  focus stays silent, so only the `result` bind
# can rewrite the bar, and it used to do that only around zero matches: the
# session row kept the dead pane's hints (^z zoom, ^s swap, ^t send).
tmux -L "$SOCK" new-session -d -s delta -x 120 -y 24 -c "$TMPD/cwd" 'sleep 3600'
tmux -L "$SOCK" split-window -t '=delta:0' -c "$TMPD/cwd" 'sleep 3602'
if launch 'bash -c'; then
  settle > /dev/null
  # Down one row at a time, each step waiting for the cursor to leave the row
  # it was on (every row reads differently).
  for _i in $(seq 1 30); do
    r0=$(cur_row)
    [[ "$r0" == *'├╴ delta 0.0'* ]] && break
    keys Down
    for _j in $(seq 1 40); do [ "$(cur_row)" != "$r0" ] && break; sleep 0.05; done
  done
  if [[ "$(cur_row)" != *'├╴ delta 0.0'* ]]; then
    report "the cursor reaches delta's first pane row (fixture)" fail
    ERRORS+="    cursor on: $(cur_row)"$'\n'
  else
    s=$(settle)
    if ! printf '%s' "$s" | grep -qF '^z zoom'; then
      report "a pane row shows the pane hints (fixture)" fail
    else
      keys C-x
      for _i in $(seq 1 100); do screen | grep -qF "Kill pane" && break; sleep 0.1; done
      keys y
      for _i in $(seq 1 100); do
        tmux -L "$SOCK" list-panes -t '=delta:0' 2>/dev/null | wc -l | grep -qx 1 \
          && ! screen | grep -qF 'delta 0.1' && break
        sleep 0.1
      done
      s=$(settle)
      row=$(cur_row)
      if [[ "$row" == *'▸ gamma'* ]] && printf '%s' "$s" | grep -qF '^d detach' \
         && ! printf '%s' "$s" | grep -qF '^z zoom'; then
        report "a kill that slides a session row under the cursor shows the session hints" pass
      else
        report "a kill that slides a session row under the cursor shows the session hints" fail
        ERRORS+="    cursor: $row"$'\n'"    bar: $(printf '%s\n' "$s" | grep -E 'enter' | head -1 | sed 's/^ *//')"$'\n'
      fi
    fi
  fi
  tmux -L "$OUTER" kill-server 2>/dev/null || true
else
  report "the navigator opens for the kill case" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
