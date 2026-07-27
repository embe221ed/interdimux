#!/usr/bin/env bash
#
# The hint bar: what the picker tells you it can do, and where it says it.
#
# Three things are under test, and each one has burned this project before:
#
#   drift    - the bar exists TWICE, as the --footer-for handler (used by old
#              fzf, or when the user supplies their own --with-shell) and as an
#              inline snippet the navigator hands to fzf's focus bind.  They
#              used to be two hand-kept hint lists; now they share hint_set, and
#              this suite drives the REAL snippet against the REAL handler
#              rather than a copy of either.
#   tiering  - measured, the S/W/P lines are 73/71/70 cells and an 80-column
#              terminal gives the bar ~61, so every one of them overflowed and
#              fzf truncated from the right — which cut `^] scope`, the least
#              discoverable binding in the tool, first.  The ladder must fit at
#              every width and must drop in the intended order.
#   placement- the bar is a --footer on fzf >= 0.63.  That is the whole point of
#              the change, so it is asserted against a rendered screen, not
#              against the flag.
#
# Plus the match-scope prompt and the find-or-create announcement, which share
# the same inline-callback machinery.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-hint-test-$$"
OUTER="${SOCK}-outer"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  tmux -L "$OUTER" kill-server 2>/dev/null || true
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

plain() { sed 's/\x1b\[[0-9;]*m//g'; }
cells() { plain | awk 'NR==1{print length($0)} END{if (NR==0) print 0}'; }

echo "interdimux hint bar tests"
echo

# A server is needed only so the script's preflight passes.
tmux -f /dev/null -L "$SOCK" new-session -d -s hint -x 120 -y 30
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=hint:' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1

SPECS=("S:alpha" "W:alpha:0" "P:alpha:0:1" "D:/tmp/some/dir" "Q:other" "S:it's odd" "S:has space")
TYPES=(S W P D X)

# --- the ladder ---------------------------------------------------------------
# Read from the script itself.  Every assertion below is about the ladder the
# navigator actually exports, not about a list retyped here.
declare -A LADDER=()
missing=0
for t in "${TYPES[@]}"; do
  LADDER[$t]="$(bash "$SCRIPT" --hint-ladder "$t")"
  [ -n "${LADDER[$t]}" ] || missing=1
done
[ "$missing" = 0 ] && report "every row type's ladder was read from the script" pass \
                   || report "every row type's ladder was read from the script" fail

# Every rung must (a) declare its own width truthfully and (b) get narrower.
for t in "${TYPES[@]}"; do
  ok=1 prev=999999 rungs=0 detail=""
  rest="${LADDER[$t]}"
  while [ -n "$rest" ]; do
    rung="${rest%%|*}"
    if [ "$rung" = "$rest" ]; then rest=""; else rest="${rest#*|}"; fi
    rungs=$((rungs + 1))
    want="${rung%%:*}"
    got=$(printf '%s' "${rung#*:}" | cells)
    [ "$want" = "$got" ] || { ok=0; detail+=" rung claims ${want} but renders ${got};"; }
    [ "$want" -lt "$prev" ] || { ok=0; detail+=" ${want} is not narrower than ${prev};"; }
    prev="$want"
  done
  [ "$prev" -eq 0 ] || { ok=0; detail+=" the last rung is ${prev}, not empty;"; }
  [ "$rungs" -ge 4 ] || { ok=0; detail+=" only ${rungs} rungs;"; }
  if [ "$ok" = 1 ]; then
    report "the $t ladder is honest and strictly narrowing ($rungs rungs)" pass
  else
    report "the $t ladder is honest and strictly narrowing" fail
    ERRORS+="     $detail"$'\n'
  fi
done

# The bar must FIT at every width — this is the whole difference from truncation.
ok=1
for t in "${TYPES[@]}"; do
  for w in 200 120 100 80 64 61 50 40 30 20 12 8 4 0; do
    got=$(FZF_COLUMNS=$((w + 3)) bash "$SCRIPT" --footer-for "$t:x" | cells)
    if [ "$got" -gt "$w" ]; then
      ok=0
      ERRORS+="     $t at ${w} cells rendered ${got}"$'\n'
    fi
  done
done
[ "$ok" = 1 ] && report "no row type ever renders wider than the bar it is given" pass \
              || report "no row type ever renders wider than the bar it is given" fail

