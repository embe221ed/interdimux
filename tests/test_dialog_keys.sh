#!/usr/bin/env bash
#
# The keys of the dialogs' text field: Rename, Send keys and Schedule.
#
# What used to go wrong, all reproduced on tmux 3.7b:
#   * a key that starts with ESC but is not a CSI or SS3 sequence cancelled
#     the dialog and threw away everything typed (BUG-50) -- Alt-b and Alt-f
#     among them, which Ghostty sends for Option+Left and Option+Right.
#   * after ESC [ the editor read one byte (two after a digit), so Ctrl-Left,
#     ESC [ 1 ; 5 D, went home and typed "5D"; F5 typed "~", Shift-Right
#     "2C"; and Enter applied the junk (BUG-49).
#
# The editor's oracle is what a pane READ: the Send dialog targets a pane
# running `cat >> FILE`, so FILE holds every buffer exactly as it was applied.
# The keys go in two ways: as bytes in a file (INTERDIMUX_TTY_IN), which
# covers every spelling quickly; and through a real pane with send-keys, the
# way a terminal delivers them -- with the 50 ms that tells a lone ESC from
# the start of a key in play.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-dlgkeys-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-dlgkeys.XXXXXX")"
TMPD="$(cd "$TMPD" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""
SOCKPATH=""

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  # tmux 3.7 leaves the socket file behind after kill-server
  [ -n "$SOCKPATH" ] && rm -f "$SOCKPATH"
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

# expect NAME GOT WANT -- exact comparison, both sides shown on failure
expect() {
  if [ "$2" = "$3" ]; then
    report "$1" pass
  else
    report "$1" fail
    ERRORS+="    want: $(printf '%s' "$3" | cat -A | tr '\n' '|')"$'\n'
    ERRORS+="    got : $(printf '%s' "$2" | cat -A | tr '\n' '|')"$'\n'
  fi
}

# check NAME DETAIL STATUS
check() {
  if [ "$3" = 0 ]; then report "$1" pass; else report "$1" fail; ERRORS+="      $2"$'\n'; fi
}

# poll SECS CMD... -- until CMD succeeds, or SECS have passed
poll() {
  local secs=$1 i
  shift
  for (( i = 0; i < secs * 20; i++ )); do
    "$@" && return 0
    sleep 0.05
  done
  return 1
}

T() { tmux -L "$SOCK" "$@"; }

echo "interdimux dialog-key tests"
echo

# Wide characters below are sliced by the dialog one CHARACTER at a time.
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

# Exported BEFORE the server starts: the dialogs run in its panes, which get
# its global environment -- and their state files must not be the user's.
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export XDG_CONFIG_HOME="$TMPD/config" XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
CAUGHT="$TMPD/caught"
SHELL=/bin/sh T -f /dev/null new-session -d -s host -x 120 -y 30 -c "$TMPD" "exec cat >> '$CAUGHT'"
T set -g default-shell /bin/sh
T set -g default-command 'bash --norc --noprofile -i'
T new-session -d -s 'alpha beta' -x 80 -y 20 'sleep 900'
T new-session -d -s keep -x 80 -y 20 'sleep 900'
SOCKPATH="$(T display-message -p '#{socket_path}')"
export TMUX="$SOCKPATH,99999,0"
export TMUX_PANE="$(T list-panes -t '=host:' -F '#{pane_id}' | head -1)"

