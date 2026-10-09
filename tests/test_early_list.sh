#!/usr/bin/env bash
#
# The navigator's first list is started early (review PERF-16): forked as soon
# as everything gather_targets can run is defined, in a process substitution,
# while the rest of the file is parsed and the navigator sets itself up; fzf
# reads it from the fd.  It used to be `gather_targets | fzf` at the top of
# the loop, after all of that, so its rows reached fzf too late for fzf's first
# paint step.  The loop's later passes (ctrl-o, then Esc) still gather that way.
#
# What must not change, driven with a stand-in fzf (it saves what it reads and
# cancels, as Esc does) and a stand-in core in front of the real one:
#
#   * the rows fzf reads: byte for byte the same list as the pipeline's
#   * whether it is early at all: the stand-in core says so -- the loop
#     exports INTERDIMUX_HINTS_X before its own gather, and the early list
#     started before that.  Early with a private XDG_RUNTIME_DIR on bash >=
#     4.4; the pipeline without one (the scratch names come from mktemp), and
#     on bash 4.3, whose `wait` cannot wait for a process substitution
#   * what the list says on stderr reaches errors.log, as the pipeline's did:
#     the navigator does not truncate the error file the list writes to
#   * the mounts file the list's core writes is still there for fzf's
#     callbacks: the navigator clears a leftover before the list starts, not
#     after
#   * no scratch file is left behind -- and none appears later: an fzf that
#     ends before the list has (Esc as the popup opens) still has the
#     navigator wait for the list, whose core writes the mounts file, before
#     the EXIT trap removes it.  And the wait ends even for a list bigger than
#     a pipe holds: its pipe is closed first, so it is not left writing to it
#   * the preview state the list is laid out for: read back from the file the
#     navigator writes, with read -r, which trims it -- @interdimux-show-preview
#     ' on' lays the rows out as 'on' does, early or not.  And neither that file
#     nor the error file is rewritten while the list may be using it (traced)
#
# And the real thing: the binding's popup, on a server with a private
# XDG_RUNTIME_DIR, with the real fzf.  It draws the early list, ^r reloads it,
# ctrl-o and then Esc run the loop's next pass, and Enter switches.  The other
# suites' popups take the early path only when the suites run with an
# XDG_RUNTIME_DIR of their own, and the dev image has none.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
BIN="$SCRIPT_DIR/rust/target/release/imux"
SOCK="interdimux-earlylist-test-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-earlylist.XXXXXX")" && pwd -P)"
PASS=0
FAIL=0
ERRORS=""

SOCK_PATH=""
PSOCK="${SOCK}-p" OSOCK="${SOCK}-o"   # the real popup's server, and its client's
cleanup() {
  local s
  for s in "$OSOCK" "$PSOCK" "$SOCK"; do tmux -L "$s" kill-server 2>/dev/null || true; done
  # the socket files too: tmux leaves them behind after kill-server
  rm -f ${SOCK_PATH:+"$SOCK_PATH"} "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$PSOCK" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$OSOCK"
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

echo "interdimux early-list tests"
echo

if [ ! -x "$BIN" ]; then
  echo "  (skipped: the Rust core is not built, and the early list is the Rust path's)"
  echo
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

mkdir -p "$TMPD/fzfbin" "$TMPD/run" "$TMPD/tmp" "$TMPD/home" "$TMPD/state" "$TMPD/data" "$TMPD/out"
chmod 700 "$TMPD/run"

PC='exec sleep 900'
tmux -f /dev/null -L "$SOCK" new-session -d -s alpha -x 120 -y 30 -c "$TMPD/home" "$PC"
tmux -L "$SOCK" set -g automatic-rename off
tmux -L "$SOCK" new-window -d -t '=alpha:' -n two -c "$TMPD/home" "$PC"
tmux -L "$SOCK" split-window -d -t '=alpha:1' -c "$TMPD/home" "$PC"
tmux -L "$SOCK" new-session -d -s bravo -x 120 -y 30 -c "$TMPD/home" "$PC"
SOCK_PATH="$(tmux -L "$SOCK" display-message -p '#{socket_path}')"
PANE="$(tmux -L "$SOCK" list-panes -t '=alpha:0' -F '#{pane_id}')"

# The stand-in fzf: saves its stdin (EL_READ=0: reads nothing, as an fzf that
# is cancelled before the list arrives) and whether the core's mounts file is
# there once the list has ended, then cancels.
cat > "$TMPD/fzfbin/fzf" <<'FZF'
#!/bin/sh
case " $* " in *" --version "*) echo "0.74.3 (stub)"; exit 0 ;; esac
[ "${EL_READ:-1}" = 0 ] && exit 130
cat > "$EL_OUT/rows.$EL_TAG"
[ -f "${INTERDIMUX_MOUNTS_FILE:-}" ] && echo there > "$EL_OUT/mounts.$EL_TAG"
exit 130
FZF
# The stand-in core: whether the loop had exported its hints yet, then the
# real core (after EL_SLOW seconds; EL_BIG: its rows 3000 times over, ~1 MB),
# then a mark that it is done.
cat > "$TMPD/core" <<CORE
#!/bin/sh
if [ -n "\${INTERDIMUX_HINTS_X+x}" ]; then echo pipeline; else echo early; fi >> "\$EL_OUT/core.\$EL_TAG"
[ -z "\${EL_SLOW:-}" ] || sleep "\$EL_SLOW"
if [ -n "\${EL_BIG:-}" ]; then
  rows=\$("$BIN" "\$@") || exit
  i=0; while [ \$i -lt 3000 ]; do printf '%s\\n' "\$rows"; i=\$((i + 1)); done; rc=0
