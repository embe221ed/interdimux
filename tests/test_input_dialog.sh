#!/usr/bin/env bash
#
# The text field of input_dialog (Rename, Send keys, Schedule), laid out in
# CELLS on a real terminal.
#
# The editor sized its field in cells but sliced, padded, scrolled and placed
# the cursor by characters, so every CJK or emoji character drew two cells for
# the one it was counted as.  Observed before the fix:
#
#   * Rename on a session with a long CJK name: the prefilled name ran through
#     the right border and wrapped onto the row below, and tmux put the cursor
#     at column 34 -- in the middle of the text, not after it.
#   * Send keys, three CJK characters typed: the padding erased the right border
#     and the cursor sat inside the second character.
#
# The buffer was always right; only the picture was wrong.  So every assertion
# here is about the picture, and the authority for it is tmux's own grid:
#
#   * the cursor is #{cursor_x}/#{cursor_y} of the pane running the dialog;
#   * a cell width is measured by printing the string into a scratch pane on a
#     second private server and reading #{cursor_x} there (capture-pane emits one
#     character per cluster, not per cell, so it cannot be counted).
#
# Needs a real tty of a known size: the dialog reads `stty size`, which a
# fixture file does not have.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-inputdlg-$$"
MSOCK="${SOCK}-meas"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-inputdlg.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  tmux -L "$MSOCK" kill-server 2>/dev/null || true
  rm -rf "$TMPD"
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

echo "interdimux input-dialog tests"
echo

# Everything below slices strings that hold CJK text, and the dialog under test
# reads its keys one CHARACTER at a time -- both need a UTF-8 locale, in this
# shell and in the tmux server the dialog inherits its environment from.
case "$(locale charmap 2>/dev/null)" in
  UTF-8|utf8) ;;
  *) export LC_ALL=C.UTF-8 ;;
