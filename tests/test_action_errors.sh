#!/usr/bin/env bash
#
# Action-layer robustness (IDEAS #22, #23).
#
#   #23 tmux's own error message must reach the user.  "duplicate session: two"
#       tells them what to do; "failed to rename" leaves them guessing, and the
#       real reason was being thrown away by 2>/dev/null.
#   #22 a dialog hides the cursor and, in kill mode, turns the popup border red.
#       Ctrl-C used to abandon both, leaving an invisible cursor behind a
#       permanently red frame.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-actionerr-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-actionerr.XXXXXX")"
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

echo "interdimux action-error tests"
echo

tmux -f /dev/null -L "$SOCK" new-session -d -s one -x 100 -y 30
tmux -L "$SOCK" new-session -d -s two -x 100 -y 30
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=one:' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
sleep 1

# Drive the rename dialog: the initial value is pre-filled, so ctrl-u clears it,
# then we type the new name and press Enter.
# The dialogs draw with absolute cursor positioning and write with `>`, so each
# call truncates a plain file and only the last survives.  Render into a REAL
# pane instead and read the screen — which is also what the user actually sees.
run_rename()    { run_rename_on 'one' "$1"; }
run_rename_on() { # $1 = session, $2 = new name -> prints the rendered screen
  local sess="$1" newname="$2" in="$TMPD/in"
  printf '\025%s\n' "$newname" > "$in"     # ^U then the name then Enter
  tmux -L "$SOCK" kill-window -t "=$sess:dlg" 2>/dev/null || true
  local wid
  wid=$(tmux -L "$SOCK" new-window -d -P -F '#{window_id}' -t "=$sess:" -n dlg \
    "env INTERDIMUX_TTY_IN='$in' INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 \
         INTERDIMUX_TMUX_VNUM=307 TMUX_PANE='$TMUX_PANE' \
         bash '$SCRIPT' --action rename \"S:$sess\"; sleep 3" 2>/dev/null) || return 0
  # Poll for the dialog to actually render rather than guessing a duration —
  # under load a fixed sleep samples an empty screen and the assertion fails for
  # the wrong reason.  Capture by WINDOW ID, not session:name: a successful
  # rename changes the session name out from under us mid-flight.
  local i out=""
  for i in $(seq 1 60); do
    out=$(tmux -L "$SOCK" capture-pane -t "$wid" -p 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r' || true)
    printf '%s' "$out" | grep -q '╭' && break
    sleep 0.1
  done
  printf '%s' "$out"
}

# --- #23: the real reason, not a generic failure -------------------------------
out=$(run_rename 'two')
if printf '%s' "$out" | grep -q 'duplicate session'; then
  report "a rejected rename shows tmux's own reason" pass
else
  report "a rejected rename shows tmux's own reason" fail
  ERRORS+="    drew: $(printf '%s' "$out" | tr -s ' ' | tail -c 200)"$'\n'
fi
if printf '%s' "$out" | grep -q 'failed to rename'; then
  report "the generic message is no longer used when tmux explained itself" fail
else
  report "the generic message is no longer used when tmux explained itself" pass
fi
# the session must be unchanged after a rejected rename
if tmux -L "$SOCK" has-session -t '=one' 2>/dev/null; then
  report "a rejected rename leaves the session alone" pass
else
  report "a rejected rename leaves the session alone" fail
fi

# --- a rename that should succeed ----------------------------------------------
out=$(run_rename 'renamed-ok')
if tmux -L "$SOCK" has-session -t '=renamed-ok' 2>/dev/null; then
  report "a valid rename still works" pass
else
  report "a valid rename still works" fail
fi

# --- #22: the cleanup trap exists and restores both --------------------------
if grep -q "trap '_action_cleanup; exit 130' INT TERM" "$SCRIPT"; then
  report "the action handler traps INT/TERM" pass
else
  report "the action handler traps INT/TERM" fail
fi
if grep -q "trap '_action_cleanup' EXIT" "$SCRIPT"; then
  report "the action handler cleans up on every exit path" pass
else
  report "the action handler cleans up on every exit path" fail
fi
# the cleanup must show the cursor again and restore the border
_cleanup_body=$(sed -n '/_action_cleanup() {/,/^  }/p' "$SCRIPT")
printf '%s' "$_cleanup_body" | grep -q '25h' \
  && report "cleanup makes the cursor visible again" pass \
  || report "cleanup makes the cursor visible again" fail
printf '%s' "$_cleanup_body" | grep -q 'popup_accent' \
  && report "cleanup restores the popup border" pass \
  || report "cleanup restores the popup border" fail
printf '%s' "$_cleanup_body" | grep -q 'stty' \
  && report "cleanup restores the terminal mode input_dialog changed" pass \
  || report "cleanup restores the terminal mode input_dialog changed" fail

# --- regressions from the reliability hunt -------------------------------------

# Every action except zoom used to die with "tty_in: unbound variable" on a
# directory row, because the D: early-exit set only tty_out and set -u kills the
# process at the first read of the unbound one.  D: rows are on by default, so
# ctrl-x on one was an instant, silent death.
out=$(timeout 10 bash "$SCRIPT" --action kill 'D:/tmp' 2>&1) || true
if printf '%s' "$out" | grep -q 'unbound variable'; then
  report "an action on a directory row does not die on an unbound variable" fail
else
  report "an action on a directory row does not die on an unbound variable" pass
fi

# The cleanup trap calls popup_accent, which issues `display-popup` with no -E.
# Inside a popup that repaints it; with a client attached and NO popup open tmux
# OPENS one and blocks until a human dismisses it -- so every --action run
# outside a popup hung forever.
timeout 10 bash "$SCRIPT" --action zoom "P:one:0.0" >/dev/null 2>&1
if [ $? -eq 124 ]; then
  report "an action outside a popup does not hang" fail
else
  report "an action outside a popup does not hang" pass
fi

# tmux parses a leading '-' as a flag unless -- separates it.
_dash_ok=1
grep -q 'rename-session -t "$target" -- "$new_name"' "$SCRIPT" || _dash_ok=0
grep -q 'rename-window  -t "$target" -- "$new_name"' "$SCRIPT" || _dash_ok=0
grep -q 'send-keys -t "$t" -- "$send_cmd"' "$SCRIPT" || _dash_ok=0
[ "$_dash_ok" = 1 ] && report "user text is passed after -- so a leading dash is not a flag" pass \
                    || report "user text is passed after -- so a leading dash is not a flag" fail

# A ':' in a session name makes the session permanently unreachable from the
# picker: tmux splits a target at the FIRST ':', so spec_target's "=name:idx"
# resolves against the wrong thing.  tmux itself ACCEPTS such a rename, so the
# dialog has to refuse it.  (Verified: a session named "has:colon" exists but
# `-t '=has:colon:'` resolves to empty.)
# NOTE: an earlier test renames "one" to "renamed-ok", so this needs its own
# session — targeting a session that no longer exists made run_rename return
# empty and the assertion fail for the wrong reason.
tmux -L "$SOCK" new-session -d -s colonsrc -x 100 -y 30
for _i in $(seq 1 50); do tmux -L "$SOCK" has-session -t '=colonsrc' 2>/dev/null && break; sleep 0.1; done
out=$(run_rename_on 'colonsrc' 'no:good')
if printf '%s' "$out" | grep -q "cannot contain"; then
  report "a rename to a name containing ':' is refused with a reason" pass
else
  report "a rename to a name containing ':' is refused with a reason" fail
  ERRORS+="    drew: $(printf '%s' "$out" | tr -s ' ' | tail -c 160)"$'\n'
fi
if tmux -L "$SOCK" has-session -t '=no:good' 2>/dev/null; then
  report "...and no unreachable session was created" fail
else
  report "...and no unreachable session was created" pass
fi

# --- the dialog must stay inside a SHORT popup ------------------------------------
# The box is centred on the terminal size read from the tty, and the status row
# carries pre-coloured text.  Two things went wrong on a small popup, and both
# destroyed the frame rather than merely looking cramped:
#
#   * ${#text} counts the SGR escapes, so a coloured message that "fits" by that
#     measure ran past the right border, wrapped, and overwrote the bottom one.
#     Captured at 52x6 before the fix:
#         │   ✗ a name cannot contain ':' (tmux splits targ
#         ets there)────────────────────────────────────╯
#   * a box taller than the popup clamped DLG_TOP to 1, drew its bottom border
#     past the last row, and scrolled the title off the top.
#
# Needs a REAL tty of the right size: the dialog reads its dimensions with
# `stty size`, which returns nothing for the file the other tests feed in, so a
# file-driven run always renders at the 24x80 fallback and proves nothing.
run_rename_tty() { # $1 = cols, $2 = rows, $3 = new name, $4 = session to rename
  local w="$1" h="$2" newname="$3" sess="$4" i out=""
  # '=tiny', not 'tiny': tmux matches an UNANCHORED target by prefix, so
  # `kill-session -t tiny` killed the "tinysrc" fixture this test had just
  # created — and the action then correctly reported the target as gone, which
  # looked like the dialog was broken.  The product code anchors every target
  # for the same reason.
  tmux -L "$SOCK" kill-session -t '=tiny' 2>/dev/null || true
  tmux -L "$SOCK" new-session -d -s tiny -x "$w" -y "$h" \
    "env INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
         TMUX_PANE='$TMUX_PANE' bash '$SCRIPT' --action rename \"S:$sess\"; sleep 6"
  for i in $(seq 1 60); do
    tmux -L "$SOCK" capture-pane -t '=tiny:' -p 2>/dev/null | grep -q '╭' && break
    sleep 0.1
  done
  tmux -L "$SOCK" send-keys -t '=tiny:' C-u "$newname" Enter
  for i in $(seq 1 60); do
    out=$(tmux -L "$SOCK" capture-pane -t '=tiny:' -p 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
    printf '%s' "$out" | grep -q '✗' && break
    sleep 0.1
  done
  printf '%s' "$out"
}

# Its own session: an earlier test renames "one" away, and acting on a spec
# whose target is gone now (correctly) shows the "Gone" dialog instead of the
# rename one -- which is a different assertion entirely.
tmux -L "$SOCK" new-session -d -s tinysrc -x 100 -y 30
for _i in $(seq 1 50); do tmux -L "$SOCK" has-session -t '=tinysrc' 2>/dev/null && break; sleep 0.1; done
tiny_out=$(run_rename_tty 52 6 'no:good' 'tinysrc')

# the frame survives: both borders present, on their own rows
if printf '%s\n' "$tiny_out" | grep -q '╭' && printf '%s\n' "$tiny_out" | grep -q '╰'; then
  report "in a 6-row popup the dialog keeps both borders" pass
else
  report "in a 6-row popup the dialog keeps both borders" fail
  ERRORS+="$(printf '%s\n' "$tiny_out" | sed 's/^/      /')"$'\n'
fi

# nothing leaked past the right border onto the frame row
if printf '%s\n' "$tiny_out" | grep -q '^[^│]*there)'; then
  report "the error text does not overrun the frame" fail
  ERRORS+="$(printf '%s\n' "$tiny_out" | sed 's/^/      /')"$'\n'
else
  report "the error text does not overrun the frame" pass
fi

# ...and it is still legible, truncated rather than dropped
if printf '%s\n' "$tiny_out" | grep -q '✗ a name cannot contain'; then
  report "the error is still shown, truncated to fit" pass
else
  report "the error is still shown, truncated to fit" fail
  ERRORS+="$(printf '%s\n' "$tiny_out" | sed 's/^/      /')"$'\n'
fi

# no rendered row is wider than the popup — a wrap is what ate the border
too_wide=$(printf '%s\n' "$tiny_out" | awk '{ n=0; for (i=1; i<=length($0); i++) n++ } n > 52 { print NR }')
if [ -z "$too_wide" ]; then
  report "no dialog row is wider than the popup" pass
else
  report "no dialog row is wider than the popup (rows: $too_wide)" fail
fi
tmux -L "$SOCK" kill-session -t tiny 2>/dev/null || true

# --- acting on a row whose target is gone -------------------------------------------
# The list is a snapshot.  Open the picker, get distracted, and by the time you
# press ctrl-x that window may have been closed from another client.  Every
# action used to open its dialog regardless — "Kill session 'victim'?" for a
# session that no longer exists — and only failed after you confirmed.
tmux -L "$SOCK" new-session -d -s vanishing -x 100 -y 30
tmux -L "$SOCK" new-window -d -t '=vanishing:' -n doomed
for _i in $(seq 1 50); do tmux -L "$SOCK" has-session -t '=vanishing' 2>/dev/null && break; sleep 0.1; done
tmux -L "$SOCK" kill-session -t '=vanishing'

run_on_gone() { # $1 = action, $2 = spec -> the rendered screen
  local act="$1" gspec="$2" i out=""
  tmux -L "$SOCK" kill-window -t '=colonsrc:gone' 2>/dev/null || true
  tmux -L "$SOCK" new-window -d -t '=colonsrc:' -n gone \
    "env INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
         TMUX_PANE='$TMUX_PANE' bash '$SCRIPT' --action $act \"$gspec\"; sleep 5"
  for i in $(seq 1 60); do
    out=$(tmux -L "$SOCK" capture-pane -t '=colonsrc:gone' -p 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
    printf '%s' "$out" | grep -q '╭' && break
    sleep 0.1
  done
  printf '%s' "$out"
}

for pair in "kill:S:vanishing" "rename:W:vanishing:1" "send:P:vanishing:1:0"; do
  act="${pair%%:*}"; gspec="${pair#*:}"
  out=$(run_on_gone "$act" "$gspec")
  if printf '%s\n' "$out" | grep -q 'no longer exists'; then
    report "$act on a vanished $gspec says so instead of prompting" pass
  else
    report "$act on a vanished $gspec says so instead of prompting" fail
    ERRORS+="$(printf '%s\n' "$out" | grep -v '^ *$' | head -3 | sed 's/^/      /')"$'\n'
  fi
done
# The second line of that dialog is exactly as wide as the box allows, which is
# the case dlg_fit used to get wrong: it reserved a column for the ellipsis
# before checking whether anything needed cutting, so a line that fitted exactly
# lost its last character to a "…" that bought nothing.
out=$(run_on_gone kill 'S:vanishing')
if printf '%s\n' "$out" | grep -q 'press \^r to reload\.'; then
  report "a dialog line that fits exactly is not ellipsised" pass
else
  report "a dialog line that fits exactly is not ellipsised" fail
  ERRORS+="$(printf '%s\n' "$out" | grep 'reload' | sed 's/^/      /')"$'\n'
fi

# ...and it must NOT fire for a target that is still there
out=$(run_on_gone kill 'S:colonsrc')
if printf '%s\n' "$out" | grep -q 'no longer exists'; then
  report "a live target is not reported as gone" fail
else
  report "a live target is not reported as gone" pass
fi
tmux -L "$SOCK" kill-window -t '=colonsrc:gone' 2>/dev/null || true

# --- dialogs are measured in CELLS, not characters ------------------------------------
# ${#s} counts characters, so a CJK name produced a title 87 cells wide inside a
# 66-cell box and obliterated the right border.  Measured with tmux's own
# #{cursor_x}, which is the only thing that knows how many cells a row occupies.
CJK='日本語のセッション名前とても長い名前です本当に長いのです'
tmux -L "$SOCK" new-session -d -s "$CJK" -x 100 -y 30
for _i in $(seq 1 50); do tmux -L "$SOCK" has-session -t "=$CJK" 2>/dev/null && break; sleep 0.1; done
printf 'n\n' > "$TMPD/cjkin"
tmux -L "$SOCK" new-window -d -t "=$CJK:" -n dlg \
  "env INTERDIMUX_TTY_IN='$TMPD/cjkin' INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 \
       INTERDIMUX_TMUX_VNUM=307 TMUX_PANE='$TMUX_PANE' \
       bash '$SCRIPT' --action kill \"S:$CJK\"; sleep 6"
for _i in $(seq 1 60); do
  tmux -L "$SOCK" capture-pane -t "=$CJK:dlg" -p 2>/dev/null | grep -q '╭' && break
  sleep 0.1
done
tmux -L "$SOCK" capture-pane -t "=$CJK:dlg" -p 2>/dev/null \
  | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^ *$' > "$TMPD/cjkrows"

# every rendered row must occupy the same number of CELLS -- ask tmux, because
# counting characters here would repeat the very mistake under test
nrow=0
while IFS= read -r r; do nrow=$((nrow+1)); printf '%s' "$r" > "$TMPD/cjk$nrow"; done < "$TMPD/cjkrows"
widths=""
for _i in $(seq 1 "$nrow"); do
  ms="${SOCK}-m$_i"
  tmux -f /dev/null -L "$ms" new-session -d -s m -x 250 -y 10 "cat '$TMPD/cjk$_i'; sleep 10"
  for _j in $(seq 1 40); do
    w=$(tmux -L "$ms" display-message -p -t '=m:' '#{cursor_x}' 2>/dev/null || echo 0)
    [ "${w:-0}" -gt 0 ] && break
    sleep 0.1
  done
  widths="$widths $w"
  tmux -L "$ms" kill-server 2>/dev/null || true
done
uniq_w=$(printf '%s\n' $widths | sort -u | tr '\n' ' ')
if [ "$nrow" -ge 4 ] && [ "$(printf '%s\n' $widths | sort -u | wc -l)" = 1 ]; then
  report "a CJK dialog title keeps every row the same cell width ($uniq_w)" pass
else
  report "a CJK dialog title keeps every row the same cell width" fail
  ERRORS+="    rows=$nrow widths:$widths"$'\n'
fi
tmux -L "$SOCK" kill-session -t "=$CJK" 2>/dev/null || true

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
