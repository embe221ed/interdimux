#!/usr/bin/env bash
#
# gather_targets issues its four tmux queries as ONE command list, with the
# sections separated by RS (\x1e).  Two things have to hold:
#
#   1. the batched result is identical to the separate-query result
#   2. an RS that appears INSIDE a field is detected and falls back
#
# (2) is not hypothetical: tmux rejects RS in session and window names, but a
# pane's working directory can legitimately contain one.  An extra field shifts
# every later section, which truncates a path AND drops the current-row marker
# — silently, on every row.
#
# --preview batches the same way, and is held to the same two rules below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-batch-test-$$"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-batch.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

SOCK_PATH=""
# kill-server leaves the socket file behind (tmux 3.7b): remove it by name
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -f ${SOCK_PATH:+"$SOCK_PATH"}; rm -rf "$WORKDIR"; }
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

tmux_cmd() { tmux -f /dev/null -L "$SOCK" "$@"; }

echo "interdimux gather-batching tests"
echo

# Every pane runs a process that never prints and never changes, and window
# names are frozen, so two renders a moment apart can only differ by the thing
# under test.  (They used to start the user's login shell, and a `sleep 2`
# stood in for "it has finished starting".)
PC='exec sleep 900'
tmux_cmd new-session -d -s b1 -x 200 -y 50 -c "$SCRIPT_DIR" "$PC"
tmux_cmd set -g automatic-rename off
tmux_cmd new-window  -d -t '=b1:' -n two -c "$SCRIPT_DIR" "$PC"
tmux_cmd split-window -d -t '=b1:two' -c "$SCRIPT_DIR" "$PC"
tmux_cmd new-session -d -s b2 -x 200 -y 50 -c "$SCRIPT_DIR" "$PC"

# Settled: every pane has its cwd and has exec'd its command.
settled() {
  local l
  while IFS= read -r l; do
    [ "$l" = "cwd sleep" ] || return 1
  done < <(tmux -L "$SOCK" list-panes -a -F '#{?pane_current_path,cwd,nocwd} #{pane_current_command}' 2>/dev/null)
}
wait_settled() {
  local i
  for i in $(seq 1 100); do settled && return 0; sleep 0.1; done
  echo "  (the panes never settled)" >&2
  return 1
}

SOCK_PATH="$(tmux -L "$SOCK" display-message -p '#{socket_path}')"
export TMUX="$SOCK_PATH,99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=b1:0' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_SHOW_FULL_COMMAND=off INTERDIMUX_SHOW_GIT_BRANCH=off
export INTERDIMUX_ORDER=mru INTERDIMUX_USE_ZOXIDE=off
wait_settled || true

# Pin the clock for both runs.  The age column is derived from it, so without
# this the two renders disagree whenever a second boundary falls between them —
# which is a property of when the test ran, not of batching.
export INTERDIMUX_NOW=$(( $(date +%s) + 5 ))
batched=$(bash "$SCRIPT" --list 2>/dev/null)
separate=$(INTERDIMUX_NO_BATCH=1 bash "$SCRIPT" --list 2>/dev/null)

if [ "$batched" = "$separate" ]; then
  report "batched output matches separate queries" pass
else
  report "batched output matches separate queries" fail
  ERRORS+="$(diff <(printf '%s\n' "$separate") <(printf '%s\n' "$batched") | head -6 || true)"$'\n'
fi

marker_count=$(printf '%s\n' "$batched" | sed 's/\x1b\[[0-9;]*m//g' | grep -c '^\*' || true)
if [ "$marker_count" -ge 1 ]; then
  report "current-row marker survives batching ($marker_count rows)" pass
else
  report "current-row marker survives batching (found none)" fail
fi

# Only ONE tmux invocation should be needed for the queries.  (A cold run also
# dumps options, so prime that away to isolate the gather.)
if command -v strace >/dev/null 2>&1; then
  tr_out="$WORKDIR/trace"
  INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_SHOW_PREVIEW=off INTERDIMUX_POPUP_WIDTH=80% \
    strace -f -e trace=execve -o "$tr_out" bash "$SCRIPT" --list >/dev/null 2>&1 || true
  n=$(grep -c 'execve("[^"]*/tmux"' "$tr_out" || true)
  if [ "$n" -eq 1 ]; then
    report "the gather costs exactly one tmux invocation" pass
  else
    report "the gather costs exactly one tmux invocation (got $n)" fail
  fi
