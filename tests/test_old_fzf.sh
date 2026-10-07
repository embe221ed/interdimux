#!/usr/bin/env bash
#
# Old fzf: the navigator must open, and DRAW, on the releases below 0.74 that
# the preflight admits.  README promises "older versions still open a working
# picker"; this is the only suite that runs one.
#
# Two ways it used not to, both invisible to every suite pinned to 0.74:
#
#   0.40-0.45  the `resize` event arrived in fzf 0.46, and fzf REFUSES TO START
#              on an event it does not know.  The bind was unconditional, so
#              prefix+f opened a popup that closed at once, leaving
#              "unsupported key: resize" in errors.log.  Ubuntu 24.04 ships
#              0.44.1.
#   0.46-0.52  fzf draws its whole interface on STDERR before 0.53, and the
#              navigator sends its stderr to a log.  The popup stayed black,
#              Esc still quit, and errors.log filled with the rendered frames.
#              ctrl-o's directory picker, an execute() child, inherits the same
#              stderr and was just as invisible.
#
# These need REAL release binaries; an INTERDIMUX_FZF_MINOR on a modern fzf
# cannot reproduce either failure.  Point INTERDIMUX_OLD_FZF_DIR at a directory
# holding <version>/fzf (CI fetches them; see docs/CI.md), e.g.
#
#   for v in 0.40.0 0.44.1 0.52.1; do mkdir -p "$d/$v"; curl -fsSL \
#     "https://github.com/junegunn/fzf/releases/download/$v/fzf-$v-linux_amd64.tar.gz" \
#     | tar -xz -C "$d/$v"; done
#
# (no `v` in the tag: fzf's tags gained it at 0.54.0, and .../download/v0.44.1/
# is a 404).
#
# With INTERDIMUX_OLD_FZF_DIR set, a version that is not there FAILS, by name:
# this list is the one CI must supply (OLD_FZF_VERSIONS in dev/versions.env),
# and a skip there would read as a pass in every total.  Unset, a local run
# without the binaries, each one is reported as skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-oldfzf-test-$$"
OUTER="" OUTERS=()   # a fresh outer server per launch, see new_outer
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-oldfzf.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  local o
  for o in ${OUTERS[@]+"${OUTERS[@]}"}; do tmux -L "$o" kill-server 2>/dev/null || true; done
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$TMPD"
}
trap cleanup EXIT

# Each launch gets a NEW outer server rather than killing and re-creating one
# on the same socket: under load the old server can still be shutting down when
# the next new-session connects, and that failure takes the suite down.
new_outer() {
  [ -n "$OUTER" ] && tmux -L "$OUTER" kill-server 2>/dev/null || true
  OUTER="${SOCK}-o$(( ${#OUTERS[@]} + 1 ))"
  OUTERS+=("$OUTER")
}

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

echo "interdimux old-fzf tests"
echo

# The README's floor, and the only release under test on the `fzf_ge 42` false
# branch (plain `--info=inline`; 0.41 is on it too); one below the `resize`
# floor (and what Ubuntu 24.04 ships); and the last release that draws on
# stderr.
VERSIONS=(0.40.0 0.44.1 0.52.1)
OLD_DIR="${INTERDIMUX_OLD_FZF_DIR:-}"
have=()
for v in "${VERSIONS[@]}"; do
  bin="$OLD_DIR/$v/fzf"
  if [ -n "$OLD_DIR" ] && [ -x "$bin" ] && [ "$("$bin" --version 2>/dev/null | awk '{print $1}')" = "$v" ]; then
    have+=("$v")
  elif [ -n "$OLD_DIR" ]; then
    report "fzf $v is in \$INTERDIMUX_OLD_FZF_DIR (no $OLD_DIR/$v/fzf of that version)" fail
  else
    echo "  (skipped fzf $v: no $v/fzf under INTERDIMUX_OLD_FZF_DIR='${OLD_DIR}')"
  fi
done
if [ "${#have[@]}" -eq 0 ]; then
  echo; echo "Results: $PASS passed, $FAIL failed"
  if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
  exit 0
fi