esac
if [ "$(printf '%s' '日本' | { IFS= read -r x; echo "${#x}"; })" != 2 ]; then
  echo "  (skipped: no UTF-8 locale available)"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

CJK='日本語のセッション名前とても長い名前です本当に長いのです'   # 27 chars, 54 cells

tmux -f /dev/null -L "$SOCK" new-session -d -s host -x 120 -y 30 'sleep 900'
tmux -L "$SOCK" new-session -d -s solo -x 120 -y 30 'sleep 900'
tmux -L "$SOCK" new-session -d -s "$CJK" -x 120 -y 30 'sleep 900'
SOCKPATH="$(tmux -L "$SOCK" display-message -p '#{socket_path}')"
ANCHOR="$(tmux -L "$SOCK" list-panes -t '=host:' -F '#{pane_id}' | head -1)"

tmux -f /dev/null -L "$MSOCK" new-session -d -s m -x 250 -y 5 'sleep 900'

# ---------------------------------------------------------------------------
# The oracle: how many cells does tmux give this string?
# ---------------------------------------------------------------------------
# Printed into a fresh pane, followed by an OSC 2 title that acts as a receipt:
# once the pane's title is the token, tmux has processed every byte before it,
# so #{cursor_x} is final -- no sleep to guess at.  Sets REPLY (-1 on timeout).
_mn=0
cells() {
  _mn=$((_mn + 1))
  local f="$TMPD/m.$_mn" tok="imuxcells$_mn-$$" t="" i
  printf '%s\033]2;%s\033\\' "$1" "$tok" > "$f"
  tmux -L "$MSOCK" new-window -d -t '=m:' -n "w$_mn" "cat '$f'; exec sleep 60"
  for i in $(seq 1 100); do
    t=$(tmux -L "$MSOCK" display-message -p -t "=m:w$_mn" '#{pane_title}' 2>/dev/null || true)
    [ "$t" = "$tok" ] && break
    sleep 0.05
  done
  if [ "$t" = "$tok" ]; then
    REPLY=$(tmux -L "$MSOCK" display-message -p -t "=m:w$_mn" '#{cursor_x}')
  else
    REPLY=-1
  fi
  tmux -L "$MSOCK" kill-window -t "=m:w$_mn" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Driving the dialog
# ---------------------------------------------------------------------------

# Open ACTION on SPEC in a COLSxROWS pane and wait for the prompt to be drawn.
# That is NOT yet "ready for keys": after drawing it the editor drains pending
# input, and anything typed during the drain is thrown away.  Nor does the
# tty's mode tell: the drain reads with bash's `read -rsn1`, which switches
# canonical mode off exactly as the edit loop's own `read -rsN1` does.  (A
# poll on -icanon lost the first keys 4 times in 12.)  Only the edit loop's
# repaint says the drain is over -- see wait_vis and editor_ready_empty.
open_dialog() { # $1 cols, $2 rows, $3 action, $4 spec
  tmux -L "$SOCK" kill-session -t '=drv' 2>/dev/null || true
  tmux -L "$SOCK" new-session -d -s drv -x "$1" -y "$2" \
    "env TMUX='$SOCKPATH,99999,0' TMUX_PANE='$ANCHOR' INTERDIMUX_OPTS_PRIMED=1 \
         INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
         bash '$SCRIPT' --action $3 '$4'; exec sleep 60"
  local i
  for i in $(seq 1 200); do
    tmux -L "$SOCK" capture-pane -t '=drv:' -p 2>/dev/null | grep -q '❯ ' && return 0
    sleep 0.05
  done
  return 1
}
keys()    { tmux -L "$SOCK" send-keys -t '=drv:' "$@"; }
typed()   { tmux -L "$SOCK" send-keys -t '=drv:' -l "$1"; }

# Read the dialog off the screen.  FIELD_ROW is the row holding the prompt, HEAD
# that row up to and including the prompt, VIS the text shown in the field
# (trailing blanks and the border removed), CUR_X/CUR_Y the terminal cursor.
SCREEN="" FIELD_ROW="" FIELD_IDX=-1 HEAD="" VIS="" CUR_X=-1 CUR_Y=-1
snap() {
  local r i=0
  SCREEN=$(tmux -L "$SOCK" capture-pane -t '=drv:' -p 2>/dev/null || true)
  FIELD_ROW="" FIELD_IDX=-1
  while IFS= read -r r; do
    case "$r" in *'❯ '*) FIELD_ROW="$r" FIELD_IDX=$i; break ;; esac
    i=$((i + 1))
  done <<< "$SCREEN"
  HEAD="${FIELD_ROW%%❯ *}❯ "
  VIS="${FIELD_ROW#*❯ }"; VIS="${VIS%│}"; VIS="${VIS%"${VIS##*[! ]}"}"
  read -r CUR_X CUR_Y < <(tmux -L "$SOCK" display-message -p -t '=drv:' '#{cursor_x} #{cursor_y}')
}

# Poll until the field shows exactly TEXT (the whole buffer fits), or until it
# ends with TEXT when the second argument is "tail" (the buffer has scrolled).
# That is the receipt that every key sent so far has been processed: the text
# and the cursor are written by the same repaint.
wait_vis() { # $1 text, [$2 = tail|head]
  local i
  for i in $(seq 1 100); do
    snap
    case "${2:-exact}" in
      exact) [ "$VIS" = "$1" ] && return 0 ;;
      tail)  [ -n "$VIS" ] && [ "${VIS%"$1"}" != "$VIS" ] && return 0 ;;
      head)  [ -n "$VIS" ] && [ "${VIS#"$1"}" != "$VIS" ] && return 0 ;;
    esac
    sleep 0.05
  done
  return 1
}

# Poll until the cursor sits right after PREFIX on the field row, i.e. at the
# cell width tmux gives "<HEAD><PREFIX>".  The expectation is measured once;
# the cursor is polled, because a motion key changes nothing else to wait for.
WANT_X=-1
cursor_after() { # $1 prefix (the text the cursor should follow)
  local i
  snap
  cells "${HEAD}$1"; WANT_X=$REPLY
  for i in $(seq 1 60); do
    [ "$CUR_X" = "$WANT_X" ] && [ "$CUR_Y" = "$FIELD_IDX" ] && return 0
    sleep 0.05
    snap
  done
  return 1
}

