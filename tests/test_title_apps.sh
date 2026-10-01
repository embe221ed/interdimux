#!/usr/bin/env bash
#
# The default title rules for apps that are a terminal somewhere else (ssh,
# mosh, docker and the other container clients, screen, a nested tmux), and
# what keeps a title that only repeats the row off it -- in BOTH renderers.
#
# Every title below is one a real program was seen to set (or its rc file
# reads so; README "Agents and pane titles"): the ubuntu:24.04 bashrc in a
# `docker run -it` (TERM=xterm, so `root@<id>: /`), Fedora with no USER in the
# container (`@<id>:/`), Arch, `docker exec -u 1000`, fish with SSH_TTY
# (`[host] path`, `[host] cmd path`), mosh-client (`[mosh] ` before the
# remote's title), tmux with set-titles on (`#S:#I:#W - "#T" `), and what an
# oh-my-zsh preexec hook leaves while the client starts (the command line).
#
#   1. through the dump seam, `known` (the default): what shows, and what does
#      not -- a preexec line, a stale prompt of this host, a leftover title on
#      an app with no rule, the local fish's `[host] ...` on an ssh row
#   2. through the dump seam, `all`: the repeat filters on their own -- a
#      prompt of this host ends at the host name (`web` is not `web-7d4b9c`),
#      fish's `[host]` is cut to 10 characters, a sudo row's own preexec line
#   3. the README's rules that are not defaults, from a user's file: a sudo
#      row's container prompt shows, its own preexec line (which has a prompt's
#      shape) does not
#   4. live, on a private server: panes that set the exact title with an OSC 0
#      and then become the app (argv0 is what picks the rules); a real nested
#      tmux client with set-titles on; a real docker container shell when
#      docker runs without sudo and ubuntu:24.04 is already local (never pulled;
#      INTERDIMUX_TEST_DOCKER=off turns it off)
#
# Expected rows are written out here, not computed by either renderer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-titleapps-test-$$"
ISOCK="interdimux-titleapps-inner-$$"
CTR="interdimux-titleapps-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-titleapps.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""
DOCKER_RAN=0