mkdir -p "$TMPD/cwd" "$TMPD/home"
tmux -f /dev/null -L "$SOCK" new-session -d -s alpha -x 120 -y 24 -c "$TMPD/cwd" 'sleep 3600'
tmux -L "$SOCK" new-session -d -s gamma -x 120 -y 24 -c "$TMPD/cwd" 'sleep 3600'
INNER_TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
INNER_PANE="$(tmux -L "$SOCK" list-panes -t '=alpha:0' -F '#{pane_id}' | head -1)"

screen() { tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | plain || true; }
keys()   { tmux -L "$OUTER" send-keys -t '=drv:' "$@"; }
wait_text() { # $1 = fixed string; $2 = tenths of a second (default 100)
  local i
  for i in $(seq 1 "${2:-100}"); do
    screen | grep -qF -- "$1" && return 0
    sleep 0.1
  done
  return 1
}

launch_old() { # $1 = version; resets the exit sentinel and the log
  local v="$1" sh="$TMPD/launch-$1.sh"
  state="$TMPD/state-$v" exited="$TMPD/exited-$v"
  rm -rf "$state" "$exited"; mkdir -p "$state"
  # No INTERDIMUX_FZF_MINOR: the script must probe the fzf it is handed, which
  # is the whole point.  The sentinel marks the navigator's exit -- after its
  # EXIT trap has flushed anything it logged.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export PATH=%q:"$PATH"\n' "$OLD_DIR/$v"
    printf 'export TMUX=%q TMUX_PANE=%q HOME=%q XDG_STATE_HOME=%q\n' \
      "$INNER_TMUX" "$INNER_PANE" "$TMPD/home" "$state"
    printf 'export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_TMUX_VNUM=307 FZF_DEFAULT_OPTS=\n'
    printf 'export INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_SHOW_DIRS=off INTERDIMUX_SHOW_PREVIEW=off\n'
    printf 'unset INTERDIMUX_FZF_MINOR\n'
    printf 'bash %q\n' "$SCRIPT"
    printf 'printf done > %q\n' "$exited"
  } > "$sh"
  chmod +x "$sh"
  new_outer
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 120 -y 24 "$sh; sleep 60"
}
wait_exit() {
  local i
  for i in $(seq 1 100); do [ -e "$exited" ] && return 0; sleep 0.1; done
  return 1
}

for v in "${have[@]}"; do
  launch_old "$v"
  if wait_text '▸ gamma' 150; then
    report "fzf $v: the navigator opens and draws its rows" pass
  else
    report "fzf $v: the navigator opens and draws its rows" fail
    [ -e "$exited" ] && ERRORS+="    it exited at once"$'\n'
  fi
  if screen | grep -qF 'enter switch'; then
    report "fzf $v: ...and its hint bar" pass
  else
    report "fzf $v: ...and its hint bar" fail
  fi
  # Quit, and only then read the log: it is written by the EXIT trap.
  [ -e "$exited" ] || keys Escape
  if wait_exit; then
    log="$state/interdimux/errors.log"
    if [ -s "$log" ] && grep -qE '▸|enter switch|unsupported key' "$log"; then
      report "fzf $v: errors.log holds no rendered frames or startup errors" fail
      ERRORS+="    $(head -c 160 "$log" | tr '\n\033' '|^')"$'\n'
    else
      report "fzf $v: errors.log holds no rendered frames or startup errors" pass
    fi
  else
    report "fzf $v: Esc quits the navigator" fail
  fi

  # ctrl-o runs the directory picker as an execute() child: on these releases
  # it draws on the stderr it inherits.  Its bar is the marker, not its prompt,
  # which becomes "∅ nothing matched" once the (empty, here) list is searched.
  launch_old "$v"
  wait_text '▸ gamma' 150 || true
  keys C-o
  if wait_text 'deep search'; then
    report "fzf $v: ctrl-o's directory picker draws" pass
    # ...and cancelling it reopens the navigator, drawn again.
    keys Escape
    for _i in $(seq 1 100); do
      screen | grep -qF 'deep search' || break
      sleep 0.1
    done
    if wait_text '▸ gamma'; then
      report "fzf $v: cancelling it brings the navigator back" pass
    else
      report "fzf $v: cancelling it brings the navigator back" fail
    fi
  else
    report "fzf $v: ctrl-o's directory picker draws" fail
  fi
done
tmux -L "$OUTER" kill-server 2>/dev/null || true

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