# An EMPTY field's first repaint is invisible, so probe for the edit loop: type
# "x" then Home until the field shows only x's with the cursor on its first
# cell.  Only the loop draws that -- a key eaten by the drain shows nothing,
# and one the line discipline echoes before raw mode shows "x^[[1~", with the
# cursor after it.  Then Ctrl-K clears every probe, including any still in
# flight, because the tty delivers keys in order.
editor_ready_empty() {
  local i j x0
  snap; cells "$HEAD"; x0=$REPLY
  for i in $(seq 1 40); do
    typed "x"; keys Home
    for j in $(seq 1 8); do
      snap
      if [[ "$VIS" =~ ^x+$ ]] && [ "$CUR_X" = "$x0" ]; then
        keys C-k
        wait_vis ""
        return
      fi
      sleep 0.05
    done
  done
  return 1
}

# Open a Send keys dialog in an 80x20 pane and make sure its edit loop is
# reading.  A failure here is reported, not counted as a pass.
open_send() { # $1 what the section is about
  if ! open_dialog 80 20 send 'P:solo:0:0' || ! editor_ready_empty; then
    report "the send editor opens and reads keys ($1)" fail
    ERRORS+="      screen: $(printf '%s' "$SCREEN" | grep '❯' || true)"$'\n'
  fi
}

# The frame survives the field: the field row still ends in its blank gutter and
# the border, and it, the row below it and the top border all occupy the same
# number of cells.  A field that overran erases or displaces the border; one
# that wrapped leaves text at the start of the row below.
FRAME_WHY=""
frame_intact() {
  local top below tw fw bw
  snap
  top=$(printf '%s\n' "$SCREEN" | grep -m1 '╭' || true)
  below=$(printf '%s\n' "$SCREEN" | sed -n "$((FIELD_IDX + 2))p")
  FRAME_WHY="field row: '$FIELD_ROW'"
  case "$FIELD_ROW" in *' │') ;; *) FRAME_WHY+=" (no blank gutter + border at its end)"; return 1 ;; esac
  case "$below" in *'│') ;; *) FRAME_WHY+=" row below: '$below'"; return 1 ;; esac
  cells "$top"; tw=$REPLY
  cells "$FIELD_ROW"; fw=$REPLY
  cells "$below"; bw=$REPLY
  FRAME_WHY+=" widths top=$tw field=$fw below=$bw"
  [ "$tw" -gt 0 ] && [ "$tw" = "$fw" ] && [ "$tw" = "$bw" ]
}

# run CMD...: RC is its status, without tripping `set -e`
RC=0
run() { RC=0; "$@" || RC=$?; }
# $2 is the END of $1 and not all of it: what a view scrolled to the end shows
is_tail() { [ -n "$2" ] && [ "$2" != "$1" ] && [ "${1%"$2"}" != "$1" ]; }

# The field's geometry, read off the screen (after a snap): FIELD_X is the
# column of its first cell, FIELD_W its width -- the row, minus the head, minus
# the blank gutter and the border.
FIELD_X=-1 FIELD_W=-1
field_geometry() {
  cells "$FIELD_ROW"; FIELD_W=$REPLY
  cells "$HEAD"; FIELD_X=$REPLY
  FIELD_W=$(( FIELD_W - FIELD_X - 2 ))
}

