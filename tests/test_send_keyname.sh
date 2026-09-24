#!/usr/bin/env bash
#
# "Send keys" can press a key.  When the WHOLE text given to ctrl-t's send, or
# to a scheduled send (--send-in / --send-at), is exactly one control or
# navigation key name in tmux's spelling -- C-c, M-x, C-M-x, ^x, Escape,
# Up/Down/Left/Right, PPage/NPage, BTab, F1-F12 -- that key is pressed, with
# no Enter after it.  Anything else is typed literally and then Enter is
# pressed, including words that merely look like keys (Enter, Home, c-c,
# "C-c C-c").  Startup commands (hydration) are always typed literally.
#
# Why: making every send literal (`send-keys -l`, so a trailing ';' and a text
# like `Enter` arrive intact -- see tests/test_send_literal.sh) also took away
# the one practical use of a key name: C-c typed into a pane arrived as the
# text "C-c" plus Enter, and the program kept running.  Reproduced on tmux
# 3.7b against a trap-catcher pane: before, no SIGINT and the line "C-c".
#
# The oracles are what the pane's program saw:
#   * a SIGINT catcher, `trap 'echo GOT_SIGINT' INT` around cat, for C-c;
#   * a raw catcher, `cat -v` with the tty in non-canonical mode, for the other
#     keys, so an Escape arrives as "^[" and an Up as "^[[A".
# "No Enter after the key" is a negative, so every case ends with a sentinel
# line typed by the test itself: the tty delivers in order, so once the
# sentinel is in the file, whatever the send produced is in front of it.
#
# No real at(1) job is ever submitted: `at` is a PATH shim that keeps the job
# body and queues nothing, and the body is then run under /bin/sh, as atd would.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-sendkey-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-sendkey.XXXXXX")"
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

# expect NAME GOT WANT -- exact comparison, both sides shown on failure
expect() {
  if [ "$2" = "$3" ]; then
    report "$1" pass
  else
    report "$1" fail
    ERRORS+="    want: $(printf '%s' "$3" | cat -A | tr '\n' '|')"$'\n'
    ERRORS+="    got : $(printf '%s' "$2" | cat -A | tr '\n' '|')"$'\n'
  fi
}

T() { tmux -L "$SOCK" "$@"; }

echo "interdimux send-a-key tests"
echo

# A SIGINT catcher: every C-c that reaches the pane as an interrupt writes
# GOT_SIGINT, and cat is restarted, so one pane serves several cases.
sigcatcher() { # $1 file
  printf '%s' "trap 'echo GOT_SIGINT >> $1' INT; while :; do cat >> $1; done"
}
# A raw catcher: no line discipline, so each key arrives as it was pressed, and
# cat -v makes the control bytes readable.
rawcatcher() { # $1 file
  printf '%s' "stty -icanon -echo min 1 time 0; exec cat -v >> $1"
}

T -f /dev/null new-session -d -s key -x 200 -y 40 -c "$TMPD" "sh -c \"$(sigcatcher "$TMPD/sig")\""
T new-window -d -t '=key:1' -c "$TMPD" "sh -c \"$(rawcatcher "$TMPD/raw")\""
# window 2: two SIGINT catchers, for the fan-out case
T new-window -d -t '=key:2' -c "$TMPD" "sh -c \"$(sigcatcher "$TMPD/w2a")\""
T split-window -d -t '=key:2' -c "$TMPD" "sh -c \"$(sigcatcher "$TMPD/w2b")\""
# sessions connect_dir creates (hydration) run a catcher in their own dir
T set -g default-shell /bin/sh
T set -g default-command 'exec cat >> .caught'
export TMUX="$(T display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(T list-panes -t '=key:0' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_HYDRATE=on INTERDIMUX_STARTUP_COMMAND=''
export XDG_CONFIG_HOME="$TMPD/config" XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
P_SIG="$TMUX_PANE"
P_RAW="$(T list-panes -t '=key:1' -F '#{pane_id}' | head -1)"

