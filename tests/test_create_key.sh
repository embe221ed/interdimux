#!/usr/bin/env bash
#
# The create key (review UX-54): alt-enter creates a session from the query
# WHATEVER the query matches.
#
# Enter only creates at zero matches, and in the default name+cmd scope the
# command column is a pane's whole argv.  One pane running
#
#   kubectl logs -f deployment/payments-api -n production --since=1h
#
# scatter-matches docs, blog, auth, cli, search...: typing `docs` leaves one
# match, Enter switches to that pane, and find-or-create is unreachable for an
# ordinary name.  An agent row's state word and description (`claude working
# Fix login timeout`) are more words in the same column.  So:
#
#   * with that one scattered match under the cursor, the bar names what
#     alt-enter makes, and alt-enter creates `docs` and the client that pressed
#     it lands there; the same past an agent row's state word (`work`)
#   * fzf's own exact syntax is the other way out: `'docs` reaches zero
#     matches, and Enter must then create `docs`, not a session called `'docs`
#   * the bar's entry follows every keystroke and goes with the query
#   * alt-enter on an empty query, or on one that is only fzf syntax, does
#     nothing: the navigator stays open
#
# Real clients and real key presses throughout: an inner server under test, an
# outer one whose pane holds a `tmux attach` client to it, and the plugin's own
# prefix+f binding opening the popup -- so M-Enter goes through tmux to fzf the
# way a keyboard's does, and the switch lands on a real client.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BASE="interdimux-ckey-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-ckey.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""
SOCK="" OUTER="" N=0 SOCKS=()

# Never the server this suite was started from: every tmux call below names its
# socket, and nothing inherits a TMUX that points anywhere else.
unset TMUX TMUX_PANE