# A view scrolled to the end of FULL (cursor after the text) shows as much of it
# as fits: the character just left of the view would not fit beside the text
# and the cursor's own cell.  Scrolling one character too far is otherwise
# invisible -- the frame is intact and the cursor still follows the text.
FILL_WHY=""
fills_view() { # $1 the whole buffer
  local prev vis_w prev_w
  field_geometry
  cells "$VIS"; vis_w=$REPLY
  prev="${1:$(( ${#1} - ${#VIS} - 1 )):1}"
  cells "$prev"; prev_w=$REPLY
  FILL_WHY="field=$FIELD_W cells, shown=$vis_w, the next character left ('$prev') is $prev_w"
  [ ${#VIS} -lt ${#1} ] && [ $(( vis_w + prev_w + 1 )) -gt "$FIELD_W" ]
}

check() { # $1 name, $2 detail shown on failure, $3 status
  if [ "$3" = 0 ]; then report "$1" pass; else report "$1" fail; ERRORS+="      $2"$'\n'; fi
}

# ---------------------------------------------------------------------------
# 1. Rename, prefilled with a name wider than the field
# ---------------------------------------------------------------------------
# 60 columns: the box is 58 wide and the field 50 cells, so the 54-cell name
# cannot fit and the view has to scroll to its end, where the cursor starts.

# Only the edit loop's repaint draws the prefilled name, so seeing its end is
# also the proof that the input drain is over.
RC=0
open_dialog 60 14 rename "S:$CJK" && wait_vis "のです" tail || RC=1
check "the rename editor opens with the end of the name in view" "field: '$FIELD_ROW'" "$RC"

run frame_intact
check "a prefilled CJK name stays inside the frame" "$FRAME_WHY" "$RC"

run cursor_after "$VIS"
check "the cursor starts right after the prefilled CJK name" \
      "want x=$WANT_X y=$FIELD_IDX, got x=$CUR_X y=$CUR_Y; field: '$FIELD_ROW'" "$RC"

# the view is the END of the name, since that is where the cursor is
run is_tail "$CJK" "$VIS"
check "the scrolled view shows the end of the name" "shown: '$VIS'" "$RC"

run fills_view "$CJK"
check "the field shows as much of the name as fits" "$FILL_WHY" "$RC"

# The value is the buffer, not the picture: typing after the wide text and
# pressing Enter renames to exactly the name plus what was typed.
typed "x"
wait_vis "x" tail || true
run cursor_after "$VIS"
check "typing after a wide name puts the cursor after the new character" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"
keys Enter
RC=1
for _i in $(seq 1 100); do
  tmux -L "$SOCK" has-session -t "=${CJK}x" 2>/dev/null && { RC=0; break; }
  sleep 0.05
done
check "Enter applies the whole edited name" \
      "sessions: $(tmux -L "$SOCK" list-sessions -F '#{session_name}' | tr '\n' ' ')" "$RC"

# ---------------------------------------------------------------------------
# 2. Send keys: wide text typed into an empty field
# ---------------------------------------------------------------------------

open_send "wide text"
typed "日本語"
wait_vis "日本語" || true
run cursor_after "日本語"
check "after three CJK characters the cursor follows them, not the middle" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"
run frame_intact
check "three CJK characters leave the border where it was" "$FRAME_WHY" "$RC"

# 40 chars, 80 cells: wider than any field an 80-column pane can hold
LONG='日本語のコマンドをここに入力しますとてもながいものですもっと長くしてみます本当に'
typed "${LONG:3}"
wait_vis "本当に" tail || true
run frame_intact
check "a CJK line wider than the field scrolls inside the frame" "$FRAME_WHY" "$RC"
run cursor_after "$VIS"
check "the cursor follows the scrolled CJK text" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"
run is_tail "$LONG" "$VIS"
check "the scrolled view is the end of what was typed" "shown: '$VIS'" "$RC"

keys Home
wait_vis "日本語の" head || true
run cursor_after ""
check "Home puts the cursor on the first cell of the field" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"
run frame_intact
check "the start of a long CJK line stays inside the frame" "$FRAME_WHY" "$RC"

keys Right Right Right
run cursor_after "日本語"
check "Right moves the cursor a whole wide character at a time" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"
keys Escape

# ---------------------------------------------------------------------------
# 3. Editing mixed-width text in the middle
# ---------------------------------------------------------------------------
# Every edit has to keep the widths in step with the characters.  A width that
# goes stale only shows once the cursor moves PAST it, so each edit is made in
# the middle, removes or inserts a character whose width differs from its
# neighbours', and is followed by End.

open_send "mixed-width edits"
typed "ab日本 cd語 ef"
wait_vis "ab日本 cd語 ef" || true
run cursor_after "ab日本 cd語 ef"
check "mixed-width text: the cursor follows it" "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"

keys Left Left Left Left
run cursor_after "ab日本 cd"
check "mixed-width text: Left steps back over narrow and wide characters" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"

keys Right BSpace
run wait_vis "ab日本 cd ef"
check "Backspace of a wide character in the middle erases both of its cells" "shown: '$VIS'" "$RC"
run cursor_after "ab日本 cd"
check "Backspace in the middle leaves the cursor where the character was" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"
keys End
run cursor_after "ab日本 cd ef"
check "after Backspace in the middle, End lands after the text" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"

keys Home Right Right DC
run wait_vis "ab本 cd ef"
check "Delete of a wide character erases both of its cells" "shown: '$VIS'" "$RC"
keys End
run cursor_after "ab本 cd ef"
check "after Delete of a wide character, End lands after the text" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"

keys Home Right Right Right C-w
run wait_vis " cd ef"
check "Ctrl-W of a word with a wide character erases it" "shown: '$VIS'" "$RC"
keys End
run cursor_after " cd ef"
check "after Ctrl-W, End lands after the text" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"

keys Home
typed "語語"
run wait_vis "語語 cd ef"
check "inserting wide characters in the middle shifts the rest right" "shown: '$VIS'" "$RC"
run cursor_after "語語"
check "inserting wide characters in the middle puts the cursor after them" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"
keys End
run cursor_after "語語 cd ef"
check "after inserting in the middle, End lands after the text" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"

keys Home Right Right C-u
run wait_vis " cd ef"
check "Ctrl-U of wide characters erases them from the field" "shown: '$VIS'" "$RC"
keys End
run cursor_after " cd ef"
check "after Ctrl-U, End lands after the text" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"
keys Escape

# ---------------------------------------------------------------------------
# 4. A wide character at the edge of the field
# ---------------------------------------------------------------------------
# With one cell left, a wide character cannot be drawn.  It must be left out:
# drawn anyway, its second half lands in the gutter beside the border.  The
# field width is read off the screen, so this does not depend on the box size.

open_send "the field's edge"
snap
field_geometry
narrow=$(printf '%*s' $(( FIELD_W - 1 )) '' | tr ' ' 'a')
typed "${narrow}日b"
wait_vis "日b" tail || true
keys Home
wait_vis "$narrow" || true
run frame_intact
check "a wide character that would straddle the edge is not drawn into the gutter" \
      "field=$FIELD_W cells; $FRAME_WHY" "$RC"
run cursor_after ""
check "Home on that line puts the cursor at the field's start" "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"
keys End
wait_vis "日b" tail || true
run frame_intact
check "End on that line scrolls the wide character into view, inside the frame" "$FRAME_WHY" "$RC"
run cursor_after "$VIS"
check "End on that line puts the cursor after the text" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"
# ...on a cell of its own INSIDE the field: the text is scrolled so the cursor
# never lands in the gutter, where the next character typed would be drawn
run test "$CUR_X" -lt $(( FIELD_X + FIELD_W ))
check "End on that line keeps the cursor inside the field, not in the gutter" \
      "field is x=$FIELD_X..$(( FIELD_X + FIELD_W - 1 )), cursor x=$CUR_X" "$RC"
run fills_view "${narrow}日b"
check "End on that line shows as much of it as fits" "$FILL_WHY" "$RC"
keys Escape

# ---------------------------------------------------------------------------
# 5. A combining mark at the left edge of a scrolled view
# ---------------------------------------------------------------------------
# A decomposed "é" is two characters, e + U+0301, in ONE cell.  Scrolled so that
# a mark's base is just out of view, the mark must go too: drawn first, a
# combining mark attaches to the cell before it -- the prompt's, outside the
# field.  (Observed on tmux: the prompt's trailing blank grows an accent.)

open_send "combining marks"
snap
field_geometry
MARK=$'\u0301'
decomposed=""
for (( _k = 0; _k < FIELD_W + 4; _k++ )); do decomposed+="e$MARK"; done
typed "${decomposed}z"
wait_vis "e${MARK}z" tail || true
run test "${VIS:0:1}" != "$MARK"
check "a combining mark whose base scrolled out of view is not drawn onto the prompt" \
      "field: '$FIELD_ROW'" "$RC"
run cursor_after "$VIS"
check "the cursor follows text with combining marks" \
      "want x=$WANT_X, got x=$CUR_X; field: '$FIELD_ROW'" "$RC"
keys Escape

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
