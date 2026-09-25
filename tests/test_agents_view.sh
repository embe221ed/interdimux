#!/usr/bin/env bash
#
# The agents view: what the dashboard's Agents entry opens (review R03).
#
# `--launch agents` runs the navigator with INTERDIMUX_VIEW=agents, and both
# renderers then mark, in the gutter where `*` marks the current target, the
# row of every pane that waits on you: `!` for approve, `?` for input, one row
# per pane.  The view opens with `^! | ^?` typed, which has to match exactly
# those rows.  It used to open on `'approve' | 'input'`, which also matched a
# working agent's description (`Approve button styling`), a window called
# `input-form`, and a waiting pane twice (its window row and its pane row), so
# fzf's count ran past the dashboard's and the cursor could land on a working
# agent.
#
# rust/tests/corpus/waiting.dump holds those cases, and a session group that
# lists one waiting pane under two sessions.  No tmux server, no pty: the dump
# goes in through INTERDIMUX_DUMP_IN (see tests/test_corpus_parity.sh), and
# tmux is a PATH stub that logs and fails.
#
# The oracles: the golden the Rust core blessed (rust/tests/golden.rs, which
# checks the marked targets on its own), the other renderer, and a hand-written
# list of the panes that wait in the dump -- never the renderer's own code.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
CORPUS="$SCRIPT_DIR/rust/tests/corpus"
DUMP="$CORPUS/waiting.dump"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-agview.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

echo "interdimux agents view tests (both renderers, no server)"
echo

mkdir -p "$TMPD/stub"
cat > "$TMPD/stub/tmux" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$TMPD/tmux-calls"
exit 1
STUB
chmod +x "$TMPD/stub/tmux"

# golden.rs's environment, as tests/test_corpus_parity.sh passes it
GENV=(
  HOME=/home/u
  PATH="$TMPD/stub:$PATH"
  LANG=C.UTF-8 LC_ALL=C.UTF-8
  INTERDIMUX_NOW=1700086400
  INTERDIMUX_SHOW_PREVIEW=off
  INTERDIMUX_SHOW_FULL_COMMAND=off
  INTERDIMUX_SHOW_GIT_BRANCH=off
  INTERDIMUX_SHOW_DIRS=off
  INTERDIMUX_ORDER=mru
  INTERDIMUX_COLOR_ACCENT=173 INTERDIMUX_COLOR_PATH=180 INTERDIMUX_COLOR_GIT=140
  INTERDIMUX_COLOR_SSH=109 INTERDIMUX_COLOR_EDITOR=150 INTERDIMUX_COLOR_DANGER=167
  INTERDIMUX_COLOR_TREE=240 INTERDIMUX_COLOR_SEPARATOR=245
  TMUX="$TMPD/no-server,1,0"
  INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
)
# $1 = cols, $2 = rule on|off, $3 = the Rust core on|off, rest = extra env
render() {
  local cols="$1" rule="$2" rust="$3"; shift 3
  env -i "${GENV[@]}" FZF_COLUMNS="$cols" INTERDIMUX_SESSION_RULE="$rule" \
      INTERDIMUX_USE_RUST="$rust" INTERDIMUX_DUMP_IN="$DUMP" "$@" \
      bash "$SCRIPT" --list
}
strip() { sed 's/\x1b\[[0-9;]*m//g' "$1"; }
# The rows the view's query selects, by target, as the navigator's fzf reads
# them (its delimiter and match scope).
# (fzf --filter exits 1 when nothing matches, which pipefail would pass on.)
selected() {
  { fzf --ansi --filter '^! | ^?' --delimiter=$'\t' --with-nth=1..3 --nth=1,3 \
      --tiebreak=index < "$1" || true; } | cut -f4 | tr '\n' ' '
}
# The panes that wait in waiting.dump, one row each, in list order (MRU puts
# misc2, then misc, then work, the current session, last):
#   misc2:1  codex, `Action Required`: approve.  misc lists the same pane
#            again (a session group): its row is not marked a second time
#   work:0   claude, the registry says approve; the current window, so its
#            mark replaces the `*`
#   work:1.0 codex, `Action Required`, the window's ACTIVE pane: its pane row
#            carries the mark, not the window row that repeats it
#   work:1.2 @agent_state input
# Not: misc2:0 / misc:0 (working, `Fix input validation`), work:1.1 (working,
# `Approve button styling`), work:2 (a window called input-form).
WANT="W:misc2:1 W:work:0 P:work:1:0 P:work:1:2 "