# PATH shims for the script under test, never for this harness.
#   sleep: with SLEEP_SKIP, the dialogs' own pauses cost nothing.
SHIM="$TMPD/shim"
REAL_SLEEP="$(command -v sleep)"
mkdir -p "$SHIM"
cat > "$SHIM/sleep" <<SHIMEOF
#!/bin/sh
[ -n "\${SLEEP_SKIP:-}" ] && exit 0
exec "$REAL_SLEEP" "\$@"
SHIMEOF
chmod +x "$SHIM"/*

# The program a dialog's pane runs: the command, then OUT.done.
cat > "$TMPD/wrap.sh" <<'WRAPEOF'
out=$1; shift
"$@"
: > "$out.done"
exec sleep 60
WRAPEOF

nlines() { local n=0; [ -f "$1" ] && n=$(wc -l < "$1"); echo $((n)); }

# next_line FILE N -- wait for FILE to hold N lines, print line N
next_line() {
  local i
  for (( i = 0; i < 200; i++ )); do
    if [ "$(nlines "$1")" -ge "$2" ]; then sed -n "${2}p" "$1"; return 0; fi
    sleep 0.05
  done
  echo "<nothing arrived>"
}

# ---------------------------------------------------------------------------
# 1. Every spelling, from a file
# ---------------------------------------------------------------------------

# run_send INPUT -- the Send dialog on the catcher pane, given INPUT (printf %b)
run_send() {
  printf '%b' "$1" > "$TMPD/in"
  : > "$TMPD/out"
  INTERDIMUX_TTY_IN="$TMPD/in" INTERDIMUX_TTY_OUT="$TMPD/out" SLEEP_SKIP=1 PATH="$SHIM:$PATH" \
    timeout 20 bash "$SCRIPT" --action send 'P:host:0:0' >/dev/null 2>&1
}

# keycase NAME INPUT WANT -- what the pane read once the dialog was given INPUT
keycase() {
  local n=$(( $(nlines "$CAUGHT") + 1 ))
  run_send "$2"
  expect "$1" "$(next_line "$CAUGHT" "$n")" "$3"
}

# cancels NAME INPUT -- the dialog given INPUT sends nothing: the next line the
# pane reads is the one a later dialog sends
_nc=0
cancels() {
  local n=$(( $(nlines "$CAUGHT") + 1 ))
  _nc=$((_nc + 1))
  run_send "$2"
  run_send "after $_nc\n"
  expect "$1" "$(next_line "$CAUGHT" "$n")" "after $_nc"
}

keycase "control: plain text is sent as typed"             'one two\n'           'one two'

# readline's Alt keys.  A word is a run of letters and digits.
keycase "Alt-b (ESC b) moves back a word, not cancels"      'one two\ebX\n'       'one Xtwo'
keycase "Alt-b stops at punctuation, as readline's does"    'git-log --all\eb\ebX\n' 'git-Xlog --all'
keycase "Alt-B moves back a word too"                        'one two\eBX\n'       'one Xtwo'
keycase "Alt-f (ESC f) moves on to the end of a word"       'one two\001\efX\n'   'oneX two'
keycase "Alt-f twice crosses the blank to the next word"     'one two\001\ef\efX\n' 'one twoX'
keycase "Alt-d deletes to the end of the word"               'one two\001\edX\n'   'X two'
keycase "Alt-d between words deletes the next one"           'one two\001\ef\edX\n' 'oneX'
keycase "Alt-Backspace (ESC DEL) deletes the word before"   'one two\e\177X\n'    'one X'
keycase "Alt-Backspace as ESC ^H deletes it too"             'one two\e\010X\n'    'one X'
keycase "Alt-Backspace stops at punctuation"                 'a.b-cd\e\177\n'      'a.b-'
keycase "an unknown Alt key is dropped, both bytes"          'ab\excd\n'           'abcd'
keycase "word keys over wide characters"                     'ab 日本\ebX\n'       'ab X日本'
keycase "Alt-Backspace of a wide word"                       '日本 語\e\177X\n'    '日本 X'
# An accent typed as its own character (NFD, as macOS names files) is part of
# its letter: a word key never stops between the two.
MARK=$'́'
keycase "Alt-f does not stop between a letter and its accent" "cafe${MARK} bar\\001\\efX\\n" "cafe${MARK}X bar"
keycase "Alt-b does not stop between a letter and its accent" "ca${MARK}fe\\ebX\\n"          "Xca${MARK}fe"
keycase "Alt-d takes a word's last accent with it"            "cafe${MARK} bar\\001\\edX\\n" "X bar"

# CSI and SS3, read whole
keycase "Ctrl-Left (ESC [1;5D) moves back a word, types nothing" 'one two\e[1;5DX\n'      'one Xtwo'
keycase "Alt-Left (ESC [1;3D) moves back a word"             'one two\e[1;3DX\n'          'one Xtwo'
keycase "Ctrl-Right (ESC [1;5C) moves on a word"             'one two\001\e[1;5CX\n'      'oneX two'
keycase "Alt-Right (ESC [1;3C) moves on a word"              'one two\001\e[1;3CX\n'      'oneX two'
keycase "Shift-Left (ESC [1;2D) moves one character"         'abc\e[1;2DX\n'              'abXc'
keycase "Shift-Right (ESC [1;2C) moves one character"        'abc\001\e[1;2CX\n'          'aXbc'
keycase "Left (ESC [D)"                                      'ac\e[Db\n'                  'abc'
keycase "Left (ESC O D)"                                     'ac\eODb\n'                  'abc'
keycase "Right (ESC [C)"                                     'ab\001\e[CX\n'              'aXb'
keycase "Right (ESC O C)"                                    'ab\001\eOCX\n'              'aXb'
for _k in '[H' 'OH' '[1~' '[7~' '[1;5H'; do
  keycase "Home (ESC $_k)"                                   "bc\\e${_k}a\\n"             'abc'
done
for _k in '[F' 'OF' '[4~' '[8~' '[1;5F'; do
  keycase "End (ESC $_k)"                                    "ab\\001\\e${_k}c\\n"        'abc'
done
keycase "Delete (ESC [3~)"                                   'aXbc\001\e[C\e[3~\n'        'abc'
for _k in 'F5:[15~' 'F12:[24~' 'F1:OP' 'Up:[A' 'Down:OB' 'Insert:[2~' 'PageUp:[5~' \
          'Shift-Tab:[Z' 'Ctrl-Delete:[3;5~' 'a mouse click:[<0;10;5M'; do
  keycase "${_k%%:*} is dropped whole, none of it typed"      "x\\e${_k#*:}y\\n"          'xy'
done
keycase "a bracketed paste keeps the text, not its markers"  'a\e[200~pasted\e[201~b\n'   'apastedb'

# Cancelling is unchanged: a lone ESC (here: the last byte there is), Esc
# twice, and Esc then Ctrl-C.
cancels "a lone ESC cancels; nothing is sent"                'abc\e'
cancels "Esc twice cancels"                                  'abc\e\ezz\n'
cancels "Esc then Ctrl-C cancels"                            'abc\e\003zz\n'

# ---------------------------------------------------------------------------
# 2. On a real terminal, as Ghostty sends them through tmux
# ---------------------------------------------------------------------------
# Option+Left is ESC b, Option+Right ESC f, Ctrl-Left ESC [1;5D: each sent as
# those exact bytes (send-keys -H).  The others are tmux's own key names.

PANE_OUT=""
# open_rename SESSION OUT -- the Rename dialog for SESSION in a pane of its own,
# under wrap.sh.  Ready once the field shows the name: the editor draws the
# prefilled name only after it has drained the input, so a key sent from then
# on is read, not thrown away.
open_rename() {
  PANE_OUT="$2"
  T kill-session -t '=drv' 2>/dev/null || true
  T new-session -d -s drv -x 80 -y 20 \
    "bash '$TMPD/wrap.sh' '$2' bash '$SCRIPT' --action rename 'S:$1'"
  wait_vis "$1"
}
keys()  { T send-keys -t '=drv:' "$@"; }
typed() { T send-keys -t '=drv:' -l "$1"; }
bytes() { T send-keys -t '=drv:' -H "$@"; }

# VIS: the text in the field, trailing blanks and the border removed
VIS=""
snap() {
  local r
  VIS=""
  while IFS= read -r r; do
    case "$r" in *'❯ '*) VIS="${r#*❯ }"; VIS="${VIS%│}"; VIS="${VIS%"${VIS##*[! ]}"}"; break ;; esac
  done < <(T capture-pane -t '=drv:' -p 2>/dev/null || true)
}
vis_is() { snap; [ "$VIS" = "$1" ]; }
wait_vis() { poll 10 vis_is "$1"; }

RC=0; open_rename 'alpha beta' "$TMPD/r1" || RC=1
check "the rename dialog opens with the name in its field" "field: '$VIS'" "$RC"

bytes 1b 62; typed "X"
RC=0; wait_vis "alpha Xbeta" || RC=1
check "Option+Left (ESC b) moves back a word and the dialog stays open" "field: '$VIS'" "$RC"

keys Home; bytes 1b 66; typed "Y"
RC=0; wait_vis "alphaY Xbeta" || RC=1
check "Option+Right (ESC f) moves on to the end of the word" "field: '$VIS'" "$RC"

bytes 1b 5b 31 3b 35 44; typed "Z"
RC=0; wait_vis "ZalphaY Xbeta" || RC=1
check "Ctrl-Left (ESC [1;5D) moves back a word and types nothing" "field: '$VIS'" "$RC"

keys C-Right; typed "W"
RC=0; wait_vis "ZalphaYW Xbeta" || RC=1
check "Ctrl-Right moves on a word" "field: '$VIS'" "$RC"

keys M-d
RC=0; wait_vis "ZalphaYW" || RC=1
check "Alt-d deletes the next word" "field: '$VIS'" "$RC"

typed " end"; wait_vis "ZalphaYW end" || true
keys M-BSpace; typed "ok"
RC=0; wait_vis "ZalphaYW ok" || RC=1
check "Alt-Backspace deletes the word before the cursor" "field: '$VIS'" "$RC"

keys Enter
RC=0; poll 10 T has-session -t '=ZalphaYW ok' 2>/dev/null || RC=1
check "Enter applies the name edited with those keys" \
      "sessions: $(T list-sessions -F '#{session_name}' | tr '\n' ',')" "$RC"

# A lone Esc is told from the start of a key by the 50 ms after it.
RC=0; open_rename keep "$TMPD/r2" || RC=1
typed "zz"; wait_vis "keepzz" || RC=1
keys Escape
poll 10 test -e "$TMPD/r2.done" || RC=1
T has-session -t '=keep' 2>/dev/null || RC=1
T has-session -t '=keepzz' 2>/dev/null && RC=1
check "a lone Esc still cancels on a real terminal" \
      "sessions: $(T list-sessions -F '#{session_name}' | tr '\n' ',')" "$RC"

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