# wait_for FILE PATTERN -- until FILE has a line matching the fixed string
wait_for() {
  local i
  for (( i = 0; i < 200; i++ )); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

# The raw catcher only reads once stty has run: wait until it echoes a probe.
T send-keys -t "$P_RAW" -l -- 'READY'
wait_for "$TMPD/raw" 'READY' || report "the raw catcher starts (precondition)" fail
: > "$TMPD/raw"

# settle PANE FILE -- type a sentinel line into PANE and wait for it in FILE.
# Everything sent to PANE before it has then been read.  Prints what FILE holds
# in front of the sentinel, each newline shown as ⏎ (a command substitution
# would drop a trailing one, and a trailing newline is exactly how an Enter
# shows), then empties FILE for the next case.
_sn=0
settle() {
  _sn=$((_sn + 1))
  local s="SENTINEL$_sn" c
  T send-keys -t "$1" -l -- "$s"
  T send-keys -t "$1" Enter
  wait_for "$2" "$s" || true
  c=$(cat "$2" 2>/dev/null; printf x); c="${c%x}"
  c="${c%%"$s"*}"
  printf '%s' "${c//$'\n'/⏎}"
  : > "$2"
}

# run_send SPEC TEXT -- ctrl-t's send action, the text answered from a file
DIALOG=""
run_send() {
  printf '%s\n' "$2" > "$TMPD/in"
  : > "$TMPD/out"
  INTERDIMUX_TTY_IN="$TMPD/in" INTERDIMUX_TTY_OUT="$TMPD/out" \
    timeout 20 bash "$SCRIPT" --action send "$1" >/dev/null 2>&1
  DIALOG=$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$TMPD/out")
}

# --- ctrl-t: a lone key name is pressed ----------------------------------------
: > "$TMPD/sig"
run_send 'P:key:0:0' 'C-c'
# (An Enter after a C-c would not show here: the interrupt flushes the tty's
# input queue.  The raw-catcher cases below are the ones that see an Enter.)
expect "send: C-c interrupts the pane's program instead of being typed" \
  "$(settle "$P_SIG" "$TMPD/sig")" "GOT_SIGINT⏎"
if [[ "$DIALOG" == *'sent to 1 pane(s)'* && "$DIALOG" != *failed* ]]; then
  report "send: ...and the dialog reports it sent" pass
else
  report "send: ...and the dialog reports it sent" fail
  ERRORS+="    drew: $(printf '%s' "$DIALOG" | tr -s ' ' | tail -c 120)"$'\n'
fi

# key_case NAME TEXT WANT -- send TEXT to the raw catcher; WANT is what cat -v
# shows before the sentinel (a trailing newline there would be an Enter)
key_case() {
  run_send 'P:key:1:0' "$2"
  expect "$1" "$(settle "$P_RAW" "$TMPD/raw")" "$3"
}
key_case "send: Escape is pressed, not typed"           'Escape' '^['
key_case "send: Up is pressed, not typed"               'Up'     '^[[A'
key_case "send: F5 is pressed, not typed"               'F5'     '^[[15~'
key_case "send: M-x is pressed as Meta-x"               'M-x'    '^[x'
key_case "send: ^d is pressed as Ctrl-d"                '^d'     '^D'
# tmux's argv parser reads a word ending in ';' as a command separator
key_case "send: M-; is pressed, its ';' intact"         'M-;'    '^[;'

# --- ...and everything else is still typed, then Enter -----------------------
key_case "send: Home (a key name, but not a control or motion key) is typed" \
  'Home' 'Home⏎'
key_case "send: Enter is typed, not pressed" 'Enter' 'Enter⏎'
key_case "send: c-c (not tmux's spelling) is typed" 'c-c' 'c-c⏎'
key_case "send: 'C-c C-c' (two keys) is typed" 'C-c C-c' 'C-c C-c⏎'
key_case "send: a key name with a trailing blank is typed" 'Up ' 'Up ⏎'
key_case "send: F13 (no such key) is typed" 'F13' 'F13⏎'

# --- fan-out, and a pane in copy-mode -------------------------------------------
: > "$TMPD/w2a"; : > "$TMPD/w2b"
run_send 'W:key:2' 'C-c'
expect "send: C-c to a window interrupts its first pane" \
  "$(settle "$(T list-panes -t '=key:2' -F '#{pane_id}' | sed -n 1p)" "$TMPD/w2a")" "GOT_SIGINT⏎"
expect "send: ...and its second pane" \
  "$(settle "$(T list-panes -t '=key:2' -F '#{pane_id}' | sed -n 2p)" "$TMPD/w2b")" "GOT_SIGINT⏎"

T copy-mode -t "$P_SIG"
if [ "$(T display-message -p -t "$P_SIG" '#{pane_in_mode}')" = 1 ]; then
  run_send 'P:key:0:0' 'C-c'
  expect "send: C-c to a pane in copy-mode leaves the mode and interrupts it" \
    "$(settle "$P_SIG" "$TMPD/sig")" "GOT_SIGINT⏎"
else
  report "send: the pane entered copy-mode (precondition)" fail
fi

# --- scheduled: --send-in under a minute (tmux run-shell, then /bin/sh) -------------
: > "$TMPD/sig"
bash "$SCRIPT" --send-in 1 "$P_SIG" 'C-c' >/dev/null 2>&1 || true
wait_for "$TMPD/sig" 'GOT_SIGINT' || true
expect "send-in (run-shell): C-c interrupts the pane when it fires" \
  "$(settle "$P_SIG" "$TMPD/sig")" "GOT_SIGINT⏎"

bash "$SCRIPT" --send-in 1 "$P_RAW" 'Escape' >/dev/null 2>&1 || true
wait_for "$TMPD/raw" '^[' || true
expect "send-in (run-shell): Escape is pressed when it fires" \
  "$(settle "$P_RAW" "$TMPD/raw")" "^["

# run-shell format-expands its command, so a '#' has to be doubled -- after the
# text is recognised as a key, not before ("M-##" is no key name)
bash "$SCRIPT" --send-in 1 "$P_RAW" 'M-#' >/dev/null 2>&1 || true
wait_for "$TMPD/raw" '#' || true
expect "send-in (run-shell): M-# is pressed when it fires, its '#' intact" \
  "$(settle "$P_RAW" "$TMPD/raw")" "^[#"

# --- scheduled: --send-at, the at job body run by /bin/sh as atd would -------------
shimdir="$TMPD/atshim"; mkdir -p "$shimdir"
cat > "$shimdir/at" <<'SHIM'
#!/bin/sh
# stands in for at(1): keeps the job body, queues nothing
case " $* " in *' -q '*) ;; *) echo "shim: Garbled time" >&2; exit 1 ;; esac
cat > "$IMUX_AT_BODY"
echo "job 4242 at Thu Jan  1 00:00:00 2099" >&2
SHIM
chmod +x "$shimdir/at"
if [ "$(PATH="$shimdir:$PATH" command -v at)" != "$shimdir/at" ]; then
  report "send-at: the at shim is the at that runs (else a real job would be queued)" fail
