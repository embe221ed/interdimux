#!/usr/bin/env bash
#
# Which description and which state a row shows, and which it leaves out --
# in BOTH renderers, through the dump seam (INTERDIMUX_DUMP_IN: no server, no
# timing).  README "Agents and pane titles" and "Title rules" are the spec.
#
#   1. a remote or container prompt is not a command line, even when its
#      directory is named like the app (`deploy@web1:/etc/ssh` on an ssh row)
#   2. a description a hook or plugin PUBLISHED (@agent_desc, an option rule's
#      DESC) is shown as published: the filters for stale or copied titles are
#      not for it, only a bare repeat of the row's name goes
#   3. an agent's row shows a title only when a rule knows it, like any other
#      row: a title the last program left in the pane (a shell that sets none
#      keeps it) is not an agent's task.  The agents that title themselves
#      have rules, so their own titles still show.
#   4. a rule whose STATE is not one of the six words gives no state (README
#      "Title rules"), though it still matches and gives its DESC
#   5. @interdimux-agents off stops the naming and only that: rows keep their
#      whole command, a native agent's title rules and Claude's registry still
#      give it a state (after the command), an npm install is `node` to the
#      rules; the rows of old need all three agent settings off
#
# Expected rows are written out here, not computed by either renderer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-rowdesc.XXXXXX")" && pwd -P)"
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

echo "interdimux row description tests (both renderers, no server)"
echo

RENDERERS="off"
[ -x "$BIN" ] && RENDERERS="off on"
[ -x "$BIN" ] || echo "  (the Rust core is not built: only the bash renderer is checked)"

US=$'\x1f' RS=$'\x1e' GS=$'\x1d'
# the option names a pane line carries values for, in order
read -r -a ONAMES <<< "$(sed -n "s/^DEFAULT_STATE_OPTS='\(.*\)'\$/\1/p" "$SCRIPT")"
mkdir -p "$TMPD/home" "$TMPD/stub"
# a tmux that must never run: the seam is the whole input
printf '#!/bin/sh\nexit 1\n' > "$TMPD/stub/tmux"; chmod +x "$TMPD/stub/tmux"

# The pane options of one case, positional: `opt=value;opt=value` -> one value
# per name in ONAMES, each ended by GS.
opts_of() {
  local spec="$1" out="" n kv
  local -A v=()
  local -a kvs=()
  IFS=';' read -r -a kvs <<< "$spec"
  for kv in ${kvs[@]+"${kvs[@]}"}; do [ -n "$kv" ] && v["${kv%%=*}"]="${kv#*=}"; done
  for n in "${ONAMES[@]}"; do out+="${v[$n]-}$GS"; done
  REPLY="$out"
}

# Settings for the next check_dump: the show-title setting, this host's name
# and short name, the registry section (empty: none), and extra environment.
SHOW=known HOST=web.example.com HS=web REG=""
EXTRA=()

# $1 = on|off (the Rust core); the cases are `command|title` or
# `command|title§opt=value;...`, one window of one pane each, pane N's pid
# 1000+N and id %N.  Prints each window row's command field.
render_dump() {
  local rust="$1" i c cmd rest title o; shift
  {
    printf 's%s1700000000%s%s%s%s/tmp\n%s\n' "$US" "$US" "$#" "$US" "$US" "$RS"
    i=0; for c in "$@"; do
      printf 's%s%d%sw%d%s0%s%s%s/tmp%s1%s%d%s000\n' "$US" "$i" "$US" "$i" "$US" "$US" "${c%%|*}" "$US" "$US" "$US" $((1000 + i)) "$US"
      i=$((i + 1))
    done
    printf '%s\n' "$RS"
    i=0; for c in "$@"; do
      cmd="${c%%|*}" rest="${c#*|}" o=""
      title="${rest%%§*}"; [[ "$rest" == *§* ]] && o="${rest#*§}"
      opts_of "$o"
      printf 's%s%d%s0%s1%s%s%s/tmp%s%d%s1%s%%%d%s%s%s%s\n' "$US" "$i" "$US" "$US" "$US" "$cmd" "$US" "$US" $((1000 + i)) "$US" "$US" "$i" "$US" "$title" "$US" "$REPLY"
      i=$((i + 1))
    done
    printf '%s\ns%s0%s0%s%s%s%s\n' "$RS" "$US" "$US" "$US" "$HOST" "$US" "$HS"
    if [ -n "$REG" ]; then printf '%s\n%s\n' "$RS" "$REG"; fi
  } > "$TMPD/case.dump"
  env -i HOME="$TMPD/home" PATH="$TMPD/stub:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    TMUX="$TMPD/no-server,1,0" INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
    INTERDIMUX_NOW=1700086400 INTERDIMUX_SHOW_FULL_COMMAND=off INTERDIMUX_SHOW_GIT_BRANCH=off \
    INTERDIMUX_SHOW_DIRS=off INTERDIMUX_ORDER=index INTERDIMUX_USE_RUST="$rust" \
    INTERDIMUX_SHOW_TITLE="$SHOW" INTERDIMUX_TITLE_RULES='~/titles' INTERDIMUX_DUMP_IN="$TMPD/case.dump" \
    ${EXTRA[@]+"${EXTRA[@]}"} bash "$SCRIPT" --list 2> "$TMPD/err.$rust" \
    | awk -F'\t' '$4 ~ /^W:/ { print $3 }' | sed 's/\x1b\[[0-9;]*m//g'
}

