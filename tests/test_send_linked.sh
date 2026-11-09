#!/usr/bin/env bash
# Session sends address physical panes once, even when tmux repeats window links.
# Catchers record what they read; per-pane sentinels drain all preceding input.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${IMUX_TEST_SCRIPT:-$ROOT/scripts/interdimux.sh}"
SOCK="interdimux-send-linked-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-send-linked.XXXXXX")"
TMPD="$(cd "$TMPD" && pwd -P)"
PASS=0 FAIL=0

T() { tmux -f /dev/null -L "$SOCK" "$@"; }
cleanup() { T kill-server 2>/dev/null || true; rm -rf "$TMPD"; }
trap cleanup EXIT
report() {
  if [ "$2" = pass ]; then
    PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"
  fi
}
wait_line() {
  local file="$1" line="$2" i
  for ((i=0; i<100; i++)); do
    grep -qxF -- "$line" "$file" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

p0=$(T new-session -d -s primary -n linked -x 120 -y 40 -c "$TMPD" -P -F '#{pane_id}' 'exec cat >> p0')
p1=$(T split-window -h -t '=primary:0' -c "$TMPD" -P -F '#{pane_id}' 'exec cat >> p1')
p2=$(T new-window -d -t '=primary:1' -c "$TMPD" -P -F '#{pane_id}' 'exec cat >> p2')
p3=$(T new-session -d -s other -x 120 -y 40 -c "$TMPD" -P -F '#{pane_id}' 'exec cat >> p3')
T link-window -s '=primary:0' -t '=primary:2'
T link-window -s '=primary:0' -t '=primary:4'
T link-window -s '=primary:0' -t '=other:2'
T link-window -s '=primary:0' -t '=other:4'

export TMUX="$(T display-message -p '#{socket_path}'),99999,0" TMUX_PANE="$p0"
export INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_USE_ZOXIDE=off
export XDG_CONFIG_HOME="$TMPD/config" XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
panes=("$p0" "$p1" "$p2" "$p3")

# Ensure every catcher has received input before testing delivery.
for i in 0 1 2 3; do
  T send-keys -t "${panes[$i]}" -l -- ready
  T send-keys -t "${panes[$i]}" Enter
  wait_line "$TMPD/p$i" ready
done
rows=$(T list-panes -s -t '=primary' -F '#{pane_id}' | wc -l | tr -d ' ')
if [ "$rows" = 7 ]; then report 'fixture has seven links for three physical panes' pass
else report "fixture has seven links for three physical panes (got $rows)" fail; fi

check_send() {
  local name="$1" spec="$2" marker="$3" expected_count="$4" i got wanted sentinel
  shift 4
  local expected=("$@")
  printf '%s\n' "$marker" > "$TMPD/input"
  INTERDIMUX_TTY_IN="$TMPD/input" INTERDIMUX_TTY_OUT="$TMPD/dialog" \
    timeout 20 bash "$SCRIPT" --action send "$spec" >/dev/null 2>&1
  if grep -qF "sent to $expected_count pane(s)" "$TMPD/dialog"; then
    report "$name: dialog counts physical recipients" pass
  else
    report "$name: dialog counts physical recipients" fail
  fi
  for i in 0 1 2 3; do
    sentinel="drained-$marker-$i"
    T send-keys -t "${panes[$i]}" -l -- "$sentinel"
    T send-keys -t "${panes[$i]}" Enter
    wait_line "$TMPD/p$i" "$sentinel"
    got=$(grep -xcF -- "$marker" "$TMPD/p$i" || :)
    wanted="${expected[$i]}"
    if [ "$got" = "$wanted" ]; then
      report "$name: pane $i receives $wanted copy" pass
    else
      report "$name: pane $i receives $wanted copy (got $got)" fail
    fi
  done
}

check_send 'repeated links in source session' S:primary linked-primary 3 1 1 1 0
check_send 'shared links in another session' S:other linked-other 3 1 1 0 1
check_send 'one selected window link' W:primary:2 linked-window 2 1 1 0 0
check_send 'one selected pane link' P:primary:4:0 linked-pane 1 1 0 0 0

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