else
  echo "  (skipped exec-count check: no strace)"
fi

# --- the RS-in-a-field guard -------------------------------------------------
rsdir="$WORKDIR/$(printf 'dir\036rs')"
mkdir -p "$rsdir"
tmux_cmd new-window -d -t '=b1:' -n rsw -c "$rsdir" "$PC"
wait_settled || true

rs_batched=$(bash "$SCRIPT" --list 2>/dev/null)
rs_separate=$(INTERDIMUX_NO_BATCH=1 bash "$SCRIPT" --list 2>/dev/null)

if [ "$rs_batched" = "$rs_separate" ]; then
  report "an RS inside a pane path falls back instead of corrupting rows" pass
else
  report "an RS inside a pane path falls back instead of corrupting rows" fail
  ERRORS+="$(diff <(printf '%s\n' "$rs_separate") <(printf '%s\n' "$rs_batched") | head -8 || true)"$'\n'
fi

bad=$(printf '%s\n' "$rs_batched" | awk -F'\t' 'NF != 4 { print }')
if [ -z "$bad" ]; then
  report "rows keep 4 fields even with an RS in a path" pass
else
  report "rows keep 4 fields even with an RS in a path" fail
fi

marker_count=$(printf '%s\n' "$rs_batched" | sed 's/\x1b\[[0-9;]*m//g' | grep -c '^\*' || true)
if [ "$marker_count" -ge 1 ]; then
  report "current-row marker survives an RS in a path" pass
else
  report "current-row marker survives an RS in a path (found none)" fail
fi

# --- the preview's one command list (review PERF-06) -------------------------
# --preview fetches a session row's header, window list and capture -- and a
# window or pane row's check and capture -- through ONE tmux client, framed by
# RS with the capture last.  The split is easy to get subtly wrong, and nothing
# else would notice: a newline left on the window list is an empty window row
# at the top and bottom of every session's preview, one left on the capture a
# blank line above it, and a cwd holding an RS cuts the window list in two.  So
# every row of a fixture built to provoke those, and rows that are gone,
# preview byte for byte as the separate queries (INTERDIMUX_NO_BATCH) preview
# them -- and what tmux itself says, not either path, decides the rest.
#
#   pv     0: prints, in colour   1: cwd holds an RS, split (a blank pane)
#          2: NAMED "7", so the gone row pv:7 still finds it by name
#   lead   prints blank lines first, from a cwd that holds a newline
#   $cash  a name tmux would read as a session ID
nldir="$WORKDIR/$(printf 'dir\nnl')"
mkdir -p "$nldir"
printf '%s\n' "printf 'hello\\n\\n\\033[31mred\\033[0m text\\n\\n\\n'; exec sleep 900" > "$WORKDIR/hello.sh"
printf '%s\n' "printf '\\n\\nlead blank\\n'; exec sleep 900" > "$WORKDIR/lead.sh"
printf '%s\n' "printf 'NAMED-SEVEN\\n'; exec sleep 900" > "$WORKDIR/named.sh"
tmux_cmd new-session -d -s pv -x 120 -y 30 -c "$SCRIPT_DIR" "exec sh '$WORKDIR/hello.sh'"
tmux_cmd new-window -d -t '=pv:' -n rs -c "$rsdir" "$PC"
tmux_cmd split-window -d -t '=pv:1' -c "$rsdir" "$PC"
tmux_cmd new-window -d -t '=pv:' -n 7 -c "$SCRIPT_DIR" "exec sh '$WORKDIR/named.sh'"
tmux_cmd new-session -d -s lead -x 120 -y 30 -c "$nldir" "exec sh '$WORKDIR/lead.sh'"
tmux_cmd new-session -d -s '$cash' -x 120 -y 30 -c "$SCRIPT_DIR" "$PC"
wait_settled || true
# ...and every pane's output has reached its screen
painted() {
  [[ "$(tmux -L "$SOCK" capture-pane -p -t '=pv:0.0' 2>/dev/null)" == *"red text"* ]] \
    && [[ "$(tmux -L "$SOCK" capture-pane -p -t '=pv:2.0' 2>/dev/null)" == *NAMED-SEVEN* ]] \
    && [[ "$(tmux -L "$SOCK" capture-pane -p -t '=lead:0.0' 2>/dev/null)" == *"lead blank"* ]]
}
for _ in $(seq 1 100); do painted && break; sleep 0.1; done

