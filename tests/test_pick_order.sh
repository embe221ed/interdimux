#!/usr/bin/env bash
#
# Pick priority: what the cursor lands on when a query matches both an existing
# target and a new-session suggestion.
#
# Reported from real use: a session named `circle/sui-cctp`, and a directory
# named `Circle` offered as a new session.  Typing `circle` marked the
# DIRECTORY, so Enter created a second session instead of switching to the one
# that was already open.
#
# The mechanism, measured rather than reasoned about: fzf scores those two rows
# IDENTICALLY.  Both names sit immediately after a space in field 1 — ` ▸ name`
# for a session, ` + name` for a directory — so the first matched character gets
# the same word-boundary bonus, and fzf's score looks only at the matched
# region, never at how much of the row is left over.  (Confirmed by feeding the
# two rows in both orders under --tiebreak=index: the winner follows the input
# order, which only happens on an exact tie.)
#
# So the tiebreak was the entire decision, and `--tiebreak=chunk` breaks it by
# the length of the whitespace chunk the match landed in: `Circle` is 6 cells,
# `circle/sui-cctp` is 15, so the suggestion won every query that reached both.
# `index` — keep the list's own order — is the tiebreak that gets this right,
# because the list is already ordered the way the answer wants: MRU sessions,
# their windows and panes, then directory suggestions last.
#
# The counter-property is asserted here too, and it is why this is a tiebreak
# change and not "a session always wins": a directory suggestion that is
# genuinely the better match — an exact `notes` against a session that only
# matches it as a scattered subsequence — must STILL be picked first.  That case
# is decided by the score, above the tiebreak, so no reordering of tiebreak keys
# can reach it; a rule that buried it would have to be a hard class ordering,
# and a hard class ordering would make the one-list model useless.
#
# Needs a real client: this is about which row the cursor is on after typing,
# and send-keys writes to a pane's pty rather than driving fzf, so an outer tmux
# types into an inner one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-pickorder-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-po.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

