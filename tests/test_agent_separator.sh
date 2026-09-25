#!/usr/bin/env bash
#
# What sets the parts of an agent row apart -- @interdimux-agent-separator --
# in BOTH renderers, through the dump seam (INTERDIMUX_DUMP_IN: no server).
#
#   <command> ∣ <state> <age> ∣ <description>
#
#   * the default is ∣ (U+2223), drawn in the separator colour, with a blank
#     either side; a part that is not there takes its separator with it
#   * `off` joins the parts with a blank alone (the rows before the option)
#   * any other value up to three characters is used as it is (`·`, `::`)
#   * a longer value, or one with a control character, is replaced by the
#     default -- a separator lands inside a row
#   * an agent's kept arguments stay with its name (@interdimux-agent-args on)
#
# Expected rows are written out here, not computed by either renderer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-agentsep.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

echo "interdimux agent separator tests (both renderers, no server)"
echo

RENDERERS="off"
[ -x "$BIN" ] && RENDERERS="off on"
[ -x "$BIN" ] || echo "  (the Rust core is not built: only the bash renderer is checked)"

US=$'\x1f' RS=$'\x1e' GS=$'\x1d'
read -r -a ONAMES <<< "$(sed -n "s/^DEFAULT_STATE_OPTS='\(.*\)'\$/\1/p" "$SCRIPT")"
EMPTY=""; for _ in "${ONAMES[@]}"; do EMPTY+="$GS"; done
mkdir -p "$TMPD/home" "$TMPD/stub"
printf '#!/bin/sh\nexit 1\n' > "$TMPD/stub/tmux"; chmod +x "$TMPD/stub/tmux"

# One window each: an agent with a state, an age and a title (Claude's
# registry); an agent with arguments and a state and title from its own
# title; one with a title only; one with a state only; an app with a title
# a rule knows; and a plain command, which has nothing to set apart.
CMDS=("claude" "codex resume" "claude" "codex" "ssh web1" "make -j8")
TITLES=("✳ Fix the parser" "[ ! ] Action Required | Add tests | app" "✳ Tidy up" "⠋ x" "deploy@web1: ~/src" "make -j8")
{
  printf 'w%s1700000000%s%d%s%s/home/u\n%s\n' "$US" "$US" "${#CMDS[@]}" "$US" "$US" "$RS"
  for i in "${!CMDS[@]}"; do
    printf 'w%s%d%sw%d%s0%s%s%s/home/u%s1%s%d%s000\n' "$US" "$i" "$US" "$i" "$US" "$US" "${CMDS[i]}" "$US" "$US" "$US" $((4000 + i)) "$US"
  done
  printf '%s\n' "$RS"
  for i in "${!CMDS[@]}"; do
    printf 'w%s%d%s0%s1%s%s%s/home/u%s%d%s1%s%%%d%s%s%s%s\n' "$US" "$i" "$US" "$US" "$US" "${CMDS[i]}" "$US" "$US" $((4000 + i)) "$US" "$US" "$i" "$US" "${TITLES[i]}" "$US" "$EMPTY"
  done
  printf '%s\nw%s0%s0%shost%shost\n%s\n' "$RS" "$US" "$US" "$US" "$US" "$RS"
  printf '%%0%s4000%sworking%s1700086000\n' "$US" "$US" "$US"
} > "$TMPD/sep.dump"

# $1 = on|off (the Rust core), rest = VAR=value -> the window rows' command
# fields, colours kept (RAW) and stripped (ROWS)
render() {
  local r="$1"; shift
  RAW=$(env -i HOME="$TMPD/home" PATH="$TMPD/stub:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
          TMUX="$TMPD/no-server,1,0" INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
          INTERDIMUX_NOW=1700086400 INTERDIMUX_SHOW_FULL_COMMAND=off INTERDIMUX_SHOW_GIT_BRANCH=off \
          INTERDIMUX_SHOW_DIRS=off INTERDIMUX_ORDER=index INTERDIMUX_COLOR_SEPARATOR=245 \
          INTERDIMUX_USE_RUST="$r" INTERDIMUX_DUMP_IN="$TMPD/sep.dump" "$@" \
          bash "$SCRIPT" --list 2> "$TMPD/err" | awk -F'\t' '$4 ~ /^W:/ { print $3 }')
  ROWS=$(printf '%s\n' "$RAW" | sed 's/\x1b\[[0-9;]*m//g')
}
# $1 = label, $2 = the separator as drawn, rest = env
expect_rows() {
  local label="$1" s="$2"; shift 2
  local want
  want=$(printf '%s\n' \
    "claude${s}working 6m${s}Fix the parser" \
    "codex${s}approve${s}Add tests" \
    "claude${s}Tidy up" \
    "codex${s}working" \
    "ssh web1${s}deploy@web1: ~/src" \
    "make -j8")
  for rust in $RENDERERS; do
    local who=bash; [ "$rust" = on ] && who=rust
    render "$rust" "$@"
    if [ "$ROWS" = "$want" ] && [ ! -s "$TMPD/err" ]; then
      report "$who: $label" pass
    else
      report "$who: $label" fail
      ERRORS+="    got:"$'\n'"$(printf '%s\n' "$ROWS" | sed 's/^/      /')"$'\n'"$(head -2 "$TMPD/err")"$'\n'
    fi
  done
}

expect_rows "the default is ∣ between each part that is there" " ∣ "
expect_rows "off: a blank alone" " " INTERDIMUX_AGENT_SEPARATOR=off
expect_rows "a middle dot, as given" " · " INTERDIMUX_AGENT_SEPARATOR='·'
expect_rows "three characters, as given" " ::: " INTERDIMUX_AGENT_SEPARATOR=':::'
expect_rows "four characters: the default instead" " ∣ " INTERDIMUX_AGENT_SEPARATOR='::::'
expect_rows "a control character: the default instead" " ∣ " INTERDIMUX_AGENT_SEPARATOR=$'|\t|'

# Drawn in the separator colour, the column rule's (here 245), not the text's.
for rust in $RENDERERS; do
  who=bash; [ "$rust" = on ] && who=rust
  render "$rust"
  if [[ "$RAW" == *$' \e[38;5;245m∣\e[0m '* ]]; then
    report "$who: the separator is drawn in the separator colour" pass
  else
    report "$who: the separator is drawn in the separator colour" fail
    ERRORS+="    raw: $(printf '%s' "$RAW" | head -1 | cat -v)"$'\n'
  fi
done

# Kept arguments stay with the name, before the first separator.
for rust in $RENDERERS; do
  who=bash; [ "$rust" = on ] && who=rust
  render "$rust" INTERDIMUX_AGENT_ARGS=on
  got=$(printf '%s\n' "$ROWS" | sed -n 2p)
  [ "$got" = "codex resume ∣ approve ∣ Add tests" ] \
    && report "$who: @interdimux-agent-args on: the arguments stay with the name" pass \
    || report "$who: @interdimux-agent-args on: the arguments stay with the name (got: $got)" fail
done

echo
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