# The drop ORDER is the point of the priorities: `enter` is the binding nothing
# has to advertise, `^] scope` is the one nothing else does.
narrow=$(FZF_COLUMNS=64 bash "$SCRIPT" --footer-for 'S:x' | plain)
case "$narrow" in
  *"enter switch"*) report "at 61 cells the obvious binding is the one dropped" fail
                    ERRORS+="     $narrow"$'\n' ;;
  *"^] scope"*)     report "at 61 cells the obvious binding is the one dropped" pass ;;
  *)                report "at 61 cells the obvious binding is the one dropped" fail ;;
esac

last=""
for w in 200 100 64 50 40 30 20 12; do
  out=$(FZF_COLUMNS=$((w + 3)) bash "$SCRIPT" --footer-for 'S:x' | plain)
  [ -n "$out" ] && last="$out"
done
case "$last" in
  *"^] scope"*) report "^] scope is the last hint standing" pass ;;
  *) report "^] scope is the last hint standing (got: '$last')" fail ;;
esac

# Below the floor: nothing, rather than something cut mid-word.  fzf removes the
# whole footer section when a transform emits nothing, so this costs no row.
tiny=$(FZF_COLUMNS=6 bash "$SCRIPT" --footer-for 'S:x' | plain)
[ -z "$tiny" ] && report "below the floor the bar is empty, not mangled" pass \
               || report "below the floor the bar is empty, not mangled (got: '$tiny')" fail

# A visible preview HALVES the list, and FZF_COLUMNS does not move with it.
wide=$(FZF_COLUMNS=120 bash "$SCRIPT" --footer-for 'P:x:0:1' | cells)
half=$(FZF_COLUMNS=120 FZF_PREVIEW_COLUMNS=56 bash "$SCRIPT" --footer-for 'P:x:0:1' | cells)
if [ "$half" -le 57 ] && [ "$half" -lt "$wide" ]; then
  report "an open preview narrows the bar even though FZF_COLUMNS does not" pass
else
  report "an open preview narrows the bar (wide=$wide half=$half)" fail
fi

# --- drift: the inline snippet vs the handler ---------------------------------
# Build the snippet by EVALUATING the script's own assignments.  A hand-copied
# duplicate silently stopped matching the moment one side changed, which is the
# exact failure this suite exists to catch.
eval "$(grep -E '^\s*_hint_case(\+)?=' "$SCRIPT")"
hint_case="${_hint_case:-}"
if [ -n "$hint_case" ]; then
  report "the inline snippet was extracted from the script" pass
else
  report "the inline snippet was extracted from the script" fail
  echo; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

case "$hint_case" in
  *,*) report "the inline snippet contains no comma (fzf splits --bind on commas)" fail ;;
  *)   report "the inline snippet contains no comma (fzf splits --bind on commas)" pass ;;
esac

for t in "${TYPES[@]}"; do export "INTERDIMUX_HINTS_$t=${LADDER[$t]}"; done

rm -f /tmp/imux_hint_pwned
for spec in "${SPECS[@]}" '$(touch /tmp/imux_hint_pwned)'; do
  agree=1
  for w in 200 100 64 40 20 8; do
    want=$(FZF_COLUMNS="$w" bash "$SCRIPT" --footer-for "$spec")
    # fzf single-quotes the placeholder; printf %q is the closest stand-in
    got=$(FZF_COLUMNS="$w" sh -c "${hint_case/_\{-1\}/_$(printf '%q' "$spec")}")
    if [ "$want" != "$got" ]; then
      agree=0
      ERRORS+="     '$spec' at $w: handler '$(printf '%s' "$want" | plain)' vs inline '$(printf '%s' "$got" | plain)'"$'\n'
    fi
  done
  [ "$agree" = 1 ] && report "inline == --footer-for at every width for '$spec'" pass \
                   || report "inline == --footer-for at every width for '$spec'" fail
done
if [ -e /tmp/imux_hint_pwned ]; then
  report "a row spec cannot execute shell" fail; rm -f /tmp/imux_hint_pwned
else
  report "a row spec cannot execute shell" pass
fi

# The snippet reads the LIVE width, which is what keeps the bar right after ^/
# and after a resize — neither is knowable when the navigator builds the string.
a=$(FZF_COLUMNS=200 sh -c "${hint_case/_\{-1\}/_S:x}" | cells)
b=$(FZF_COLUMNS=64  sh -c "${hint_case/_\{-1\}/_S:x}" | cells)
if [ "$b" -lt "$a" ]; then
  report "the inline snippet re-tiers on the live width ($a -> $b)" pass
