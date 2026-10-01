#!/usr/bin/env bash
#
# --agents: the agent panes and their merged state, for a status line or a
# script (review AGENT-09).
#
#   * one line per agent pane, tab-separated: pane id, target, agent, state,
#     since, description -- with the state Claude's registry gives, which no
#     tmux format can see, merged with the published options and the titles
#     as the rows merge them;
#   * most urgent first (approve, input, error, done, working, idle), and
#     within a state the one in it longest first -- whatever order tmux lists
#     the panes in: the oldest approval here is in the session listed LAST;
#   * each pane once, though a session group lists it again, and none from a
#     session @interdimux-hide keeps out of the navigator;
#   * --count prints how many, STATES keeps only those (through the
#     dashboard's shortcuts for approve and input, through every pane for the
#     rest), a word that is no state is refused with exit 2;
#   * a server with no agent prints nothing and exits 0, and --count says 0;
#   * no fzf is needed (a status line runs it from the server's PATH), and
#     bash 4.3 -- the floor -- gives the same lines when it is there
#     (INTERDIMUX_OLD_BASH_DIR, as tests/test_bash_floor.sh).
#
# The agents are fakes: `exec -a <name> sleep`, a title set with printf, pane
# options set with tmux, and Claude's registry a directory of records written
# here (INTERDIMUX_CLAUDE_DIR), never ~/.claude.  Expected lines are written
# out here; the pane ids and window indexes in them are tmux's own.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-agentslist-test-$$"
EMPTY="$SOCK-empty"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-agentslist.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  tmux -L "$EMPTY" kill-server 2>/dev/null || true
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$EMPTY"
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
# $1 = what, $2 = got, $3 = want
same() {
  if [ "$2" = "$3" ]; then report "$1" pass
  else
    report "$1" fail
    ERRORS+="    got:"$'\n'"$(printf '%s\n' "$2" | cat -A | sed 's/^/      /')"$'\n'
    ERRORS+="    want:"$'\n'"$(printf '%s\n' "$3" | cat -A | sed 's/^/      /')"$'\n'
  fi
}

echo "interdimux --agents tests"
echo

if [ ! -r /proc/self/stat ]; then
  echo "  (skipped: needs /proc for the registry's pid check)"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

unset TMUX TMUX_PANE
export LC_ALL=C.UTF-8 LANG=C.UTF-8
export XDG_CONFIG_HOME="$TMPD/config" XDG_STATE_HOME="$TMPD/state" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_CLAUDE_DIR="$TMPD/claude-home"
mkdir -p "$INTERDIMUX_CLAUDE_DIR/sessions"

mk() { # name, title (no single quote), argv0, seconds
  cat > "$TMPD/$1" <<EOF
#!/usr/bin/env bash
printf '\\033]0;%s\\007' '$2'
exec -a '$3' sleep $4
EOF
  chmod +x "$TMPD/$1"
}
mk claudeA '✳ Fix the parser'                        claude 979
mk claudeB '✳ Review the API'                        claude 978
mk claudeC '✳ Pick a name'                           claude 977
mk codex1  '[ ! ] Action Required | Add tests | proj' codex  976
mk codexh  '[ ! ] Action Required | Hidden | proj'   codex  975
mk vim1    'notes - VIM'                             vim    974
mk plain   'whatever'                                sleep  973
mk claudeW '◐ Thinking it over'                      claude 972
mk claudeD '✳ Refactor the store'                    claude 970
mk claudeN 'Just a title'                            claude 969
cat > "$TMPD/aider1" <<'EOF2'
#!/usr/bin/env bash
exec -a aider sleep 971
EOF2
chmod +x "$TMPD/aider1"