cleanup() {
  local d="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  tmux -L "$ISOCK" kill-server 2>/dev/null || true
  rm -f "$d/$SOCK" "$d/$ISOCK"
  if [ "$DOCKER_RAN" = 1 ]; then timeout 20 docker kill "$CTR" >/dev/null 2>&1 || true; fi
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

echo "interdimux title tests: apps that are a terminal somewhere else"
echo

RENDERERS="off"
[ -x "$BIN" ] && RENDERERS="off on"
[ -x "$BIN" ] || echo "  (the Rust core is not built: the Rust renderer's cases are skipped)"

# --- the dump seam ------------------------------------------------------------
US=$'\x1f' RS=$'\x1e' GS=$'\x1d'
NOPTS=$(sed -n "s/^DEFAULT_STATE_OPTS='\(.*\)'\$/\1/p" "$SCRIPT" | wc -w)
empty_opts=$(printf "${GS}%.0s" $(seq "$NOPTS"))
mkdir -p "$TMPD/home" "$TMPD/stub"
printf '#!/bin/sh\nexit 1\n' > "$TMPD/stub/tmux"; chmod +x "$TMPD/stub/tmux"

# $1 = on|off (the Rust core), $2 = show-title, $3 = this host's name, $4 its
# short name, rest = the cases, `app|title` each.  One window of one pane per
# case, so the window row is the case; prints each row's command field.
render_dump() {
  local rust="$1" show="$2" host="$3" hs="$4" i c; shift 4
  {
    printf 's%s1700000000%s%s%s%s/tmp\n%s\n' "$US" "$US" "$#" "$US" "$US" "$RS"
    i=0; for c in "$@"; do
      printf 's%s%d%sw%d%s0%s%s%s/tmp%s1%s%d%s000\n' "$US" "$i" "$US" "$i" "$US" "$US" "${c%%|*}" "$US" "$US" "$US" $((1000 + i)) "$US"
      i=$((i + 1))
    done
    printf '%s\n' "$RS"
    i=0; for c in "$@"; do
      printf 's%s%d%s0%s1%s%s%s/tmp%s%d%s1%s%%%d%s%s%s%s\n' "$US" "$i" "$US" "$US" "$US" "${c%%|*}" "$US" "$US" $((1000 + i)) "$US" "$US" "$i" "$US" "${c#*|}" "$US" "$empty_opts"
      i=$((i + 1))
    done
    printf '%s\ns%s0%s0%s%s%s%s\n%s\n' "$RS" "$US" "$US" "$US" "$host" "$US" "$hs" "$RS"
  } > "$TMPD/apps.dump"
  env -i HOME="$TMPD/home" PATH="$TMPD/stub:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    TMUX="$TMPD/no-server,1,0" INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
    INTERDIMUX_NOW=1700086400 INTERDIMUX_SHOW_FULL_COMMAND=off INTERDIMUX_SHOW_GIT_BRANCH=off \
    INTERDIMUX_SHOW_DIRS=off INTERDIMUX_ORDER=index INTERDIMUX_USE_RUST="$rust" \
    INTERDIMUX_SHOW_TITLE="$show" INTERDIMUX_TITLE_RULES='~/titles' INTERDIMUX_DUMP_IN="$TMPD/apps.dump" \
    bash "$SCRIPT" --list 2> "$TMPD/err.$rust" \
    | awk -F'\t' '$4 ~ /^W:/ { print $3 }' | sed 's/\x1b\[[0-9;]*m//g'
}

# $1 = show-title, $2 = host, $3 = short host; then the arrays CASES, EXPECT
# and WHAT, index for index
check_dump() {
  local show="$1" host="$2" hs="$3" rust label i
  for rust in $RENDERERS; do
    label="bash"; [ "$rust" = on ] && label="rust"
    mapfile -t GOT < <(render_dump "$rust" "$show" "$host" "$hs" "${CASES[@]}")
    for i in "${!EXPECT[@]}"; do
      if [ "${GOT[i]-}" = "${EXPECT[i]}" ]; then
        report "$label, $show: ${WHAT[i]}" pass
      else
        report "$label, $show: ${WHAT[i]} (got: '${GOT[i]-}', want: '${EXPECT[i]}')" fail
      fi
    done
    [ "${#GOT[@]}" = "${#EXPECT[@]}" ] && [ ! -s "$TMPD/err.$rust" ] \
      && report "$label, $show: one row per case, nothing on stderr" pass \
      || { report "$label, $show: one row per case, nothing on stderr (${#GOT[@]} rows)" fail
           ERRORS+="$(head -3 "$TMPD/err.$rust")"$'\n'; }
  done
}

# --- 1. what shows by default -------------------------------------------------
# This host is web.example.com: `web` is its short name.
CASES=(
  'docker|root@96fecc5c832f: /'
  'docker|@8b85756b3f26:/'
  'docker|ubuntu@tc2svc: ~'
  'docker|@tchost:/work/sub'
  'docker|remote:0:top - "tchost" '
  'kubectl|root@web-7d4b9c: /app'
  'screen|root@tchost: /work/sub'
  'ssh|me@remote: ~/src'
  'ssh|me@remote:~/src'
  'ssh|[tchost] /w/s/deeper'
  'ssh|[tchost] sleep 5 /w/s/deeper'
  'ssh|remote:0:sh - "tchost" '
  'mosh-client|[mosh] root@tchost: /work/sub'
  'tmux|inner:0:zsh - "me@web:/tmp/x" '
  'docker|docker run --rm -it --name tc2-zu --hostname tchost ubuntu:24.04 bash'
  'docker|docker run -v /a:/b img@sha256:abc bash'
  'docker|me@web:/tmp/x'
  'ssh|ssh me@remote'
  'ssh|Thanks for flying Vim'
  'ssh|[web] ssh me@remote ~'
  'htop|root@tchost: /'
  'mosh-client|root@tchost: /work/sub'
  'nvim|file.txt (/w/sandbox) - Nvim'
  'docker|/work'
  'tmux|tmux -L other attach'
)
EXPECT=(
  'docker ∣ root@96fecc5c832f: /'
  'docker ∣ @8b85756b3f26:/'
  'docker ∣ ubuntu@tc2svc: ~'
  'docker ∣ @tchost:/work/sub'
  'docker ∣ remote:0:top - "tchost"'
  'kubectl ∣ root@web-7d4b9c: /app'
  'screen ∣ root@tchost: /work/sub'
  'ssh ∣ me@remote: ~/src'
  'ssh ∣ me@remote:~/src'
  'ssh ∣ [tchost] /w/s/deeper'
  'ssh ∣ [tchost] sleep 5 /w/s/deeper'
  'ssh ∣ remote:0:sh - "tchost"'
  'mosh-client ∣ root@tchost: /work/sub'
  'tmux ∣ inner:0:zsh'
  'docker'
  'docker'
  'docker'
  'ssh'
  'ssh'
  'ssh'
  'htop'
  'mosh-client'
  'nvim'
  'docker'
  'tmux'
)
WHAT=(
  "a container prompt (ubuntu bashrc, TERM=xterm)"
  "a container prompt with no USER (fedora)"
  "docker exec -u 1000"
  "arch: user@host:path"
  "tmux in a container, set-titles on"
  "a pod whose name starts with this host's is not this host"
  "screen passes a container prompt on"
  "a remote prompt, Debian and Ubuntu shape"
  "a remote prompt, Fedora, Arch and oh-my-zsh shape"
  "fish over ssh, at its prompt"
  "fish over ssh, while a command runs"
  "a remote tmux, set-titles on"
  "mosh-client shows the remote title without its [mosh]"
  "a nested tmux client: session:index:window, past this host in #T"
  "not: the preexec line while docker starts"
  "not: a preexec line that looks like a prompt"
  "not: a prompt of this host left in the title"
  "not: the preexec line while ssh connects"
  "not: what vim left behind"
  "not: the local fish (SSH_TTY set) naming this host"
  "not: a container prompt left on an app with no rule"
  "not: a title mosh did not set (it prefixes its own)"
  "not: an editor title (no rule by default)"
  "not: fish in a container with no SSH_TTY (no rule by default)"
  "not: the preexec line of a nested client"
)
check_dump known web.example.com web

# --- 2. the repeat filters, under `all` ----------------------------------------
CASES=(
  'sudo|sudo docker run --rm -it ubuntu bash'
  'screen|me@web.example.com:~/x'
  'ssh|me@web'
  'ssh|[web] ~/src'
  'htop|[web] htop ~/x'
  'ssh|me@webserver: ~'
  'ssh|[webserver] ~'
)
EXPECT=(
  'sudo'
  'screen'
  'ssh'
  'ssh'
  'htop'
  'ssh ∣ me@webserver: ~'
  'ssh ∣ [webserver] ~'
)
WHAT=(
  "a sudo row: its own preexec line, sudo first"
  "a prompt of this host with its domain"
  "a prompt of this host with no path (oh-my-zsh, Apple Terminal)"
  "the local fish prompt, SSH_TTY set"
  "the local fish command line, SSH_TTY set"
  "a host whose name starts with this one's"
  "...and in fish's brackets"
)
check_dump all web.example.com web

# fish cuts the host name to 10 characters in its brackets
CASES=(
  'ssh|[krootabulo] ssh me@remote ~'
  'ssh|me@krootabulon-2:~'
  'ssh|[krootabulo] ~'
)
EXPECT=(
  'ssh'
  'ssh ∣ me@krootabulon-2:~'
  'ssh'
)
WHAT=(
  "fish names a long host by its first 10 characters"
  "a host whose name starts with a long one's"
  "...and the local fish prompt"
)
check_dump all krootabulon.lan krootabulon

# --- 3. the README's rules that are not defaults, from a user's file -----------
printf '%s\n' \
  'nvim            -  $1  * - Nvim' \
  'zellij          -  =   *' \
  'docker,podman   -  =   /*' \
  'sudo            -  =   *@*:*' > "$TMPD/home/titles"
CASES=(
  'nvim|file.txt (/w/sandbox) - Nvim'
  'zellij|wise-diplodocus'
  'docker|/work'
  'sudo|root@3f2a9c1b: /'
  'sudo|sudo docker run -v /a:/b img@sha256:abc bash'
)
EXPECT=(
  'nvim ∣ file.txt (/w/sandbox)'
  'zellij ∣ wise-diplodocus'
  'docker ∣ /work'
  'sudo ∣ root@3f2a9c1b: /'
  'sudo'
)
WHAT=(
  "user file: nvim with set title"
  "user file: zellij"
  "user file: fish in a container"
  "user file: sudo docker, the container prompt"
  "user file: ...but not its own preexec line, which has a prompt shape"
)
check_dump known web.example.com web
rm -f "$TMPD/home/titles"

# --- 4. live ----------------------------------------------------------------------
unset TMUX TMUX_PANE
tmux_cmd() { tmux -f /dev/null -L "$SOCK" "$@"; }

# A pane that sets title $2 the way the program does (OSC 0) and then becomes
# `$1 <n>`: argv0 is what picks the rules.  Window name $3.
N=990
pane_as() {
  local app="$1" title="$2" name="$3" cmd
  N=$((N + 1))
  printf -v cmd 'printf %q %q; exec -a %q sleep %d' '\033]0;%s\007' "$title" "$app" "$N"
  if [ "$(tmux_cmd list-sessions -F x 2>/dev/null | wc -l)" = 0 ]; then
    tmux_cmd new-session -d -s t -n "$name" -x 200 -y 30 -c "$TMPD" "bash -c $(printf %q "$cmd")"
  else
    tmux_cmd new-window -d -t '=t:' -n "$name" -c "$TMPD" "bash -c $(printf %q "$cmd")"
  fi
}
pane_as docker 'root@3f2a9c1b: /usr/share' dk
pane_as ssh '[web1] make /h/m/src' sh1
pane_as mosh-client '[mosh] deploy@web1: ~/app' mo
pane_as ssh 'ssh deploy@web1' sh2

# a real nested client: its own server, set-titles on, attached from a pane
tmux -f /dev/null -L "$ISOCK" new-session -d -s inner -n edit -x 80 -y 20 -c "$TMPD" 'exec sleep 989'
tmux -L "$ISOCK" set -g set-titles on
tmux_cmd new-window -d -t '=t:' -n nest -c "$TMPD" "exec env -u TMUX tmux -L $ISOCK attach -t inner"

# a real container shell, when docker is there without sudo and the image is
# already local.  INTERDIMUX_TEST_DOCKER=off is a choice, not something missing,
# so it is said without the word run_all.sh counts as a skip: CI makes it, since
# it never pulls the image (and IMUX_STRICT there fails on any skip).
DOCKER=0
if [ "${INTERDIMUX_TEST_DOCKER:-on}" = off ]; then
  echo "  (the container case is off: INTERDIMUX_TEST_DOCKER=off)"
elif command -v docker >/dev/null 2>&1 \
   && timeout 10 docker image inspect ubuntu:24.04 >/dev/null 2>&1; then
  DOCKER=1 DOCKER_RAN=1
  # the container ends itself too, should cleanup never run
  tmux_cmd new-window -d -t '=t:' -n ctr -c "$TMPD" \
    "exec docker run --rm -it --name $CTR --hostname tchost -w /usr/share ubuntu:24.04 timeout --foreground 300 bash"
else
  echo "  (docker without sudo, or a local ubuntu:24.04, is not there: the container case is skipped)"
fi

wopt() { tmux -L "$SOCK" display-message -p -t "=t:$1" "$2" 2>/dev/null; }
settled() {
  [ "$(wopt dk '#{pane_title}')" = 'root@3f2a9c1b: /usr/share' ] || return 1
  [ "$(wopt sh1 '#{pane_title}')" = '[web1] make /h/m/src' ] || return 1
  [ "$(wopt mo '#{pane_title}')" = '[mosh] deploy@web1: ~/app' ] || return 1
  [ "$(wopt sh2 '#{pane_title}')" = 'ssh deploy@web1' ] || return 1
  [[ "$(wopt nest '#{pane_title}')" == 'inner:0:edit - "'* ]] || return 1
  [ "$(wopt dk '#{pane_current_command}')" = docker ] || return 1
  [ "$(wopt mo '#{pane_current_command}')" = mosh-client ] || return 1
  [ "$(wopt nest '#{pane_current_command}')" = tmux ] || return 1
  if [ "$DOCKER" = 1 ]; then
    [ "$(wopt ctr '#{pane_title}')" = 'root@tchost: /usr/share' ] || return 1
  fi
}
for _ in $(seq 1 300); do settled && break; sleep 0.1; done
settled && report "the panes settled (titles set, argv0 final)" pass \
        || report "the panes settled (titles set, argv0 final)" fail

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=t:dk' -F '#{pane_id}' | head -1)"
live() { # $1 = on|off; prints "window-name<TAB>command field"
  env HOME="$TMPD/home" XDG_CONFIG_HOME="$TMPD/xdg" XDG_STATE_HOME="$TMPD/state" \
    INTERDIMUX_CLAUDE_DIR="$TMPD/noclaude" INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
    INTERDIMUX_SHOW_FULL_COMMAND=off INTERDIMUX_SHOW_GIT_BRANCH=off INTERDIMUX_SHOW_DIRS=off \
    INTERDIMUX_ORDER=index INTERDIMUX_USE_RUST="$1" \
    bash "$SCRIPT" --list 2> "$TMPD/lerr.$1" \
    | awk -F'\t' '$4 ~ /^W:/ { print $4 "\t" $3 }' | sed 's/\x1b\[[0-9;]*m//g'
}
row_of() { # $1 = the rows, $2 = window name
  local idx
  idx=$(tmux -L "$SOCK" display-message -p -t "=t:$2" '#{window_index}')
  printf '%s\n' "$1" | awk -F'\t' -v s="W:t:$idx" '$1 == s { print $2 }'
}
for rust in $RENDERERS; do
  label="bash"; [ "$rust" = on ] && label="rust"
  OUT=$(live "$rust")
  got=$(row_of "$OUT" dk)
  [ "$got" = 'docker ∣ root@3f2a9c1b: /usr/share' ] \
    && report "$label: live docker row shows the container prompt" pass \
    || report "$label: live docker row shows the container prompt (got: '$got')" fail
  got=$(row_of "$OUT" sh1)
  [ "$got" = 'ssh ∣ [web1] make /h/m/src' ] \
    && report "$label: live ssh row shows the remote fish title" pass \
    || report "$label: live ssh row shows the remote fish title (got: '$got')" fail
  got=$(row_of "$OUT" mo)
  [ "$got" = 'mosh-client ∣ deploy@web1: ~/app' ] \
    && report "$label: live mosh-client row shows the remote title" pass \
    || report "$label: live mosh-client row shows the remote title (got: '$got')" fail
  got=$(row_of "$OUT" sh2)
  [ "$got" = 'ssh' ] \
    && report "$label: live ssh row hides the preexec line" pass \
    || report "$label: live ssh row hides the preexec line (got: '$got')" fail
  got=$(row_of "$OUT" nest)
  [ "$got" = 'tmux ∣ inner:0:edit' ] \
    && report "$label: a real nested tmux client (set-titles on) shows session:index:window" pass \
    || report "$label: a real nested tmux client (set-titles on) shows session:index:window (got: '$got')" fail
  if [ "$DOCKER" = 1 ]; then
    got=$(row_of "$OUT" ctr)
    [ "$got" = 'docker ∣ root@tchost: /usr/share' ] \
      && report "$label: a real ubuntu:24.04 container shell shows its prompt" pass \
      || report "$label: a real ubuntu:24.04 container shell shows its prompt (got: '$got')" fail
  fi
  [ ! -s "$TMPD/lerr.$rust" ] && report "$label: live, nothing on stderr" pass \
    || { report "$label: live, nothing on stderr" fail; ERRORS+="$(head -3 "$TMPD/lerr.$rust")"$'\n'; }
done

echo
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
