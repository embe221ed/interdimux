#!/usr/bin/env bash
#
# One-list model (IDEAS #14): directory rows appear inline in the navigator, so
# Enter works whether or not a session exists yet.
#
# The two properties that matter beyond "they show up":
#   * they are emitted AFTER every tmux row, so they can neither delay the
#     first paint nor widen the tree's content-sized columns
#   * a directory that already has a session is not offered again

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-onelist-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-onelist.XXXXXX")"
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

# Wait for a CONDITION, not a duration.  Fixed sleeps were tuned on an idle box
# and failed when the suite ran back-to-back with the others (observed: the D:
# row assertion failing only inside a full-suite run, passing in isolation).
wait_for() { # $1 = description, $2.. = a command that must succeed
  local desc="$1"; shift
  local i
  for i in $(seq 1 150); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "  (timed out waiting for: $desc)" >&2
  return 1
}

echo "interdimux one-list (directory row) tests"
echo

mkdir -p "$TMPD/alpha" "$TMPD/beta" "$TMPD/taken" "$TMPD/data/interdimux"
mkdir -p "$TMPD/alpha/.git" && printf 'ref: refs/heads/main\n' > "$TMPD/alpha/.git/HEAD"
printf '{}\n' > "$TMPD/beta/package.json"
printf '%s\n%s\n%s\n' "$TMPD/alpha" "$TMPD/beta" "$TMPD/taken" > "$TMPD/data/interdimux/recent_dirs"

# "taken" already has a session, so it must not be offered as a directory
tmux -f /dev/null -L "$SOCK" new-session -d -s taken -x 200 -y 50 -c "$TMPD/taken"
tmux -L "$SOCK" new-window -d -t '=taken:' -c "$SCRIPT_DIR"

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=taken:0' -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_GIT_BRANCH=on
# the windows must exist before --list can be expected to show them
wait_for "the bench windows" sh -c "[ \"\$(tmux -L '$SOCK' list-windows -a | wc -l)\" -ge 2 ]"
# ...and --list must actually produce rows
wait_for "--list to produce rows" sh -c "bash '$SCRIPT' --list 2>/dev/null | grep -q ."

out=$(bash "$SCRIPT" --list 2>/dev/null)
plain=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g')
specs=$(printf '%s\n' "$plain" | awk -F'\t' '{print $4}')

# --- presence ----------------------------------------------------------------
if printf '%s\n' "$specs" | grep -qx "D:$TMPD/alpha"; then
  report "a recent directory appears as a D: row" pass
else
  report "a recent directory appears as a D: row" fail
  ERRORS+="$(printf '%s\n' "$specs" | head -8)"$'\n'
fi

# --- dedup against existing sessions -----------------------------------------
if printf '%s\n' "$specs" | grep -qx "D:$TMPD/taken"; then
  report "a directory that already has a session is NOT offered" fail
else
  report "a directory that already has a session is NOT offered" pass
fi

# --- ordering: every D row after every tmux row ------------------------------
last_tmux=$(printf '%s\n' "$specs" | grep -n '^[SWP]:' | tail -1 | cut -d: -f1)
first_dir=$(printf '%s\n' "$specs" | grep -n '^D:'     | head -1 | cut -d: -f1)
if [ -n "$last_tmux" ] && [ -n "$first_dir" ] && [ "$first_dir" -gt "$last_tmux" ]; then
  report "D: rows are emitted after every tmux row (first paint unaffected)" pass
else
  report "D: rows are emitted after every tmux row (got tmux@$last_tmux dir@$first_dir)" fail
fi

# --- row contract -------------------------------------------------------------
bad=$(printf '%s\n' "$out" | awk -F'\t' 'NF != 4 { print }')
if [ -z "$bad" ]; then
  report "D: rows keep the 4-field row contract" pass
else
  report "D: rows keep the 4-field row contract" fail
fi

# --- project type badge --------------------------------------------------------
if printf '%s\n' "$plain" | awk -F'\t' -v s="D:$TMPD/beta" '$4 == s {print $3}' | grep -q 'Node.js'; then
  report "D: rows carry a project-type badge" pass
else
  report "D: rows carry a project-type badge" fail
fi

# --- the disable switch ---------------------------------------------------------
if INTERDIMUX_SHOW_DIRS=off bash "$SCRIPT" --list 2>/dev/null | grep -q $'\tD:'; then
  report "@interdimux-show-dirs off removes them" fail
else
  report "@interdimux-show-dirs off removes them" pass
fi

# --- the cap --------------------------------------------------------------------
for i in 1 2 3 4 5 6; do mkdir -p "$TMPD/many$i"; echo "$TMPD/many$i" >> "$TMPD/data/interdimux/recent_dirs"; done
n=$(INTERDIMUX_DIRS_LIMIT=3 INTERDIMUX_RECENT_LIMIT=50 bash "$SCRIPT" --list 2>/dev/null | grep -c $'\tD:' || true)
if [ "$n" -eq 3 ]; then
  report "@interdimux-dirs-limit caps the number of D: rows (got $n)" pass
else
  report "@interdimux-dirs-limit caps the number of D: rows (got $n, want 3)" fail
fi

# --- Enter on a D: row creates, hydrates and switches ----------------------------
printf 'echo ONELIST_HYDRATED\n' > "$TMPD/alpha/.interdimux-startup"
bash "$SCRIPT" --connect-dir "$TMPD/alpha" >/dev/null 2>&1 || true
wait_for "the alpha session" tmux -L "$SOCK" has-session -t '=alpha'
wait_for "alpha to be hydrated" sh -c \
  "tmux -L '$SOCK' capture-pane -t '=alpha:' -p 2>/dev/null | grep -q ONELIST_HYDRATED"
if tmux -L "$SOCK" has-session -t '=alpha' 2>/dev/null; then
  report "opening a D: row creates the session" pass
else
  report "opening a D: row creates the session" fail
fi
if tmux -L "$SOCK" capture-pane -t '=alpha:' -p 2>/dev/null | grep -q 'ONELIST_HYDRATED'; then
  report "opening a D: row hydrates the new session" pass
else
  report "opening a D: row hydrates the new session" fail
fi
# ...and it now has a session, so it must drop out of the directory rows.
#
# Dedup keys on the cwd tmux reports for each session's ACTIVE window, and tmux
# derives that from /proc at query time — under a loaded box it can still be
# reporting the server's cwd for a pane whose shell has only just been forked.
# Wait for that precondition explicitly, so a slow box fails the wait (with the
# cwds printed) instead of silently failing the dedup assertion.
wait_for "tmux to report alpha's cwd" sh -c \
  "tmux -L '$SOCK' list-windows -a -F '#{?window_active,#{pane_current_path},}' \
     | grep -qx '$TMPD/alpha'" \
  || ERRORS+="    cwds: $(tmux -L "$SOCK" list-windows -a -F '#{session_name}=#{pane_current_path}' | tr '\n' ' ')"$'\n'

if bash "$SCRIPT" --list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -F'\t' '{print $4}' \
     | grep -qx "D:$TMPD/alpha"; then
  report "an opened directory drops out of the D: rows" fail
else
  report "an opened directory drops out of the D: rows" pass
fi

# --- the spec survives a path containing a colon ---------------------------------
odd="$TMPD/we:ird"; mkdir -p "$odd"
printf '%s\n' "$odd" > "$TMPD/data/interdimux/recent_dirs"
if bash "$SCRIPT" --list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -F'\t' '{print $4}' \
     | grep -qx "D:$odd"; then
  report "a directory path containing ':' round-trips in the spec" pass
else
  report "a directory path containing ':' round-trips in the spec" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