# --- 1. the bash renderer draws the blessed view ------------------------------
render 120 on off INTERDIMUX_VIEW=agents > "$TMPD/b" 2> "$TMPD/berr" || true
if [ -s "$TMPD/berr" ]; then
  report "bash renders the agents view without a word on stderr" fail
  ERRORS+="$(head -3 "$TMPD/berr")"$'\n'
elif cmp -s "$TMPD/b" "$CORPUS/waiting.view.expected"; then
  report "bash renders the agents view byte for byte as the golden" pass
else
  report "bash renders the agents view byte for byte as the golden" fail
  ERRORS+="$(diff <(strip "$CORPUS/waiting.view.expected") <(strip "$TMPD/b") | head -6 || true)"$'\n'
fi

# --- 2. the view's query selects exactly the waiting panes --------------------
if ! command -v fzf >/dev/null 2>&1; then
  echo "  (fzf not installed: the query checks are skipped)"
else
  got=$(selected "$TMPD/b")
  if [ "$got" = "$WANT" ]; then
    report "bash: ^! | ^? selects the waiting panes, one row each ($WANT)" pass
  else
    report "bash: ^! | ^? selects the waiting panes, one row each (got: $got want: $WANT)" fail
  fi
  # Outside the view nothing is marked, and the query matches nothing.
  render 120 on off > "$TMPD/plain" 2>/dev/null || true
  got=$(selected "$TMPD/plain")
  if [ -s "$TMPD/plain" ] && [ -z "$got" ]; then
    report "outside the view no row is marked: the query matches nothing" pass
  else
    report "outside the view no row is marked: the query matches nothing (got: $got)" fail
  fi
  if [ -x "$BIN" ]; then
    render 120 on on INTERDIMUX_VIEW=agents > "$TMPD/r" 2>/dev/null || true
    got=$(selected "$TMPD/r")
    if [ "$got" = "$WANT" ]; then
      report "the Rust core: ^! | ^? selects the same panes" pass
    else
      report "the Rust core: ^! | ^? selects the same panes (got: $got)" fail
    fi
  fi
fi

# --- 3. both renderers, byte for byte, across the geometry --------------------
if [ ! -x "$BIN" ]; then
  echo "  (rust binary not built: the cross-renderer sweep is skipped)"
else
  bad=""
  for cols in 40 52 80 120 200; do
    for rule in on off; do
      render "$cols" "$rule" off INTERDIMUX_VIEW=agents > "$TMPD/b" 2>/dev/null || true
      render "$cols" "$rule" on  INTERDIMUX_VIEW=agents > "$TMPD/r" 2>/dev/null || true
      if [ ! -s "$TMPD/b" ] || ! cmp -s "$TMPD/b" "$TMPD/r"; then bad+=" $cols/$rule"; fi
    done
  done
  if [ -z "$bad" ]; then
    report "the agents view is byte-identical in both renderers at 40-200 cols, rule on/off" pass
  else
    report "the agents view is byte-identical in both renderers (differs at:$bad)" fail
    ERRORS+="$(diff <(strip "$TMPD/r") <(strip "$TMPD/b") | head -6 || true)"$'\n'
  fi
fi

# Last: nothing above may have reached for tmux.
if [ ! -e "$TMPD/tmux-calls" ]; then
  report "no render asked tmux for anything" pass
else
  report "no render asked tmux for anything ($(wc -l < "$TMPD/tmux-calls") calls)" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
