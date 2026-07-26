#!/usr/bin/env bash
#
# The baked prefix+f binding: does a real key press deliver the right
# environment into the popup?
#
# This exercises the whole chain -- bind-key storage -> run-shell format
# expansion -> tmux's command parser -> display-popup -e -> /bin/sh -> bash --
# because that is where the failures live, and every one of them is SILENT:
#
#   raw #{@x}      a double quote in a value kills the binding outright;
#                  prefix+f then does nothing at all, with no error
#   #{?@x,...}     tmux format truthiness treats the string "0" as FALSE, so
#                  colour-tree 0 / recent-limit 0 get replaced by defaults
#   TMUX_PANE      a popup natively exports its OWN pane id, which resolves to
#                  an empty target: the current-row marker disappears and MRU's
#                  move-current-to-end (Enter = hop back) stops working
#
# Note `send-keys` cannot be used to fire a binding: it writes straight to a
# pane's pty, while real keys arrive via a CLIENT.  Hence the nested client.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK="interdimux-bindkeys-test-$$"
T=$(command -v tmux)
TMPD=$(mktemp -d /tmp/imuxbind.XXXXXX)
OUT="$TMPD/env.txt"
trap '"$T" -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMPD"' EXIT

# the probe copy: dump env and exit when invoked with NO args
{
  head -1 "$REPO/scripts/interdimux.sh"
  printf 'if [ $# -eq 0 ]; then env | grep -E "^(INTERDIMUX_|TMUX_PANE=)" | sort > %q; exit 0; fi\n' "$OUT"
  tail -n +2 "$REPO/scripts/interdimux.sh"
} > "$TMPD/probe.sh"
chmod +x "$TMPD/probe.sh"
bash -n "$TMPD/probe.sh" || { echo "probe copy does not parse"; exit 1; }

"$T" -f /dev/null -L "$SOCK" new-session -d -s main -x 120 -y 40 -c "$REPO"
"$T" -L "$SOCK" new-window -d -t '=main:' -n second -c "$REPO"

# A real key press has to arrive through a CLIENT: `send-keys` writes straight
# to a pane's pty and never reaches tmux's key table.  So drive an outer tmux
# whose pane holds a client attached to the server under test, and type into
# that — the same nesting tests/test_list_format.sh uses.
OUTER="${SOCK}-outer"
trap '"$T" -L "$SOCK" kill-server 2>/dev/null || true; "$T" -L "$OUTER" kill-server 2>/dev/null || true; rm -rf "$TMPD"' EXIT
"$T" -f /dev/null -L "$OUTER" new-session -d -s drv -x 130 -y 45 \
  "TMUX= $T -L $SOCK attach -t main"
sleep 3

NASTY='a"b\c$HOME;d#{pane_id}e}f --no-mouse'
"$T" -L "$SOCK" set -g @interdimux-fzf-opts "$NASTY"
"$T" -L "$SOCK" set -g @interdimux-color-tree 0      # "0" is FALSE to #{?...}
"$T" -L "$SOCK" set -g @interdimux-recent-limit 0
"$T" -L "$SOCK" set -g @interdimux-order index
# popup-width/height deliberately left UNSET, to exercise the defaults

# point $TMUX at the private server or the script rebinds the REAL one
export TMUX="$("$T" -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
bash "$TMPD/probe.sh" --bind-keys || { echo "--bind-keys failed"; exit 1; }

# make window 2 active, so #{pane_id} must resolve to ITS pane, not window 1's
"$T" -L "$SOCK" select-window -t '=main:second'
sleep 1
EXPECT_PANE=$("$T" -L "$SOCK" display-message -p '#{pane_id}')

# type prefix+f into the OUTER pane -> the inner client sees a real key press
"$T" -L "$OUTER" send-keys -t '=drv:' C-b
sleep 0.6
"$T" -L "$OUTER" send-keys -t '=drv:' f
sleep 3.5

PASS=0
FAIL=0
ERRORS=""
ck() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$1"
    ERRORS+="  FAIL: $1"$'\n'"        want: [$3]"$'\n'"        got : [$2]"$'\n'
  fi
}

if [ ! -s "$OUT" ]; then
  echo "  POPUP NEVER RAN - the binding did not fire"
  "$T" -L "$SOCK" list-keys -T prefix | grep -E ' f ' | cut -c1-200
  exit 1
fi

echo "interdimux baked-keybinding tests"
echo
get() { sed -n "s/^$1=//p" "$OUT"; }
ck "hostile @interdimux-fzf-opts survives verbatim" "$(get INTERDIMUX_FZF_OPTS)" "$NASTY"
ck "color-tree=0 is not swallowed as false"         "$(get INTERDIMUX_COLOR_TREE)" "0"
ck "recent-limit=0 is not swallowed as false"       "$(get INTERDIMUX_RECENT_LIMIT)" "0"
ck "order forwarded"                                "$(get INTERDIMUX_ORDER)" "index"
ck "unset option arrives empty (-> built-in default)" "$(get INTERDIMUX_SHOW_PREVIEW)" ""
ck "OPTS_PRIMED set"                                "$(get INTERDIMUX_OPTS_PRIMED)" "1"
ck "TMUX_PANE is the PRESSING client's pane"        "$(get TMUX_PANE)" "$EXPECT_PANE"
# The title names the session you are in: once the list is longer than the
# popup the current row scrolls away, and the title is the only thing left on
# screen saying where you are.  Free here -- it comes from a tmux format
# expanded in-server at keypress.
ck "TITLE names the current session"                "$(get INTERDIMUX_TITLE)" " interdimux · main "
ck "TMUX_VNUM baked numerically"                    "$(get INTERDIMUX_TMUX_VNUM)" "307"

