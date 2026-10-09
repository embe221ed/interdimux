#!/usr/bin/env bash
#
# --list draws its rows ahead of the rest of the file (review PERF-17): it
# sources interdimux-list.sh right after the options, and with the Rust core
# that file is all it runs.  Only when the core does not draw the rows --
# refusing the protocol (exit 2), failing, or printing something that is not
# a row list -- is the rest of the file parsed, down to --list's own dispatch,
# whose bash renderer draws what the fast path fetched.  What must hold, on a
# private server:
#
#   * the rows are the full path's, byte for byte: the bash renderer's
#     (INTERDIMUX_USE_RUST=off: every row drawn by the full file), and the
#     core's as the navigator's loop gathers them (the full gather_targets)
#     -- with @interdimux-hide too, matching a session and matching none
#   * a list asks tmux once and runs the core once
#   * a core that refuses: the bash renderer's rows, tmux asked once, the core
#     run once, the refusal said once (errors.log and the status line)
#   * a core that fails, or prints what is not a row list: the bash
#     renderer's rows, tmux asked once, the core run once, nothing said
#   * the fast path parses neither the renderer nor a callback; the fall-through
#     does parse the renderer (bash -v echoes what bash reads)
#   * through a symlink to the script (absolute, relative, a link to a link),
#     the files it sources are found beside the script itself: the same rows,
#     and an argument no mode takes is still refused by name
#
# tmux and the core are stand-ins in front of the real ones that log each run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-listfast-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-listfast.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

SOCK_PATH=""
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -f ${SOCK_PATH:+"$SOCK_PATH"}
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

echo "interdimux --list fast-path tests"
echo

if [ ! -x "$BIN" ]; then
  echo "  (skipped: the Rust core is not built, and the fast path is the core's)"
  echo
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

mkdir -p "$TMPD/bin" "$TMPD/fzfbin" "$TMPD/home" "$TMPD/state" "$TMPD/out"

PC='exec sleep 900'
tmux -f /dev/null -L "$SOCK" new-session -d -s alpha -x 120 -y 30 -c "$TMPD/home" "$PC"
tmux -L "$SOCK" set -g automatic-rename off
tmux -L "$SOCK" new-window -d -t '=alpha:' -n two -c "$TMPD/home" "$PC"
tmux -L "$SOCK" split-window -d -t '=alpha:1' -c "$TMPD/home" "$PC"
tmux -L "$SOCK" new-session -d -s bravo -x 120 -y 30 -c "$TMPD/home" "$PC"
tmux -L "$SOCK" new-session -d -s scratch-1 -x 120 -y 30 -c "$TMPD/home" "$PC"
SOCK_PATH="$(tmux -L "$SOCK" display-message -p '#{socket_path}')"
PANE="$(tmux -L "$SOCK" list-panes -t '=alpha:0' -F '#{pane_id}')"

# The stand-in tmux: one line per run, then the real one.
REAL_TMUX="$(command -v tmux)"
cat > "$TMPD/bin/tmux" <<TMUX
#!/bin/sh
printf '%s\n' "\$1" >> "\$LF_OUT/tmux.\$LF_TAG"
exec '$REAL_TMUX' "\$@"
TMUX
# The stand-in core: one line per run, then as LF_CORE says -- the real core,
# a refusal of the protocol, a failure, or a line that is no row.
cat > "$TMPD/core" <<CORE
#!/bin/sh
echo run >> "\$LF_OUT/core.\$LF_TAG"
case "\${LF_CORE:-real}" in
  refuse) echo "imux: unknown subcommand" >&2; exit 2 ;;
  fail)   exit 1 ;;
  junk)   echo gather; exit 0 ;;
esac
exec '$BIN' "\$@"
CORE
# The stand-in fzf, for the navigator's loop: saves what it reads, cancels.
cat > "$TMPD/fzfbin/fzf" <<'FZF'
#!/bin/sh
case " $* " in *" --version "*) echo "0.74.3 (stub)"; exit 0 ;; esac
cat > "$LF_OUT/fzf.$LF_TAG"
exit 130
FZF
chmod +x "$TMPD/bin/tmux" "$TMPD/core" "$TMPD/fzfbin/fzf"

