#!/usr/bin/env bash
#
# Tests for the navigator list output (--list).
#
# Verifies the display contract the fzf integration depends on:
#   - every row has exactly 4 tab-separated fields with the SPEC last
#   - MRU ordering: most recently active sessions first, the current
#     session moved to the end
#   - INTERDIMUX_ORDER=index preserves tmux's native (alphabetical) order
#   - window/pane rows carry their session name (search context)
#   - pane rows appear only for multi-pane windows
#
# Uses a dedicated tmux server socket so tests don't interfere with the
# user's live session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-list-test-$$"
OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/interdimux-list-out.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -f "$OUT_FILE"
}
trap cleanup EXIT

# -f /dev/null: the test server must not inherit the developer's ~/.tmux.conf.
# A user `base-index 1` makes every ":0" target below fail with "can't find
# window: 0", which aborts the whole suite under set -e.
tmux_cmd() {
  tmux -f /dev/null -L "$SOCK" "$@"
}

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1))
    printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: $name"$'\n'
    printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

# Run --list inside the test server from charlie's pane (making charlie
# the "current" session), ANSI codes stripped.
# Dir rows (IDEAS #14) come from the developer's own recent-dirs/zoxide, which
# would make this suite depend on the machine it runs on.  This file tests the
# tmux TREE format; tests/test_one_list.sh owns the D: rows.
#
# TMUX_PANE is passed EXPLICITLY.  `run-shell -t` does not export it — verified
# against tmux 3.4 (apt), 3.5a (apt), 3.6 (source), 3.7b (source) and 3.7b
# (Debian package); only a locally patched build does.  Without it the script
# falls back to an untargeted `#S`, which resolves to the most recently ATTACHED
# session rather than the one named here, and the MRU assertion below reads
# `alpha charlie bravo`.  The real key bindings already do this — they bake
# `TMUX_PANE=#{pane_id}` into the binding for exactly the same reason.
run_list() {
  local extra_env="INTERDIMUX_SHOW_DIRS=off ${1:-}" pane
  pane=$(tmux_cmd list-panes -t "=charlie:0" -F '#{pane_id}' 2>/dev/null | head -1)
  tmux_cmd run-shell -t "=charlie:0" \
    "TMUX_PANE=$pane $extra_env bash '$SCRIPT' --list > '$OUT_FILE'" 2>/dev/null || true
  sed $'s/\x1b\\[[0-9;]*m//g' "$OUT_FILE"
}

# Session name of each session row, in order (the driver session is
# test plumbing — its position is timing-dependent, so it is excluded)
session_order() {
  awk -F'\t' '$4 ~ /^S:/ { sub(/^S:/, "", $4); print $4 }' | grep -v '^driver$'
}

# ---------------------------------------------------------------------------
# Setup: alpha (multi-pane), bravo, charlie — attached in a staggered
# order (via a nested client running in the driver session's pane tty)
# so the MRU order (bravo, alpha, charlie-last) differs from the
# alphabetical index order (alpha, bravo, charlie).
# ---------------------------------------------------------------------------

tmux_cmd new-session -d -s alpha -x 120 -y 30
tmux_cmd split-window -t "=alpha:0" -h
tmux_cmd new-session -d -s bravo -x 120 -y 30
tmux_cmd new-session -d -s charlie -x 120 -y 30
tmux_cmd new-session -d -s driver -x 120 -y 30 /bin/sh
sleep 0.5

# Attach (then detach) a real client to alpha, then bravo — this is the
# only reliable way to advance #{session_last_attached} headlessly.
# Wait for the CONDITION, not a fixed duration: these sleeps were tuned on an
# idle box and flake under load (observed: MRU asserted "bravo charlie alpha"
# because the attach had not landed yet).  Polling makes the suite deterministic
# regardless of how busy the machine is.
visit() {
  local before after i
  before=$(tmux_cmd display-message -p -t "=$1:" '#{session_last_attached}' 2>/dev/null || echo 0)
  tmux_cmd send-keys -t "=driver:0" "TMUX= tmux -L '$SOCK' attach -t '=$1'" Enter
  # the attach has happened once last_attached advances
  for i in $(seq 1 100); do
    after=$(tmux_cmd display-message -p -t "=$1:" '#{session_last_attached}' 2>/dev/null || echo 0)
    [ "$after" != "$before" ] && [ "${after:-0}" -gt 0 ] && break
    sleep 0.1
  done
  # ...and give the clock a full second, since last_attached has 1s resolution
  # and equal timestamps would make the MRU sort order ambiguous
  sleep 1
  tmux_cmd detach-client -s "=$1" 2>/dev/null || true
  for i in $(seq 1 50); do
    tmux_cmd list-clients -t "=$1" 2>/dev/null | grep -q . || break
    sleep 0.1
  done
}
visit alpha
visit bravo

