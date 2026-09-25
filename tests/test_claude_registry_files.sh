#!/usr/bin/env bash
#
# What sits in Claude's session registry (~/.claude/sessions/<pid>.json) is
# read on every list, every reload and every prefix+g, so a file there that is
# not a record must never stop them (review R24):
#
#   * a FIFO named like a record (<digits>.json) is passed over: opening one
#     for reading blocks until a writer comes, and --list, prefix+g's count
#     and --doctor each blocked on it for good, in both renderers
#   * a record is read up to 65,536 characters: a longer file is not a record
#     (it would be read whole on every paint), so its pane shows no state
#   * a real record next to them is still read: its row says `approve`
#
# A private server; the registry is a scratch directory (INTERDIMUX_CLAUDE_DIR),
# never ~/.claude.  Each run is under a timeout, which is what a hang would hit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-claudereg-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-claudereg.XXXXXX")" && pwd -P)"
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

echo "interdimux Claude registry file tests"
echo

if [ ! -r /proc/self/stat ]; then
  echo "  (skipped: needs /proc for the registry's pid check)"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

RENDERERS="off"
[ -x "$BIN" ] && RENDERERS="off on"
[ -x "$BIN" ] || echo "  (the Rust core is not built: only the bash renderer is checked)"

unset TMUX TMUX_PANE
REG="$TMPD/claude/sessions"
mkdir -p "$REG" "$TMPD/home" "$TMPD/bin"
tm() { tmux -L "$SOCK" "$@"; }
# Two Claude panes: one with a record, one whose record is too long to be one.
tmux -f /dev/null -L "$SOCK" new-session -d -s reg -x 160 -y 30 -n rec -c "$TMPD" 'exec -a claude timeout 988 sleep 988'
tm new-window -d -t '=reg:' -n big -c "$TMPD" 'exec -a claude timeout 987 sleep 987'
PID_A=$(tm display-message -p -t '=reg:rec' '#{pane_pid}') PANE_A=$(tm display-message -p -t '=reg:rec' '#{pane_id}')
PID_B=$(tm display-message -p -t '=reg:big' '#{pane_pid}') PANE_B=$(tm display-message -p -t '=reg:big' '#{pane_id}')
settled() {
  [[ "$(tr '\0' ' ' < "/proc/$PID_A/cmdline")" == "claude "* ]] || return 1
  [[ "$(tr '\0' ' ' < "/proc/$PID_B/cmdline")" == "claude "* ]]
}
for _ in $(seq 1 100); do settled && break; sleep 0.05; done
# A record as Claude writes it; $3 pads it inside a string.
record() { # $1 pid, $2 pane, $3 padding, $4 status
  local -a st=()
  read -r -a st < "/proc/$1/stat"
  printf '{"pid":%s,"sessionId":"x","cwd":"/tmp","startedAt":1,"procStart":"%s","version":"2.1.281","kind":"interactive","entrypoint":"cli","tmux":"t:@1.%s","name":"%s","status":"%s","waitingFor":"permission prompt","statusUpdatedAt":%s}' \
    "$1" "${st[21]}" "$2" "$3" "$4" "$(( $(date +%s) * 1000 ))"
}
record "$PID_A" "$PANE_A" n waiting > "$REG/$PID_A.json"
record "$PID_B" "$PANE_B" "$(printf 'x%.0s' $(seq 70000))" waiting > "$REG/$PID_B.json"
mkfifo "$REG/424242.json"

export TMUX="$(tm display-message -p '#{socket_path}'),99999,0" TMUX_PANE="$PANE_A"
export HOME="$TMPD/home" XDG_CONFIG_HOME="$TMPD/xdg" XDG_STATE_HOME="$TMPD/state" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_CLAUDE_DIR="$TMPD/claude" INTERDIMUX_SHOW_DIRS=off INTERDIMUX_ORDER=index

# --list: within 5 s, the recorded pane's row says approve; the other is its
# command alone (arguments and all: an agent row with no state keeps them).
for r in $RENDERERS; do
  label="bash"; [ "$r" = on ] && label="rust"
  RC=0
  INTERDIMUX_USE_RUST="$r" timeout 5 bash "$SCRIPT" --list > "$TMPD/list" 2>/dev/null || RC=$?
  rows=$(awk -F'\t' '$4 ~ /^W:reg:/ { print $3 }' "$TMPD/list" | sed 's/\x1b\[[0-9;]*m//g')
  row_a=$(printf '%s\n' "$rows" | sed -n 1p) row_b=$(printf '%s\n' "$rows" | sed -n 2p)
  [ "$RC" = 0 ] && [[ "$row_a" == "claude ∣ approve"* ]] \
    && report "$label: a FIFO named like a record does not stop the list, and the record is read" pass \
    || report "$label: a FIFO named like a record does not stop the list, and the record is read (rc $RC, row '$row_a')" fail
  [ "$RC" = 0 ] && [ "$row_b" = "claude 987 sleep 987" ] \
    && report "$label: a record of more than 65,536 characters is not read" pass \
    || report "$label: a record of more than 65,536 characters is not read (rc $RC, row '$row_b')" fail
done

# prefix+g: no client is attached, so the dashboard takes its fzf fallback,
# and the stand-in fzf keeps the menu it is given.
cat > "$TMPD/bin/fzf" <<'EOF'
#!/bin/sh
case "$1" in --version) echo "0.74.0 (stand-in)"; exit 0 ;; esac
cat > "$FZF_IN"
exit 130
EOF
chmod +x "$TMPD/bin/fzf"
: > "$TMPD/menu"
RC=0
FZF_IN="$TMPD/menu" PATH="$TMPD/bin:$PATH" timeout 5 bash "$SCRIPT" --dashboard > /dev/null 2>&1 || RC=$?
[ "$RC" != 124 ] && grep -q '1 agent needs you' "$TMPD/menu" \
  && report "prefix+g counts past the FIFO: 1 agent needs you" pass \
  || report "prefix+g counts past the FIFO: 1 agent needs you (rc $RC)" fail

# --doctor reads the registry twice: its own count, and the list's reader
# (only once a record parses, which one here does).
RC=0
out=$(timeout 30 bash "$SCRIPT" --doctor 2>&1) || RC=$?
out=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g')
[ "$RC" != 124 ] && [[ "$out" == *"— 1 record parses"* ]] \
  && report "--doctor finishes with the FIFO there, and counts the one record that parses" pass \
  || report "--doctor finishes with the FIFO there, and counts the one record that parses (rc $RC)" fail
[[ "$out" == *"1 record there could not be read"* ]] \
  && report "...and says the FIFO could not be read" pass \
  || report "...and says the FIFO could not be read" fail
[[ "$out" == *"1 record there lacks what the list reads"* ]] \
  && report "...and that the long one is not a record it knows" pass \
  || report "...and that the long one is not a record it knows" fail

rm -f "$REG/424242.json"

echo
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