# $1 = what the section is about; the arrays CASES, EXPECT and WHAT, index for
# index
check_dump() {
  local about="$1" rust label i
  local -a got=()
  for rust in $RENDERERS; do
    label="bash"; [ "$rust" = on ] && label="rust"
    mapfile -t got < <(render_dump "$rust" "${CASES[@]}")
    for i in "${!EXPECT[@]}"; do
      if [ "${got[i]-}" = "${EXPECT[i]}" ]; then
        report "$label, $about: ${WHAT[i]}" pass
      else
        report "$label, $about: ${WHAT[i]} (got: '${got[i]-}', want: '${EXPECT[i]}')" fail
      fi
    done
    if [ "${#got[@]}" = "${#EXPECT[@]}" ] && [ ! -s "$TMPD/err.$rust" ]; then
      report "$label, $about: one row per case, nothing on stderr" pass
    else
      report "$label, $about: one row per case, nothing on stderr (${#got[@]} rows)" fail
      ERRORS+="$(head -3 "$TMPD/err.$rust")"$'\n'
    fi
  done
}

# --- 1. a prompt is not a command line ----------------------------------------
# A preexec hook's copy of the command line is dropped when its first word
# names argv0.  A prompt with no blank after the colon is one word too, and its
# last directory can be the app's name: that is still a prompt.
CASES=(
  'ssh|deploy@web1:/etc/ssh'
  'ssh|deploy@web1:~/ssh'
  'docker|root@3f2a9c1b:/var/lib/docker'
  'ssh|deploy@web1: /etc/ssh'
  'ssh|/usr/bin/ssh web1'
  'ssh|ssh web1:/etc'
)
EXPECT=(
  'ssh deploy@web1:/etc/ssh'
  'ssh deploy@web1:~/ssh'
  'docker root@3f2a9c1b:/var/lib/docker'
  'ssh deploy@web1: /etc/ssh'
  'ssh'
  'ssh'
)
WHAT=(
  "a remote prompt in /etc/ssh (Fedora, Arch, oh-my-zsh shape)"
  "a remote prompt in ~/ssh"
  "a container prompt in /var/lib/docker"
  "a remote prompt with a blank after the colon"
  "not: a preexec line whose command is a path"
  "not: a preexec line with a colon after its last slash"
)
check_dump "prompts"

# --- 2. a published description is shown as published --------------------------
# This host is web.example.com, `web` for short.
CASES=(
  'claude|✳ Fix it§agent_state=working;agent_desc=claude reviewing PR 42'
  'sleep 100|§agent_state=working;agent_desc=sleep until the build finishes'
  'make build|§agent_desc=make is running'
  'vim foo|§agent_desc=web'
  'sleep 30|§agent_desc=deploy@web: /srv'
  'sh ./my-agent|§agent_state=working;agent_desc=my-agent step 2 of 5'
  'claude|§agent_state=working;agent_desc=claude'
)
EXPECT=(
  'claude working claude reviewing PR 42'
  'sleep 100 working sleep until the build finishes'
  'make build make is running'
  'vim foo web'
  'sleep 30 deploy@web: /srv'
  'sh my-agent working my-agent step 2 of 5'
  'claude working'
)
WHAT=(
  "one that starts with the agent's name"
  "one that starts with argv0"
  "one that starts with argv0, and no state"
  "one that is this host's short name"
  "one shaped like a prompt of this host"
  "one that starts with the script a shell runs"
  "not: one that is only the name"
)
check_dump "published"