# OUTER first.  It owns the pane the navigator runs in, and the navigator talks
# to $SOCK — kill the inner server first and any tmux client it has in flight is
# left blocking on a socket that will never answer, which outlives this suite.
# (Seen once, on a deliberately failing run: an orphaned `tmux new-session -d -s
# Circle` still resident after the suite had exited.)
cleanup() {
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  tmux -L "$SOCK" kill-server 2>/dev/null || true
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
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

echo "interdimux pick-priority tests"
echo

# --- the fixture ---------------------------------------------------------------
# `Circle` and `notes` are siblings under dirs/, and no session's cwd is either
# of them — a directory that already has a session is not offered at all, which
# would make every assertion below pass for the wrong reason.
mkdir -p "$TMPD/data/interdimux" "$TMPD/dirs/Circle" "$TMPD/dirs/notes" \
         "$TMPD/cwd" "$TMPD/cwd/sui" "$TMPD/cwd/ann"
printf '%s\n%s\n' "$TMPD/dirs/Circle" "$TMPD/dirs/notes" > "$TMPD/data/interdimux/recent_dirs"

tmux -f /dev/null -L "$SOCK" new-session -d -s driver -x 160 -y 20 -c "$TMPD/cwd"
tmux -L "$SOCK" new-session -d -s 'circle/sui-cctp'    -x 160 -y 20 -c "$TMPD/cwd/sui"
# The decoy for the counter-property: `notes` is a scattered subsequence of
# `annotations-worker` (a-N-n-O-T-a-t-i-o-n-S), so a rule that always preferred
# a session would bury the exact directory match under it.
tmux -L "$SOCK" new-session -d -s 'annotations-worker' -x 160 -y 20 -c "$TMPD/cwd/ann"

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=driver:0' -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_USE_ZOXIDE=off

# Pinned to the width of the pane the picker is driven in below, so the rows
# these premises are measured on are the rows fzf ranks.  Left to itself the
# script falls back to `stty size </dev/tty` and then to 80, which is a
# different identity column and a different truncation point.
list_rows() { FZF_COLUMNS=160 "$@" bash "$SCRIPT" --list 2>/dev/null | plain; }

wait_rows() { # $1 = a spec that must be present in --list
  local i
  for i in $(seq 1 150); do
    list_rows | awk -F'\t' '{print $4}' | grep -qxF "$1" && return 0
    sleep 0.1
  done
  return 1
}
wait_rows "D:$TMPD/dirs/Circle" \
  || ERRORS+="    the Circle suggestion never appeared in --list"$'\n'

LIST=$(list_rows)

# --- premise 1: the list's own order is the answer ------------------------------
# `index` is only the right tiebreak because the input is already ordered.  If a
# later change interleaves the directory rows, this suite should say so here
# rather than leave the pty assertions below failing for an unexplained reason.
specs=$(printf '%s\n' "$LIST" | awk -F'\t' '{print $4}')
last_tmux=$(printf '%s\n' "$specs" | grep -n '^[SWP]:' | tail -1 | cut -d: -f1)
first_dir=$(printf '%s\n' "$specs" | grep -n '^D:'     | head -1 | cut -d: -f1)
if [ -n "$last_tmux" ] && [ -n "$first_dir" ] && [ "$first_dir" -gt "$last_tmux" ]; then
  report "the suggestions are last in the list the picker is given" pass
else
  report "the suggestions are last in the list (tmux@$last_tmux dir@$first_dir)" fail
fi

# --- premise 2: the two rows really do tie on score ------------------------------
# fzf's first-character bonus comes from the class of the character BEFORE the
# match.  A space in front of both names is what makes the scores equal and
# hands the decision to the tiebreak; put a different class in front of one of
# them and the tie — and with it this whole fix — is gone.  Both renderers,
# because both draw these rows and the parity suite only asserts they agree with
# each other, not what they agree on.
#
# The comparison is against a plain ASCII space, so it is byte-safe in any
# locale; only the diagnostic below can come out as a partial glyph.
preceding_char() { # $1 = rows, $2 = spec, $3 = name
  local row f1 before
  row=$(printf '%s\n' "$1" | awk -F'\t' -v s="$2" '$4 == s')
  f1="${row%%$'\t'*}"
  before="${f1%%"$3"*}"
  [ "$before" = "$f1" ] && { printf '(name not in field 1)'; return; }
  printf '%s' "${before: -1}"
}
for renderer in rust bash; do
  if [ "$renderer" = bash ]; then rows=$(list_rows env INTERDIMUX_USE_RUST=off)
  else rows="$LIST"; fi
  s_pre=$(preceding_char "$rows" "S:circle/sui-cctp" "circle/sui-cctp")
  d_pre=$(preceding_char "$rows" "D:$TMPD/dirs/Circle" "Circle")
  if [ "$s_pre" = " " ] && [ "$d_pre" = " " ]; then
    report "[$renderer] both names follow a space, so the two rows score equal" pass
  else
    report "[$renderer] both names follow a space, so the two rows score equal" fail
    ERRORS+="    session:[$s_pre] dir:[$d_pre] — a different class in front of one of"$'\n'
    ERRORS+="    them breaks the tie the index tiebreak resolves"$'\n'
  fi
done

# --- the picker itself ----------------------------------------------------------
# The launcher drops a sentinel when the navigator EXITS.  The screen cannot
# stand in for that: fzf restores the terminal before the script that read its
# output has done anything with it, so "the prompt is gone" arrives strictly
# earlier than "Enter has been acted on" — and an assertion that no session was
# created passes trivially in that window.  Measured: it passed against the
# unfixed script, which does create one.
EXITED="$TMPD/exited"
launch() {
  local sh="$TMPD/launch.sh"
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  rm -f "$EXITED"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export TMUX=%q TMUX_PANE=%q XDG_DATA_HOME=%q\n' "$TMUX" "$TMUX_PANE" "$XDG_DATA_HOME"
    printf 'export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_FZF_MINOR=74\n'
    printf 'export INTERDIMUX_USE_ZOXIDE=off FZF_DEFAULT_OPTS=\n'
    printf 'bash %q\n' "$SCRIPT"
    printf 'printf done > %q\n' "$EXITED"
  } > "$sh"
  chmod +x "$sh"
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 160 -y 20 "$sh; sleep 45"
  local i
  for i in $(seq 1 250); do
    tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | grep -q '❯' && return 0
    sleep 0.1
  done
  return 1
}
screen() { tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | plain; }
# The rows stream in, so the prompt appearing is not the list being there.  Poll
# for the row about to be asserted on rather than sleeping a fixed time.
wait_screen() { # $1 = pattern
  local i
  for i in $(seq 1 150); do
    screen | grep -q "$1" && return 0
    sleep 0.1
  done
  return 1
}
# The marked row: --pointer is '▌' and `change:first` puts the cursor back on
# rank 1 after every keystroke, so this is what Enter would act on.
marked() { screen | grep '▌' | head -1 || true; }
# Type a query into a picker that is already open, having cleared the last one,
# and return the row it settles on.  Two conditions, no fixed sleep: every
# character of the query has reached the prompt, and the cursor has then stopped
# moving (the same non-empty row read twice).  Waiting on a single read races the
# repaint — `result:best` moves the cursor after the list has already been drawn.
query() { # $1 = query
  local i cur="" prev=""
  tmux -L "$OUTER" send-keys -t '=drv:' C-u
  tmux -L "$OUTER" send-keys -t '=drv:' "$1"
  for i in $(seq 1 100); do
    screen | head -1 | grep -qF "❯ $1" && break
    sleep 0.1
  done
  for i in $(seq 1 100); do
    cur=$(marked)
    [ -n "$cur" ] && [ "$cur" = "$prev" ] && break
    prev="$cur"
    sleep 0.1
  done
  printf '%s' "$cur"
}