tin() { tmux -L "$SOCK" "$@"; }
tin -f /dev/null new-session -d -s aa -x 120 -y 30 -c "$TMPD" "exec bash --norc --noprofile -i"
tin set -g default-command 'bash --norc --noprofile -i'
tin new-window -d -t '=aa:' -n cb -c "$TMPD" "exec '$TMPD/claudeB'"
tin new-window -d -t '=aa:' -n in -c "$TMPD" "exec '$TMPD/claudeC'"
tin new-session -d -s zz -x 120 -y 30 -c "$TMPD" "exec bash --norc --noprofile -i"
for w in ca:claudeA cx:codex1 wk:plain id:plain er:plain dn:plain vi:vim1 cw:claudeW ai:aider1 \
         cd:claudeD cn:claudeN; do
  tin new-window -d -t '=zz:' -n "${w%%:*}" -c "$TMPD" "exec '$TMPD/${w#*:}'"
done
tin new-session -d -s scratch -x 120 -y 30 -c "$TMPD" "exec '$TMPD/codexh'"
tin new-session -d -s zzgrp -t '=zz'           # every zz pane, listed again (after zz)
tin set -g @interdimux-hide 'scratch'

tin set -p -t '=zz:wk' @agent_state working
tin set -p -t '=zz:wk' @agent_desc 'Indexing'
tin set -p -t '=zz:id' @agent_state idle
tin set -p -t '=zz:er' @agent_state error
tin set -p -t '=zz:dn' @agent_state 'done'
# A tab or a newline in a published description must not reach a line: the
# only tabs are the ones between the columns.
tin set -p -t '=zz:dn' @agent_desc "Shipped"$'\t'"v2"$'\n'"now"

pane_of() { tin display-message -p -t "$1" '#{pane_id}'; }
widx_of() { tin display-message -p -t "$1" '#{window_index}'; }
title_is() { [ "$(tin display-message -p -t "$1" '#{pane_title}')" = "$2" ]; }
settled() {
  title_is '=aa:cb' '✳ Review the API' && title_is '=aa:in' '✳ Pick a name' \
    && title_is '=zz:ca' '✳ Fix the parser' && title_is '=zz:cx' '[ ! ] Action Required | Add tests | proj' \
    && title_is '=scratch:' '[ ! ] Action Required | Hidden | proj' && title_is '=zz:vi' 'notes - VIM' \
    && title_is '=zz:cw' '◐ Thinking it over' && title_is '=zz:cd' '✳ Refactor the store' \
    && title_is '=zz:cn' 'Just a title' \
    && [ "$(tin display-message -p -t '=zz:ai' '#{pane_current_command}')" = aider ] \
    && [ "$(tin display-message -p -t '=zz:cx' '#{pane_current_command}')" = codex ]
}
for _ in $(seq 1 100); do settled && break; sleep 0.05; done
settled && report "the panes settled (titles set, argv final)" pass \
        || report "the panes settled (titles set, argv final)" fail

# Claude's registry: A and B wait for a permission, A since longer (and in
# the session tmux lists LAST); C asks a question; D is busy, which no title
# of Claude's can say under tmux.  statusUpdatedAt is in ms.
record() { # window, status, waitingFor, statusUpdatedAt
  local pane pid st
  pane=$(pane_of "$1"); pid=$(tin display-message -p -t "$1" '#{pane_pid}')
  read -r -a st < "/proc/$pid/stat"
  printf '{"pid":%s,"sessionId":"x","cwd":"/tmp","startedAt":1,"procStart":"%s","version":"2.1.281","kind":"interactive","entrypoint":"cli","tmux":"t:@1.%s","name":"n","status":"%s","waitingFor":"%s","statusUpdatedAt":%s}' \
    "$pid" "${st[21]}" "$pane" "$2" "$3" "$4" > "$INTERDIMUX_CLAUDE_DIR/sessions/$pid.json"
}
record '=zz:ca' waiting 'permission prompt' 1700000000000
record '=aa:cb' waiting 'permission prompt' 1700000600000
record '=aa:in' waiting 'input needed'      1700000300000
record '=zz:cd' busy    ''                  1700000100000

export TMUX="$(tin display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(pane_of '=aa:0')"
agents() { bash "$SCRIPT" --agents "$@" 2>"$TMPD/err"; }

