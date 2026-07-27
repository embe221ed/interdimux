#!/usr/bin/env bash
#
# Scheduled keys: send a command to a pane at a future time.
#
# The assertions that matter are the safety ones.  Verified on this host:
#   * `at` snapshots the WHOLE submitting environment, $TMUX included, so a job
#     inherits a stale pointer to a possibly-dead server.  The socket must be
#     passed explicitly.
#   * pane ids are RECYCLED across a tmux server restart — scheduling for
#     session alpha's %0, restarting, and firing lands the keys in whatever
#     session owns %0 now.  For a scheduled deploy that is data loss, so every
#     job carries a server-pid guard.
#   * bare `atq` lists every queue including the user's own unrelated jobs, so
#     interdimux uses a dedicated queue letter and never touches anything else.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-sched-test-$$"
PASS=0
FAIL=0
ERRORS=""
SUBMITTED=()
TMPD_SCHED="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-sched.XXXXXX")"

cleanup() {
  rm -rf "$TMPD_SCHED"
  for j in ${SUBMITTED[@]+"${SUBMITTED[@]}"}; do atrm "$j" 2>/dev/null || true; done
  tmux -L "$SOCK" kill-server 2>/dev/null || true
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

echo "interdimux scheduled-keys tests"
echo

# Count the user's OWN at jobs — everything NOT in interdimux's queue.  bare
# `atq` lists every queue, but its columns are platform-specific: GNU appends
# the queue letter and owner ("… i user"), while BSD/macOS atq prints only
# "<id>\t<date>" with no queue column at all — so `grep -v " i "` cannot tell
# our job from the user's there and miscounts.  Compare id SETS instead: every
# id, minus the ids in our own queue.  Works on both.
count_other_jobs() {
  comm -23 \
    <(atq       2>/dev/null | awk '{print $1}' | sort -u) \
    <(atq -q i  2>/dev/null | awk '{print $1}' | sort -u) \
    | grep -c . || true
}

if ! command -v at >/dev/null 2>&1 || ! command -v atq >/dev/null 2>&1; then
  echo "  (skipped: 'at' is not installed)"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

tmux -f /dev/null -L "$SOCK" new-session -d -s target -x 120 -y 30
tmux -L "$SOCK" new-window -d -t '=target:' -n second
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=target:0' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
sleep 1

before_other=$(count_other_jobs)

# --- submit --------------------------------------------------------------------
out=$(bash "$SCRIPT" --send-at "now + 1 hour" '=target:0' 'echo SCHEDULED_MARKER' 2>&1) || true
jid=$(printf '%s' "$out" | grep -oE 'job [0-9]+' | head -1 | awk '{print $2}')
if [ -n "$jid" ]; then
  SUBMITTED+=("$jid"); report "a job can be scheduled (job $jid)" pass
else
  report "a job can be scheduled" fail; ERRORS+="    $out"$'\n'
fi

# --- it lands in our own queue, and only ours ------------------------------------
if [ -n "$jid" ] && atq -q i | awk '{print $1}' | grep -qx "$jid"; then
  report "the job goes to interdimux's dedicated at queue" pass
else
  report "the job goes to interdimux's dedicated at queue" fail
fi
after_other=$(count_other_jobs)
if [ "$before_other" = "$after_other" ]; then
  report "the user's own at jobs are untouched" pass
else
  report "the user's own at jobs are untouched ($before_other -> $after_other)" fail
fi

# --- the job body is self-describing and safe ------------------------------------
if [ -n "$jid" ]; then
  body=$(at -c "$jid" 2>/dev/null)
  printf '%s' "$body" | grep -q '^# imux:v1 ' \
    && report "the job is self-describing (imux:v1 header)" pass \
    || report "the job is self-describing (imux:v1 header)" fail

  # It must address the server by explicit socket, because at replays a stale
  # $TMUX from submit time.
  printf '%s' "$body" | grep -q 'tmux -S ' \
    && report "the job addresses tmux by explicit socket path" pass \
    || report "the job addresses tmux by explicit socket path" fail

  # The guard against pane-id recycling.
  printf '%s' "$body" | grep -q "display-message -p '#{pid}'" \
    && report "the job guards on the tmux server pid" pass \
    || report "the job guards on the tmux server pid" fail

  # Output must be logged, not discarded: with no MTA, atd destroys it.
  printf '%s' "$body" | grep -qE 'exec >>' \
    && report "the job logs its output rather than losing it to the missing MTA" pass \
    || report "the job logs its output rather than losing it to the missing MTA" fail

  # The resolved pane id, not the user's target string, is what gets sent to.
  want_pane=$(tmux -L "$SOCK" list-panes -t '=target:0' -F '#{pane_id}' | head -1)
  printf '%s' "$body" | grep -q "pane=.*${want_pane}" \
    && report "the target is resolved to a stable pane id at submit time" pass \
    || report "the target is resolved to a stable pane id at submit time" fail
fi

# --- listing ---------------------------------------------------------------------
if [ -n "$jid" ] && bash "$SCRIPT" --sched-list 2>/dev/null | grep -q "$jid"; then
  report "--sched-list shows the job" pass
else
  report "--sched-list shows the job" fail
fi
if bash "$SCRIPT" --sched-list 2>/dev/null | grep -q 'SCHEDULED_MARKER'; then
  report "--sched-list shows what will be sent" pass
else
  report "--sched-list shows what will be sent" fail
fi

# --- cancelling ------------------------------------------------------------------
if bash "$SCRIPT" --sched-cancel 999999 >/dev/null 2>&1; then
  report "cancelling an unknown id is refused" fail
else
  report "cancelling an unknown id is refused" pass
fi
if [ -n "$jid" ]; then
  bash "$SCRIPT" --sched-cancel "$jid" >/dev/null 2>&1 || true
  if atq -q i | awk '{print $1}' | grep -qx "$jid"; then
    report "--sched-cancel removes the job" fail
  else
    report "--sched-cancel removes the job" pass
    SUBMITTED=()
  fi
fi

# --- bad input --------------------------------------------------------------------
if bash "$SCRIPT" --send-at "now + 1 hour" '%99999' 'echo x' >/dev/null 2>&1; then
  report "an unknown target is refused" fail
else
  report "an unknown target is refused" pass
fi
if bash "$SCRIPT" --send-at "not a time" '=target:0' 'echo x' >/dev/null 2>&1; then
  report "an unparseable time is refused" fail
else
  report "an unparseable time is refused" pass
fi

# --- sub-minute delays go to tmux, which at cannot express -------------------------
out=$(bash "$SCRIPT" --send-in 2 '=target:0' 'echo FAST_MARKER' 2>&1) || true
if printf '%s' "$out" | grep -q 'tmux timer'; then
  report "a sub-minute delay uses tmux's own timer" pass
else
  report "a sub-minute delay uses tmux's own timer" fail; ERRORS+="    $out"$'\n'
fi
sleep 4
if tmux -L "$SOCK" capture-pane -t '=target:0' -p 2>/dev/null | grep -q 'FAST_MARKER'; then
  report "the sub-minute job actually delivered the keys" pass
else
  report "the sub-minute job actually delivered the keys" fail
fi

# --- run-shell FORMAT-EXPANDS its argument -------------------------------------
# Verified: "echo host-is-#H" arrived in the pane as "echo host-is-<hostname>".
# tmux rewrote the user's command, and because the substituted text is not
# re-quoted, a value like a pane title could inject shell.  '##' is the escape.
out=$(bash "$SCRIPT" --send-in 2 '=target:0' 'echo fmt-#H-and-#S' 2>&1) || true
sleep 4
pane=$(tmux -L "$SOCK" capture-pane -t '=target:0' -p 2>/dev/null | grep -m1 'fmt-' || true)
case "$pane" in
  *'fmt-#H-and-#S'*) report "a scheduled command is not rewritten by tmux format expansion" pass ;;
  *) report "a scheduled command is not rewritten by tmux format expansion (got: $pane)" fail ;;