else
  "$BIN" "\$@"; rc=\$?
fi
echo done > "\$EL_OUT/done.\$EL_TAG"
exit \$rc
CORE
chmod +x "$TMPD/fzfbin/fzf" "$TMPD/core"

# No controlling terminal, so the width is the same 80 columns everywhere.
SETSID=()
command -v setsid >/dev/null 2>&1 && setsid -w true 2>/dev/null && SETSID=(setsid -w)

# nav TAG BASH [VAR=value ...]: the navigator, as the popup starts it, to the
# stand-in fzf's cancel.  With XDG_RUNTIME_DIR="" there is no private one.
nav() {
  local tag="$1" sh="$2"; shift 2
  rm -f "$TMPD/out/"*".$tag"
  env -i HOME="$TMPD/home" PATH="$TMPD/fzfbin:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 TMPDIR="$TMPD/tmp" \
      XDG_RUNTIME_DIR="$TMPD/run" XDG_STATE_HOME="$TMPD/state" XDG_DATA_HOME="$TMPD/data" \
      TMUX="$SOCK_PATH,99999,0" TMUX_PANE="$PANE" INTERDIMUX_OPTS_PRIMED=1 \
      INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_USE_ZOXIDE=off \
      INTERDIMUX_BIN="$TMPD/core" EL_OUT="$TMPD/out" EL_TAG="$tag" "$@" \
      ${SETSID[@]+"${SETSID[@]}"} "$sh" "$SCRIPT" </dev/null >/dev/null 2>"$TMPD/out/err.$tag" || :
}
said() { cat "$TMPD/out/core.$1" 2>/dev/null || true; }
leftovers() { # the navigator's scratch files, wherever they were made
  ls "$TMPD/run" "$TMPD/tmp" 2>/dev/null | grep 'resume' | tr '\n' ' ' || true
}

# --- the same rows, early or not ----------------------------------------------------
nav early bash
nav pipeline bash XDG_RUNTIME_DIR=
check "with a private XDG_RUNTIME_DIR the first list starts early (got: $(said early))" '[ "$(said early)" = early ]'
check "without one it is the loop's pipeline (got: $(said pipeline))" '[ "$(said pipeline)" = pipeline ]'
check "fzf reads a list (the sessions and the split window's panes)" \
  'grep -q "S:alpha\$" "$TMPD/out/rows.early" && grep -q "S:bravo\$" "$TMPD/out/rows.early" && grep -q "P:alpha:1:1\$" "$TMPD/out/rows.early"'
check "...the same list, byte for byte" 'cmp -s "$TMPD/out/rows.early" "$TMPD/out/rows.pipeline"'
check "...and nothing on stderr" '[ ! -s "$TMPD/out/err.early" ] && [ ! -s "$TMPD/out/err.pipeline" ]'
check "the core's mounts file is there for fzf's callbacks, early or not" \
  '[ -e "$TMPD/out/mounts.early" ] && [ -e "$TMPD/out/mounts.pipeline" ]'