echo "interdimux --list format tests"
echo

out=$(run_list)

# ---------------------------------------------------------------------------
# Sanity: the structural checks below are "no BAD rows exist", which is
# vacuously true when --list emits nothing at all.  Assert we actually got a
# list first, so a silently-broken gather reports as a failure instead of
# printing green ticks against zero rows.
# ---------------------------------------------------------------------------

row_count=$(printf '%s\n' "$out" | grep -c $'\t' || true)
if [ "$row_count" -ge 8 ]; then
  report "--list produced rows to check (got $row_count)" pass
else
  report "--list produced rows to check (got $row_count, expected >= 8)" fail
fi

# ---------------------------------------------------------------------------
# Field structure
# ---------------------------------------------------------------------------

bad_fields=$(printf '%s\n' "$out" | awk -F'\t' 'NF != 4 { print }')
if [ -z "$bad_fields" ]; then
  report "every row has exactly 4 tab-separated fields" pass
else
  report "every row has exactly 4 tab-separated fields" fail
fi

bad_specs=$(printf '%s\n' "$out" | awk -F'\t' '$4 !~ /^[SWPD]:/ { print }')
if [ -z "$bad_specs" ]; then
  report "every row ends with a S:/W:/P:/D: spec field" pass
else
  report "every row ends with a S:/W:/P:/D: spec field" fail
fi

# ---------------------------------------------------------------------------
# Ordering
# ---------------------------------------------------------------------------

order=$(printf '%s\n' "$out" | session_order | tr '\n' ' ')
if [ "$order" = "bravo alpha charlie " ]; then
  report "MRU order: recent first, current session last (got: $order)" pass
else
  report "MRU order: recent first, current session last (got: $order)" fail
fi

out_index=$(run_list "INTERDIMUX_ORDER=index")
order=$(printf '%s\n' "$out_index" | session_order | tr '\n' ' ')
if [ "$order" = "alpha bravo charlie " ]; then
  report "index order keeps tmux native order (got: $order)" pass
else
  report "index order keeps tmux native order (got: $order)" fail
fi

# ---------------------------------------------------------------------------
# Row content
# ---------------------------------------------------------------------------

if printf '%s\n' "$out" | awk -F'\t' '$4 == "W:bravo:0"' | grep -q 'bravo'; then
  report "window rows carry their session name" pass
else
  report "window rows carry their session name" fail
fi

if printf '%s\n' "$out" | grep -q $'\tP:alpha:0:'; then
  report "multi-pane window lists its panes" pass
else
  report "multi-pane window lists its panes" fail
fi

if printf '%s\n' "$out" | grep -q $'\tP:bravo:'; then
  report "single-pane windows list no panes" fail
else
  report "single-pane windows list no panes" pass
fi

# ---------------------------------------------------------------------------
# The session group rule
# ---------------------------------------------------------------------------
#
# A flat list has no way to show where one session's windows end and the next
# begins — --gap rules between every row and zebra striping crosses the
# boundaries.  Extending the session row's own padding into a run of '─' costs
# no extra rows and marks it.  What has to hold:
#
#   * the run lands the session meta in the SAME column as the command on child
#     rows, or it is decoration rather than structure
#   * the run lives entirely inside field 1 (see rust/src/render.rs), so a
#     ^]-scope cycle can never split it into two intensities
#   * it turns itself OFF once the popup is too narrow for a command column,
#     because there the meta would simply be clipped
#
# The byte-identical rust/bash question is tests/test_rust_parity.sh's; the
# cell-exact layout is rust/tests/golden.rs'.  This is the bash renderer's own
# behaviour, measured through a real tmux server.

# Cells, and a cell count needs a UTF-8 locale: awk's length() and bash's ${#}
# both count BYTES under LC_ALL=C, and the rule row is almost entirely multibyte
# while the window row is almost entirely not — so the two columns being compared
# would be measured on different scales and disagree by ~90.  The PRODUCT is
# locale-independent here (rust-vs-bash output is byte-identical under both C and
# C.UTF-8, verified); this is the measuring instrument, not the thing measured.
UTF8_LOCALE=""
for _l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  [ "$(LC_ALL="$_l" locale charmap 2>/dev/null)" = "UTF-8" ] && { UTF8_LOCALE="$_l"; break; }
done
# Column (0-based) at which a row's SECOND field starts, on the rendered line.
# fzf draws the tab as one cell at --tabstop=1, so this is what the eye sees.
second_col() { LC_ALL="${UTF8_LOCALE:-C}" awk -F'\t' 'NR==1 {print length($1) + 1}'; }