esac

# --- the job body is executed by /bin/sh, not by bash -----------------------------
# `at` replays the body under a plain POSIX shell (dash here).  The body used to
# be quoted with bash's printf %q, which switches to ANSI-C quoting the instant a
# control character appears: `echo a<TAB>b` became `echo\ a$'\t'b`, and dash --
# which has no $'...' -- delivered the literal text `echo a$\tb` to the pane.
#
# Assert it behaviourally: run the real job body under dash with a `tmux` shim
# that records what it was asked to send, and compare against the original.
TRICKY="echo a$(printf '\t')b 'q' \$HOME"
# XDG_STATE_HOME so the job's log path points into the test dir, not the user's
# real ~/.local/state -- the body bakes the absolute path in at submit time.
out=$(XDG_STATE_HOME="$TMPD_SCHED/state" bash "$SCRIPT" --send-at "now + 1 hour" '=target:0' "$TRICKY" 2>&1) || true
jid2=$(printf '%s' "$out" | grep -oE 'job [0-9]+' | head -1 | awk '{print $2}')
if [ -n "$jid2" ]; then
  SUBMITTED+=("$jid2")
  body=$(at -c "$jid2" 2>/dev/null)
  # the body is everything after at's environment preamble; the marker heredoc
  # wrapper is at's own, so just take the imux:v1 header onwards
  imux_body=$(printf '%s\n' "$body" | sed -n '/^# imux:v1 /,$p')

  shimdir="$TMPD_SCHED/shim"; mkdir -p "$shimdir"
  cat > "$shimdir/tmux" <<'SHIM'