check "no scratch file is left behind (got: $(leftovers))" '[ -z "$(leftovers)" ]'

# --- the old bashes: 4.4 waits for a process substitution, 4.3 cannot ---------------
OLD_DIR="${INTERDIMUX_OLD_BASH_DIR:-}"
for v in 4.3 4.4; do
  b="$OLD_DIR/$v/bash"
  if [ -n "$OLD_DIR" ] && [ -x "$b" ]; then
    want=early; [ "$v" = 4.3 ] && want=pipeline
    nav "b$v" "$b"
    check "bash $v: the first list is the $want's (got: $(said "b$v"))" '[ "$(said "b$v")" = "$want" ]'
    check "bash $v: ...the same list" 'cmp -s "$TMPD/out/rows.early" "$TMPD/out/rows.b$v"'
    check "bash $v: ...and no scratch file is left behind (got: $(leftovers))" '[ -z "$(leftovers)" ]'
  elif [ -n "$OLD_DIR" ]; then
    report "bash $v is in \$INTERDIMUX_OLD_BASH_DIR (no $b)" fail
  else
    echo "  (skipped bash $v: not in \$INTERDIMUX_OLD_BASH_DIR)"
  fi
done

# --- an fzf that is gone before the list is done --------------------------------------
# The core takes a second; the stand-in fzf reads nothing and cancels at once.
# The navigator returns only once the list has ended, and nothing it wrote --
# the core writes the mounts file on every list -- is left after the EXIT trap.
nav slow bash EL_READ=0 EL_SLOW=1
check "Esc before the list is done: the navigator waits for it (the core had finished)" '[ -e "$TMPD/out/done.slow" ]'
check "...and nothing is left behind, the mounts file included (got: $(leftovers))" '[ -z "$(leftovers)" ]'
# ~1 MB of rows, and nothing reads them: the navigator closes the list's pipe
# before it waits, so the list dies of SIGPIPE (or EPIPE) instead of filling it
# forever.  A navigator that hangs here is stopped by timeout (exit 124).
rc=0
rm -f "$TMPD/out/"*".big"
env -i HOME="$TMPD/home" PATH="$TMPD/fzfbin:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 TMPDIR="$TMPD/tmp" \
    XDG_RUNTIME_DIR="$TMPD/run" XDG_STATE_HOME="$TMPD/state" XDG_DATA_HOME="$TMPD/data" \
    TMUX="$SOCK_PATH,99999,0" TMUX_PANE="$PANE" INTERDIMUX_OPTS_PRIMED=1 \
    INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_USE_ZOXIDE=off \
    INTERDIMUX_BIN="$TMPD/core" EL_OUT="$TMPD/out" EL_TAG=big EL_READ=0 EL_BIG=1 \
    timeout 20 ${SETSID[@]+"${SETSID[@]}"} bash "$SCRIPT" </dev/null >/dev/null 2>&1 || rc=$?
check "a list bigger than a pipe holds, and nobody reads it: the navigator still ends (rc $rc)" \
  '[ "$rc" != 124 ] && [ "$(said big)" = early ]'
check "...and nothing is left behind (got: $(leftovers))" '[ -z "$(leftovers)" ]'

# --- what the list says on stderr is reported ---------------------------------------
# A dump the list cannot read is said on its stderr, which is the navigator's
# error file -- created before the list starts, and not truncated after.
for tag in early pipeline; do
  rm -rf "$TMPD/state/interdimux"
  if [ "$tag" = early ]; then nav "dump-$tag" bash INTERDIMUX_DUMP_IN="$TMPD/nowhere"
  else nav "dump-$tag" bash INTERDIMUX_DUMP_IN="$TMPD/nowhere" XDG_RUNTIME_DIR=; fi
  check "$tag: the list's error is in errors.log" \
    'grep -qF "INTERDIMUX_DUMP_IN: cannot read $TMPD/nowhere" "$TMPD/state/interdimux/errors.log" 2>/dev/null'
done

# --- the preview state, as the list reads it back ---------------------------------
# The navigator writes @interdimux-show-preview to the preview state's file,
# and the list reads it back with read -r, which trims it: ' on' and 'on '
# are laid out as 'on' is.  Early, that file is written before the list
# starts; the list must not take the option's raw value instead.
nav pv-on bash INTERDIMUX_SHOW_PREVIEW=on
check "show-preview on: the rows are laid out for the preview (not as off's are)" \
  '[ "$(said pv-on)" = early ] && ! cmp -s "$TMPD/out/rows.pv-on" "$TMPD/out/rows.early"'