# No controlling terminal: the navigator's width is 80, as FZF_COLUMNS makes
# --list's.
SETSID=()
command -v setsid >/dev/null 2>&1 && setsid -w true 2>/dev/null && SETSID=(setsid -w)
NOW=$(( $(date +%s) + 5 ))

# run TAG [VAR=value ...] [-- ARGS]: the script, as a reload runs it, with the
# stand-ins; its rows in out/rows.TAG, its stderr in out/err.TAG.
run() {
  local tag="$1"; shift
  local -a envs=() args=(--list)
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; args=("$@"); break ;; *) envs+=("$1"); shift ;; esac
  done
  rm -f "$TMPD/out/"*".$tag"
  env -i HOME="$TMPD/home" PATH="$TMPD/bin:$TMPD/fzfbin:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      XDG_STATE_HOME="$TMPD/state" XDG_DATA_HOME="$TMPD/home/.local/share" XDG_RUNTIME_DIR= \
      TMUX="$SOCK_PATH,99999,0" TMUX_PANE="$PANE" INTERDIMUX_OPTS_PRIMED=1 \
      INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_USE_ZOXIDE=off \
      INTERDIMUX_NOW="$NOW" INTERDIMUX_BIN="$TMPD/core" LF_OUT="$TMPD/out" LF_TAG="$tag" \
      ${envs[@]+"${envs[@]}"} \
      ${SETSID[@]+"${SETSID[@]}"} bash "${RUN_SCRIPT:-$SCRIPT}" ${args[@]+"${args[@]}"} \
      </dev/null >"$TMPD/out/rows.$tag" 2>"$TMPD/out/err.$tag" || :
}
# How often stand-in TAG ran: tmux's queries (the list's starts with
# list-sessions) and the core's runs.
queries() { grep -c '^list-sessions$' "$TMPD/out/tmux.$1" 2>/dev/null || true; }
cores() { grep -c . "$TMPD/out/core.$1" 2>/dev/null || true; }
said() { grep -c '^display-message$' "$TMPD/out/tmux.$1" 2>/dev/null || true; }
same() { cmp -s "$TMPD/out/rows.$1" "$TMPD/out/rows.$2"; }
refusals() { grep -c 'rust core refused' "$TMPD/state/interdimux/errors.log" 2>/dev/null || true; }

# --- the rows: the full path's -----------------------------------------------------
run fast FZF_COLUMNS=80
run bash FZF_COLUMNS=80 INTERDIMUX_USE_RUST=off
# the navigator's loop: XDG_RUNTIME_DIR is empty, so its first list is the
# pipeline's, through gather_targets in the fully parsed file
run nav --
mv "$TMPD/out/fzf.nav" "$TMPD/out/rows.nav" 2>/dev/null || :
check "--list draws the sessions, the windows and the split window's panes" \
  'grep -q "S:alpha\$" "$TMPD/out/rows.fast" && grep -q "S:bravo\$" "$TMPD/out/rows.fast" && grep -q "P:alpha:1:1\$" "$TMPD/out/rows.fast"'
check "...the bash renderer's rows, byte for byte" 'same fast bash'
check "...the navigator's own gather's, byte for byte (the core, the full file)" 'same fast nav'
check "...nothing on stderr" '[ ! -s "$TMPD/out/err.fast" ] && [ ! -s "$TMPD/out/err.bash" ] && [ ! -s "$TMPD/out/err.nav" ]'
check "one list: tmux asked once (got $(queries fast)), the core run once (got $(cores fast))" \
  '[ "$(queries fast)" = 1 ] && [ "$(cores fast)" = 1 ]'
for hide in 'scratch-*' 'nothing-matches-*'; do
  t="hide-${hide%%-*}"
  run "$t" FZF_COLUMNS=80 INTERDIMUX_HIDE="$hide"
  run "$t-bash" FZF_COLUMNS=80 INTERDIMUX_HIDE="$hide" INTERDIMUX_USE_RUST=off
  check "@interdimux-hide '$hide': the bash renderer's rows" 'same "$t" "$t-bash"'
done
check "...the one hides its session, the other nothing" \
  '! grep -q "S:scratch-1\$" "$TMPD/out/rows.hide-scratch" && grep -q "S:alpha\$" "$TMPD/out/rows.hide-scratch" && same hide-nothing fast'

