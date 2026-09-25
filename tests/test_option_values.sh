#!/usr/bin/env bash
#
# Option values, as the script reads them and as --doctor reports them.
#
#   * a numeric option is the DECIMAL number it spells, whatever its leading
#     zeros, in both renderers (review R11).  bash arithmetic reads a leading 0
#     as octal: @interdimux-title-max 08 made the bash renderer's --list die
#     with "value too great for base" and draw nothing, 050 cut titles at forty
#     where the Rust core cut at fifty, and scan-depth 08 broke the directory
#     search the same way;
#   * --doctor names every value of the agent options that the script
#     replaces, and says what it is replaced with (review R10).  It gave all of
#     them a tick: `agent-args yes` silently stayed off, `show-title always`
#     became known, a word of @interdimux-agents the script skips was never
#     mentioned.  What it says is checked against the renderers themselves:
#     the bad value must draw exactly the rows of the value the report names.
#
# No server for the rows: the list comes from a dump (INTERDIMUX_DUMP_IN, the
# seam tests/test_corpus_parity.sh uses), with a tmux on PATH that logs and
# fails, and the directory search from a fixture HOME.  The expected rows are
# written out by hand: the first N-1 characters of the title and an ellipsis.
# --doctor runs against a private server (tmux -L), with a fake HOME.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-optvals.XXXXXX")" && pwd -P)"
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
# $1 = name, $2 = got, $3 = wanted
same() {
  if [ "$2" = "$3" ]; then report "$1" pass
  else report "$1" fail; ERRORS+="      wanted: [$3]"$'\n'"      got:    [$2]"$'\n'; fi
}

echo "interdimux option value tests"
echo

export LANG=C.UTF-8 LC_ALL=C.UTF-8

# --- a tmux that must never run ---------------------------------------------
mkdir -p "$TMPD/stub"
cat > "$TMPD/stub/tmux" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$TMPD/tmux-calls"
exit 1
STUB
chmod +x "$TMPD/stub/tmux"

# --- 1. @interdimux-title-max with leading zeros ------------------------------
# One codex pane whose title is an approval for an 82-character thread.
US=$'\x1f' RS=$'\x1e' GS=$'\x1d'
THREAD='Fix the login timeout that users hit after a long idle period on mobile browsers'
OPTS=""; for _ in 1 2 3 4 5 6 7 8 9 10; do OPTS+="$GS"; done
{
  printf 'work%s1700080000%s1%sattached%s/home/u\n' "$US" "$US" "$US" "$US"
  printf '%s\n' "$RS"
  printf 'work%s0%scodex%s1%scodex%s/home/u%s1%s1001%s000\n' "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US"
  printf '%s\n' "$RS"
  printf 'work%s0%s0%s1%scodex%s/home/u%s1001%s1%s%%1%s[ ! ] Action Required | %s | app%s%s\n' \
    "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$THREAD" "$US" "$OPTS"
  printf '%s\n' "$RS"
  printf 'work%s0%s0%shost%shost\n' "$US" "$US" "$US" "$US"
  printf '%s\n' "$RS"   # the registry section: no records
} > "$TMPD/codex.dump"

# $1 = @interdimux-title-max, $2 = on|off (the Rust core).  OUT: the window
# row's command field, colours stripped; RC; ERR: stderr.
render() {
  RC=0
  env -i HOME=/home/u PATH="$TMPD/stub:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      INTERDIMUX_NOW=1700086400 INTERDIMUX_SHOW_PREVIEW=off INTERDIMUX_SHOW_FULL_COMMAND=off \
      INTERDIMUX_SHOW_GIT_BRANCH=off INTERDIMUX_SHOW_DIRS=off \
      TMUX="$TMPD/no-server,1,0" INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
      FZF_COLUMNS=200 INTERDIMUX_USE_RUST="$2" INTERDIMUX_DUMP_IN="$TMPD/codex.dump" \
      INTERDIMUX_TITLE_MAX="$1" bash "$SCRIPT" --list > "$TMPD/out" 2> "$TMPD/err" || RC=$?
  ERR=$(cat "$TMPD/err")
  OUT=$(sed 's/\x1b\[[0-9;]*m//g' "$TMPD/out" | awk -F'\t' '$4 ~ /^W:/ { print $3 }')
}

renderers=(off)
if [ -x "$BIN" ]; then renderers+=(on); else echo "  (rust binary not built: the Rust renderer's cases are skipped)"; fi

# value | what the row must say
cases=(
  "8|codex approve Fix the…"
  "08|codex approve Fix the…"
  "09|codex approve Fix the …"
  "000|codex approve Fix the…"
  "40|codex approve Fix the login timeout that users hit af…"
  "040|codex approve Fix the login timeout that users hit af…"
  "0040|codex approve Fix the login timeout that users hit af…"
  "050|codex approve Fix the login timeout that users hit after a long…"
  "0000000000000000000050|codex approve Fix the login timeout that users hit after a long…"
)
for r in "${renderers[@]}"; do
  label=bash; [ "$r" = on ] && label=rust
  for c in "${cases[@]}"; do
    v="${c%%|*}" want="${c#*|}"
    render "$v" "$r"
    if [ "$RC" = 0 ] && [ -z "$ERR" ]; then
      same "$label, title-max $v: cut where the decimal number says" "$OUT" "$want"
    else
      report "$label, title-max $v: renders (exit 0, nothing on stderr)" fail
      ERRORS+="      rc=$RC stderr: ${ERR:0:300}"$'\n'
    fi
  done