for pv in ' on' 'on ' ' off'; do
  t="pv${pv// /_}"
  nav "$t" bash INTERDIMUX_SHOW_PREVIEW="$pv"
  nav "$t-pipe" bash INTERDIMUX_SHOW_PREVIEW="$pv" XDG_RUNTIME_DIR=
  check "show-preview '$pv': early (got: $(said "$t")), and the pipeline's rows byte for byte" \
    '[ "$(said "$t")" = early ] && cmp -s "$TMPD/out/rows.$t" "$TMPD/out/rows.$t-pipe"'
done
check "...which for ' on' are on's" 'cmp -s "$TMPD/out/rows.pv_on" "$TMPD/out/rows.pv-on"'
check "...and nothing is left behind, the preview state's file included (got: $(leftovers))" '[ -z "$(leftovers)" ]'
# And nothing truncates a file the list reads or writes while it may be at it:
# a rewrite of the preview state truncates it first, and a read in between
# (the list's comes 10-20 ms after the fork, as the navigator reaches its
# loop) found it empty and laid the list out for no preview -- rarely, and not
# in a run as slow as a traced one, so the opens are counted instead.  Each of
# the two is created once before fzf starts; the navigator appends to the
# error file, and never rewrites the preview state before fzf has started.
if command -v strace >/dev/null 2>&1 && strace -f -qq -o /dev/null true 2>/dev/null; then
  cat > "$TMPD/sbash" <<'SBASH'
#!/bin/sh
exec strace -f -qq -e trace=openat,execve -o "$EL_TRACE" bash "$@"
SBASH
  chmod +x "$TMPD/sbash"
  nav traced "$TMPD/sbash" INTERDIMUX_SHOW_PREVIEW=on EL_TRACE="$TMPD/out/trace"
  truncs() { # $1 = the file's suffix: its O_TRUNC opens before fzf's exec
    awk -v sfx="$1" -v fzf="$TMPD/fzfbin/fzf" '
      index($0, "execve(\"" fzf "\"") { exit }
      index($0, sfx "\", O_") && /O_TRUNC/ { n++ }
      END { print n + 0 }' "$TMPD/out/trace" 2>/dev/null
  }
  check "traced, early (got: $(said traced)): the preview state's file is written once before fzf starts (got: $(truncs .preview))" \
    '[ "$(said traced)" = early ] && [ "$(truncs .preview)" = 1 ]'
  check "...and so is the error file (got: $(truncs .err))" '[ "$(truncs .err)" = 1 ]'
else
  echo "  (skipped the traced run: needs strace, and permission to trace a child)"
fi

# --- the real popup, with the real fzf ----------------------------------------------
# The binding opens the navigator from the server's environment, so the
# server is started from a controlled one: the private XDG_RUNTIME_DIR, the
# stand-in core (which says early or not, then runs the real one), state and
# data of its own, /bin/sh to run the popup's command.  A client in an outer
# server's pane shows the popup, and the screen is read off that pane.
wait_for() { # $1 = a command that must succeed [, $2 = tenths of a second]
  local i
  for i in $(seq 1 "${2:-100}"); do eval "$1" && return 0; sleep 0.1; done
  return 1
}
if ! command -v fzf >/dev/null 2>&1; then
  echo "  (skipped the real popup: needs fzf)"
