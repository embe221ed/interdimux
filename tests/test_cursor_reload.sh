#!/usr/bin/env bash
#
# Raw mode: where the cursor is after a RELOAD.
#
# Raw mode chains `best` into the `result` bind, because with every row still
# displayed nothing else moves the cursor onto a match as you type.  But fzf
# fires `result` after every reload too -- and ^r, ^/, a resize, ^z and every
# confirmed or cancelled ^x/^e/^d/^s/^t end in one.  With an empty query `best`
# is row 1, so each of those threw the cursor to the top: cancel a ^x on gamma,
# press ^x again, and the dialog offered to kill whatever was first.
#
# What must hold: a reload with the query unchanged leaves the cursor where it
# was, with or without a query; a query change still lands on the best match;
# a reload that leaves the cursor on a row the query does not match (a kill
# slid a dimmed one under it) moves it back onto a match; and a reload that
# drops the bottom rows, leaving the cursor past the end, lands it on the new
# last row as raw off does -- or, under a query, on a match.
#
# Each reload is made observable by adding a session to the inner server first:
# `result` actions run before fzf draws the new list, so once the new row is on
# screen the cursor has already been placed.  No fixed sleeps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-cursor-test-$$"
OUTER="" OUTERS=()   # a fresh outer server per launch, see new_outer
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-cursor.XXXXXX")"
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

echo "interdimux cursor-across-reload tests"
echo

fzf_minor=$(fzf --version 2>/dev/null | awk '{print $1}' | cut -d. -f2)
if [ "${fzf_minor:-0}" -lt 74 ]; then
  echo "  (skipped: raw mode needs fzf >= 0.74, found ${fzf_minor:-?})"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

# --- the fixture ---------------------------------------------------------------
# Index order (tmux sorts sessions by name), so a session added as `zz…` lands
# BELOW every row asserted on and cannot shift the cursor's row by itself.
# `cuckoo` has no `a` in it: under the query `a` it is the one dimmed row
# between matches.
mkdir -p "$TMPD/cwd" "$TMPD/home" "$TMPD/state" "$TMPD/data"
for s in alpha beta cuckoo delta gamma; do
  if [ "$s" = alpha ]; then
    tmux -f /dev/null -L "$SOCK" new-session -d -s "$s" -x 120 -y 30 -c "$TMPD/cwd" 'sleep 3600'
  else
    tmux -L "$SOCK" new-session -d -s "$s" -x 120 -y 30 -c "$TMPD/cwd" 'sleep 3600'
  fi
done
INNER_TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
INNER_PANE="$(tmux -L "$SOCK" list-panes -t '=alpha:0' -F '#{pane_id}' | head -1)"
added=0 z=""
add_session() { # a new row at the bottom, to make the next reload visible; sets z
  added=$((added + 1))
  z="zz$added"
  tmux -L "$SOCK" new-session -d -s "$z" -x 120 -y 30 -c "$TMPD/cwd" 'sleep 3600'
}

