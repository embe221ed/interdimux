#!/usr/bin/env bash
#
# The job body --send-at hands to at(1), run the way atd runs it: under
# /bin/sh, later, from nowhere in particular.  And the target it is built for.
#
# What used to go wrong, each reproduced with the body run under dash:
#   * the session label ("name:window.pane") was spliced raw into a live
#     `echo "== ... firing for <label>"` line, so a session name holding a '"',
#     a backtick or '$(' RAN when the job fired; a lone '"' broke the body's
#     syntax and the keys were never sent (review SEC-02).  Session names come
#     from directory names, so this needs nothing more than a project folder.
#   * the body redirected itself into the log with `exec >>LOG` before its
#     server guard and its send.  exec is a special builtin, so under dash a
#     log dir that cannot be created or opened at firing time ENDS the job
#     there: no keys, and no log line saying why (BUG-88).
#   * target '.' with TMUX_PANE unset (cron, an ssh command, env -i) dropped -t,
#     and tmux picked a pane of its own: the keys went somewhere never named,
#     with exit status 0 (BUG-44).
#
# No real at job is ever submitted: `at` is a PATH shim that keeps the body and
# queues nothing, and the body is then run by /bin/sh against this suite's
# private tmux server, whose one pane is `cat >> FILE` -- FILE holds exactly
# what the pane was sent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-jobbody-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-jobbody.XXXXXX")"
TMPD="$(cd "$TMPD" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

# The socket file too: tmux leaves it behind after kill-server.
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"
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
# expect NAME GOT WANT -- exact comparison, both sides shown on failure
expect() {
  if [ "$2" = "$3" ]; then
    report "$1" pass
  else
    report "$1" fail
    ERRORS+="    want: $(printf '%s' "$3" | cat -A | tr '\n' '|')"$'\n'
    ERRORS+="    got : $(printf '%s' "$2" | cat -A | tr '\n' '|')"$'\n'
  fi
}
T() { tmux -L "$SOCK" "$@"; }

echo "interdimux job-body tests"
echo

T -f /dev/null new-session -d -s jb -x 120 -y 30 -c "$TMPD" "exec cat >> '$TMPD/caught'"
T set -g default-command 'bash --norc --noprofile -i'
export TMUX="$(T display-message -p '#{socket_path}'),99999,0"
P0=$(T list-panes -t '=jb:' -F '#{pane_id}' | head -1)
export TMUX_PANE="$P0"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
# a queued job is a real job whatever atd is doing: keep the heads-up out of it
export INTERDIMUX_AT_DAEMON=up
export XDG_CONFIG_HOME="$TMPD/config" XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
mkdir -p "$TMPD/run"

nlines() { local n=0; [ -f "$1" ] && n=$(wc -l < "$1"); echo $((n)); }
# next_line FILE N [SECS] -- wait for FILE to hold N lines, print line N
next_line() {
  local f="$1" n="$2" secs="${3:-10}" i
  for (( i = 0; i < secs * 20; i++ )); do
    if [ "$(nlines "$f")" -ge "$n" ]; then sed -n "${n}p" "$f"; return 0; fi
    sleep 0.05
  done
  echo "<nothing arrived>"
}

shimdir="$TMPD/atshim"; mkdir -p "$shimdir"
cat > "$shimdir/at" <<'SHIM'
#!/bin/sh
# stands in for at(1): keeps the job body, queues nothing
case " $* " in *' -q '*) ;; *) echo "shim: Garbled time" >&2; exit 1 ;; esac
cat > "$IMUX_AT_BODY"
echo "job 4242 at Thu Jan  1 00:00:00 2099" >&2
SHIM
chmod +x "$shimdir/at"
if [ "$(PATH="$shimdir:$PATH" command -v at)" != "$shimdir/at" ]; then
  # never let a real at run: nothing below is safe without the shim
  report "the at shim is the at that runs (else a real job would be queued)" fail
  echo; echo "Results: $PASS passed, $FAIL failed"; printf '%s' "$ERRORS"; exit 1
fi

