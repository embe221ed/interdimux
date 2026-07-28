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

# --- the ctrl-o picker marks directories that already have a session (IDEAS #7) ---
# Enter on such a row switches rather than creates -- connect_dir finds the
# session first -- but the picker gave no sign of it, so "new session" on a
# directory you already had open looked like it had done nothing.  Naming the
# session is the useful half: it says where you are about to land.
#
# ("taken" is the fixture session created at $TMPD/taken during setup.)
dirs_out=$(INTERDIMUX_PROJECT_DIRS="$TMPD" bash "$SCRIPT" --dirs-list 2>/dev/null \
           | sed 's/\x1b\[[0-9;]*m//g')
taken_row=$(printf '%s\n' "$dirs_out" | awk -F'\t' -v p="$TMPD/taken" '$3 == p')
free_row=$(printf '%s\n' "$dirs_out"  | awk -F'\t' -v p="$TMPD/beta"  '$3 == p')

# Assert on the BADGE column, not the whole row: this fixture's session is named
# after its directory, so a row-wide match would pass on the path alone and the
# test would have no teeth.
taken_badge=$(printf '%s\n' "$taken_row" | awk -F'\t' '{print $2}')
if [ "$taken_badge" = "→ taken" ]; then
  report "the dir picker names the session already open in a directory" pass
else
  report "the dir picker names the session already open in a directory" fail
  ERRORS+="    badge: [$taken_badge]"$'\n'
fi
case "$taken_row" in
  *▸*) report "...and marks it with the session glyph, not the tier glyph" pass ;;
  *) report "...and marks it with the session glyph, not the tier glyph" fail
     ERRORS+="    row: [$taken_row]"$'\n' ;;
esac
# a directory with no session must be untouched, or the mark means nothing
free_badge=$(printf '%s\n' "$free_row" | awk -F'\t' '{print $2}')
case "$free_row" in
  '') report "a directory with no session is NOT marked (row missing)" fail ;;
  *▸*) report "a directory with no session is NOT marked" fail
       ERRORS+="    row: [$free_row]"$'\n' ;;
  *) case "$free_badge" in
       *→*) report "a directory with no session is NOT marked" fail
            ERRORS+="    badge: [$free_badge]"$'\n' ;;
       *)   report "a directory with no session is NOT marked" pass ;;
     esac ;;
esac
# the spec column still carries the plain path, so Enter still resolves
if [ "$(printf '%s\n' "$taken_row" | awk -F'\t' '{print $3}')" = "$TMPD/taken" ]; then
  report "a marked row still carries its plain path in the spec column" pass
else
  report "a marked row still carries its plain path in the spec column" fail
fi

# --- @interdimux-hide keeps scratch sessions out of the way -------------------------
# MRU ranks by recency, so a popup you opened ten seconds ago outranks the
# project you have been in all day.  Filtered on the RAW sections, so both
# renderers see the same list.
tmux -L "$SOCK" new-session -d -s scratchpad -x 200 -y 50 -c "$TMPD"
tmux -L "$SOCK" new-session -d -s 'floax-one' -x 200 -y 50 -c "$TMPD"
tmux -L "$SOCK" new-window  -d -t '=scratchpad:' -n extra -c "$TMPD"
wait_for "the hide fixtures" sh -c \
  "tmux -L '$SOCK' has-session -t '=scratchpad' && tmux -L '$SOCK' has-session -t '=floax-one'"

specs_of() { bash "$SCRIPT" --list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -F'\t' '{print $4}'; }

if specs_of | grep -q '^S:scratchpad$'; then
  report "the scratch session is visible before hiding" pass
else
  report "the scratch session is visible before hiding" fail
fi

# The glob case above passes for the wrong reason unless the CWD is stacked
# against it.  `for _hp in $HIDE_PATTERNS` needs the word splitting, and without
# `set -f` it gets PATHNAME EXPANSION too — so `floax-*` was expanded against the
# current directory before it was ever compared to a session name.  In a
# directory containing a FILE called `floax-one`, the pattern became that
# filename and the session it was meant to hide stayed visible; in a directory
# containing no match, bash left the word alone and it worked.  Which meant the
# feature depended on where the popup was opened from, and this suite ran
# somewhere it happened to work.
#
# The decoy must match the PATTERN without matching the SESSION.  A file named
# `floax-one` — the obvious fixture — makes the glob expand to the session's own
# name and the hide still works, so the assertion passes with the bug present.
# Verified: with `floax-one` as the decoy, removing `set -f` from the hide loops
# left this suite green.
mkdir -p "$TMPD/globtrap"
: > "$TMPD/globtrap/floax-DECOY"