else
  mkdir -p "$TMPD/pstate" "$TMPD/pdata/interdimux" "$TMPD/proj"
  # one directory for ctrl-o's picker to list, so its prompt is the plain one
  printf '%s\n' "$TMPD/proj" > "$TMPD/pdata/interdimux/recent_dirs"
  P() { tmux -L "$PSOCK" "$@"; }
  O() { tmux -L "$OSOCK" "$@"; }
  env -u TMUX -u TMUX_PANE -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE \
      HOME="$TMPD/home" SHELL=/bin/sh LANG=C.UTF-8 LC_ALL=C.UTF-8 TMPDIR="$TMPD/tmp" \
      XDG_RUNTIME_DIR="$TMPD/run" XDG_STATE_HOME="$TMPD/pstate" XDG_DATA_HOME="$TMPD/pdata" \
      XDG_CACHE_HOME="$TMPD/cache" XDG_CONFIG_HOME="$TMPD/config" \
      INTERDIMUX_USE_RUST=on INTERDIMUX_BIN="$TMPD/core" EL_OUT="$TMPD/out" EL_TAG=popup \
    tmux -f /dev/null -L "$PSOCK" new-session -d -s host -x 100 -y 30 -c "$TMPD/home" "$PC"
  P set -g default-shell /bin/sh
  P set -s escape-time 0
  P set -g @interdimux-use-zoxide off
  P new-session -d -s victim -x 100 -y 30 -c "$TMPD/home" "$PC"
  PSOCK_PATH="$(P display-message -p '#{socket_path}')"
  # the bindings, installed the way the plugin installs them
  TMUX="$PSOCK_PATH,99999,0" TMUX_PANE="$(P list-panes -t '=host:' -F '#{pane_id}')" \
    bash "$SCRIPT" --bind-keys
  env -u TMUX -u TMUX_PANE SHELL=/bin/sh LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    tmux -f /dev/null -L "$OSOCK" new-session -d -s drv -x 100 -y 30 \
    "TMUX= LANG=C.UTF-8 LC_ALL=C.UTF-8 tmux -L $PSOCK attach -t host"
  O set -g status off
  O set -s escape-time 0
  cap()      { O capture-pane -t '=drv:' -p 2>/dev/null || true; }
  shows()    { cap | grep -qF -- "$1"; }
  popup_up() { cap | grep -q '┌'; }
  key()      { O send-keys -t '=drv:' "$@"; }
  on_row()   { { cap | grep -m1 '▌' || true; } | grep -qF -- "▸ $1"; }   # the cursor's row
  screen_err() { ERRORS+="    screen: $(cap | grep -v '^ *$' | head -6 | tr '\n' '|')"$'\n'; }
  CL=""
  if wait_for '[ -n "$(P list-clients 2>/dev/null)" ]'; then CL=$(P list-clients -F '#{client_name}' | head -1); fi
  rm -f "$TMPD/out/"*".popup"
  if [ -z "$CL" ]; then
    report "the real popup: a client attaches" fail
  else
    key C-b f
    if wait_for 'shows "▸ victim"' 150; then
      report "the real popup: fzf draws the list" pass
    else
      report "the real popup: fzf draws the list" fail; screen_err
    fi
    check "...which started early (the core's first run said: $(head -n 1 "$TMPD/out/core.popup" 2>/dev/null))" \
      '[ "$(head -n 1 "$TMPD/out/core.popup" 2>/dev/null)" = early ]'
    P new-session -d -s charlie -x 100 -y 30 -c "$TMPD/home" "$PC"
    key C-r
    if wait_for 'shows "▸ charlie"' 100; then
      report "^r reloads it (a session made since is listed)" pass
    else
      report "^r reloads it (a session made since is listed)" fail; screen_err
    fi
    key C-o
    if wait_for 'shows "new session ❯"' 100; then
      key Escape
      if wait_for '! shows "new session ❯" && shows "▸ charlie" && shows "▸ victim"' 100; then
        report "ctrl-o, then Esc: the loop's next pass draws the list again" pass
      else
        report "ctrl-o, then Esc: the loop's next pass draws the list again" fail; screen_err
      fi
    else
      report "ctrl-o opens the directory picker" fail; screen_err
    fi
    # the query, and the cursor on its match before the Enter
    key charlie
    wait_for 'on_row charlie' 100 || true
    key Enter
    if wait_for '! popup_up' 100; then
      report "Enter: the popup closes by itself" pass
    else
      report "Enter: the popup closes by itself" fail; screen_err
      P display-popup -C -c "$CL" 2>/dev/null || true
    fi
    sw="$({ P list-clients -F '#{client_name} #{client_session}' 2>/dev/null || true; } | awk -v c="$CL" '$1 == c { print $2 }')"
    check "...and the client is switched to the row chosen (got: $sw)" '[ "$sw" = charlie ]'
    check "...nothing went to errors.log" '[ ! -s "$TMPD/pstate/interdimux/errors.log" ]'
    check "...and nothing is left behind (got: $(leftovers))" '[ -z "$(leftovers)" ]'
  fi
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
