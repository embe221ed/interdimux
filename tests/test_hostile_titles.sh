#!/usr/bin/env bash
#
# Pane titles are chosen by the program in the pane -- over ssh, from a
# container, from `cat` of a file -- so the title code has to hold up against
# any of them, in BOTH renderers (review R01):
#
#   * the Rust matcher captures exactly what bash's ERE does: a seeded random
#     set of patterns and titles, each through both renderers
#   * a title that almost matches the default remote-shell rule
#     (`*:*:* - "*"*`, 2,000 colons) renders in both, within a budget: the
#     backtracking matcher took 12 s on half of it
#
# Expected rows are written out, not computed by either renderer; where the
# case is random the two renderers are each other's oracle -- bash matches with
# glibc's ERE, the Rust core with its own code.  Everything goes through the
# dump seam (INTERDIMUX_DUMP_IN): no server, no timing but the budgets.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-hostile.XXXXXX")" && pwd -P)"
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

echo "interdimux hostile title tests"
echo

RENDERERS="off"
[ -x "$BIN" ] && RENDERERS="off on"
[ -x "$BIN" ] || echo "  (the Rust core is not built: only the bash renderer is checked)"

US=$'\x1f' RS=$'\x1e' GS=$'\x1d'
NOPTS=$(sed -n "s/^DEFAULT_STATE_OPTS='\(.*\)'\$/\1/p" "$SCRIPT" | wc -w)
EMPTY_OPTS=$(printf "${GS}%.0s" $(seq "$NOPTS"))

# A dump of one session whose window N runs app N with title N, one pane each:
# the window row is the case.  $1 the file, then "app|title" per window.  A
# pane's options are $OPTS when set (one value per DEFAULT_STATE_OPTS name,
# each ended by GS), else none.
mkdump() {
  local out="$1" i=0 c
  shift
  {
    printf 's%s1700000000%s%s%s%s/tmp\n%s\n' "$US" "$US" "$#" "$US" "$US" "$RS"
    for c in "$@"; do
      printf 's%s%d%sw%d%s0%s%s%s/tmp%s1%s%d%s000\n' "$US" "$i" "$US" "$i" "$US" "$US" "${c%%|*}" "$US" "$US" "$US" $((1000 + i)) "$US"
      i=$((i + 1))
    done
    printf '%s\n' "$RS"
    i=0
    for c in "$@"; do
      printf 's%s%d%s0%s1%s%s%s/tmp%s%d%s1%s%%%d%s%s%s%s\n' "$US" "$i" "$US" "$US" "$US" "${c%%|*}" "$US" "$US" $((1000 + i)) "$US" "$US" "$i" "$US" "${c#*|}" "$US" "${OPTS:-$EMPTY_OPTS}"
      i=$((i + 1))
    done
    printf '%s\ns%s0%s0%shost.example%shost\n%s\n' "$RS" "$US" "$US" "$US" "$US" "$RS"
  } > "$out"
}

mkdir -p "$TMPD/home" "$TMPD/stub"
printf '#!/bin/sh\nexit 1\n' > "$TMPD/stub/tmux"; chmod +x "$TMPD/stub/tmux"
# The window rows' command column, colours stripped, into GOT (one per row).
# $1 on|off, $2 the dump, $3 the budget in seconds; RC is 124 when it ran
# out.  The rules file is ~/titles.  Extra environment after them.
RC=0 GOT=()
render() {
  local r="$1" dump="$2" budget="$3"
  shift 3
  RC=0
  env -i HOME="$TMPD/home" PATH="$TMPD/stub:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    TMUX="$TMPD/no-server,1,0" INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
    INTERDIMUX_NOW=1700086400 INTERDIMUX_SHOW_FULL_COMMAND=off INTERDIMUX_SHOW_GIT_BRANCH=off \
    INTERDIMUX_SHOW_DIRS=off INTERDIMUX_ORDER=index INTERDIMUX_USE_RUST="$r" INTERDIMUX_TITLE_MAX=200 \
    INTERDIMUX_TITLE_RULES='~/titles' INTERDIMUX_DUMP_IN="$dump" "$@" \
    timeout "$budget" bash "$SCRIPT" --list > "$TMPD/out" 2> "$TMPD/err" || RC=$?
  awk -F'\t' '$4 ~ /^W:/ { print $3 }' "$TMPD/out" | sed 's/\x1b\[[0-9;]*m//g' > "$TMPD/rows"
  mapfile -t GOT < "$TMPD/rows"
}
label() { if [ "$1" = on ]; then echo rust; else echo bash; fi; }

