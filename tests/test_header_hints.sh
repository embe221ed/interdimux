#!/usr/bin/env bash
#
# The per-row header and the match-scope prompt exist TWICE: as the
# --header-for / --scope-prompt handlers (used by old fzf, or when the user
# supplies their own --with-shell), and as inline `case` snippets the navigator
# hands to fzf's focus / ctrl-] binds.  The two must agree, or the fast path
# silently shows different hints from the fallback.
#
# Two kinds of check:
#   content  - the hint argument lists are the same in both places (static)
#   dispatch - the inline `case` picks the right one, including the empty
#              result list, where fzf substitutes NOTHING for {-1}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-hdr-test-$$"
PASS=0
FAIL=0
ERRORS=""

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

echo "interdimux header/scope inline-callback tests"
echo

# --- content: the two hint lists must carry the same keys -------------------
# From the --header-for handler:  "    S) hint enter switch ... ;;"
# From the navigator:             "      hint_r enter switch ... ${_scope_hint...}"
norm() { sed -e 's/\${[_a-zA-Z]*scope_hint\[@\][^}]*}[^ ]*//' -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//'; }

for pair in "S:HDR_S" "W:HDR_W" "P:HDR_P"; do
  t="${pair%%:*}" ; label="${pair#*:}"
  from_handler=$(grep -E "^ *$t\) hint " "$SCRIPT" | head -1 | sed -e "s/^ *$t) hint //" -e 's/ *;;$//' | norm)
  from_nav=$(grep -A1 -E "^ *hint_r .*" "$SCRIPT" | grep -B1 "INTERDIMUX_$label=" | head -1 \
             | sed -e 's/^ *hint_r //' | norm)
  if [ -n "$from_handler" ] && [ "$from_handler" = "$from_nav" ]; then
    report "hint keys agree for $t rows" pass
  else
    report "hint keys agree for $t rows" fail
    ERRORS+="      handler: $from_handler"$'\n'"      nav    : $from_nav"$'\n'
  fi
done

fallback_handler=$(grep -E '^ *\*\) hint ' "$SCRIPT" | head -1 | sed -e 's/^ *\*) hint //' -e 's/ *;;$//' | norm)
fallback_nav=$(grep -B1 'INTERDIMUX_HDR_X=' "$SCRIPT" | grep 'hint_r ' | head -1 | sed -e 's/^ *hint_r //' | norm)
if [ -n "$fallback_handler" ] && [ "$fallback_handler" = "$fallback_nav" ]; then
  report "hint keys agree for the fallback row type" pass
else
  report "hint keys agree for the fallback row type" fail
  ERRORS+="      handler: $fallback_handler"$'\n'"      nav    : $fallback_nav"$'\n'
fi

# --- dispatch: the inline case, driven exactly as fzf drives it -------------
# A server is needed only so the script's preflight passes.
tmux -f /dev/null -L "$SOCK" new-session -d -s hdr -x 120 -y 30
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=hdr:' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307

export INTERDIMUX_HDR_S="$(bash "$SCRIPT" --header-for 'S:x')"
export INTERDIMUX_HDR_W="$(bash "$SCRIPT" --header-for 'W:x:0')"
export INTERDIMUX_HDR_P="$(bash "$SCRIPT" --header-for 'P:x:0:1')"
export INTERDIMUX_HDR_X="$(bash "$SCRIPT" --header-for '')"

hdr_case='case _SUBJECT in'
hdr_case+=' _S:*) printf "%s\n" "$INTERDIMUX_HDR_S";;'
hdr_case+=' _W:*) printf "%s\n" "$INTERDIMUX_HDR_W";;'
hdr_case+=' _P:*) printf "%s\n" "$INTERDIMUX_HDR_P";;'
hdr_case+=' *) printf "%s\n" "$INTERDIMUX_HDR_X";; esac'

for spec in "S:alpha" "W:alpha:0" "P:alpha:0:1" "D:dir" "S:it's odd" "S:has space" 'S:$(touch /tmp/imux_pwned)'; do
  want=$(bash "$SCRIPT" --header-for "$spec")
  # fzf single-quotes the placeholder; printf %q is the closest stand-in
  got=$(sh -c "${hdr_case/_SUBJECT/_$(printf '%q' "$spec")}")
  if [ "$want" = "$got" ]; then
    report "inline header matches --header-for for '$spec'" pass
  else
    report "inline header matches --header-for for '$spec'" fail
  fi
done
if [ -e /tmp/imux_pwned ]; then
  report "a row spec cannot execute shell" fail; rm -f /tmp/imux_pwned
else
  report "a row spec cannot execute shell" pass
fi

# Empty result list: fzf expands {-1} to zero words.  The `_` prefix is what
# keeps the case subject a real word instead of `case in` (a syntax error).
got=$(sh -c "${hdr_case/_SUBJECT/_}" 2>&1) || got="ERROR"
if [ "$got" = "$INTERDIMUX_HDR_X" ]; then
  report "empty result list falls back to the generic header" pass
else
  report "empty result list falls back to the generic header (got: ${got:0:40})" fail
fi
if sh -c "${hdr_case/_SUBJECT/}" >/dev/null 2>&1; then
  report "control: an unprefixed empty subject IS a syntax error" fail
else
  report "control: an unprefixed empty subject IS a syntax error" pass
fi

# --- scope prompt ------------------------------------------------------------
scope_case='case "${FZF_NTH:-}" in'
scope_case+=' 1) printf "name ❯ \n";; 2) printf "path ❯ \n";;'
scope_case+=' 3) printf "cmd ❯ \n";; 1,2,3) printf "all ❯ \n";;'
scope_case+=' *) printf "❯ \n";; esac'
for nth in 1 2 3 1,2,3 1,3 ""; do
  want=$(FZF_NTH="$nth" bash "$SCRIPT" --scope-prompt)
  got=$(FZF_NTH="$nth" sh -c "$scope_case")
  if [ "$want" = "$got" ]; then
    report "inline scope prompt matches --scope-prompt for FZF_NTH='$nth'" pass
  else
    report "inline scope prompt matches --scope-prompt for FZF_NTH='$nth' (want '$want', got '$got')" fail
  fi
done

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
