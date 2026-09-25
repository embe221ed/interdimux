#!/usr/bin/env bash
#
# Which description and which state a row shows, and which it leaves out --
# in BOTH renderers, through the dump seam (INTERDIMUX_DUMP_IN: no server, no
# timing).  README "Agents and pane titles" and "Title rules" are the spec.
#
#   1. a remote or container prompt is not a command line, even when its
#      directory is named like the app (`deploy@web1:/etc/ssh` on an ssh row)
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

echo
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
