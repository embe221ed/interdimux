#!/usr/bin/env bash
# Real scheduler CLI entry points, with every at command confined to fixtures.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=${IMUX_SCHEDULE_SCRIPT:-$root/scripts/interdimux.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/interdimux-schedule-ownership.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/bodies" "$work/state" "$work/config" "$work/data"
export XDG_STATE_HOME="$work/state" XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data"
export IMUX_SCHEDULE_FIXTURE="$work" INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_USE_RUST=off
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export TMUX="$work/socket,123,0" TMUX_PANE=%7
unset INTERDIMUX_ERR_FILE

cat > "$work/bin/atq" <<'SHIM'
#!/bin/sh
if [ "${IMUX_ATQ_FAIL:-0}" != 0 ]; then
  cat "$IMUX_SCHEDULE_FIXTURE/queue"
  echo 'fixture queue unavailable' >&2
  exit 1
fi
[ "${IMUX_ATQ_BSD:-0}" = 0 ] || [ "${3:-}" != -o ] || exit 1
while IFS= read -r id; do
  [ -n "$id" ] && printf '%s\t2026-11-09 12:00 i fixture\n' "$id"
done < "$IMUX_SCHEDULE_FIXTURE/queue"
SHIM
cat > "$work/bin/at" <<'SHIM'
#!/bin/sh
if [ "${1:-}" = -c ]; then
  cat "$IMUX_SCHEDULE_FIXTURE/bodies/$2" || exit 1
  [ "${IMUX_AT_READ_FAIL:-}" != "$2" ]
else
  cat > "$IMUX_SCHEDULE_FIXTURE/submitted"
  printf 'job 1000 at Mon Nov 9 12:00:00 2026\n' >&2
fi
SHIM
cat > "$work/bin/atrm" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$IMUX_SCHEDULE_FIXTURE/removals"
if [ "${IMUX_AT_REMOVE_FAIL:-0}" != 0 ]; then
  echo 'fixture removal denied' >&2
  exit 7