T=$'\t'
CA=$(pane_of '=zz:ca') CB=$(pane_of '=aa:cb') CC=$(pane_of '=aa:in') CX=$(pane_of '=zz:cx')
WK=$(pane_of '=zz:wk') ID=$(pane_of '=zz:id') ER=$(pane_of '=zz:er') DN=$(pane_of '=zz:dn')
CW=$(pane_of '=zz:cw') AI=$(pane_of '=zz:ai') CD=$(pane_of '=zz:cd') CN=$(pane_of '=zz:cn')
L_CA="$CA$T=zz:=$(widx_of '=zz:ca').0${T}claude${T}approve${T}1700000000${T}Fix the parser"
L_CB="$CB$T=aa:=$(widx_of '=aa:cb').0${T}claude${T}approve${T}1700000600${T}Review the API"
L_CX="$CX$T=zz:=$(widx_of '=zz:cx').0${T}codex${T}approve${T}-${T}Add tests"
L_CC="$CC$T=aa:=$(widx_of '=aa:in').0${T}claude${T}input${T}1700000300${T}Pick a name"
L_ER="$ER$T=zz:=$(widx_of '=zz:er').0${T}sleep${T}error${T}-${T}"
# The tab goes in tmux's capped read of the option, which drops a control
# character; the newline is rewritten to '?' first (state_optfmt_r).
L_DN="$DN$T=zz:=$(widx_of '=zz:dn').0${T}sleep${T}done${T}-${T}Shippedv2?now"
L_WK="$WK$T=zz:=$(widx_of '=zz:wk').0${T}sleep${T}working${T}-${T}Indexing"
L_ID="$ID$T=zz:=$(widx_of '=zz:id').0${T}sleep${T}idle${T}-${T}"
# Claude with no registry record: its title's state.  aider sets no title and
# publishes nothing: an agent by its name alone, with no state, last.
L_CW="$CW$T=zz:=$(widx_of '=zz:cw').0${T}claude${T}working${T}-${T}Thinking it over"
L_AI="$AI$T=zz:=$(widx_of '=zz:ai').0${T}aider${T}-${T}-${T}"
L_CD="$CD$T=zz:=$(widx_of '=zz:cd').0${T}claude${T}working${T}1700000100${T}Refactor the store"
# A title no rule of Claude's knows is not the row's description (show-title
# known), so not this one's either.
L_CN="$CN$T=zz:=$(widx_of '=zz:cn').0${T}claude${T}-${T}-${T}"

# --- the listing -----------------------------------------------------------------
want=$(printf '%s\n' "$L_CA" "$L_CB" "$L_CX" "$L_CC" "$L_ER" "$L_DN" "$L_CD" "$L_WK" "$L_CW" "$L_ID" "$L_AI" "$L_CN")
rc=0; got=$(agents) || rc=$?
same "every agent pane once, most urgent first, the longest-waiting first within a state" "$got" "$want"
same "...exit 0, and nothing on stderr" "$rc:$(cat "$TMPD/err")" "0:"
same "...six columns on every line: no tab or newline from a description" \
  "$(printf '%s\n' "$got" | awk -F'\t' 'NF != 6 { print "line " NR ": " NF " columns" }')" ""

# --- STATES and --count ------------------------------------------------------------
same "--agents approve,input: those only, in the same order" \
  "$(agents approve,input)" "$(printf '%s\n' "$L_CA" "$L_CB" "$L_CX" "$L_CC")"
same "--agents working,idle (no shortcut: every pane is asked, a title too)" \
  "$(agents working,idle)" "$(printf '%s\n' "$L_CD" "$L_WK" "$L_CW" "$L_ID")"
same "--agents --count approve,input: the dashboard's count (the hidden session's codex is not in it)" \
  "$(agents --count approve,input)" 4
same "--agents --count approve" "$(agents --count approve)" 3
same "--agents --count done,error" "$(agents --count done,error)" 2
same "--agents --count: every agent pane" "$(agents --count)" 12