cleanup() {
  local s
  for s in ${SOCKS[@]+"${SOCKS[@]}"}; do tmux -L "$s" kill-server 2>/dev/null || true; done
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
I() { tmux -L "$SOCK" "$@"; }    # the server under test
O() { tmux -L "$OUTER" "$@"; }   # the one whose pane is its client
screen() { { O capture-pane -p -t '=A:' 2>/dev/null || true; } | sed 's/\x1b\[[0-9;]*m//g'; }
wait_for() { # $1 = a command that must succeed; bounded poll, no fixed sleep
  local i
  for i in $(seq 1 "${2:-100}"); do eval "$1" && return 0; sleep 0.1; done
  return 1
}
press() { O send-keys -t '=A:' "$@"; }
client_session() { I list-clients -F '#{client_session}' 2>/dev/null | head -1; }
sessions() { I list-sessions -F '#{session_name}' 2>/dev/null | sort; }
# The prompt line: the query, then fzf's match count once the search is done.
prompt_line() { screen | grep -m1 '❯' || true; }
# The row under fzf's cursor.
cursor_row() { screen | grep -m1 '▌' || true; }
# The hint bar: the footer, the last line that names a key.
bar() { screen | grep -E 'enter|create|M-⏎|\^x' | tail -1 | sed 's/^ *//'; }

echo "interdimux create-key tests"
echo

fzf_minor=$(fzf --version 2>/dev/null | awk '{print $1}' | cut -d. -f2)
if [ "${fzf_minor:-0}" -lt 74 ]; then
  echo "  (skipped: needs fzf >= 0.74, found ${fzf_minor:-?})"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

KUBE='kubectl logs -f deployment/payments-api -n production --since=1h'

# Fresh servers per case: each ends with the client in a new session.
# $1 = @interdimux-raw value, $2 = @interdimux-fzf-opts (optional).
setup() {
  local raw="$1" fopts="${2:-}" home
  N=$((N + 1))
  SOCK="$BASE-$N" OUTER="$BASE-$N-o"
  SOCKS+=("$OUTER" "$SOCK")
  home="$TMPD/home$N"
  mkdir -p "$home" "$TMPD/state$N" "$TMPD/data$N"
  # The popup's environment is the server's: every file the script writes
  # (recent dirs, state) stays under $TMPD, no FZF_DEFAULT_OPTS of the user's
  # rebinds a key, and Claude's registry is looked for in the empty fake HOME.
  env -u CLAUDE_CONFIG_DIR HOME="$home" XDG_STATE_HOME="$TMPD/state$N" \
    XDG_DATA_HOME="$TMPD/data$N" XDG_CONFIG_HOME="$TMPD/config$N" FZF_DEFAULT_OPTS= \
    tmux -f /dev/null -L "$SOCK" new-session -d -s demo -x 120 -y 34 -c "$home" 'sleep 3600'
  # The sessions the create makes run this, not the user's login shell and rc.
  I set -g default-command 'bash --norc --noprofile -i'
  I new-session -d -s prod-db -x 120 -y 34 -c "$home" 'sleep 3600'
  # The long argv, through perl's $0 (no real kubectl): the process's cmdline
  # is what the command column shows.
  I new-window -d -t '=prod-db:1' -n logs -c "$home" "perl -e '\$0 = \"$KUBE\"; sleep 3600'"
  # An agent row: `claude` by argv0, with a state word and a description from
  # the pane options an agent plugin publishes.
  I new-session -d -s agents -x 120 -y 34 -c "$home" "perl -e '\$0 = \"claude\"; sleep 3600'"
  I rename-window -t '=agents:0' ai
  I set -p -t '=agents:0' @agent_state working
  I set -p -t '=agents:0' @agent_desc 'Fix login timeout'
  I new-session -d -s web -x 120 -y 34 -c "$home" 'sleep 3600'
  I set -g @interdimux-raw "$raw"
  I set -g @interdimux-use-zoxide off
  I set -g @interdimux-show-dirs off
  I set -g @interdimux-show-preview off
  [ -z "$fopts" ] || I set -g @interdimux-fzf-opts "$fopts"
  O -f /dev/null new-session -d -s A -x 120 -y 34 "TMUX= tmux -L $SOCK attach -t demo"
  wait_for '[ "$(I list-clients | wc -l)" = 1 ]' || return 1
  TMUX="$(I display-message -p '#{socket_path}'),99999,0" bash "$SCRIPT" --bind-keys
  # the argv really is in place before anything is typed
  wait_for "I list-panes -t '=prod-db:1' -F '#{pane_pid}' | xargs -I{} cat /proc/{}/cmdline 2>/dev/null | tr '\\0' ' ' | grep -q deployment/payments-api" 50 || return 1
  press C-b; press f
  # ...and the list shows both the kubectl row and the agent's state
  wait_for "screen | grep -q 'kubectl logs -f' && screen | grep -q 'claude working'" 150
}
# type $1, then wait until the prompt shows the query $3 (default: $1) with
# the count $2 (a regex)
type_q() {
  local i
  press -l "$1"
  for i in $(seq 1 100); do
    prompt_line | grep -F -- "❯ ${3:-$1}" | grep -qE -- "$2" && return 0
    sleep 0.1
  done
  return 1
}
close_all() {
  local s
  for s in "$OUTER" "$SOCK"; do tmux -L "$s" kill-server 2>/dev/null || true; done
}

for raw in on off; do
  # --- alt-enter creates past a scattered match ---------------------------------
  if setup "$raw"; then
    if type_q docs ' 1/' && cursor_row | grep -q 'prod-db 1:logs'; then
      report "[raw $raw] 'docs' scatter-matches the kubectl pane, and only it: 1 match, under the cursor" pass
    else
      report "[raw $raw] 'docs' scatter-matches the kubectl pane, and only it: 1 match, under the cursor" fail
      ERRORS+="    prompt: $(prompt_line)"$'\n'"    cursor: $(cursor_row | sed 's/  */ /g')"$'\n'
    fi
    # The bar names what alt-enter will make, while the match holds the cursor.
    if wait_for "screen | grep -qF 'M-⏎ create docs'" 80; then
      report "[raw $raw] with that match under the cursor, the bar says 'M-⏎ create docs'" pass
    else
      report "[raw $raw] with that match under the cursor, the bar says 'M-⏎ create docs'" fail
      ERRORS+="    bar: $(bar)"$'\n'
    fi
    press M-Enter
    wait_for '[ "$(client_session)" = docs ]' 100 || true
    got=$(client_session)
    if [ "$got" = docs ] && sessions | grep -qx docs; then
      report "[raw $raw] alt-enter creates 'docs' and the client lands there, not on prod-db:1" pass
    else
      report "[raw $raw] alt-enter creates 'docs' and the client lands there, not on prod-db:1" fail
      ERRORS+="    client on '$got'; sessions: $(sessions | tr '\n' ' ')"$'\n'
    fi
  else
    report "[raw $raw] the navigator opens over the kubectl fixture" fail
  fi
  close_all

  # --- 'docs + Enter: fzf's exact syntax, zero matches, creates `docs` ----------
  if setup "$raw"; then
    # Zero matches with the kubectl and agent rows present: the exact term
    # finds `docs` in neither.
    if type_q "'docs" ' 0/'; then
      report "[raw $raw] \"'docs\" matches nothing, agent rows included" pass
    else
      report "[raw $raw] \"'docs\" matches nothing, agent rows included" fail
      ERRORS+="    prompt: $(prompt_line)"$'\n'
    fi
    # The zero-match announcement names the name without the quote...
    if wait_for "screen | grep -qF 'create docs in'" 80; then
      report "[raw $raw] at zero matches the bar announces 'create docs', not \"'docs\"" pass
    else
      report "[raw $raw] at zero matches the bar announces 'create docs', not \"'docs\"" fail
      ERRORS+="    bar: $(bar)"$'\n'
    fi
    # ...and Enter makes that one.
    press Enter
    wait_for '[ "$(client_session)" != demo ]' 100 || true
    got=$(client_session)
    if [ "$got" = docs ] && ! sessions | grep -qF "'"; then
      report "[raw $raw] \"'docs\" + Enter creates 'docs' and lands there" pass
    else
      report "[raw $raw] \"'docs\" + Enter creates 'docs' and lands there" fail
      ERRORS+="    client on '$got'; sessions: $(sessions | tr '\n' ' ')"$'\n'
    fi
  else
    report "[raw $raw] the navigator opens over the kubectl fixture" fail
  fi
  close_all
done

# --- past an agent row's state word ------------------------------------------------
# `work` is a plain session name, and `working` is the state the agent row
# shows: the row matches, Enter would switch to the agent, alt-enter creates.
if setup on; then
  if type_q work ' 1/' && cursor_row | grep -q 'claude working'; then
    report "[agent] 'work' matches the agent row's state word, and only it" pass
  else
    report "[agent] 'work' matches the agent row's state word, and only it" fail
    ERRORS+="    prompt: $(prompt_line)"$'\n'"    cursor: $(cursor_row | sed 's/  */ /g')"$'\n'
  fi
  if wait_for "screen | grep -qF 'M-⏎ create work'" 80; then
    report "[agent] the bar says 'M-⏎ create work' over the agent row" pass
  else
    report "[agent] the bar says 'M-⏎ create work' over the agent row" fail
    ERRORS+="    bar: $(bar)"$'\n'
  fi
  press M-Enter
  wait_for '[ "$(client_session)" = work ]' 100 || true
  got=$(client_session)
  if [ "$got" = work ]; then
    report "[agent] alt-enter creates 'work' and the client lands there, not on the agent" pass
  else
    report "[agent] alt-enter creates 'work' and the client lands there, not on the agent" fail
    ERRORS+="    client on '$got'; sessions: $(sessions | tr '\n' ' ')"$'\n'
  fi
else
  report "[agent] the navigator opens over the agent fixture" fail
fi
close_all

# --- the bar follows the query, on every dispatch path ----------------------------
# The entry must track each keystroke, and go when the query is cleared, even
# when the cursor does not move -- then `focus` stays silent and only the
# `result` bind can rewrite the bar.  A user --with-shell takes the fallback
# path (--footer-for re-exec'd, and in raw mode the result guard deciding when).
#
#   * clearing: type the name of the session on row 1.  Its own row is the
#     best match, so the cursor stays on row 1 with the query and without it.
#     The entry says `switch to`, since that session exists.
#   * renaming: `doc`, then `s` -- the kubectl row is the only match of both.
for m in "on|" "off|" "on|--with-shell='bash -c'" "off|--with-shell='bash -c'"; do
  raw="${m%%|*}" fo="${m#*|}"
  label="raw $raw${fo:+, user --with-shell}"
  if setup "$raw" "$fo"; then
    first=$(cursor_row | sed -n 's/.*▸ \([^ ]*\) .*/\1/p')
    type_q "$first" ' [1-9][0-9]*/' || true
    if [ -n "$first" ] && cursor_row | grep -qF "▸ $first " \
       && wait_for "screen | grep -qF 'M-⏎ switch to $first'" 80; then
      report "[$label] row 1's own name, cursor unmoved: the bar says 'M-⏎ switch to <it>'" pass
    else
      report "[$label] row 1's own name, cursor unmoved: the bar says 'M-⏎ switch to <it>'" fail
      ERRORS+="    row 1: '$first'; cursor: $(cursor_row | sed 's/  */ /g')"$'\n'"    bar: $(bar)"$'\n'
    fi
    press C-u
    type_q '' ' [1-9][0-9]*/' '' || true
    if wait_for "screen | grep -qF 'enter switch' && ! screen | grep -qF 'M-⏎'" 80 \
       && cursor_row | grep -qF "▸ $first "; then
      report "[$label] clearing the query under an unmoved cursor drops the entry" pass
    else
      report "[$label] clearing the query under an unmoved cursor drops the entry" fail
      ERRORS+="    cursor: $(cursor_row | sed 's/  */ /g')"$'\n'"    bar: $(bar)"$'\n'
    fi
    type_q doc ' 1/' || true
    wait_for "screen | grep -qF 'M-⏎ create doc'" 80 || true
    type_q s ' 1/' docs || true
    if cursor_row | grep -q 'prod-db 1:logs' && wait_for "screen | grep -qF 'M-⏎ create docs'" 80; then
      report "[$label] a keystroke under an unmoved cursor renames the entry (doc -> docs)" pass
    else
      report "[$label] a keystroke under an unmoved cursor renames the entry (doc -> docs)" fail
      ERRORS+="    cursor: $(cursor_row | sed 's/  */ /g')"$'\n'"    bar: $(bar)"$'\n'
    fi
  else
    report "[$label] the navigator opens" fail
  fi
  close_all
done

# --- alt-enter on a query that names nothing does nothing ---------------------------
# Positive discriminator: after the key, the SAME popup still takes the next
# keystrokes and shows them -- fzf handles keys in order, so had alt-enter
# closed it, nothing typed after it could reach the prompt.  Then the client
# and the session list are checked untouched.
if setup on; then
  before=$(sessions)
  press M-Enter
  if type_q web ' [1-9][0-9]*/'; then
    report "empty query: alt-enter leaves the navigator open" pass
  else
    report "empty query: alt-enter leaves the navigator open" fail
    ERRORS+="    screen: $(screen | grep -v '^ *$' | head -2 | tr '\n' '|')"$'\n'
  fi
  # A query that is only fzf syntax names no session either: no bar entry,
  # and the key does what the bar says.
  press C-u
  type_q "'" ' [0-9]+/' || true
  press M-Enter
  if type_q web ' [0-9]+/' "'web"; then
    report "a query of only fzf syntax (') : alt-enter leaves the navigator open" pass
  else
    report "a query of only fzf syntax (') : alt-enter leaves the navigator open" fail
    ERRORS+="    screen: $(screen | grep -v '^ *$' | head -2 | tr '\n' '|')"$'\n'
  fi
  if [ "$(sessions)" = "$before" ] && [ "$(client_session)" = demo ]; then
    report "neither alt-enter created anything or switched anywhere" pass
  else
    report "neither alt-enter created anything or switched anywhere" fail
    ERRORS+="    client on '$(client_session)'; sessions: $(sessions | tr '\n' ' ')"$'\n'
  fi
else
  report "the navigator opens for the empty-query case" fail
fi
close_all

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
