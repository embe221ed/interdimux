#!/usr/bin/env bash
#
# A directory's name is arbitrary bytes, and it is drawn in two places: the
# ctrl-o picker's path column, and the navigator's directory rows (the name in
# the identity column).  Neither may pass a control byte through raw (review
# B03).  An ESC made the rest of the name a live SGR sequence -- `esc<ESC>[31mred`
# showed as a red `escred` -- and the padding counted the five bytes the
# terminal swallowed, so that row's next column sat five cells left of every
# other row's.  A CR sent the cursor back to column 0.  The navigator's context
# column already sanitised the path; the ctrl-o picker (bash only, whatever
# renderer draws the navigator) and both renderers' identity column did not.
#
# The spec -- the last field, which Enter opens -- stays the raw path.
#
# Oracles: the bytes of each field with the palette's own SGR sequences removed,
# and for alignment, tmux's own grid: field 1 of each row is printed into a
# pane and the cursor's column read back.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-dirnames-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-dirnames.XXXXXX")" && pwd -P)"
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

echo "interdimux directory-name tests"
echo

export LC_ALL=C.UTF-8 LANG=C.UTF-8
H="$TMPD/h"
ESCD="$H/esc"$'\e'"[31mred"; CRD="$H/cr"$'\r'"z"; PLAIN="$H/plain"
mkdir -p "$ESCD" "$CRD" "$PLAIN" "$TMPD/data/interdimux"
printf '%s\n' "$ESCD" "$CRD" "$PLAIN" > "$TMPD/data/interdimux/recent_dirs"

tmux -f /dev/null -L "$SOCK" new-session -d -s main -x 200 -y 20 -c "$TMPD" 'sleep 99999'
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=main:' -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data" INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_PROJECT_DIRS="$TMPD/nowhere"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1

sgr_strip() { sed 's/\x1b\[[0-9;]*m//g'; }
# Control bytes left in $1 once the palette's SGR sequences are gone.
ctl_count() { printf '%s' "$1" | sgr_strip | LC_ALL=C tr -d '\040-\176\200-\377' | wc -c | tr -d ' '; }
# The row of list $1 whose LAST field is $2, and its field $3.
field_of() { printf '%s\n' "$1" | awk -F'\t' -v s="$2" -v f="$3" '$NF == s { print $f; exit }'; }

# The column tmux's grid leaves the cursor at after drawing $1 in a fresh pane.
# The pane prints the bytes and then waits; the column is read once the
# pane has said it is done (the marker file), and twice alike.
cursor_after() {
  local f="$TMPD/draw.$RANDOM" x="" prev="" i
  printf '%s' "$1" > "$f"
  rm -f "$f.done"
  tmux -L "$SOCK" respawn-pane -k -t "$DRAW" "printf '\\033[H\\033[2J'; cat '$f'; : > '$f.done'; exec sleep 99999"
  for i in $(seq 1 100); do
    if [ -e "$f.done" ]; then
      x=$(tmux -L "$SOCK" display-message -p -t "$DRAW" '#{cursor_x}')
      [ -n "$prev" ] && [ "$x" = "$prev" ] && break
      prev="$x"
    fi
    sleep 0.05
  done
  REPLY="$x"
}
DRAW=$(tmux -L "$SOCK" new-window -d -P -F '#{pane_id}' -t '=main:' 'sleep 99999')

# --- the ctrl-o picker ------------------------------------------------------------
dl=$(bash "$SCRIPT" --dirs-list 2>/dev/null)
for d in "$ESCD" "$CRD" "$PLAIN"; do
  [ -n "$(field_of "$dl" "$d" 1)" ] || { report "ctrl-o lists every fixture directory (missing: $(printf '%q' "$d"))" fail; continue; }
