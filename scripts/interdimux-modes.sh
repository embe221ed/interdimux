# shellcheck shell=bash
#
# interdimux-modes.sh -- the modes the navigator never runs: the dialogs and
# --action, ctrl-o's directory picker (--dirs), --list when the Rust core does
# not draw it, --jump, the popup launcher (--launch, Health, Jobs), the
# dashboard, --agents and --agent-next, and --doctor.  Part of
# scripts/interdimux.sh, which sources it for an invocation with an argument
# that no mode above that line took; it is never run on its own.
#
# A file of its own so that the navigator -- every prefix+f, the one
# invocation without an argument -- does not parse it.  bash parses a script
# as it runs it, and these ~180 KB came last before the navigator, so every
# open parsed them before fzf could start: ~8 ms.  Each mode here parses what
# it parsed before, in the same order, and one open more.

# ---------------------------------------------------------------------------
# Dialogs (drawn on the popup tty while fzf is suspended by execute)
# ---------------------------------------------------------------------------

DLG_ROWS=24 DLG_COLS=80
DLG_TOP=0 DLG_LEFT=0 DLG_W=0 DLG_H=0

# The user's configured popup border (option defaults if unset), in
# POPUP_USER_LINES and POPUP_USER_STYLE: both options from ONE tmux client, read
# once per process.  Each used to be a $(...) of its own around its own
# show-option -- two forks and a client, twice, on every repaint, and an
# --action repaints up to three times.  Both options are tmux 3.3's, as is
# every caller (popup_accent, --launch), so the first one cannot fail and take
# the second with it (a failed command ends tmux's list).  What the client did
# print is kept even so: a failed second read defaults the style alone, as
# its own read did.  (`exec`: with a redirection on its command, bash forks a
# $(...) once more before running it.)
POPUP_USER_LINES="" POPUP_USER_STYLE=""
popup_user_border() {
  [ -n "$POPUP_USER_LINES" ] && return 0
  local o
  o=$(exec tmux show-option -gv popup-border-lines \; show-option -gv popup-border-style 2>/dev/null) || :
  POPUP_USER_LINES="${o%%$'\n'*}" POPUP_USER_STYLE=""
  case "$o" in *$'\n'*) POPUP_USER_STYLE="${o#*$'\n'}" ;; esac
  POPUP_USER_LINES="${POPUP_USER_LINES:-single}" POPUP_USER_STYLE="${POPUP_USER_STYLE:-default}"
}

# The user's border style with the frame colour swapped to the danger
# red (later attributes win in tmux styles, so bg/attrs are preserved).
#
# danger_style -- sets REPLY.
#
# With "padded" the frame is made of SPACES, so a red foreground on it is
# invisible: the only thing left carrying the danger cue was the title text,
# which tmux draws in the border style.  There the danger colour becomes the
# BACKGROUND, and the text takes the frame's own background colour (or the
# terminal's default) -- setting bg alone would leave the title red on red, and
# `reverse` is no help: tmux keeps only the colours of a popup border style and
# zeroes its attributes.  ("none" draws no frame and no title, so no border
# style can show anything there.)
danger_style() {
  local base tok ink=default
  local -a toks=()
  popup_user_border
  base="$POPUP_USER_STYLE"
  if [ "$POPUP_USER_LINES" = padded ]; then
    IFS=', ' read -r -a toks <<< "$base"
    for tok in ${toks[@]+"${toks[@]}"}; do
      case "$tok" in bg=*) ink="${tok#bg=}" ;; esac
    done
    [ -n "$ink" ] || ink=default
    case "$base" in
      default) REPLY="bg=$POPUP_BORDER_DANGER,fg=$ink" ;;
      *)       REPLY="$base,bg=$POPUP_BORDER_DANGER,fg=$ink" ;;
    esac
    return 0
  fi
  case "$base" in
    default) REPLY="fg=$POPUP_BORDER_DANGER" ;;
    *)       REPLY="$base,fg=$POPUP_BORDER_DANGER" ;;
  esac
}

# Repaint the live popup frame: "danger" for destructive prompts, "user"
# to restore the configured border.  tmux >= 3.6 modifies the running
# popup; 3.3–3.5 silently ignore the call; older tmux rejects the flags,
# so gate on 3.3.  Lines and title must be re-sent on every repaint: a
# partial display-popup on >= 3.6 replaces omitted properties with
# defaults (-T absent means title "", not "keep") — INTERDIMUX_TITLE is
# forwarded into the popup by --launch.
#
# A repaint to the accent this process last applied is skipped: kill restores
# the frame itself, and its EXIT trap asked for the same again a millisecond
# later (in kill mode all three were the danger frame) -- a display-popup for a
# frame tmux was already drawing.  Only what this process applied counts: a
# repaint that failed is sent again.
#
# It starts empty, NOT as the accent the popup was opened with, which would
# spare every other action its exit repaint: that repaint is no no-op.  On
# tmux 3.7 it drops popup-style's foreground from the popup's text, and draws a
# '#[...]' in a session name in the title as a style where the opened popup
# showed it as text -- which is how a popup has looked after its first action.
POPUP_ACCENT_NOW=""
popup_accent() {
  tmux_ge 303 || return 0
  # Only INSIDE a popup that is still there.  This is a display-popup with no
  # command: in a popup it repaints the frame, but on a client with no popup
  # open tmux OPENS one, running the default shell, and blocks in it until
  # someone dismisses it.  INTERDIMUX_TITLE is set only by the popup launchers,
  # so without it there is no popup -- a hand-written binding or run-shell
  # running --action kill hung behind a shell popup before its dialog even drew
  # (BUG-53).  (So a popup you open yourself, without the title, keeps its frame
  # through a kill dialog: nothing else tells it from a pane.)  And a popup
  # closed under a waiting dialog (display-popup -C, its session killed) hangs
  # up the dialog's terminal, after which /dev/tty no longer opens: the
  # orphaned dialog's cleanup repainted a popup that was gone, and so opened a
  # shell one (BUG-52).
  [ -n "${INTERDIMUX_TITLE:-}" ] || return 0
  { : </dev/tty; } 2>/dev/null || return 0
  [ "$1" = "$POPUP_ACCENT_NOW" ] && return 0
  local style
  popup_user_border
  if [ "$1" = "danger" ]; then danger_style; style="$REPLY"; else style="$POPUP_USER_STYLE"; fi
  local -a t=()
  # -T is a FORMAT, and the title carries the session name, so any '#' in it
  # would be re-expanded on every repaint.  tmux expands a name it is GIVEN at
  # create/rename time, but connect_dir escapes a directory's name first so it
  # is stored verbatim -- a project named 'x#(cmd)' is a session of exactly that
  # name, and unescaped here cmd would run on every danger repaint.  The style
  # prefix is left alone: its '#[' is meant as a format.
  [ -n "${INTERDIMUX_TITLE:-}" ] && t=(-T "${POPUP_TITLE_STYLE}${INTERDIMUX_TITLE//'#'/##}")
  # -c: the popup to repaint is the PRESSING client's.  Without it tmux picks
  # the most recently active client, and on any other client -- one with no
  # popup open -- a display-popup without -E OPENS a shell popup and blocks.
  if tmux display-popup ${TMUX_C[@]+"${TMUX_C[@]}"} -b "$POPUP_USER_LINES" -S "$style" ${t[@]+"${t[@]}"} 2>/dev/null; then
    POPUP_ACCENT_NOW="$1"
  fi
}