if launch; then
  report "the navigator opens" pass
else
  report "the navigator opens" fail
  echo; echo "Results: $PASS passed, $FAIL failed"; echo; printf '%s' "$ERRORS"; exit 1
fi
wait_screen 'sui-cctp' || ERRORS+="    the session row never painted"$'\n'
wait_screen '+ Circle' || ERRORS+="    the Circle suggestion never painted"$'\n'

# Lower case on purpose.  fzf is smart-case, so a query of `Circle` is matched
# case-SENSITIVELY and the session `circle/sui-cctp` cannot match it at all —
# that is fzf working as documented, not this ordering, and asserting on it here
# would test the wrong thing.
#
#   circle  the reported query, and the "two rows match about equally" case
#   cle     first, fourth-from-last and last letters: a scattered subsequence of
#           both names, which is how a name gets typed when it is being typed fast
#   crce    the same shape again, with nothing contiguous to lean on
for q in circle cle crce; do
  cur=$(query "$q")
  case "$cur" in
    *'sui-cctp'*) report "'$q' marks the session that already exists" pass ;;
    *) report "'$q' marks the session that already exists" fail
       ERRORS+="    marked: [$(printf '%s' "$cur" | sed 's/  */ /g')]"$'\n' ;;
  esac
done

# The counter-property.  Nothing here may become "a session always wins".
cur=$(query notes)
case "$cur" in
  *'+ notes'*) report "'notes' still marks the suggestion it exactly names" pass ;;
  *) report "'notes' still marks the suggestion it exactly names" fail
     ERRORS+="    marked: [$(printf '%s' "$cur" | sed 's/  */ /g')]"$'\n'
     ERRORS+="    a scattered match on a session must not outrank an exact one on a dir"$'\n' ;;
esac

# --- and what Enter actually does, which is the whole complaint -------------------
# With the suggestion marked, Enter runs connect_dir and a SECOND session appears
# next to the one the user was trying to reach.
before_sessions=$(tmux -L "$SOCK" list-sessions -F '#{session_name}' 2>/dev/null | sort)
query circle >/dev/null
tmux -L "$OUTER" send-keys -t '=drv:' Enter
# The navigator having EXITED is the positive signal that Enter was acted on —
# connect_dir runs after fzf has already given the terminal back.
for i in $(seq 1 300); do
  [ -s "$EXITED" ] && break
  sleep 0.1
done
[ -s "$EXITED" ] || ERRORS+="    the navigator never exited after Enter"$'\n'
after_sessions=$(tmux -L "$SOCK" list-sessions -F '#{session_name}' 2>/dev/null | sort)
if [ "$after_sessions" = "$before_sessions" ]; then
  report "Enter on that query creates no second session" pass
else
  report "Enter on that query creates no second session" fail
  ERRORS+="    before: $(printf '%s' "$before_sessions" | tr '\n' ' ')"$'\n'
  ERRORS+="    after:  $(printf '%s' "$after_sessions" | tr '\n' ' ')"$'\n'
fi
if tmux -L "$SOCK" has-session -t '=Circle' 2>/dev/null; then
  report "...and specifically not one named after the suggested directory" fail
else
  report "...and specifically not one named after the suggested directory" pass
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