launch() { # $1 = extra `export …` line (may be empty)
  local sh="$TMPD/launch.sh" i
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export TMUX=%q TMUX_PANE=%q HOME=%q\n' "$INNER_TMUX" "$INNER_PANE" "$TMPD/home"
    printf 'export XDG_STATE_HOME=%q XDG_DATA_HOME=%q\n' "$TMPD/state" "$TMPD/data"
    printf 'export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_FZF_MINOR=74\n'
    printf 'export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_PREVIEW=off\n'
    printf 'export INTERDIMUX_ORDER=index INTERDIMUX_RAW=on FZF_DEFAULT_OPTS=\n'
    printf '%s\n' "${1:-}"
    printf 'bash %q\n' "$SCRIPT"
  } > "$sh"
  chmod +x "$sh"
  new_outer
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 120 -y 40 "$sh; sleep 60"
  for i in $(seq 1 150); do
    screen | grep -q '▸ gamma' && return 0
    sleep 0.1
  done
  return 1
}
screen() { tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | plain || true; }
keys()   { tmux -L "$OUTER" send-keys -t '=drv:' "$@"; }
# The session whose row the cursor is on (session rows only: `▸ name`).
cursor() { { screen | grep -m1 '▌' || true; } | sed -n 's/.*▸ \([^ ]*\) .*/\1/p'; }
wait_text() { # $1 = fixed string, $2 = "absent" to wait for it to go
  local i
  for i in $(seq 1 100); do
    if [ "${2:-}" = absent ]; then
      screen | grep -qF -- "$1" || return 0
    else
      screen | grep -qF -- "$1" && return 0
    fi
    sleep 0.1
  done
  return 1
}
move_to() { # $1 = session: step Down until the cursor is on its row
  local i
  for i in $(seq 1 30); do
    [ "$(cursor)" = "$1" ] && return 0
    keys Down
    sleep 0.1
  done
  return 1
}
check() { # $1 = label, $2 = expected session under the cursor
  local got; got=$(cursor)
  if [ "$got" = "$2" ]; then
    report "$1" pass
  else
    report "$1" fail
    ERRORS+="    cursor on: '${got:-<not a session row>}', expected '$2'"$'\n'
  fi
}

if ! launch; then
  report "the navigator opens in raw mode" fail
  echo; echo "Results: $PASS passed, $FAIL failed"; printf '%s' "$ERRORS"; exit 1
fi

# --- empty query ---------------------------------------------------------------
move_to gamma || true
check "the cursor is on gamma to begin with" gamma

add_session; keys C-r; wait_text "▸ $z" || true
check "^r leaves the cursor on gamma" gamma

add_session; keys C-/; wait_text "▸ $z" || true
check "^/ leaves the cursor on gamma" gamma
add_session; keys C-/; wait_text "▸ $z" || true
check "^/ again (preview closed) leaves it there too" gamma

add_session; tmux -L "$OUTER" resize-window -t '=drv:' -x 112; wait_text "▸ $z" || true
check "a resize leaves the cursor on gamma" gamma

keys C-x
if wait_text "Kill session 'gamma'"; then
  add_session; keys n
  wait_text "Kill " absent || true
  wait_text "▸ $z" || true
  check "a cancelled ^x leaves the cursor on gamma" gamma
  keys C-x
  if wait_text "Kill session 'gamma'"; then
    report "...so the next ^x offers gamma again, not the first row" pass
  else
    report "...so the next ^x offers gamma again, not the first row" fail
    ERRORS+="    dialog: $(screen | grep -o "Kill session '[^']*'" | head -1)"$'\n'
  fi
  keys n; wait_text "Kill " absent || true
else
  report "^x on gamma opens its dialog" fail
fi

# --- with a query ---------------------------------------------------------------
# A query change must still land on the best match: that is what `best` is for.
keys delta
wait_text "❯ delta" || true
for _i in $(seq 1 50); do [ "$(cursor)" = delta ] && break; sleep 0.1; done
check "typing a query still puts the cursor on its match" delta

# `a` matches alpha, beta, delta, gamma; move off the best match by hand, then
# reload: the choice survives.  This reload is made visible by REMOVING a row
# below the cursor rather than adding one: rows that were never in the list
# before, under a typed query, are how a list still loading looks, and those
# rightly move the cursor to the best match (the last test below).
keys C-u a
wait_text "❯ a " || true
for _i in $(seq 1 50); do [ -n "$(cursor)" ] && [ "$(cursor)" != delta ] && break; sleep 0.1; done
move_to gamma || true
tmux -L "$SOCK" kill-session -t '=zz1'; keys C-r; wait_text "▸ zz1 " absent || true
check "with a query, ^r keeps a cursor moved off the best match" gamma