preview() { # SPEC [VAR=value ...]: the preview, its trailing newlines and status kept
  local spec="$1"; shift
  env FZF_PREVIEW_COLUMNS=60 FZF_PREVIEW_LINES=30 "$@" bash "$SCRIPT" --preview "$spec" 2>&1
  printf 'rc=%s' "$?"
}
pv_specs=()
while IFS= read -r spec; do
  case "$spec" in [SWP]:*) pv_specs+=("$spec") ;; esac
done < <(bash "$SCRIPT" --list 2>/dev/null | awk -F'\t' '{ print $NF }')
pv_specs+=('S:nosuch' 'W:nosuch:0' 'P:nosuch:0:0' 'W:pv:9' 'P:pv:1:5' 'W:pv:7' 'P:pv:7:0')
pv_diff=0 pv_kinds=""
for spec in "${pv_specs[@]}"; do
  a=$(preview "$spec")
  b=$(preview "$spec" INTERDIMUX_NO_BATCH=1)
  [[ "$pv_kinds" == *"${spec%%:*}"* ]] || pv_kinds+="${spec%%:*}"
  if [ "$a" != "$b" ]; then
    pv_diff=$((pv_diff + 1))
    ERRORS+="  --preview $spec, separate queries (<) vs one client (>):"$'\n'
    ERRORS+="$(diff <(printf '%s\n' "$b" | cat -v) <(printf '%s\n' "$a" | cat -v) | head -6 || true)"$'\n'
  fi
done
# at least this fixture's 10 rows (pv's 6, lead's 2, $cash's 2) and the 7 gone
if [ "${#pv_specs[@]}" -ge 17 ] && [ "$pv_kinds" = SWP ] && [ "$pv_diff" -eq 0 ]; then
  report "every row previews as the separate queries preview it (${#pv_specs[@]} rows)" pass
else
  report "every row previews as the separate queries preview it (${#pv_specs[@]} rows, kinds $pv_kinds, $pv_diff differ)" fail
fi

strip() { sed 's/\x1b\[[0-9;]*m//g'; }
# a window row per window, and the RS-cut path whole: the rows run from the
# line under the header's rule to the blank line above the capture's
out=$(preview 'S:pv' | strip)
want=$(tmux -L "$SOCK" list-windows -t '=pv' -F x | wc -l | tr -d ' ')
got=$(printf '%s\n' "$out" | awk 'NR > 2 && $0 == "" { exit } NR > 2 { n++ } END { print n + 0 }')
if [ "$got" = "$want" ] && [[ "$out" == *"dir"$'\x1e'"rs"* ]]; then
  report "a session's preview lists its $want windows, an RS in a cwd and all" pass
else
  report "a session's preview lists its $want windows, an RS in a cwd and all (got $got rows)" fail
  ERRORS+="$(printf '%s\n' "$out" | cat -v | head -8 || true)"$'\n'
fi
# the capture as the pane shows it: two blank lines, then its text
out=$(preview 'S:lead' | strip)
got=$(printf '%s\n' "$out" | awk '/── active pane/ { on = 1; next } on && n++ < 3 { printf "[%s]", $0 }')
if [ "$got" = "[][][lead blank]" ]; then
  report "a capture that starts with blank lines keeps exactly those" pass
else
  report "a capture that starts with blank lines keeps exactly those (got $got)" fail
fi
out=$(preview 'P:pv:0:0' | strip)
got=$(printf '%s\n' "$out" | sed -n '3,5p' | tr '\n' '|')
if [ "$got" = "hello||red text|" ]; then
  report "a pane's preview shows its screen right under the rule" pass
else
  report "a pane's preview shows its screen right under the rule (got $got)" fail
fi
# index 7 is gone, and "=pv:=7" falls back to the window NAMED 7: batched, its
# screen comes back in the same answer, and must not be shown
out="$(preview 'W:pv:7')$(preview 'P:pv:7:0')"
if [[ "$out" != *NAMED-SEVEN* ]] && [ "$(printf '%s\n' "$out" | grep -c 'cannot capture pane')" = 2 ]; then
  report "a gone window's preview never shows the window named like its index" pass
else
  report "a gone window's preview never shows the window named like its index" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