# --- 3. an agent's title needs a rule, as any other title does ----------------
EXTRA=(INTERDIMUX_AGENTS=myagent)
CASES=(
  'aider --model sonnet|✳ Refactor auth middleware'
  'python3 /h/.local/bin/aider|✳ Refactor auth middleware'
  'myagent|Thanks for flying Vim'
  'kiro-cli|root@3f2a9c1b: /app'
  'sh ./my-agent|✳ Refactor auth middleware§agent_state=working'
  'claude|Thanks for flying Vim'
  'claude|✳ Fix the parser'
  'claude|✳ Claude Code'
  'cursor-agent|Refactor the store'
  'cursor-agent|Cursor Agent'
  'codex|Fix login | app'
  'gemini|✦  Planning the refactor'
)
EXPECT=(
  'aider --model sonnet'
  'aider'
  'myagent'
  'kiro-cli'
  'sh my-agent working'
  'claude'
  'claude Fix the parser'
  'claude'
  'cursor-agent Refactor the store'
  'cursor-agent'
  'codex Fix login'
  'gemini working Planning the refactor'
)
WHAT=(
  "not: a leftover title on aider, which sets none"
  "not: ...on an npm aider"
  "not: ...on a name added with @interdimux-agents"
  "not: ...a container prompt on kiro-cli"
  "not: ...on a wrapper made an agent row by @agent_state"
  "not: ...what vim left on a claude row"
  "Claude's session title"
  "not: Claude's name for itself"
  "Cursor's chat name"
  "not: Cursor's name for itself"
  "codex's thread"
  "gemini's thought"
)
check_dump "agent titles"
# ...and under `all`, every title shows, as it did
SHOW=all
CASES=('aider --model sonnet|✳ Refactor auth middleware' 'myagent|Thanks for flying Vim')
EXPECT=('aider Refactor auth middleware' 'myagent Thanks for flying Vim')
WHAT=("aider's leftover title" "a user-added agent's leftover title")
check_dump "agent titles"
SHOW=known EXTRA=()

# --- 4. a STATE that is not a state word gives none -----------------------------
printf '%s\n' \
  'myagent   waiting  -   [?] *' \
  'myagent   Approve  $1  !! *' \
  'myagent   input    -   ?? *' \
  'sleep     blocked  =   *' \
  '@agent_desc  waiting  =  *' > "$TMPD/home/titles"
EXTRA=(INTERDIMUX_AGENTS=myagent)
CASES=(
  'myagent|[?] Pick one'
  'myagent|!! Now'
  'myagent|?? Which file'
  'sleep 883|t'
  'sleep 5|§agent_desc=Build'
)
EXPECT=(
  'myagent'
  'myagent Now'
  'myagent input'
  'sleep 883 t'
  'sleep 5 Build'
)
WHAT=(
  "a made-up word: no state, and the rule still decides (DESC -)"
  "a state word in capitals is no state word; its DESC stays"
  "a state word is a state"
  "a made-up word on another app: the whole title, no state"
  "an @option rule with a made-up word: its DESC, no state"
)
check_dump "state words"
rm -f "$TMPD/home/titles"
EXTRA=()

# --- 5. @interdimux-agents off ------------------------------------------------
# pane %0 (pid 1000) has a live Claude registry record: working, 5 minutes
REG="%0${US}1000${US}working${US}1700086100"
CX_TITLE='[ ! ] Action Required | Fix the build | proj'
CASES=(
  'claude 2400|✳ Validate user input on signup'
  "codex 2400|$CX_TITLE"
  "node /usr/lib/node_modules/@openai/codex/bin/codex resume 0199a1b2-aaaa|$CX_TITLE"
)
EXTRA=()
EXPECT=(
  'claude working 5m Validate user input on signup'
  'codex approve Fix the build'
  'codex approve Fix the build'
)
WHAT=(
  "claude, named and its arguments dropped"
  "a native codex"
  "an npm codex is codex too"
)
check_dump "agents on"
EXTRA=(INTERDIMUX_AGENTS=off)
EXPECT=(
  'claude 2400 working 5m Validate user input on signup'
  'codex 2400 approve Fix the build'
  'node codex resume 0199a1b2-aaaa'
)
WHAT=(
  "claude keeps its arguments; the registry state follows them"
  "a native codex keeps its arguments; its title rule's state follows them"
  "an npm codex is node to the title rules: no state"
)
check_dump "agents off"
EXTRA=(INTERDIMUX_AGENTS=off INTERDIMUX_AGENT_STATE=off INTERDIMUX_SHOW_TITLE=off)
EXPECT=(
  'claude 2400'
  'codex 2400'
  'node codex resume 0199a1b2-aaaa'
)
WHAT=(
  "claude as it always was"
  "codex as it always was"
  "an npm codex as it always was"
)
check_dump "all three off"
REG="" EXTRA=()

echo
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