#!/bin/sh
# invoked as: tmux -S <sock> <verb> ...
shift 2            # past -S <sock>
verb=$1; shift
case "$verb" in
  display-message) cat "$IMUX_SHIM_PID" ;;
  send-keys)
    shift 2        # past -t <pane>
    [ "$1" = "--" ] && shift
    [ "$1" = "Enter" ] || printf '%s' "$1" > "$IMUX_SHIM_SENT"
    ;;
esac
SHIM
  chmod +x "$shimdir/tmux"
  printf '%s' "$(tmux -L "$SOCK" display-message -p '#{pid}')" > "$TMPD_SCHED/pid"
  printf '%s\n' "$imux_body" > "$TMPD_SCHED/body.sh"

  if dash -n "$TMPD_SCHED/body.sh" 2>/dev/null || sh -n "$TMPD_SCHED/body.sh" 2>/dev/null; then
    report "the job body parses as POSIX sh" pass
  else
    report "the job body parses as POSIX sh" fail
  fi

  rm -f "$TMPD_SCHED/sent"
  ( PATH="$shimdir:$PATH" IMUX_SHIM_PID="$TMPD_SCHED/pid" IMUX_SHIM_SENT="$TMPD_SCHED/sent" \
      /bin/sh "$TMPD_SCHED/body.sh" ) >/dev/null 2>&1 || true
  got=$(cat "$TMPD_SCHED/sent" 2>/dev/null || true)
  if [ "$got" = "$TRICKY" ]; then
    report "a command with a tab, a quote and a \$ survives /bin/sh verbatim" pass
  else
    report "a command with a tab, a quote and a \$ survives /bin/sh verbatim" fail
    ERRORS+="    want: $(printf '%s' "$TRICKY" | cat -A)"$'\n'
    ERRORS+="    got : $(printf '%s' "$got" | cat -A)"$'\n'
  fi

  # and the structural tell: no bash-only ANSI-C quoting anywhere in the body
  if printf '%s' "$imux_body" | grep -q "\$'"; then
    report "the job body contains no bash-only \$'...' quoting" fail
  else
    report "the job body contains no bash-only \$'...' quoting" pass
  fi
fi

# --- and the same for the sub-minute path, which /bin/sh runs unconditionally ------
# `tmux run-shell` hands its argument to /bin/sh, so this one was broken for
# every user, not just those whose atd shell is dash.  Send into a pane running
# `cat` rather than a shell: a TAB typed at a shell prompt triggers completion,
# which would mangle the very character under test.
tmux -L "$SOCK" new-window -d -t '=target:' -n catcher "cat > '$TMPD_SCHED/caught'"
for _i in $(seq 1 50); do [ -e "$TMPD_SCHED/caught" ] && break; sleep 0.1; done
TABBY="tab[$(printf '\t')]end"
bash "$SCRIPT" --send-in 2 '=target:catcher' "$TABBY" >/dev/null 2>&1 || true
for _i in $(seq 1 80); do grep -q 'end' "$TMPD_SCHED/caught" 2>/dev/null && break; sleep 0.1; done
caught=$(head -1 "$TMPD_SCHED/caught" 2>/dev/null | tr -d '\r')
if [ "$caught" = "$TABBY" ]; then
  report "a sub-minute command with a tab survives run-shell's /bin/sh" pass
else
  report "a sub-minute command with a tab survives run-shell's /bin/sh" fail
  ERRORS+="    want: $(printf '%s' "$TABBY" | cat -A)"$'\n'
  ERRORS+="    got : $(printf '%s' "$caught" | cat -A)"$'\n'
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