# The description is the row's: @interdimux-show-title decides it here too.
same "show-title all: a title no rule knows is the description" \
  "$(INTERDIMUX_SHOW_TITLE=all bash "$SCRIPT" --agents 2>&1 | grep "^$CN$T")" "${L_CN}Just a title"
same "show-title off: no description" \
  "$(INTERDIMUX_SHOW_TITLE=off bash "$SCRIPT" --agents approve 2>&1)" \
  "$(printf '%s\n' "${L_CA%"$T"*}$T" "${L_CB%"$T"*}$T" "${L_CX%"$T"*}$T")"

for bad in bogus approve,bogus ,approve --count=1; do
  rc=0; out=$(bash "$SCRIPT" --agents "$bad" 2>"$TMPD/err") || rc=$?
  same "--agents '$bad' is refused with exit 2, and prints nothing" "$rc:$out" "2:"
done
rc=0; out=$(bash "$SCRIPT" --agents --count approve extra 2>"$TMPD/err") || rc=$?
same "--agents --count approve extra is refused with exit 2" "$rc:$out" "2:"
grep -q 'usage: --agents' "$TMPD/err" && report "...saying how it is used" pass \
                                       || report "...saying how it is used" fail

# --- no fzf on PATH: a status line runs it from the server's -------------------------
mkdir -p "$TMPD/onlytmux"
ln -s "$(command -v tmux)" "$TMPD/onlytmux/tmux"
rc=0; out=$(PATH="$TMPD/onlytmux" "$BASH" "$SCRIPT" --agents --count approve,input 2>"$TMPD/err") || rc=$?
same "with no fzf on PATH, --agents --count still answers" "$rc:$out" "0:4"
rc=0; out=$(PATH="$TMPD/onlytmux" "$BASH" "$SCRIPT" --agents approve 2>"$TMPD/err") || rc=$?
same "...and so does the listing" "$rc:$out" "0:$(printf '%s\n' "$L_CA" "$L_CB" "$L_CX")"

# --- bash 4.3, the floor -------------------------------------------------------------
B43="${INTERDIMUX_OLD_BASH_DIR:-}/4.3/bash"
if [ -n "${INTERDIMUX_OLD_BASH_DIR:-}" ] && [ -x "$B43" ]; then
  same "bash 4.3 lists the same lines" "$("$B43" "$SCRIPT" --agents 2>&1)" "$want"
  same "...and counts the same" "$("$B43" "$SCRIPT" --agents --count working,idle 2>&1)" 4
else
  echo "  (skipped bash 4.3: not in \$INTERDIMUX_OLD_BASH_DIR)"
fi

# --- a server with no agent ------------------------------------------------------------
tmux -f /dev/null -L "$EMPTY" new-session -d -s only -x 80 -y 24 "exec bash --norc --noprofile -i"
tmux -L "$EMPTY" new-window -d -t '=only:' "exec '$TMPD/vim1'"
ETMUX="$(tmux -L "$EMPTY" display-message -p '#{socket_path}'),99999,0"
EPANE=$(tmux -L "$EMPTY" display-message -p -t '=only:0' '#{pane_id}')
rc=0; out=$(TMUX="$ETMUX" TMUX_PANE="$EPANE" bash "$SCRIPT" --agents 2>"$TMPD/err") || rc=$?
same "a server with no agent: --agents prints nothing and exits 0" "$rc:$out:$(cat "$TMPD/err")" "0::"
same "...--agents --count approve,input prints 0" \
  "$(TMUX="$ETMUX" TMUX_PANE="$EPANE" bash "$SCRIPT" --agents --count approve,input 2>&1)" 0
same "...and --agents --count, 0" "$(TMUX="$ETMUX" TMUX_PANE="$EPANE" bash "$SCRIPT" --agents --count 2>&1)" 0

printf '\nResults: %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"

exit "$FAIL"