# submit TARGET TEXT -- --send-at through the shim; the body lands in
# $TMPD/body, the exit status in RC and stderr in ERR
submit() {
  rm -f "$TMPD/body"
  PATH="$shimdir:$PATH" IMUX_AT_BODY="$TMPD/body" \
    bash "$SCRIPT" --send-at 'now + 1 hour' "$1" "$2" >/dev/null 2>"$TMPD/err"
  RC=$?
  ERR=$(cat "$TMPD/err")
}
# fire -- run the body as atd would, under /bin/sh; its status in FIRE_RC
fire() {
  ( cd "$TMPD/run" && /bin/sh "$TMPD/body" ) >/dev/null 2>&1
  FIRE_RC=$?
}

# --- a session name is never code in the body ---------------------------------------
# Every way out of a double-quoted string at once: a '"' that closes it, a
# backtick and a $(...) that run inside it, and a backslash dash's echo reads as
# an escape.  Relative paths: the body runs in $TMPD/run.
T rename-session -t '=jb' 'q"; touch INJ1; echo "`touch INJ2`$(touch INJ3)\c'
NAME=$(T display-message -p -t "$P0" '#{session_name}')
submit "$P0" 'echo NAMED'
if [ ! -s "$TMPD/body" ]; then
  report "a session with a hostile name can be scheduled into (precondition)" fail
  ERRORS+="    rc=$RC: $ERR"$'\n'
else
  n=$(( $(nlines "$TMPD/caught") + 1 ))
  fire
  injected=$(cd "$TMPD/run" && find . -name 'INJ*' | sort | tr '\n' ' ')
  expect "nothing in the session name runs when the job fires" "$injected" ""
  expect "...and the job still sends its keys" "$(next_line "$TMPD/caught" "$n")" 'echo NAMED'
  logl=$(tail -n 1 "$XDG_STATE_HOME/interdimux/scheduled.log" 2>/dev/null)
  # "== YYYY-MM-DD HH:MM:SS " and then the name exactly as tmux has it
  if [[ "$logl" =~ ^==\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ (.*)$ ]]; then
    logl="${BASH_REMATCH[1]}"
  fi
  expect "...and its log line names the session verbatim" "$logl" "firing for $NAME:0.0 ($P0)"
fi
# a lone '"' left the body unparseable: the job died with a syntax error
T rename-session -t "=$NAME" 'it"s'
submit "$P0" 'echo QUOTED'
if [ ! -s "$TMPD/body" ]; then
  report "a session named it\"s can be scheduled into (precondition)" fail
else
  if sh -n "$TMPD/body" 2>/dev/null; then
    report "the body parses as POSIX sh with a lone '\"' in the session name" pass
  else
    report "the body parses as POSIX sh with a lone '\"' in the session name" fail
  fi
  n=$(( $(nlines "$TMPD/caught") + 1 ))
  fire
  expect "...and that job sends its keys" "$(next_line "$TMPD/caught" "$n")" 'echo QUOTED'
fi
T rename-session -t '=it"s' jb

# an ordinary name: the same log line as ever
submit "$P0" 'echo PLAIN'
n=$(( $(nlines "$TMPD/caught") + 1 ))
[ -s "$TMPD/body" ] && fire
expect "an ordinary job sends its keys" "$(next_line "$TMPD/caught" "$n")" 'echo PLAIN'
logl=$(tail -n 1 "$XDG_STATE_HOME/interdimux/scheduled.log" 2>/dev/null)
logl="${logl#== ????-??-?? ??:??:?? }"
expect "...and logs 'firing for jb:0.0 ($P0)'" "$logl" "firing for jb:0.0 ($P0)"

# --- a log that cannot be written does not stop the send -----------------------------
# The state dir is baked in at submit time; here its parent is a FILE, so at
# firing time neither mkdir -p nor the append can succeed.
: > "$TMPD/blocked"
XDG_STATE_HOME="$TMPD/blocked/state" submit "$P0" 'echo UNLOGGED'
if [ ! -s "$TMPD/body" ]; then
  report "a job can be scheduled with an unwritable state dir (precondition)" fail
  ERRORS+="    rc=$RC: $ERR"$'\n'
