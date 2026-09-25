#!/usr/bin/env bash
#
# Pane titles are chosen by the program in the pane -- over ssh, from a
# container, from `cat` of a file -- so the title code has to hold up against
# any of them, in BOTH renderers (review R01, R13):
#
#   * the Rust matcher captures exactly what bash's ERE does: a seeded random
#     set of patterns and titles, each through both renderers
#   * a title that almost matches the default remote-shell rule
#     (`*:*:* - "*"*`, 2,000 colons) renders in both, within a budget: the
#     backtracking matcher took 12 s on half of it
#   * a rule reads a title's first 256 characters, and not the 257th: counted
#     in characters, so width and bytes change nothing, and zero-width
#     characters are counted too
#   * a 100,000-character title costs the bash renderer well under its budget
#     (the window row split it with ${x#*"$US"}: quadratic, 90 s at 1 MB)
#   * cleaning is linear too: a description of 20,000 C1 controls, or padded
#     with 30,000 blanks each side, renders within its budget (the bash
#     control-character loop and blank trims were quadratic: minutes)
#   * prefix+g's count, which always runs in bash, with a codex pane whose
#     title is 5,000 é and a U+0085: it took 4.3 s, live
#   * a rules file with a line that is not UTF-8 (review R02): only that line
#     is dropped, in both renderers -- the Rust core used to get an EMPTY rule
#     set, every built-in rule gone -- and the core drops such a line itself
#     if one reaches it; --doctor names the line, and a NUL (UTF-16)
#
# Expected rows are written out, not computed by either renderer; where the
# case is random the two renderers are each other's oracle -- bash matches with
# glibc's ERE, the Rust core with its own code.  Everything but the last case
# goes through the dump seam (INTERDIMUX_DUMP_IN): no server, no timing but the
# budgets.  The last runs on a private server, never the user's.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-hostile-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-hostile.XXXXXX")" && pwd -P)"
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

# --- 3. the rules read a title's first 256 characters -----------------------
printf '%s\n' 'capt  -  hit  *Z' 'capz  -  hit  Z*' > "$TMPD/home/titles"
rep() { printf "$1%.0s" $(seq "$2"); }
mkdump "$TMPD/cap.dump" \
  "capt|$(rep a 255)Z" \
  "capt|$(rep a 256)Z" \
  "capt|$(rep é 255)Z" \
  "capt|$(rep 中 255)Z" \
  "capt|$(rep $'\xe2\x80\x8b' 255)Z" \
  "capt|$(rep $'\xe2\x80\x8b' 256)Z" \
  "capz|Z$(rep $'\xe2\x80\x8b' 5000) tail"
CAP_EXPECT=('capt hit' 'capt' 'capt hit' 'capt hit' 'capt hit' 'capt' 'capz hit')
CAP_WHAT=(
  "the 256th character is read"
  "...the 257th is not"
  "characters, not bytes (é is two)"
  "characters, not cells (中 is two)"
  "zero-width characters count (U+200B)"
  "...to the same 256"
  "a title cut in the middle still matches a rule for its head"
)
for r in $RENDERERS; do
  render "$r" "$TMPD/cap.dump" 20
  for i in "${!CAP_EXPECT[@]}"; do
    [ "${GOT[i]-}" = "${CAP_EXPECT[i]}" ] && report "$(label "$r"): ${CAP_WHAT[i]}" pass \
      || report "$(label "$r"): ${CAP_WHAT[i]} (got: '${GOT[i]-}', want: '${CAP_EXPECT[i]}')" fail
  done
done

# --- 4. a 100,000-character title --------------------------------------------
# What a program can set (tmux keeps an OSC title of up to 1 MB), through the
# whole bash renderer.  The window row's old split ran past the budget on it
# (40,000 characters cost 1.6 s, 1 MB 90 s).
printf '%s\n' 'capz  -  hit  Z*' > "$TMPD/home/titles"
mkdump "$TMPD/long.dump" "capz|Z$(rep $'\xe2\x80\x8b' 100000)"
for r in $RENDERERS; do
  render "$r" "$TMPD/long.dump" 3
  [ "$RC" = 0 ] && [ "${GOT[0]-}" = "capz hit" ] \
    && report "$(label "$r"): a 100,000-character title renders within 3 s" pass \
    || report "$(label "$r"): a 100,000-character title renders within 3 s (rc $RC, got: '${GOT[0]-}')" fail
done

