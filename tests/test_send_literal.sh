#!/usr/bin/env bash
#
# Text typed into a pane arrives exactly as written, at every site that types
# it: ctrl-t's send, startup commands (hydration), the sub-minute --send-in
# (tmux run-shell, under /bin/sh) and the at-backed --send-at (a job body
# replayed by /bin/sh).
#
# What used to go wrong, all reproduced on tmux 3.7b:
#   * tmux's argv parser reads a word ending in ';' as a command separator and
#     turns a trailing '\;' into ';'.  `find . -exec echo {} \;` arrived as
#     `... {} ;` while the dialog said "sent"; `echo x;` failed outright; in
#     the scheduled paths the ';' was silently dropped.
#   * without send-keys -l, a command that is a key name (`Enter`) was PRESSED.
#
# The oracle is what the pane's program READ: every pane here runs
# `cat >> FILE`, so FILE holds each line exactly as the pane received it.
#
# No real at(1) job is ever submitted: `at` is a PATH shim that keeps the job
# body and queues nothing, and the body is then run the way atd would run it,
# under /bin/sh, against this suite's private tmux server.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-sendlit-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-sendlit.XXXXXX")"
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

echo "interdimux literal-send tests"
echo

# window 0: one catcher pane.  window 1: two, for the fan-out case.
T -f /dev/null new-session -d -s lit -x 200 -y 40 -c "$TMPD" "exec cat >> '$TMPD/p0'"
T new-window -d -t '=lit:1' -c "$TMPD" "exec cat >> '$TMPD/w1a'"
T split-window -d -t '=lit:1' -c "$TMPD" "exec cat >> '$TMPD/w1b'"
# sessions connect_dir creates (hydration) run a catcher in their own dir too
T set -g default-shell /bin/sh
T set -g default-command 'exec cat >> .caught'
export TMUX="$(T display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(T list-panes -t '=lit:0' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_HYDRATE=on INTERDIMUX_STARTUP_COMMAND=''
export XDG_CONFIG_HOME="$TMPD/config" XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
P0="$TMUX_PANE"

nlines() { local n=0; [ -f "$1" ] && n=$(wc -l < "$1"); echo $((n)); }

# wait_for_line FILE LINE [SECS] -- wait until FILE holds LINE as a whole line
wait_for_line() {
  local f="$1" want="$2" secs="${3:-10}" i
  for (( i = 0; i < secs * 20; i++ )); do
    grep -qxF -- "$want" "$f" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

# next_line FILE N [SECS] -- wait for FILE to hold N lines, print line N
next_line() {
  local f="$1" n="$2" secs="${3:-10}" i
  for (( i = 0; i < secs * 20; i++ )); do
    if [ "$(nlines "$f")" -ge "$n" ]; then sed -n "${n}p" "$f"; return 0; fi
    sleep 0.05
  done
  echo "<nothing arrived>"
}

# run_send SPEC TEXT -- ctrl-t's send action, answered from a file.  Sets DIALOG
# to what the dialog drew, escape sequences stripped.
DIALOG=""
run_send() {
  printf '%s\n' "$2" > "$TMPD/in"
  : > "$TMPD/out"
  INTERDIMUX_TTY_IN="$TMPD/in" INTERDIMUX_TTY_OUT="$TMPD/out" \
    timeout 20 bash "$SCRIPT" --action send "$1" >/dev/null 2>&1
  DIALOG=$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$TMPD/out")
}

# send_case NAME TEXT -- send TEXT to pane 0 and compare what it read
send_case() {
  local n=$(( $(nlines "$TMPD/p0") + 1 ))
  run_send 'P:lit:0:0' "$2"
  expect "$1" "$(next_line "$TMPD/p0" "$n")" "$2"
}

# --- ctrl-t send ----------------------------------------------------------------
send_case "send: a command ending in ';' is typed intact" 'echo trailing;'
if [[ "$DIALOG" == *'sent to 1 pane(s)'* && "$DIALOG" != *failed* ]]; then
  report "send: ...and the dialog reports it sent, not failed" pass
else
  report "send: ...and the dialog reports it sent, not failed" fail
  ERRORS+="    drew: $(printf '%s' "$DIALOG" | tr -s ' ' | tail -c 120)"$'\n'
fi
send_case "send: find -exec ... \\; keeps its backslash" 'find . -maxdepth 0 -exec echo FOUND {} \;'
send_case "send: a trailing \\\\; keeps both backslashes" 'echo two \\;'
send_case "send: a lone ';' is typed" ';'
send_case "send: a command that is a key name (Enter) is typed, not pressed" 'Enter'
send_case "send: a command starting with '-' is typed, not read as a flag" '-n starts with a dash'

# --- hydration -----------------------------------------------------------------
proj="$TMPD/hydproj"; mkdir -p "$proj"
printf '%s\n' 'find . -maxdepth 0 -exec echo HYD {} \;' 'echo hyd2;' > "$proj/.interdimux-startup"
bash "$SCRIPT" --connect-dir "$proj" >/dev/null 2>&1 || true
# a sentinel typed after connect_dir returned marks the end of what it sent
if T has-session -t '=hydproj' 2>/dev/null; then
  T send-keys -t '=hydproj:' -l -- 'SENTINEL'
  T send-keys -t '=hydproj:' Enter
  wait_for_line "$proj/.caught" 'SENTINEL' || true
fi
expect "hydration: startup lines ending in \\; and ; are typed intact" \
  "$(sed '/^SENTINEL$/,$d' "$proj/.caught" 2>/dev/null)" \
  "find . -maxdepth 0 -exec echo HYD {} \\;
echo hyd2;"

# --- --send-in under a minute: tmux run-shell, then /bin/sh -------------------------
for text in 'echo sub;' 'find . -maxdepth 0 -exec echo SUB {} \;'; do
  n=$(( $(nlines "$TMPD/p0") + 1 ))
  bash "$SCRIPT" --send-in 1 "$P0" "$text" >/dev/null 2>&1 || true
  expect "send-in (run-shell): '$text' arrives intact" "$(next_line "$TMPD/p0" "$n" 15)" "$text"
done

# --- --send-at: the at job body, run by /bin/sh as atd would -------------------------
shimdir="$TMPD/atshim"; mkdir -p "$shimdir"
cat > "$shimdir/at" <<'SHIM'
#!/bin/sh
# stands in for at(1): keeps the job body, queues nothing
case " $* " in *' -q '*) ;; *) echo "shim: Garbled time" >&2; exit 1 ;; esac
cat > "$IMUX_AT_BODY"
echo "job 4242 at Thu Jan  1 00:00:00 2099" >&2
SHIM
chmod +x "$shimdir/at"
# submit_at TEXT -- run --send-at with the shim; the body lands in $TMPD/body
submit_at() {
  rm -f "$TMPD/body"
  PATH="$shimdir:$PATH" IMUX_AT_BODY="$TMPD/body" INTERDIMUX_AT_DAEMON=up \
    bash "$SCRIPT" --send-at 'now + 1 hour' "$P0" "$1" >/dev/null 2>&1 || true
}

