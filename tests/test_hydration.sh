#!/usr/bin/env bash
#
# Session hydration (#13): a newly created session runs its project's startup
# command.
#
# The delivery mechanism is `send-keys`, not the pane's initial command --
# sesh shipped exec-based delivery in v2.26.0 and reverted it in v2.26.2
# (lost prompt echo, lost shell history, pane reparented on exit, double shell
# init).  send-keys races shell startup instead, which is why wait_pane_ready
# exists and why these tests use a shell that takes a moment to initialise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-hydrate-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-hydrate.XXXXXX")"
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

echo "interdimux hydration tests"
echo

tmux -f /dev/null -L "$SOCK" new-session -d -s anchor -x 120 -y 30
# connect_dir creates its own sessions, so the pane shell cannot be passed per
# session -- pin it on the server.  Without this every pane starts the user's
# real login shell and sources their rc, and on a loaded box that shell had not
# reached a prompt before the test's `clear` was sent: the first hydration's
# output was still on screen and the re-hydration check failed spuriously.
tmux -L "$SOCK" set -g default-command 'bash --norc --noprofile -i' 
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=anchor:' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_USE_ZOXIDE=off
export XDG_CONFIG_HOME="$TMPD/config"
export XDG_DATA_HOME="$TMPD/data"
mkdir -p "$XDG_CONFIG_HOME/interdimux" "$XDG_DATA_HOME"

# Drive connect_dir directly: source the script's functions without running a
# picker.  --session-name-for is a cheap existing entry point, but hydration
# needs the real thing, so use a tiny harness mode instead.
run_connect() { # $1 = dir, extra env in the caller
  bash -c '
    set -euo pipefail
    INTERDIMUX_CONNECT_DIR="$2" exec bash "$1" --connect-dir "$2"
  ' _ "$SCRIPT" "$1" 2>&1
}

marker_in() { # $1 = session, returns the pane content
  tmux -L "$SOCK" capture-pane -t "=$1:" -p 2>/dev/null | tr -d '\r'
}

# --- 1. per-project .interdimux-startup --------------------------------------
proj="$TMPD/projalpha"; mkdir -p "$proj"
printf 'echo HYDRATED_ALPHA\n' > "$proj/.interdimux-startup"
run_connect "$proj" >/dev/null 2>&1 || true
sleep 2
if marker_in projalpha | grep -q 'HYDRATED_ALPHA'; then
  report "per-project .interdimux-startup runs in the new session" pass
else
  report "per-project .interdimux-startup runs in the new session" fail
  ERRORS+="$(marker_in projalpha | head -5)"$'\n'
fi

# --- 2. startup.conf glob beats the per-project file --------------------------
proj2="$TMPD/projbeta"; mkdir -p "$proj2"
printf 'echo FROM_PROJECT_FILE\n' > "$proj2/.interdimux-startup"
printf '%s/projbeta\techo FROM_GLOB_CONF\n' "$TMPD" > "$XDG_CONFIG_HOME/interdimux/startup.conf"
run_connect "$proj2" >/dev/null 2>&1 || true
sleep 2
out=$(marker_in projbeta)
if printf '%s' "$out" | grep -q 'FROM_GLOB_CONF' && ! printf '%s' "$out" | grep -q 'FROM_PROJECT_FILE'; then
  report "startup.conf glob takes precedence over the project file" pass
else
  report "startup.conf glob takes precedence over the project file" fail
  ERRORS+="$(printf '%s' "$out" | head -5)"$'\n'
fi

# --- 3. @interdimux-startup-command as the fallback ---------------------------
: > "$XDG_CONFIG_HOME/interdimux/startup.conf"
proj3="$TMPD/projgamma"; mkdir -p "$proj3"
INTERDIMUX_STARTUP_COMMAND='echo FROM_GLOBAL_OPTION' run_connect "$proj3" >/dev/null 2>&1 || true
sleep 2
if marker_in projgamma | grep -q 'FROM_GLOBAL_OPTION'; then
  report "@interdimux-startup-command is the fallback" pass
else
  report "@interdimux-startup-command is the fallback" fail
fi

# --- 4. no startup command configured => nothing sent -------------------------
proj4="$TMPD/projdelta"; mkdir -p "$proj4"
run_connect "$proj4" >/dev/null 2>&1 || true
sleep 1.5
if [ -z "$(marker_in projdelta | grep -c 'HYDRATED\|FROM_' || true)" ] || \
   ! marker_in projdelta | grep -q 'HYDRATED\|FROM_'; then
  report "no startup command configured leaves the session untouched" pass
else
  report "no startup command configured leaves the session untouched" fail
fi

# --- 5. hydrate=off disables it ----------------------------------------------
proj5="$TMPD/projeps"; mkdir -p "$proj5"
printf 'echo SHOULD_NOT_RUN\n' > "$proj5/.interdimux-startup"
INTERDIMUX_HYDRATE=off run_connect "$proj5" >/dev/null 2>&1 || true
sleep 1.5
if marker_in projeps | grep -q 'SHOULD_NOT_RUN'; then
  report "@interdimux-hydrate off disables hydration" fail
else
  report "@interdimux-hydrate off disables hydration" pass
fi

# --- 6. an EXISTING session is switched to, not re-hydrated -------------------
# Clear the pane first, so any marker seen afterwards can only have been sent
# again.  WAIT for the clear to land instead of sleeping: under load `clear` had
# not run within the old fixed 1 s, leaving the first hydration's output on
# screen and failing this as a spurious "ran again".
tmux -L "$SOCK" send-keys -t '=projalpha:' 'clear' Enter 2>/dev/null || true
cleared=0
for _i in $(seq 1 100); do
  [ "$(marker_in projalpha | grep -c 'HYDRATED_ALPHA' || true)" -eq 0 ] && { cleared=1; break; }
  sleep 0.1
done
if [ "$cleared" != 1 ]; then
  report "the pane could be cleared before re-connecting (precondition)" fail
fi
run_connect "$proj" >/dev/null 2>&1 || true
sleep 1.5
n=$(marker_in projalpha | grep -c 'HYDRATED_ALPHA' || true)
if [ "$n" -eq 0 ]; then
  report "connecting to an existing session does not re-run startup" pass
else
  report "connecting to an existing session does not re-run startup (ran again)" fail
fi

# --- 7. multi-line startup sends each line ------------------------------------
proj7="$TMPD/projzeta"; mkdir -p "$proj7"
printf 'echo LINE_ONE\necho LINE_TWO\n' > "$proj7/.interdimux-startup"
run_connect "$proj7" >/dev/null 2>&1 || true
sleep 2.5
out=$(marker_in projzeta)
if printf '%s' "$out" | grep -q 'LINE_ONE' && printf '%s' "$out" | grep -q 'LINE_TWO'; then
  report "a multi-line startup file sends every line" pass
else
  report "a multi-line startup file sends every line" fail
  ERRORS+="$(printf '%s' "$out" | head -6)"$'\n'
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