# --- 1. the matcher: Rust against bash's ERE, seeded random cases ----------
# App m<N> has one rule, m<N> - <$1|$2|$3|$4> PATTERN, so its row shows every
# capture.  Small alphabet (so pieces recur in the titles, where a placement
# can go wrong), multibyte in it; half the titles are built from the pattern's
# own pieces, so that many match.
RANDOM=4242
ALPHA=(a b : ' ' é 中 -)
rtext() { # $1 = longest; REPLY
  local n=$(( RANDOM % ($1 + 1) )) i
  REPLY=""
  for (( i = 0; i < n; i++ )); do REPLY+="${ALPHA[RANDOM % ${#ALPHA[@]}]}"; done
}
NCASE=300
: > "$TMPD/home/titles"
CASES=()
for (( k = 0; k < NCASE; k++ )); do
  stars=$(( RANDOM % 5 )) pat="" title="" pieces=()
  for (( j = 0; j <= stars; j++ )); do rtext 2; pieces+=("$REPLY"); done
  for (( j = 0; j <= stars; j++ )); do
    [ "$j" -gt 0 ] && pat+='*'
    pat+="${pieces[j]}"
  done
  # a pattern of blanks alone is no rule at all: give it a star
  [[ "$pat" == *[!\ ]* ]] || pat="*$pat"
  if (( RANDOM % 2 )); then
    rtext 12; title="$REPLY"
  else
    for (( j = 0; j <= stars; j++ )); do
      if [ "$j" -gt 0 ]; then rtext 4; title+="$REPLY"; fi
      title+="${pieces[j]}"
    done
  fi
  printf 'm%d  -  <$1|$2|$3|$4>  %s\n' "$k" "$pat" >> "$TMPD/home/titles"
  CASES+=("m$k|$title")
done
mkdump "$TMPD/random.dump" "${CASES[@]}"
if [ -x "$BIN" ]; then
  render off "$TMPD/random.dump" 60; cp "$TMPD/rows" "$TMPD/random.bash"
  render on "$TMPD/random.dump" 60; cp "$TMPD/rows" "$TMPD/random.rust"
  nb=$(wc -l < "$TMPD/random.bash") nr=$(wc -l < "$TMPD/random.rust")
  hits=$(grep -c '<' "$TMPD/random.bash" || true)
  if [ "$nb" = "$NCASE" ] && [ "$nr" = "$NCASE" ] && cmp -s "$TMPD/random.bash" "$TMPD/random.rust"; then
    report "the Rust matcher captures what bash's ERE does, in $NCASE random cases ($hits match)" pass
  else
    report "the Rust matcher captures what bash's ERE does, in $NCASE random cases" fail
    ERRORS+="$(diff "$TMPD/random.bash" "$TMPD/random.rust" | head -6)"$'\n'
    ERRORS+="     (rows: bash $nb, rust $nr, of $NCASE)"$'\n'
  fi
  # the comparison is only as good as its matches
  [ "$hits" -gt $(( NCASE / 5 )) ] && report "...and enough of them match to mean something" pass \
    || report "...and enough of them match to mean something ($hits of $NCASE)" fail
fi

# --- 2. a title that almost matches the remote-shell rule ------------------
# `ssh` has the default rule *:*:* - "*"*: 2,000 colons and no ` - "`.  No
# rule matches, so the row is the command alone.
: > "$TMPD/home/titles"
colons=$(printf 'a:%.0s' $(seq 2000))
mkdump "$TMPD/colons.dump" "ssh web1|$colons" "ssh web2|deploy@web2: ~/app"
for r in $RENDERERS; do
  render "$r" "$TMPD/colons.dump" 10
  if [ "$RC" = 0 ] && [ "${GOT[0]-}" = "ssh web1" ] && [ "${GOT[1]-}" = "ssh web2 deploy@web2: ~/app" ]; then
    report "$(label "$r"): 2,000 colons against the remote-shell rule render within 10 s" pass
  else
    report "$(label "$r"): 2,000 colons against the remote-shell rule render within 10 s (rc $RC, got: '${GOT[0]-}' / '${GOT[1]-}')" fail
  fi
done

echo
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