# Truncate a PRE-COLOURED string to a visible column budget, keeping its escape
# sequences intact.  ${#s} counts the escapes, so measuring with it lets a
# coloured string overrun the frame while a plain one of the same visible length
# fits.  Observed: the rename dialog's "✗ a name cannot contain ':' (tmux splits
# targets there)" ran straight through the right border and off the box.
#
# Sets REPLY.  Character-at-a-time is fine here: these are single dialog lines,
# not the list.
dlg_fit() {
  local s="$1" max="$2" out="" n=0 i=0 ch j len w
  # NOT `local s="$1" … len=${#s}`: bash expands every word of a `local` command
  # before performing any of its assignments, so ${#s} reads the OUTER s — unset
  # here, which under `set -u` killed the dialog outright.
  len=${#s}
  [ "$max" -lt 2 ] && max=2

  # Nothing to do is the common case, and it has to be checked FIRST: the loop
  # below reserves a column for the ellipsis, so without this a string exactly
  # `max` cells wide lost its last character to a "…" that bought nothing.
  dlg_width "$s"
  if [ "$REPLY" -le "$max" ]; then REPLY="$s"; return 0; fi

  while [ "$i" -lt "$len" ]; do
    ch="${s:i:1}"
    if [ "$ch" = $'\033' ]; then
      # copy the whole CSI/OSC-style sequence: it costs no columns
      j=$(( i + 1 ))
      while [ "$j" -lt "$len" ] && [[ "${s:j:1}" != [a-zA-Z] ]]; do j=$(( j + 1 )); done
      out+="${s:i:j-i+1}"
      i=$(( j + 1 ))
      continue
    fi
    dlg_width "$ch"; w="$REPLY"
    if [ $(( n + w )) -gt $(( max - 1 )) ]; then out+="…"; break; fi
    out+="$ch"; n=$(( n + w )); i=$(( i + 1 ))
  done
  REPLY="${out}${RST}"
}

# dialog_open ACCENT TITLE [BODY...] — clear the screen and draw a
# centered rounded box.  Body rows are pre-colored strings whose plain
# length must fit; the row below the body is reserved for hint/status.
dialog_open() {
  local accent="$1" title="$2"
  shift 2
  local dims line w
  DLG_ROWS=24 DLG_COLS=80
  if [ -c "$tty_in" ] && dims=$({ stty size <"$tty_in"; } 2>/dev/null); then
    DLG_ROWS="${dims%% *}" DLG_COLS="${dims#* }"
  fi
  # CELLS, not characters: ${#title} counted a CJK name at half its drawn width,
  # so the box was sized for 66 cells and the title drew 87.
  dlg_width "$title"; w=$(( REPLY + 10 ))
  for line in "$@"; do
    dlg_width "$line"
    [ $(( REPLY + 8 )) -gt "$w" ] && w=$(( REPLY + 8 ))
  done
  [ "$w" -lt 44 ] && w=44
  [ "$w" -gt $(( DLG_COLS - 2 )) ] && w=$(( DLG_COLS - 2 ))
  DLG_W="$w"
  DLG_H=$(( $# + 5 ))   # top border, blank, body…, blank, hint, bottom border

  # A box taller than the popup does not just look wrong: DLG_TOP clamps to 1,
  # the bottom border is then drawn past the last row, the terminal scrolls, and
  # the scroll takes the top border and title with it -- leaving a half-drawn
  # frame over the list.  Drop body rows instead; the hint row is what carries
  # the error text and it is the one that must survive.
  local -a body=("$@")
  if [ "$DLG_H" -gt $(( DLG_ROWS - 1 )) ]; then
    local keep=$(( DLG_ROWS - 6 ))
    [ "$keep" -lt 0 ] && keep=0
    body=("${body[@]:0:keep}")
    DLG_H=$(( ${#body[@]} + 5 ))
    [ "$DLG_H" -gt "$DLG_ROWS" ] && DLG_H="$DLG_ROWS"
  fi
  set -- ${body[@]+"${body[@]}"}

  DLG_TOP=$(( (DLG_ROWS - DLG_H) / 2 ))
  [ "$DLG_TOP" -lt 1 ] && DLG_TOP=1
  DLG_LEFT=$(( (DLG_COLS - DLG_W) / 2 ))
  [ "$DLG_LEFT" -lt 1 ] && DLG_LEFT=1
  # ...and truncate the title in cells too, keeping any escapes it carries
  dlg_width "$title"
  if [ "$REPLY" -gt $(( DLG_W - 6 )) ]; then
    dlg_fit "$title" $(( DLG_W - 6 )); title="$REPLY"
  fi

  local hbar sp i r
  printf -v hbar '%*s' $(( DLG_W - 2 )) ''
  hbar="${hbar// /─}"
  printf -v sp '%*s' $(( DLG_W - 2 )) ''

  {
    printf '\033[2J\033[H\033[?25l'
    printf '\033[%d;%dH%s╭%s╮%s' "$DLG_TOP" "$DLG_LEFT" "$accent" "$hbar" "$RST"
    for (( i = 1; i < DLG_H - 1; i++ )); do
      printf '\033[%d;%dH%s│%s%s%s│%s' \
        $(( DLG_TOP + i )) "$DLG_LEFT" "$accent" "$RST" "$sp" "$accent" "$RST"
    done
    printf '\033[%d;%dH%s╰%s╯%s' $(( DLG_TOP + DLG_H - 1 )) "$DLG_LEFT" "$accent" "$hbar" "$RST"
    printf '\033[%d;%dH%s %s %s' "$DLG_TOP" $(( DLG_LEFT + 2 )) "${accent}${BOLD}" "$title" "$RST"
    r=$(( DLG_TOP + 2 ))
    for line in "$@"; do
      dlg_fit "$line" $(( DLG_W - 8 ))
      printf '\033[%d;%dH%s' "$r" $(( DLG_LEFT + 4 )) "$REPLY"
      r=$(( r + 1 ))
    done
  } >>"$tty_out"
}

# Write a hint/status line on the reserved row inside the box
dialog_status() {
  local text="$1" sp
  local r=$(( DLG_TOP + DLG_H - 2 ))
  printf -v sp '%*s' $(( DLG_W - 8 )) ''
  dlg_fit "$text" $(( DLG_W - 8 ))
  printf '\033[%d;%dH%s\033[%d;%dH%s' \
    "$r" $(( DLG_LEFT + 4 )) "$sp" \
    "$r" $(( DLG_LEFT + 4 )) "$REPLY" >>"$tty_out"
}

dialog_close() {
  # >> not >, for the same reason _action_cleanup uses it: INTERDIMUX_TTY_OUT can
  # be a regular file (that is how the dialogs are tested) and > TRUNCATES it, so
  # closing a dialog silently erased every frame the flow had drawn.  Identical
  # on a real tty.
  printf '\033[?25h' >>"$tty_out"
}

# ONE input fd for the whole process, opened on first use.
#
# `read < "$tty_in"` per call is correct for a tty — each open continues the
# terminal's key queue — but it REWINDS a regular file to offset 0, so a flow
# with two prompts read its first answer forever.  input_dialog already knew
# this and held one fd for the duration of a single call; a flow like Schedule
# asks twice, so the fd has to outlive the call.  Left open until exit.
#
# Sets REPLY to the fd number.  Returns non-zero if the source cannot be opened,
# which the callers treat as "no input" rather than blocking.
_tty_fd=""
tty_fd() {
  if [ -z "$_tty_fd" ]; then
    exec {_tty_fd}<"$tty_in" 2>/dev/null || { _tty_fd=""; return 1; }
  fi
  REPLY="$_tty_fd"
}

# Drain pending input (only on a real tty — a test fixture file would
# be consumed by the read loop)
drain_input() {
  [ -c "$tty_in" ] || return 0
  tty_fd || return 0
  local fd="$REPLY"
  while IFS= read -rsn1 -t 0.01 -u "$fd" _; do :; done
}

# confirm_dialog ACCENT TITLE [BODY...] → 0 when confirmed with y/Y
confirm_dialog() {
  local accent="$1" title="$2"
  shift 2
  dialog_open "$accent" "$title" "$@"
  dialog_status "$(hint y confirm n/esc cancel)"
  drain_input
  local key="" fd
  tty_fd || return 1        # nothing to read from → treat as "not confirmed"
  fd="$REPLY"
  # -u BEFORE the variable name: bash stops parsing options at the first
  # non-option word, so `read -rsn1 key -u "$fd"` reads STDIN and treats -u and
  # the fd number as two more variable names.  It fails silently — the key comes
  # back empty, which here reads as "the user did not confirm".
  IFS= read -rsn1 -u "$fd" key 2>/dev/null
  if [ "$key" = $'\x1b' ]; then
    drain_input   # swallow escape-sequence tails (arrow keys, etc.)
    return 1
  fi
  [[ "$key" =~ ^[yY]$ ]]
}

# Cells covered by a WIDTH STRING — one digit per character, each 0, 1 or 2
# (input_dialog keeps one alongside its buffer).  Two substitutions instead of a
# loop, because this runs on every keystroke: cells = characters - zeros + twos.
# Sets REPLY.
_dlg_cells() {
  local zeros="${1//[12]/}" twos="${1//[01]/}"
  REPLY=$(( ${#1} - ${#zeros} + ${#twos} ))
}

# The width input_dialog's field keeps for CH, with PREV and NEXT the characters
# either side of it ('' at an end of the buffer).  Sets REPLY.
#
# The field puts the cursor after any character, so where dlg_width may err
# wide this has to be exact for the sequences people type.  tmux draws some
# characters INTO the cell before them rather than into one of their own
# (screen_write_combine and utf8_should_combine, tmux 3.7b; each rule below
# measured there against #{cursor_x}):
#
#   U+FE0F after a one-cell character   widens that cell to two     ⚙ 1, ⚙️ 2
#   a non-ASCII character after a ZWJ   joins the ZWJ's cell        👨‍👩‍👧 2
#   a skin tone after a modifier base   joins the base's cell       👍🏽 2
#     -- tmux's own list of bases (_dlg_tone_base); 🎅🏽 and ✋🏽 stay 4
#
# Such a character is 0 here, and the cell U+FE0F adds goes on the character it
# widens, so a 0 always means "drawn into the cell before": the view must never
# start on one, where it would join the prompt's cell.  Measured one character
# at a time, 👍🏽 came to 4, 👨‍👩‍👧 to 6, and ⚙️ to 1+1, so a view could open on
# its U+FE0F.  (A regional indicator is 1 either way -- see dlg_width, which
# also has the medial and final Hangul jamo at 0.)
#
# One rule of that tmux function is left out on purpose: it also joins a
# modifier BASE to a skin tone standing alone before it -- 🏽👍 is two cells,
# counted four here.  Whether a tone stands alone depends on every character
# before it (🏽👍🏽👍 is 2+2 in tmux, 🏽👍🏽 is 2+2 too), so no fixed-size
# re-measure keeps it right, and leaving it out only ever errs WIDE: at every
# point of such a run the count here is at least tmux's, so the cursor may sit
# right of the text but the text never reaches the border.
_DLG_VS16=$'\xef\xb8\x8f'                 # U+FE0F, as bytes: no locale needed
_dlg_cw() {
  local cp pp
  printf -v cp '%d' "'$2" 2>/dev/null || cp=63
  if (( cp >= 0x20 && cp < 0x7f )); then
    REPLY=1                          # tmux never draws ASCII into another cell
  elif (( cp == 0xfe0f )); then
    REPLY=0; return 0
  else
    if [ -n "$1" ]; then
      printf -v pp '%d' "'$1" 2>/dev/null || pp=0
      if (( pp == 0x200d )) || { (( cp >= 0x1f3fb && cp <= 0x1f3ff )) && _dlg_tone_base "$pp"; }; then
        REPLY=0; return 0
      fi
    fi
    dlg_width "$2"
  fi
  if (( REPLY == 1 )) && [ "$3" = "$_DLG_VS16" ]; then REPLY=2; fi
  return 0
}

# True for a code point a skin tone joins: tmux's list (utf8_should_combine in
# utf8-combined.c), which is not all of Unicode's Emoji_Modifier_Base.
_dlg_tone_base() {
  local c=$1
  (( (c >= 0x1f44b && c <= 0x1f450) || (c >= 0x1f466 && c <= 0x1f469) || c == 0x1f46e \
     || (c >= 0x1f470 && c <= 0x1f478) || c == 0x1f47c || (c >= 0x1f481 && c <= 0x1f483) \
     || (c >= 0x1f485 && c <= 0x1f487) || c == 0x1f4aa || c == 0x1f575 || c == 0x1f57a \
     || c == 0x1f590 || c == 0x1f595 || c == 0x1f596 || (c >= 0x1f645 && c <= 0x1f647) \
     || (c >= 0x1f64b && c <= 0x1f64f) || (c >= 0x1f6b4 && c <= 0x1f6b6) || c == 0x1f926 \
     || (c >= 0x1f937 && c <= 0x1f939) || c == 0x1f93d || c == 0x1f93e || c == 0x1f9b5 \
     || c == 0x1f9b6 || c == 0x1f9b8 || c == 0x1f9b9 || (c >= 0x1f9cd && c <= 0x1f9cf) \
     || (c >= 0x1f9d1 && c <= 0x1f9df) ))
}

# Measure character J of input_dialog's buffer again, from its neighbours as
# they are now, into cw.  buf and cw are input_dialog's locals.  An edit changes
# the neighbours on both sides of where it happened, so every edit re-measures
# those two characters: deleting 👍 from 👍🏽 leaves a skin tone that stands
# alone, two cells wide, and deleting the U+FE0F of ⚙️ takes ⚙ back to one.
_dlg_remeasure() {
  local j=$1
  (( j >= 0 && j < ${#buf} )) || return 0
  if (( j > 0 )); then
    _dlg_cw "${buf:j-1:1}" "${buf:j:1}" "${buf:j+1:1}"
  else
    _dlg_cw "" "${buf:0:1}" "${buf:1:1}"
  fi
  cw="${cw:0:j}$REPLY${cw:j+1}"
}

# input_dialog ACCENT TITLE PROMPT INITIAL [NOTE] — a single-line text editor
# drawn inside the dialog box.  Sets REPLY (empty = cancelled).
#
# NOTE, when given, is drawn as a second body row under the field.  It goes
# there rather than in the status line because dialog_open sizes the box to fit
# its body rows, so a format hint widens the frame — while dialog_status is
# clamped to whatever width the box already has and would ellipsise it.
#
# Hand-rolled instead of `read -e`: readline owns the whole physical terminal
# line (column 0 → terminal width) and knows nothing about the box, so it
# erased the right border on backspace and snapped the cursor to column 0 once
# the field emptied.  This editor only ever repaints the field region between
# the prompt and the right border, so the frame can't be corrupted, and it
# scrolls horizontally rather than wrapping through the border on long input.
#
# The field is laid out in CELLS, not characters.  field_w always was a cell
# count, but the slice, the padding, the scroll and the cursor came from ${#buf}
# and ${buf:scroll:field_w}, so every CJK or emoji character drew two cells for
# the one it was counted as.  Three were enough to push the padding through the
# right border; a long CJK session name in Rename wrapped onto the row below;
# and the cursor sat in the middle of the text from the first wide character
# on.  The buffer, and so the value applied on Enter, was always right — only
# the picture was wrong.  dialog_open had the same bug in the title.
# Runs under the --action handler's `set +e`, so bare (( … )) tests are safe.
input_dialog() {
  local accent="$1" title="$2" prompt="$3" initial="$4"
  local note="${5:-}"
  if [ -n "$note" ]; then
    dialog_open "$accent" "$title" "" "$note"
  else
    dialog_open "$accent" "$title" ""
  fi
  dialog_status "${DIM}enter apply · esc cancel${RST}"

  local irow=$(( DLG_TOP + 2 ))
  local col_prompt=$(( DLG_LEFT + 4 ))
  dlg_width "$prompt"
  local field_start=$(( col_prompt + REPLY ))
  local field_end=$(( DLG_LEFT + DLG_W - 3 ))   # one-column gutter before the border
  local field_w=$(( field_end - field_start + 1 ))
  [ "$field_w" -lt 1 ] && field_w=1

  # The prompt is static — draw it once; the loop only repaints the field.
  printf '\033[%d;%dH%s%s%s\033[?25h' \
    "$irow" "$col_prompt" "$accent" "$prompt" "$RST" >>"$tty_out"

  # cw is buf's shadow: ONE DIGIT PER CHARACTER, that character's width in
  # cells (0, 1 or 2, from _dlg_cw).  Every edit below applies the same slice
  # to both strings, so ${cw:i:1} is always the width of ${buf:i:1}.  Each
  # character is measured as it enters the buffer, and again only when an
  # edit changes a neighbour (_dlg_remeasure): re-measuring the whole buffer on
  # every repaint made a paste quadratic, because every pasted character is
  # its own keystroke and repaint, and dlg_width costs tens of microseconds a
  # character.
  local buf="$initial" pos=${#initial} scroll=0 cw="" i pc="" cc nc
  cc="${buf:0:1}"
  for (( i = 0; i < pos; i++ )); do
    nc="${buf:i+1:1}"
    _dlg_cw "$pc" "$cc" "$nc"; cw+="$REPLY"
    pc="$cc" cc="$nc"
  done
  drain_input

  # Read the input source through the process-wide fd (see tty_fd): re-opening
  # `<"$tty_in"` rewinds a regular file to offset 0, which is an infinite loop
  # within one call and a repeated first answer across two.
  local ifd
  if tty_fd; then ifd="$REPLY"; else REPLY=""; return 0; fi
  # On a real terminal, edit in raw/no-echo mode for the duration so fast keys
  # arriving between reads aren't echoed over the box.  Ctrl-C is a byte only
  # between reads: bash's `read -N1` turns the signal back on while it waits
  # for a key, so it is mostly a SIGINT, which --action traps (the navigator's
  # main loop says what else it reaches).  Skipped for non-ttys.
  local saved_stty=""
  if [ -c "$tty_in" ]; then
    saved_stty=$(stty -g <"$tty_in" 2>/dev/null) || saved_stty=""
    # published so the --action INT/EXIT trap can restore the terminal even if
    # we are killed between here and the restore below
    _saved_stty_global="$saved_stty"
    [ -n "$saved_stty" ] && stty -echo -icanon -isig min 1 time 0 <"$tty_in" 2>/dev/null
  fi

  # Published so a caller that LOOPS on this dialog can tell "the user pressed
  # Enter" from "the input source is exhausted".  Without it, the Schedule
  # retry loop re-submitted the same rejected time forever on a closed stdin —
  # EOF is accepted below as "take what we have", which is right for one prompt
  # and non-terminating for a loop.
  _input_eof=0
  local c vis len off cur k w blank
  printf -v blank '%*s' "$field_w" ''
  while true; do
    len=${#buf}
    if (( pos <= scroll )); then
      # The cursor moved left of the view: start the view at the cursor -- or,
      # when that character is drawn into the cell before it (width 0: a
      # combining mark, say), at the character that cell belongs to.  Started
      # on the mark, the view drew it onto the prompt's blank, so every step
      # Left through decomposed text stacked one more accent there.  The
      # cursor AT the view's start needs it too: Delete of the view's first
      # character, or Backspace between it and its mark, leaves the view on
      # that mark with the cursor unmoved.
      scroll=$pos
      while (( scroll > 0 )) && [ "${cw:scroll:1}" = 0 ]; do scroll=$(( scroll - 1 )); done
    fi
    # The cursor needs the cells of the character under it — or the one blank
    # cell after the text — inside the field too.
    cur=1
    if (( pos < len )); then cur=${cw:pos:1}; (( cur < 1 )) && cur=1; fi
    _dlg_cells "${cw:scroll:pos-scroll}"; off=$REPLY
    if (( off + cur > field_w )); then
      # The cursor ran off the right edge: start at the leftmost character from
      # which it fits.  Stepping the start forward from where it was finds
      # exactly that one -- the cells from the start to the cursor only shrink
      # as the start moves right, and every start left of the old one failed
      # already -- and typing at the end, it is one step or two.  A paste is
      # one keystroke per character, and the walk back across the whole field
      # this used to do on each made a paste 3-6x slower.  A big jump (End on
      # a long line) walks back from the cursor instead: one field's width,
      # not the length of the jump.
      if (( off + cur - field_w < field_w )); then
        while (( off + cur > field_w && scroll < pos )); do
          off=$(( off - ${cw:scroll:1} )) scroll=$(( scroll + 1 ))
        done
      else
        scroll=$pos off=0
        while (( scroll > 0 )); do
          w=${cw:scroll-1:1}
          (( off + w + cur > field_w )) && break
          scroll=$(( scroll - 1 )) off=$(( off + w ))
        done
      fi
    fi
    # Nor can a character drawn into the cell before it open the field on the
    # right: drawn first, it would join the prompt's cell, outside the field.
    while (( scroll < pos )) && [ "${cw:scroll:1}" = 0 ]; do scroll=$(( scroll + 1 )); done
    # The visible text is the longest run from `scroll` that fits.  A wide
    # character that would straddle the edge is left out rather than drawn over
    # the gutter; the cell it would have started in stays blank.  At the end of
    # the text, the run is the one `off` already measured.
    if (( pos == len )); then REPLY=$off; else _dlg_cells "${cw:scroll}"; fi
    if (( REPLY <= field_w )); then
      vis="${buf:scroll}"
    else
      k=$scroll i=0
      while (( k < len )); do
        w=${cw:k:1}
        (( i + w > field_w )) && break
        i=$(( i + w )) k=$(( k + 1 ))
      done
      vis="${buf:scroll:k-scroll}"
    fi
    # At the buffer's start there is no base to walk back to: a mark or a
    # U+FE0F that an edit left first (Home, Delete on a decomposed É, or on
    # ⚙️) would join the prompt's blank -- a U+FE0F widening it to two cells
    # and pushing the whole field right.  Such characters are left out of the
    # picture; they have no cells, so `off` stands.
    if (( scroll == 0 )) && [ "${cw:0:1}" = 0 ]; then
      k=0
      while (( k < ${#vis} )) && [ "${cw:k:1}" = 0 ]; do k=$(( k + 1 )); done
      vis="${vis:k}"
    fi
    # Blank the field, draw the text, place the cursor.  Blanking first instead
    # of padding after means a glyph dlg_width over-counts (a ZWJ sequence)
    # cannot leave stale cells at the end of the field.  The prompt is drawn
    # again AFTER the text: a character tmux draws into the cell before it that
    # the widths above do not know about (a Thai, Hebrew, Arabic or Devanagari
    # mark, which dlg_width counts as a cell) can still open the view, and
    # joins the prompt's blank -- rewritten, that cell drops it in the same
    # frame instead of stacking one more on each.  Nothing else is written
    # outside [field_start, field_end], so the borders are never touched.
    printf '\033[%d;%dH%s\033[%d;%dH%s\033[%d;%dH%s%s%s\033[%d;%dH' \
      "$irow" "$field_start" "$blank" \
      "$irow" "$field_start" "$vis" \
      "$irow" "$col_prompt" "$accent" "$prompt" "$RST" \
      "$irow" $(( field_start + off )) >>"$tty_out"

    IFS= read -rsN1 -u "$ifd" c || { _input_eof=1; c=$'\n'; }   # EOF → accept what we have
    case "$c" in
      $'\n'|$'\r') break ;;                                  # accept
      $'\x1b') _dlg_esc "$ifd" || { buf=""; break; } ;;     # a key (see _dlg_esc), or lone ESC → cancel
      $'\x7f'|$'\x08') (( pos > 0 )) && {
                         buf="${buf:0:pos-1}${buf:pos}" cw="${cw:0:pos-1}${cw:pos}"; pos=$(( pos - 1 ))
                         _dlg_remeasure $(( pos - 1 )); _dlg_remeasure "$pos"; } ;;
      $'\x03') buf=""; break ;;                              # Ctrl-C → cancel
      $'\x01') pos=0 ;;                                       # Ctrl-A → start
      $'\x05') pos=$len ;;                                    # Ctrl-E → end
      $'\x15') buf="${buf:pos}" cw="${cw:pos}"; pos=0; _dlg_remeasure 0 ;;        # Ctrl-U → delete to start
      $'\x0b') buf="${buf:0:pos}" cw="${cw:0:pos}"; _dlg_remeasure $(( pos - 1 )) ;; # Ctrl-K → delete to end
      $'\x17')                                                # Ctrl-W → delete word before cursor
        local l="${buf:0:pos}" r="${buf:pos}"
        while [ -n "$l" ] && [ "${l: -1}" = ' ' ]; do l="${l%?}"; done
        while [ -n "$l" ] && [ "${l: -1}" != ' ' ]; do l="${l%?}"; done
        buf="$l$r" cw="${cw:0:${#l}}${cw:pos}"; pos=${#l}
        _dlg_remeasure $(( pos - 1 )); _dlg_remeasure "$pos" ;;
      *)
        if [[ -n "$c" && "$c" != [[:cntrl:]] ]]; then
          printf -v k '%d' "'$c" 2>/dev/null || k=0
          if (( pos == len && k >= 0x20 && k < 0x7f )); then
            # ASCII at the end -- typing, and every character of a paste:
            # nothing either side changes width, so append, and slice nothing
            buf+="$c" cw+="1"   # cw is a string of per-character widths
          else
            buf="${buf:0:pos}$c${buf:pos}" cw="${cw:0:pos}0${cw:pos}"
            _dlg_remeasure $(( pos - 1 )); _dlg_remeasure "$pos"; _dlg_remeasure $(( pos + 1 ))
          fi
          pos=$(( pos + 1 ))
        fi ;;
    esac
  done

  [ -n "$saved_stty" ] && stty "$saved_stty" <"$tty_in" 2>/dev/null
  _saved_stty_global=""
  # NOT closed: the fd is shared with every other dialog in this process.
  REPLY="$buf"
}

# Brief informational dialog
# info_flash ACCENT TITLE [BODY...] — every body line is forwarded, because
# dialog_open already lays out as many as it is given and `"${3:-}"` silently
# dropped the rest.
info_flash() {
  local _if_accent="$1" _if_title="$2"
  shift 2
  dialog_open "$_if_accent" "$_if_title" ${@+"$@"}
  sleep 0.9
  # A key pressed to dismiss the box was left for fzf once this returned: Esc
  # closed the whole navigator, and anything else became query text.
  drain_input
  dialog_close
}

# _dlg_esc FD -- the rest of a key whose ESC input_dialog has just read from FD,
# applied to its buffer (buf, cw and pos are its locals, as in _dlg_remeasure).
# Returns non-zero to cancel the dialog: for a lone ESC -- nothing after it
# within 50 ms -- as always, and for Esc pressed twice or Esc then Ctrl-C.  Any
# other byte in those 50 ms makes it an Alt chord, as readline and fzf read it:
# Alt-x IS ESC x, so Esc with another key hard on its heels does not cancel.
# Here and not beside input_dialog because only the actions below open one,
# and the fzf callbacks above would pay to parse it on every keystroke.
#
# Any other key is read WHOLE, then handled or dropped whole, never typed:
#
#   ESC b/B, ESC f/F    back / on by a word -- Alt-b/f, and what Ghostty sends
#                       for Option+Left/Right
#   ESC d/D, ESC DEL/^H delete a word forward / back
#   ESC [ ... / ESC O ...   CSI and SS3: parameter and intermediate bytes
#                       (0x20-0x3F), then one final byte (0x40-0x7E).  The
#                       arrows, by a word with any modifier but Shift (Ctrl or
#                       Alt, as readline's inputrc has them); Home and End in
#                       every spelling; Delete.
#
# It used to read ESC and ONE more byte, and cancel on anything but [ or O, so
# Alt-b threw away all the user had typed; and after the [ it took one byte
# (two after a digit), so Ctrl-Left -- ESC [ 1 ; 5 D -- went home and typed
# "5D", F5 typed "~", and Enter applied the junk.  A word is a run of letters
# and digits, as it is to readline's Alt keys, with any character drawn into
# the cell before it (a 0 in cw: the accent of an NFD é) -- so a word key never
# stops between a letter and its mark.  Ctrl-W keeps its blank-ended words.
_dlg_esc() {
  local fd=$1 c="" p="" f="" k=0 e=0
  IFS= read -rsN1 -t 0.05 -u "$fd" c || return 1
  case "$c" in
    '['|O)
      while IFS= read -rsN1 -t 0.05 -u "$fd" c; do
        printf -v k '%d' "'$c" 2>/dev/null || k=0
        if (( k >= 0x20 && k < 0x40 )); then p+="$c"; continue; fi
        (( k >= 0x40 && k < 0x7f )) && f="$c"
        break
      done
      case "$p$f" in
        D|1D|'1;2D') c=left ;;
        C|1C|'1;2C') c=right ;;
        '1;'*D) c=b ;;
        '1;'*C) c=f ;;
        *H|1~|7~) c=home ;;
        *F|4~|8~) c=end ;;
        3~) c=del ;;
        *) return 0 ;;
      esac ;;
    $'\x1b'|$'\x03') return 1 ;;
  esac
  case "$c" in
    left)  (( pos > 0 )) && pos=$(( pos - 1 )) ;;
    right) (( pos < ${#buf} )) && pos=$(( pos + 1 )) ;;
    home)  pos=0 ;;
    end)   pos=${#buf} ;;
    del)   (( pos < ${#buf} )) && {
             buf="${buf:0:pos}${buf:pos+1}" cw="${cw:0:pos}${cw:pos+1}"
             _dlg_remeasure $(( pos - 1 )); _dlg_remeasure "$pos"; } ;;
    [bB]|$'\x7f'|$'\x08')
      p="${buf:0:pos}"
      while [ -n "$p" ] && [[ "${p: -1}" != [[:alnum:]] ]]; do p="${p%?}"; done
      while [ -n "$p" ] && [[ "${p: -1}" == [[:alnum:]] || "${cw:${#p}-1:1}" == 0 ]]; do p="${p%?}"; done
      e=${#p}
      if [[ "$c" == [bB] ]]; then pos=$e; else
        buf="$p${buf:pos}" cw="${cw:0:e}${cw:pos}"; pos=$e
        _dlg_remeasure $(( pos - 1 )); _dlg_remeasure "$pos"
      fi ;;
    [fFdD])
      p="${buf:pos}"
      while [ -n "$p" ] && [[ "${p:0:1}" != [[:alnum:]] ]]; do p="${p#?}"; done
      while [ -n "$p" ] && [[ "${p:0:1}" == [[:alnum:]] || "${cw:${#buf}-${#p}:1}" == 0 ]]; do p="${p#?}"; done
      e=$(( ${#buf} - ${#p} ))
      if [[ "$c" == [fF] ]]; then pos=$e; else
        buf="${buf:0:pos}$p" cw="${cw:0:pos}${cw:e}"
        _dlg_remeasure $(( pos - 1 )); _dlg_remeasure "$pos"
      fi ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Actions (called by fzf keybindings via execute)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--action" ]; then
  set +e
  action="$2"
  spec="${3:-}"
  spec="${spec%%	*}"
  [ -z "$spec" ] && exit 0
  parse_spec "$spec"
  # in this process, not two forks of it: every action key pays for these
  spec_target_r; target="$REPLY"
  spec_label_r; label="$REPLY"

  # /dev/tty for interactive I/O; overridable for testing.  Both must be set
  # BEFORE the directory-row branch below: it calls info_flash -> dialog_open,
  # which reads $tty_in, and under set -u an unbound variable kills the process
  # outright — `set +e` does not protect against that.
  tty_in="${INTERDIMUX_TTY_IN:-${INTERDIMUX_TTY:-/dev/tty}}"
  tty_out="${INTERDIMUX_TTY_OUT:-${INTERDIMUX_TTY:-/dev/tty}}"

  # Every action below operates on a live tmux target; a directory row has none.
  if [ "$SPEC_TYPE" = "D" ]; then
    case "$action" in
      zoom) imux_msg "$label is not a tmux target" ;;
      *)    info_flash "$BOLD_AMBER" "Not applicable" "That row is a directory, not a session." ;;
    esac
    exit 0
  fi

  # A dialog hides the cursor and, in kill mode, recolours the popup border red.
  # Ctrl-C used to abandon both: the user was returned to the list with an
  # invisible cursor behind a permanently red frame, and the only way out was to
  # close the popup.  Restore unconditionally, on interrupt AND on any exit path
  # (IDEAS #22).  input_dialog also puts the terminal in raw mode, so the saved
  # stty settings are restored here too if it did not get the chance.
  _action_cleanup() {
    [ -n "${_saved_stty_global:-}" ] && stty "$_saved_stty_global" <"$tty_in" 2>/dev/null
    # >> not >: on a real tty either works, but INTERDIMUX_TTY_OUT can be a
    # regular file (that is how the dialogs are tested), and > TRUNCATES it —
    # silently destroying everything the dialog drew.
    printf '\033[?25h' >>"$tty_out" 2>/dev/null
    # Outside a popup, or once it has closed, this does nothing: popup_accent
    # checks for both itself.
    if [ "${INTERDIMUX_MODE:-switch}" = "kill" ]; then
      popup_accent danger
    else
      popup_accent user
    fi
  }
  trap '_action_cleanup; exit 130' INT TERM
  trap '_action_cleanup' EXIT

  # The row you are acting on may be gone.  The list is a snapshot: open the
  # picker, get distracted, and by the time you press ctrl-x that window may
  # have been closed from another client.  Every action used to open its dialog
  # regardless -- "Kill session 'victim'?" for a session that no longer exists --
  # and only failed after you confirmed, which is a confusing two-step for what
  # is really one fact.  Checked once here rather than in six places, and only
  # on the action path, never on the hot one.
  #
  # Deliberately NOT a guard against index reuse: if a different window has
  # since taken that index this check passes, because tmux cannot tell us it is
  # a different window from a "session:index" target alone. Fixing that needs
  # the SPEC to carry @id/%id, which is a wider change than this.
  #
  # ONE round-trip answers both "is it still there?" and everything the dialogs
  # below want to say about it.  has-session is the check, because it is the only
  # one that can fail: display-message resolves its target with CMD_FIND_CANFAIL,
  # so for a live session whose window is gone it printed the session's CURRENT
  # window instead of failing -- as the check, it passed every stale W/P row.  A
  # command that fails aborts the rest of a tmux command list, so a gone target
  # prints nothing at all.  The indices are compared as well: spec_target's exact
  # "=idx" form still falls back to a window NAMED exactly "3" once index 3 is
  # gone.  Free-text fields go last, where a stray separator cannot shift the
  # fields after them.  (The zoom and active flags are for ^z, below.)
  _t_info=$(exec tmux has-session -t "$target" \; display-message -p -t "$target" \
    "#{session_id}${US}#{window_id}${US}#{pane_id}${US}#{window_index}${US}#{pane_index}${US}#{session_windows}${US}#{window_panes}${US}#{window_zoomed_flag}${US}#{pane_active}${US}#{session_group}${US}#{session_name}${US}#{window_name}${US}#{pane_current_command}" \
    2>/dev/null)
  IFS="$US" read -r T_SID T_WID T_PID T_WIDX T_PIDX T_SWINS T_WPANES T_WZOOM T_PACT T_SGRP T_SNAME T_WNAME T_PCMD <<< "$_t_info"
  case "$SPEC_TYPE" in
    S) [ -n "$T_SID" ] ;;
    W) [ -n "$T_WID" ] && [ "$T_WIDX" = "$SPEC_WIDX" ] ;;
    P) [ -n "$T_PID" ] && [ "$T_WIDX" = "$SPEC_WIDX" ] && [ "$T_PIDX" = "$SPEC_PIDX" ] ;;
  esac || {
    if [ "$action" = zoom ]; then
      # zoom has no dialog of its own; it reports through the status line
      imux_msg "$label is gone — press ^r to reload"
    else
      info_flash "$BOLD_AMBER" "Gone" "$label no longer exists." "The list is stale — press ^r to reload."
    fi
    exit 0
  }

  # From here on, act on what the check just found, by tmux ID.  A name or an
  # index can change hands while a dialog waits for an answer (a rename, a closed
  # window with renumber-windows on); an ID never names anything else, so the
  # thing that gets killed is the thing the dialog named -- or nothing.
  case "$SPEC_TYPE" in
    S) target="$T_SID" ;;
    W) target="$T_WID" ;;
    P) target="$T_PID" ;;
  esac

  # The list shows a window by its NAME ("2:build") and a pane by what runs in
  # it, so the dialogs say that too -- "Kill window 'demo:2'?" made you map a
  # number back to the row you had just read, in the one place where getting it
  # wrong is final.  Names are user-controlled: control characters are made
  # visible, as they are for the list.
  _t_what=""
  case "$SPEC_TYPE" in
    W) _t_what="$T_WNAME" ;;
    P) _t_what="$T_PCMD" ;;
  esac
  if [ -n "$_t_what" ]; then
    sanitize_args "$_t_what"
    label="$label $REPLY"
  fi

  # Destroying a session detaches its clients (default detach-on-destroy),
  # ejecting the user from tmux even when other sessions exist -- so hop them to
  # the most recently used session that survives first, and the stay-open kill
  # workflow carries on.  SID is the session going away; GROUP, when given,
  # takes every session of that group with it (grouped sessions share their
  # windows, so the last window's death empties all of them).  With nowhere to
  # go the clients stay, and tmux's detach is the honest outcome.
  hop_clients_off() {
    local sid="$1" grp="${2:-}" fb="" id g c csid cgrp
    while IFS="$US" read -r _ id g; do
      [ -n "$id" ] || continue
      [ "$id" = "$sid" ] && continue
      [ -n "$grp" ] && [ "$g" = "$grp" ] && continue
      fb="$id"; break
    done <<< "$(tmux list-sessions -F "#{?session_last_attached,#{session_last_attached},#{session_activity}}${US}#{session_id}${US}#{session_group}" 2>/dev/null \
                | sort -s -t "$US" -k1,1nr)"
    [ -n "$fb" ] || return 0
    while IFS="$US" read -r c csid cgrp; do
      [ -n "$c" ] || continue
      if [ "$csid" = "$sid" ] || { [ -n "$grp" ] && [ "$cgrp" = "$grp" ]; }; then
        tmux switch-client -c "$c" -t "$fb" 2>/dev/null
      fi
    done <<< "$(tmux list-clients -F "#{client_name}${US}#{session_id}${US}#{session_group}" 2>/dev/null)"
    return 0
  }

  case "$action" in
    kill)
      popup_accent danger
      # The last window of a session -- or the last pane of its last window --
      # takes the session with it, and every client on it with the session.
      # Say so while there is still a choice, and hop the clients off first,
      # exactly as for a session kill: the README's "no surprise detach" was
      # only ever kept for session rows, and ctrl-x on the only window of the
      # session you were in dropped you out of tmux mid-dialog.
      _k_last=0
      case "$SPEC_TYPE" in
        W) [ "$T_SWINS" = 1 ] && _k_last=1 ;;
        P) [ "$T_SWINS" = 1 ] && [ "$T_WPANES" = 1 ] && _k_last=1 ;;
      esac
      _k_body=("This cannot be undone.")
      if [ "$_k_last" = 1 ]; then
        sanitize_args "$T_SNAME"
        _k_what=window; [ "$SPEC_TYPE" = P ] && _k_what=pane
        _k_body=("It is the last $_k_what of '$REPLY', so the session closes too." "${_k_body[@]}")
      fi
      if confirm_dialog "$BOLD_RED" "Kill ${label}?" "${_k_body[@]}"; then
        case "$SPEC_TYPE" in
          S)
            hop_clients_off "$T_SID"
            tmux kill-session -t "$target" 2>/dev/null
            ;;
          W|P)
            # Asked again now, not trusted from before the dialog: a window
            # opened or closed while it waited changes the answer, and a hop
            # that was not needed moves the user for nothing.
            _k_now=$(tmux display-message -p -t "$target" "#{session_windows}${US}#{window_panes}" 2>/dev/null)
            IFS="$US" read -r _k_sw _k_wp <<< "$_k_now"
            if [ "$_k_sw" = 1 ] && { [ "$SPEC_TYPE" = W ] || [ "$_k_wp" = 1 ]; }; then
              hop_clients_off "$T_SID" "$T_SGRP"
            fi
            if [ "$SPEC_TYPE" = W ]; then
              tmux kill-window -t "$target" 2>/dev/null
            else
              tmux kill-pane   -t "$target" 2>/dev/null
            fi
            ;;
        esac
        if [ $? -eq 0 ]; then
          dialog_status "${GREEN}✓ killed${RST}"
        else
          dialog_status "${RED}✗ failed to kill ${label}${RST}"
        fi
        sleep 0.35
      fi
      # Kill mode keeps its standing danger frame; other modes restore
      # the user's configured border
      if [ "${INTERDIMUX_MODE:-switch}" = "kill" ]; then
        popup_accent danger
      else
        popup_accent user
      fi
      dialog_close
      ;;

    rename)
      if [ "$SPEC_TYPE" = "P" ]; then
        info_flash "$BOLD_AMBER" "Rename" "Panes cannot be renamed."
        exit 0
      fi
      # The guard's round-trip already fetched both names.
      case "$SPEC_TYPE" in
        S) current_name="$T_SNAME" ;;
        W) current_name="$T_WNAME" ;;
      esac
      input_dialog "$BOLD_AMBER" "Rename ${label}" "❯ " "$current_name"
      new_name="$REPLY"
      # The picker itself reaches any session name -- spec_target resolves the
      # ones tmux's targets cannot spell to an ID -- but two kinds of name are
      # still refused here, because nothing ELSE can reach them by name: tmux
      # splits a target at its first ':' (so `tmux attach -t my:app` cannot find
      # "my:app"), and reads a leading '$' as a session ID ("$1" is session 1,
      # whatever it is called).  tmux accepts both renames, so saying no is the
      # dialog's job.  '.' is fine: "=my.app:" names the session.
      _bad_name=""
      case "$new_name" in
        *:*) _bad_name="a name cannot contain ':' (tmux splits targets there)" ;;
      esac
      case "$SPEC_TYPE:$new_name" in
        'S:$'*) _bad_name="a session name cannot start with '\$' (tmux reads it as an ID)" ;;
      esac
      if [ -n "$_bad_name" ]; then
        dialog_status "${RED}✗ ${_bad_name}${RST}"
        sleep 1.2
        dialog_close
        exit 0
      fi
      if [ -n "$new_name" ] && [ "$new_name" != "$current_name" ]; then
        # Capture tmux's own message instead of discarding it: "duplicate
        # session: two" tells the user what to do, where "failed to rename"
        # leaves them guessing (IDEAS #23).
        #
        # The new name is FORMAT-EXPANDED by tmux, the target is not: "proj#Sx"
        # was stored as "proj<this session>x" while the dialog said "renamed to
        # proj#Sx".  esc_fmt is the escape, and the status line reads the name
        # back from tmux (by ID, which a rename does not change) rather than
        # echoing what was typed.
        _err=""
        esc_fmt "$new_name"
        case "$SPEC_TYPE" in
          S) _err=$(tmux rename-session -t "$target" -- "$REPLY" 2>&1) ;;
          W) _err=$(tmux rename-window  -t "$target" -- "$REPLY" 2>&1) ;;
        esac
        if [ $? -eq 0 ]; then
          case "$SPEC_TYPE" in
            S) _got=$(tmux display-message -p -t "$target" '#{session_name}' 2>/dev/null) ;;
            W) _got=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null) ;;
          esac
          sanitize_args "${_got:-$new_name}"
          dialog_status "${GREEN}✓ renamed to ${REPLY}${RST}"
        else
          _err="${_err//$'\n'/ }"
          [ "${#_err}" -gt $(( DLG_W - 12 )) ] && _err="${_err:0:DLG_W-13}…"
          dialog_status "${RED}✗ ${_err:-failed to rename}${RST}"
          sleep 0.9
        fi
        sleep 0.35
      fi
      dialog_close
      ;;

    zoom)
      # Bound via execute-silent (no terminal handover) — errors go to
      # the tmux status line instead of a dialog.
      if [ "$SPEC_TYPE" != "P" ]; then
        imux_msg "only panes can be zoomed"
        exit 0
      fi
      # resize-pane -Z toggles the WINDOW's zoom, whichever pane it names: with
      # another pane of the window zoomed, ^z on this one only unzoomed that
      # one, the opposite of what the hint says.  select-pane -Z moves the zoom
      # to it instead.  On the zoomed pane itself, ^z still unzooms.
      if [ "$T_WZOOM" = 1 ] && [ "$T_PACT" = 0 ]; then
        tmux select-pane -Z -t "$target"
      else
        tmux resize-pane -Z -t "$target"
      fi 2>/dev/null || imux_msg "failed to toggle zoom"
      ;;

    detach)
      if [ "$SPEC_TYPE" != "S" ]; then
        info_flash "$BOLD_AMBER" "Detach" "Only sessions can be detached."
        exit 0
      fi
      if confirm_dialog "$BOLD_AMBER" "Detach clients from ${label}?"; then
        if tmux detach-client -s "$target" 2>/dev/null; then
          dialog_status "${GREEN}✓ detached${RST}"
        else
          dialog_status "${RED}✗ failed to detach${RST}"
        fi
        sleep 0.35
      fi
      dialog_close
      ;;

    send)
      input_dialog "$BOLD_AMBER" "Send keys to ${label}" "❯ " "" "$SEND_NOTE"
      send_cmd="$REPLY"
      if [ -n "$send_cmd" ]; then
        # Build list of pane targets to send to
        send_targets=()
        case "$SPEC_TYPE" in
          P)
            send_targets+=("$target")
            ;;
          W)
            # All panes in this window
            while read -r pidx; do
              send_targets+=("$pidx")
            done < <(tmux list-panes -t "$target" -F '#{pane_id}' 2>/dev/null)
            ;;
          S)
            # All panes in all windows of this session
            while read -r pidx; do
              send_targets+=("$pidx")
            done < <(tmux list-panes -s -t "$target" -F '#{pane_id}' 2>/dev/null)
            ;;
        esac

        sent=0 failed=0
        for t in "${send_targets[@]}"; do
          # send_input: a lone key name pressed, any other text typed
          # literally with a trailing ';' intact, and a pane in copy-mode
          # taken out of it first so the command actually runs
          if send_input "$t" "$send_cmd" 2>/dev/null; then
            sent=$((sent + 1))
          else
            failed=$((failed + 1))
          fi
        done

        if [ "$failed" -eq 0 ]; then
          dialog_status "${GREEN}✓ sent to ${sent} pane(s)${RST}"
        else
          dialog_status "${RED}✗ sent to ${sent} pane(s), ${failed} failed${RST}"
        fi
        sleep 0.35
      fi
      dialog_close
      ;;

    schedule)
      if ! command -v at >/dev/null 2>&1; then
        info_flash "$BOLD_AMBER" "Schedule" "'at' is not installed." \
          "Without it only sub-minute delays work." "Install it, then enable its job-runner."
        exit 0
      fi

      # A scheduled command fires into ONE pane, and the job body carries one
      # pane id.  Fanning it out the way ctrl-t's send does is almost never what
      # you meant for something that runs unattended an hour later, so a window
      # or session row resolves to its ACTIVE pane — and the dialog names the
      # pane it chose, so the narrowing is never silent.
      # $target is the session/window/pane ID the guard resolved, which
      # sched_resolve narrows to its active pane.
      sched_pick="$target"
      if ! sched_resolve "$sched_pick"; then
        info_flash "$BOLD_AMBER" "Schedule" "Could not resolve a pane for ${label}."
        exit 0
      fi

      sched_when="" sched_cmd="" sched_out="" sched_rc=0
      sched_note="${DIM}5m · 90m · 2h · 17:30 · 1:10am · noon tomorrow${RST}"
      while true; do
        input_dialog "$BOLD_AMBER" "Schedule → ${SCHED_LABEL}" "when ❯ " "$sched_when" "$sched_note"
        sched_when="$REPLY"
        [ -n "$sched_when" ] || { dialog_close; exit 0; }

        # Asked once and kept across a retry: a rejected time must not cost the
        # user the command they already typed.
        if [ -z "$sched_cmd" ]; then
          input_dialog "$BOLD_AMBER" "Schedule ${sched_when} → ${SCHED_LABEL}" "❯ " "" \
            "$SEND_NOTE"
          sched_cmd="$REPLY"
          [ -n "$sched_cmd" ] || { dialog_close; exit 0; }
        fi

        # Relative shorthand.  `at` rejects a bare 1-3 digit number outright
        # ("Garbled time" — probed on this host) and needs four digits for HHMM,
        # so reading 1-3 digits as MINUTES extends its grammar without shadowing
        # anything it accepts: 1730 still means 17:30.  10# because a leading
        # zero would otherwise be parsed as octal, and 09 is not a number.
        sched_secs=""
        if [[ "$sched_when" =~ ^([0-9]+)([smhd])$ ]]; then
          case "${BASH_REMATCH[2]}" in
            s) sched_secs=$(( 10#${BASH_REMATCH[1]} )) ;;
            m) sched_secs=$(( 10#${BASH_REMATCH[1]} * 60 )) ;;
            h) sched_secs=$(( 10#${BASH_REMATCH[1]} * 3600 )) ;;
            d) sched_secs=$(( 10#${BASH_REMATCH[1]} * 86400 )) ;;
          esac
        elif [[ "$sched_when" =~ ^[0-9]{1,3}$ ]]; then
          sched_secs=$(( 10#$sched_when * 60 ))
        fi

        # Submit through our own CLI rather than re-implementing the job body:
        # the server-pid guard, the explicit socket, and the POSIX quoting for
        # atd's /bin/sh all live there and must not be forked into two copies.
        if [ -n "$sched_secs" ]; then
          sched_out=$(bash "$SCRIPT_PATH" --send-in "$sched_secs" "$SCHED_PANE" "$sched_cmd" 2>&1)
        else
          sched_out=$(bash "$SCRIPT_PATH" --send-at "$sched_when" "$SCHED_PANE" "$sched_cmd" 2>&1)
        fi
        sched_rc=$?
        [ "$sched_rc" -eq 0 ] && break

        # Nothing left to read: retrying would resubmit the same rejected spec
        # forever, because input_dialog accepts at EOF rather than cancelling.
        if [ "${_input_eof:-0}" = 1 ]; then
          dialog_status "${RED}✗ ${sched_when} was refused${RST}"
          dialog_close
          exit 0
        fi

        # at's own complaint is the useful one ("Problem in hours
        # specification…"); our "at rejected the time spec" line only repeats
        # what the user just typed.  Re-open the field that was wrong, keeping
        # its value so a one-character typo is a one-character fix.
        sched_msg=$(printf '%s\n' "$sched_out" | grep -v '^interdimux:' | head -1)
        [ -n "$sched_msg" ] || sched_msg=$(printf '%s\n' "$sched_out" | head -1)
        sched_note="${RED}✗ ${sched_msg}${RST}"
      done

      # "interdimux: job 5 at Mon Jul 28 01:10:00 2026 -> sess:0.0 (%3)"
      sched_job="" sched_at=""
      _sched_re='^interdimux: job ([0-9]+) at (.*) -> '
      if [[ "$sched_out" =~ $_sched_re ]]; then
        sched_job="${BASH_REMATCH[1]}"; sched_at="${BASH_REMATCH[2]}"
      fi

      dlg_fit "$sched_cmd" 60; sched_cmd_disp="$REPLY"
      if [ -n "$sched_job" ]; then
        # Showing the RESOLVED time is the whole point of this screen: "1:10am"
        # is tomorrow, and "13:00" typed at 13:31 is also tomorrow.  Undo is
        # offered here rather than making the user go find the Jobs view, which
        # is where they would only look if they already suspected a mistake.
        sched_dlg=(
          "${GREEN}✓${RST} ${BOLD}${sched_at}${RST}"
          "${DIM}→${RST} ${SCHED_LABEL} ${DIM}(${SCHED_PANE})${RST}"
          "${DIM}\$${RST} ${sched_cmd_disp}"
        )
        # The job is queued; it only RUNS if at's job-runner is active (atd, or
        # atrun on macOS — which ships disabled).  A bare green ✓ would be a lie
        # on such a host, so surface the one thing between "scheduled" and "ran".
        # Only when the runner is CONFIRMED down — never on an "unknown" probe.
        if [ "$(at_daemon_state)" = down ]; then
          sched_dlg+=( "${RED}won't fire — at's job-runner is off (see --doctor)${RST}" )
        fi
        dialog_open "$BOLD_AMBER" "Scheduled" "${sched_dlg[@]}"
        dialog_status "$(hint u undo 'any key' close)"
        drain_input
        sched_key=""
        tty_fd && IFS= read -rsn1 -u "$REPLY" sched_key 2>/dev/null
        if [[ "$sched_key" =~ ^[uU]$ ]]; then
          if bash "$SCRIPT_PATH" --sched-cancel "$sched_job" >/dev/null 2>&1; then
            dialog_status "${GREEN}✓ cancelled job ${sched_job}${RST}"
          else
            dialog_status "${RED}✗ could not cancel job ${sched_job}${RST}"
          fi
          sleep 0.5
        fi
        # "any key" is a one-byte read, so the rest of a key that sends more
        # (an arrow is ESC [ B) was left for fzf, and came back as query text.
        drain_input
      else
        # The sub-minute path runs on a tmux timer, which has no job id to
        # cancel and dies with the server.  Say so rather than imply a queue.
        info_flash "$BOLD_AMBER" "Scheduled" \
          "${GREEN}✓${RST} in ${sched_when} ${DIM}→${RST} ${SCHED_LABEL} ${DIM}(${SCHED_PANE})${RST}" \
          "${DIM}\$${RST} ${sched_cmd_disp}" \
          "${DIM}tmux timer — cannot be cancelled, lost if the server exits${RST}"
      fi
      dialog_close
      ;;

    swap)
      case "$SPEC_TYPE" in
        W|P) ;;
        *)
          info_flash "$BOLD_AMBER" "Swap" "Only windows and panes can be swapped."
          exit 0
          ;;
      esac

      # Call gather_targets directly (subprocess would hit set -euo issues)
      swap_list=$(gather_targets)
      case "$SPEC_TYPE" in
        W) swap_list=$(printf '%s\n' "$swap_list" | grep $'\tW:' || true) ;;
        P) swap_list=$(printf '%s\n' "$swap_list" | grep $'\tP:' || true) ;;
      esac
      [ -z "$swap_list" ] && { info_flash "$BOLD_AMBER" "Swap" "No valid swap targets."; exit 0; }

      # Name the SOURCE in the prompt.  The destination list looks exactly like
      # the navigator's, so a picker headed only "swap with ❯" gave no way to
      # tell which of the two ends you had already chosen -- and swapping the
      # wrong pair is not obviously wrong until you look for the window you
      # meant to move.  parse_spec already ran on "$spec" for the type check
      # above, so the label is free.
      # $label is the guard's: it names the window or what runs in the pane,
      # the same words the dialogs use.
      _swap_src="$label"
      # A session name can contain a newline, which a prompt cannot.
      _swap_src="${_swap_src//$'\n'/ }"

      printf '\033[2J\033[H' >>"$tty_out"
      HINT_PREVIEW_PCT=0   # no preview here, and an execute child inherits the navigator's
      _swap_freeze=(--no-hscroll)
      fzf_ge 67 && _swap_freeze=(--freeze-left=1)
      hint_flag enter 'swap destination' 2 esc cancel 1
      dest=$(printf '%s\n' "$swap_list" | fzf \
        "${FZF_THEME[@]}" \
        "${_swap_freeze[@]}" \
        --delimiter=$'\t' \
        --with-nth=1..3 \
        --nth=1,3 \
        --prompt="swap $_swap_src with ❯ " \
        ${HINT_FLAG[@]+"${HINT_FLAG[@]}"} \
      ) || exit 0

      dest_spec="${dest##*	}"
      parse_spec "$dest_spec"
      dest_target=$(spec_target)
      # The destination was listed when this picker opened, and may have
      # closed since: checked by index, as the source was, and swapped by ID.
      # A stale "=s:=3" finds a window NAMED "3" -- and swapped with it.
      if ! spec_at "$dest_target"; then
        imux_msg "$(spec_label) no longer exists, so nothing was swapped"
        exit 0
      fi
      dest_target="$SPEC_AT"

      # The source is the ID the guard resolved before the picker opened.
      parse_spec "$spec"
      src_target="$target"

      case "$SPEC_TYPE" in
        W) tmux swap-window -s "$src_target" -t "$dest_target" 2>/dev/null ;;
        P) tmux swap-pane   -s "$src_target" -t "$dest_target" 2>/dev/null ;;
      esac

      if [ $? -ne 0 ]; then
        imux_msg "swap failed"
      fi
      ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# New session from directory (ctrl-o)