# A kill that slides a NON-matching row under the cursor: under `a`, killing
# beta leaves cuckoo (dimmed) in its row, and the cursor goes back to a match.
move_to beta || true
check "the cursor is on beta before the kill" beta
keys C-x
if wait_text "Kill session 'beta'"; then
  keys y
  # The dialog flashes its result before it closes, so the list is only back
  # once the dialog is gone -- and beta is only gone once the reload landed.
  wait_text "Kill " absent || true
  wait_text "▸ beta" absent || true
  got=$(cursor)
  case "$got" in
    alpha|delta|gamma) report "a kill that slides a dimmed row under the cursor moves it to a match ($got)" pass ;;
    *) report "a kill that slides a dimmed row under the cursor moves it to a match" fail
       ERRORS+="    cursor on: '${got:-<not a session row>}'"$'\n'"$(screen | grep -v "^ *$" | head -20)"$'\n' ;;
  esac
else
  report "^x on beta opens its dialog" fail
fi

# --- a query typed while the list is still loading -------------------------------
# The case that `best` on a reload must NOT lose: prefix+f, type, Enter, all
# before the list has finished arriving.  The directory suggestions come last,
# and here they come 1.5 s late (a zoxide stand-in that sleeps; the bash
# renderer prints the session rows first, so they land as a second snapshot of
# the SAME query).  `notes` scatters across the session nobody-testers
# (N-O-body-T-E-S), so the first snapshot has a match to put the cursor on --
# which is what makes this about arriving rows and not about a cursor left on a
# dimmed one -- and the exact directory is the better match when it arrives:
# the cursor must follow it there.
mkdir -p "$TMPD/shim" "$TMPD/dirs/notes"
cat > "$TMPD/shim/zoxide" <<EOF
#!/bin/sh
[ "\$1 \$2" = "query --list" ] || exit 1
sleep 1.5
printf '%s\n' '$TMPD/dirs/notes'
EOF
chmod +x "$TMPD/shim/zoxide"
tmux -L "$SOCK" new-session -d -s nobody-testers -x 120 -y 30 -c "$TMPD/cwd" 'sleep 3600'
if launch "export PATH=$TMPD/shim:\$PATH INTERDIMUX_USE_RUST=off INTERDIMUX_USE_ZOXIDE=on INTERDIMUX_SHOW_DIRS=on"; then
  if screen | grep -qF '+ notes'; then
    report "typed ahead: the directory rows arrive after the query (fixture)" fail
  else
    keys notes
    first=""
    for _i in $(seq 1 30); do
      first=$(screen | grep -m1 '▌' || true)
      case "$first" in *nobody-testers*|*'+ notes'*) break ;; esac
      sleep 0.1
    done
    case "$first" in
      *nobody-testers*) report "typed ahead: the first snapshot puts the cursor on its match (fixture)" pass ;;
      *) report "typed ahead: the first snapshot puts the cursor on its match (fixture)" fail ;;
    esac
    wait_text "+ notes" || true
    got=""
    for _i in $(seq 1 30); do
      got=$(screen | grep -m1 '▌' || true)
      case "$got" in *'+ notes'*) break ;; esac
      sleep 0.1
    done
    case "$got" in
      *'+ notes'*) report "typed ahead: the cursor follows a better match that arrives later" pass ;;
      *) report "typed ahead: the cursor follows a better match that arrives later" fail
         ERRORS+="    cursor on: $(printf '%s' "$got" | sed 's/  */ /g')"$'\n' ;;
    esac
  fi
else
  report "typed ahead: the navigator opens with the bash renderer" fail
fi