fi
awk -v wanted="$1" '$0 != wanted' "$IMUX_SCHEDULE_FIXTURE/queue" > "$IMUX_SCHEDULE_FIXTURE/queue.next"
mv "$IMUX_SCHEDULE_FIXTURE/queue.next" "$IMUX_SCHEDULE_FIXTURE/queue"
SHIM
cat > "$work/bin/tmux" <<'SHIM'
#!/bin/sh
if [ "${1:-}" = -S ]; then
  shift 2
  if [ "${1:-}" = display-message ]; then printf '123\n'; exit 0; fi
  while [ $# -gt 0 ]; do
    if [ "$1" = -l ] && [ "${2:-}" = -- ]; then
      printf '%s' "$3" > "$IMUX_SCHEDULE_FIXTURE/delivered"
      exit 0
    fi
    shift
  done
elif [ "${1:-}" = display-message ] && [ -f "$IMUX_SCHEDULE_FIXTURE/resolve" ]; then
  cat "$IMUX_SCHEDULE_FIXTURE/resolve"
  exit 0
fi
echo 'unexpected tmux call in scheduler ownership fixture' >&2
exit 1
SHIM
chmod +x "$work/bin/atq" "$work/bin/at" "$work/bin/atrm" "$work/bin/tmux"
export PATH="$work/bin:$PATH"

valid_body() {
  printf '%s\n' '#!/bin/sh' 'fixture_env="ignored"' \
    '# imux:v1 interdimux scheduled keys' '# imux-pane: %7' \
    '# imux-target: project with desc= space:0.0' '# imux-desc: echo KEEP; $HOME' \
    '# the generated job continues here' 'echo never-executed'
}
valid_body > "$work/bodies/100"
printf '%s\n' '#!/bin/sh' 'echo unrelated job' > "$work/bodies/200"
valid_body | sed '/^# imux-desc:/d' > "$work/bodies/300"
valid_body | sed 's/^# imux-pane:.*/# imux-pane: %oops/' > "$work/bodies/400"
valid_body | sed 's/^# imux:v1.*/# imux:v1 unrelated producer/' > "$work/bodies/500"
valid_body | sed '/^# imux-pane:/d' > "$work/bodies/600"
valid_body | sed '/^# imux-pane:/a\
# imux-pane: %8
' > "$work/bodies/700"
{
  printf '%s\n' '# imux-pane: %999' '# imux-target: ENVIRONMENT_FORGERY'
  valid_body
} > "$work/bodies/800"
valid_body | sed 's/^# imux-target:.*/# imux-target: /' > "$work/bodies/900"
valid_body | sed 's/^# imux-desc:.*/# imux-desc: /' > "$work/bodies/901"
# Replace the actual target line with a framing character, not a later comment.
awk 'BEGIN {US=sprintf("%c",31)} /^# imux-target:/ {print "# imux-target: bad" US "record"; next} {print}' \
  "$work/bodies/100" > "$work/bodies/902"
valid_body > "$work/bodies/903"
printf '%s\n' 100 200 300 400 500 600 700 800 900 901 902 903 > "$work/queue"
: > "$work/removals"
export IMUX_AT_READ_FAIL=903

passed=0 failed=0
check() {
  local label=$1; shift
  if "$@"; then
    passed=$((passed + 1)); printf '  passed: %s\n' "$label"
  else
    failed=$((failed + 1)); printf '  FAILED: %s\n' "$label" >&2
  fi
}
has_line() { [[ $1 == *"$2"* ]]; }
lacks_line() { [[ $1 != *"$2"* ]]; }
run_cli() {
  status=0
  output=$(bash "$script" "$@" 2>&1) || status=$?
}

run_cli --sched-list
listing=$output
check 'owned job remains listable with literal spaced metadata' has_line "$output" 'project with desc= space:0.0'
check 'owned description remains literal' has_line "$output" 'echo KEEP; $HOME'
check 'environment metadata before the marker is ignored' lacks_line "$output" ENVIRONMENT_FORGERY
for id in 200 300 400 500 600 700 900 901 903; do
  check "unrelated or malformed job $id stays out of listing" lacks_line "$listing" "$id "
  run_cli --sched-cancel "$id"
  check "cancellation refuses unverified job $id" test "$status" -ne 0
done
check 'unverified cancellation never invokes atrm' test ! -s "$work/removals"
check 'older owned metadata with US stays visible as a safe escape' has_line "$listing" 'bad\x1frecord'

for id in '-f' '.*' '../100' '100 800'; do
  run_cli --sched-cancel "$id"
  check "invalid ID $id is refused before removal" test "$status" -ne 0
done
check 'invalid IDs never invoke atrm' test ! -s "$work/removals"

export IMUX_AT_REMOVE_FAIL=1
run_cli --sched-cancel 100
check 'atrm failure is returned to caller' test "$status" -eq 7
check 'atrm failure has a useful diagnostic' has_line "$output" 'fixture removal denied'
check 'failed removal never claims cancellation' lacks_line "$output" 'cancelled job'
run_cli --sched-list
check 'failed cancellation leaves the owned job visible' has_line "$output" '100 '
unset IMUX_AT_REMOVE_FAIL

run_cli --sched-cancel 800
check 'verified cancellation succeeds' test "$status" -eq 0
check 'verified cancellation is reported only after removal' has_line "$output" 'cancelled job 800'
run_cli --sched-list
check 'successfully removed job leaves the list' lacks_line "$output" '800 '
check 'other valid jobs survive cancellation' has_line "$output" '100 '
run_cli --sched-cancel 902
check 'older owned job with raw US metadata remains cancellable' test "$status" -eq 0

export IMUX_ATQ_BSD=1
run_cli --sched-list
check 'BSD queue fallback still validates and lists owned jobs' has_line "$output" '100 '
check 'BSD queue fallback excludes unrelated jobs' lacks_line "$output" '200 '
unset IMUX_ATQ_BSD

before=$(cat "$work/removals")
export IMUX_ATQ_FAIL=1
run_cli --sched-cancel 100
check 'unavailable queue cannot authorize cancellation' test "$status" -ne 0
after=$(cat "$work/removals")
check 'queue failure never invokes atrm' test "$before" = "$after"
unset IMUX_ATQ_FAIL

printf '%s\n' 200 > "$work/queue"
run_cli --sched-list
check 'a queue containing only unrelated jobs reports none' has_line "$output" 'no scheduled keys'
check 'an unrelated-only queue does not expose its job' lacks_line "$output" '200 '

# Drive the actual producer as well: display metadata may escape control bytes,
# but the generated POSIX job must still deliver the original command verbatim.
label=$'project\rname\037desc=:0.0'
keys=$'printf first\nsecond\r\037tail'
printf '%%7\037%s\037123\037%s\n' "$work/socket" "$label" > "$work/resolve"
export INTERDIMUX_AT_DAEMON=unknown
run_cli --send-at 'now + 1 hour' '%7' "$keys"
check 'producer accepts literal control characters in scheduled text' test "$status" -eq 0
cp "$work/submitted" "$work/bodies/1000"
printf '%s\n' 1000 > "$work/queue"
run_cli --sched-list
check 'new owned control-character metadata stays visible' has_line "$output" '1000 '
check 'producer escapes CR/US in the displayed target' has_line "$output" 'project\rname\x1fdesc=:0.0'
check 'producer keeps the displayed command on one line' has_line "$output" 'printf first second\r\x1ftail'
check 'metadata contains no raw field separator' lacks_line "$output" $'\037'
check 'metadata contains no raw carriage return' lacks_line "$output" $'\r'
status=0
/bin/sh "$work/submitted" || status=$?
check 'generated POSIX job executes successfully against the fixture' test "$status" -eq 0
delivered=$(cat "$work/delivered")
check 'display escaping leaves the actual scheduled payload unchanged' test "$delivered" = "$keys"
run_cli --sched-cancel 1000
check 'new control-character job remains cancellable' test "$status" -eq 0

printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
