#!/usr/bin/env bash
#
# Title and option rules (README "Title rules"), in BOTH renderers.
#
#   * DEFAULT_STATE_OPTS -- the option names the script puts in its list-panes
#     format -- is exactly the set the default @option rules read (it is
#     spelled out for speed, so it can drift from them)
#   * rule syntax: literal patterns (a backslash and every ERE special match
#     themselves), greedy captures, templates, `=`, `-`, %spin, `*` rules in
#     their place in the order, an empty name in an APPS list, comments, tabs
#     and CRLF line ends
#   * a user's rules file comes first, so it overrides the defaults; `~` in its
#     path is the home directory
#   * option rules: the first state and the first description win, and an
#     @option named only in the user's file is read from tmux all the same
#
# Expected rows are written out here, not computed by either renderer.  The
# dump seam (INTERDIMUX_DUMP_IN) feeds both renderers the same panes, so the
# syntax cases need no timing; the option cases run on a private server.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-titlerules-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-titlerules.XXXXXX")" && pwd -P)"
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

echo "interdimux title rule tests"
echo

RENDERERS="off"
[ -x "$BIN" ] && RENDERERS="off on"
[ -x "$BIN" ] || echo "  (the Rust core is not built: only the bash renderer is checked)"

# --- 1. DEFAULT_STATE_OPTS against the default rules ------------------------
# The rules' @names, parsed here with awk: the first word of every rule line
# that starts with @, split on commas.
defaults=$(awk "/^DEFAULT_TITLE_RULES='/ { on = 1; next } on && /^'\$/ { exit } on" "$SCRIPT")
from_rules=$(printf '%s\n' "$defaults" | awk '$1 ~ /^@/ { n = split($1, a, ","); for (i = 1; i <= n; i++) { sub(/^@/, "", a[i]); if (a[i] != "" && !seen[a[i]]++) print a[i] } }')
listed=$(sed -n "s/^DEFAULT_STATE_OPTS='\(.*\)'\$/\1/p" "$SCRIPT" | tr ' ' '\n' | sed '/^$/d')
if [ -n "$from_rules" ] && [ "$from_rules" = "$listed" ]; then
  report "DEFAULT_STATE_OPTS is exactly the default rules' options, in order ($(printf '%s\n' "$listed" | wc -l))" pass
else
  report "DEFAULT_STATE_OPTS is exactly the default rules' options, in order" fail
  ERRORS+="     rules:  $(printf '%s ' $from_rules)"$'\n'"     listed: $(printf '%s ' $listed)"$'\n'
fi

# The rules are one single-quoted string: an apostrophe in a comment in it
# would end the string and run the rest as commands.
if printf '%s\n' "$defaults" | grep -q "'"; then
  report "the default rules hold no apostrophe (it would end the quoted string)" fail
else
  report "the default rules hold no apostrophe (it would end the quoted string)" pass
fi

# --- 2. rule syntax, through the dump seam ----------------------------------
US=$'\x1f' RS=$'\x1e' GS=$'\x1d'
NOPTS=$(printf '%s\n' "$listed" | wc -l)
empty_opts=$(printf "${GS}%.0s" $(seq "$NOPTS"))
# One pane per case: app | title.  Every window has one pane, so the window
# row is the case.
CASES=(
  'tool|a\b(x)'                  # backslash and parens are literal
  'tool|ab(x)'                   # ...so this does not match
  'tool|^.$|?+{}[] tail'         # every ERE special is literal
  'tool|S one | two | three'     # greedy: $1 takes the most it can
  'star|S star'                  # a * rule, before the app rules in the file
  'tool|T early'                 # an app rule that comes before a * rule
  'tool|⠋ spinning'              # %spin
  'tool|x spinning'              # ...needs a spinner
  'other|kept whole'             # DESC =
  'other|hidden'                 # DESC -
  'codex|⠋ Fix login | app'      # the user's rule overrides the default
  'codex|[ ! ] Action Required | Add tests | app'   # a default the user left alone
)
{
  printf 's%s1700000000%s%s%s%s/tmp\n%s\n' "$US" "$US" "${#CASES[@]}" "$US" "$US" "$RS"
  i=0; for c in "${CASES[@]}"; do
    printf 's%s%d%sw%d%s0%s%s%s/tmp%s1%s%d%s000\n' "$US" "$i" "$US" "$i" "$US" "$US" "${c%%|*}" "$US" "$US" "$US" $((1000 + i)) "$US"
    i=$((i + 1))
  done
  printf '%s\n' "$RS"
  i=0; for c in "${CASES[@]}"; do
    printf 's%s%d%s0%s1%s%s%s/tmp%s%d%s1%s%%%d%s%s%s%s\n' "$US" "$i" "$US" "$US" "$US" "${c%%|*}" "$US" "$US" $((1000 + i)) "$US" "$US" "$i" "$US" "${c#*|}" "$US" "$empty_opts"
    i=$((i + 1))
  done
  printf '%s\ns%s0%s0%shost.example%shost\n%s\n' "$RS" "$US" "$US" "$US" "$US" "$RS"
} > "$TMPD/rules.dump"