AT_SHIM_OK=0
[ "$(PATH="$shimdir:$PATH" command -v at)" = "$shimdir/at" ] && AT_SHIM_OK=1
if [ "$AT_SHIM_OK" != 1 ]; then
  report "send-at: the at shim is the at that runs (else a real job would be queued)" fail
else
  for text in 'echo at;' 'find . -maxdepth 0 -exec echo AT {} \;'; do
    submit_at "$text"
    if [ ! -s "$TMPD/body" ]; then
      report "send-at: '$text' produced a job body" fail
      continue
    fi
    expect "send-at: the job's description is the command as written ('$text')" \
      "$(sed -n 's/^# imux-desc: //p' "$TMPD/body")" "$text"
    n=$(( $(nlines "$TMPD/p0") + 1 ))
    /bin/sh "$TMPD/body" >/dev/null 2>&1 || true
    expect "send-at (job body under /bin/sh): '$text' arrives intact" \
      "$(next_line "$TMPD/p0" "$n")" "$text"
  done
fi

# --- a pane in copy-mode ------------------------------------------------------------
# Keys sent to a pane in copy-mode were read as copy-mode BINDINGS: with vi keys
# the `D` in "echo COPYMODE" copied into a new paste buffer and left the mode,
# the rest failed with "not in a mode", the command never ran, and the dialog
# said "1 failed" with no reason.  A W: fan-out silently missed that one pane.
# The pane is now taken out of the mode first, at every site.
T set -g mode-keys vi
in_mode() { T display-message -p -t "$1" '#{pane_in_mode}' 2>/dev/null; }
bufs() { T list-buffers 2>/dev/null | wc -l | tr -d ' '; }

T copy-mode -t '=lit:1.1'
if [ "$(in_mode '=lit:1.1')" = 1 ]; then
  b0=$(bufs)
  na=$(( $(nlines "$TMPD/w1a") + 1 )); nb=$(( $(nlines "$TMPD/w1b") + 1 ))
  run_send 'W:lit:1' 'echo COPYMODE'
  expect "copy-mode: a W: fan-out reaches the pane that is not in a mode" \
    "$(next_line "$TMPD/w1a" "$na")" 'echo COPYMODE'
  expect "copy-mode: ...and the pane that was in copy-mode runs it too" \
    "$(next_line "$TMPD/w1b" "$nb")" 'echo COPYMODE'
  if [[ "$DIALOG" == *'sent to 2 pane(s)'* && "$DIALOG" != *failed* ]]; then
    report "copy-mode: ...and the dialog reports 2 sent, none failed" pass
  else
    report "copy-mode: ...and the dialog reports 2 sent, none failed" fail
    ERRORS+="    drew: $(printf '%s' "$DIALOG" | tr -s ' ' | tail -c 120)"$'\n'
  fi
  expect "copy-mode: ...and no paste buffer was written on the way" "$(bufs)" "$b0"
else
  report "copy-mode: the pane entered copy-mode (precondition)" fail
fi

# the scheduled paths: the pane is scrolled back when the command fires
T copy-mode -t "$P0"
if [ "$(in_mode "$P0")" = 1 ]; then
  n=$(( $(nlines "$TMPD/p0") + 1 ))
  bash "$SCRIPT" --send-in 1 "$P0" 'echo COPY_SUB' >/dev/null 2>&1 || true
  expect "copy-mode: a --send-in firing into a pane in copy-mode runs" \
    "$(next_line "$TMPD/p0" "$n" 15)" 'echo COPY_SUB'
else
  report "copy-mode: pane 0 entered copy-mode for --send-in (precondition)" fail
fi
T copy-mode -t "$P0"
if [ "$AT_SHIM_OK" != 1 ]; then
  :   # already reported above; never let a real at run
elif [ "$(in_mode "$P0")" = 1 ]; then
  submit_at 'echo COPY_AT'
  n=$(( $(nlines "$TMPD/p0") + 1 ))
  [ -s "$TMPD/body" ] && /bin/sh "$TMPD/body" >/dev/null 2>&1
  expect "copy-mode: an at job firing into a pane in copy-mode runs" \
    "$(next_line "$TMPD/p0" "$n")" 'echo COPY_AT'
else
  report "copy-mode: pane 0 entered copy-mode for --send-at (precondition)" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