for renderer in rust bash; do
  [ "$renderer" = bash ] && export INTERDIMUX_USE_RUST=off || unset INTERDIMUX_USE_RUST
  trapped=$(cd "$TMPD/globtrap" && INTERDIMUX_HIDE='scratchpad floax-*' specs_of)
  if printf '%s\n' "$trapped" | grep -q 'scratchpad\|floax'; then
    report "[$renderer] a hide pattern is not expanded against the cwd" fail
    ERRORS+="    $(printf '%s' "$trapped" | tr '\n' ' ')"$'\n'
  else
    report "[$renderer] a hide pattern is not expanded against the cwd" pass
  fi

  out=$(INTERDIMUX_HIDE='scratchpad floax-*' specs_of)
  if printf '%s\n' "$out" | grep -q 'scratchpad\|floax'; then
    report "[$renderer] @interdimux-hide removes matching sessions" fail
    ERRORS+="    $(printf '%s' "$out" | tr '\n' ' ')"$'\n'
  else
    report "[$renderer] @interdimux-hide removes matching sessions" pass
  fi
  # their windows go with them, or the tree is left with orphan rows
  if printf '%s\n' "$out" | grep -q '^W:scratchpad:'; then
    report "[$renderer] ...and their windows go with them" fail
  else
    report "[$renderer] ...and their windows go with them" pass
  fi
  # everything else survives
  if printf '%s\n' "$out" | grep -q '^S:taken$'; then
    report "[$renderer] ...and nothing else is removed" pass
  else
    report "[$renderer] ...and nothing else is removed" fail
  fi
done
unset INTERDIMUX_USE_RUST

# The current session is never hidden: the row marker, the header and MRU's
# move-to-end all key off it.
cur=$(tmux -L "$SOCK" display-message -p -t "$TMUX_PANE" '#S')
if INTERDIMUX_HIDE="$cur" specs_of | grep -q "^S:$cur\$"; then
  report "the current session is never hidden ($cur)" pass
else
  report "the current session is never hidden ($cur)" fail
fi

# Hidden is not unreachable: nothing matches an exact name, so find-or-create
# runs and connect_dir switches to the existing session instead of making one.
verb=$(INTERDIMUX_HIDE='scratchpad' bash "$SCRIPT" --describe-create 'scratchpad' 2>/dev/null \
       | sed 's/\x1b\[[0-9;]*m//g')
case "$verb" in
  'switch to scratchpad'*) report "a hidden session is still reachable by exact name" pass ;;
  *) report "a hidden session is still reachable by exact name (got: $verb)" fail ;;
esac

tmux -L "$SOCK" kill-session -t scratchpad 2>/dev/null || true
tmux -L "$SOCK" kill-session -t 'floax-one' 2>/dev/null || true

# --- recent (★) rows carry the project-type badge too --------------------------------
# They are the directories you use most, and were the only tier without it: the
# same directory showed "Rust" as a ◆ row and nothing once it became recent.
mkdir -p "$TMPD/rustyrec"
printf '[package]\n' > "$TMPD/rustyrec/Cargo.toml"
printf '%s\n' "$TMPD/rustyrec" >> "$TMPD/data/interdimux/recent_dirs"
row=$(INTERDIMUX_PROJECT_DIRS="$TMPD" bash "$SCRIPT" --dirs-list 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g' | awk -F'\t' -v p="$TMPD/rustyrec" '$3 == p')
case "$row" in
  *'★'*) report "the new dir is on the recent tier" pass ;;
  *) report "the new dir is on the recent tier (got: $row)" fail ;;
esac
if [ "$(printf '%s' "$row" | awk -F'\t' '{print $2}')" = "Rust" ]; then
  report "...and a recent row still shows its project type" pass
else
  report "...and a recent row still shows its project type (got: $(printf '%s' "$row" | awk -F'\t' '{print $2}'))" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