done

# The binary on its own, handed a value bash did not normalise (the golden
# tests do this): it must read it exactly as bash would have.
if [ -x "$BIN" ]; then
  RULESET=$(awk "/^DEFAULT_TITLE_RULES='/ { on = 1; sub(/^DEFAULT_TITLE_RULES='/, \"\"); print; next }
                 on && /^'\$/ { exit } on { print }" "$SCRIPT")
  STATE_OPTS=$(sed -n "s/^DEFAULT_STATE_OPTS='\\(.*\\)'\$/\\1/p" "$SCRIPT")
  for c in "0040|codex approve Fix the login timeout that users hit af…" \
           "99999999999999999999999|codex approve $THREAD"; do
    v="${c%%|*}" want="${c#*|}"
    got=$(env -i HOME=/home/u LANG=C.UTF-8 LC_ALL=C.UTF-8 INTERDIMUX_NOW=1700086400 \
            INTERDIMUX_COLS=200 INTERDIMUX_SHOW_FULL_COMMAND=off INTERDIMUX_SHOW_GIT_BRANCH=off \
            INTERDIMUX_SHOW_DIRS=off INTERDIMUX_TITLE_RULESET="$RULESET" INTERDIMUX_STATE_OPTS="$STATE_OPTS" \
            INTERDIMUX_TITLE_MAX="$v" "$BIN" gather3 < "$TMPD/codex.dump" 2>/dev/null \
          | sed 's/\x1b\[[0-9;]*m//g' | awk -F'\t' '$4 ~ /^W:/ { print $3 }')
    same "imux alone, INTERDIMUX_TITLE_MAX=$v: read as bash reads it" "$got" "$want"
  done
fi

if [ -s "$TMPD/tmux-calls" ]; then
  report "no render reached a tmux server" fail
else
  report "no render reached a tmux server" pass
fi

# --- 2. @interdimux-scan-depth with leading zeros -----------------------------
# The name search goes twice the scan depth deep, in arithmetic: 08 was "value
# too great for base" (nothing found), and 010 went 16 deep instead of 20.
FH="$TMPD/home"
mkdir -p "$FH/work/a/b/c/needle_dir" "$FH/.local/share"
deep="$FH/work"; for i in $(seq 1 17); do deep+="/d$i"; done
mkdir -p "$deep/haystack_dir"   # 18 below the search path
dirs_list() { # $1 = scan depth, $2 = query -> OUT: the paths; ERR
  env -i PATH="$TMPD/stub:$PATH" HOME="$FH" XDG_DATA_HOME="$FH/.local/share" TMUX="$TMPD/no-server,0,0" \
      INTERDIMUX_PROJECT_DIRS="$FH/work" INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SCAN_DEPTH="$1" \
      bash "$SCRIPT" --dirs-list --deep "$2" > "$TMPD/out" 2> "$TMPD/err" || true
  ERR=$(cat "$TMPD/err")
  OUT=$(sed 's/\x1b\[[0-9;]*m//g' "$TMPD/out" | cut -f3)
}
dirs_list 08 needle
same "scan-depth 08: the name search runs (nothing on stderr)" "$ERR" ""
same "...and finds the directory it finds at 8" "$OUT" "$FH/work/a/b/c/needle_dir"
dirs_list 010 haystack
same "scan-depth 010 searches 20 deep, as 10 does (not 16)" "$OUT" "$deep/haystack_dir"
dirs_list 8 haystack
same "...where 8 (16 deep) does not reach" "$OUT" ""

# --- 3. --doctor names what the script replaces ------------------------------
# A dump with one row per option: a codex pane with an argument and an approval
# title (agent-state, agent-args, title-max), a sleep with a title no rule knows
# (show-title), and a program named only by @interdimux-agents (agents).
{
  printf 'work%s1700080000%s3%sattached%s/home/u\n' "$US" "$US" "$US" "$US"
  printf '%s\n' "$RS"
  printf 'work%s0%scodex%s1%scodex resume%s/home/u%s1%s1001%s000\n' "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US"
  printf 'work%s1%snotes%s0%ssleep%s/home/u%s1%s1002%s000\n' "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US"
  printf 'work%s2%smine%s0%smyagent%s/home/u%s1%s1003%s000\n' "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US"
  printf '%s\n' "$RS"
  printf 'work%s0%s0%s1%scodex resume%s/home/u%s1001%s1%s%%1%s[ ! ] Action Required | %s | app%s%s\n' \
    "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$THREAD" "$US" "$OPTS"
  printf 'work%s1%s0%s1%ssleep%s/home/u%s1002%s1%s%%2%sQuarterly numbers%s%s\n' \
    "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$OPTS"
  printf 'work%s2%s0%s1%smyagent%s/home/u%s1003%s1%s%%3%shello there%s%s\n' \
    "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$OPTS"
  printf '%s\n' "$RS"
  printf 'work%s0%s0%shost%shost\n' "$US" "$US" "$US" "$US"
  printf '%s\n' "$RS"
} > "$TMPD/opts.dump"
# $1 = renderer (on|off), then VAR=value pairs -> stdout: every command field
rows() {
  local r="$1"; shift
  env -i HOME=/home/u PATH="$TMPD/stub:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      INTERDIMUX_NOW=1700086400 INTERDIMUX_SHOW_PREVIEW=off INTERDIMUX_SHOW_FULL_COMMAND=off \
      INTERDIMUX_SHOW_GIT_BRANCH=off INTERDIMUX_SHOW_DIRS=off \
      TMUX="$TMPD/no-server,1,0" INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
      FZF_COLUMNS=200 INTERDIMUX_USE_RUST="$r" INTERDIMUX_DUMP_IN="$TMPD/opts.dump" "$@" \
      bash "$SCRIPT" --list 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | cut -f3
}

SOCK="interdimux-optvals-test-$$"
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMPD"; }
unset TMUX TMUX_PANE FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE CLAUDE_CONFIG_DIR CODEX_HOME \
      INTERDIMUX_CLAUDE_DIR INTERDIMUX_TITLE_RULES INTERDIMUX_AGENT_STATE INTERDIMUX_AGENT_ARGS \
      INTERDIMUX_AGENTS INTERDIMUX_SHOW_TITLE INTERDIMUX_TITLE_MAX INTERDIMUX_SCAN_DEPTH XDG_CONFIG_HOME
export HOME="$TMPD/dhome" XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
mkdir -p "$HOME"
tmux -f /dev/null -L "$SOCK" new-session -d -s optvals -x 120 -y 40
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_AT_DAEMON=up
setopt()   { tmux -L "$SOCK" set -g "@interdimux-$1" "$2"; }
unsetopt() { tmux -L "$SOCK" set -gu "@interdimux-$1" 2>/dev/null || true; }
# the report's line for @interdimux-$1, colours stripped
doctor_line() {
  timeout 60 bash "$SCRIPT" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -F "@interdimux-$1 = " || true
}

# option | bad value | the value it acts as | what the report says | a value it must NOT act as
bad=(
  "show-title|always|known|expected 'known', 'all' or 'off', so it stays known|all"
  "agent-state|yes|on|expected 'on' or 'off', so it stays on|off"
  "agent-args|yes|off|expected 'on' or 'off', so it stays off|on"
  "title-max|300|200|the most is 200, so 200 applies|40"
  "title-max|1000|200|the most is 200, so 200 applies|40"
  "title-max|5|8|the least is 8, so 8 applies|40"
  "title-max|4O|40|expected a whole number from 8 to 200, so the default, 40, applies|200"
  "agents|my/agent myagent|myagent|skipped: 'my/agent' (a name is letters, digits, dots, underscores and hyphens)|"
)
for c in "${bad[@]}"; do
  IFS='|' read -r o v eff why other <<< "$c"
  var="INTERDIMUX_$(printf '%s' "$o" | tr 'a-z-' 'A-Z_')"
  setopt "$o" "$v"
  same "doctor: @interdimux-$o '$v' is named, with what applies" "$(doctor_line "$o")" \
       "  ✗ @interdimux-$o = '$v' — $why"
  unsetopt "$o"
  for r in "${renderers[@]}"; do
    label=bash; [ "$r" = on ] && label=rust
    got=$(rows "$r" "$var=$v") want=$(rows "$r" "$var=$eff") not=$(rows "$r" "$var=$other")
    same "...$label draws '$v' exactly as '$eff'" "$got" "$want"
    if [ "$want" != "$not" ]; then
      report "...which the rows tell from '$other'" pass
    else
      report "...which the rows tell from '$other'" fail
    fi
  done
done

# Values the script takes as they are get a tick.  08 is eight now (R11).
good=(
  "title-max|08" "title-max|200" "show-title|all" "agent-state|off" "agent-args|on"
  "agents|myagent claude-x" "agents|off" "scan-depth|010"
)
for c in "${good[@]}"; do
  o="${c%%|*}" v="${c#*|}"
  setopt "$o" "$v"
  same "doctor: @interdimux-$o '$v' is fine" "$(doctor_line "$o")" "  ✓ @interdimux-$o = '$v'"
  unsetopt "$o"
done
for v in 011 99999999999999999999; do
  setopt scan-depth "$v"
  same "doctor: scan-depth $v is too deep (as a decimal number, with no error)" "$(doctor_line scan-depth)" \
       "  ✗ @interdimux-scan-depth = '$v' — deeper than 10 will not finish inside a popup"
  unsetopt scan-depth
done

echo
if [ -n "$ERRORS" ]; then printf '%s' "$ERRORS"; echo; fi
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