rule_out=$(run_list "INTERDIMUX_USE_RUST=off FZF_COLUMNS=120")
sess_col=$(printf '%s\n' "$rule_out" | grep $'\tS:alpha$' | second_col)
win_line=$(printf '%s\n' "$rule_out" | grep $'\tW:alpha:0$')
win_col=$(printf '%s' "$win_line" \
          | LC_ALL="${UTF8_LOCALE:-C}" awk -F'\t' '{print length($1) + 1 + length($2) + 1}')
if [ -z "$UTF8_LOCALE" ]; then
  echo "  (skipped the rule's column alignment: no UTF-8 locale to measure cells in)"
elif [ -n "$sess_col" ] && [ "$sess_col" = "$win_col" ]; then
  report "the rule lands the session meta in the command column ($sess_col)" pass
else
  report "the rule lands the session meta in the command column (meta $sess_col, command $win_col)" fail
fi

if printf '%s\n' "$rule_out" | grep $'\tS:alpha$' | grep -q '▸ alpha ──'; then
  report "the rule is separated from the name by a space" pass
else
  report "the rule is separated from the name by a space" fail
  ERRORS+="      --tiebreak=chunk demotes the session row if they are glued"$'\n'
fi

if printf '%s\n' "$rule_out" | grep $'\tS:alpha$' | awk -F'\t' '$2 ~ /─/ {exit 1}'; then
  report "the rule stays inside field 1" pass
else
  report "the rule stays inside field 1" fail
fi

off_out=$(run_list "INTERDIMUX_USE_RUST=off INTERDIMUX_SESSION_RULE=off FZF_COLUMNS=120")
if printf '%s\n' "$off_out" | grep $'\tS:alpha$' | grep -q '─'; then
  report "@interdimux-session-rule=off draws no rule" fail
else
  report "@interdimux-session-rule=off draws no rule" pass
fi

# Below the width where the squeeze still fits a command column, the rule turns
# itself off: measured, "2 win ● 2h" became "2 win…" at ~45 popup columns.
tight_out=$(run_list "INTERDIMUX_USE_RUST=off FZF_COLUMNS=44")
if printf '%s\n' "$tight_out" | grep $'\tS:alpha$' | grep -q '─'; then
  report "the rule switches itself off on a narrow popup" fail
  ERRORS+="      $(printf '%s\n' "$tight_out" | grep $'\tS:alpha$' | head -1)"$'\n'
else
  report "the rule switches itself off on a narrow popup" pass
fi
# ...and the control: it really was drawing at the wide width, so "off
# everywhere" cannot pass the pair.
if printf '%s\n' "$rule_out" | grep $'\tS:alpha$' | grep -q '──'; then
  report "control: it does draw at 120 columns" pass
else
  report "control: it does draw at 120 columns" fail
fi

# The bash renderer measures with ${#var}, which counts CHARACTERS, so it cannot
# size a rule after a wide glyph — and an over-long run does not merely shift the
# column, it pushes the meta off the right edge where fzf clips it away.  So bash
# declines to draw one there.  (The Rust core measures cells and has no such
# limit; a wide-glyph name already renders differently between the two.)
tmux_cmd new-session -d -s '日本語日本語日本語' -x 200 -y 50
sleep 0.3
cjk_out=$(run_list "INTERDIMUX_USE_RUST=off FZF_COLUMNS=120")
if printf '%s\n' "$cjk_out" | grep $'\tS:日本語日本語日本語$' | grep -q '─'; then
  report "bash draws no rule after a name it cannot measure" fail
else
  report "bash draws no rule after a name it cannot measure" pass
fi
# ...and the truncation ellipsis is NOT such a glyph: it is one char and one
# cell, so a merely-long ASCII name must keep its rule.  Testing for non-ASCII
# after truncation instead of before dropped the rule from every long name, and
# the parity suite is what noticed.
tmux_cmd new-session -d -s 'a-very-long-ascii-session-name-that-gets-truncated' -x 200 -y 50
sleep 0.3
long_out=$(run_list "INTERDIMUX_USE_RUST=off FZF_COLUMNS=120")
if printf '%s\n' "$long_out" | grep $'\tS:a-very-long-ascii-session-name-that-gets-truncated$' | grep -q '─'; then
  report "a long ASCII name keeps its rule (the ellipsis is not a wide glyph)" pass
else
  report "a long ASCII name keeps its rule (the ellipsis is not a wide glyph)" fail
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