mkdir -p "$TMPD/home"
# tabs, a CRLF line and a comment on purpose; ',tool' names tool (the empty
# name names nothing)
printf '%s\n' \
  '# a comment, never a rule' \
  $',tool\t-\t[$1]\ta\\b(*)' \
  'tool  working  -  ^.$|?+{}[]*' \
  'tool  -  <$1>  S * | *' \
  $'*  -  star:$1  S *\r' \
  'tool  -  T:$1  T *' \
  '*  -  late:$1  T *' \
  'tool  working  $1  %spin *' \
  'other  -  =  kept whole' \
  'other  -  -  *' \
  'codex  input  OVR:$1  %spin * | *' \
  > "$TMPD/home/titles"

# the script's own isolation, as tests/test_corpus_parity.sh runs it
mkdir -p "$TMPD/stub"; printf '#!/bin/sh\nexit 1\n' > "$TMPD/stub/tmux"; chmod +x "$TMPD/stub/tmux"
render_dump() { # $1 = on|off
  env -i HOME="$TMPD/home" PATH="$TMPD/stub:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    TMUX="$TMPD/no-server,1,0" INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
    INTERDIMUX_NOW=1700086400 INTERDIMUX_SHOW_FULL_COMMAND=off INTERDIMUX_SHOW_GIT_BRANCH=off \
    INTERDIMUX_SHOW_DIRS=off INTERDIMUX_ORDER=index INTERDIMUX_USE_RUST="$1" \
    INTERDIMUX_TITLE_RULES='~/titles' INTERDIMUX_DUMP_IN="$TMPD/rules.dump" \
    bash "$SCRIPT" --list 2> "$TMPD/err.$1" \
    | awk -F'\t' '$4 ~ /^W:/ { print $3 }' | sed 's/\x1b\[[0-9;]*m//g'
}
EXPECT=(
  'tool ∣ [x]'
  'tool'
  'tool ∣ working'
  'tool ∣ <one | two>'
  'star ∣ star:star'
  'tool ∣ T:early'
  'tool ∣ working ∣ spinning'
  'tool'
  'other ∣ kept whole'
  'other'
  'codex ∣ input ∣ OVR:Fix login'
  'codex ∣ approve ∣ Add tests'
)
WHAT=(
  "a backslash and parens match themselves"
  "...and nothing else"
  "every ERE special matches itself"
  "a capture is greedy, from the left"
  "a * rule applies to any app"
  "an app rule before a * rule wins over it"
  "%spin matches a leading spinner"
  "...and only a spinner"
  "DESC = keeps the whole title"
  "DESC - shows none"
  "the user's file overrides a default rule (~ in its path)"
  "...and leaves the other defaults in force"
)
for rust in $RENDERERS; do
  label="bash"; [ "$rust" = on ] && label="rust"
  mapfile -t GOT < <(render_dump "$rust")
  for i in "${!EXPECT[@]}"; do
    if [ "${GOT[i]-}" = "${EXPECT[i]}" ]; then
      report "$label: ${WHAT[i]}" pass
    else
      report "$label: ${WHAT[i]} (got: '${GOT[i]-}', want: '${EXPECT[i]}')" fail
    fi
  done
  [ ! -s "$TMPD/err.$rust" ] && report "$label: nothing on stderr" pass \
    || { report "$label: nothing on stderr" fail; ERRORS+="$(head -3 "$TMPD/err.$rust")"$'\n'; }
