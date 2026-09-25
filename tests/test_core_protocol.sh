#!/usr/bin/env bash
#
# A Rust core from another version of interdimux is refused, not trusted.
#
# The script hands the binary its sections on stdin, and the binary reads
# fields by position.  Nothing rebuilds the binary when the script changes -- not
# TPM's update, not a `git pull`, and never an INTERDIMUX_BIN installed
# elsewhere -- so a binary older than the script is routine.  When the session
# name moved from the second field to the first, a binary built before that read
# the timestamp as the name: every session drawn as `S:1790254646`, no window or
# pane (they are grouped by the real name), and exit 0, so that WAS the picker.
#
# The subcommand is now the protocol's version (IMUX_PROTO / PROTOCOL, `gather3`)
# and an old binary exits 2 on a name it does not know.  Checked here with a
# stand-in for such a binary -- one that knows only `gather` and reads the name
# from field 2, as the old parser did:
#   * the list is the bash renderer's, with nothing on stderr (the old binary's
#     usage line would otherwise land in errors.log on every open)
#   * the user is told ONCE, on the status line and in errors.log (which --doctor
#     reports), which binary it is and how to rebuild it; again only after a
#     rebuild that is still the wrong version
#   * not while interdimux.tmux's background build is replacing that binary --
#     but a lock whose PID now belongs to some other process is no build
#   * never for a current binary
# The binary's own side (it refuses `gather`) is rust/tests/protocol.rs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-proto-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-proto.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""
HOLDER=""

cleanup() {
  [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null
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
check() { if eval "$2"; then report "$1" pass; else report "$1" fail; fi; }

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

echo "interdimux Rust-core protocol tests"
echo

export LC_ALL=C.UTF-8 LANG=C.UTF-8
unset INTERDIMUX_BIN

# --- the bench: the finding's own layout ---------------------------------------
mkdir -p "$TMPD/home" "$TMPD/data"
PANECMD='sleep 99999'
tmux -f /dev/null -L "$SOCK" new-session -d -s api -x 200 -y 50 -c "$TMPD/home" "$PANECMD"
tmux -L "$SOCK" new-session -d -s eps -x 200 -y 50 -c "$TMPD/home" "$PANECMD"
tmux -L "$SOCK" new-window -d -t '=eps:' -c "$TMPD/home" "$PANECMD"
tmux -L "$SOCK" new-session -d -s my-project -x 200 -y 50 -c "$TMPD/home" "$PANECMD"
tmux -L "$SOCK" split-window -d -t '=my-project:0' -c "$TMPD/home" "$PANECMD"
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=api:0' -F '#{pane_id}' | head -1)"
export HOME="$TMPD/home" XDG_DATA_HOME="$TMPD/data"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_SHOW_DIRS=off INTERDIMUX_USE_ZOXIDE=off
wait_for "the bench panes" sh -c "[ \"\$(tmux -L '$SOCK' list-panes -a | wc -l)\" -ge 5 ]"

# --- a binary built before the session name moved to the front ----------------
# It knows one subcommand, `gather`, takes the session name from field 2 -- the
# old `f.get(1)` -- and prints what the old binary printed for that input:
# one row per session, named by the timestamp, and no windows.  Anything else
# gets the old usage line and exit 2.
make_old() { # $1 = where
  mkdir -p "${1%/*}"
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "imux 0.1.0" ;;
  gather)
    all=$(cat); sessions=${all%%$'\x1e'*}
    while IFS=$'\x1f' read -r _ name _; do
      [ -n "$name" ] && printf ' ▸ %s\t1 win\t\tS:%s\n' "$name" "$name"
    done <<< "$sessions"
    exit 0 ;;   # exit 0, as it did: nothing about this output looked like a failure
  *) echo "imux: usage: imux gather" >&2; exit 2 ;;
esac
EOF
  chmod +x "$1"
}
OLD="$TMPD/elsewhere/imux"
make_old "$OLD"

specs() { printf '%s\n' "$1" | awk -F'\t' 'NF { print $NF }' | tr '\n' ' '; }
# entries in an errors.log: one "== " header each
entries() { if [ -f "$1" ]; then grep -c '^== ' "$1" || true; else echo 0; fi; }

WANT=$(specs "$(INTERDIMUX_USE_RUST=off bash "$SCRIPT" --list 2>/dev/null)")
case "$WANT" in
  *"W:eps:1"*"P:my-project:0:1"*) report "control: the bash renderer lists every window and pane" pass ;;
  *) report "control: the bash renderer lists every window and pane (got: $WANT)" fail ;;
esac

# $1 = the XDG_STATE_HOME, rest = extra env; run --list from a pane of another
# server, because tmux logs a display-message only from a client with a
# terminal.  Sets GOT (the spec column) and ERR (its stderr).
list_in_pane() {
  local state="$1"; shift
  local n=$((${LISTN:-0} + 1)); LISTN=$n
  tmux -f /dev/null -L "$OUTER" new-session -d -s "r$n" -x 120 -y 30 \
    "env TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' XDG_STATE_HOME='$state' $* \
         bash '$SCRIPT' --list > '$TMPD/out$n' 2> '$TMPD/err$n'; echo \$? > '$TMPD/rc$n'; sleep 60"
  wait_for "run $n of --list" test -s "$TMPD/rc$n" || true
  GOT=$(specs "$(cat "$TMPD/out$n")")
  ERR=$(cat "$TMPD/err$n")
}
# the display-messages the inner server logged that name the binary $1
notices() {
  tmux -L "$SOCK" show-messages 2>/dev/null | grep -F 'command: display-message' \
    | grep -F -- "$1" | grep -c 'does not speak gather3' || true
}