# ---------------------------------------------------------------------------
#
# Exits 0 after creating/switching, non-zero when cancelled (the
# navigator's ctrl-o binding uses this to decide whether to reopen).

if [ "${1:-}" = "--dirs" ]; then
  set +e

  # Optional live deep search: re-scan as the query changes.  The
  # scanner is the matcher then — fzf's own filtering is disabled, since
  # it would re-filter against the trimmed *display* path and hide rows
  # whose matching text was elided into "…/".
  dirs_extra=()
  ctrl_f_extra=""
  if [ "$DIRS_LIVE" = "on" ]; then
    dirs_extra+=(--disabled)
    dirs_extra+=(--bind="change:reload:sleep 0.1; bash '$SCRIPT_PATH' --dirs-list --deep {q}")
  else
    # Same display-path pitfall on ctrl-f: clear the query once the deep
    # results load, so none of them are pre-hidden by the text that
    # produced them (the header keeps showing what was searched)
    ctrl_f_extra="+clear-query"
  fi
  fzf_ge 61 && dirs_extra+=(--ghost='directory name or path')

  # Empty state (IDEAS #28).  A fruitless deep search leaves a blank panel with
  # no visible way out: the list is gone and nothing says that ^r puts the
  # default view back.
  #
  # The PROMPT carries it, not the header: ^f and ^g already own the header via
  # transform-header, and a `result` bind restoring a default would clobber the
  # "deep search"/"browse" header they had just set.  The prompt is unowned, and
  # it is where the eye already is while typing.
  #
  # ONE bind on `result`, dispatching on the count -- not a `zero` bind plus a
  # `result` bind.  Both events fire when the list empties, and `result` runs
  # last: the pair rendered the message and then immediately overwrote it, so
  # nothing was visible at all (verified in a real pty before this was changed).
  #
  # FZF_MATCH_COUNT needs fzf >= 0.51, the same floor as the inline callbacks.
  if fzf_ge 51; then
    dirs_extra+=(--bind="result:transform-prompt:[ \"\${FZF_MATCH_COUNT:-1}\" -eq 0 ] && printf '%s' '∅ nothing matched · ^r resets ❯ ' || printf '%s' 'new session ❯ '")
  fi

  # The default header is static and this process already has the builder —
  # re-exec'ing the whole script for it cost ~18 ms of dead time before the
  # picker could open.  (The ctrl-f/ctrl-g binds still call --dirs-hints:
  # theirs are per-mode and carry the live query.)
  HINT_PREVIEW_PCT=40
  hint_flag enter create 2 ^f 'deep search' 5 ^g 'browse into' 4 ^r reset 3 esc cancel 1

  # Every --dirs-list reload and every --dirs-preview cursor move asks
  # is_remote_path: classify the mount table once, here, for all of them.
  mounts_export

  # pipefail off for THIS pipeline only, exactly as the navigator's
  # `gather_targets | fzf` needs it.  --dirs-list is a slow STREAMING producer --
  # a filesystem scan, measured at 76 ms with the default config and 4.85 s
  # against a 1500-directory tree -- so accepting a row before the scan finishes
  # closes the pipe under it and it dies with SIGPIPE.  Verified:
  # `--dirs-list | head -1` leaves PIPESTATUS "141 0".  With pipefail on, the
  # substitution reports that 141 rather than fzf's 0, `|| exit 1` reads it as a
  # cancel, and the directory the user just picked is silently never opened.
  #
  # PIPESTATUS is no help here: inside a command substitution it describes the
  # substitution, not the inner pipeline, and ${PIPESTATUS[1]} is fatal under
  # `set -u`.
  #
  # Restoring AFTER the `|| exit 1` is deliberate: the cancel path leaves the
  # process, and the enclosing --dirs block already runs under `set +e`.
  #
  # Under the navigator the producer starts with /dev/null for its stderr, as
  # fzf starts the reloads.  Its bash warns before any of this file runs when
  # LC_ALL names a locale that is not installed (an ssh session forwards one),
  # and with this process's stderr, which is ERR_FILE, that put the warning on
  # the status line and in errors.log on every ^o.  --dirs-list re-attaches
  # itself to ERR_FILE (see the top of the file), so its own errors still go
  # there.
  _dl_err=2
  [ -z "${INTERDIMUX_ERR_FILE:-}" ] || exec {_dl_err}>/dev/null
  set +o pipefail
  selected=$(bash "$SCRIPT_PATH" --dirs-list 2>&"$_dl_err" | fzf \
    "${FZF_THEME[@]}" \
    --no-sort \
    --delimiter=$'\t' \
    --with-nth=1..2 \
    --nth=1 \
    --prompt='new session ❯ ' \
    ${HINT_FLAG[@]+"${HINT_FLAG[@]}"} \
    --preview="bash '$SCRIPT_PATH' --dirs-preview {-1}" \
    --preview-window="right,40%,border-left,nowrap" \
    --bind="ctrl-f:reload(bash '$SCRIPT_PATH' --dirs-list --deep {q})+transform-$HINT_BAR(bash '$SCRIPT_PATH' --dirs-hints deep {q})${ctrl_f_extra}" \
    --bind="ctrl-g:reload(bash '$SCRIPT_PATH' --dirs-list --scan {-1})+transform-$HINT_BAR(bash '$SCRIPT_PATH' --dirs-hints browse {-1})" \
    --bind="ctrl-r:reload(bash '$SCRIPT_PATH' --dirs-list)+transform-$HINT_BAR(bash '$SCRIPT_PATH' --dirs-hints)" \
    ${dirs_extra[@]+"${dirs_extra[@]}"} \
  ) || exit 1
  set -o pipefail

  dir_path="${selected##*	}"
  dir_path="${dir_path%/}"
  [ -z "$dir_path" ] && exit 1
  # Physical path, so comparisons match finder output (which resolves symlinks)
  dir_path=$(cd "$dir_path" 2>/dev/null && pwd -P || echo "$dir_path")
  # Removed since the list was built: refused, as the navigator's D row refuses
  # it.  tmux takes `new-session -c <missing>` without a word and starts the
  # shell in $HOME, so this became a session named after the directory, in the
  # wrong place.  Exit 1 is the cancel, so the navigator reopens.
  [ -d "$dir_path" ] || { imux_msg "directory '$dir_path' no longer exists"; exit 1; }

  record_dir_use "$dir_path"
  connect_dir "$dir_path"
  exit 0
fi

# ---------------------------------------------------------------------------
# List-only mode (used by fzf reload binding)
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--list" ]; then
  set +e
  gather_targets
  exit 0
fi