done
f1e=$(field_of "$dl" "$ESCD" 1); f1c=$(field_of "$dl" "$CRD" 1); f1p=$(field_of "$dl" "$PLAIN" 1)
n=$(( $(ctl_count "$f1e") + $(ctl_count "$f1c") ))
[ "$n" = 0 ] && report "ctrl-o: no raw control byte in a row's path column" pass \
             || report "ctrl-o: no raw control byte in a row's path column ($n found)" fail
case "$(printf '%s' "$f1e" | sgr_strip)" in
  *"/esc?[31mred "*) report "ctrl-o: an ESC in a name shows as '?', the rest of the name as text" pass ;;
  *) report "ctrl-o: an ESC in a name shows as '?' (got: $(printf '%s' "$f1e" | cat -v))" fail ;;
esac
cursor_after "$f1p"; xp="$REPLY"
cursor_after "$f1e"; xe="$REPLY"
cursor_after "$f1c"; xc="$REPLY"
if [ -n "$xp" ] && [ "$xp" -gt 20 ] && [ "$xe" = "$xp" ] && [ "$xc" = "$xp" ]; then
  report "ctrl-o: every row's path column ends in the same terminal column ($xp)" pass
else
  report "ctrl-o: every row's path column ends in the same terminal column (plain $xp, ESC $xe, CR $xc)" fail
fi
[ "$(printf '%s\n' "$dl" | awk -F'\t' -v s="$ESCD" '$3 == s' | wc -l)" = 1 ] \
  && report "ctrl-o: the row still opens the directory itself (raw path in the last field)" pass \
  || report "ctrl-o: the row still opens the directory itself (raw path in the last field)" fail

# --- the navigator's directory rows, in each renderer -------------------------------
renderers="off"
[ -x "$BIN" ] && renderers="on off"
for r in $renderers; do
  label=$([ "$r" = on ] && echo rust || echo bash)
  out=$(INTERDIMUX_USE_RUST="$r" INTERDIMUX_SHOW_DIRS=on FZF_COLUMNS=160 bash "$SCRIPT" --list 2>/dev/null)
  i1e=$(field_of "$out" "D:$ESCD" 1); i1c=$(field_of "$out" "D:$CRD" 1); i1p=$(field_of "$out" "D:$PLAIN" 1)
  if [ -z "$i1e" ] || [ -z "$i1c" ] || [ -z "$i1p" ]; then
    report "$label: the navigator lists every fixture directory" fail
    continue
  fi
  n=0
  for s in "D:$ESCD" "D:$CRD"; do
    for f in 1 2 3; do n=$(( n + $(ctl_count "$(field_of "$out" "$s" "$f")") )); done
  done
  [ "$n" = 0 ] && report "$label: no raw control byte in a directory row's name, path or badge" pass \
               || report "$label: no raw control byte in a directory row's name, path or badge ($n found)" fail
  case "$(printf '%s' "$i1e" | sgr_strip)" in
    *" esc?[31mred "*) report "$label: an ESC in the name shows as '?' in the identity column" pass ;;
    *) report "$label: an ESC in the name shows as '?' in the identity column (got: $(printf '%s' "$i1e" | cat -v))" fail ;;
  esac
  cursor_after "$i1p"; xp="$REPLY"
  cursor_after "$i1e"; xe="$REPLY"
  cursor_after "$i1c"; xc="$REPLY"
  if [ -n "$xp" ] && [ "$xp" -gt 5 ] && [ "$xe" = "$xp" ] && [ "$xc" = "$xp" ]; then
    report "$label: every directory row's identity column ends in the same terminal column ($xp)" pass
  else
    report "$label: every directory row's identity column ends in the same terminal column (plain $xp, ESC $xe, CR $xc)" fail
  fi
  printf '%s\n' "$out" | grep 'D:' > "$TMPD/drows.$r"
done
if [ -x "$BIN" ]; then
  cmp -s "$TMPD/drows.on" "$TMPD/drows.off" \
    && report "both renderers draw the same directory rows, byte for byte" pass \
    || report "both renderers draw the same directory rows, byte for byte" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