# --- 1. a binary installed elsewhere (INTERDIMUX_BIN) ---------------------------
ST="$TMPD/state1"
LOG="$ST/interdimux/errors.log"
list_in_pane "$ST" INTERDIMUX_USE_RUST=on "INTERDIMUX_BIN='$OLD'"
check "an old binary: the list is the bash renderer's, every window and pane" '[ "$GOT" = "$WANT" ]'
[ "$GOT" = "$WANT" ] || ERRORS+="     got:  $GOT"$'\n'"     want: $WANT"$'\n'
check "...with no session named by its timestamp" '! [[ "$GOT" =~ S:[0-9]{9,} ]]'
check "...and nothing on stderr (the old usage line, on every open)" '[ -z "$ERR" ]'
[ -z "$ERR" ] || ERRORS+="     stderr: $ERR"$'\n'
check "...said on the status line, naming the binary" '[ "$(notices "$OLD")" = 1 ]'
check "...and in errors.log, once, naming the binary" \
  '[ "$(entries "$LOG")" = 1 ] && grep -qF "the Rust core at $OLD " "$LOG" 2>/dev/null'
check "...with what to do about it" 'grep -qF "point INTERDIMUX_BIN at a build of this version" "$LOG" 2>/dev/null'

# every later list -- the next open, each reload -- says nothing more
list_in_pane "$ST" INTERDIMUX_USE_RUST=on "INTERDIMUX_BIN='$OLD'"
list_in_pane "$ST" INTERDIMUX_USE_RUST=on "INTERDIMUX_BIN='$OLD'"
check "the next lists still fall back" '[ "$GOT" = "$WANT" ]'
check "...and say nothing more: one status-line message" '[ "$(notices "$OLD")" = 1 ]'
check "...and one errors.log entry" '[ "$(entries "$LOG")" = 1 ]'

# a rebuild that is STILL the wrong version is news again: the binary is newer
# than the note that was taken of it
touch -d '-1 minute' "$ST/interdimux/imux-refused" 2>/dev/null || true
touch "$OLD"
list_in_pane "$ST" INTERDIMUX_USE_RUST=on "INTERDIMUX_BIN='$OLD'"
check "a rebuilt binary that is still the wrong version is reported again" \
  '[ "$(entries "$LOG")" = 2 ] && [ "$(notices "$OLD")" = 2 ]'

# --- 2. the in-repo binary, and the plugin's own background build --------------
# A copy of the plugin, so the in-repo path and the build lock are this test's.
PLUG="$TMPD/plugin"
mkdir -p "$PLUG/scripts"
cp "$SCRIPT" "$PLUG/scripts/"
make_old "$PLUG/rust/target/release/imux"
LOCK="$PLUG/rust/target/.interdimux-autobuild.lock"
ST="$TMPD/state2"
LOG="$ST/interdimux/errors.log"
SCRIPT_SAVED="$SCRIPT"; SCRIPT="$PLUG/scripts/interdimux.sh"

# interdimux.tmux is rebuilding it right now (the lock names a running build
# job): that job announces its own result, so this says nothing.  The job is a
# stand-in, run as the real one is -- this plugin's interdimux.tmux --autobuild.
cat > "$PLUG/interdimux.tmux" <<'EOF'
trap 'kill "$!" 2>/dev/null; exit 0' TERM
sleep 600 & wait
EOF
bash "$PLUG/interdimux.tmux" --autobuild & HOLDER=$!
wait_for "the stand-in build job" sh -c "ps -o args= -p '$HOLDER' | grep -q -- --autobuild"
ln -s "$HOLDER" "$LOCK"
list_in_pane "$ST" INTERDIMUX_USE_RUST=on
check "during the background build: the list falls back" '[ "$GOT" = "$WANT" ]'
check "...and nothing is said, or noted" \
  '[ "$(entries "$LOG")" = 0 ] && [ ! -e "$ST/interdimux/imux-refused" ] && [ "$(notices "$PLUG/rust")" = 0 ]'

# the build is gone (its owner died with it) and the binary is still old
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null || true; HOLDER=""
list_in_pane "$ST" INTERDIMUX_USE_RUST=on
check "with no build under way: said once, with the command that rebuilds it" \
  '[ "$(entries "$LOG")" = 1 ] && grep -qF "(cd '"'"'$PLUG/rust'"'"' && cargo build --release)" "$LOG" 2>/dev/null'
check "...on the status line too" '[ "$(notices "$PLUG/rust/target/release/imux")" = 1 ]'

# The lock names a live process, but not a build job: one killed before it could
# remove its lock (SIGKILL, the OOM killer, a power cut), and its PID reused.
# Nothing is replacing the binary, so this is said as well.
ST="$TMPD/state2b"
LOG="$ST/interdimux/errors.log"
sleep 600 & HOLDER=$!
rm -f "$LOCK"; ln -s "$HOLDER" "$LOCK"
list_in_pane "$ST" INTERDIMUX_USE_RUST=on
check "a lock whose PID is some other process now: said all the same" \
  '[ "$(entries "$LOG")" = 1 ] && [ "$(notices "$PLUG/rust/target/release/imux")" = 2 ]'
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null || true; HOLDER=""
SCRIPT="$SCRIPT_SAVED"

# --- 3. a current binary is not refused ----------------------------------------
if [ -x "$BIN" ]; then
  ST="$TMPD/state3"
  list_in_pane "$ST" INTERDIMUX_USE_RUST=on
  check "the real binary: the same list" '[ "$GOT" = "$WANT" ]'
  check "...with nothing said, or noted" \
    '[ "$(entries "$ST/interdimux/errors.log")" = 0 ] && [ ! -e "$ST/interdimux/imux-refused" ] && [ -z "$ERR" ]'
else
  echo "  (skipped the current-binary case: $BIN not built)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  printf '%s' "$ERRORS"
  exit 1
fi