# --- 5. cleaning a description is linear ---------------------------------------
# Through a published option, which carries what a title carries and is not
# cut at 256: tmux caps an option value at 128 CELLS, so zero-width
# characters -- a C1 control is one -- pass it in any number.  The row's
# description is the value with each control made '?' and its blanks trimmed.
: > "$TMPD/home/titles"
read -r -a OPT_NAMES <<< "$(sed -n "s/^DEFAULT_STATE_OPTS='\(.*\)'\$/\1/p" "$SCRIPT")"
opt_values() { # name=value ...; OPTS
  local n kv v
  OPTS=""
  for n in "${OPT_NAMES[@]}"; do
    v=""
    for kv in "$@"; do [ "${kv%%=*}" = "$n" ] && v="${kv#*=}"; done
    OPTS+="$v$GS"
  done
}
opt_values "agent_desc=Fix$(rep $'\xc2\x85' 20000)it"
mkdump "$TMPD/c1.dump" "sleep|"
opt_values "agent_desc=$(rep ' ' 30000)Fix it$(rep ' ' 30000)"
mkdump "$TMPD/pad.dump" "sleep|"
OPTS=""
want_c1="sleep Fix$(rep '?' 196)…"
got0() { local g="${GOT[0]-}"; printf '%s' "${g:0:40}"; }
for r in $RENDERERS; do
  render "$r" "$TMPD/c1.dump" 3
  [ "$RC" = 0 ] && [ "${GOT[0]-}" = "$want_c1" ] \
    && report "$(label "$r"): 20,000 C1 controls in a description are made '?' within 3 s" pass \
    || report "$(label "$r"): 20,000 C1 controls in a description are made '?' within 3 s (rc $RC, got: '$(got0)')" fail
  render "$r" "$TMPD/pad.dump" 3
  [ "$RC" = 0 ] && [ "${GOT[0]-}" = "sleep Fix it" ] \
    && report "$(label "$r"): 30,000 blanks either side of a description are trimmed within 3 s" pass \
    || report "$(label "$r"): 30,000 blanks either side of a description are trimmed within 3 s (rc $RC, got: '$(got0)')" fail
done

# --- 6. prefix+g's count, live ------------------------------------------------
# The count always runs in bash, whichever renderer draws the rows.  A codex
# pane titles itself by OSC 2, as codex does, with an approval waiting and a
# thread name of 5,000 é and a U+0085.  No client is attached, so the
# dashboard takes its fzf fallback; the fzf here is a stand-in that keeps the
# menu it is given.
if [ -r /proc/self/stat ]; then
  cat > "$TMPD/codex" <<'EOF_AGENT'
#!/usr/bin/env bash
t=$(printf 'é%.0s' $(seq 5000))
printf '\033]2;[ ! ] Action Required | %s\302\205 | proj\007' "$t"
exec -a codex timeout 991 sleep 991
EOF_AGENT
  mkdir -p "$TMPD/bin"
  cat > "$TMPD/bin/fzf" <<'EOF_FZF'
#!/bin/sh
case "$1" in --version) echo "0.74.0 (stand-in)"; exit 0 ;; esac
cat > "$FZF_IN"
exit 130
EOF_FZF
  chmod +x "$TMPD/codex" "$TMPD/bin/fzf"
  unset TMUX TMUX_PANE
  tmux -f /dev/null -L "$SOCK" new-session -d -s agents -x 120 -y 30 -c "$TMPD" "exec '$TMPD/codex'"
  for _ in $(seq 1 100); do
    case "$(tmux -L "$SOCK" display-message -p -t '=agents:' '#{pane_title}')" in '[ ! ]'*) break ;; esac
    sleep 0.05
  done
  RC=0
  env TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0" \
    TMUX_PANE="$(tmux -L "$SOCK" display-message -p -t '=agents:' '#{pane_id}')" \
    HOME="$TMPD/home" XDG_CONFIG_HOME="$TMPD/xdg" XDG_STATE_HOME="$TMPD/state" \
    INTERDIMUX_CLAUDE_DIR="$TMPD/noclaude" INTERDIMUX_TITLE_RULES="$TMPD/none" \
    FZF_IN="$TMPD/menu" PATH="$TMPD/bin:$PATH" \
    timeout 3 bash "$SCRIPT" --dashboard > /dev/null 2>&1 || RC=$?
  if [ "$RC" != 124 ] && grep -q '1 agent needs you' "$TMPD/menu" 2>/dev/null; then
    report "prefix+g counts a codex pane with a 5,000-character title within 3 s" pass
  else
    report "prefix+g counts a codex pane with a 5,000-character title within 3 s (rc $RC)" fail
    ERRORS+="$(grep -a -o 'gents[^\t]*' "$TMPD/menu" 2>/dev/null | head -2)"$'\n'
  fi
  tmux -L "$SOCK" kill-server 2>/dev/null || true
else
  echo "  (skipped the live count: no /proc)"
fi

# --- 7. a rules file that is not all UTF-8 -------------------------------------
# A Latin-1 comment, a good rule of the user's, and a Latin-1 rule.  The
# built-in rules stay (codex's approval, ssh's prompt), the good line stays,
# and the Latin-1 rule alone is gone: bar's title is then no rule's, so hidden.
printf '# caf\xe9 rules\nfoo  -  =  *\nbar  -  caf\xe9:$1  x*\n' > "$TMPD/home/titles"
mkdump "$TMPD/latin1.dump" "codex|[ ! ] Action Required | Add tests | app" \
  "ssh web1|deploy@web1: ~/app" "foo|hello" "bar|xyz"