# --jump N — switch to the Nth session in the picker's own order, no popup.
#
# With the default MRU ordering the current session is parked last, so N=1 is
# the previous session, N=2 the one before that, and so on: a fixed number is a
# fixed destination for as long as you do not visit anything else.  That is the
# whole point — muscle memory needs the target not to move, which a fuzzy query
# cannot promise.
#
# The order comes from gather_targets rather than a second sort here, so "the
# Nth session" means exactly the Nth session the picker would show, under
# @interdimux-order 'mru' or 'index' alike.  Duplicating the sort would let the
# two drift, and a jump that lands somewhere other than the row you counted is
# worse than no jump at all.
#
# Bindable on its own for a two-keystroke hop with no popup:
#   bind-key -n M-2 run-shell -b "bash …/interdimux.sh --jump 2"
# and bound to alt-1..alt-5 inside the navigator.
if [ "${1:-}" = "--jump" ]; then
  set +e
  _jn="${2:-}"
  case "$_jn" in
    ''|*[!0-9]*) echo "interdimux: usage: --jump N (1-based)" >&2; exit 2 ;;
  esac
  [ "$_jn" -ge 1 ] || { echo "interdimux: --jump is 1-based" >&2; exit 2; }

  _jt=$(gather_targets 2>/dev/null | awk -F'\t' -v n="$_jn" '
    $4 ~ /^S:/ { c++; if (c == n) { print substr($4, 3); exit } }')
  if [ -z "$_jt" ]; then
    imux_msg "no session #$_jn"
    exit 1
  fi
  # The same target the picker's Enter would use (a "$1" or "c:d" name cannot
  # be spelled "=name"), and the client that pressed the key -- not whichever
  # one tmux thinks was active last.
  parse_spec "S:$_jt"
  tmux switch-client ${TMUX_C[@]+"${TMUX_C[@]}"} -t "$(spec_target)" 2>/dev/null || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# Popup launcher — single source of popup chrome (border, title, size)
# ---------------------------------------------------------------------------

# Script path with single quotes escaped, for embedding in tmux command
# strings
# (SQ_SCRIPT is precomputed next to SCRIPT_PATH — see the top of the file.)

# Resolved options forwarded into the popup, so the navigator and every
# fzf-spawned subprocess (header/preview/reload, which run on each
# cursor move) skip the tmux option round-trips.
env_fwd_vars() {
  ENV_FWD=(
    "INTERDIMUX_SHOW_PREVIEW=$SHOW_PREVIEW"
    "INTERDIMUX_SHOW_FULL_COMMAND=$SHOW_FULL_COMMAND"
    "INTERDIMUX_SHOW_GIT_BRANCH=$SHOW_GIT_BRANCH"
    "INTERDIMUX_POPUP_WIDTH=$POPUP_WIDTH"
    "INTERDIMUX_POPUP_HEIGHT=$POPUP_HEIGHT"
    "INTERDIMUX_ORDER=$ORDER"
    "INTERDIMUX_FZF_OPTS=$FZF_USER_OPTS"
    "INTERDIMUX_RECENT_LIMIT=$RECENT_LIMIT"
    "INTERDIMUX_SCAN_DEPTH=$SCAN_DEPTH"
    "INTERDIMUX_USE_ZOXIDE=$USE_ZOXIDE"
    "INTERDIMUX_DIRS_LIVE=$DIRS_LIVE"
    "INTERDIMUX_PROJECT_MARKERS=$EXTRA_MARKERS"
    "INTERDIMUX_STARTUP_COMMAND=$STARTUP_COMMAND"
    "INTERDIMUX_HYDRATE=$HYDRATE"
    "INTERDIMUX_SHOW_DIRS=$SHOW_DIRS"
    "INTERDIMUX_DIRS_LIMIT=$DIRS_LIMIT"
    "INTERDIMUX_RAW=$RAW_MODE"
    "INTERDIMUX_HIDE=$HIDE_PATTERNS"
    "INTERDIMUX_SESSION_RULE=$SESSION_RULE"
    "INTERDIMUX_SCOPE_HIGHLIGHT=$SCOPE_HIGHLIGHT"
    "INTERDIMUX_SHOW_TITLE=$SHOW_TITLE"
    "INTERDIMUX_TITLE_MAX=$TITLE_MAX"
    "INTERDIMUX_AGENTS=$AGENT_NAMES"
    "INTERDIMUX_AGENT_ARGS=$AGENT_ARGS"
    "INTERDIMUX_AGENT_STATE=$AGENT_STATE"
    "INTERDIMUX_CLAUDE_DIR=$CLAUDE_DIR"
    "INTERDIMUX_TITLE_RULES=$TITLE_RULES_FILE"
    "INTERDIMUX_AGENT_SEPARATOR=$AGENT_SEPARATOR"
    "INTERDIMUX_PROJECT_DIRS=$PROJECT_DIRS"
    "INTERDIMUX_COLOR_ACCENT=$COLOR_ACCENT"
    "INTERDIMUX_COLOR_PATH=$COLOR_PATH"
    "INTERDIMUX_COLOR_GIT=$COLOR_GIT"
    "INTERDIMUX_COLOR_SSH=$COLOR_SSH"
    "INTERDIMUX_COLOR_EDITOR=$COLOR_EDITOR"
    "INTERDIMUX_COLOR_SUCCESS=$COLOR_SUCCESS"
    "INTERDIMUX_COLOR_DANGER=$COLOR_DANGER"
    "INTERDIMUX_COLOR_TREE=$COLOR_TREE"
    "INTERDIMUX_COLOR_SEPARATOR=$COLOR_SEPARATOR"
    "INTERDIMUX_COLOR_QUERY=$COLOR_QUERY"
    "INTERDIMUX_COLOR_MATCH_CURRENT=$COLOR_MATCH_CURRENT"
    "INTERDIMUX_COLOR_CURRENT_BG=$COLOR_CURRENT_BG"
    "INTERDIMUX_COLOR_HEADER=$COLOR_HEADER"
    "INTERDIMUX_COLOR_BORDER=$COLOR_BORDER"
    "INTERDIMUX_COLOR_MENU_SEL_FG=$COLOR_MENU_SEL_FG"
    "INTERDIMUX_FZF_MINOR=$FZF_MINOR"
    "INTERDIMUX_TMUX_VNUM=$TMUX_VNUM"
    # Tells the child that every option above was already resolved, so
    # load_tmux_opts can skip its tmux round-trip even when a value is empty.
    # Every get_opt env var MUST be forwarded above for this to be correct --
    # tests/test_config_fwd.sh enforces that.
    "INTERDIMUX_OPTS_PRIMED=1"
  )
}

# On tmux >= 3.3 the vars ride in as display-popup -e flags — no shell
# parsing at all, so a fish/dash default-shell can't break them.
env_fwd_flags() {
  local kv
  ENV_FWD_FLAGS=()
  env_fwd_vars
  for kv in "${ENV_FWD[@]}"; do ENV_FWD_FLAGS+=(-e "$kv"); done
}

# tmux 3.2 fallback (no -e): an `env` prefix on the popup command — a
# plain command word, so it also survives non-POSIX job shells.
build_env_fwd() {
  local kv out="env"
  env_fwd_vars
  # POSIX quoting, not %q — the popup command is run by a job shell we do not
  # control, and an option value may hold a newline (@interdimux-startup-command
  # is multi-line by design).  See shq().
  for kv in "${ENV_FWD[@]}"; do shq "$kv"; out+=" $REPLY"; done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# --doctor in a popup (the dashboard's Health entry)
# ---------------------------------------------------------------------------
#
# fzf is the pager, not `less`: it is already a hard dependency, it is already
# themed to match every other panel here, Esc already closes it, and search over
# a health report is worth having rather than something to suppress.  On
# fzf >= 0.74 --raw keeps the non-matching lines on screen, dimmed, so filtering
# narrows the report instead of shredding the sections out of it.
#
# ^r re-runs the checks in place, which is the whole point after fixing one.
if [ "${1:-}" = "--doctor-view" ]; then
  set +e
  _dv_extra=()
  if fzf_ge 74; then
    _dv_extra+=(--raw --gutter-raw=' ' --color="nomatch:${COLOR_TREE}:strip:dim")
  fi
  HINT_PREVIEW_PCT=0   # no preview here, and an execute child inherits the navigator's
  hint_flag '^r' recheck 2 esc close 1
  # pipefail off for THIS pipeline, the same guard the other three pickers carry:
  # --doctor exits 1 when it found a problem, and with pipefail on that status
  # would mask fzf's.
  set +o pipefail
  bash "$SCRIPT_PATH" --doctor 2>&1 | fzf \
    "${FZF_THEME[@]}" \
    --no-sort \
    --no-multi \
    --prompt='health ❯ ' \
    ${HINT_FLAG[@]+"${HINT_FLAG[@]}"} \
    ${_dv_extra[@]+"${_dv_extra[@]}"} \
    --bind="ctrl-r:reload(bash '$SQ_SCRIPT' --doctor)" \
    >/dev/null 2>&1
  set -o pipefail
  exit 0
fi

if [ "${1:-}" = "--launch" ]; then
  set +e
  mode="${2:-switch}"

  # The navigator's title names the session you are in, so there is a "you are
  # here" anchor even once the current row has scrolled out of the list.  The
  # baked prefix+f binding gets this from a tmux format for free; this path is
  # already forking, so one more round-trip costs nothing that matters.
  _cur_sess=$(tmux display-message -p ${CUR_T[@]+"${CUR_T[@]}"} '#S' 2>/dev/null) || _cur_sess=""
  title=' interdimux '
  [ -n "$_cur_sess" ] && title=" interdimux · $_cur_sess "
  case "$mode" in
    kill)   title=' interdimux · kill ' ;;
    rename) title=' interdimux · rename ' ;;
    zoom)   title=' interdimux · zoom ' ;;
    swap)   title=' interdimux · swap ' ;;
    detach) title=' interdimux · detach ' ;;
    send)   title=' interdimux · send keys ' ;;
    dirs)   title=' interdimux · new session ' ;;
    schedule) title=' interdimux · schedule ' ;;
    jobs)     title=' interdimux · scheduled jobs ' ;;
    doctor)   title=' interdimux · health ' ;;
    agents)   title=' interdimux · agents ' ;;
  esac

  # `agents` is the navigator in the agents view (VIEW): the panes that need
  # you marked, and a QUERY typed for the user that matches exactly them,
  # rather than a filtered list: raw mode dims the other rows so the tree
  # keeps its shape, the cursor lands on the first match, and a keystroke
  # widens it.  `^` and `|` are as old as fzf itself: no version split.

  sp="$SQ_SCRIPT"
  chrome=()
  if tmux_ge 303; then
    # Border style/lines are left to the user's popup-border-* options;
    # only destructive modes recolour the frame
    #
    # The NAME is doubled, not the style: -T is a format, and a session named
    # after a directory 'x#(cmd)' would run cmd here (see _bk_title_fmt).
    # title itself stays raw for INTERDIMUX_TITLE, which popup_accent escapes.
    chrome=(-T "${POPUP_TITLE_STYLE}${title//'#'/##}")
    [ "$mode" = "kill" ] && { danger_style; chrome+=(-S "$REPLY"); }
    # A popup gets the server's global TMUX_PANE — forward ours so
    # current-target detection is exact.  It is the PRESSING pane only because
    # every route here passes it explicitly (the bindings' TMUX_PANE=#{pane_id},
    # the dashboard's baked items): run-shell itself hands over the server's
    # global TMUX_PANE, which can belong to another server entirely.  The
    # pressing client rides along for the same reason (see TMUX_C).
    [ -n "${TMUX_PANE:-}" ] && chrome+=(-e "TMUX_PANE=$TMUX_PANE")
    [ -n "$INTERDIMUX_CLIENT" ] && chrome+=(-e "INTERDIMUX_CLIENT=$INTERDIMUX_CLIENT")
    env_fwd_flags
    chrome+=("${ENV_FWD_FLAGS[@]}")
    # The title rides along so popup_accent can re-send it (a style-only
    # repaint on >= 3.6 would otherwise erase it)
    chrome+=(-e "INTERDIMUX_TITLE=$title")
    case "$mode" in
      # --dirs exits non-zero on cancel (the navigator's ctrl-o resume
      # contract); as a standalone popup that would bubble up through
      # display-popup to run-shell as a "returned 1" status message —
      # absorb it here
      # The rest are exec'd, as prefix+f's is (see --bind-keys).
      dirs)   chrome+=(-e "INTERDIMUX_MODE=dirs"); cmd="bash '$sp' --dirs || true" ;;
      # Not a picker over tmux targets — its own list, its own handler.
      jobs)   cmd="exec bash '$sp' --jobs" ;;
      doctor) cmd="exec bash '$sp' --doctor-view" ;;
      switch) cmd="exec bash '$sp'" ;;
      agents) chrome+=(-e "INTERDIMUX_VIEW=agents"); cmd="exec bash '$sp'" ;;
      *)      chrome+=(-e "INTERDIMUX_MODE=$mode"); cmd="exec bash '$sp'" ;;
    esac
  else
    env_fwd=$(build_env_fwd)
    case "$mode" in
      dirs)   cmd="$env_fwd bash '$sp' --dirs || true" ;;
      jobs)   cmd="$env_fwd bash '$sp' --jobs" ;;
      doctor) cmd="$env_fwd bash '$sp' --doctor-view" ;;
      switch) cmd="$env_fwd bash '$sp'" ;;
      agents) cmd="$env_fwd INTERDIMUX_VIEW=agents bash '$sp'" ;;
      *)      cmd="$env_fwd INTERDIMUX_MODE=$mode bash '$sp'" ;;
    esac
  fi

  # -c: open on the client that asked.  Left to tmux it lands on the most
  # recently active client, which from a menu or a popup is not reliably this
  # one (keys pressed in an overlay do not count as activity).
  # -EE -k: a picker that fails stays open with its error until a key, as
  # prefix+f's does (see --bind-keys).
  _close=(-E)
  tmux_ge 306 && _close=(-EE -k)
  exec tmux display-popup ${TMUX_C[@]+"${TMUX_C[@]}"} -w "$POPUP_WIDTH" -h "$POPUP_HEIGHT" \
    ${chrome[@]+"${chrome[@]}"} "${_close[@]}" "$cmd"
fi

# ---------------------------------------------------------------------------
# Scheduled jobs picker
# ---------------------------------------------------------------------------
#
# Scheduling without a way to see and undo what you scheduled is a trap: the
# only other exit is `atrm` on the command line, and by then you have to know
# the queue letter.  Deliberately placed AFTER the dialog helpers — these blocks
# execute during the top-to-bottom pass, so a handler above dlg_fit's definition
# would call a function that does not exist yet.

# Rows for the picker: "<display>\t<pane>\t<id>", the last field being what
# {-1} hands to the cancel binding.  A function, so that the picker opening
# lists them in its own process: `$(bash interdimux.sh --jobs-list)` started
# a second bash, which parsed most of this file again (~20 ms).  fzf's
# reloads still run --jobs-list.
jobs_list_rows() {
  local _id _when _tgt _pane _desc _c1 _c2 _p1 _p2
  command -v atq >/dev/null 2>&1 || return 0
  while IFS="$US" read -r _id _when _tgt _pane _desc; do
    [ -n "$_id" ] || continue
    # Pad the FITTED text, not the raw text: %-20s counts escape bytes as
    # columns, and a CJK session name draws at twice the width bash measures.
    dlg_fit "$_when" 18; _c1="$REPLY"; dlg_width "$_c1"
    printf -v _p1 '%*s' $(( 18 - REPLY )) ''
    dlg_fit "$_tgt" 20; _c2="$REPLY"; dlg_width "$_c2"
    printf -v _p2 '%*s' $(( 20 - REPLY )) ''
    printf '%s%s%s%s  %s%s%s%s  %s\t%s\t%s\n' \
      "$ACCENT_ESC" "$_c1" "$_p1" "$RST" \
      "$DIM" "$_c2" "$_p2" "$RST" \
      "$_desc" "$_pane" "$_id"
  done < <(sched_rows)
}
if [ "${1:-}" = "--jobs-list" ]; then
  set +e
  jobs_list_rows
  exit 0
fi

if [ "${1:-}" = "--job-cancel" ]; then
  set +e
  _jid="${2:-}"
  [ -n "$_jid" ] || exit 0
  tty_in="${INTERDIMUX_TTY_IN:-${INTERDIMUX_TTY:-/dev/tty}}"
  tty_out="${INTERDIMUX_TTY_OUT:-${INTERDIMUX_TTY:-/dev/tty}}"
  trap 'printf "\033[?25h" >>"$tty_out" 2>/dev/null' EXIT

  _when="" _tgt="" _desc=""
  while IFS="$US" read -r _i _w _t _p _d; do
    [ "$_i" = "$_jid" ] && { _when="$_w"; _tgt="$_t"; _desc="$_d"; break; }
  done < <(sched_rows)
  if [ -z "$_when" ]; then
    info_flash "$BOLD_AMBER" "Cancel" "Job $_jid is no longer queued."
    dialog_close
    exit 0
  fi

  if confirm_dialog "$BOLD_AMBER" "Cancel job ${_jid}?" \
       "${DIM}${_when} →${RST} ${_tgt}" "${DIM}\$${RST} ${_desc}"; then
    # Through --sched-cancel so the "never touch a job outside our own queue"
    # guard stays in one place.
    if bash "$SCRIPT_PATH" --sched-cancel "$_jid" >/dev/null 2>&1; then
      dialog_status "${GREEN}✓ cancelled${RST}"
    else
      dialog_status "${RED}✗ could not cancel job ${_jid}${RST}"
    fi
    sleep 0.35
  fi
  dialog_close
  exit 0
fi

if [ "${1:-}" = "--jobs" ]; then
  set +e
  tty_in="${INTERDIMUX_TTY_IN:-${INTERDIMUX_TTY:-/dev/tty}}"
  tty_out="${INTERDIMUX_TTY_OUT:-${INTERDIMUX_TTY:-/dev/tty}}"
  if ! command -v atq >/dev/null 2>&1; then
    info_flash "$BOLD_AMBER" "Scheduled jobs" "'at' is not installed." \
      "Scheduling beyond a minute needs it."
    dialog_close
    exit 0
  fi
  _jl="bash '$SQ_SCRIPT' --jobs-list"
  # Read once, not twice: --jobs-list costs an `at -c` per job, and the
  # emptiness check and the picker want the same rows.
  _jrows=$(jobs_list_rows)
  if [ -z "$_jrows" ]; then
    info_flash "$BOLD_AMBER" "Scheduled jobs" "Nothing is scheduled." \
      "Schedule one from the dashboard."
    dialog_close
    exit 0
  fi
  _jwait=""
  fzf_ge 74 && _jwait="wait+"
  HINT_PREVIEW_PCT=0   # no preview here, and an execute child inherits the navigator's
  hint_flag enter cancel 3 ^r reload 1 esc quit 2
  # Same guard as the other two pickers: under `set -o pipefail` an accept that
  # closes the pipe early makes the producer's SIGPIPE (141) mask fzf's status.
  # Nothing reads that status here, but the invariant is the point — the next
  # picker to be pasted from this one inherits the shape.
  set +o pipefail
  printf '%s\n' "$_jrows" | fzf \
    "${FZF_THEME[@]}" \
    --delimiter=$'\t' \
    --with-nth=1 \
    --no-sort \
    --prompt='jobs ❯ ' \
    ${HINT_FLAG[@]+"${HINT_FLAG[@]}"} \
    --bind="enter:${_jwait}execute(bash '$SQ_SCRIPT' --job-cancel {-1})+reload($_jl)" \
    --bind="ctrl-r:reload($_jl)" \
    >/dev/null 2>&1
  set -o pipefail
  exit 0
fi

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

# How many agents need you -- a pane whose state is `approve` or `input` -- in
# REPLY: the dashboard's Agents entry.  Counted per PANE, so an agent counts
# once however many rows show it: a window row repeats its active pane's, and
# `list-panes -a` prints a pane once for every session that holds its window
# -- a session group (`tmux new -t work`) or a linked window counted one agent
# two or three times (review R06).
#
# The state is agent_state_r's, the function the rows are drawn with, over the
# inputs the navigator's batched query gives them.  Only those, for prefix+g's
# sake: ONE tmux call (a list-panes of id, pid, current command, title and the
# published options), the registry read, and no rendering.  The command is
# resolved as the rows resolve it (resolve_command) only where the state can
# depend on it:
#   * an interpreter (node, nodejs, python*), because the agent is named by
#     the script it runs: `node .../bin/codex` is codex, and codex titles say
#     `approve`;
#   * a pane Claude's registry or a published option speaks for, because that
#     state shows only on a row that is not an idle shell -- and a wrapper
#     script (`sh ./my-agent`, see the README) is a shell to tmux's
#     #{pane_current_command}.
# Anywhere else #{pane_current_command} stands in, by its basename: argv0's
# basename is what names the row, and tmux strips the directory only from an
# argv0 that starts with `/` -- `./codex` and `target/release/codex` came
# through whole, found no rules, and a waiting agent went uncounted (review
# R12).  (The one difference left is a stopped agent in the background of a
# shell at its prompt, whose last title the row reads.)
#
# Most panes are decided before agent_state_r, the expensive part (review R08:
# prefix+g opened 30-47 ms later on a server of ssh panes):
#   * a registry record that applies and says anything but approve or input:
#     the registry is the first source that speaks, so nothing else can make
#     that pane wait;
#   * a pane with neither a record nor an option: only a title RULE can give
#     it a state, so only an app one of whose rules says approve or input is
#     looked at (AW_CAN).  ssh, docker, kubectl and the other remote shells
#     have title rules, none with a state, and Claude's say only `working`:
#     they used to cost a full title parse each, for a count they could never
#     reach.  AW_CAN needs no rule index (DEFAULT_AW_CAN, and the user's own
#     rules), so a list of shells and remote panes never loads the rules.
#
# Sessions @interdimux-hide keeps out of the navigator are left out here too,
# so the entry never promises an agent the navigator will not show.  The
# per-pane dedupe comes after that filter, so a pane linked into a hidden and
# a visible session still counts, from its visible line.
#
# The same call also answers, last, where the pressing client is: AW_CLIENT is
# "<height> <width> <session>" -- the session for the hide rule (the current
# one is never hidden), the size for the dashboard, which would otherwise have
# spent a round-trip of its own on it.  Empty when that lookup failed (a stale
# target: the one command here that can, hence last) or was never made.
#
# --agents and --agent-next walk the panes with this too, through two globals:
#   AW_WANT  the states that count, " approve input " for the dashboard; empty,
#            every agent pane (AS_AGENT).  The two shortcuts above hold only
#            while it names nothing but approve and input: past that, every
#            pane is resolved and asked, as its row is.
#   AW_LIST  set: each pane that counts is also handed to aw_row, which those
#            modes define below --list, so that a list never parses it.  The
#            RS line then also brings the host names (CUR_HOST, CUR_HOST_SHORT),
#            which the description of a row is checked against (row_desc_r).
#
# Here with the dashboard, not with the rest of the agent layer above --action,
# for the same reason: only the dashboard and the agents' modes count, and
# --action, the ctrl-o picker, --list and --jump parsed these ~8 KB on every
# run while they sat up there.
AW_CLIENT="" AW_WANT=' approve input ' AW_LIST=""
agents_waiting_r() {
  REPLY=0 AW_CLIENT=""
  [ "$AGENT_ON" = 1 ] && { [ "$AGENT_STATE" = on ] || [ -z "$AW_WANT" ]; } || return 0
  utf8_ctype_r   # the rows' character type (see gather_targets)
  [ -z "$REPLY" ] || local LC_CTYPE="$REPLY"
  REPLY=0
  local fmt all rest cur="" line pane pid pcc raw res hp n=0 pt=0 rs=$'\x1e' mark=$'\x1e' a0 b v fast=1 wi="" pi=""
  local -a f=() lines=()
  local -A CLAUDE_BY_PANE=() aw_seen=()
  local AS_STATE_ONLY=1   # see agent_state_r: the count wants the state alone
  v="${AW_WANT// approve / }"; v="${v// input / }"
  [ -n "$AW_WANT" ] && [[ "$v" != *[!\ ]* ]] || fast=0
  # shellcheck disable=SC2034  # agent_state_r reads it, in interdimux.sh
  [ "$fast" = 1 ] && [ -z "$AW_LIST" ] || AS_STATE_ONLY=""
  title_ruleset
  state_optfmt_r
  fmt="#{session_name}${US}#{pane_id}${US}#{pane_pid}${US}#{pane_current_command}${US}#{pane_title}${US}$REPLY"
  [ -z "$AW_LIST" ] || { fmt="#{window_index}${US}#{pane_index}${US}$fmt"; mark+="#{host}${US}#{host_short}"; }
  all=$(tmux list-panes -a -F "$fmt" \; display-message -p "$mark" \; \
          display-message -p ${TMUX_C[@]+"${TMUX_C[@]}"} ${CUR_T[@]+"${CUR_T[@]}"} \
          '#{client_height} #{client_width} #S' 2>/dev/null)
  # Cut at the LAST RS (a command name may hold one), from the end: a
  # ${x#*pat} would be quadratic in its offset.
  rest="${all%"$rs"*}"
  if [ "$rest" != "$all" ]; then
    AW_CLIENT="${all:${#rest}+1}"
    if [ -n "$AW_LIST" ]; then
      v="${AW_CLIENT%%$'\n'*}"; AW_CLIENT="${AW_CLIENT:${#v}}"
      # shellcheck disable=SC2034  # the title rules read them, in interdimux.sh
      CUR_HOST="${v%%"$US"*}" CUR_HOST_SHORT="${v#*"$US"}"
    fi
    AW_CLIENT="${AW_CLIENT#$'\n'}"; all="$rest"
    if [[ "$AW_CLIENT" =~ ^([0-9]*)\ ([0-9]*)\ (.*)$ ]]; then
      cur="${BASH_REMATCH[3]}"   # a session with no client has no size, but has a name
      [ -n "${BASH_REMATCH[1]}" ] && [ -n "${BASH_REMATCH[2]}" ] || AW_CLIENT=""
    else
      AW_CLIENT=""
    fi
  fi
  [ -n "$all" ] || return 0
  claude_registry_r
  if [ -n "$CLAUDE_REG" ]; then
    while IFS= read -r line; do
      [[ "$line" == %*"$US"* ]] && CLAUDE_BY_PANE["${line%%"$US"*}"]="${line#*"$US"}"
    done <<< "$CLAUDE_REG"
  fi
  set -f; IFS=$'\n'; lines=($all); unset IFS; set +f
  for line in ${lines[@]+"${lines[@]}"}; do
    # set -f per line: agent_state_r's option rules turn it back off.
    set -f; IFS="$US"; f=($line$US); unset IFS; set +f   # the appended US: see gather_targets
    [ -z "$AW_LIST" ] || { wi="${f[0]-}" pi="${f[1]-}"; f=("${f[@]:2}"); }
    pane="${f[1]-}"
    case "$pane" in %[0-9]*) ;; *) continue ;; esac
    case "$pane" in %*[!0-9]*) continue ;; esac
    if [ -n "${HIDE_PATTERNS:-}" ] && [ "${f[0]}" != "$cur" ]; then
      set -f
      for hp in $HIDE_PATTERNS; do
        # shellcheck disable=SC2254  # the pattern is a glob by design
        case "${f[0]}" in $hp) set +f; continue 2 ;; esac
      done
      set +f
    fi
    # One pane, one count, however many sessions show it.
    [[ ${aw_seen[$pane]+x} ]] && continue
    aw_seen[$pane]=1
    # A line tmux cut short (see gather_targets) keeps its row, but its pid is
    # never read.
    pid="${f[2]-}"; [ "${#f[@]}" -eq 6 ] || pid=""
    pcc="${f[3]-}" raw="${f[3]-}" res=0
    a0="${pcc%% *}"; b="${a0##*/}"
    # A record that applies (agent_state_r's test) and says anything but
    # approve or input (AW_WANT) decides it: the registry speaks first.
    v="${CLAUDE_BY_PANE[$pane]-}"
    if [ -n "$v" ] && [ -n "$AW_WANT" ] && { [ -z "${v%%"$US"*}" ] || [ "${v%%"$US"*}" = "$pid" ]; }; then
      v="${v#*"$US"}"
      [[ "$AW_WANT" == *" ${v%%"$US"*} "* ]] || continue
    fi
    case "$b" in
      ''|node|nodejs|python*) res=1 ;;
      *) if [ "$fast" = 0 ] || [ -n "${CLAUDE_BY_PANE[$pane]-}" ] || [[ "${f[5]-}" == *[!$GS]* ]]; then res=1; fi ;;
    esac
    if [ "$res" = 1 ]; then
      [ "$pt" = 1 ] || { [ "$SHOW_FULL_COMMAND" = on ] && build_process_table; pt=1; }
      resolve_command "$pcc" "$pid"; raw="$REPLY"
    else
      # Neither a record nor an option: only the title can give it a state, and
      # only through a title rule for its app that says approve or input.  Most
      # panes (shells, editors, remote shells) have none, and are passed over
      # here, before the call -- a bash function call is most of what a pane
      # costs.  The app is named as agent_state_r names it: argv0's basename.
      [ -n "${f[4]-}" ] || continue
      [ -n "$AW_CAN" ] || aw_can_r
      [[ "$AW_CAN" == *" ${b#-} "* || "$AW_CAN" == *" * "* ]] || continue
    fi
    agent_state_r "$raw" "$pid" "$pane" "${f[4]-}" "${f[5]-}" || continue
    if [ -n "$AW_WANT" ]; then
      [[ -n "$AS_STATE" && "$AW_WANT" == *" $AS_STATE "* ]] || continue
    else
      [ "$AS_AGENT" = 1 ] || continue
    fi
    n=$(( n + 1 ))
    [ -z "$AW_LIST" ] || aw_row "$n" "$pane" "${f[0]}" "$wi" "$pi" "$raw"
  done
  REPLY="$n"
}

# The "who pressed the key" prefix for a `run-shell … --launch X` the dashboard
# builds, in REPLY: "TMUX_PANE=%N INTERDIMUX_CLIENT=<client> ", either part
# omitted when unknown, and the versions this process resolved.
#
# run-shell does NOT pass the pressing pane: its job gets the tmux SERVER's
# global environment, whose TMUX_PANE is whatever the process that started the
# server exported -- a pane of another server when it was started from inside
# tmux.  The dashboard's own binding carries the right values, but every item
# it launched dropped them, so a picker opened from prefix+g marked the wrong
# session current (or none), ordered MRU against it, and could open on another
# client.  Menu item commands are not expanded in the pressing client's
# context, so the values are baked in as literals; both are checked against a
# charset that needs no quoting in /bin/sh or tmux's parser.
#
# The versions go along so that --launch does not ask `fzf --version` and
# `tmux -V` again, seconds later, for the same two numbers -- which are what
# it hands its popup (env_fwd) either way.  ~10 ms of every dashboard item
# (fzf is a Go binary).  Integers, so they need no quoting either.
launch_env_prefix() {
  REPLY=""
  [[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]] && REPLY+="TMUX_PANE=$TMUX_PANE "
  [ -n "$INTERDIMUX_CLIENT" ] && REPLY+="INTERDIMUX_CLIENT=$INTERDIMUX_CLIENT "
  REPLY+="INTERDIMUX_TMUX_VNUM=$TMUX_VNUM INTERDIMUX_FZF_MINOR=$FZF_MINOR "
  return 0
}

