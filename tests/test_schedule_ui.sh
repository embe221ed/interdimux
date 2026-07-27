#!/usr/bin/env bash
#
# The Schedule dashboard entry: the two-prompt dialog flow, the relative-time
# shorthand, undo, and the jobs list.
#
# What these assertions are really defending:
#
#   * A scheduled command fires into ONE pane.  ctrl-t's send BROADCASTS to every
#     pane under the selected row, and a broadcast that happens unattended two
#     hours later is a different and much worse thing than one you watch happen.
#     A window or session row must narrow to a single pane.
#   * The relative shorthand must not shadow anything `at` already accepts.
#     Probed on this host: `at` rejects a bare 1-3 digit number outright, and
#     reads four digits as HHMM.  So "90" may mean 90 minutes, but "1730" must
#     still mean 17:30 — get that backwards and a command lands 28 hours late.
#   * A rejected time must not cost the user the command they already typed.
#   * The job header must survive a session name containing a space.  The old
#     single-line "pane=… target=… desc=…" form could not be parsed back, and
#     tmux allows both spaces and the literal "desc=" in a session name.
#
# Input comes from a fixture FILE, which is the reason input_dialog reads through
# a process-wide fd: re-opening a regular file rewinds it to offset 0, so a flow
# with two prompts used to replay its first answer forever.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-schedui-$$"
PASS=0
FAIL=0
ERRORS=""
SUBMITTED=()
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-schedui.XXXXXX")"