else
  report "the inline snippet re-tiers on the live width ($a -> $b)" fail
fi
# Opening the preview must be worth exactly a halving, and nothing else: with it
# open at 128 the bar has to be the same rung it would pick at 64 with no
# preview.  A `<` test would pass on a threshold that happened to be wrong.
withpv=$(FZF_COLUMNS=128 FZF_PREVIEW_COLUMNS=60 sh -c "${hint_case/_\{-1\}/_S:x}")
nopv=$(FZF_COLUMNS=64 sh -c "${hint_case/_\{-1\}/_S:x}")
if [ "$withpv" = "$nopv" ] && [ -n "$nopv" ]; then
  report "an open preview costs the snippet exactly half the width" pass
else
  report "an open preview costs the snippet exactly half the width" fail
  ERRORS+="     with preview: '$(printf '%s' "$withpv" | plain)'"$'\n'"     at half   : '$(printf '%s' "$nopv" | plain)'"$'\n'
fi

# Empty result list: fzf expands {-1} to zero words.  The `_` prefix is what
# keeps the case subject a real word instead of `case in` (a syntax error).
got=$(FZF_COLUMNS=200 sh -c "${hint_case/_\{-1\}/_}" 2>&1) || got="ERROR"
want=$(FZF_COLUMNS=200 bash "$SCRIPT" --footer-for '')
if [ "$got" = "$want" ]; then
  report "empty result list falls back to the generic bar" pass
else
  report "empty result list falls back to the generic bar (got: ${got:0:40})" fail
fi
if sh -c "${hint_case/_\{-1\}/}" >/dev/null 2>&1; then
  report "control: an unprefixed empty subject IS a syntax error" fail
else
  report "control: an unprefixed empty subject IS a syntax error" pass
fi

# --- placement: the bar is at the BOTTOM ---------------------------------------
# The reason for the whole change is that a bar above the list is rewritten on
# every cursor move, at the exact row the eye uses to keep its place.  Assert it
# against a rendered screen; the flag alone would pass even if fzf ignored it.
render() { # $1 = rows, $2 = fzf minor to pretend to be; prints the screen
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 100 -y "$1" \
    "env TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' INTERDIMUX_OPTS_PRIMED=1 \
         INTERDIMUX_FZF_MINOR=${2:-74} INTERDIMUX_TMUX_VNUM=307 \
         INTERDIMUX_SHOW_DIRS=off FZF_DEFAULT_OPTS= \
         bash '$SCRIPT'; sleep 30"
  local i
  for i in $(seq 1 150); do
    tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | grep -q '❯' && break
    sleep 0.15
  done
  sleep 0.6
  tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | plain
}

screen=$(render 16)
bar_row=$(printf '%s\n' "$screen" | grep -n 'kill' | head -1 | cut -d: -f1)
row_row=$(printf '%s\n' "$screen" | grep -n '▸ hint' | head -1 | cut -d: -f1)
if [ -n "$bar_row" ] && [ -n "$row_row" ] && [ "$bar_row" -gt "$row_row" ]; then
  report "the hint bar renders BELOW the list (row $bar_row vs $row_row)" pass
else
  report "the hint bar renders below the list (bar=$bar_row list=$row_row)" fail
  ERRORS+="$(printf '%s\n' "$screen" | head -6 | sed 's/^/       /')"$'\n'
fi

# ...and it costs exactly the row the header was already spending.  Measured on
# fzf 0.74: the footer's DEFAULT border draws a separator and costs a SECOND
# row, which is why --footer-border=none is in the shared theme.
sep=$(printf '%s\n' "$screen" | grep -c '^─────' || true)
if [ "${sep:-0}" -le 1 ]; then
  report "the footer draws no second separator (borderless, one row)" pass
else
  report "the footer draws no second separator (found $sep rules)" fail
fi

old=$(render 16 62)
old_bar=$(printf '%s\n' "$old" | grep -n 'kill' | head -1 | cut -d: -f1)
old_row=$(printf '%s\n' "$old" | grep -n '▸ hint' | head -1 | cut -d: -f1)
if [ -n "$old_bar" ] && [ -n "$old_row" ] && [ "$old_bar" -lt "$old_row" ]; then
  report "on fzf < 0.63 it is still a header, above the list" pass