else
  rm -f "$TMPD/body"
  PATH="$shimdir:$PATH" IMUX_AT_BODY="$TMPD/body" INTERDIMUX_AT_DAEMON=up \
    bash "$SCRIPT" --send-at 'now + 1 hour' "$P_SIG" 'C-c' >/dev/null 2>&1 || true
  if [ -s "$TMPD/body" ]; then
    : > "$TMPD/sig"
    /bin/sh "$TMPD/body" >/dev/null 2>&1 || true
    wait_for "$TMPD/sig" 'GOT_SIGINT' || true
    expect "send-at (job body under /bin/sh): C-c interrupts the pane when it fires" \
      "$(settle "$P_SIG" "$TMPD/sig")" "GOT_SIGINT⏎"
    expect "send-at: the job's description is the key as written" \
      "$(sed -n 's/^# imux-desc: //p' "$TMPD/body")" "C-c"
  else
    report "send-at: C-c produced a job body" fail
  fi
fi

# --- hydration stays literal -----------------------------------------------------
# A startup file is a list of commands to type; a line that happens to be a key
# name is still typed.  The new session's pane runs `cat >> .caught`, which a
# pressed C-c would kill before it caught anything.
proj="$TMPD/keyproj"; mkdir -p "$proj"
printf '%s\n' 'C-c' 'Escape' > "$proj/.interdimux-startup"
bash "$SCRIPT" --connect-dir "$proj" >/dev/null 2>&1 || true
if T has-session -t '=keyproj' 2>/dev/null; then
  T send-keys -t '=keyproj:' -l -- 'SENTINEL'
  T send-keys -t '=keyproj:' Enter
  wait_for "$proj/.caught" 'SENTINEL' || true
fi
expect "hydration: startup lines that are key names are typed, not pressed" \
  "$(sed '/^SENTINEL$/,$d' "$proj/.caught" 2>/dev/null)" "C-c
Escape"

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