L1_EXPECT=('codex approve Add tests' 'ssh web1 deploy@web1: ~/app' 'foo hello' 'bar')
for r in $RENDERERS; do
  render "$r" "$TMPD/latin1.dump" 20
  if [ "${GOT[*]-}" = "${L1_EXPECT[*]}" ]; then
    report "$(label "$r"): a Latin-1 line in the rules file drops that line, and only it" pass
  else
    report "$(label "$r"): a Latin-1 line in the rules file drops that line, and only it" fail
    ERRORS+="     got:  $(printf '[%s] ' "${GOT[@]}")"$'\n'"     want: $(printf '[%s] ' "${L1_EXPECT[@]}")"$'\n'
  fi
done
# In a C locale too, where bash's own regexes would take the Latin-1 rule
# whole (in UTF-8 they happen to fail on the byte): the row is the Rust
# core's in every locale.
render off "$TMPD/latin1.dump" 20 LANG=C LC_ALL=C
[ "${GOT[3]-}" = "bar" ] \
  && report "bash: ...in a C locale too" pass \
  || report "bash: ...in a C locale too (got: '${GOT[3]-}')" fail
# The core's own guard: the rule text handed to it directly, a Latin-1 line in
# front of the built-in rules, as nothing in bash would pass it any more.
if [ -x "$BIN" ]; then
  defaults=$(awk "/^DEFAULT_TITLE_RULES='/ { on = 1; next } on && /^'\$/ { exit } on" "$SCRIPT")
  proto=$(sed -n 's/^IMUX_PROTO=//p' "$SCRIPT")
  got=$(env -i INTERDIMUX_TITLE_RULESET="$(printf 'bar  -  caf\xe9:$1  x*')"$'\n'"$defaults" \
          INTERDIMUX_STATE_OPTS="$(printf '%s ' "${OPT_NAMES[@]}")" INTERDIMUX_COLS=200 \
          "$BIN" "$proto" < "$TMPD/latin1.dump" 2>/dev/null \
        | awk -F'\t' '$4 ~ /^W:/ { print $3 }' | sed 's/\x1b\[[0-9;]*m//g' | head -2 | tr '\n' '|')
  [ "$got" = "codex approve Add tests|ssh web1 deploy@web1: ~/app|" ] \
    && report "rust: the core itself drops a rule line that is not UTF-8, and keeps the rest" pass \
    || report "rust: the core itself drops a rule line that is not UTF-8, and keeps the rest (got: '$got')" fail
fi
# --doctor, on a private server: the Latin-1 rule is named by its line, the
# comment is not (dropping it changes nothing), and one rule is counted.
unset TMUX TMUX_PANE
tmux -f /dev/null -L "$SOCK" new-session -d -s doc -x 120 -y 30 -c "$TMPD" 'exec sleep 990'
doctor_agents() {
  env TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0" \
    TMUX_PANE="$(tmux -L "$SOCK" display-message -p -t '=doc:' '#{pane_id}')" \
    HOME="$TMPD/home" XDG_CONFIG_HOME="$TMPD/xdg" XDG_STATE_HOME="$TMPD/state" XDG_DATA_HOME="$TMPD/data" \
    INTERDIMUX_CLAUDE_DIR="$TMPD/noclaude" INTERDIMUX_TITLE_RULES="$1" INTERDIMUX_AT_DAEMON=up \
    timeout 60 bash "$SCRIPT" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g' \
    | awk '/^agents / { f = 1; next } /^[^ ]/ { f = 0 } f'
}
out=$(doctor_agents "$TMPD/home/titles") || :   # --doctor exits 1 on any ✗ elsewhere
case "$out" in *"line 3 is not UTF-8"*) report "--doctor names the rule line that is not UTF-8" pass ;;
  *) report "--doctor names the rule line that is not UTF-8" fail; ERRORS+="$(printf '%s\n' "$out" | grep -i -A3 'title rules' | head -6)"$'\n' ;; esac
case "$out" in *"line 1 is not"*) report "...and not the comment (dropping it changes nothing)" fail ;;
  *) report "...and not the comment (dropping it changes nothing)" pass ;; esac
case "$out" in *"holds 1 rule,"*) report "...and counts the one rule that is read" pass ;;
  *) report "...and counts the one rule that is read" fail ;; esac
# UTF-16 (little-endian, with its BOM): bash reads up to the first NUL.
printf '\xff\xfef\0o\0o\0 \0-\0 \0=\0 \0*\0\n\0' > "$TMPD/utf16"
out=$(doctor_agents "$TMPD/utf16") || :
case "$out" in *"holds a NUL byte"*"line 1 is not UTF-8"*|*"line 1 is not UTF-8"*"holds a NUL byte"*)
    report "--doctor says a UTF-16 file holds a NUL, and that what is read of it is not UTF-8" pass ;;
  *) report "--doctor says a UTF-16 file holds a NUL, and that what is read of it is not UTF-8" fail
     ERRORS+="$(printf '%s\n' "$out" | grep -i -A3 'title rules' | head -6)"$'\n' ;; esac
tmux -L "$SOCK" kill-server 2>/dev/null || true

echo
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