# Entry point for the prefix+g binding: a native styled menu on a client tall
# enough for it, otherwise (short, or of unknown height) a compact fzf menu.
if [ "${1:-}" = "--dashboard-launch" ]; then
  set +e
  sp="$SQ_SCRIPT"

  # display-menu SILENTLY draws nothing and exits 0 when the menu is taller than
  # the client.  Verified on 3.7b — no message, no error, prefix+g simply becomes
  # a dead key.  MENU_ROWS (defined next to the other geometry helpers, because
  # --doctor reports against it too) is items + 2 for the borders.
  #
  # The fzf fallback below has no such ceiling: its list scrolls.  So the tmux
  # version is not the only thing that decides which one to draw.
  #
  # The Agents entry's count asks tmux for the panes and, in the same
  # round-trip, for the client's size (AW_CLIENT); only without it is the size
  # a round-trip of its own.  No native menu below 3.4, so no count there: the
  # fzf fallback counts for itself.
  _n_agents=0 AW_CLIENT=""
  if tmux_ge 304 && [ "$AGENT_STATE" = on ]; then agents_waiting_r; _n_agents="$REPLY"; fi
  if [ -n "$AW_CLIENT" ]; then
    _cli_h="${AW_CLIENT%% *}" _cli_w="${AW_CLIENT#* }"; _cli_w="${_cli_w%% *}"
  else
    client_dims; _cli_h="${REPLY% *}" _cli_w="${REPLY#* }"
  fi
  # Unknown height takes the fallback, not the menu: a popup where a menu would
  # have done is cosmetic, and a dead prefix+g is not.
  if tmux_ge 304 && [ "$_cli_h" -ge "$MENU_ROWS" ]; then
    # Menu item commands are re-parsed by tmux's command parser when
    # selected: inside its double-quoted token, \ " $ are escapes and
    # run-shell format-expands #{...} — escape those layers on top of
    # the shell quoting so exotic install paths survive.
    menu_sp="$SQ_SCRIPT_FMT"
    menu_sp="${menu_sp//\\/\\\\}"
    menu_sp="${menu_sp//\"/\\\"}"
    menu_sp="${menu_sp//\$/\\\$}"
    launch_env_prefix
    _mp="${REPLY}bash '$menu_sp' --launch"

    # A menu item whose name begins with '-' is DISABLED: tmux dims it and drops
    # its key column (verified against 3.7b).  Offering Schedule on a box with no
    # `at`, and answering the click with an error dialog, is worse than saying up
    # front that it is unavailable.  The count rides in the Jobs label for the
    # same reason — an empty picker is a wasted keypress.
    #
    # One fork on the prefix+g path, which is not the hot path (prefix+f is) and
    # already forks bash to get here.  The lines are counted here, the
    # non-empty ones, as `| grep -c .` counted them: a pipe and an exec fewer.
    _m_sched='Schedule' _m_jobs='-Jobs'
    if command -v at >/dev/null 2>&1; then
      _njobs=0
      while IFS= read -r _jline; do
        [ -z "$_jline" ] || _njobs=$((_njobs + 1))
      done <<< "$(atq -q "$SCHED_QUEUE" 2>/dev/null)"
      case "$_njobs" in
        ''|0) _m_jobs='-Jobs' ;;
        *)    _m_jobs="Jobs ($_njobs)" ;;
      esac
    else
      _m_sched='-Schedule (needs at)'
      _m_jobs='-Jobs (needs at)'
    fi
    # Agents that wait on you (approve / input), counted above by the rows' own
    # state logic (agents_waiting_r).  Greyed out when there are none, like
    # Jobs -- a filter that finds nothing is a wasted keypress.  The key is `e`:
    # display-menu spends g/G (and j/k, q) on moving about.
    if [ "$AGENT_STATE" != on ]; then
      _m_agents='-Agents (agent-state off)'
    elif [ "$_n_agents" = 0 ]; then
      _m_agents='-Agents'
    elif [ "$_n_agents" = 1 ]; then
      _m_agents='Agents (1 needs you)'
    else
      _m_agents="Agents ($_n_agents need you)"
    fi
    # Item names are FORMATS, so #[...] styles them.  Kill is the only entry here
    # that destroys something; give it the same danger colour as the frame it
    # turns red.
    tmux display-menu -x C -y C ${TMUX_C[@]+"${TMUX_C[@]}"} \
      -T '#[align=centre,bold] interdimux ' \
      -H "bg=${MENU_SEL_BG},fg=${MENU_SEL_FG},bold" \
      'Switch'      s "run-shell -b \"$_mp switch\"" \
      "$_m_agents"  e "run-shell -b \"$_mp agents\"" \
      'New session' n "run-shell -b \"$_mp dirs\"" \
      '' \
      'Rename'      r "run-shell -b \"$_mp rename\"" \
      "#[fg=${POPUP_BORDER_DANGER}]Kill" i "run-shell -b \"$_mp kill\"" \
      'Swap'        w "run-shell -b \"$_mp swap\"" \
      'Zoom'        z "run-shell -b \"$_mp zoom\"" \
      '' \
      'Detach'      d "run-shell -b \"$_mp detach\"" \
      'Send keys'   t "run-shell -b \"$_mp send\"" \
      '' \
      "$_m_sched"   a "run-shell -b \"$_mp schedule\"" \
      "$_m_jobs"    o "run-shell -b \"$_mp jobs\"" \
      '' \
      'Health'      h "run-shell -b \"$_mp doctor\""
  else
    chrome=()
    cmd="$(build_env_fwd) bash '$sp' --dashboard"
    if tmux_ge 303; then
      chrome=(-T "${POPUP_TITLE_STYLE} interdimux ")
      [ -n "${TMUX_PANE:-}" ] && chrome+=(-e "TMUX_PANE=$TMUX_PANE")
      [ -n "$INTERDIMUX_CLIENT" ] && chrome+=(-e "INTERDIMUX_CLIENT=$INTERDIMUX_CLIENT")
      env_fwd_flags
      chrome+=("${ENV_FWD_FLAGS[@]}")
      cmd="exec bash '$sp' --dashboard"   # exec: see --bind-keys
    fi
    # Entries + 5: two border rows, the prompt, the rule under it, and the hint
    # bar.  MEASURED rather than guessed — the 12 entries show fully at -h 17,
    # and at 16 the last one scrolls away (as 11 did at 15, before Agents) —
    # because the number that was here before was slack nothing could
    # distinguish from any other slack, and the entry added last is the one a
    # too-short popup scrolls away.  tests/test_dashboard.sh derives it
    # from the item list and fails if the two drift, exactly as it does for
    # MENU_ROWS.
    #
    # Clamped to the client, because display-popup does NOT clamp: it fails with
    # "height too large" and draws nothing.  Verified — on a 14-row client `-h 14`
    # succeeds and `-h 15` errors, so the limit is exactly the client's size.  A
    # fixed 64x19 made this the same dead key as an oversized menu, reached by the
    # other path.  fzf's list scrolls, so a short popup is merely cramped.
    _pop_w=64 _pop_h=17
    [ "$_cli_w" -gt 0 ] && [ "$_cli_w" -lt "$_pop_w" ] && _pop_w="$_cli_w"
    [ "$_cli_h" -gt 0 ] && [ "$_cli_h" -lt "$_pop_h" ] && _pop_h="$_cli_h"
    # Held open on a failure, as every other popup is (see --bind-keys).
    _close=(-E)
    tmux_ge 306 && _close=(-EE -k)
    tmux display-popup ${TMUX_C[@]+"${TMUX_C[@]}"} -w "$_pop_w" -h "$_pop_h" ${chrome[@]+"${chrome[@]}"} \
      "${_close[@]}" "$cmd"
  fi
  exit 0
fi

# fzf fallback menu (a client shorter than MENU_ROWS, or of unknown height)
if [ "${1:-}" = "--dashboard" ]; then
  set +e

  # Agents: no disabled state in an fzf list, so the count goes in the
  # description (the native menu greys the entry out instead).
  if [ "$AGENT_STATE" != on ]; then
    _fb_agents="Agents waiting on you (@interdimux-agent-state is off)"
  else
    agents_waiting_r
    case "$REPLY" in
      0) _fb_agents="No agent needs you now" ;;
      1) _fb_agents="1 agent needs you (approve or input)" ;;
      *) _fb_agents="$REPLY agents need you (approve or input)" ;;
    esac
  fi
  items=$(printf "%s\t  ${BOLD_AMBER}%-14s${RST} ${DIM}%s${RST}\n" \
    "switch" "Switch"       "Navigate & jump to target" \
    "agents" "Agents"       "$_fb_agents" \
    "dirs"   "New session"  "Create session from directory" \
    "rename" "Rename"       "Rename a session or window" \
    "kill"   "Kill"         "Remove sessions, windows, or panes" \
    "zoom"   "Zoom"         "Toggle pane zoom" \
    "swap"   "Swap"         "Swap windows or panes" \
    "detach" "Detach"       "Detach clients from session" \
    "send"   "Send keys"    "Send a command to a pane" \
    "schedule" "Schedule"   "Run a command later, via at" \
    "jobs"   "Jobs"         "See and cancel scheduled commands" \
    "doctor" "Health"       "Check the setup, like :checkhealth")

  # shellcheck disable=SC2034  # hint_cols reads it, in interdimux.sh
  HINT_PREVIEW_PCT=0   # no preview here, and an execute child inherits the navigator's
  hint_flag enter select 2 esc quit 1
  choice=$(printf '%s\n' "$items" | fzf \
    "${FZF_THEME[@]}" \
    --no-sort \
    --no-info \
    --delimiter=$'\t' \
    --with-nth=2 \
    --prompt='interdimux ❯ ' \
    ${HINT_FLAG[@]+"${HINT_FLAG[@]}"} \
  ) || exit 0

  action="${choice%%	*}"

  # Launch the selected tool in a new popup via run-shell -b (popups
  # can't nest, so this runs after the dashboard popup closes).  The pane and
  # client this popup was opened for go along: run-shell would hand --launch
  # the server's global TMUX_PANE instead (see launch_env_prefix).
  launch_env_prefix
  tmux run-shell -b "${REPLY}bash '$SQ_SCRIPT_FMT' --launch $action"
  exit 0
fi

# ---------------------------------------------------------------------------
# Agents from the command line: --agents, --agent-next
# ---------------------------------------------------------------------------
#
# The panes the dashboard counts, for a status line, a script or a key, with
# Claude's registry state, which no tmux format can see.  Both modes walk the
# panes with agents_waiting_r (one tmux call, the registry read, agent_state_r
# per pane), so what they say is what the rows and the count say.  Down here,
# below --list and --jump and the dashboard's modes, so that no list, and
# nothing the dashboard opens, parses them.
#
#   --agents [--count] [STATES]   one line per agent pane, tab-separated:
#                                 pane id, target, agent, state, since (epoch
#                                 seconds), description -- or, with --count,
#                                 how many.  STATES (approve,input,...) keeps
#                                 only the panes in one of them.
#   --agent-next [STATES]         switch to the next of them (approve,input by
#                                 default), wrapping.
#
# The columns are fixed: a new one only ever goes at the end.  `-` is a state
# or a since that is not known (only Claude's registry says since when).  The
# target is spec_target's for the pane's row, `=session:=window.pane`, in the
# first session that shows it, as the count takes it.  The description is the
# row's (row_desc_r: none when it only repeats the name, the host or the
# command), before @interdimux-title-max cuts it, and cleaned as a title is
# (title_text_r): no tab or newline can reach a line.
#
# Most urgent first -- approve, input, error, done, working, idle, then a pane
# with no state -- and within a state, the one in it longest first.  That
# order is the KEY of AW_ROWS, which bash walks in index order: urgency, since
# (an unknown one after every known one) and the pane's place in the list, so
# nothing is sorted and nothing forks.
AW_ROWS=()
aw_row() { # $1 the pane's place, $2 its id, $3 session, $4 window, $5 pane index, $6 command
  local r s d="$AS_DESC"
  case "$AS_STATE" in
    approve) r=0 ;; input) r=1 ;; error) r=2 ;; done) r=3 ;; working) r=4 ;; idle) r=5 ;; *) r=6 ;;
  esac
  # A record with no statusUpdatedAt says 0 (claude_registry_r), which the row
  # shows no age for (age_of): unknown, not the oldest of all.
  s="$AS_SINCE"
  case "$s" in ''|0|*[!0-9]*|???????????*) s="" ;; esac
  case "$SHOW_TITLE" in off) d="" ;; known) [ "$AS_KNOWN" = 1 ] || d="" ;; esac
  [ -z "$d" ] || { row_desc_r "$d" "$6"; d="$REPLY"; }
  r=$(( r * 10**15 + 10#${s:-9999999999} * 10**5 + $1 ))
  AW_ROWS[r]="$2$US$3$US$4$US$5$US${AS_NAME//[[:cntrl:]]/?}	${AS_STATE:--}	${s:--}	$d"
}

# STATE,STATE,... ($1) as AW_WANT; status 1 for a word that is no state.
aw_want() {
  local w
  AW_WANT=""
  set -f; IFS=,
  for w in $1; do
    case "$w" in
      approve|input|error|done|working|idle) AW_WANT+=" $w" ;;
      *) unset IFS; set +f; return 1 ;;
    esac
  done
  unset IFS; set +f
  [ -z "$AW_WANT" ] || AW_WANT+=" "
}