else
  n=$(( $(nlines "$TMPD/caught") + 1 ))
  fire
  expect "with its log dir unwritable at firing time, the job still sends its keys" \
    "$(next_line "$TMPD/caught" "$n")" 'echo UNLOGGED'
  expect "...and exits 0" "$FIRE_RC" 0
fi
# The dir is there but the log will not open (here it is a directory): the
# probe itself must not be what ends the job.
mkdir -p "$TMPD/state2/interdimux/scheduled.log"
XDG_STATE_HOME="$TMPD/state2" submit "$P0" 'echo UNOPENED'
if [ -s "$TMPD/body" ]; then
  n=$(( $(nlines "$TMPD/caught") + 1 ))
  fire
  expect "with a log that will not open, the job still sends its keys" \
    "$(next_line "$TMPD/caught" "$n")" 'echo UNOPENED'
else
  report "a job can be scheduled with an unopenable log (precondition)" fail
fi

# --- '.' is the caller's pane, or nothing -------------------------------------------
rm -f "$TMPD/body"
env -u TMUX_PANE PATH="$shimdir:$PATH" IMUX_AT_BODY="$TMPD/body" \
  bash "$SCRIPT" --send-at 'now + 1 hour' . 'echo DOT_AT' >/dev/null 2>"$TMPD/err"
RC=$?
if [ "$RC" != 0 ] && grep -q 'TMUX_PANE' "$TMPD/err"; then
  report "--send-at '.' without TMUX_PANE is refused, naming TMUX_PANE" pass
else
  report "--send-at '.' without TMUX_PANE is refused, naming TMUX_PANE" fail
  ERRORS+="    rc=$RC: $(cat "$TMPD/err")"$'\n'
fi
[ -e "$TMPD/body" ] && report "...and nothing is handed to at" fail \
                     || report "...and nothing is handed to at" pass

# The sub-minute path is a tmux timer.  Nothing may be scheduled: a sentinel
# timer set AFTER it with the same delay fires after it, so once the sentinel
# has arrived, a refused send that slipped through would already be there.
env -u TMUX_PANE bash "$SCRIPT" --send-in 1 . 'echo DOT_IN' >/dev/null 2>"$TMPD/err"
RC=$?
if [ "$RC" != 0 ] && grep -q 'TMUX_PANE' "$TMPD/err"; then
  report "--send-in '.' without TMUX_PANE is refused, naming TMUX_PANE" pass
else
  report "--send-in '.' without TMUX_PANE is refused, naming TMUX_PANE" fail
  ERRORS+="    rc=$RC: $(cat "$TMPD/err")"$'\n'
fi
n=$(( $(nlines "$TMPD/caught") + 1 ))
bash "$SCRIPT" --send-in 1 "$P0" 'echo DOT_SENTINEL' >/dev/null 2>&1
expect "...and nothing reaches a pane tmux picked instead" "$(next_line "$TMPD/caught" "$n")" 'echo DOT_SENTINEL'

# ...while '.' from inside a pane is still that pane
submit . 'echo DOT_OK'
expect "'.' with TMUX_PANE set still schedules into that pane" \
  "$(sed -n 's/^# imux-pane: //p' "$TMPD/body" 2>/dev/null)" "$P0"

# sched_resolve's own guard, beneath the CLI's: no caller hands it an empty
# target today, but tmux reads -t '' exactly as no -t, so that guard is all
# that keeps the next caller from scheduling into tmux's pick.  The function is
# taken from the script and called directly, outside any pane.
fn=$(sed -n '/^sched_resolve() {$/,/^}$/p' "$SCRIPT")
# resolve TARGET -> "refused", or the pane it resolved to
resolve() (
  unset TMUX_PANE; US=$'\x1f'; eval "$fn"
  if sched_resolve "$1"; then echo "$SCHED_PANE"; else echo refused; fi
)
expect "sched_resolve, taken from the script, resolves a named pane (precondition)" \
  "$(resolve "$P0")" "$P0"
expect "sched_resolve refuses an empty target" "$(resolve '')" refused
expect "sched_resolve refuses '.' outside a pane" "$(resolve .)" refused

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
exit 0