# --- a core that does not draw them ------------------------------------------------
rm -rf "$TMPD/state/interdimux"
for mode in refuse fail junk; do
  run "core-$mode" FZF_COLUMNS=80 LF_CORE="$mode"
  check "a core that ${mode}s: the bash renderer's rows" 'same "core-$mode" bash'
  check "...tmux asked once (got $(queries "core-$mode")), the core run once (got $(cores "core-$mode"))" \
    '[ "$(queries "core-$mode")" = 1 ] && [ "$(cores "core-$mode")" = 1 ]'
  check "...nothing on stderr" '[ ! -s "$TMPD/out/err.core-$mode" ]'
  if [ "$mode" = refuse ]; then
    check "...the refusal said once: errors.log (got $(refusals)) and the status line (got $(said core-refuse))" \
      '[ "$(refusals)" = 1 ] && [ "$(said core-refuse)" = 1 ]'
  else
    check "...and nothing said (status line: $(said "core-$mode"))" '[ "$(said "core-$mode")" = 0 ]'
  fi
done
check "...and no refusal logged but the refusing core's (got $(refusals))" '[ "$(refusals)" = 1 ]'

# --- what each path parses ---------------------------------------------------------
# bash -v echoes every line it reads: the fast path never reaches the renderer
# or a callback (the preview's dispatch is the first); the fall-through does.
for tag in fast-v refuse-v; do
  core=real; [ "$tag" = refuse-v ] && core=refuse
  rm -f "$TMPD/out/"*".$tag"
  env -i HOME="$TMPD/home" PATH="$TMPD/bin:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      XDG_STATE_HOME="$TMPD/state" TMUX="$SOCK_PATH,99999,0" TMUX_PANE="$PANE" \
      INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
      INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_NOW="$NOW" FZF_COLUMNS=80 \
      INTERDIMUX_BIN="$TMPD/core" LF_OUT="$TMPD/out" LF_TAG="$tag" LF_CORE="$core" \
      bash -v "$SCRIPT" --list </dev/null >"$TMPD/out/rows.$tag" 2>"$TMPD/out/err.$tag" || :
done
# $1 = tag, $2 = a line: how often bash read it
parsed() { grep -cxF -- "$2" "$TMPD/out/err.$1" || true; }
LISTD='if [ "${1:-}" = "--list" ]; then'   # --list's own dispatch, below the callbacks
check "traced: the rows are the same" 'same fast-v fast && same refuse-v bash'
check "the fast path parses neither the renderer nor a callback, nor --list's own dispatch" \
  '[ "$(parsed fast-v "gather_targets() {")" = 0 ] && [ "$(parsed fast-v "if [ \"\${1:-}\" = \"--preview\" ]; then")" = 0 ] && [ "$(parsed fast-v "$LISTD")" = 0 ]'
check "...a refusal falls through to the renderer and to --list's own dispatch" \
  '[ "$(parsed refuse-v "gather_targets() {")" = 1 ] && [ "$(parsed refuse-v "$LISTD")" = 1 ]'

# --- through a symlink -----------------------------------------------------------
mkdir -p "$TMPD/links/sub"
ln -s "$SCRIPT" "$TMPD/links/abs"
ln -s ../abs "$TMPD/links/sub/rel"   # relative, and to the first link
for l in links/abs links/sub/rel; do
  t="link-${l##*/}"
  RUN_SCRIPT="$TMPD/$l" run "$t" FZF_COLUMNS=80
  RUN_SCRIPT="$TMPD/$l" run "$t-bash" FZF_COLUMNS=80 INTERDIMUX_USE_RUST=off
  RUN_SCRIPT="$TMPD/$l" run "$t-bad" -- --no-such-mode
  check "through a symlink ($l): the core's rows and the bash renderer's" \
    'same "$t" fast && same "$t-bash" bash && [ ! -s "$TMPD/out/err.$t" ] && [ ! -s "$TMPD/out/err.$t-bash" ]'
  check "...and an argument no mode takes is refused by name" \
    'grep -qx "interdimux: unknown mode '"'"'--no-such-mode'"'"' (see --help)" "$TMPD/out/err.$t-bad"'
done

echo
if [ -n "$ERRORS" ]; then printf '%s' "$ERRORS"; echo; fi
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