if [ "${1:-}" = "--agents" ]; then
  set +e
  _ac=""
  [ "${2:-}" = --count ] && { _ac=1; shift; }
  if [ $# -gt 2 ] || ! aw_want "${2:-}"; then
    echo "interdimux: usage: --agents [--count] [STATE,...]  (approve input error done working idle)" >&2
    exit 2
  fi
  [ -n "$_ac" ] || AW_LIST=1
  agents_waiting_r
  if [ -n "$_ac" ]; then
    printf '%s\n' "$REPLY"
    exit 0
  fi
  for _k in ${AW_ROWS[@]+"${!AW_ROWS[@]}"}; do
    set -f; IFS="$US"; _f=(${AW_ROWS[_k]}); unset IFS; set +f
    parse_spec "P:${_f[1]}:${_f[2]}:${_f[3]}"
    printf '%s\t' "${_f[0]}"; spec_target; printf '\t%s\n' "${_f[4]-}"
  done
  exit 0
fi

# The next agent that needs you, for a key (@interdimux-agent-next-key) or a
# script: the first pane in --agents order AFTER the one you are in, wrapping,
# so that pressing it again visits the next one -- A, B, C, A -- rather than
# going back and forth between the two at the top: you have not answered A
# yet, so A is still first.  From a pane not in the list, the first one.
if [ "${1:-}" = "--agent-next" ]; then
  set +e
  if [ $# -gt 2 ] || ! aw_want "${2:-approve,input}"; then
    echo "interdimux: usage: --agent-next [STATE,...]  (approve input error done working idle)" >&2
    exit 2
  fi
  AW_LIST=1
  agents_waiting_r
  _first="" _next="" _here=""
  for _k in ${AW_ROWS[@]+"${!AW_ROWS[@]}"}; do
    [ -n "$_first" ] || _first="$_k"
    if [ -n "$_here" ]; then _next="$_k"; break; fi
    [ "${AW_ROWS[_k]%%"$US"*}" = "${TMUX_PANE:-}" ] && _here=1
  done
  _next="${_next:-$_first}"
  if [ -z "$_next" ]; then
    imux_msg "no agent needs you"
    exit 0
  fi
  # The client that pressed the key (TMUX_C), as for --jump.  By the pane's
  # id, which moves it to that session, window and pane at once, and leaves
  # the choice of session to tmux when a session group or a linked window
  # shows the pane more than once: the one you are in if it is one of them,
  # else the one used last (tmux 3.7b, measured).
  tmux switch-client ${TMUX_C[@]+"${TMUX_C[@]}"} -t "${AW_ROWS[_next]%%"$US"*}" 2>/dev/null || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# --doctor — tell the user what is wrong instead of failing quietly
# ---------------------------------------------------------------------------
#
# Everything here used to be a silent no-op or a mangled popup:
#
#   * a mistyped option name.  `@interdimux-fzf-opt` (no 's') is not an error
#     to tmux -- user options are free-form -- so the setting simply never
#     applied and the user had no way to tell.
#   * an out-of-domain value.  `@interdimux-order 'recent'` fell through to mru,
#     `@interdimux-show-preview 'true'` read as off.
#   * a '#' anywhere in the install path.  The prefix+f binding is built with
#     `run-shell -bC`, which FORMAT-EXPANDS its argument, so a '#' in the path
#     is eaten at keypress and the binding silently opens nothing.
#   * an unwritable state dir, which turns every recent-dir write into stderr
#     noise painted over the popup.
#
# Deliberately NOT part of the startup path: the hot path already validates the
# three numeric options it would otherwise crash on, and nothing else here is
# worth a millisecond on every open.
#
# And the last mode before the navigator: this is ~77 KB, and bash parses a
# script as it runs it, so every mode dispatched below it parsed all of it on
# each run -- ~2.8 ms that the dashboard, its menu's --launch, Health and Jobs
# paid for nothing.  tests/test_render_cost.sh checks the order.
if [ "${1:-}" = "--doctor" ]; then
  set +e
  _doc_fail=0

  # `--doctor --ack`: the errors logged so far have been seen, so the check
  # below stops failing on them (UX-17).  The log itself is kept; the marker
  # is its newest entry's header.
  #
  # Text above the first header (a log cut by hand, or written by something
  # else) counts as an entry of its own, under this stand-in header: counted
  # as nothing, it was a red check that no --ack could clear.
  _estart='== (before the first entry)'
  if [ "${2:-}" = --ack ]; then
    _ein=$(awk -v start="$_estart" '
      !n && !/^== / { n = 1; h = start }
      /^== / { n++; h = $0 }
      END { if (n) { print n; print h } }' "$SCHED_LOGDIR/errors.log" 2>/dev/null)
    if [ -z "$_ein" ]; then
      echo "interdimux: no errors are logged"
    elif printf '%s\n' "${_ein#*$'\n'}" > "$SCHED_LOGDIR/errors.seen" 2>/dev/null; then
      echo "interdimux: ${_ein%%$'\n'*} logged error(s) acknowledged; --doctor fails again only on a new one"
    else
      echo "interdimux: cannot write $SCHED_LOGDIR/errors.seen" >&2
      exit 1
    fi
    exit 0
  fi

  # Buffered rather than streamed, so the SUMMARY can come first.  In a popup the
  # first line is the one you actually read, and "3 problems" up top is the whole
  # point of running this; a count at the bottom of a scrolling report is a count
  # you have to go looking for.  The checks take well under 100 ms, so there is
  # nothing to stream.
  # Appended, not printf'd: a command substitution per check is ~30 forks for a
  # report, and this file does not spend forks it does not have to.
  # Buffering stdout is not enough: a check that writes to STDERR streams
  # straight past the buffer and lands ABOVE the title, so the first line of the
  # Health popup becomes a bash error.  Divert it for the duration of the checks
  # and fold whatever arrives into the report, where it belongs — a check that
  # errors is itself a finding.
  #
  # Never a predictable name in a shared /tmp: one planted there as a symlink
  # would have `: >` truncate whatever it points at.  The same choice as
  # RESUME_FILE (see there): in-process in the private $XDG_RUNTIME_DIR, else
  # mktemp.  The trap is for a run cut short, which left the file behind.
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
    _derr="$XDG_RUNTIME_DIR/interdimux-doctor-err.$$"
  else
    _derr=$(mktemp "${TMPDIR:-/tmp}/interdimux-doctor-err.XXXXXX" 2>/dev/null) || _derr=""
  fi
  if [ -n "$_derr" ] && : > "$_derr" 2>/dev/null; then
    trap 'rm -f "$_derr"' EXIT
    exec 3>&2 2>"$_derr"
  else
    _derr=""
  fi

  _doc="" _n_ok=0 _n_warn=0 _n_bad=0
  _ok()   { _doc+=$'  \033[32m✓\033[0m '"$1"$'\n'; _n_ok=$((_n_ok + 1)); }
  _warn() { _doc+=$'  \033[33m⚠\033[0m '"$1"$'\n'; _n_warn=$((_n_warn + 1)); }
  _bad()  { _doc+=$'  \033[31m✗\033[0m '"$1"$'\n'; _n_bad=$((_n_bad + 1)); _doc_fail=1; }
  _note() { _doc+=$'      \033[2m'"$1"$'\033[0m\n'; }
  # A run of '─', fork-free.  Sets REPLY.
  _rule() { local n="$1"; [ "$n" -lt 0 ] && n=0; printf -v REPLY '%*s' "$n" ''; REPLY="${REPLY// /─}"; }
  # A section heading, with a rule out to the report width.
  _sec()  {
    _rule $(( _doc_w - ${#1} - 1 ))
    _doc+=$'\n\033[1m'"$1"$'\033[0m \033[2m'"$REPLY"$'\033[0m\n'
  }

  # Width to lay the report out in.  In a popup this is the popup; fzf keeps a
  # couple of columns for its gutter and scrollbar, hence the margin.  Capped
  # because a rule 150 cells wide is not structure, it is noise.
  # -6, not -4: in the Health popup this is drawn INSIDE fzf, which takes two
  # cells of gutter and keeps the last column for its scrollbar.  At -4 the title
  # row was one cell over on a 44-column popup and fzf ellipsized the summary the
  # whole rewrite exists to put first.
  term_cols_r; _doc_w=$(( REPLY - 6 ))
  [ "$_doc_w" -gt 96 ] && _doc_w=96
  # No floor beyond 1.  A floor is the wrong shape for this: any floor WIDER than
  # the display puts the ellipsis back, which is the one thing the layout has to
  # avoid, and it does so on exactly the narrow popup a floor was meant to help.
  [ "$_doc_w" -lt 1 ] && _doc_w=1

  _sec environment

  # The environment the popups actually run in.  prefix+f's display-popup and
  # every run-shell binding start their command from the tmux SERVER's
  # environment — the global one, overlaid by the session's — not from the shell
  # this was typed into, and the two differ in exactly the cases worth
  # diagnosing: fzf on PATH only through a shell rc, a locale only a login
  # profile exports, an $FZF_DEFAULT_OPTS set after the server started.  Every
  # check of that kind below reads it from here.  Run from the Health popup the
  # two are the same, so either way the answer is the popup's.
  #
  # One dump per scope, not a query per name: each is a tmux round-trip.  Both
  # are parsed once into a map, session scope over global, the way tmux merges
  # them; `-NAME` is tmux's "removed".  (Matching each lookup against the raw
  # dumps instead cost more than every other check here together: a glob over a
  # few KB of environment, per name, per scope.)
  declare -A _senv_v=() _senv_sc=()
  _senv_load() { # $1 = a show-environment dump, $2 = its scope: g or s
    local line name IFS=$'\n'
    local -a lines=()
    set -f; lines=($1); set +f
    for line in ${lines[@]+"${lines[@]}"}; do
      case "$line" in
        -*) name="${line#-}" ;;
        *=*) name="${line%%=*}" ;;
        *) continue ;;
      esac
      # A line of a value that spans lines is not a variable; this skips most.
      [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      if [ "$line" = "-$name" ]; then unset "_senv_v[$name]"
      else _senv_v["$name"]="${line#*=}"
      fi
      _senv_sc["$name"]="$2"
    done
  }
  _senv_ok=0
  if _senv_dump=$(tmux show-environment -g 2>/dev/null); then
    _senv_ok=1
    _senv_load "$_senv_dump" g
    _senv_dump=$(tmux show-environment ${TMUX_PANE:+-t "$TMUX_PANE"} 2>/dev/null) \
      && _senv_load "$_senv_dump" s
  fi
  # $1 = a variable name.  Sets REPLY to the value a popup would get and returns
  # 0, or returns 1 when a popup would not have it at all.  $2 = exact re-reads
  # the value on its own, because a dump line holds only the first line of a
  # value that spans several — and $FZF_DEFAULT_OPTS often does.  When tmux could
  # not be asked at all, this process's own value stands in.
  _srv_env() {
    local line
    if [ "$_senv_ok" = 0 ]; then
      [ -n "${!1+set}" ] || return 1
      REPLY="${!1}"
      return 0
    fi
    [ -n "${_senv_v[$1]+set}" ] || return 1
    REPLY="${_senv_v[$1]}"
    if [ "${2:-}" = exact ]; then
      if [ "${_senv_sc[$1]}" = s ]; then
        line=$(tmux show-environment ${TMUX_PANE:+-t "$TMUX_PANE"} "$1" 2>/dev/null) && REPLY="${line#*=}"
      else
        line=$(tmux show-environment -g "$1" 2>/dev/null) && REPLY="${line#*=}"
      fi
    fi
    return 0
  }

  # The version every check branches on is TMUX_VNUM (forwarded by the binding,
  # or parsed from `tmux -V` at startup), so that is the one named — spelled the
  # way tmux spells it (3.7b) when the two agree.  Printing a fresh `tmux -V`
  # while branching on something else let this line name one version and judge
  # another.
  _tvs=$(tmux -V 2>/dev/null); _tvs="${_tvs#tmux }"
  _tv_same=0
  [[ "$_tvs" =~ ([0-9]+)\.([0-9]+) ]] \
    && [ $(( 10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]} )) = "$TMUX_VNUM" ] \
    && _tv_same=1
  if [ "$_tv_same" = 0 ]; then
    if [ "$TMUX_VNUM" = 999 ]; then _tvs="${_tvs:-of unknown version}"   # unparseable: assumed modern
    else _tvs="$(( TMUX_VNUM / 100 )).$(( TMUX_VNUM % 100 ))"
    fi
  fi
  # 3.6 is a floor, not a preference.  Every row is delimited with a raw US byte
  # inside a `-F` format, and tmux 3.5a and older rewrite that byte as the four
  # characters `\037`: each row then parses as ONE field, and the picker is simply
  # blank — measured 3.4 -> 0 rows, 3.5a -> 0, 3.6 -> all of them (README,
  # docs/CI.md).  Those are the versions stock Ubuntu 24.04 and Debian 13 ship,
  # which makes this the likeliest real failure there is — and it used to get a
  # green tick here.
  if [ "$TMUX_VNUM" -lt 306 ]; then
    _bad "tmux $_tvs is older than 3.6 — it rewrites the row delimiter as \\037, so the picker lists nothing"
    _note "Ubuntu 24.04 ships 3.4 and Debian 13 ships 3.5a: build tmux from source, or use a backport"
  else
    _ok "tmux $_tvs (fast prefix-key binding available)"
  fi

  # fzf and bash as the popups will find them.  Only the tmux server's PATH
  # counts, and nothing on the way sources a shell rc: run-shell runs /bin/sh on
  # it, display-popup a non-interactive default-shell.  So "fzf is on my PATH"
  # in a terminal proves nothing about either — this used to say ✓ from a shell
  # that had fzf while every popup closed the moment it opened, and never looked
  # at bash, whose version is a hard floor too.
  #
  # `command -v` against a PATH that is not ours, without a fork, searched the
  # way a POSIX shell searches it: each element as written.  That is how the
  # popups' `bash` is found (by /bin/sh, or the default-shell).  fzf is found by
  # bash, which searches differently; see the probe below.  Sets REPLY.
  _which_in() {
    local d
    local -a dirs=()
    IFS=: read -r -a dirs <<< "$1"
    for d in ${dirs[@]+"${dirs[@]}"}; do
      [ -n "$d" ] || d=.
      if [ -f "$d/$2" ] && [ -x "$d/$2" ]; then REPLY="$d/$2"; return 0; fi
    done
    return 1
  }
  # _spath_ok, not a test on _spath: an EMPTY PATH is still the one the popups get.
  _spath="" _spath_ok=0 _sfzf="" _sbash=""
  if _srv_env PATH; then
    _spath="$REPLY" _spath_ok=1
    _which_in "$_spath" bash && _sbash="$REPLY"
  fi

  # The locale the popups get, gathered here because the same probe measures it
  # (the check itself is further down, with the others about text).
  _lc_env=(env -u LC_ALL -u LC_CTYPE -u LANG) _lc_name="" _lc_var=""
  for _lv in LANG LC_CTYPE LC_ALL; do     # rising precedence: the last one set wins
    _srv_env "$_lv" || continue
    _lc_env+=("$_lv=$REPLY")
    [ -n "$REPLY" ] && { _lc_name="$REPLY"; _lc_var="$_lv"; }
  done
  # ONE bash started the way a popup starts it — the server's PATH picks it and
  # is its PATH, the server's locale configures it — reports its version, how
  # many characters it counts in two box-drawing ones (2 in UTF-8; 6 when it is
  # counting bytes), and which fzf it would run.
  #
  # That last is bash's OWN command search, because bash is what runs fzf for
  # every picker, and it is not the literal one above: bash tilde-expands a PATH
  # element.  A `~/.local/bin` quoted into PATH by mistake works in every popup,
  # and a literal lookup called fzf missing and exited 1 on a working setup.
  # $HOME is the server's, since that is the one the popup's bash expands.
  # With no bash on that PATH, this process's own stands in.
  _pr_env=("${_lc_env[@]}")
  if [ "$_spath_ok" = 1 ]; then
    _pr_env+=("PATH=$_spath")
    _srv_env HOME && _pr_env+=("HOME=$REPLY")
  fi
  _pv=$("${_pr_env[@]}" "${_sbash:-$BASH}" -c \
          'printf "%s %s %s\n" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "${#1}"; printf fzf:; type -P fzf' _ '├─' \
          2>/dev/null </dev/null)
  read -r _sbmaj _sbmin _lc_w _ <<< "${_pv%%$'\n'*}"
  # No "fzf:" line means the probe did not run at all (a bash that cannot start
  # is its own finding, below); the literal search is then the best there is.
  case "$_pv" in
    *$'\n'fzf:*) _sfzf="${_pv##*$'\n'fzf:}" ;;
    *) [ "$_spath_ok" = 1 ] && _which_in "$_spath" fzf && _sfzf="$REPLY" ;;
  esac

  # The fzf every picker runs is that one, so it is the one judged, by its own
  # --version.  Not this shell's, and not $FZF_MINOR either, which is this
  # process's or whatever --bind-keys baked into the binding: judged from here,
  # a distro's 0.38 ahead of the fzf you installed got "✓ fzf 0.74" and exit 0
  # while every popup failed to start, and a shell with no fzf at all got "not
  # on PATH" from a server that had one.  This shell's fzf stands in only when
  # tmux has no PATH to give.  (`hash` is bash's search without the fork a
  # $(type -P) costs; BASH_CMDS then holds what it found.)
  _myfzf=""; hash fzf 2>/dev/null && _myfzf="${BASH_CMDS[fzf]:-}"
  if [ "$_spath_ok" = 1 ]; then _jfzf="$_sfzf"; else _jfzf="$_myfzf"; fi
  _fzv=""
  if [ -n "$_jfzf" ]; then
    # The version with the user's defaults kept out of it: fzf parses those
    # before it looks at --version, so a bad $FZF_DEFAULT_OPTS made this line
    # print no version at all.  Whether fzf accepts them is its own check below.
    _fzv=$(FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' "$_jfzf" --version 2>/dev/null </dev/null)
    _fzv="${_fzv%% *}"
    # The minor the tiers compare, derived as the preflight derives FZF_MINOR:
    # a 1.x is past all of them.
    _fzm=""
    if [[ "$_fzv" =~ ^([0-9]+)\.([0-9]+) ]]; then
      _fzm=$(( 10#${BASH_REMATCH[2]} ))
      [ $(( 10#${BASH_REMATCH[1]} )) -gt 0 ] && _fzm=999
    fi
    # Below 0.40 the preflight refuses to start a picker at all (--doctor alone
    # is let past it, to say so here).
    if   [ -z "$_fzm" ];        then _warn "could not ask the fzf the popups run its version ($_jfzf)"
    elif [ "$_fzm" -lt 40 ];    then _bad "fzf $_fzv is older than 0.40 — the picker refuses to start"
    elif [ "$_fzm" -ge 74 ];    then _ok "fzf $_fzv (raw filter mode available)"
    elif [ "$_fzm" -ge 67 ];    then _warn "fzf $_fzv — 0.74 adds raw mode, which stops the tree collapsing as you type"
    elif [ "$_fzm" -ge 66 ];    then _warn "fzf $_fzv — 0.67 adds --freeze-left, which keeps a row's identity while a long command scrolls"
    elif [ "$_fzm" -ge 63 ];    then _warn "fzf $_fzv — 0.66 dims the columns the ^] scope is not searching"
    elif [ "$_fzm" -ge 58 ];    then _warn "fzf $_fzv — 0.63 moves the key hints to a footer, so the top of the list stops twitching"
    else _warn "fzf $_fzv — old, but supported (0.58 adds the ^] match scope)"
    fi
    # Which fzf that was, when this shell would have named another.  A different
    # path is only worth a word as a different version: a distro's old package
    # ahead of the one you installed is the usual shape.
    if [ "$_jfzf" != "$_myfzf" ]; then
      if [ -z "$_myfzf" ]; then
        _note "that is $_jfzf, on the tmux server's PATH — this shell finds none, which the popups do not mind"
      else
        _myfzv=$(FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' "$_myfzf" --version 2>/dev/null </dev/null)
        _myfzv="${_myfzv%% *}"
        [ "$_myfzv" != "$_fzv" ] \
          && _note "that is $_jfzf, first on the tmux server's PATH — this shell's is ${_myfzv:-another one}, at $_myfzf"
      fi
    fi
  elif [ "$_spath_ok" = 1 ]; then
    _bad "fzf is not on the tmux server's PATH — every popup closes the moment it opens"
    _note "the server's PATH: $_spath"
    _note "for the running server: tmux set-environment -g PATH \"\$PATH\", from a shell that finds fzf"
  else
    _bad "fzf is not on PATH"
    _note "it must be on the PATH the TMUX SERVER inherited, not just your shell's"
  fi

  if [ "$_spath_ok" = 1 ]; then
    # bash >= 4.3: namerefs (`local -n`, which every option read goes through)
    # are 4.3, `[[ -v arr[k] ]]` and printf's %(...)T are 4.2.  macOS's /bin/bash
    # is 3.2 and dies at the first `declare -A`, before anything can draw — and it
    # is the bash a server PATH without Homebrew's finds.
    if [ -z "$_sbash" ]; then
      _bad "bash is not on the tmux server's PATH — every binding runs it by name"
      _note "the server's PATH: $_spath"
    elif ! [[ "${_sbmaj:-}" =~ ^[0-9]+$ && "${_sbmin:-}" =~ ^[0-9]+$ ]]; then
      _warn "could not ask the bash on the tmux server's PATH its version ($_sbash)"
    elif [ $(( _sbmaj * 100 + _sbmin )) -lt 403 ]; then
      _bad "bash $_sbmaj.$_sbmin on the tmux server's PATH is older than 4.3 — every popup dies before it draws"
      _note "$_sbash: install a newer bash, and put it ahead of that one on the server's PATH"
    else
      _ok "bash $_sbmaj.$_sbmin on the tmux server's PATH"
    fi
  fi

  _repo="${SCRIPT_PATH%/scripts/*}"
  # What to do about a helper that is missing or stale.  The build command only
  # where there is a cargo to run it -- this used to tell a machine with no Rust
  # at all to run cargo.  rustup's own directory counts too: a PATH that only a
  # shell rc extends (~/.cargo/env) is the usual way to have cargo and not find
  # it.  Then what interdimux.tmux's background build is doing, if anything: a
  # build under way, or one that failed, is the answer to "why is it missing".
  _cargo=""
  if command -v cargo >/dev/null 2>&1; then _cargo=cargo
  elif [ -x "${CARGO_HOME:-$HOME/.cargo}/bin/cargo" ]; then _cargo="${CARGO_HOME:-$HOME/.cargo}/bin/cargo"
  fi
  _build_hint() { # $1 = build | rebuild
    local first last blog="$SCHED_LOGDIR/build.log"
    if [ ! -f "$_repo/rust/Cargo.toml" ]; then
      _note "this install has no rust/ sources to build: point INTERDIMUX_BIN at a prebuilt imux"
      _note "for the popups: tmux set-environment -g INTERDIMUX_BIN <path>"
      return 0
    elif [ -n "$_cargo" ]; then
      _note "$1 it with: (cd '$_repo/rust' && $_cargo build --release)"
    else
      _note "no cargo here: install Rust (https://rustup.rs) and $1 it, or point INTERDIMUX_BIN at a prebuilt imux"
      _note "for the popups: tmux set-environment -g INTERDIMUX_BIN <path>"
    fi
    if imux_autobuild_running "$_repo"; then
      _note "the plugin is building it in the background right now: $blog"
    elif [ -s "$blog" ] && IFS= read -r first < "$blog" \
         && case "$first" in "== building $_repo/rust "*) true ;; *) false ;; esac; then
      last=$(tail -n 1 "$blog" 2>/dev/null)
      case "$last" in "== failed"*) _note "the plugin's last build of it failed: $blog" ;; esac
    fi
  }
  # The helper the POPUPS run, picked the way the top of this file picks it, but
  # from the tmux server's environment: that is where INTERDIMUX_BIN belongs
  # (`tmux set-environment -g`, as the notes here advise), and it is the one a
  # popup starts from.  Judged from this process's own, a doctor run from a
  # terminal vetted the in-repo build while every popup ran whatever the
  # server's INTERDIMUX_BIN named.  Run from the Health popup the two agree.
  _pur=on; _srv_env INTERDIMUX_USE_RUST && _pur="${REPLY:-on}"
  _pib="";  _srv_env INTERDIMUX_BIN && _pib="$REPLY"
  _pbin="" _prefused=0
  if [ "$_pur" != off ]; then
    for _c in "$_pib" "$_repo/rust/target/release/imux" "$_repo/bin/imux"; do
      if [ -n "$_c" ] && [ -x "$_c" ]; then _pbin="$_c"; break; fi
    done
  fi
  if [ -n "$_pbin" ]; then
    # Ask it what it is.  The helper is picked by an -x test, which any
    # executable passes, and this used to give a green tick to whatever printed
    # anything at all — `/bin/ls` got "✓ ls (GNU coreutils) 9.4".  The real one
    # answers "imux <version>".  </dev/null: something that reads stdin instead
    # must not hang the report.
    if _v=$("$_pbin" --version 2>/dev/null </dev/null) && [ -n "$_v" ]; then
      case "$_v" in
        'imux '*)
          # ...and whether it speaks THIS script's protocol, the way the list
          # asks: a build from other sources -- the usual state after a `git
          # pull` or a TPM update, neither of which rebuilds rust/ -- answers
          # --version like any other and is then refused on every draw
          # (imux_refused).  It used to get a green tick here, before any list
          # had been drawn and after.  Exit 2 is the refusal; a build that
          # speaks IMUX_PROTO reads the empty stdin and exits 3, at once.
          "$_pbin" "$IMUX_PROTO" </dev/null >/dev/null 2>&1
          if [ "$?" = 2 ]; then
            _prefused=1
            _bad "$_pbin is from another version of interdimux (it does not speak $IMUX_PROTO): the list uses the slower bash renderer"
            if [ "$_pbin" = "$_repo/rust/target/release/imux" ]; then
              _build_hint rebuild
            else
              _note "rebuild it, or point INTERDIMUX_BIN at a build of this version"
              _note "for the popups: tmux set-environment -g INTERDIMUX_BIN <path>"
            fi
          else
            _ok "$_v at $_pbin"
          fi ;;
        *) _bad "$_pbin is not the interdimux helper — its --version says: ${_v%%$'\n'*}"
           _note "the list notices, and falls back to the slow bash renderer; point INTERDIMUX_BIN at an imux build" ;;
      esac
    else
      _bad "rust helper at $_pbin is present but does not run"
      _build_hint rebuild
    fi
  elif [ "$_pur" = off ]; then
    _warn "rust helper disabled by INTERDIMUX_USE_RUST=off"
  else
    _warn "rust helper not found — falling back to the minimal bash renderer"
    _build_hint build
  fi
  # The shell this was typed into is the obvious place to look, and the wrong
  # one; say so when it would have picked differently.
  [ "$_pbin" != "${IMUX_BIN:-}" ] \
    && _note "that is the tmux server's pick, which the popups get — this shell's environment picks ${IMUX_BIN:-the bash renderer}"
  # An INTERDIMUX_BIN that is not executable is skipped in favour of the in-repo
  # build, silently — the line above then names a different binary than the one
  # asked for, with nothing to say why.
  if [ -n "$_pib" ] && [ "$_pur" != off ] && [ "$_pbin" != "$_pib" ]; then
    _warn "INTERDIMUX_BIN=$_pib is not an executable file, so it is ignored"
  fi

  # The MRU order is stable only because the sort is: without `-s`, GNU sort
  # breaks a tie in session_last_attached (one-second resolution, so ties are
  # routine) with its last-resort comparison, which orders by the user's
  # COLLATION — and the Rust core, which sorts stably, then disagrees with the
  # bash fallback about the order of the list.  `-s` is the one non-POSIX flag
  # this file relies on (GNU, BSD and busybox all have it), and a sort that
  # rejected it would empty the session list outright, so it is verified rather
  # than assumed.
  if printf 'b\na\n' | sort -s >/dev/null 2>&1; then
    _ok "sort -s is supported (the session order is stable, and locale-free)"
  else
    _bad "this sort rejects -s — the session list would come out empty"
    _note "the MRU sort needs it; it is present in GNU, BSD and busybox sort"
  fi

  # The tree glyphs and every width calculation assume UTF-8.  Without it the
  # box-drawing characters arrive as mojibake and the column arithmetic — which
  # counts CELLS — is measuring something the terminal is not drawing.
  #
  # Measured, not read off the name, and in the popups' environment.  A UTF-8
  # locale that is named but not installed — LANG sent over ssh to a host that
  # never generated it, a minimal container — makes bash fall back to C: ${#…}
  # counts BYTES, every column misaligns, and every bash the navigator starts
  # prints a setlocale warning.  The name looked perfect, so this used to say ✓.
  # The probe near the top of this section counted the characters in a bash
  # started with the popups' locale (_lc_w).
  #
  # "<chars>:<name>".  An empty count means the probe itself could not run, and
  # then the name is all there is to go on.
  case "$_lc_w:$_lc_name" in
    2:*|:*[Uu][Tt][Ff]*8*)
      _ok "character encoding is UTF-8 (${_lc_name:-the system default})" ;;
    *:*[Uu][Tt][Ff]*8*)
      _bad "locale '$_lc_name' is not installed — bash falls back to C and counts bytes, so every column misaligns"
      _note "generate it (locale-gen $_lc_name), or give tmux one that exists: tmux set-environment -g $_lc_var C.UTF-8"
      _note "it is also what bash's 'setlocale: cannot change locale' warning is about" ;;
    *:)
      _warn "no locale is set — the tree glyphs need a UTF-8 one"
      _note "export LANG=C.UTF-8 (or your own) where the tmux SERVER can see it" ;;
    *)
      _warn "locale '$_lc_name' is not UTF-8 — the tree glyphs will be mojibake"
      _note "the column widths count cells, so a non-UTF-8 terminal misaligns them" ;;
  esac
  # The shell this was typed into is the obvious place to look, and the wrong
  # one; say so when it disagrees.
  _lc_self="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  [ "$_lc_self" != "$_lc_name" ] \
    && _note "that is the tmux server's locale, which the popups get — this shell's is '${_lc_self:-unset}'"

  # $FZF_DEFAULT_OPTS (and _FILE) is applied to every picker before this tool's
  # own flags and is invisible to the option validator below, which only reads
  # @interdimux-fzf-opts.  The server's copy, again: it is the one the pickers get.
  _fdo="" _fdof=""
  _srv_env FZF_DEFAULT_OPTS exact && _fdo="$REPLY"
  _srv_env FZF_DEFAULT_OPTS_FILE && _fdof="$REPLY"

  # Whether fzf takes them at all is the one thing here that can break a picker.
  # fzf parses its defaults before any flag, so one option it does not know — a
  # typo, a flag from a newer fzf — makes EVERY picker exit before it draws, and
  # --version is enough to find out.  Asked of the fzf the popups run.
  #
  # Nothing else in them can.  build_fzf_theme resets what people usually put
  # there — --tmux/--popup, --height, --border, --margin, --padding, --style,
  # --preview, --with-shell, and every colour — on each fzf that parses the
  # flag, and an fzf too old to parse one rejects it here.  This used to warn
  # about those very flags, and to advise moving them to @interdimux-fzf-opts:
  # the one place they DO take effect, since it comes after the resets.
  # Following it turned a harmless global setting into the nested frame and
  # shrunk list the resets exist to prevent.  (Whether the flags there are
  # sensible is the option check's business, and a deliberate choice's.)
  if { [ -n "$_fdo" ] || [ -n "$_fdof" ]; } && [ -n "$_jfzf" ]; then
    if ! _fe=$(FZF_DEFAULT_OPTS="$_fdo" FZF_DEFAULT_OPTS_FILE="$_fdof" "$_jfzf" --version 2>&1 >/dev/null </dev/null); then
      _bad "fzf rejects its default options — every picker exits before it draws"
      _note "${_fe%%$'\n'*}"
      [ "$_fdo" != "${FZF_DEFAULT_OPTS:-}" ] \
        && _note "that is the tmux server's \$FZF_DEFAULT_OPTS, which the pickers get — this shell's differs"
    else
      if [ -n "$_fdo" ] && [ -n "$_fdof" ]; then
        _ok "\$FZF_DEFAULT_OPTS and \$FZF_DEFAULT_OPTS_FILE are set, and fzf accepts them — the pickers reset their layout and colours"
      elif [ -n "$_fdo" ]; then
        _ok "\$FZF_DEFAULT_OPTS is set, and fzf accepts it — the pickers reset its layout and colours"
      else
        _ok "\$FZF_DEFAULT_OPTS_FILE is set, and fzf accepts it — the pickers reset its layout and colours"
      fi
      _note "--tmux/--popup, --height, --border, --margin, --padding, --style and --with-shell are all overridden;"
      _note "@interdimux-fzf-opts is where a deliberate one goes"
    fi
  fi

  # A binary older than the sources it was built from renders differently from
  # the bash fallback, and the difference is silent — the picker still opens.
  # Only when the binary belongs to THIS checkout.  One installed elsewhere has
  # no relationship to these sources, and a fresh clone — which stamps every
  # source with the checkout time — would otherwise report it stale for ever.
  # -type f as well, or find returns the start directory and it takes one of the
  # three slots below.  The popups' helper, as picked above.
  # Not for one the protocol check above refused: the list does not run it at
  # all, and that line has already said to rebuild it.
  if [ -n "$_pbin" ] && [ "$_prefused" = 0 ] && [ -d "$_repo/rust/src" ] \
     && case "$_pbin" in "$_repo"/*) true ;; *) false ;; esac; then
    _newer=$(find "$_repo/rust/src" "$_repo/rust/Cargo.toml" -type f -newer "$_pbin" 2>/dev/null | head -3)
    if [ -n "$_newer" ]; then
      _warn "the rust helper is older than its sources — it is rendering last build's layout"
      while IFS= read -r _nf; do [ -n "$_nf" ] && _note "newer: ${_nf#"$_repo/"}"; done <<< "$_newer"
      _build_hint rebuild
    fi
  fi

  if command -v at >/dev/null 2>&1; then
    _ok "at is installed (Schedule, --send-at / --send-in beyond a minute)"
    # `at` without its job-runner accepts jobs, queues them, and never fires
    # them — silently.  The only symptom is a command that did not run, hours
    # later, which is exactly the failure this tool must not have.  The runner is
    # atd on Linux and atrun (launchd) on macOS; at_daemon_state knows the
    # difference and reads each without root, and says so honestly when it cannot
    # tell (BSD's cron-atrun, or a host without pgrep) rather than crying wolf.
    # (its non-empty lines, as `| grep -c .` counted them, without the grep)
    _npend=0
    while IFS= read -r _pl; do
      [ -z "$_pl" ] || _npend=$((_npend + 1))
    done <<< "$(atq -q "$SCHED_QUEUE" 2>/dev/null)"
    case "${_npend:-0}" in
      0) ;;
      1) _note "1 command is scheduled — see it under Jobs on the dashboard" ;;
      *) _note "$_npend commands are scheduled — see them under Jobs on the dashboard" ;;
    esac
    case "$(at_daemon_state)" in
      up)   _ok "at's job-runner is active — scheduled jobs will fire" ;;
      down) _bad "at's job-runner is not active — jobs would queue but never fire"
            _note "enable it: $(at_enable_hint)" ;;
      *)    _note "could not verify at's job-runner from here — ensure it is enabled" ;;
    esac
  else
    _warn "at is not installed — only sub-minute delays work (tmux's own timer)"
    _note "install it, then enable its job-runner, for the dashboard's Schedule entry"
  fi

  # A '#' is handled (SQ_SCRIPT_FMT doubles it, so tmux's format expansion gives
  # the path back).  A single quote is NOT: verified by driving a real key press
  # from such a path, the popup never opened -- tmux's command parser re-escapes
  # the '\'' sequence and the shell then sees a different string.  Report it
  # rather than pretend, because the symptom is a key that does nothing at all.
  case "$SCRIPT_PATH" in
    *"'"*) _bad "the install path contains a single quote: $SCRIPT_PATH"
           _note "the key bindings cannot survive it — move the install somewhere without one" ;;
    *'#'*) _ok "install path contains '#', which is escaped for tmux format expansion" ;;
    *)     _ok "install path is safe to embed in a key binding" ;;
  esac

  # The navigator routes its stderr to a log rather than painting it over the
  # list, so this is the one place a past failure is still visible.
  #
  # Only what is new is a problem, though.  Any entry at all used to keep this
  # red for good -- months after its cause was fixed, which teaches you to
  # ignore the check (UX-17).  `--doctor --ack` marks the log as seen by writing
  # its newest entry's header to errors.seen; an entry after the last copy of
  # that header is new, and with no marker, or the marked entry trimmed away,
  # every entry is.  Seen ones are still reported, as a warning.  One awk pass:
  # the entries (text above the first header is one, as for --ack), how many
  # are new, and the newest one's header and first line.
  _elog="$SCHED_LOGDIR/errors.log"
  if [ -s "$_elog" ]; then
    _eseen=""; { IFS= read -r _eseen < "$SCHED_LOGDIR/errors.seen"; } 2>/dev/null || :
    _ein=$(awk -v seen="$_eseen" -v start="$_estart" '
      !n && !/^== / { n = 1; h = start; if (h == seen) s = 1; want = 1 }
      /^== / { n++; if ($0 == seen) s = n; h = $0; l = $0; want = 1; next }
      want && /[^[:space:]]/ { l = $0; want = 0 }
      END { print n + 0; print n - s; print h; print l }' "$_elog" 2>/dev/null)
    { read -r _en; read -r _enew; IFS= read -r _ehdr; IFS= read -r _elast; } <<< "$_ein" || :
    # "most recent: 2026-07-28 12:00:00 — <its first line>": the date is what
    # says whether it is still news.
    read -r _ _ed _et _ <<< "$_ehdr" || :
    _eat="$_ed $_et — "
    [[ "$_ed" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || _eat=""
    if [ "${_enew:-0}" -gt 0 ] || [ "${_en:-0}" = 0 ]; then
      _ewhat="error(s)"
      [ "${_enew:-0}" -lt "${_en:-0}" ] && _ewhat="new error(s)"
      _bad "the navigator has logged ${_enew:-0} $_ewhat"
      _note "most recent: $_eat$_elast"
      _note "full log: $_elog"
      # The flag first: in the Health popup a long install path is cut off,
      # and the note would end before it said what to run.
      _note "acknowledge them with --doctor --ack: bash '$SCRIPT_PATH' --doctor --ack"
    else
      _warn "the navigator has logged $_en error(s), all acknowledged"
      _note "most recent: $_eat$_elast"
      _note "full log: $_elog"
    fi
  else
    _ok "no navigator errors logged"
  fi

  for _d in "${XDG_DATA_HOME:-$HOME/.local/share}/interdimux" "$SCHED_LOGDIR"; do
    if mkdir -p "$_d" 2>/dev/null && [ -w "$_d" ]; then
      _ok "writable: $_d"
    else
      _bad "not writable: $_d"
      _note "recent directories and the scheduled-keys log cannot be saved"
    fi
  done

  # Where the navigator keeps its scratch files (the resume flag, the preview
  # state, the stderr it reports): $XDG_RUNTIME_DIR when it is usable, else
  # $TMPDIR — as the popups' environment has them.  A tmp dir that was gone or
  # full used to end the navigator before it drew, with nothing here to say why.
  # It falls back to the state dir now, so this is a warning, unless that one is
  # unwritable too, which the line above reports.  A real file, not `-w`: a full
  # disk passes -w.
  _srt=""
  _srv_env XDG_RUNTIME_DIR && _srt="$REPLY"
  _stmp=/tmp
  _srv_env TMPDIR && [ -n "$REPLY" ] && _stmp="$REPLY"
  if [ -n "$_srt" ] && [ -d "$_srt" ] && [ -w "$_srt" ]; then
    _ok "writable: $_srt (the navigator's scratch files)"
  elif _tf=$(mktemp "$_stmp/interdimux-doctor.XXXXXX" 2>/dev/null); then
    rm -f "$_tf"
    _ok "writable: $_stmp (the navigator's scratch files)"
  else
    _warn "cannot create a file in $_stmp — the navigator keeps its scratch files in $SCHED_LOGDIR instead"
    _note "that is \$TMPDIR as the tmux server has it (or /tmp): tmux show-environment -g TMPDIR"
  fi

  # --- key bindings -----------------------------------------------------------
  _sec 'key bindings'
  _k=$(tmux show-option -gqv @interdimux-key);           _k="${_k:-f}"
  _dk=$(tmux show-option -gqv @interdimux-dashboard-key); _dk="${_dk:-g}"
  # Read the table once and match the key column ourselves: `list-keys -T prefix
  # <key>` prints nothing on tmux 3.7b, so filtering with it silently reports
  # every binding as missing.
  # A pattern test and a here-string, not `printf … | grep -q`: grep -q exits
  # at its first match, and a printf still writing the rest of the table then
  # dies of SIGPIPE — which pipefail (on for this whole file) turns into "no
  # match".  Under load, or with a big enough table, the report said no
  # bindings were installed.
  _keytable=$(tmux list-keys -T prefix 2>/dev/null)
  if [[ "$_keytable" == *interdimux* ]]; then
    # Both keys in one pass over the table, not an awk each: a line per key,
    # "1 <the fzf minor --bind-keys baked into it, if any>" (only prefix+f's
    # carries one) when it is bound, else "0".
    _bres=$(awk -v k1="${_k%%:*}" -v k2="${_dk%%:*}" '
      function hit(i) {
        f[i] = 1
        if (match($0, /INTERDIMUX_FZF_MINOR=[0-9]+/)) m[i] = substr($0, RSTART + 21, RLENGTH - 21)
      }
      $2=="-T" && $3=="prefix" && /interdimux/ { if ($4==k1) hit(1); if ($4==k2) hit(2) }
      END { for (i = 1; i <= 2; i++) print (f[i] ? "1 " m[i] : "0") }' <<< "$_keytable")
    _bi=0
    for _pair in "$_k:navigator" "$_dk:dashboard"; do
      _key="${_pair%%:*}"; _what="${_pair#*:}"
      _bi=$((_bi + 1))
      if [ "$_bi" = 1 ]; then _bl="${_bres%%$'\n'*}"; else _bl="${_bres#*$'\n'}"; fi
      if [ "${_bl%% *}" = 1 ]; then
        _bfz="${_bl#1 }"
        _ok "prefix+$_key opens the $_what"
        # That number is fzf's version as it was when the plugin last loaded,
        # and every fzf feature the picker uses is gated on it.  Nothing
        # refreshes it: after an upgrade the new features stay off, and after
        # a downgrade the picker asks the older fzf for options it refuses, and
        # does not open (BUG-100).  The version judged above is the live one.
        if [ -n "$_bfz" ] && [ -n "${_fzm:-}" ] && [ "$_bfz" != "$_fzm" ]; then
          _bfv="0.$_bfz"; [ "$_bfz" = 999 ] && _bfv="1.x"
          if [ "$_bfz" -gt "$_fzm" ]; then
            _bad "prefix+$_key was set up for fzf $_bfv, newer than the fzf $_fzv the popups run — it may not open"
          else
            _warn "prefix+$_key was set up for fzf $_bfv, older than the fzf $_fzv the popups run — its newer features stay off"
          fi
          _note "reload the plugin, or run: bash '$SCRIPT_PATH' --bind-keys"
        fi
      else
        _bad "prefix+$_key is not bound to the $_what"
        _note "reload the plugin, or run: bash '$SCRIPT_PATH' --bind-keys"
      fi
    done
  else
    _bad "no interdimux key bindings are installed"
    _note "run: bash '$SCRIPT_PATH' --bind-keys"
  fi

  # The dashboard is a native menu when it fits and an fzf popup when it does
  # not, and BOTH have silently drawn nothing in the past when the client was too
  # short: display-menu exits 0 without painting, display-popup refuses a size
  # larger than the client.  Both are guarded now, so this is not a failure — but
  # it is worth saying which one the user is about to get, because they look
  # different and "prefix+g looks wrong" is otherwise unexplainable.
  client_dims; _dh="${REPLY% *}" _dwid="${REPLY#* }"
  if [ "$_dh" = 0 ]; then
    _note "no client attached here, so the dashboard's size could not be checked"
  elif ! tmux_ge 304; then
    _note "tmux < 3.4: the dashboard is the fzf popup, not a native menu"
  elif [ "$_dh" -ge "$MENU_ROWS" ]; then
    _ok "the client is ${_dwid}x${_dh} — the dashboard draws as a native menu"
  else
    _warn "the client is only $_dh rows — the dashboard falls back to the fzf popup"
    _note "the native menu needs $MENU_ROWS rows; the popup version scrolls instead"
  fi

  # --- options ----------------------------------------------------------------
  _sec options
  # Names the code understands but that are not in OPT_MAP: they are read at
  # bind time rather than forwarded to the popup.
  # (No `binary`: the helper's path is read from $INTERDIMUX_BIN only, and an
  # option by that name was once accepted here and green-ticked while nothing
  # read it.  Unknown now, so setting it says so.)
  # (`autobuild` is read by interdimux.tmux, at plugin load.)
  _known=("${OPT_NAMES[@]}" key dashboard-key jump-keys agent-next-key autobuild)

  # One pattern test, not a loop over the fifty names for every option set (a
  # statement each).  A name here never holds a blank.
  _known_s=" ${_known[*]} "
  _is_known() { [[ "$_known_s" == *" $1 "* ]]; }

  # Longest-common-prefix suggestion.  Crude on purpose: the realistic typo is a
  # dropped or doubled character, not an anagram.
  _suggest() {
    local want="$1" n i best="" bestlen=0 len
    for n in "${_known[@]}"; do
      len=0
      for (( i = 0; i < ${#want} && i < ${#n}; i++ )); do
        [ "${want:i:1}" = "${n:i:1}" ] || break
        len=$((len + 1))
      done
      [ "$len" -gt "$bestlen" ] && { bestlen="$len"; best="$n"; }
    done
    [ "$bestlen" -ge 4 ] && REPLY="$best" || REPLY=""
  }

  # A value's domain, by option name.  Empty always means "unset, use default".
  # The complaint goes to _why (_cv: printf's formatting), not to stdout: a
  # $(_check_value) was a fork for every option set, sixteen for the VPS
  # user's.  fzf-opts alone is still judged in one, and prints (see the loop).
  _cv() { local m; printf -v m "$@"; _why+="$m"; }
  _check_value() { # $1 = name, $2 = value -> _why gets a complaint, or nothing
    local n="$1" v="$2" _d
    [ -n "$v" ] || return 0
    case "$n" in
      show-preview|show-full-command|show-git-branch|use-zoxide|dirs-live-search|hydrate|show-dirs|raw|session-rule|scope-highlight|autobuild)
        case "$v" in on|off) ;; *) _cv "expected 'on' or 'off'" ;; esac ;;
      order)
        case "$v" in mru|index) ;; *) _cv "expected 'mru' or 'index'" ;; esac ;;
      # The agent options, in the terms the script replaces a bad value in
      # (right after the get_opt calls): the default, which for agent-args is
      # off and for agent-state on -- so a `yes` does the opposite of what it
      # says for one of them.
      agent-args)
        case "$v" in on|off) ;; *) _cv "expected 'on' or 'off', so it stays off" ;; esac ;;
      agent-state)
        case "$v" in on|off) ;; *) _cv "expected 'on' or 'off', so it stays on" ;; esac ;;
      agent-separator)
        case "$v" in
          off) ;;
          *[[:cntrl:]]*) _cv "holds a control character, so the default, ∣, applies" ;;
          *) [ "${#v}" -le 3 ] || _cv 'at most 3 characters, so the default, ∣, applies' ;;
        esac ;;
      show-title)
        case "$v" in known|all|off) ;; *) _cv "expected 'known', 'all' or 'off', so it stays known" ;; esac ;;
      title-max)
        # Decimal whatever the leading zeros, then clamped to 8..200.
        case "$v" in
          *[!0-9]*) _cv 'expected a whole number from 8 to 200, so the default, 40, applies' ;;
          *) _d="${v#"${v%%[!0]*}"}"; _d="${_d:-0}"
             if [ "${#_d}" -gt 3 ] || [ "$_d" -gt 200 ]; then _cv 'the most is 200, so 200 applies'
             elif [ "$_d" -lt 8 ]; then _cv 'the least is 8, so 8 applies'
             fi ;;
        esac ;;
      agents)
        # `off`, or names: a word with anything but letters, digits, '.', '_'
        # and '-' is skipped (AGENT_KNOWN), and says nothing where it is.
        local _w _skip=""
        if [ "$v" != off ]; then
          set -f
          for _w in $v; do
            case "$_w" in *[!A-Za-z0-9._-]*) _skip+="${_skip:+, }'$_w'" ;; esac
          done
          set +f
          [ -z "$_skip" ] || _cv 'skipped: %s (a name is letters, digits, dots, underscores and hyphens)' "$_skip"
        fi ;;
      recent-limit|dirs-limit|scan-depth)
        case "$v" in ''|*[!0-9]*) _cv 'expected a whole number' ;; esac
        # Decimal, whatever the leading zeros, as the script reads it; and the
        # length first, as there: `[ -gt ]` on a 20-digit number is an error.
        [ "$n" = scan-depth ] && case "$v" in ''|*[!0-9]*) ;; *)
          _d="${v#"${v%%[!0]*}"}"; _d="${_d:-0}"
          { [ "${#_d}" -gt 2 ] || [ "$_d" -gt 10 ]; } && _cv 'deeper than 10 will not finish inside a popup' ;; esac ;;
      popup-width|popup-height)
        case "$v" in *%) case "${v%\%}" in ''|*[!0-9]*) _cv 'expected NN or NN%%' ;; esac ;;
                     ''|*[!0-9]*) _cv 'expected NN or NN%%' ;; esac ;;
      color-*)
        # Exactly: '#' and six hex digits, 0-255, -1, or default.  The length
        # alone let '#zzzzzz' through.  [[:xdigit:]] rather than a range: under
        # bash < 5 a range follows the locale's collation.
        case "$v" in
          default|-1) ;;
          '#'[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]) ;;
          '#'*) _cv 'a hex colour must be #rrggbb' ;;
          ''|*[!0-9]*) _cv 'expected #rrggbb, a 0-255 index, or default' ;;
          # Length first: `[ "$v" -le 255 ]` on a 26-digit number is not false,
          # it is "integer expression expected" ON STDERR — which used to land
          # above the report's own title.
          ????*) _cv 'a colour index must be 0-255' ;;
          *) [ "$v" -le 255 ] || _cv 'a colour index must be 0-255' ;;
        esac ;;
      key|dashboard-key|agent-next-key)
        # Any key tmux can bind, not one character: --bind-keys hands the value to
        # `tmux bind-key` as it is, and C-f, M-g, F5 and Space all bind fine — a
        # length test called them wrong in the same report that confirmed them
        # bound.  So ask tmux: `list-keys -T prefix <key>` changes nothing and
        # fails with "invalid key: …" on exactly what bind-key would refuse ('ff',
        # 'C-', 'X-f').  By that text, not by its exit status: tmux 3.6 — the
        # floor — ALSO fails, with "unknown key: …", for a perfectly good key that
        # is merely not bound in the prefix table yet (3.7 dropped that).  So a
        # key set after the plugin loaded, the very case this report exists for,
        # was called unknown while the message listed it as an example.
        # A bare ';' is the one it cannot judge — tmux reads it as a command
        # separator, so the query "succeeds" and the binding never happens.
        # The opt-in agent-next key is never bound over the navigator's or the
        # dashboard's key (--bind-keys skips it), which nothing else here would
        # show: that key still opens what it opened, so it ticks.
        local _ke
        if [ "$n" = agent-next-key ]; then
          case "$v" in
            "$_k")  _cv 'prefix+%s opens the navigator, so it is not bound to --agent-next' "$v"; return 0 ;;
            "$_dk") _cv 'prefix+%s opens the dashboard, so it is not bound to --agent-next' "$v"; return 0 ;;
          esac
        fi
        case "$v" in
          ';') _cv "tmux reads a bare ';' as a command separator, so it cannot be bound this way" ;;
          *)   _ke=$(tmux list-keys -T prefix "$v" 2>&1 >/dev/null) \
                 || case "$_ke" in
                      'invalid key'*) _cv 'not a key tmux knows (e.g. f, C-f, M-g, F5, Space)' ;;
                    esac ;;
        esac ;;
      fzf-opts)
        # Two ways this option silently does nothing, both checked the way the
        # pickers meet the value.  build_fzf_theme evals it into words and, when
        # that fails, drops the WHOLE set — on purpose, so a stray quote cannot
        # kill every picker — without a word.  And the words reach fzf last, so
        # one it does not know makes every picker exit before it draws.  fzf
        # parses every flag before it honours --version, so that finds it; its
        # own defaults are kept out, so they are not blamed on this.  (The eval
        # is the one the navigator runs on every open, so it risks nothing new.)
        # The parse is tried in a subshell of its own first: this runs inside
        # $(…), and there a syntax error in eval ends the whole subshell instead
        # of failing the command — which printed nothing, i.e. "✓".
        local -a _u=()
        if ! ( eval "_u=($v)" ) 2>/dev/null; then
          printf 'does not parse as shell words (an unbalanced quote?), so none of it applies'
          return 0
        fi
        eval "_u=($v)" 2>/dev/null
        # --tmux/--popup here is not what it is in $FZF_DEFAULT_OPTS, which the
        # theme cancels: these words come last, so nothing overrides them.
        local _w _pop=""
        for _w in ${_u[@]+"${_u[@]}"}; do
          case "$_w" in
            --tmux|--tmux=*|--popup|--popup=*) _pop="${_w%%=*}" ;;
            --no-tmux|--no-popup)              _pop="" ;;
          esac
        done
        if [ -n "$_pop" ]; then
          printf '%s makes fzf open a popup of its own, underneath the one the picker is in, which stays blank' "$_pop"
          return 0
        fi
        # The fzf the popups run, as the environment section found it.
        local _e
        if [ -n "$_jfzf" ] \
           && ! _e=$(FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' "$_jfzf" --version ${_u[@]+"${_u[@]}"} 2>&1 >/dev/null </dev/null); then
          printf 'fzf rejects it, so every picker exits before it draws: %s' "${_e%%$'\n'*}"
        fi ;;
      jump-keys)
        # space-separated tmux key specs; the count is what maps to #1, #2, …
        case "$v" in *[!A-Za-z0-9\ ^\-]*) _cv 'expected space-separated tmux keys, e.g. "M-1 M-2 M-3"' ;; esac ;;
    esac
  }

  # Every @interdimux-* actually set, global and session scope.  Each line comes
  # tagged with its scope (g/s), so a value can be re-read from the right one.
  _optlines=$( { tmux show-options -g 2>/dev/null; echo '#session'; tmux show-options 2>/dev/null; } \
            | awk '$0 == "#session" { sc = "s"; next }
                   /^@interdimux-/ && !seen[$0]++ { print (sc == "" ? "g" : sc) " " $0 }' )
  # The values show-options prints quoted or escaped are read back raw (see
  # below), and when there are several -- every '#rrggbb' colour is one -- in
  # ONE tmux client, each followed by a marker line: a client each cost ~3 ms,
  # fifteen colours ~50 ms of the report.  Taken only if the markers frame the
  # values exactly -- each in its place, none left over, as a value holding
  # such a line would leave one -- and each one is then what $(show-option -v)
  # gives; otherwise every value is read on its own, as it always was.
  _rq=() _rv=() _rn=0 _rmark='interdimux:end-of-value'
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _scope="${_line%% *}"; _line="${_line#* }"; _name="${_line%% *}"
    _val="${_line#* }"; [ "$_val" = "$_line" ] && _val=""
    case "$_val" in
      \"*|\'*|*\\*)
        [ "$_rn" = 0 ] || _rq+=(\;)
        if [ "$_scope" = g ]; then _rq+=(show-option -gqv "$_name"); else _rq+=(show-option -qv "$_name"); fi
        _rq+=(\; display-message -p "$_rmark")
        _rn=$((_rn + 1)) ;;
    esac
  done <<< "$_optlines"
  if [ "$_rn" -gt 1 ]; then
    _rall=$(tmux "${_rq[@]}" 2>/dev/null; printf x); _rall="${_rall%x}"
    while [ "${#_rv[@]}" -lt "$_rn" ]; do
      case "$_rall" in
        "$_rmark"$'\n'*) _rv+=(""); _rall="${_rall#"$_rmark"$'\n'}" ;;    # unset since
        *$'\n'"$_rmark"$'\n'*)
          _r="${_rall%%$'\n'"$_rmark"$'\n'*}"; _rall="${_rall#*$'\n'"$_rmark"$'\n'}"
          while [[ "$_r" == *$'\n' ]]; do _r="${_r%$'\n'}"; done
          _rv+=("$_r") ;;
        *) break ;;
      esac
    done
    [ "${#_rv[@]}" = "$_rn" ] && [ -z "$_rall" ] || _rv=()
  fi
  _seen=0 _ri=0
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _scope="${_line%% *}"; _line="${_line#* }"
    _name="${_line%% *}"; _name="${_name#@interdimux-}"
    _val="${_line#* }"; [ "$_val" = "$_line" ] && _val=""
    # show-options prints a value the way tmux's own parser would need it: in
    # quotes, with \" \$ and \\ escaped, so `--bind "x:y"` comes out as
    # "--bind \"x:y\"".  That is fine to show, but it is not the value the code
    # reads — checked in that form, a perfectly good @interdimux-fzf-opts would be
    # "rejected by fzf".  So a quoted or escaped one is read back raw to be checked.
    _raw="$_val"
    case "$_val" in
      \"*|\'*|*\\*)
        if [ "$_ri" -lt "${#_rv[@]}" ]; then _raw="${_rv[_ri]}"
        elif [ "$_scope" = g ]; then _raw=$(tmux show-option -gqv "@interdimux-$_name" 2>/dev/null)
        else _raw=$(tmux show-option -qv "@interdimux-$_name" 2>/dev/null)
        fi
        _ri=$((_ri + 1)) ;;
    esac
    _val="${_val%\"}"; _val="${_val#\"}"
    _seen=$((_seen + 1))
    if ! _is_known "$_name"; then
      _suggest "$_name"
      if [ -n "$REPLY" ]; then
        _bad "unknown option @interdimux-$_name — did you mean @interdimux-$REPLY?"
      else
        _bad "unknown option @interdimux-$_name"
      fi
      [ "$_name" = binary ] \
        && _note "the helper's path comes from \$INTERDIMUX_BIN only — for the popups: tmux set-environment -g INTERDIMUX_BIN <path>"
      continue
    fi
    # fzf-opts in a $(…) still, its check as it was: the eval runs what the
    # value holds, and what that prints or defines must land where it did, in
    # the complaint or nowhere.
    _why=""
    if [ "$_name" = fzf-opts ]; then _why=$(_check_value "$_name" "$_raw")
    else _check_value "$_name" "$_raw"
    fi
    if [ -n "$_why" ]; then
      _bad "@interdimux-$_name = '$_val' — $_why"
    else
      _ok "@interdimux-$_name = '$_val'"
    fi
  done <<< "$_optlines"
  [ "$_seen" = 0 ] && _note 'nothing set — every option is at its default'

  # A hide pattern that matches no session is indistinguishable from a working
  # one: the list simply looks normal.  Naming the dead pattern is the only way a
  # typo ever surfaces.
  # Read from tmux, not from $HIDE_PATTERNS.  In the Health popup the latter is
  # the value forwarded at launch, so this could contradict the option list
  # printed immediately above it — which does read tmux.  Session scope first,
  # then global, matching get_opt.
  _hv=$(tmux show-option -qv @interdimux-hide 2>/dev/null)
  [ -n "$_hv" ] || _hv=$(tmux show-option -gqv @interdimux-hide 2>/dev/null)
  if [ -n "$_hv" ]; then
    _snames=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
    _cur_s=$(tmux display-message -p ${TMUX_PANE:+-t "$TMUX_PANE"} '#S' 2>/dev/null)
    # set -f for the same reason the hide loops themselves need it: unquoted, the
    # patterns would be pathname-expanded against the cwd first, and this check
    # would then report the FILENAMES it found rather than the patterns the user
    # set — which is how that bug was noticed.
    set -f
    for _hp in $_hv; do
      _hit=0 _hit_cur=0
      while IFS= read -r _sn; do
        [ -n "$_sn" ] || continue
        # shellcheck disable=SC2254  # the pattern is the point
        case "$_sn" in
          $_hp) if [ "$_sn" = "$_cur_s" ]; then _hit_cur=1; else _hit=1; break; fi ;;
        esac
      done <<< "$_snames"
      if [ "$_hit" = 1 ]; then
        _ok "@interdimux-hide pattern '$_hp' matches a session"
      elif [ "$_hit_cur" = 1 ]; then
        # The current session is NEVER hidden — the row marker, the popup title
        # and MRU's move-to-end all key off it — so a pattern whose only match is
        # the session you are standing in does nothing at all, and "matches a
        # session" would be a true sentence about a filter that is not running.
        _warn "@interdimux-hide pattern '$_hp' matches only the session you are in"
        _note "the current session is never hidden, so this pattern is doing nothing here"
      else
        _warn "@interdimux-hide pattern '$_hp' matches no session right now"
        _note "harmless if that session is not running; a typo looks exactly the same"
      fi
    done
    set +f
  fi

  # --- agents -----------------------------------------------------------------
  # Which of the signals a coding agent sends reach tmux, and the one setting
  # that fixes a missing one: until now the way to find out was to miss an
  # approval prompt (review AGENT-14).  Read off the installed binaries (Claude
  # Code 2.1.280-282, Codex 0.155) and reproduced on a private tmux 3.7b:
  #
  #   * a title (OSC 0/2) lands in #{pane_title} unless allow-set-title is off;
  #   * a bare BEL sets #{window_bell_flag}, the row's '!', unless monitor-bell
  #     is off.  bell-action none does not stop the flag (measured), only the
  #     bell tmux would pass on to the terminal;
  #   * a desktop notification (OSC 9/99/777) is wrapped in tmux's DCS
  #     passthrough, which no format sees.  Under allow-passthrough `on` it is
  #     forwarded only for a pane on screen, so a background agent's alert --
  #     the one that matters -- is dropped; under `off` every one is.
  #
  # Advisory, all of it: nothing here stops the picker working, so nothing here
  # is a ✗ or moves the exit status, which a health check reads as "interdimux
  # is broken".  An agent that is not installed is one dim line.  A config that
  # cannot be read, or holds a value this does not know, is "unknown", never
  # wrong: agent configs drift between versions, and drift is not the user's
  # mistake.  Read-only: no agent is started, and the only files opened are the
  # title rules, settings.json, config.toml and sessions/<digits>.json, each by
  # name -- never a credential (~/.codex/auth.json, ~/.claude/.credentials*,
  # the sessions/<pid>.<hash>.key files).
  _sec agents
  # A path with ~ for $HOME, in REPLY: they are long, and the notes quote them.
  _tl() {
    if [ -n "$HOME" ] && [ "$HOME" != / ] && [[ "$1" == "$HOME"/* ]]; then REPLY="~${1#"$HOME"}"
    else REPLY="$1"
    fi
  }
  # "1 pane", "2 panes", in REPLY.
  _nof() { if [ "$1" = 1 ]; then REPLY="1 $2"; else REPLY="$1 ${2}s"; fi; }

  # One round-trip for every tmux option below, as it applies to this pane (a
  # pane, window or session override counts, as it would for an agent here).
  # Flags come back 1/0, allow-passthrough as off/on/all.  default-terminal is
  # the TERM a pane starts with, which is what an agent picks its alerts by.
  _ag=$(tmux display-message -p ${TMUX_PANE:+-t "$TMUX_PANE"} \
          '#{allow-set-title}|#{monitor-bell}|#{bell-action}|#{allow-passthrough}|#{focus-events}|#{default-terminal}' 2>/dev/null)
  IFS='|' read -r _ag_title _ag_mbell _ag_bact _ag_pass _ag_focus _ag_term <<< "$_ag"
  case "$_ag_title" in
    1) _ok "tmux takes the titles programs set (allow-set-title on): what an agent says it is doing" ;;
    0) _warn "allow-set-title is off — the titles agents set (what they are working on) never reach tmux"
       _note "set -g allow-set-title on" ;;
    *) _note "allow-set-title could not be read — unknown" ;;
  esac
  case "$_ag_mbell" in
    1) _ok "a bell flags its window with ! (monitor-bell on): the one alert any agent can hand tmux"
       [ "$_ag_bact" = none ] \
         && _note "bell-action is none: the ! still appears, but tmux passes no bell on to your terminal" ;;
    0) _warn "monitor-bell is off — an agent's bell never flags its window, so no row shows it waits on you"
       _note "setw -g monitor-bell on" ;;
    *) _note "monitor-bell could not be read — unknown" ;;
  esac

  # Your title rules, read before the built-in ones.  A line that is not a rule
  # is skipped by both renderers without a word, so say which: rule_fields is
  # their own split.  The text is what title_ruleset reads -- up to a NUL, if
  # the file holds one (UTF-16) -- and a line that is not UTF-8 is one it
  # drops (review R02).
  _trf="${TITLE_RULES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/interdimux/titles}"
  _tl "$_trf"; _trf_d="$REPLY"
  if [ -f "$_trf" ] && [ -r "$_trf" ]; then
    _nr=0 _ln=0 _trn=() _re_skip='^ *(#|$)' _trt="" _trnul=0
    { IFS= read -r -d '' _trt < "$_trf"; } 2>/dev/null && _trnul=1
    [ "$_trnul" = 1 ] && _trn+=("it holds a NUL byte (is it UTF-16?): nothing after the first one is read")
    while IFS= read -r _l || [ -n "$_l" ]; do
      _ln=$((_ln + 1))
      _l="${_l//[$'\t\r']/ }"
      [[ "$_l" =~ $_re_skip ]] && continue
      if ! is_utf8 "$_l"; then
        _trn+=("line $_ln is not UTF-8, so it is skipped: save the file as UTF-8")
        continue
      fi
      if ! rule_fields "$_l"; then
        _trn+=("line $_ln is not a rule (APPS STATE DESC PATTERN), so it is skipped")
        continue
      fi
      _nr=$((_nr + 1))
      case "$RULE_S" in
        -|approve|input|working|idle|done|error) ;;
        *) _trn+=("line $_ln: its STATE is not one of approve input working idle done error, or -, so the rule gives none") ;;
      esac
      [[ "$RULE_A" == @* ]] || continue
      # The names an option rule reads go into the list's tmux query, so one
      # that is not a plain option name is left out of it: never read.
      _tro=()
      IFS=, read -r -a _tro <<< "$RULE_A"
      for _o in ${_tro[@]+"${_tro[@]}"}; do
        _o="${_o#@}"
        case "$_o" in
          *[!A-Za-z0-9_-]*) _trn+=("line $_ln: @$_o is not an option name tmux can be asked for, so it is never read"); break ;;
        esac
      done
    done 2>/dev/null <<< "$_trt"
    _nof "$_nr" rule
    _ok "your title rules: $_trf_d holds $REPLY, read before the built-in ones"
    for (( _i = 0; _i < ${#_trn[@]} && _i < 5; _i++ )); do _note "${_trn[_i]}"; done
    [ "${#_trn[@]}" -gt 5 ] && _note "… and $(( ${#_trn[@]} - 5 )) more"
  elif [ -e "$_trf" ]; then
    _warn "your title rules at $_trf_d cannot be read — only the built-in ones apply"
  elif [ -n "$TITLE_RULES_FILE" ]; then
    _warn "@interdimux-title-rules names $_trf_d, which does not exist — only the built-in rules apply"
  else
    _note "title rules: none of your own ($_trf_d) — the built-in ones apply"
  fi

  # What agent plugins, or your own hooks, publish as pane options: the names
  # the list reads in its one list-panes (the built-in rules' and any your file
  # adds), each asked only whether it is set -- no value is shown.  The same
  # query gives every pane's pid, which Claude's registry is checked against
  # below.  A pane in two sessions is counted once.
  title_ruleset
  _pon=() _pfmt='#{pane_id} #{pane_pid} '
  for _o in $STATE_OPTS; do _pon+=("$_o"); _pfmt+="#{!=:#{@$_o},}"; done
  declare -A _ppid=() _pwho_n=() _pwho_o=()
  _pwho=() _npub=0
  _ag_who() {
    case "$1" in
      agent_state|agent_desc)                  REPLY='your hooks' ;;
      pane_status|pane_wait_reason)            REPLY=tmux-agent-sidebar ;;
      claude_state|codex_state|opencode_state) REPLY=tmux-agent-icons ;;
      claude_pane_status)                      REPLY=tmux-claude-status ;;
      workmux_pane_status)                     REPLY=workmux ;;
      dmux_attention)                          REPLY=dmux ;;
      *)                                       REPLY='your title rules' ;;
    esac
  }
  while IFS=' ' read -r _pid _ppd _bits; do
    [ -n "$_pid" ] && [ -z "${_ppid[$_pid]+x}" ] || continue
    _ppid[$_pid]="$_ppd"
    [[ "$_bits" == *1* ]] || continue
    _npub=$((_npub + 1))
    declare -A _pw=()
    for (( _i = 0; _i < ${#_pon[@]}; _i++ )); do
      [ "${_bits:_i:1}" = 1 ] || continue
      _ag_who "${_pon[_i]}"
      if [ -z "${_pwho_n[$REPLY]+x}" ]; then _pwho+=("$REPLY"); _pwho_n[$REPLY]=0; _pwho_o[$REPLY]=""; fi
      [[ " ${_pwho_o[$REPLY]} " == *" @${_pon[_i]} "* ]] || _pwho_o[$REPLY]+="${_pwho_o[$REPLY]:+ }@${_pon[_i]}"
      if [ -z "${_pw[$REPLY]+x}" ]; then
        _pw[$REPLY]=1 _n="${_pwho_n[$REPLY]}"
        _pwho_n[$REPLY]=$(( _n + 1 ))
      fi
    done
    unset _pw
  done <<< "$(tmux list-panes -a -F "$_pfmt" 2>/dev/null)"
  if [ "$_npub" -gt 0 ]; then
    _nof "$_npub" pane
    _ok "agent state is published on $REPLY, as options the list reads"
    for _w in ${_pwho[@]+"${_pwho[@]}"}; do
      _nof "${_pwho_n[$_w]}" pane; _o="${_pwho_o[$_w]// /, }"
      case "$_w" in
        'your hooks')       _note "your hooks publish $_o on $REPLY" ;;
        'your title rules') _note "$_o, which your title rules read, is set on $REPLY" ;;
        *)                  _note "$_w publishes $_o on $REPLY" ;;
      esac
    done
    [ "$AGENT_STATE" = on ] \
      || _note "@interdimux-agent-state is off, so no row shows any of it as a state"
  else
    _note "plugin options: no pane publishes an agent's state (@agent_state, @pane_status, …) right now"
  fi

  # An agent's alerts sent as an OSC wrapped for passthrough: where they end up.
  # $1 the agent, $2 the terminal they are meant for, $3 how they come to be
  # sent that way (a note), $4 the setting that makes them a bell instead.
  _ag_passthrough() {
    if [ "$_ag_pass" = all ]; then
      _ok "$1's notifications reach $2 from every pane (allow-passthrough all), but tmux never sees them"
      _note "$3"
      _note "no row gets a ! for them; $4 would give it one"
    else
      _warn "$1's notifications go to $2 through tmux passthrough — tmux never sees them"
      _note "$3"
      case "$_ag_pass" in
        on)  _note "allow-passthrough is on: only a pane on screen gets through — a background agent's alert is dropped" ;;
        off) _note "allow-passthrough is off: tmux drops every one of them" ;;
        *)   _note "allow-passthrough could not be read — whether any get through is unknown" ;;
      esac
      _note "to have tmux flag the window instead: $4"
      _note "or: set -g allow-passthrough all — but then any hidden pane can write to your terminal"
    fi
  }

  # Claude Code, in the directory the list reads it from: @interdimux-claude-dir,
  # else $CLAUDE_CONFIG_DIR as the tmux server has it (the environment popups
  # and new panes start from), else ~/.claude.
  _cdir="$CLAUDE_DIR"
  if [ -z "$_cdir" ]; then
    _cdir="$HOME/.claude"
    _srv_env CLAUDE_CONFIG_DIR && [ -n "$REPLY" ] && _cdir="$REPLY"
  fi
  _tl "$_cdir"; _cdir_d="$REPLY"
  # A CLAUDE_CONFIG_DIR that only this shell has is one the popups never see.
  _ccfg_note=""
  if [ -z "$CLAUDE_DIR" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "${CLAUDE_CONFIG_DIR%/}" != "${_cdir%/}" ]; then
    _tl "$CLAUDE_CONFIG_DIR"
    _ccfg_note="this shell's CLAUDE_CONFIG_DIR is $REPLY, which the popups do not see: set -g @interdimux-claude-dir '$REPLY'"
  fi
  _tl "$_cdir/settings.json"; _cset_d="$REPLY"
  _tl "$_cdir/sessions"; _csd_d="$REPLY"
  if [ ! -d "$_cdir" ]; then
    _note "Claude Code: no $_cdir_d — skipped"
    [ -z "$_ccfg_note" ] || _note "$_ccfg_note"
  else
    # settings.json (the user's), read whole without a fork and only ever
    # matched against the few keys below: JSON is not parsed, and no value but
    # those is shown.  Absent is fine (every key at its default); present but
    # unreadable, or not a JSON object, is unknown.
    _cset="$_cdir/settings.json" _cs="" _cs_ok=1
    if [ -e "$_cset" ]; then
      _cs_ok=0
      if [ -f "$_cset" ] && [ -r "$_cset" ]; then
        { IFS= read -r -d '' _cs; } 2>/dev/null < "$_cset"
        [[ "$_cs" =~ ^[[:space:]]*\{ ]] && _cs_ok=1
      fi
    fi

    # CLAUDE_CODE_DISABLE_TERMINAL_TITLE, where Claude gets it: the environment
    # its pane starts with (tmux's), or settings.json's "env".  A boolean to
    # Claude (1, true, yes or on, any case; so "0" is off), and it stops every
    # title write AND the request that names the session.
    _truthy() {
      local v="${1,,}"
      v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
      case "$v" in 1|true|yes|on) return 0 ;; esac
      return 1
    }
    _re='"CLAUDE_CODE_DISABLE_TERMINAL_TITLE"[[:space:]]*:[[:space:]]*"?([^",}]*)'
    if _srv_env CLAUDE_CODE_DISABLE_TERMINAL_TITLE && _truthy "$REPLY"; then
      _warn "CLAUDE_CODE_DISABLE_TERMINAL_TITLE is set in tmux's environment — Claude sets no title, and names no session"
      if [ "${_senv_sc[CLAUDE_CODE_DISABLE_TERMINAL_TITLE]:-g}" = s ]; then
        _note "tmux set-environment -u CLAUDE_CODE_DISABLE_TERMINAL_TITLE, and drop it where it is exported"
      else
        _note "tmux set-environment -gu CLAUDE_CODE_DISABLE_TERMINAL_TITLE, and drop it where it is exported"
      fi
      _note "the list strips Claude's ✳ itself: the title is worth keeping"
    elif [ "$_cs_ok" = 1 ] && [[ "$_cs" =~ $_re ]] && _truthy "${BASH_REMATCH[1]}"; then
      _warn "CLAUDE_CODE_DISABLE_TERMINAL_TITLE is set in $_cset_d — Claude sets no title, and names no session"
      _note "remove it from that file's \"env\"; the list strips Claude's ✳ itself"
    fi

    # The session registry, the list's first source of Claude's state: one
    # sessions/<pid>.json per live interactive session.  Only <digits>.json is
    # opened -- the <pid>.<hash>.key files beside them are secrets.  A record
    # "parses" when it has what the list reads: a whole object, a pid and a
    # status.  Which of them the list believes (the process is still that one,
    # and it runs in a pane here) is claude_registry_r's own answer.
    _csd="$_cdir/sessions"
    if [ -d "$_csd" ] && ! { [ -r "$_csd" ] && [ -x "$_csd" ]; }; then
      # A glob over it would come back empty, i.e. "no session is running".
      _note "Claude Code: its session registry at $_csd_d could not be read — unknown"
    elif [ -d "$_csd" ]; then
      _nrec=0 _nodd=0 _nunr=0
      for _f in "$_csd"/*.json; do
        [[ "${_f##*/}" =~ ^[0-9]+\.json$ ]] || continue
        if ! { [ -f "$_f" ] && [ -r "$_f" ]; }; then _nunr=$((_nunr + 1)); continue; fi
        _j=""
        { IFS= read -r -N 65536 _j; } 2>/dev/null < "$_f"   # as claude_registry_r
        if [[ "$_j" == *'}' && "$_j" =~ \"pid\":[0-9]+ && "$_j" =~ \"status\":\"[a-z]+\" ]]; then
          _nrec=$((_nrec + 1))
        else
          _nodd=$((_nodd + 1))
        fi
      done
      if [ $(( _nrec + _nodd + _nunr )) = 0 ]; then
        _ok "Claude's session registry is at $_csd_d — no session is running now"
      elif [ "$_nrec" = 1 ]; then
        _ok "Claude's session registry is at $_csd_d — 1 record parses"
      else
        _ok "Claude's session registry is at $_csd_d — $_nrec records parse"
      fi
      if [ "$AGENT_STATE" != on ]; then
        _note "@interdimux-agent-state is off, so the list does not read it"
      elif [ "$_nrec" -gt 0 ]; then
        _nshow=0
        CLAUDE_DIR="$_cdir" claude_registry_r
        while IFS="$US" read -r _rp _rsid _ _; do
          [ -n "$_rp" ] && [ -n "${_ppid[$_rp]+x}" ] || continue
          [ -z "$_rsid" ] || [ "$_rsid" = "${_ppid[$_rp]}" ] || continue
          _nshow=$((_nshow + 1))
        done <<< "$CLAUDE_REG"
        case "$_nshow:$_nrec" in
          0:1) _note "it is not a live session in a pane of this tmux server" ;;
          0:*) _note "none of them is a live session in a pane of this tmux server" ;;
          1:*) _note "1 is a live session in a pane here, whose row shows Claude's state" ;;
          *)   _note "$_nshow are live sessions in panes here, whose rows show Claude's state" ;;
        esac
      fi
      case "$_nodd" in
        0) ;;
        1) _note "1 record there lacks what the list reads (a pid, a status) — unknown: the format may have changed" ;;
        *) _note "$_nodd records there lack what the list reads (a pid, a status) — unknown: the format may have changed" ;;
      esac
      case "$_nunr" in
        0) ;;
        1) _note "1 record there could not be read — unknown" ;;
        *) _note "$_nunr records there could not be read — unknown" ;;
      esac
    else
      _note "Claude Code: no session registry at $_csd_d — an older Claude writes none, and its rows then show no state"
    fi
    [ -z "$_ccfg_note" ] || _note "$_ccfg_note"

    # Where Claude's alerts go: preferredNotifChannel, default auto (a project's
    # settings, or a value an older Claude kept in ~/.claude.json, can
    # override it; neither is read here).  auto picks by TERM, which in a pane
    # is tmux's default-terminal: ghostty for xterm-ghostty, kitty for a *kitty*
    # one, and NOTHING for any other (TERM_PROGRAM is tmux's there, which names
    # no channel).  Every channel but the bell is an OSC wrapped for
    # passthrough.  The values are the installed binaries' own list.
    if [ "$_cs_ok" = 0 ]; then
      _note "Claude Code: $_cset_d could not be read — where its notifications go is unknown"
    else
      _cnc="" _re='"preferredNotifChannel"[[:space:]]*:[[:space:]]*"([^"]*)"'
      if [[ "$_cs" =~ $_re ]]; then _cnc="${BASH_REMATCH[1]}"
      elif [[ "$_cs" == *'"preferredNotifChannel"'* ]]; then _cnc='?'
      fi
      _cnc_how="preferredNotifChannel is \"$_cnc\""
      [ -n "$_cnc" ] || _cnc_how="preferredNotifChannel is not set (auto)"
      _cbell="\"preferredNotifChannel\": \"terminal_bell\" in $_cset_d"
      _via="" _osc=""
      case "${_cnc:-auto}" in
        auto)
          case "$_ag_term" in
            xterm-ghostty) _via=Ghostty _osc='OSC 777' ;;
            *kitty*)       _via=kitty   _osc='OSC 99' ;;
            '') _note "Claude Code: the panes' TERM (default-terminal) could not be read — where its notifications go is unknown" ;;
            *)  _warn "Claude sends no notifications here at all"
                _note "$_cnc_how, and auto has no channel for the panes' TERM, $_ag_term"
                _note "to have it ring the bell, which tmux flags: $_cbell" ;;
          esac ;;
        ghostty) _via=Ghostty _osc='OSC 777' ;;
        kitty)   _via=kitty   _osc='OSC 99' ;;
        iterm2)  _via=iTerm2  _osc='OSC 9' ;;
        terminal_bell|iterm2_with_bell)
          _ok "Claude rings the bell when it needs you ($_cnc_how) — tmux flags its window" ;;
        notifications_disabled)
          _note "Claude Code: its notifications are turned off ($_cnc_how)" ;;
        *) _note "Claude Code: preferredNotifChannel in $_cset_d holds a value this check does not know — unknown" ;;
      esac
      if [ -n "$_via" ]; then
        if [ -z "$_cnc" ]; then
          _ag_passthrough Claude "$_via" "$_cnc_how and the panes' TERM is $_ag_term, so Claude sends $_osc wrapped for passthrough" "$_cbell"
        else
          _ag_passthrough Claude "$_via" "$_cnc_how, so Claude sends $_osc wrapped for passthrough" "$_cbell"
        fi
      fi
      [[ "$_cs" =~ \"hooks\"[[:space:]]*: ]] \
        && _note "$_cset_d defines hooks (not inspected here), which may deliver alerts of their own"
    fi
  fi

  # Codex.  Only config.toml, and only three keys of [tui] (a dotted `tui.key =`
  # at the top level counts too): never auth.json.  Names and defaults are
  # codex-rs config/src/types.rs (0.155): notifications (true), notification_
  # method (auto), notification_condition (unfocused).  "unfocused" is why it
  # is silent in tmux: Codex starts out believing it has focus, and without
  # focus-events tmux never tells it otherwise (reproduced).
  _xdir="$HOME/.codex"
  _srv_env CODEX_HOME && [ -n "$REPLY" ] && _xdir="$REPLY"
  _tl "$_xdir"; _xdir_d="$REPLY"
  _tl "$_xdir/config.toml"; _xcfg_d="$REPLY"
  if [ ! -d "$_xdir" ]; then
    _note "Codex: no $_xdir_d — skipped"
  else
    _xcfg="$_xdir/config.toml" _xcond="" _xmeth="" _xnotif="" _x_ok=1
    if [ -e "$_xcfg" ]; then
      _x_ok=0
      if [ -f "$_xcfg" ] && [ -r "$_xcfg" ]; then
        _x_ok=1 _xsec=""
        _re='^(tui\.)?(notification_condition|notification_method|notifications)[[:space:]]*=[[:space:]]*(.*)$'
        while IFS= read -r _l || [ -n "$_l" ]; do
          _l="${_l#"${_l%%[![:space:]]*}"}"
          case "$_l" in
            '['*) _xsec="${_l#[}"; _xsec="${_xsec%%]*}"; _xsec="${_xsec//[[:space:]]/}"; continue ;;
          esac
          [[ "$_l" =~ $_re ]] || continue
          if [ -n "${BASH_REMATCH[1]}" ]; then [ -z "$_xsec" ] || continue
          else [ "$_xsec" = tui ] || continue
          fi
          _v="${BASH_REMATCH[3]%%#*}"; _v="${_v%"${_v##*[![:space:]]}"}"
          _v="${_v#[\"\']}"; _v="${_v%[\"\']}"
          case "${BASH_REMATCH[2]}" in
            notification_condition) _xcond="$_v" ;;
            notification_method)    _xmeth="$_v" ;;
            notifications)          _xnotif="$_v" ;;
          esac
        done 2>/dev/null < "$_xcfg"
      fi
    fi
    # When it notifies at all: $_xwhy says why, empty for never or unknown.
    _xwhy=""
    if [ "$_x_ok" = 0 ]; then
      _note "Codex: $_xcfg_d could not be read — whether it notifies is unknown"
    elif [ "$_xnotif" = false ]; then
      _note "Codex: its notifications are turned off ([tui] notifications = false)"
    elif [ "$_xcond" = always ]; then
      _xwhy='notification_condition "always"'
    elif [ -n "$_xcond" ] && [ "$_xcond" != unfocused ]; then
      _note "Codex: notification_condition in $_xcfg_d holds a value this check does not know — unknown"
    elif [ "$_ag_focus" = 1 ]; then
      _xwhy='focus-events on'
    elif [ "$_ag_focus" = 0 ]; then
      _warn "Codex never notifies inside tmux — focus-events is off, so it never hears that its pane lost focus"
      _note "it notifies only when unfocused (notification_condition, default \"unfocused\")"
      _note "set -g focus-events on — or in $_xcfg_d, under [tui]: notification_condition = \"always\""
    else
      _note "Codex: focus-events could not be read — whether it notifies is unknown"
    fi
    # How: a bell reaches tmux; OSC 9 is wrapped for passthrough, like Claude's.
    # auto picks OSC 9 for Ghostty, iTerm2, kitty, Warp and WezTerm, found as
    # codex-rs terminal-detection finds them under tmux (whose TERM_PROGRAM it
    # skips): these variables in the pane's environment first, then TERM.
    if [ -n "$_xwhy" ]; then
      _xterm=""
      case "${_xmeth:-auto}" in
        bel) ;;
        osc9) _xterm="your terminal" ;;
        auto)
          if _srv_env GHOSTTY_RESOURCES_DIR && [ -n "$REPLY" ]; then _xterm=Ghostty
          elif _srv_env WEZTERM_VERSION; then _xterm=WezTerm
          elif _srv_env ITERM_SESSION_ID || _srv_env ITERM_PROFILE || _srv_env ITERM_PROFILE_NAME; then _xterm=iTerm2
          elif _srv_env TERM_SESSION_ID; then :                     # Apple Terminal: a bell
          elif _srv_env KITTY_WINDOW_ID || [[ "$_ag_term" == *kitty* ]]; then _xterm=kitty
          elif _srv_env ALACRITTY_SOCKET || [ "$_ag_term" = alacritty ] || _srv_env KONSOLE_VERSION \
               || _srv_env GNOME_TERMINAL_SCREEN || _srv_env VTE_VERSION || _srv_env WT_SESSION; then :
          else
            case "$_ag_term" in
              xterm-ghostty)      _xterm=Ghostty ;;
              wezterm|wezterm-mux) _xterm=WezTerm ;;
            esac
          fi ;;
        *) _xterm='?' ;;
      esac
      if [ "$_xterm" = '?' ]; then
        _note "Codex: notification_method in $_xcfg_d holds a value this check does not know — unknown"
      elif [ -z "$_xterm" ]; then
        _ok "Codex rings the bell when it needs you ($_xwhy) — tmux flags its window"
      else
        _xmhow="notification_method is \"$_xmeth\""
        [ -n "$_xmeth" ] || _xmhow="notification_method is not set (auto)"
        _ag_passthrough Codex "$_xterm" "$_xmhow, so Codex sends OSC 9 wrapped for passthrough" \
          "notification_method = \"bel\" under [tui] in $_xcfg_d"
      fi
    fi
  fi

  # Stop diverting before anything is printed, and report what was caught.
  if [ -n "$_derr" ]; then
    exec 2>&3 3>&-
    if [ -s "$_derr" ]; then
      # A warning, not a failure: this catches BOTH a bug in a check here and a
      # legitimate complaint from something a check ran — fzf grumbling about the
      # user's own $FZF_DEFAULT_OPTS_FILE arrives on exactly this channel — and
      # from here the two are indistinguishable.  Either way it belongs in the
      # report rather than above its title.
      _sec 'stderr'
      _warn "something the checks ran wrote to stderr"
      _note "either a bug in --doctor, or a real complaint from a tool it called:"
      while IFS= read -r _el; do [ -n "$_el" ] && _note "$_el"; done < "$_derr"
    fi
    # The trap is only for a run cut short: left set, it would exec a second rm
    # at exit for a file that is already gone.
    rm -f "$_derr"; trap - EXIT
  fi

  # --- the report -------------------------------------------------------------
  # Title, then the verdict, then the detail.  The verdict is a sentence rather
  # than three counts: "everything is fine" and "two things need attention" are
  # what you want to know, and the counts are right there beside it.
  _verdict='' _vcol='32'
  if [ "$_n_bad" -gt 0 ]; then
    _vcol='31'
    [ "$_n_bad" = 1 ] && _verdict='1 problem needs attention' \
                      || _verdict="$_n_bad problems need attention"
  elif [ "$_n_warn" -gt 0 ]; then
    _vcol='33'
    [ "$_n_warn" = 1 ] && _verdict='1 thing could be better' \
                       || _verdict="$_n_warn things could be better"
  else
    _verdict='everything checks out'
  fi
  # ASCII separators: the counts are measured with ${#_counts} to right-align
  # them, and ${#} counts BYTES in a non-UTF-8 locale — a '·' there is two, so
  # the title came up short by one cell per separator on exactly the setups the
  # locale check above is warning about.
  _counts="${_n_ok} ok"
  [ "$_n_warn" -gt 0 ] && _counts+=", ${_n_warn} warn"
  [ "$_n_bad" -gt 0 ]  && _counts+=", ${_n_bad} problem"
  [ "$_n_bad" -gt 1 ]  && _counts+="s"

  _rule "$_doc_w"; _hr="$REPLY"
  # Right-align the counts against the title, when there is room for it.
  _title='interdimux doctor'
  _pad=$(( _doc_w - ${#_title} - ${#_counts} ))
  if [ "$_pad" -ge 1 ]; then
    printf -v _gap '%*s' "$_pad" ''
    printf '\033[1m%s\033[0m%s\033[2m%s\033[0m\n' "$_title" "$_gap" "$_counts"
  else
    # Too narrow for both.  Drop the counts rather than run past the edge and be
    # ellipsized: the verdict on the very next line says the same thing in words,
    # so nothing is actually lost.
    printf '\033[1m%s\033[0m\n' "$_title"
  fi
  printf '\033[2m%s\033[0m\n' "$_hr"
  printf '\033[%sm%s\033[0m\n' "$_vcol" "$_verdict"
  printf '%s' "$_doc"
  printf '\033[2m%s\033[0m\n' "$_hr"
  # "then h" would be a lie on a short client: below MENU_ROWS the dashboard is
  # the fzf fallback, where letters filter rather than select.  Name the entry.
  printf '\033[2mrun again from the dashboard: prefix + %s, then Health\033[0m\n' "${_dk:-g}"

  [ "$_doc_fail" = 1 ] && exit 1
  exit 0
fi