# --- a kill at the BOTTOM of the list ------------------------------------------------
# FZF_RAW=0 means "the cursor is on a dimmed row" -- and also "the cursor is past
# the end": a reload that drops the LAST rows leaves it one beyond the shorter
# list until fzf next draws.  Read as a dimmed row, that sent it to row 1 (with
# an empty query `best` is the top), so killing your bottom pane made the next
# ^x offer the first session.  With raw off fzf clamps it to the new last row,
# and raw on must do the same -- except under a query, where that row may be a
# dimmed one and the cursor still belongs on a match.
#
# The rows are removed from outside and ^r reloads: the same shortened
# reload-sync a confirmed ^x ends in, without racing the dialog, which drains
# typeahead after it draws (a `y` sent the moment it appears can be swallowed).
# Two sessions at the bottom (index order: zzpane < zzzk): zzpane has two
# panes, so its last row is a pane row; zzzk is the only session besides
# cuckoo with a `k` in it.
cur_row() { { screen | grep -m1 '▌' || true; } | sed 's/  */ /g'; }
# One Down at a time, each waited for until the row changes: a Down sent before
# the previous one was drawn would carry the cursor past the target, and with
# --cycle on round to the top.
move_to_row() { # $1 = fixed string the current row must contain
  local i j prev
  for i in $(seq 1 40); do
    prev=$(cur_row)
    [[ "$prev" == *"$1"* ]] && return 0
    keys Down
    for j in $(seq 1 50); do [ "$(cur_row)" != "$prev" ] && break; sleep 0.05; done
  done
  return 1
}
wait_row() { # $1 = fixed string: poll until the current row contains it
  local i
  for i in $(seq 1 50); do
    [[ "$(cur_row)" == *"$1"* ]] && return 0
    sleep 0.1
  done
  return 1
}
tmux -L "$SOCK" new-session -d -s zzpane -x 120 -y 30 -c "$TMPD/cwd" 'sleep 3600'
tmux -L "$SOCK" split-window -d -t '=zzpane:0' -c "$TMPD/cwd" 'sleep 3601'
tmux -L "$SOCK" new-session -d -s zzzk -x 120 -y 30 -c "$TMPD/cwd" 'sleep 3600'
# FZF_CURRENT_ITEM is what tells "past the end" apart, and fzf passes its own
# environment through: one left over from an fzf that launched this (a picker's
# execute, say) would read as "on a row" every time.  So it is set here.
if launch "export FZF_CURRENT_ITEM='left over from a parent fzf'"; then
  # Under a query first: `k` matches cuckoo and zzzk only, so removing zzzk
  # leaves zzpane's (dimmed) pane row as the new last row.
  keys k
  wait_row cuckoo || true   # the query's own `best`, before any Down
  if move_to_row '└─ zzzk 0:'; then
    tmux -L "$SOCK" kill-session -t '=zzzk'
    keys C-r
    wait_text "zzzk" absent || true
    got=$(cur_row)
    case "$got" in
      *cuckoo*) report "under a query, dropping the bottom rows puts the cursor on a match, not a dimmed row" pass ;;
      *) report "under a query, dropping the bottom rows puts the cursor on a match, not a dimmed row" fail
         ERRORS+="    cursor on: $got"$'\n' ;;
    esac
  else
    report "the cursor reaches zzzk's window row under the query k" fail
  fi

  # Then with an empty query: the bottom row is zzpane's second pane.
  keys C-u
  wait_row '▸ alpha' || true
  if move_to_row '└╴ zzpane 0.1'; then
    tmux -L "$SOCK" kill-pane -t '=zzpane:0.1'
    keys C-r
    wait_text "zzpane 0.1" absent || true
    got=$(cur_row)
    case "$got" in
      *'└─ zzpane 0:'*) report "dropping the bottom pane leaves the cursor on the new last row" pass ;;
      *) report "dropping the bottom pane leaves the cursor on the new last row" fail
         ERRORS+="    cursor on: $got"$'\n' ;;
    esac
    # The dialog is the oracle that matters: it names fzf's current item.
    keys C-x
    if wait_text "Kill window 'zzpane:0'"; then
      report "...so the next ^x offers that row, not the first session" pass
    else
      report "...so the next ^x offers that row, not the first session" fail
      ERRORS+="    dialog: $(screen | grep -o "Kill [a-z]* '[^']*'" | head -1)"$'\n'
    fi
    keys n
  else
    report "the cursor reaches zzpane's second pane row" fail
  fi
else
  report "the navigator opens for the bottom-kill cases" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