ck "every option in OPT_MAP is forwarded" \
   "$(grep -c '^INTERDIMUX_' "$OUT")" \
   "$(( $(grep -c '"' <<< "$(sed -n '/^OPT_MAP=(/,/^)/p' "$REPO/scripts/interdimux.sh" | grep -o '"[a-z-]*:[A-Z_]*"')" ) + 4 ))"

# --- an install path containing '#' ---------------------------------------------
# run-shell FORMAT-EXPANDS its argument, so a '#' in the install path is read as
# the start of a format.  Measured against tmux 3.7b, which sequences actually
# get eaten:
#
#   .../we#ird/x     -> unchanged        (#i is not a format; tmux leaves it)
#   .../tmp#1/x      -> unchanged
#   .../w#[bold]/x   -> unchanged        (a style, re-emitted verbatim here)
#   .../we#Sird/x    -> .../we<session>ird/x
#   .../#Hx/x        -> .../<hostname>x/x
#   .../w#{pane_id}/x-> .../w%0/x
#
# So it needs a '#' followed by a format character -- narrower than "any '#'",
# but silent when it hits: prefix+f runs a path that does not exist and nothing
# is reported anywhere.  The directory below uses '#S' deliberately; '#ird'
# would pass with or without the fix and prove nothing.
HASHD="$TMPD/we#Sird dir"
mkdir -p "$HASHD"
OUT2="$TMPD/env2.txt"
{
  head -1 "$REPO/scripts/interdimux.sh"
  printf 'if [ $# -eq 0 ]; then env | grep -E "^(INTERDIMUX_|TMUX_PANE=)" | sort > %q; exit 0; fi\n' "$OUT2"
  tail -n +2 "$REPO/scripts/interdimux.sh"
} > "$HASHD/probe.sh"
chmod +x "$HASHD/probe.sh"

bash "$HASHD/probe.sh" --bind-keys || { echo "--bind-keys failed from a # path"; exit 1; }

# The stored binding must survive tmux's OWN format expansion back to the real
# path -- expand it here rather than inferring from the literal text.
for _k_what in "f:--launch switch or a popup" "g:--dashboard-launch"; do
  _k="${_k_what%%:*}"
  _stored=$("$T" -L "$SOCK" list-keys -T prefix 2>/dev/null \
            | awk -v k="$_k" '$2=="-T" && $3=="prefix" && $4==k' \
            | sed 's/^[^"]*"//; s/"$//')
  _expanded=$("$T" -L "$SOCK" display-message -p "$_stored" 2>/dev/null)
  case "$_expanded" in
    *"$HASHD/probe.sh"*) PASS=$((PASS + 1))
      printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "prefix+$_k survives tmux format expansion from a '#' path" ;;
    *) FAIL=$((FAIL + 1))
      printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "prefix+$_k survives tmux format expansion from a '#' path"
      ERRORS+="  FAIL: prefix+$_k from a '#' path"$'\n'"        want to contain: [$HASHD/probe.sh]"$'\n'"        expanded to    : [$_expanded]"$'\n' ;;
  esac
done

# The session name now travels inside the title, so a hostile one has to survive
# the whole -e/-T chain.  Measured on tmux 3.7b, what a name can actually hold:
# tmux FORMAT-EXPANDS the name at create/rename time, so "#S" and "#h" are gone
# before they are ever stored ("has#hash" becomes "has<hostname>ash") -- but a
# '"' survives intact, and so does a '#' in a benign position.  A quote is the
# dangerous one: it would close the -e token and kill the binding outright.
"$T" -L "$SOCK" rename-session -t main 'ma"in#xy'
bash "$HASHD/probe.sh" --bind-keys
rm -f "$OUT2"
"$T" -L "$OUTER" send-keys -t '=drv:' C-b
sleep 0.6
"$T" -L "$OUTER" send-keys -t '=drv:' f
sleep 3.5
_got_title=$(sed -n 's/^INTERDIMUX_TITLE=//p' "$OUT2" 2>/dev/null)
if [ "$_got_title" = ' interdimux · ma"in#xy ' ]; then
  PASS=$((PASS + 1)); printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "a session name with a quote and a '#' survives into the title"
else
  FAIL=$((FAIL + 1)); printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "a session name with a quote and a '#' survives into the title"
  ERRORS+="  FAIL: hostile session name in the title"$'\n'"        want: [ interdimux · ma\"in#Sx ]"$'\n'"        got : [$_got_title]"$'\n'
fi
"$T" -L "$SOCK" rename-session -t 'ma"in#xy' main

# ...and end to end: a real key press must actually reach the popup.
"$T" -L "$OUTER" send-keys -t '=drv:' C-b
sleep 0.6
"$T" -L "$OUTER" send-keys -t '=drv:' f
sleep 3.5
if [ -s "$OUT2" ]; then
  PASS=$((PASS + 1)); printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "prefix+f actually opens the popup from a '#' path"
else
  FAIL=$((FAIL + 1)); printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "prefix+f actually opens the popup from a '#' path"
  ERRORS+="  FAIL: the popup never ran from a '#' install path"$'\n'
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
exit 0