done

# --- 3. option rules, live ----------------------------------------------------
unset TMUX TMUX_PANE
tmux -f /dev/null -L "$SOCK" new-session -d -s t -x 160 -y 30 -c "$TMPD" 'exec sleep 991'
tmux -f /dev/null -L "$SOCK" new-window -d -t '=t:' -c "$TMPD" 'exec sleep 992'
tmux -f /dev/null -L "$SOCK" new-window -d -t '=t:' -c "$TMPD" 'exec sleep 993'
# a user-only option; a default one with a description from a second option;
# and a value with a newline, a US and an RS in it (the format rewrites them)
tmux -L "$SOCK" set -p -t '=t:0' @my_state blocked
tmux -L "$SOCK" set -p -t '=t:1' @pane_status waiting
tmux -L "$SOCK" set -p -t '=t:1' @agent_desc "$(printf 'Fix\nit%sreally%snow' "$US" "$RS")"
tmux -L "$SOCK" set -p -t '=t:2' @agent_state error
printf '%s\n' '@my_state  approve  -  blocked' '@agent_state  -  from-user  error' > "$TMPD/home/titles2"
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=t:0' -F '#{pane_id}' | head -1)"
live() { # $1 = on|off
  env HOME="$TMPD/home" XDG_CONFIG_HOME="$TMPD/xdg" XDG_STATE_HOME="$TMPD/state" \
    INTERDIMUX_CLAUDE_DIR="$TMPD/noclaude" INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
    INTERDIMUX_SHOW_FULL_COMMAND=on INTERDIMUX_SHOW_GIT_BRANCH=off INTERDIMUX_SHOW_DIRS=off \
    INTERDIMUX_ORDER=index INTERDIMUX_USE_RUST="$1" INTERDIMUX_TITLE_RULES="$TMPD/home/titles2" \
    bash "$SCRIPT" --list 2> "$TMPD/lerr.$1" \
    | awk -F'\t' '$4 ~ /^W:/ { print $3 }' | sed 's/\x1b\[[0-9;]*m//g'
}
for rust in $RENDERERS; do
  label="bash"; [ "$rust" = on ] && label="rust"
  mapfile -t GOT < <(live "$rust")
  [ "${GOT[0]-}" = "sleep 991 ∣ approve" ] \
    && report "$label: an @option only the user's file names is read from tmux" pass \
    || report "$label: an @option only the user's file names is read from tmux (got: '${GOT[0]-}')" fail
  [ "${GOT[1]-}" = "sleep 992 ∣ input ∣ Fix?it?really?now" ] \
    && report "$label: a plugin's state and a description, control bytes rewritten" pass \
    || report "$label: a plugin's state and a description, control bytes rewritten (got: '${GOT[1]-}')" fail
  [ "${GOT[2]-}" = "sleep 993 ∣ error ∣ from-user" ] \
    && report "$label: the first rule to give a state gives it; a later one still gives the description" pass \
    || report "$label: the first rule to give a state gives it; a later one still gives the description (got: '${GOT[2]-}')" fail
  [ "${#GOT[@]}" = 3 ] && report "$label: one row per window, none split by the value's newline" pass \
    || report "$label: one row per window, none split by the value's newline (got ${#GOT[@]})" fail
  [ ! -s "$TMPD/lerr.$rust" ] && report "$label: nothing on stderr" pass \
    || { report "$label: nothing on stderr" fail; ERRORS+="$(head -3 "$TMPD/lerr.$rust")"$'\n'; }
done

echo
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