cleanup() {
  # Every job this suite creates is removed, whether or not the assertion that
  # created it passed.
  for j in ${SUBMITTED[@]+"${SUBMITTED[@]}"}; do atrm "$j" 2>/dev/null || true; done
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  tmux -L "${SOCK}-mo" kill-server 2>/dev/null || true
  tmux -L "${SOCK}-mi" kill-server 2>/dev/null || true
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

echo "interdimux schedule-UI tests"
echo

if ! command -v at >/dev/null 2>&1 || ! command -v atq >/dev/null 2>&1; then
  echo "  (skipped: 'at' is not installed)"
  echo; echo "Results: 0 passed, 0 failed"; exit 0
fi

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

tmux -f /dev/null -L "$SOCK" new-session -d -s sched -n one -x 120 -y 30
tmux -L "$SOCK" split-window -t '=sched:0' -h
tmux -L "$SOCK" new-window -d -t '=sched:' -n two
tmux -L "$SOCK" split-window -t '=sched:1' -h
# A name with a space: the field the old job header could not round-trip.
tmux -f /dev/null -L "$SOCK" new-session -d -s 'my proj' -x 120 -y 30

export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=sched:0' -F '#{pane_id}' | head -1)"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

queue_ids() { atq -q i 2>/dev/null | awk '{print $1}' | sort -n; }

# Fixture bytes: one argument per answer, each newline-terminated.  Assembled
# by concatenation rather than with `printf %b` because \x takes "one or two"
# hex digits, so "\x152h" reads as \x15 followed by "2h" only if you are certain
# of the greediness — and getting it wrong silently sends a different key.
CTRL_U=$'\025'
ESC=$'\033'
fixture() {
  local out="" a
  for a in "$@"; do out+="$a"$'\n'; done
  printf '%s' "$out"
}

# Run the schedule action with a byte-exact input fixture.  Sets OUT_FILE to the
# dialog's rendered output and NEW_JOB to the id of the job it created (empty if
# none).  Never fails the suite: the assertion decides what "none" means.
run_schedule() {
  local spec="$1"
  shift
  local before after
  before=$(queue_ids)
  IN_FILE="$TMPD/in.$RANDOM"
  OUT_FILE="$TMPD/out.$RANDOM"
  fixture "$@" > "$IN_FILE"
  : > "$OUT_FILE"
  INTERDIMUX_TTY_IN="$IN_FILE" INTERDIMUX_TTY_OUT="$OUT_FILE" \
    bash "$SCRIPT" --action schedule "$spec" >"$TMPD/stdout" 2>"$TMPD/stderr" || true
  after=$(queue_ids)
  NEW_JOB=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
  [ -n "$NEW_JOB" ] && SUBMITTED+=("$NEW_JOB")
  return 0
}

# The at time of a job, ending in HH:MM.  GNU atq honours -o and yields a
# sortable "YYYY-MM-DD HH:MM"; BSD/macOS atq has no -o and prints
# "<id>\t<dow> <mon> <dd> HH:MM:SS <YYYY>" — so fall back and drop the seconds,
# exactly as sched_rows does in the script.  The full stamp is only compared
# under GNU `date -d`; the BSD branch only needs its trailing HH:MM to be right.
job_when() {
  local j="$1" rows
  if rows=$(atq -q i -o '%Y-%m-%d %H:%M' 2>/dev/null); then
    printf '%s\n' "$rows" | awk -v j="$j" '$1==j{print $2" "$3}'
  else
    atq -q i 2>/dev/null | awk -v j="$j" '$1==j{ t=$5; sub(/:[0-9][0-9]$/,"",t); print $2" "$3" "$4" "t }'
  fi
}
# The pane a job will fire into, read back out of the job body
job_pane() {
  at -c "$1" 2>/dev/null | sed -n 's/^# imux-pane: //p' | head -1
}
job_target() {
  at -c "$1" 2>/dev/null | sed -n 's/^# imux-target: //p' | head -1
}
job_desc() {
  at -c "$1" 2>/dev/null | sed -n 's/^# imux-desc: //p' | head -1
}
strip_esc() { sed 's/\x1b\[[0-9;]*m//g'; }

# Does this host's date understand relative offsets?  (GNU does; BSD wants -v.)
HAVE_DATE_D=0
date -d '+1 minute' '+%Y' >/dev/null 2>&1 && HAVE_DATE_D=1

# ---------------------------------------------------------------------------
# 1. the happy path: a pane row, two prompts, one job
# ---------------------------------------------------------------------------

PIDX=$(tmux -L "$SOCK" list-panes -t '=sched:0' -F '#{pane_index}' | tail -1)
WANT_PANE=$(tmux -L "$SOCK" display-message -p -t "=sched:0.$PIDX" '#{pane_id}')

run_schedule "P:sched:0:$PIDX" '2h' 'echo SCHEDUI_ONE' 'x'

if [ -n "$NEW_JOB" ]; then
  report "a pane row schedules one job" pass
else
  report "a pane row schedules one job" fail
fi

if [ -n "$NEW_JOB" ] && [ "$(job_desc "$NEW_JOB")" = "echo SCHEDUI_ONE" ]; then
  report "the command typed at the second prompt is what gets scheduled" pass
else
  report "the command typed at the second prompt is what gets scheduled" fail
fi

# The second prompt reading the FIRST answer again is the exact failure the
# shared input fd fixes, so pin it: the two answers must differ.
if [ -n "$NEW_JOB" ] && [ "$(job_desc "$NEW_JOB")" != "2h" ]; then
  report "the two prompts read two different answers (fixture is not rewound)" pass
else
  report "the two prompts read two different answers (fixture is not rewound)" fail
fi

if [ -n "$NEW_JOB" ] && [ "$(job_pane "$NEW_JOB")" = "$WANT_PANE" ]; then
  report "the job targets the pane that was selected" pass
else
  report "the job targets the pane that was selected" fail
fi

# The resolved absolute time is the whole point of the confirmation screen:
# "1:10am" is tomorrow, and so is "13:00" typed at 13:31.
if grep -q "$(date '+%Y')" "$OUT_FILE" 2>/dev/null; then
  report "the confirmation screen shows the resolved fire time" pass
else
  report "the confirmation screen shows the resolved fire time" fail
fi

# ---------------------------------------------------------------------------
# 2. a window row narrows to that window's ACTIVE pane — it does not broadcast
# ---------------------------------------------------------------------------

W1_ACTIVE=$(tmux -L "$SOCK" display-message -p -t '=sched:1' '#{pane_id}')
before_n=$(queue_ids | grep -c . || true)
run_schedule "W:sched:1" '3h' 'echo SCHEDUI_WIN' 'x'
after_n=$(queue_ids | grep -c . || true)

if [ "$(( after_n - before_n ))" -eq 1 ]; then
  report "a window row with two panes creates ONE job, not one per pane" pass
else
  report "a window row with two panes creates ONE job, not one per pane" fail
fi

if [ -n "$NEW_JOB" ] && [ "$(job_pane "$NEW_JOB")" = "$W1_ACTIVE" ]; then
  report "a window row resolves to that window's active pane" pass
else
  report "a window row resolves to that window's active pane" fail
fi

# ---------------------------------------------------------------------------
# 3. a session row likewise narrows to one pane
# ---------------------------------------------------------------------------

before_n=$(queue_ids | grep -c . || true)
run_schedule "S:sched" '4h' 'echo SCHEDUI_SESS' 'x'
after_n=$(queue_ids | grep -c . || true)

if [ "$(( after_n - before_n ))" -eq 1 ]; then
  report "a session row with two windows and four panes creates ONE job" pass
else
  report "a session row with two windows and four panes creates ONE job" fail
fi

# ---------------------------------------------------------------------------
# 4. the relative shorthand, and the grammar it must not shadow
# ---------------------------------------------------------------------------

if [ "$HAVE_DATE_D" = 1 ]; then
  # "5m" → five minutes.  Accept a one-minute window either side: `at` truncates
  # to the minute, so a submission that crosses a second boundary lands one
  # minute off and that is not a bug.
  run_schedule "P:sched:0:0" '5m' 'echo SCHEDUI_5M' 'x'
  got=$(job_when "$NEW_JOB")
  ok=0
  for d in 4 5 6; do
    [ "$got" = "$(date -d "+$d minutes" '+%Y-%m-%d %H:%M')" ] && ok=1
  done
  if [ "$ok" = 1 ]; then
    report "5m schedules five minutes out (got $got)" pass
  else
    report "5m schedules five minutes out (got $got, wanted ~$(date -d '+5 minutes' '+%Y-%m-%d %H:%M'))" fail
  fi

  # A bare 1-3 digit number is MINUTES.  `at` rejects those outright, so this
  # extends its grammar rather than overriding it.
  run_schedule "P:sched:0:0" '90' 'echo SCHEDUI_90' 'x'
  got=$(job_when "$NEW_JOB")
  ok=0
  for d in 89 90 91; do
    [ "$got" = "$(date -d "+$d minutes" '+%Y-%m-%d %H:%M')" ] && ok=1
  done
  if [ "$ok" = 1 ]; then
    report "a bare 90 means 90 minutes, not 90 seconds (got $got)" pass
  else
    report "a bare 90 means 90 minutes (got $got, wanted ~$(date -d '+90 minutes' '+%Y-%m-%d %H:%M'))" fail
  fi
else
  report "5m schedules five minutes out (skipped: no date -d)" pass
  report "a bare 90 means 90 minutes (skipped: no date -d)" pass
fi

# FOUR digits are at's own HHMM and must be left alone.  If the shorthand ever
# widens to four digits, 1730 becomes 1730 minutes — a command 28 hours late.
run_schedule "P:sched:0:0" '1730' 'echo SCHEDUI_HHMM' 'x'
got=$(job_when "$NEW_JOB")
if [ "${got##* }" = "17:30" ]; then
  report "1730 is still at's HHMM, not 1730 minutes (got $got)" pass
else
  report "1730 is still at's HHMM, not 1730 minutes (got $got)" fail
fi

# 17:30 is unambiguous in every reading and must work verbatim.
run_schedule "P:sched:0:0" '17:30' 'echo SCHEDUI_CLOCK' 'x'
got=$(job_when "$NEW_JOB")
if [ "${got##* }" = "17:30" ]; then
  report "a clock time is passed to at verbatim" pass
else
  report "a clock time is passed to at verbatim (got $got)" fail
fi

# ---------------------------------------------------------------------------
# 5. a rejected time re-prompts and KEEPS the command
# ---------------------------------------------------------------------------
#
# Fixture: a bad time, then the command, then ctrl-u (clear the field, whose
# initial value is the bad time) + a good time, then a key to close.
run_schedule "P:sched:0:0" 'nonsense' 'echo SCHEDUI_RETRY' "${CTRL_U}2h" 'x'

if [ -n "$NEW_JOB" ] && [ "$(job_desc "$NEW_JOB")" = "echo SCHEDUI_RETRY" ]; then
  report "a rejected time re-prompts and keeps the command already typed" pass
else
  report "a rejected time re-prompts and keeps the command already typed" fail
fi

# at's own diagnosis is the useful one; ours only repeats what was typed.
if grep -qi 'garbled\|syntax error' "$OUT_FILE" 2>/dev/null; then
  report "at's own complaint is shown, not just 'rejected'" pass
else
  report "at's own complaint is shown, not just 'rejected'" fail
fi

# An exhausted input source must END the retry loop.  input_dialog accepts at
# EOF ("take what we have"), which is right for one prompt and non-terminating
# for a loop: before the _input_eof flag this spun forever resubmitting the same
# rejected time.
before_n=$(queue_ids | grep -c . || true)
printf 'nonsense\ncmd-that-never-runs\n' > "$TMPD/eof_in"
: > "$TMPD/eof_out"
# `timeout` must signal the LOOPING process, so run the script as its DIRECT
# child.  Wrapping it in `bash -c` left the grandchild spinning after the
# wrapper died, and because that orphan had inherited this suite's stdout the
# whole run then appeared to hang producing nothing at all.  Its output goes to
# files for the same reason.
rc=0
timeout 20 env INTERDIMUX_TTY_IN="$TMPD/eof_in" INTERDIMUX_TTY_OUT="$TMPD/eof_out" \
  bash "$SCRIPT" --action schedule "P:sched:0:0" \
  >"$TMPD/eof_stdout" 2>"$TMPD/eof_stderr" || rc=$?
after_n=$(queue_ids | grep -c . || true)
if [ "$rc" -ne 124 ]; then
  report "a rejected time with no input left exits instead of looping" pass
else
  report "a rejected time with no input left exits instead of looping" fail
fi
if [ "$before_n" = "$after_n" ]; then
  report "the abandoned retry schedules nothing" pass
else
  report "the abandoned retry schedules nothing" fail
fi

# ---------------------------------------------------------------------------
# 6. undo
# ---------------------------------------------------------------------------

before_n=$(queue_ids | grep -c . || true)
run_schedule "P:sched:0:0" '6h' 'echo SCHEDUI_UNDO' 'u'
after_n=$(queue_ids | grep -c . || true)

if [ "$before_n" = "$after_n" ]; then
  report "u on the confirmation screen removes the job again" pass
else
  report "u on the confirmation screen removes the job again" fail
fi

if grep -q 'cancelled' "$OUT_FILE" 2>/dev/null; then
  report "undo says so on screen" pass
else
  report "undo says so on screen" fail
fi

# ---------------------------------------------------------------------------
# 7. cancelling at the first prompt schedules nothing
# ---------------------------------------------------------------------------

before_n=$(queue_ids | grep -c . || true)
run_schedule "P:sched:0:0" "$ESC"
after_n=$(queue_ids | grep -c . || true)
if [ "$before_n" = "$after_n" ]; then
  report "esc at the time prompt schedules nothing" pass
else
  report "esc at the time prompt schedules nothing" fail
fi

# An empty command must not schedule a bare Enter into someone's shell.
before_n=$(queue_ids | grep -c . || true)
run_schedule "P:sched:0:0" '7h' "$ESC"
after_n=$(queue_ids | grep -c . || true)
if [ "$before_n" = "$after_n" ]; then
  report "esc at the command prompt schedules nothing" pass
else
  report "esc at the command prompt schedules nothing" fail
fi

# ---------------------------------------------------------------------------
# 8. a directory row has no pane to schedule into
# ---------------------------------------------------------------------------

before_n=$(queue_ids | grep -c . || true)
run_schedule "D:/tmp" '8h' 'echo SCHEDUI_DIR' 'x'
after_n=$(queue_ids | grep -c . || true)
if [ "$before_n" = "$after_n" ]; then
  report "a directory row schedules nothing" pass
else
  report "a directory row schedules nothing" fail
fi

# ---------------------------------------------------------------------------
# 9. a session name with a space round-trips through the job header
# ---------------------------------------------------------------------------

run_schedule "S:my proj" '9h' 'echo SCHEDUI_SPACE' 'x'
SPACE_JOB="$NEW_JOB"

if [ -n "$SPACE_JOB" ] && [ "$(job_target "$SPACE_JOB")" = "my proj:0.0" ]; then
  report "a session name with a space round-trips through the job header" pass
else
  report "a session name with a space round-trips through the job header (got '$(job_target "${SPACE_JOB:-0}")')" fail
fi

if [ -n "$SPACE_JOB" ] && [ "$(job_desc "$SPACE_JOB")" = "echo SCHEDUI_SPACE" ]; then
  report "the description is not shifted by a space in the target" pass
else
  report "the description is not shifted by a space in the target" fail
fi

# ---------------------------------------------------------------------------
# 10. --jobs-list, the picker's own list
# ---------------------------------------------------------------------------

JL=$(bash "$SCRIPT" --jobs-list 2>/dev/null || true)

if [ -n "$JL" ]; then
  report "--jobs-list produces rows" pass
else
  report "--jobs-list produces rows" fail
fi

# Last field is the job id: it is what {-1} hands the cancel binding, and the
# cancel would target the wrong job if the column order ever moved.
row=$(printf '%s\n' "$JL" | grep -F "SCHEDUI_SPACE" || true)
if [ -n "$row" ] && [ "$(printf '%s' "$row" | awk -F'\t' '{print $NF}')" = "$SPACE_JOB" ]; then
  report "--jobs-list carries the job id as its last field" pass
else
  report "--jobs-list carries the job id as its last field" fail
fi

if [ -n "$row" ] && [ "$(printf '%s' "$row" | awk -F'\t' '{print $(NF-1)}')" = "$(job_pane "$SPACE_JOB")" ]; then
  report "--jobs-list carries the pane id next to last" pass
else
  report "--jobs-list carries the pane id next to last" fail
fi

if [ -n "$row" ] && printf '%s' "$row" | strip_esc | grep -q 'my proj:0\.0'; then
  report "--jobs-list shows a spaced session name intact" pass
else
  report "--jobs-list shows a spaced session name intact" fail
fi

# Chronological, not alphabetical by day name: atq's default column starts with
# "Mon"/"Fri", so sorting it as text ordered Fri before Mon.
firsts=$(printf '%s\n' "$JL" | strip_esc | awk '{print $1" "$2}')
if [ "$firsts" = "$(printf '%s\n' "$firsts" | sort)" ]; then
  report "--jobs-list is ordered chronologically" pass
else
  report "--jobs-list is ordered chronologically" fail
fi

# ---------------------------------------------------------------------------
# 11. --job-cancel
# ---------------------------------------------------------------------------

: > "$TMPD/nkey"; printf 'n' > "$TMPD/nkey"
: > "$TMPD/cancel_out"
INTERDIMUX_TTY_IN="$TMPD/nkey" INTERDIMUX_TTY_OUT="$TMPD/cancel_out" \
  bash "$SCRIPT" --job-cancel "$SPACE_JOB" >/dev/null 2>&1 || true
if queue_ids | grep -qx "$SPACE_JOB"; then
  report "--job-cancel with n keeps the job" pass
else
  report "--job-cancel with n keeps the job" fail
fi

# The confirm must name the job, not just its number: an id alone is not enough
# to tell whether it is the one you meant to drop.
if grep -q 'SCHEDUI_SPACE' "$TMPD/cancel_out" 2>/dev/null; then
  report "the cancel confirm shows what the job will run" pass
else
  report "the cancel confirm shows what the job will run" fail
fi

printf 'y' > "$TMPD/ykey"
INTERDIMUX_TTY_IN="$TMPD/ykey" INTERDIMUX_TTY_OUT=/dev/null \
  bash "$SCRIPT" --job-cancel "$SPACE_JOB" >/dev/null 2>&1 || true
if queue_ids | grep -qx "$SPACE_JOB"; then
  report "--job-cancel with y removes the job" fail
else
  report "--job-cancel with y removes the job" pass
fi

# A stale row (the job already gone) must say so rather than confirm a no-op.
: > "$TMPD/gone_out"
INTERDIMUX_TTY_IN="$TMPD/ykey" INTERDIMUX_TTY_OUT="$TMPD/gone_out" \
  bash "$SCRIPT" --job-cancel "$SPACE_JOB" >/dev/null 2>&1 || true
if grep -qi 'no longer queued' "$TMPD/gone_out" 2>/dev/null; then
  report "cancelling an already-gone job says so" pass
else
  report "cancelling an already-gone job says so" fail
fi

# ---------------------------------------------------------------------------
# 12. the dashboard menu — rendered for real, not grepped
# ---------------------------------------------------------------------------
#
# tmux disables a menu item whose name begins with '-' and DROPS its key column.
# Both facts are load-bearing here (Jobs is unpickable when nothing is queued,
# Schedule when `at` is missing), and neither is visible from the source — the
# menu string is a format tmux interprets.  So render it.
#
# display-menu needs an attached CLIENT, hence the pair of private servers: the
# outer one's pane runs an attach to the inner one, and the menu is captured off
# the outer pane.  Both sockets are private; the user's server is never touched.
MOUT="${SOCK}-mo"; MIN="${SOCK}-mi"
menu_capture() {
  tmux -L "$MIN" kill-server 2>/dev/null || true
  tmux -L "$MOUT" kill-server 2>/dev/null || true
  tmux -f /dev/null -L "$MOUT" new-session -d -s drv -x 100 -y 26 \
    "tmux -f /dev/null -L '$MIN' new-session -s host" 2>/dev/null
  local i
  for i in $(seq 1 80); do
    tmux -L "$MIN" list-clients >/dev/null 2>&1 && break
    sleep 0.15
  done
  env TMUX="$(tmux -L "$MIN" display-message -p '#{socket_path}' 2>/dev/null),99999,0" \
      INTERDIMUX_OPTS_PRIMED=1 \
      bash "$SCRIPT" --dashboard-launch >/dev/null 2>&1 &
  # poll for the menu frame instead of sleeping a fixed amount
  for i in $(seq 1 80); do
    tmux -L "$MOUT" capture-pane -t '=drv:' -p 2>/dev/null | grep -q 'Send keys' && break
    sleep 0.15
  done
  tmux -L "$MOUT" capture-pane -t '=drv:' -p 2>/dev/null
  tmux -L "$MIN" kill-server 2>/dev/null || true
  tmux -L "$MOUT" kill-server 2>/dev/null || true
}
CLEAN_MENU=1

# Empty queue: Jobs must be there but unpickable, i.e. no key in its row.
for j in ${SUBMITTED[@]+"${SUBMITTED[@]}"}; do atrm "$j" 2>/dev/null || true; done
SUBMITTED=()
menu0=$(menu_capture || true)
jobs_row=$(printf '%s\n' "$menu0" | grep -F 'Jobs' | head -1)
# Jobs' accelerator is 'o', not 'j': tmux's display-menu already spends j/k on
# item navigation, so a 'j' mnemonic was a dead key (fixed in the script, hence
# Kill is 'i' too).  A disabled item drops its key column entirely, so the tell
# is the ABSENCE of "(o)".
if [ -n "$jobs_row" ] && ! printf '%s' "$jobs_row" | grep -q '(o)'; then
  report "with nothing queued, the Jobs entry is present but disabled" pass
else
  report "with nothing queued, the Jobs entry is present but disabled (row: '$jobs_row')" fail
fi
if printf '%s\n' "$menu0" | grep -q 'Schedule .*(a)'; then
  report "Schedule is pickable when at is installed" pass
else
  report "Schedule is pickable when at is installed" fail
fi

# One queued: the count rides in the label and the key comes back.
run_schedule "P:sched:0:0" '22h' 'echo SCHEDUI_MENU' 'x'
menu1=$(menu_capture || true)
jobs_row=$(printf '%s\n' "$menu1" | grep -F 'Jobs' | head -1)
if printf '%s' "$jobs_row" | grep -q 'Jobs (1)' && printf '%s' "$jobs_row" | grep -q '(o)'; then
  report "with one queued, Jobs shows the count and becomes pickable" pass
else
  report "with one queued, Jobs shows the count and becomes pickable (row: '$jobs_row')" fail
fi

# Kill is the only destructive entry; it carries the danger colour.
if tmux -f /dev/null -L "$SOCK" show-option -gqv @nothing >/dev/null 2>&1; then :; fi
if grep -q 'POPUP_BORDER_DANGER}\]Kill' "$SCRIPT"; then
  report "the Kill entry is styled with the danger colour" pass
else
  report "the Kill entry is styled with the danger colour" fail
fi

printf '\nResults: %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ -n "$ERRORS" ] && printf '%s' "$ERRORS"

exit "$FAIL"
