#!/usr/bin/env bash
#
# startup.conf: which line's command a new session receives.
#
# Every example the README gave (`~/work/api*`, `~/code/*-cli`, `~/notes`)
# matched NOTHING: the pattern comes out of a variable, and bash never
# tilde-expands a variable's value.  tests/test_hydration.sh only ever wrote
# absolute patterns, so it could not see that.  The same parser also cut the
# pattern at its first space (a project under "My Projects" was unmatchable)
# and kept the CR of a CRLF file, which the pane then read as a second Enter.
#
# The oracle is what the new session's pane actually READ: every pane in this
# server runs `cat >> .caught` in its own directory, so the file holds the exact
# lines hydration typed, one per line, with nothing a shell prompt could add.
# A sentinel typed after connect_dir returns marks the end of hydration, so "no
# extra line" is checked without a fixed sleep.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-startconf-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-startconf.XXXXXX")"
TMPD="$(cd "$TMPD" && pwd -P)"
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

echo "interdimux startup.conf tests"
echo

HOME_REAL="$TMPD/home"          # the fixture HOME
HOME_LINK="$TMPD/homelink"      # the same HOME reached through a symlink
mkdir -p "$HOME_REAL" "$TMPD/config/interdimux" "$TMPD/data" "$TMPD/state"
ln -s "$HOME_REAL" "$HOME_LINK"
CONF="$TMPD/config/interdimux/startup.conf"

tmux -f /dev/null -L "$SOCK" new-session -d -s anchor -x 150 -y 40 -c "$TMPD"
# Every session connect_dir creates runs a catcher instead of a shell.  exec, so
# the pane has no child and wait_pane_ready returns at once.
tmux -L "$SOCK" set -g default-shell /bin/sh
tmux -L "$SOCK" set -g default-command 'exec cat >> .caught'
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=anchor:' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_HYDRATE=on INTERDIMUX_STARTUP_COMMAND=''
export XDG_CONFIG_HOME="$TMPD/config" XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"

# hydrate DIR [HOME] -- create DIR, open it as a new session the real way
# (--connect-dir), then type a sentinel and wait for it.  Prints every line the
# pane read BEFORE the sentinel, i.e. exactly what hydration sent, each line
# prefixed with '>' -- a bare empty line (a stray Enter) would otherwise vanish
# into the trailing newlines $(...) strips.
SENT=0
hydrate() {
  local dir="$1" home="${2:-$HOME_REAL}" name i
  mkdir -p "$dir"
  HOME="$home" bash "$SCRIPT" --connect-dir "$dir" >/dev/null 2>&1 || true
  name=$(tmux -L "$SOCK" list-panes -a -F '#{session_name}	#{pane_current_path}' \
         | awk -F'\t' -v d="$dir" '$2 == d {print $1; exit}')
  [ -n "$name" ] || { echo "<no session for $dir>"; return 0; }
  SENT=$((SENT + 1))
  tmux -L "$SOCK" send-keys -t "=$name:" -l -- "SENTINEL-$SENT"
  tmux -L "$SOCK" send-keys -t "=$name:" Enter
  for i in $(seq 1 200); do
    grep -qx "SENTINEL-$SENT" "$dir/.caught" 2>/dev/null && break
    sleep 0.05
  done
  grep -qx "SENTINEL-$SENT" "$dir/.caught" 2>/dev/null || { echo "<pane never read the sentinel>"; return 0; }
  sed "/^SENTINEL-$SENT\$/,\$d; s/^/>/" "$dir/.caught"
}

# expect NAME GOT WANT -- exact comparison, with both sides shown on failure
expect() {
  if [ "$2" = "$3" ]; then
    report "$1" pass
  else
    report "$1" fail
    ERRORS+="    want: $(printf '%s' "$3" | cat -A | tr '\n' '|')"$'\n'
    ERRORS+="    got : $(printf '%s' "$2" | cat -A | tr '\n' '|')"$'\n'
  fi
}

# --- the README's own forms ---------------------------------------------------
# shellcheck disable=SC2088  # literal ~ is the point: the plugin expands it itself
{
  printf '%s\n' '# the README examples, verbatim in shape'
  printf '%s\n' '~/work/api*        echo FROM_TILDE_GLOB'
  printf '%s\n' '~/notes            echo FROM_TILDE_EXACT'
  printf '~/My Projects/*\techo FROM_SPACED_PATTERN\n'
  printf '~/crlf\techo FROM_CRLF\r\n'
  printf '   ~/indented\techo FROM_INDENTED\n'
  printf '~/linked\techo FROM_LINKED_HOME\n'
  printf '~\techo FROM_BARE_HOME\n'
} > "$CONF"

expect "a ~/ glob pattern matches under \$HOME (README: ~/work/api*)" \
  "$(hydrate "$HOME_REAL/work/api-v2")" ">echo FROM_TILDE_GLOB"

expect "a ~/ exact pattern matches (README: ~/notes)" \
  "$(hydrate "$HOME_REAL/notes")" ">echo FROM_TILDE_EXACT"

expect "a bare ~ pattern matches \$HOME itself" \
  "$(hydrate "$HOME_REAL")" ">echo FROM_BARE_HOME"

# HOME reached through a symlink: connect_dir works on the PHYSICAL path, so
# expanding ~ to the logical $HOME alone can never match.
expect "a ~/ pattern matches when \$HOME is a symlink (dir is a physical path)" \
  "$(hydrate "$HOME_REAL/linked" "$HOME_LINK")" ">echo FROM_LINKED_HOME"

# --- TAB-separated: the pattern may contain spaces ----------------------------
expect "a TAB separates, so a pattern can contain a space (~/My Projects/*)" \
  "$(hydrate "$HOME_REAL/My Projects/web")" ">echo FROM_SPACED_PATTERN"

# --- CRLF: the CR is not typed as a second Enter ------------------------------
expect "a CRLF startup.conf line sends the command once, with no stray Enter" \
  "$(hydrate "$HOME_REAL/crlf")" ">echo FROM_CRLF"

proj="$HOME_REAL/crlfproj"; mkdir -p "$proj"
printf 'echo CRLF_ONE\r\necho CRLF_TWO\r\n' > "$proj/.interdimux-startup"
expect "a CRLF .interdimux-startup sends each line once, with no stray Enter" \
  "$(hydrate "$proj")" ">echo CRLF_ONE
>echo CRLF_TWO"

# --- an indented line is still a pattern line ----------------------------------
expect "leading whitespace before a pattern is ignored" \
  "$(hydrate "$HOME_REAL/indented")" ">echo FROM_INDENTED"

# --- only a leading ~ is expanded: $HOME in a pattern stays literal -------------
printf '%s\n' '$HOME/dollar  echo FROM_DOLLAR_HOME' > "$CONF"
expect "\$HOME in a pattern is not expanded (documented), so it does not match" \
  "$(hydrate "$HOME_REAL/dollar")" ""

# --- an absolute pattern keeps working ---------------------------------------
printf '%s/abs*\techo FROM_ABSOLUTE\n' "$HOME_REAL" > "$CONF"
expect "an absolute pattern still matches" \
  "$(hydrate "$HOME_REAL/absolute")" ">echo FROM_ABSOLUTE"

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