else
  report "on fzf < 0.63 it is still a header (bar=$old_bar list=$old_row)" fail
fi
tmux -L "$OUTER" kill-server 2>/dev/null || true

# --- scope prompt --------------------------------------------------------------
# Build the inline case by EVALUATING the script's own _scope_case assignments
# rather than re-typing them here.
eval "$(grep -E '^\s*_scope_case(\+)?=' "$SCRIPT")"
scope_case="$_scope_case"
if [ -n "$scope_case" ]; then
  report "the inline scope case was extracted from the script" pass
else
  report "the inline scope case was extracted from the script" fail
fi

# Every state the ctrl-] cycle can actually reach, read from the binding itself:
# a sixth state added to change-nth without a label would otherwise show a bare
# "❯ ", indistinguishable from no scope at all.
cycle=$(grep -o 'change-nth([^)]*)' "$SCRIPT" | head -1 | sed 's/change-nth(//; s/)$//')
IFS='|' read -r -a cycle_states <<< "$cycle"
if [ "${#cycle_states[@]}" -ge 5 ]; then
  report "the ctrl-] cycle was parsed from the binding (${#cycle_states[@]} states)" pass
else
  report "the ctrl-] cycle was parsed from the binding (got: '$cycle')" fail
fi
for nth in ${cycle_states[@]+"${cycle_states[@]}"}; do
  got=$(FZF_NTH="$nth" bash "$SCRIPT" --scope-prompt)
  if [ "$got" != "❯ " ]; then
    report "scope state '$nth' has a label ('${got% ❯ }')" pass
  else
    report "scope state '$nth' has a label" fail
    ERRORS+="    every state ctrl-] cycles to must name itself"$'\n'
  fi
done

for nth in ${cycle_states[@]+"${cycle_states[@]}"} ""; do
  want=$(FZF_NTH="$nth" bash "$SCRIPT" --scope-prompt)
  got=$(FZF_NTH="$nth" sh -c "$scope_case")
  if [ "$want" = "$got" ]; then
    report "inline scope prompt matches --scope-prompt for FZF_NTH='$nth'" pass
  else
    report "inline scope prompt matches --scope-prompt for FZF_NTH='$nth' (want '$want', got '$got')" fail
  fi
done

# The scope is announced in the ROWS too (fzf >= 0.66): `nth:` restyles the
# searchable fields, so the bright band is the answer to "what am I matching?".
# --color is parsed at startup and an unknown key is FATAL, so the token has to
# be exactly right or every picker dies before it draws.
if grep -q 'FZF_COLORS+=",fg:dim,nth:regular' "$SCRIPT" \
   && printf 'x\n' | fzf --filter=x --color='fg:dim,nth:regular' >/dev/null 2>&1; then
  report "the scope highlight token is one fzf accepts" pass
else
  report "the scope highlight token is one fzf accepts" fail
fi
# fg+ must carry its attributes explicitly: fzf's fg+ default is bold, and
# overriding only the colour left the current row bold AND dim at once.
if grep -q 'fg+:${COLOR_QUERY}:regular:bold' "$SCRIPT"; then
  report "the current row is exempted from the scope dim" pass
else
  report "the current row is exempted from the scope dim" fail
fi

# --- find-or-create announcement (IDEAS #1) -----------------------------------
# The feature used to be invisible: you typed a name, nothing matched, and Enter
# silently created a session — a typo made junk with no warning.
out=$(bash "$SCRIPT" --describe-create 'brandnewthing' 2>/dev/null | plain)
case "$out" in
  *create*brandnewthing*) report "--describe-create names the session it would create" pass ;;
  *) report "--describe-create names the session it would create (got: $out)" fail ;;
esac
case "$out" in
  *"(home)"*|*"(zoxide)"*|*"(path)"*) report "--describe-create says where it would create it" pass ;;
  *) report "--describe-create says where it would create it (got: $out)" fail ;;
esac
out=$(bash "$SCRIPT" --describe-create '/tmp' 2>/dev/null | plain)
case "$out" in
  *"(path)"*) report "an existing path is recognised as a path" pass ;;
  *) report "an existing path is recognised as a path (got: $out)" fail ;;
esac
out=$(bash "$SCRIPT" --describe-create '' 2>/dev/null)
[ -z "$out" ] && report "an empty query describes nothing" pass \
              || report "an empty query describes nothing" fail

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
