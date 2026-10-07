#!/usr/bin/env bash
#
# bench.sh -- performance A/B harness for interdimux
#
#   bench.sh [-n N] [-s scenario,scenario,...] [options] <worktreeA> <worktreeB>
#
# Proves (or disproves) that worktree B is not slower than worktree A.  Both are
# run against ONE fixture built once per invocation, interleaved, and compared
# by the shift of per-pair differences.  Exit status: 0 = no CPU regression and
# identical outputs, 3 = at least one scenario REGRESSION, 4 = no regression but
# some output differs between A and B (a UX change -- intended or not), 1 = the
# bench itself failed (bad worktree, fixture, or a run that exited unexpectedly),
# 2 = usage.
#
# Options
#   -n N        measured pairs per scenario (default 30; each pair is one A and
#               one B run).  An explicit -n is honoured exactly unless -b is
#               also given.
#   -s LIST     comma-separated scenarios (default: all default ones, below);
#               "all" = default + extra.
#   -w W        warm-up pairs per scenario, discarded (default 2)
#   -b SECS     per-scenario time budget (default 25 when -n is not given):
#               slow scenarios run fewer pairs, never fewer than 8; and while a
#               scenario's noise is above 6%, it gets 10 more pairs at a time
#               (up to 3N) until the budget is spent, so a load burst from
#               something else on the machine is diluted rather than decisive
#   -o FILE     also write the result table as TSV to FILE
#   -K          keep the work dir (fixture files, raw samples, outputs) for
#               inspection.  The tmux servers and holders are always killed.
#   -q          no progress lines
#   --allow-stale   accept a rust/target/release/imux older than its sources
#   --no-confirm    report first-set verdicts without re-measuring flagged ones
#   --list      list scenarios and exit
#   --exec CMD  (debugging) build the fixture, run `bash -c CMD` with BENCH_*
#               variables exported (BENCH_SOCK, BENCH_FIX, BENCH_POPUP_ENV_A ...),
#               clean up, exit with CMD's status.  Nothing is measured.
#
# Scenarios (how each one is invoked mirrors the real caller; see build_scenarios)
#   first-frame   the navigator opening: `bash interdimux.sh` with a popup's
#                 environment and a 158x35 pty, a stub fzf on PATH.  WALL is the
#                 time from exec until the stub fzf receives the FIRST row (what
#                 fzf needs to paint); CPU is the whole run (all rows, exit).
#   list          the fzf reload command (^r, ^/, resize, after every action):
#                 sh -c "bash interdimux.sh --list", Rust renderer
#   list-bash     the same with INTERDIMUX_USE_RUST=off (the bash renderer)
#   preview-S     --preview on a session row (ops, 8 windows)
#   preview-W     --preview on a window row (4 panes)
#   preview-P     --preview on a pane row (the fake claude agent pane)
#   hint          the per-cursor-move footer: the navigator's own `focus` bind
#                 snippet (read from the fzf argv the navigator built), run by
#                 sh -c with an empty query -- the inline path, no bash re-exec
#   footer        the same snippet with a query typed: it runs --footer-for
#   describe-create  the same snippet at zero matches: it runs --describe-create
#   session-name-for  bash interdimux.sh --session-name-for DIR (CLI seam)
#   dirs-list     the ctrl-o picker's list: --dirs-list, with the environment the
#                 --dirs picker hands its fzf (mount table exported etc.)
#   dirs-deep     ctrl-f deep search: --dirs-list --deep svc (~100 dirs match)
#   dirs-preview  --dirs-preview on a git repo with changes and a README
#   doctor        bash interdimux.sh --doctor
#  extra (only with -s, or -s all):
#   first-frame-bash  first-frame with INTERDIMUX_USE_RUST=off
#   hint-ladder   bash interdimux.sh --hint-ladder W (a test seam, not a
#                 runtime callback: the navigator inlines the ladders)
#   scope-prompt  bash interdimux.sh --scope-prompt (the fallback-path ^] prompt)
#   parse         bash -n interdimux.sh (pure parse cost of the script)
#
# What is measured, per run
#   cpu   user+sys of the whole process tree (the command, everything it
#         waited for, AND any orphan it left: the runner is a child subreaper)
#         PLUS the CPU the fixture's tmux server spent meanwhile (format
#         expansion for list-panes happens in the server) PLUS what the
#         server's jobs cost -- run-shell, if-shell, a hook's run-shell, #():
#         a job still running when the command is done is waited for (up to
#         3 s, then killed), and its CPU is the growth of the server's
#         cutime+cstime.  The kernel counts that in clock ticks, so a job
#         shows as 0 or 10 ms in one run and as its true cost only on average:
#         a job of a few ms is undercounted by the medians below, which the
#         note "the tmux server's jobs cost ..." (the per-run mean) makes up
#         for.  Not counted: a job's own orphans (reparented to init), and a
#         new pane's processes.
#   wall  fork -> exit of the command (first-frame: -> first row at the stub fzf)
#   Times are in ms.  Runs are interleaved in pairs whose order alternates
#   (AB BA AB ...), so drift and ordering effects cancel.
#
# The table
#   A cpu / B cpu    medians (ms)
#   dcpu%            the shift B-A: Hodges-Lehmann estimate over the per-pair
#                    differences (median of their Walsh averages), % of A's median
#   noise%           half-width of its 99% confidence interval (exact Wilcoxon
#                    signed-rank), % of A's median -- the measured noise floor
#   verdict          REGRESSION when dcpu% > max(2, noise%), FASTER when
#                    dcpu% < -max(2, noise%), else ok; "(n<8)" = too few pairs
#                    to say; FAILED = a run exited unexpectedly or no row reached
#                    fzf (see the notes).  A flagged scenario (cpu or wall) is
#                    measured AGAIN on a fresh set of pairs; the row then shows
#                    both sets together (n marked "c"), and the flag stands only
#                    if that combined result still exceeds the threshold AND the
#                    second set on its own points the same way.  One noisy
#                    stretch on a shared machine can push a single set past its
#                    interval; it rarely does that to two.
#   A wall / B wall, dwall%, wall   the same for wall time (wall: ok/SLOWER/FASTER)
#   IQR%             interquartile range of each side's cpu, % of its median
#   out              B's output vs A's, worktree paths normalised: same / DIFF /
#                    vol (A's own output varied between runs, so not comparable)
#   n                measured pairs ("c": first set + confirming set)
#   A DIFF is a UX change, not a perf one: inspect it (the first lines of each
#   differing pair are printed under the table; -K keeps the full outputs).
#
# The fixture (shared by A and B, rebuilt every invocation, removed after)
#   * private tmux server `-L imux-bench-$$ -f /dev/null`, default-command
#     'bash --norc --noprofile -i', 12 sessions / 40 windows / 90 panes (short and
#     long session names, editors, servers, ssh, logs -- perl processes with a
#     chosen argv -- and idle bash prompts), plus one attached client (a second
#     server, imux-bench-$$-outer, hosts it at 200x50, so the popup is 158x35)
#   * HOME, XDG_{CONFIG,DATA,STATE,CACHE}_HOME, XDG_RUNTIME_DIR (0700), TMPDIR
#     and _ZO_DATA_DIR all inside the work dir; 8 git repos on feature branches
#     (two dirty), ~/work with 10 teams x 10 svc-* projects, a zoxide db of ~50
#     dirs, a recent_dirs file, @interdimux-project-dirs '~/work:~/src'
#   * fake agents only: a script named `claude` (OSC title "✳ Claude Code",
#     exec -a claude sleep) with a registry record in ~/.claude/sessions, a
#     fake codex (perl with codex's argv and its "Action Required" title), and a
#     plain shell titled "✳ Claude Code".  No real agent CLI is ever started.
#   * stub `at`/`atq`/`atrm`/`batch` first on PATH (--doctor runs atq), so the
#     user's at queue is never touched
#   * INTERDIMUX_NOW is pinned in every environment, so ages cannot make two
#     renders differ (it is a seam the script honours on every path)
#
# How callbacks get their environment
#   For each worktree the bench starts the REAL navigator (twice: Rust and bash
#   renderer) and the REAL ctrl-o picker (`--dirs`) with a "holding" stub fzf,
#   which records the argv and environment it was handed and then waits.  The
#   holders stay alive for the whole run, so the state files their environment
#   names (preview state, query state, mount table) exist exactly as in a live
#   popup.  Each callback then runs with that recorded environment plus the
#   FZF_* variables fzf 0.74 exports to its children (captured from a real fzf:
#   FZF_COLUMNS=158, FZF_LINES=35, FZF_PREVIEW_* only while the preview is
#   shown, FZF_QUERY/FZF_MATCH_COUNT/...), through `sh -c` as --with-shell='sh -c'
#   does.  A worktree whose navigator does not reach fzf fails the bench.
#
# Requirements: bash >= 4.4, a C compiler (cc), tmux (the first on PATH, or
# $IMUX_BENCH_TMUX), fzf (only for its --version string), git, perl, setsid;
# fd, fdfind or find (the plugin's own choice, in that order); zoxide
# ($IMUX_PERF_ZOXIDE, else the first on PATH); Linux (/proc, a child
# subreaper, signalfd).  The fixture's PATH starts with links to the tmux,
# bash and zoxide this shell found, so the server, the panes and the plugin
# all run those.  Without a zoxide the picker has no zoxide rows and costs
# nothing for it: the run says so in a WARNING, and with IMUX_PERF_STRICT=1
# (dev/cmd.sh sets it) refuses to start.  The dev image has all of it: zoxide
# at /opt/zoxide/zoxide, off the PATH (the suites, as on CI, have none), and
# fd as Debian's fdfind, which the plugin walks with.  The VPS host has
# zoxide and fd: its dirs-* numbers are not comparable with the image's.
# Both worktrees need rust/target/release/imux built and newer than rust/src
# (--allow-stale skips the age check).
#
# Safety: never touches the user's tmux server (every tmux call is
# $TMUX_BIN -L <private socket>; TMUX, TMUX_PANE and TMUX_TMPDIR are unset
# first), never submits at jobs, never reads the real HOME's dotfiles.  On exit
# -- normal, error, Ctrl-C -- the holders, both private servers, their socket
# files and (unless -K) the work dir are removed, and any process still carrying
# this run's IMUX_BENCH_ID in its environment is killed.  A SIGKILL (a tool
# timeout) cannot be trapped: a watchdog in its own session sees this shell die
# and does the same cleanup within a couple of seconds.
#
# Running it
#   In the dev image: `make perfbench REF=main ARGS='-s list,footer'` from a
#   checkout (dev/cmd.sh perfbench: REF is extracted with git archive and gets
#   its own Rust core, B is the container's copy of the checkout, /work).  See
#   docs/DEVENV.md.  Directly: bench.sh BASE MINE, two trees with their cores
#   built.  A full default run takes ~2 minutes in the dev image on a 4-CPU
#   box (setup ~11 s; 2.5-3 minutes on the host it was written on): give the
#   command a 10-minute timeout, or run it in the background.
#   Re-run a single flagged scenario with -s to look closer.  Work dirs go
#   under $IMUX_BENCH_WORKROOT (default: ${TMPDIR:-/tmp}).
#   IMUX_BENCH_SAME_ENV=1 (debugging the harness) gives B the very environments
#   A recorded.
#
# Load
#   Nothing else heavy may run meanwhile: the verdicts compare CPU time, and a
#   busy machine widens noise% until nothing is detectable.  The run reports
#   the load average before and after (the HOST's, also inside a container:
#   /proc/loadavg is not namespaced) against the host's CPU count, and any
#   process over 50% of a CPU -- inside a container only the container's own
#   processes are visible, so that check cannot see the host's.  From
#   dev/run.sh, the other dev containers that were up when the run started
#   ($IMUX_DEV_OTHERS) are named in a WARNING too.
#
# Sensitivity (A/A runs of one tree against itself)
#   In the dev image on a 4-CPU VPS, otherwise idle (load ~1), at the default
#   budget: noise% 3.7-6% for every scenario from the 25 ms callbacks to the
#   260 ms --doctor and bash renderer, 9% for hint (a 1.6 ms sh), 5% for
#   dirs-deep (0.44 s a run there -- no zoxide or fd in the image -- so 30
#   pairs fit); with -n 10, 8-14%, once 25%.  On the host it was written on
#   (load 0.8-1.9): 4-6%, 2-5% for list-bash, 6-14% for hint, and 15-72% for
#   dirs-deep (2.5 s a run, so only 8 pairs fit the budget).  An extra
#   subshell fork in a callback is ~1 ms: about 3-4% of a 25-35 ms preview,
#   i.e. at the floor; one extra tmux round-trip (+8-10% on --list) or three
#   forks in a preview are caught.

set -uo pipefail
# never the user's server: no inherited TMUX, and the default socket directory
unset TMUX TMUX_PANE TMUX_TMPDIR

BENCH_SELF=$(readlink -f "${BASH_SOURCE[0]}")
BENCH_HOME=${BENCH_SELF%/*}
TMUX_BIN=${IMUX_BENCH_TMUX:-$(command -v tmux 2>/dev/null)}
BASH_BIN=$(command -v bash 2>/dev/null)

DEFAULT_SCENARIOS=(first-frame list list-bash preview-S preview-W preview-P hint footer
                   describe-create session-name-for dirs-list dirs-deep dirs-preview doctor)
EXTRA_SCENARIOS=(first-frame-bash hint-ladder scope-prompt parse)

CLIENT_COLS=200 CLIENT_ROWS=50          # the attached client
POPUP_COLS=158 POPUP_ROWS=35            # 80% x 75% of it, minus the popup border
PV_NAV_COLS=76 PV_NAV_LEFT=81           # --preview-window right,50%,border-left
PV_DIRS_COLS=60 PV_DIRS_LEFT=97         # --preview-window right,40%,border-left

N_PAIRS=30 N_SET=0 WARM=2 BUDGET="" OUT_TSV="" KEEP=0 QUIET=0 ALLOW_STALE=0 EXEC_CMD="" CONFIRM=1
SCN_ARG=""

usage() { sed -n '3,4p' "$BENCH_SELF" | sed 's/^# \{0,1\}//'; echo "see the header of $BENCH_SELF"; }
die() { printf 'bench: %s\n' "$*" >&2; exit 1; }
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n) N_PAIRS=${2:?}; N_SET=1; shift 2 ;;
    -s) SCN_ARG=${2:?}; shift 2 ;;
    -w) WARM=${2:?}; shift 2 ;;
    -b) BUDGET=${2:?}; shift 2 ;;
    -o) OUT_TSV=${2:?}; shift 2 ;;
    -K) KEEP=1; shift ;;
    -q) QUIET=1; shift ;;
    --allow-stale) ALLOW_STALE=1; shift ;;
    --no-confirm) CONFIRM=0; shift ;;
    --exec) EXEC_CMD=${2:?}; shift 2 ;;
    --list)
      printf 'default: %s\nextra:   %s\n' "${DEFAULT_SCENARIOS[*]}" "${EXTRA_SCENARIOS[*]}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) usage >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || { usage >&2; exit 2; }
[[ "$N_PAIRS" =~ ^[1-9][0-9]*$ ]] || die "-n wants a positive integer"
[[ "$WARM" =~ ^[0-9]+$ ]] || die "-w wants a non-negative integer"
if [ -z "$BUDGET" ] && [ "$N_SET" = 0 ]; then BUDGET=25; fi
[ -z "$BUDGET" ] || [[ "$BUDGET" =~ ^[0-9]+$ ]] || die "-b wants seconds"

# --- the worktrees -----------------------------------------------------------
check_worktree() { # $1 = path -> prints the absolute path
  local w
  w=$(cd "$1" 2>/dev/null && pwd -P) || die "no such worktree: $1"
  [ -f "$w/scripts/interdimux.sh" ] || die "$w: no scripts/interdimux.sh"
  local bin="$w/rust/target/release/imux"
  [ -x "$bin" ] || die "$w: rust/target/release/imux is not built (cd $w/rust && cargo build --release)"
  if [ "$ALLOW_STALE" = 0 ] \
     && [ -n "$(find "$w/rust/src" "$w/rust/Cargo.toml" -type f -newer "$bin" 2>/dev/null | head -1)" ]; then
    die "$w: rust/target/release/imux is older than rust/src -- rebuild it (cargo build --release), or pass --allow-stale"
  fi
  printf '%s' "$w"
}
WT_A=$(check_worktree "$1") || exit 1
WT_B=$(check_worktree "$2") || exit 1

[ -n "$TMUX_BIN" ] && [ -x "$TMUX_BIN" ] || die "no tmux (${TMUX_BIN:-none on PATH}): put one on PATH or set IMUX_BENCH_TMUX"
TMUX_BIN=$(readlink -f "$TMUX_BIN")
[ -n "$BASH_BIN" ] || die "no bash on PATH"
command -v setsid >/dev/null 2>&1 || die "setsid (util-linux) is needed for the watchdog"
command -v cc >/dev/null 2>&1 || die "a C compiler (cc) is needed for the runner"
command -v git >/dev/null 2>&1 || die "git is needed for the fixture"
command -v perl >/dev/null 2>&1 || die "perl is needed for the fixture"
# zoxide: the ctrl-o picker's frecent rows and their cost.  Without one the
# dirs-* scenarios measure a picker that a zoxide user never sees.
ZOXIDE_BIN=${IMUX_PERF_ZOXIDE:-$(command -v zoxide 2>/dev/null)}
ZOXIDE_WARN=""
if [ -n "$ZOXIDE_BIN" ] && [ -x "$ZOXIDE_BIN" ]; then
  ZOXIDE_BIN=$(readlink -f "$ZOXIDE_BIN")
else
  ZOXIDE_WARN="WARNING: no zoxide (${IMUX_PERF_ZOXIDE:-none on PATH}; IMUX_PERF_ZOXIDE names one): the dirs-* and describe-create scenarios ran without zoxide's rows and its exec"
  ZOXIDE_BIN=""
  [ "${IMUX_PERF_STRICT:-0}" != 1 ] || die "no zoxide (${IMUX_PERF_ZOXIDE:-none on PATH}), and IMUX_PERF_STRICT=1 wants one: set IMUX_PERF_ZOXIDE"
  say "bench: $ZOXIDE_WARN"
fi
REAL_FZF=$(command -v fzf 2>/dev/null) || REAL_FZF=""
FZF_VERSION_STR="0.74.3 (bench)"
[ -n "$REAL_FZF" ] && FZF_VERSION_STR=$("$REAL_FZF" --version 2>/dev/null | head -1)
FZF_MINOR=74
if [[ "$FZF_VERSION_STR" =~ ^([0-9]+)\.([0-9]+) ]]; then
  FZF_MINOR=${BASH_REMATCH[2]}; [ "${BASH_REMATCH[1]}" -gt 0 ] && FZF_MINOR=999
fi
TMUX_VNUM=999
if [[ "$("$TMUX_BIN" -V 2>/dev/null)" =~ ([0-9]+)\.([0-9]+) ]]; then
  TMUX_VNUM=$(( BASH_REMATCH[1] * 100 + BASH_REMATCH[2] ))
fi

# --- scenarios -----------------------------------------------------------------
SCENARIOS=()
if [ -z "$SCN_ARG" ]; then SCENARIOS=("${DEFAULT_SCENARIOS[@]}")
else
  IFS=, read -r -a _req <<< "$SCN_ARG"
  for s in "${_req[@]}"; do
    [ -n "$s" ] || continue
    if [ "$s" = all ]; then SCENARIOS+=("${DEFAULT_SCENARIOS[@]}" "${EXTRA_SCENARIOS[@]}"); continue; fi
    case " ${DEFAULT_SCENARIOS[*]} ${EXTRA_SCENARIOS[*]} " in
      *" $s "*) SCENARIOS+=("$s") ;;
      *) die "unknown scenario '$s' (see --list)" ;;
    esac
  done
fi
[ "${#SCENARIOS[@]}" -gt 0 ] || die "no scenarios"

# --- work dir, cleanup -------------------------------------------------------------
BENCH_ID="imux-bench-$$"
SOCK="$BENCH_ID"
OSOCK="$BENCH_ID-outer"
_root="${IMUX_BENCH_WORKROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$_root" 2>/dev/null && [ -w "$_root" ] || die "the work root $_root is not writable (IMUX_BENCH_WORKROOT)"
WORK="$(cd "$_root" && pwd -P)/$BENCH_ID"
rm -rf "${WORK:?}"; mkdir -p "$WORK" || die "cannot create $WORK"
FIX="$WORK/fix"
RUNNER="$WORK/bin/benchrun"
HOLDER_PIDS=()
SRV_PID=""
CLEANED=0

marked_pids() { # every process whose environment carries this run's id (builtins only)
  local p v
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    { while IFS= read -r -d '' v; do
        [ "$v" = "IMUX_BENCH_ID=$BENCH_ID" ] && { printf '%s\n' "${p#/proc/}"; break; }
      done < "$p/environ"; } 2>/dev/null
  done
  return 0
}
kill_marked() {
  local p
  for p in $(marked_pids); do kill -9 "$p" 2>/dev/null; done
  return 0
}

cleanup() {
  [ "$CLEANED" = 1 ] && return; CLEANED=1
  trap '' INT TERM HUP
  local f p i
  [ -n "${WATCHDOG:-}" ] && { kill -- -"$WATCHDOG" 2>/dev/null || kill "$WATCHDOG" 2>/dev/null; }
  # release the holding stub fzfs, newest first (the dirs pickers, then navigators)
  for f in "$WORK"/hold/*.ready; do [ -e "$f" ] && : > "${f%.ready}.release"; done
  for p in "${HOLDER_PIDS[@]}"; do
    for i in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.02; done
    kill "$p" 2>/dev/null
  done
  "$TMUX_BIN" -L "$OSOCK" kill-server 2>/dev/null
  "$TMUX_BIN" -L "$SOCK" kill-server 2>/dev/null
  for i in $(seq 1 50); do
    [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null || break; sleep 0.02
  done
  kill_marked
  # tmux 3.7 leaves the socket file behind after kill-server
  rm -f "/tmp/tmux-$(id -u)/$SOCK" "/tmp/tmux-$(id -u)/$OSOCK" 2>/dev/null
  if [ "$KEEP" = 1 ]; then say "kept: $WORK"; else case "$WORK" in */imux-bench-[0-9]*) rm -rf "${WORK:?}" ;; esac; fi
}
trap cleanup EXIT
trap 'say "interrupted"; exit 130' INT TERM HUP

# A trap cannot survive SIGKILL -- which is what a tool's timeout may send to
# the whole process group.  So a watchdog in a session of its own waits for this
# shell to die and then does the same cleanup; the normal path kills it first.
# It does not carry IMUX_BENCH_ID, so its own sweep cannot kill it.
setsid bash -c '
  bench=$1 osock=$2 sock=$3 work=$4 keep=$5 tmuxbin=$6 id=$7
  while kill -0 "$bench" 2>/dev/null; do sleep 1; done
  "$tmuxbin" -L "$osock" kill-server 2>/dev/null
  "$tmuxbin" -L "$sock" kill-server 2>/dev/null
  sleep 0.5
  for p in /proc/[0-9]*; do
    { while IFS= read -r -d "" v; do
        [ "$v" = "IMUX_BENCH_ID=$id" ] && { kill -9 "${p#/proc/}"; break; }
      done < "$p/environ"; } 2>/dev/null
  done
  rm -f "/tmp/tmux-$(id -u)/$sock" "/tmp/tmux-$(id -u)/$osock"
  if [ "$keep" != 1 ]; then case "$work" in */imux-bench-[0-9]*) rm -rf "$work" ;; esac; fi
' imux-bench-watchdog $$ "$OSOCK" "$SOCK" "$WORK" "$KEEP" "$TMUX_BIN" "$BENCH_ID" </dev/null >/dev/null 2>&1 &
WATCHDOG=$!

# --- the runner -----------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/stub" "$WORK/tools" "$WORK/hold" "$WORK/out" "$WORK/res"
cc -O2 -o "$RUNNER" "$BENCH_HOME/benchrun.c" 2> "$WORK/cc.log" || { cat "$WORK/cc.log" >&2; die "cannot compile benchrun.c"; }
ln -s "$RUNNER" "$WORK/stub/fzf"
# the tmux and bash this shell found, first on the fixture's PATH
ln -s "$TMUX_BIN" "$WORK/tools/tmux"
ln -s "$BASH_BIN" "$WORK/tools/bash"
for c in at atq atrm batch; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/stub/at.log"\nexit 0\n' "$c" "$WORK" > "$WORK/stub/$c"
  chmod +x "$WORK/stub/$c"
done

# --- load ---------------------------------------------------------------------------
load1() { local a _; read -r a _ < /proc/loadavg; printf '%s' "$a"; }
hogs() { # prints warnings for processes over 50% of a CPU (ours excluded)
  local pid pct comm out=""
  while read -r pid pct comm; do
    [ -n "$pid" ] || continue
    grep -qz "IMUX_BENCH_ID=$BENCH_ID" "/proc/$pid/environ" 2>/dev/null && continue
    out+="    pid $pid ($comm) at ${pct}% CPU"$'\n'
  done < <("$RUNNER" hogs 1000 50 2>/dev/null)
  printf '%s' "$out"
}
LOAD_START=$(load1)
HOGS_START=$(hogs)

# =====================================================================================
# The fixture
# =====================================================================================
H="$FIX/home"
export_fixture_env() {
  SRV_ENV=(
    HOME="$H" USER="${USER:-bench}" LOGNAME="${LOGNAME:-bench}" SHELL=/bin/bash
    LANG=C.UTF-8 TERM=xterm-256color
    PATH="$WORK/stub:$WORK/tools:$FIX/bin:/usr/local/bin:/usr/bin:/bin"
    TMPDIR="$FIX/tmp"
    XDG_CONFIG_HOME="$FIX/config" XDG_DATA_HOME="$FIX/data" XDG_STATE_HOME="$FIX/state"
    XDG_CACHE_HOME="$FIX/cache" XDG_RUNTIME_DIR="$FIX/run"
    _ZO_DATA_DIR="$FIX/zoxide"
    IMUX_BENCH_ID="$BENCH_ID"
  )
}

GIT_ENV=(HOME="$H" GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=bench GIT_AUTHOR_EMAIL=bench@example.invalid
         GIT_COMMITTER_NAME=bench GIT_COMMITTER_EMAIL=bench@example.invalid
         GIT_AUTHOR_DATE='2026-09-01T12:00:00Z' GIT_COMMITTER_DATE='2026-09-01T12:00:00Z')
mk_repo() { # dir kind branch dirty
  local d="$H/src/$1" kind="$2" br="$3" dirty="$4"
  mkdir -p "$d/src" "$d/docs" "$d/tests"
  case "$kind" in
    rust) printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "$1" > "$d/Cargo.toml"; echo 'fn main() {}' > "$d/src/main.rs" ;;
    node) printf '{ "name": "%s", "version": "1.0.0" }\n' "$1" > "$d/package.json"; echo 'export {}' > "$d/src/index.ts" ;;
    go)   printf 'module example.com/%s\n\ngo 1.22\n' "$1" > "$d/go.mod"; echo 'package main' > "$d/src/main.go" ;;
    py)   printf '[project]\nname = "%s"\n' "$1" > "$d/pyproject.toml"; echo 'print(1)' > "$d/src/train.py" ;;
    *)    echo 'all:' > "$d/Makefile" ;;
  esac
  printf '# %s\n\nThe %s service: what it does, in one line.\n' "$1" "$1" > "$d/README.md"
  for i in 1 2 3 4 5 6; do echo "notes $i" > "$d/docs/n$i.md"; done
  env -i "${GIT_ENV[@]}" PATH=/usr/bin:/bin git -C "$d" init -q -b main \
    && env -i "${GIT_ENV[@]}" PATH=/usr/bin:/bin git -C "$d" add -A \
    && env -i "${GIT_ENV[@]}" PATH=/usr/bin:/bin git -C "$d" commit -q -m "initial import of $1" \
    && env -i "${GIT_ENV[@]}" PATH=/usr/bin:/bin git -C "$d" checkout -q -b "$br" \
    || die "git failed in $d"
  if [ "$dirty" = 1 ]; then
    echo '// wip' >> "$d/README.md"; echo 'scratch' > "$d/TODO.txt"
  fi
}

build_dirs() {
  mkdir -p "$FIX"/{bin,tmp,config,data/interdimux,state,cache,zoxide,panes} "$H" "$FIX/run"
  chmod 700 "$FIX/run"
  mk_repo api-gateway       go   feature/rate-limits 1
  mk_repo frontend-monorepo node feat/new-nav       1
  mk_repo dotfiles          make main-2026          0
  mk_repo infra-terraform   make chore/upgrade-aws  0
  mk_repo ml-experiments    py   exp/sweep-lr       0
  mk_repo blog              node draft/perf-post    0
  mk_repo notes-vault       make sync              0
  mk_repo k8s-manifests     make release/1.42       0
  # ~/work: the project tree the deep search walks.  10 teams x 10 svc-* dirs
  # (the "svc" query matches all 100), each with src/ and docs/, a third of
  # them project roots.
  local t s d i=0
  for t in 01 02 03 04 05 06 07 08 09 10; do
    for s in a b c d e f g h i j; do
      d="$H/work/team-$t/svc-$t$s"
      mkdir -p "$d/src" "$d/docs"
      case $(( i % 3 )) in
        0) echo '[package]' > "$d/Cargo.toml" ;;
        1) echo '{}' > "$d/package.json" ;;
      esac
      i=$((i + 1))
    done
  done
  mkdir -p "$H/work/sandbox" "$H/work/archive/2025" "$H/Downloads" "$H/.claude/sessions"
  # tools the panes and the script look up, where the fixture's PATH would
  # not find them: fd (in ~/.cargo/bin, say) and zoxide (the dev image's is
  # off the PATH: $IMUX_PERF_ZOXIDE)
  local p
  p=$(command -v fd 2>/dev/null) && case "$p" in /usr/bin/*|/bin/*|/usr/local/bin/*) ;; *) ln -s "$p" "$FIX/bin/fd" ;; esac
  [ -n "$ZOXIDE_BIN" ] && ln -s "$ZOXIDE_BIN" "$FIX/bin/zoxide"
  # recent dirs: most recent first, two that no longer exist
  {
    printf '%s\n' "$H/src/frontend-monorepo" "$H/src/api-gateway" "$H/work/team-03/svc-03c" \
      "$H/src/ml-experiments" "$H/gone-project" "$H/src/k8s-manifests" "$H/work/team-07/svc-07a" \
      "$H/src/blog" "$H/src/dotfiles" "$H/work/sandbox" "$H/old/removed" "$H/src/notes-vault"
  } > "$FIX/data/interdimux/recent_dirs"
  # zoxide: ~50 dirs, some visited more often than others
  if [ -x "$FIX/bin/zoxide" ]; then
    local z=() n
    for d in "$H"/src/*; do z+=("$d" "$d" "$d"); done
    n=0
    for d in "$H"/work/team-*/svc-*; do
      n=$((n + 1)); case $(( n % 5 )) in 1|3) ;; *) continue ;; esac
      z+=("$d"); [ $(( n % 7 )) = 1 ] && z+=("$d")
    done
    z+=("$H/work/sandbox" "$H/work/archive/2025" "$H/Downloads")
    for d in "${z[@]}"; do
      env -i HOME="$H" _ZO_DATA_DIR="$FIX/zoxide" PATH="$FIX/bin:/usr/local/bin:/usr/bin:/bin" zoxide add -- "$d" \
        || die "zoxide add failed"
    done
    ZOX_N=$(env -i HOME="$H" _ZO_DATA_DIR="$FIX/zoxide" PATH="$FIX/bin:/usr/local/bin:/usr/bin:/bin" zoxide query --list | wc -l)
  else
    ZOX_N=0
  fi
  # What the panes show: deterministic, styled screens, so a preview's
  # capture-pane has real work to do (an empty pane is "(cannot capture pane)").
  cat > "$FIX/panes/draw" <<'EOF'
#!/bin/bash
# $1 = what to draw
e=$'\033'
case "$1" in
  logs)
    for i in $(seq 1 45); do
      printf '%s[2m2026-09-01T12:%02d:%02dZ%s[0m %s[32mINFO%s[0m  GET /api/v1/users/%d %s[36m200%s[0m %dms req=%08x\n' \
        "$e" $((i / 60)) $((i % 60)) "$e" "$e" "$e" $((i * 37)) "$e" "$e" $((i % 17 + 3)) $((i * 2654435761 % 4294967296))
    done ;;
  code)
    for i in $(seq 1 40); do
      printf '%s[33m%4d%s[0m  %s[35mfn%s[0m handler_%d(req: %s[32m&Request%s[0m) -> Result<Response> { %s[2m// %d%s[0m\n' \
        "$e" "$i" "$e" "$e" "$e" "$i" "$e" "$e" "$e" "$i" "$e"
    done ;;
  train)
    for i in $(seq 1 30); do
      printf 'epoch %3d/300  loss=%s[1m0.%04d%s[0m  lr=3e-4  [%-30s] %3d%%\n' "$i" "$e" $((9000 - i * 97)) "$e" "$(printf '%*s' $((i % 30)) '' | tr ' ' '#')" $((i * 3))
    done ;;
  table)
    printf '%s[7m  PID USER      PR  NI    VIRT    RES  %%CPU %%MEM  COMMAND%40s%s[0m\n' "$e" '' "$e"
    for i in $(seq 1 30); do
      printf '%5d bench     20   0  %6dk %6dk  %4.1f  %3.1f  %s\n' $((1000 + i * 7)) $((i * 4096)) $((i * 512)) "$((i % 10)).$((i % 7))" "0.$((i % 9))" "worker-$i --queue=q$((i % 4))"
    done ;;
  claude)
    printf '%s[38;5;174m╭──────────────────────────────────────────────╮%s[0m\n' "$e" "$e"
    printf '%s[38;5;174m│%s[0m ✻ Welcome to Claude Code!                    %s[38;5;174m│%s[0m\n' "$e" "$e" "$e" "$e"
    printf '%s[38;5;174m╰──────────────────────────────────────────────╯%s[0m\n\n' "$e" "$e"
    for i in $(seq 1 12); do
      printf '%s[1m⏺%s[0m Read(%s[36msrc/handlers/h%02d.rs%s[0m)\n  ⎿  Read %d lines (ctrl+r to expand)\n\n' "$e" "$e" "$e" "$i" "$e" $((i * 23))
    done
    printf '%s[33m Do you want to make this edit to src/main.rs?%s[0m\n ❯ 1. Yes\n   2. No\n' "$e" "$e" ;;
  shell)
    printf '%s[32mbench@box%s[0m:%s[34m~/src%s[0m$ git status\nOn branch feature/x\nChanges not staged for commit:\n' "$e" "$e" "$e" "$e"
    for i in $(seq 1 12); do printf '\t%s[31mmodified:   src/module_%02d.rs%s[0m\n' "$e" "$i" "$e"; done
    printf '\n%s[32mbench@box%s[0m:%s[34m~/src%s[0m$ ls\n' "$e" "$e" "$e" "$e"
    printf 'Cargo.toml  README.md  docs  src  target  tests\n' ;;
esac
EOF
  # fake agents -- never a real CLI
  cat > "$FIX/panes/claude" <<EOF
#!/bin/bash
printf '\033]0;✳ Claude Code\007'
"$FIX/panes/draw" claude
exec -a claude sleep 86400
EOF
  cat > "$FIX/panes/codex" <<EOF
#!/bin/bash
printf '\033]0;[ ! ] Action Required | Add tests | proj\007'
"$FIX/panes/draw" claude
exec perl -e '\$0 = "node /opt/lib/node_modules/@openai/codex/bin/codex resume"; sleep 86400'
EOF
  cat > "$FIX/panes/cct" <<EOF
#!/bin/bash
printf '\033]0;✳ Claude Code\007'
"$FIX/panes/draw" shell
exec bash --norc --noprofile -i
EOF
  cat > "$FIX/panes/shl" <<EOF
#!/bin/bash
"$FIX/panes/draw" shell
exec bash --norc --noprofile -i
EOF
  cat > "$FIX/panes/ssh" <<EOF
#!/bin/bash
printf '\033]0;deploy@web1: ~/src\007'
"$FIX/panes/draw" logs
exec perl -e '\$0 = "ssh web1"; sleep 86400'
EOF
  local k
  for k in "ed:code:nvim src/main.rs" "py:train:python3 train.py --lr 3e-4" "tail:logs:tail -f logs/app.log" \
           "top:table:htop" "srv:logs:node server.js" "k9s:table:k9s" "watch:table:watch -n2 kubectl get pods"; do
    printf '#!/bin/bash\n"%s/panes/draw" %s\nexec perl -e '"'"'$0 = "%s"; sleep 86400'"'"'\n' \
      "$FIX" "$(cut -d: -f2 <<< "$k")" "${k#*:*:}" > "$FIX/panes/${k%%:*}"
  done
  chmod +x "$FIX"/panes/*
}

# Pane kind -> what tmux reports as its command once it has settled.
kind_cmd() {
  case "$1" in
    sh|shl|cct) REPLY=bash ;; ed) REPLY=nvim ;; py) REPLY=python3 ;; tail) REPLY='tail' ;;
    top) REPLY=htop ;; srv|codex) REPLY=node ;; k9s) REPLY=k9s ;; watch) REPLY=watch ;;
    ssh) REPLY=ssh ;; claude) REPLY=claude ;; *) REPLY="?" ;;
  esac
}

# session|dir|window;window...   window = name[@dir]=kind,kind,...
LAYOUT=(
  "api-gateway-production-eu-west-1|src/api-gateway|editor=ed,shl;server=srv,tail,sh,sh;tests=shl,sh;git=shl,sh"
  "frontend-monorepo|src/frontend-monorepo|editor=ed,shl,sh,sh;dev=srv,shl,sh;storybook=srv;tests=shl,sh;shell=shl,sh"
  "dotfiles|src/dotfiles|main=ed,shl,sh;sync=shl,sh"
  "infra-terraform|src/infra-terraform|plan=shl,sh;apply=shl,sh;state=sh,sh"
  "ml-experiments-2026-q3-hyperparameter-sweep|src/ml-experiments|train=py,top;notebook=shl,sh;data=sh,sh;eval=py,sh"
  "blog|src/blog|write=ed,sh;serve=srv,shl"
  "notes|src/notes-vault|notes=ed,sh"
  "k8s|src/k8s-manifests|prod=ssh,watch,sh;staging=ssh,shl;k9s=k9s;logs=tail,tail,sh,sh"
  "agents|src/api-gateway|claude=claude,shl;codex@src/frontend-monorepo=codex,sh;review@src/ml-experiments=cct,sh"
  "scratch|.|s1=shl,sh;s2=sh,sh;tmp@Downloads=sh,sh"
  "a|.|main=sh,sh"
  "ops|work|w0=shl,sh,sh,sh;w1=sh,shl,sh;w2=top;w3=ssh,sh;w4=sh,sh;w5@work/sandbox=shl,sh;w6=tail,sh;w7=sh,sh,sh"
)
CUR_SESSION=frontend-monorepo
EXPECT_CMDS=()
EXPECT_TITLES=0

tm() { "$TMUX_BIN" -L "$SOCK" "$@"; }

start_server() {
  local args=() line sess dir wins w wname wdir kinds k idx np cmd
  # The server first, with a placeholder session, so the options are in place
  # before any pane starts; then one command list per session (a tmux client
  # command has a size cap, so the whole layout cannot go in one).
  # shellcheck disable=SC2088  # the tilde is tmux's and the script's to expand, as in the README
  ( cd "$H" && exec env -i "${SRV_ENV[@]}" "$TMUX_BIN" -L "$SOCK" -f /dev/null \
    new-session -d -s __boot -x "$CLIENT_COLS" -y "$CLIENT_ROWS" 'exec sleep 86400' \; \
    set -g default-command 'bash --norc --noprofile -i' \; \
    set -g @interdimux-project-dirs '~/work:~/src' ) \
    || die "the fixture server did not start"
  SRV_PID=$(tm display-message -p '#{pid}') || die "no fixture server pid"
  for line in "${LAYOUT[@]}"; do
    args=()
    IFS='|' read -r sess dir wins <<< "$line"
    IFS=';' read -r -a w <<< "$wins"
    idx=0
    for wname in "${w[@]}"; do
      kinds=${wname#*=}; wname=${wname%%=*}
      wdir=$dir
      case "$wname" in *@*) wdir=${wname#*@}; wname=${wname%%@*} ;; esac
      wdir="$H/$wdir"; wdir=${wdir%/.}
      IFS=, read -r -a k <<< "$kinds"
      np=0
      for kind in "${k[@]}"; do
        cmd=(); [ "$kind" = sh ] || cmd=("$FIX/panes/$kind")
        kind_cmd "$kind"; EXPECT_CMDS+=("$REPLY")
        case "$kind" in claude|cct) EXPECT_TITLES=$((EXPECT_TITLES + 1)) ;; esac
        if [ "$np" = 0 ] && [ "$idx" = 0 ]; then
          args+=(new-session -d -s "$sess" -n "$wname" -x "$CLIENT_COLS" -y "$CLIENT_ROWS" -c "$wdir" "${cmd[@]}" \;)
        elif [ "$np" = 0 ]; then
          args+=(new-window -d -t "=$sess:" -n "$wname" -c "$wdir" "${cmd[@]}" \;)
        else
          args+=(split-window -d -t "=$sess:=$idx.0" -c "$wdir" "${cmd[@]}" \;
                 select-layout -t "=$sess:=$idx" tiled \;)
        fi
        np=$((np + 1))
      done
      idx=$((idx + 1))
    done
    tm "${args[@]}" display-message -p '' >/dev/null || die "the fixture session $sess did not start"
  done
  tm kill-session -t =__boot
  tm set -p -t '=ops:=3.1' @pane_status running >/dev/null || die "cannot set a pane option"
  tm set -g @interdimux-bench "$BENCH_ID"
}

# Settled: every pane has a cwd and has become its final process, the titled
# ones carry their title, and every idle shell has drawn its prompt (cursor_x > 0,
# so a preview's capture of it no longer changes).
settled() {
  local got want l
  got=$(tm list-panes -a -F '#{pane_current_command}' | sort | tr '\n' ' ')
  want=$(printf '%s\n' "${EXPECT_CMDS[@]}" | sort | tr '\n' ' ')
  [ "$got" = "$want" ] || return 1
  l=$(tm list-panes -a -F '#{?pane_current_path,,nocwd}#{?#{==:#{pane_current_command},bash},#{?#{==:#{cursor_x},0},noprompt,},}' | tr -d '\n')
  [ -z "$l" ] || return 1
  [ "$(tm list-panes -a -F '#{pane_title}' | grep -c '✳ Claude Code')" = "$EXPECT_TITLES" ] || return 1
}
wait_settled() {
  local i ok=0 prev="" cur stable=0
  for i in $(seq 1 300); do settled && { ok=1; break; }; sleep 0.05; done
  if [ "$ok" = 0 ]; then
    tm list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command} x=#{cursor_x} [#{pane_title}]' >&2
    die "the fixture panes never settled"
  fi
  # ...and every screen has stopped changing (tmux reads pane output
  # asynchronously): the cursors and history sizes agree three polls running.
  for i in $(seq 1 100); do
    cur=$(tm list-panes -a -F '#{pane_id}:#{cursor_x},#{cursor_y},#{history_size}' | tr '\n' ' ')
    if [ "$cur" = "$prev" ]; then stable=$((stable + 1)); [ "$stable" -ge 3 ] && return 0; else stable=0; fi
    prev=$cur; sleep 0.1
  done
  die "the fixture screens never stopped changing"
}

attach_client() {
  # A real popup has a client behind it.  The outer server's pane runs the
  # client, 200x50, attached to $CUR_SESSION.
  ( cd "$H" && exec env -i "${SRV_ENV[@]}" "$TMUX_BIN" -L "$OSOCK" -f /dev/null \
    new-session -d -s host -x "$CLIENT_COLS" -y "$CLIENT_ROWS" \
    "exec env -u TMUX -u TMUX_PANE '$TMUX_BIN' -L '$SOCK' attach -t '=$CUR_SESSION'" \; \
    set -g status off ) \
    || die "the outer server did not start"
  local i
  for i in $(seq 1 200); do
    CLIENT_NAME=$(tm list-clients -F '#{client_name}' 2>/dev/null | head -1)
    [ -n "$CLIENT_NAME" ] && break; sleep 0.025
  done
  [ -n "$CLIENT_NAME" ] || die "the client never attached"
  CUR_PANE=$(tm display-message -p -t "=$CUR_SESSION:" '#{pane_id}')
}

claude_record() {
  local pid pane st
  pid=$(tm display-message -p -t '=agents:=0.0' '#{pane_pid}')
  pane=$(tm display-message -p -t '=agents:=0.0' '#{pane_id}')
  read -r -a st < "/proc/$pid/stat"
  printf '{"pid":%s,"sessionId":"bench","cwd":"%s","startedAt":1,"procStart":"%s","version":"2.1.281","kind":"interactive","entrypoint":"cli","tmux":"agents:@1.%s","name":"n","status":"waiting","waitingFor":"permission prompt","statusUpdatedAt":%s}' \
    "$pid" "$H/src/api-gateway" "${st[21]}" "$pane" "$(( (NOW_PIN - 300) * 1000 ))" > "$H/.claude/sessions/$pid.json"
}

# =====================================================================================
# Environments
# =====================================================================================
# The popup's: the server's global environment, TERM, TMUX, and the -e list the
# prefix+f binding passes -- every OPT_MAP option (unset ones expand to ""),
# OPTS_PRIMED, the pane and client, the versions and the title.  The OPT_MAP is
# read from each worktree's own script, as its --bind-keys would.
popup_env() { # $1 = worktree, $2 = name of the array to fill, $3... = extra VAR=value
  local wt="$1"; local -n _pe="$2"; shift 2
  local -a opts=() vals=() srv=()
  mapfile -d '' -t opts < <(bash -c 'eval "$(sed -n "/^OPT_MAP=(/,/^)/p" "$1")" || exit 1
    for m in "${OPT_MAP[@]}"; do printf "%s\0" "$m"; done' _ "$wt/scripts/interdimux.sh")
  [ "${#opts[@]}" -gt 0 ] || die "$wt: cannot read OPT_MAP from the script"
  local fmt="" m
  for m in "${opts[@]}"; do fmt+="#{@interdimux-${m%%:*}}"$'\x1f'; done
  IFS=$'\x1f' read -r -a vals <<< "$(tm display-message -p -t "$CUR_PANE" "$fmt")"
  # TERM and TMUX are the popup's own (below), not the server's
  mapfile -t srv < <(tm show-environment -g | grep -v -e '^-' -e '^TERM=' -e '^TMUX=' -e '^TMUX_PANE=')
  _pe=("${srv[@]}" TERM="$(tm show -gv default-terminal)" TMUX="$SOCK_PATH,99999,0")
  local i=0
  for m in "${opts[@]}"; do _pe+=("INTERDIMUX_${m#*:}=${vals[i]:-}"); i=$((i + 1)); done
  _pe+=(INTERDIMUX_OPTS_PRIMED=1 TMUX_PANE="$CUR_PANE" INTERDIMUX_CLIENT="$CLIENT_NAME"
        INTERDIMUX_TMUX_VNUM="$TMUX_VNUM" INTERDIMUX_FZF_MINOR="$FZF_MINOR"
        "INTERDIMUX_TITLE= interdimux · $CUR_SESSION "
        INTERDIMUX_NOW="$NOW_PIN" BENCH_FZF_VERSION="$FZF_VERSION_STR" BENCH_PID=$$ "$@")
}

# What fzf 0.74 exports to a child, as recorded from the real navigator under
# the real fzf in a 158x35 pty (a `bash` wrapper first on PATH logged every
# callback's environment).  The preview variables, and COLUMNS/LINES, exist
# only for a preview command or while the preview window is shown.
# $1 = array to fill; $2 = picker (nav | dirs); then key action query matches
# total item preview(0|1) [raw]
fzf_env() {
  local -n _fe="$1"
  local picker="$2" key="$3" action="$4" q="$5" mc="$6" tc="$7" item="$8" pv="$9" raw="${10:-1}"
  local ghost nth wnth prompt pvc pvl
  if [ "$picker" = nav ]; then
    ghost='session · window · pane' nth=1,3 wnth=1..3 prompt='❯ ' pvc=$PV_NAV_COLS pvl=$PV_NAV_LEFT
  else
    ghost='directory name or path' nth=1 wnth=1..2 prompt='new session ❯ ' pvc=$PV_DIRS_COLS pvl=$PV_DIRS_LEFT
  fi
  _fe=(FZF_ACTION="$action" FZF_BORDER_LABEL= FZF_CLICK_FOOTER_COLUMN=0 FZF_CLICK_FOOTER_LINE=0
       FZF_CLICK_HEADER_COLUMN=0 FZF_CLICK_HEADER_LINE=0 FZF_COLUMNS="$POPUP_COLS" FZF_LINES="$POPUP_ROWS"
       FZF_CURRENT_ITEM="$item" FZF_DIRECTION=down FZF_GHOST="$ghost" FZF_HEADER_LABEL= FZF_IDLE_TIME=0
       FZF_IDLE_TIME_MS=0 FZF_INPUT_LABEL= FZF_INPUT_STATE=enabled FZF_KEY="$key" FZF_LIST_LABEL=
       FZF_MATCH_COUNT="$mc" FZF_NTH="$nth" FZF_POINTER=▌ FZF_POS=1 FZF_PREVIEW_LABEL= FZF_PROMPT="$prompt"
       FZF_QUERY="$q" FZF_RAW="$raw" FZF_SELECT_COUNT=0 FZF_TOTAL_COUNT="$tc" FZF_WITH_NTH="$wnth")
  if [ "$pv" = 1 ]; then
    _fe+=(FZF_PREVIEW_COLUMNS="$pvc" FZF_PREVIEW_LINES="$POPUP_ROWS" FZF_PREVIEW_LEFT="$pvl"
          FZF_PREVIEW_TOP=0 COLUMNS="$pvc" LINES="$POPUP_ROWS")
  fi
  return 0
}

# A holder: the real navigator (or ctrl-o picker) run to the point where it
# execs fzf, with a stub fzf that records what it was handed and then waits.
start_holder() { # $1 = name, $2 = env array name, $3... = command
  local name="$1"; local -n _he="$2"; shift 2
  local out="$WORK/hold/$name" i
  env -i "${_he[@]}" BENCH_FZF_MODE=hold BENCH_FZF_OUT="$out" \
    "$RUNNER" run -t "${POPUP_COLS}x${POPUP_ROWS}" -p -o "$out.pty" -r "$out.result" -s 0 -- "$@" &
  HOLDER_PIDS+=($!)
  for i in $(seq 1 1500); do
    [ -e "$out.ready" ] && return 0
    if [ -s "$out.result" ]; then break; fi
    sleep 0.02
  done
  printf 'bench: holder %s never reached fzf.  Its terminal:\n' "$name" >&2
  sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$out.pty" 2>/dev/null | tail -20 >&2
  cat "$FIX"/run/interdimux-resume.*.err 2>/dev/null | tail -20 >&2
  die "holder $name failed (result: $(cat "$out.result" 2>/dev/null))"
}
holder_env() { # $1 = holder name, $2 = array to fill: its recorded env, BENCH_FZF_* removed
  local -n _ce="$2"; local -a raw=(); local v
  mapfile -d '' -t raw < "$WORK/hold/$1.env"
  _ce=()
  for v in "${raw[@]}"; do case "$v" in BENCH_FZF_MODE=*|BENCH_FZF_OUT=*) ;; *) _ce+=("$v") ;; esac; done
}
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g' "$@"; }

# The focus bind's snippet, as the navigator built it: the text after
# transform-footer:/transform-header: (or inside its parentheses).
focus_snippet() { # $1 = holder name -> REPLY (empty when not found)
  local -a argv=(); local a s=""
  mapfile -d '' -t argv < "$WORK/hold/$1.args"
  for a in "${argv[@]}"; do
    case "$a" in --bind=focus:*) s=${a#--bind=focus:} ;; esac
  done
  REPLY=""
  [ -n "$s" ] || return 1
  if [[ "$s" =~ transform-(footer|header):(.*)$ ]]; then REPLY=${BASH_REMATCH[2]}
  elif [[ "$s" =~ transform-(footer|header)\((.*)\)$ ]]; then REPLY=${BASH_REMATCH[2]}
  fi
  [ -n "$REPLY" ]
}
# fzf's placeholder expansion for the two the snippet uses: single-quoted values.
expand_ph() { # $1 = template, $2 = {-1} value, $3 = {q} value -> REPLY
  local t="$1" p1='{-1}' pq='{q}'
  t=${t//"$p1"/"'${2//\'/\'\\\'\'}'"}
  t=${t//"$pq"/"'${3//\'/\'\\\'\'}'"}
  REPLY=$t
  if [[ "$t" =~ (^|[^$])\{[-+0-9a-z.,]*\} ]]; then
    say "  note: the focus snippet has a placeholder the bench does not expand: ${BASH_REMATCH[0]}"
  fi
}

# =====================================================================================
# Scenario definitions: for each scenario and side, C_<scn>_<side> (argv),
# E_<scn>_<side> (environment), and per scenario T_<scn> (runner flags) and
# K_<scn> (kind: cmd | first).
# =====================================================================================
declare -A SCN_TTY SCN_KIND SCN_RC SCN_NOTE SCN_BAD
define() { # scenario side envarray-name argv...
  local key="${1//-/_}_$2" en="$3"; shift 3
  declare -g -a "C_$key=()" "E_$key=()"
  local -n _c="C_$key" _e="E_$key" _src="$en"
  _c=("$@"); _e=("${_src[@]}")
}

find_row() { # $1 = rows file, $2 = spec -> REPLY = the row's visible text (ANSI stripped)
  REPLY=$(strip_ansi "$1" | awk -F'\t' -v s="$2" '$NF == s { print; exit }')
  [ -n "$REPLY" ]
}

# shellcheck disable=SC2034  # the arrays named "e" here are read through define's nameref
build_scenarios() {
  local side wt sq
  local rows="$WORK/hold/A-nav.rows" drows="$WORK/hold/A-dirs.rows"
  local ntot nd
  ntot=$(wc -l < "$rows"); nd=$(wc -l < "$drows")
  [ "$ntot" -gt 100 ] || die "the navigator listed only $ntot rows"
  local S_SPEC="S:ops" W_SPEC="W:api-gateway-production-eu-west-1:1" P_SPEC="P:agents:0:0"
  local ROW_S ROW_W ROW_P ROW_F
  find_row "$rows" "$S_SPEC" || die "no row $S_SPEC in the list"; ROW_S=$REPLY
  find_row "$rows" "$W_SPEC" || die "no row $W_SPEC in the list"; ROW_W=$REPLY
  find_row "$rows" "$P_SPEC" || die "no row $P_SPEC in the list"; ROW_P=$REPLY
  find_row "$rows" "W:$CUR_SESSION:0" || die "no row W:$CUR_SESSION:0"; ROW_F=$REPLY
  local DIR_PV="$H/src/api-gateway" DEEP_Q=svc TYPED_Q=api NEW_Q=svc-07c
  grep -qF "$DIR_PV" "$drows" || die "the ctrl-o picker does not list $DIR_PV"
  local ROW_D
  ROW_D=$(strip_ansi "$drows" | awk -F'\t' -v s="$DIR_PV" '$NF == s { print; exit }')
  local -a fz_reload fz_pv_S fz_pv_W fz_pv_P fz_focus fz_typed fz_zero fz_dreload fz_ddeep fz_dpv
  # the navigator: preview hidden (the default) except for the preview itself
  fzf_env fz_reload nav ctrl-r async "" "$ntot" "$ntot" "$ROW_F" 0
  fzf_env fz_pv_S  nav down bg-cancel "" "$ntot" "$ntot" "$ROW_S" 1
  fzf_env fz_pv_W  nav down bg-cancel "" "$ntot" "$ntot" "$ROW_W" 1
  fzf_env fz_pv_P  nav down bg-cancel "" "$ntot" "$ntot" "$ROW_P" 1
  fzf_env fz_focus nav down bg-cancel "" "$ntot" "$ntot" "$ROW_W" 0
  fzf_env fz_typed nav i bg-cancel "$TYPED_Q" 15 "$ntot" "$ROW_F" 0
  fzf_env fz_zero  nav q bg-cancel "$NEW_Q" 0 "$ntot" "$ROW_F" 0 0
  # the ctrl-o picker: its preview is always shown
  fzf_env fz_dreload dirs ctrl-r async "" "$nd" "$nd" "$ROW_D" 1
  fzf_env fz_ddeep   dirs ctrl-f async "$DEEP_Q" "$nd" "$nd" "$ROW_D" 1
  fzf_env fz_dpv     dirs down async "" "$nd" "$nd" "$ROW_D" 1

  for side in A B; do
    if [ "$side" = A ]; then wt=$WT_A; else wt=$WT_B; fi
    sq="'${wt//\'/\'\\\'\'}/scripts/interdimux.sh'"
    local -a nav=() navb=() dirs=() pop=() popb=() e=()
    # IMUX_BENCH_SAME_ENV=1 (debugging the harness): B runs with A's recorded
    # environments, so the sides differ in nothing but the worktree
    local es=$side; [ "${IMUX_BENCH_SAME_ENV:-0}" = 1 ] && es=A
    holder_env "$es-nav" nav
    holder_env "$es-navbash" navb
    holder_env "$es-dirs" dirs
    local -n _pop="POPUP_$es" _popb="POPUPB_$es"
    pop=("${_pop[@]}"); popb=("${_popb[@]}")

    e=("${pop[@]}" BENCH_FZF_MODE=first)
    define first-frame "$side" e bash "$wt/scripts/interdimux.sh"
    e=("${popb[@]}" BENCH_FZF_MODE=first)
    define first-frame-bash "$side" e bash "$wt/scripts/interdimux.sh"

    e=("${nav[@]}" "${fz_reload[@]}");  define list "$side" e sh -c "bash $sq --list"
    e=("${navb[@]}" "${fz_reload[@]}"); define list-bash "$side" e sh -c "bash $sq --list"
    e=("${nav[@]}" "${fz_pv_S[@]}"); define preview-S "$side" e sh -c "bash $sq --preview '$S_SPEC'"
    e=("${nav[@]}" "${fz_pv_W[@]}"); define preview-W "$side" e sh -c "bash $sq --preview '$W_SPEC'"
    e=("${nav[@]}" "${fz_pv_P[@]}"); define preview-P "$side" e sh -c "bash $sq --preview '$P_SPEC'"

    if focus_snippet "$side-nav"; then
      local snip=$REPLY
      expand_ph "$snip" "$W_SPEC" ""
      e=("${nav[@]}" "${fz_focus[@]}"); define hint "$side" e sh -c "$REPLY"
      expand_ph "$snip" "W:$CUR_SESSION:0" "$TYPED_Q"
      e=("${nav[@]}" "${fz_typed[@]}"); define footer "$side" e sh -c "$REPLY"
      expand_ph "$snip" "" "$NEW_Q"
      e=("${nav[@]}" "${fz_zero[@]}"); define describe-create "$side" e sh -c "$REPLY"
    else
      SCN_NOTE[hint]+="$side: no focus bind in the navigator's fzf argv"$'\n'
      e=("${nav[@]}" "${fz_focus[@]}"); define hint "$side" e sh -c "bash $sq --footer-for '$W_SPEC'"
      e=("${nav[@]}" "${fz_typed[@]}"); define footer "$side" e sh -c "bash $sq --footer-for 'W:$CUR_SESSION:0'"
      e=("${nav[@]}" "${fz_zero[@]}"); define describe-create "$side" e sh -c "bash $sq --describe-create '$NEW_Q'"
    fi
    e=("${pop[@]}"); define session-name-for "$side" e bash "$wt/scripts/interdimux.sh" --session-name-for "$H/src/frontend-monorepo"
    e=("${nav[@]}" "${fz_focus[@]}"); define hint-ladder "$side" e bash "$wt/scripts/interdimux.sh" --hint-ladder W
    e=("${nav[@]}" "${fz_focus[@]}" FZF_NTH=1); define scope-prompt "$side" e sh -c "bash $sq --scope-prompt"
    e=("${pop[@]}"); define parse "$side" e bash -n "$wt/scripts/interdimux.sh"

    e=("${dirs[@]}" "${fz_dreload[@]}"); define dirs-list "$side" e sh -c "bash $sq --dirs-list"
    e=("${dirs[@]}" "${fz_ddeep[@]}");   define dirs-deep "$side" e sh -c "bash $sq --dirs-list --deep '$DEEP_Q'"
    e=("${dirs[@]}" "${fz_dpv[@]}");     define dirs-preview "$side" e sh -c "bash $sq --dirs-preview '$DIR_PV'"
    e=("${pop[@]}"); define doctor "$side" e bash "$wt/scripts/interdimux.sh" --doctor
  done
  local s
  for s in "${DEFAULT_SCENARIOS[@]}" "${EXTRA_SCENARIOS[@]}"; do
    SCN_TTY[$s]="-t ${POPUP_COLS}x${POPUP_ROWS}"; SCN_KIND[$s]=cmd; SCN_RC[$s]=0
  done
  SCN_TTY[first-frame]+=" -p"; SCN_KIND[first-frame]=first
  SCN_TTY[first-frame-bash]+=" -p"; SCN_KIND[first-frame-bash]=first
  SCN_RC[doctor]="0 1"
}

# =====================================================================================
# Running and statistics
# =====================================================================================
# The worktree and work-dir paths in an output, as <WT> and <WORK>: whole paths
# only (not preceded or followed by a name character), longest first.  B is
# /work in the dev image, and the fixture has a ~/work of its own: a plain
# substitution would rewrite $H/work/team-01 too.
norm_paths() {
  NP_A=$WT_A NP_B=$WT_B NP_W=$WORK perl -pe '
    BEGIN {
      %to = ($ENV{NP_W} => "<WORK>", $ENV{NP_A} => "<WT>", $ENV{NP_B} => "<WT>");
      $re = join "|", map { quotemeta } sort { length($b) <=> length($a) } grep { length } keys %to;
    }
    s{(?<![\w.-])($re)(?![\w.-])}{$to{$1}}g'
}
# One run of one side.  Appends "wall_us cpu_us proc_us srv_us rc orphans killed
# sum jobs_us jobs" to $WORK/res/<scn>.<side> (cpu_us = proc_us + srv_us, and
# srv_us includes jobs_us: what the tmux server's jobs cost).
run_one() { # scenario side
  local scn="$1" side="$2" key="${1//-/_}_$2"
  # shellcheck disable=SC2178  # namerefs to the scenario's argv and environment arrays
  local -n _c="C_$key" _e="E_$key"
  local out="$WORK/out/$key.out" err="$WORK/out/$key.err" fz="$WORK/out/$key.fzf" res
  local wall cpu srv rc rt0 orph killed jobs jkilled jobus first sum
  local -a extra=()
  [ "${SCN_KIND[$scn]}" = first ] && { extra=(BENCH_FZF_OUT="$fz"); rm -f "$fz.t" "$fz.rows"; }
  # shellcheck disable=SC2086  # the runner flags are words
  res=$(env -i "${_e[@]}" "${extra[@]}" "$RUNNER" run ${SCN_TTY[$scn]} -s "$SRV_PID" -o "$out" -e "$err" -- "${_c[@]}") \
    || { SCN_NOTE[$scn]+="$side: runner failed"$'\n'; return 1; }
  read -r wall cpu srv rc rt0 orph killed jobs jkilled jobus <<< "$res"
  if [ "${SCN_KIND[$scn]}" = first ]; then
    if [ -s "$fz.t" ]; then
      read -r first _ _ _ < "$fz.t"
      if [ "$first" -gt 0 ]; then wall=$(( first - rt0 )); else wall=-1; fi
      out="$fz.rows"
    else
      wall=-1
    fi
    [ "$wall" -ge 0 ] || { SCN_NOTE[$scn]+="$side: no row ever reached fzf"$'\n'; SCN_BAD[$scn]=1; }
  fi
  # the output, worktree paths normalised, as one checksum
  sum=$(norm_paths < "$out" 2>/dev/null | cksum)
  sum=${sum%% *}
  [ -e "$WORK/out/$key.first" ] || norm_paths < "$out" > "$WORK/out/$key.first" 2>/dev/null
  printf '%s %s %s %s %s %s %s %s %s %s\n' "$wall" $(( cpu + srv )) "$cpu" "$srv" "$rc" "$orph" "$killed" "$sum" \
    "${jobus:-0}" "${jobs:-0}" >> "$WORK/res/$scn.$side${3:-}"
  case " ${SCN_RC[$scn]} " in
    *" $rc "*) ;;
    *) SCN_NOTE[$scn]+="$side: exit $rc ($(head -c 200 "$err" 2>/dev/null | tr "\n" " "))"$'\n'; SCN_BAD[$scn]=1 ;;
  esac
  [ "$killed" -gt 0 ] && SCN_NOTE[$scn]+="$side: $killed orphan(s) outlived the run and were killed"$'\n'
  [ "$orph" -gt 0 ] && [ "$killed" = 0 ] && SCN_NOTE[$scn]+="$side: left $orph background process(es) (their CPU is counted)"$'\n'
  [ "${jkilled:-0}" -gt 0 ] && SCN_NOTE[$scn]+="$side: $jkilled job(s) of the tmux server outlived the run by 3 s and were killed"$'\n'
  [ "${jobs:-0}" -gt 0 ] && [ "${jkilled:-0}" = 0 ] && SCN_NOTE[$scn]+="$side: the tmux server was still running $jobs job(s) for it when it ended (waited for: their CPU is counted)"$'\n'
  return 0
}

run_pairs() { # scenario count -- interleaved, the order alternating per pair
  local i
  for (( i = 0; i < $2; i++ )); do
    if (( i % 2 == 0 )); then run_one "$1" A; run_one "$1" B
    else run_one "$1" B; run_one "$1" A; fi
  done
}
# Warm-up pairs, then N pairs (fewer when one pair is too slow for the budget,
# never fewer than 8).  Then, within the budget: while the measured noise is
# above NOISE_MAX%, ten more pairs at a time, up to 3N -- a load burst from
# something else on the machine is diluted instead of deciding the result.
NOISE_MAX=6
run_scenario() { # scenario -> also leaves R_LINE[scenario] analysed
  local scn="$1" pairs t0 t1 per total nz
  rm -f "$WORK/res/$scn".*
  t0=$(date +%s%N)
  local i
  for (( i = 0; i < WARM; i++ )); do
    if (( i % 2 == 0 )); then run_one "$scn" A .warm; run_one "$scn" B .warm
    else run_one "$scn" B .warm; run_one "$scn" A .warm; fi
  done
  t1=$(date +%s%N)
  pairs=$N_PAIRS
  if [ -n "$BUDGET" ] && [ "$WARM" -gt 0 ]; then
    per=$(( (t1 - t0) / WARM ))                     # ns per pair, overhead included
    [ "$per" -gt 0 ] || per=1
    local fit=$(( BUDGET * 1000000000 / per ))
    [ "$fit" -lt "$pairs" ] && pairs=$fit
    [ "$pairs" -lt 8 ] && pairs=8
    [ "$N_SET" = 1 ] && [ "$pairs" -gt "$N_PAIRS" ] && pairs=$N_PAIRS
  fi
  run_pairs "$scn" "$pairs"
  analyse "$scn"
  total=$pairs
  [ -n "$BUDGET" ] || return 0
  while :; do
    IFS='|' read -r _ _ _ _ nz _ <<< "${R_LINE[$scn]}"
    awk -v z="$nz" -v m="$NOISE_MAX" 'BEGIN { exit !(z + 0 > m) }' || break
    [ "$total" -lt $(( 3 * N_PAIRS )) ] || break
    [ $(( $(date +%s%N) - t0 )) -lt $(( BUDGET * 1000000000 )) ] || break
    run_pairs "$scn" 10
    total=$((total + 10))
    analyse "$scn"
  done
}

# Column $2 (1-based) of a result file -> "median q1 q3"
quart() { # file col
  awk -v c="$2" '{ print $c }' "$1" | sort -g | awk '
    { v[NR] = $1 }
    END {
      if (NR == 0) { print "nan nan nan"; exit }
      printf "%s %s %s\n", q(0.5), q(0.25), q(0.75)
    }
    function q(p,   h, lo) { h = (NR - 1) * p + 1; lo = int(h); if (lo >= NR) return v[NR]; return v[lo] + (h - lo) * (v[lo + 1] - v[lo]) }'
}
# The shift between the sides, from the per-pair differences d = B - A of
# column $3: the Hodges-Lehmann estimate (median of the Walsh averages
# (d_i + d_j)/2, i <= j) and its exact Wilcoxon signed-rank confidence interval
# at CONF (99%) -> "estimate ci_lo ci_hi".  Robust to the odd run a load burst
# hit, and tighter than a sign-test interval for the same number of runs.
CONF_ALPHA=0.01
paired() { # fileA fileB col
  local d n
  d=$(paste -d' ' <(awk -v c="$3" '{ print $c }' "$1") <(awk -v c="$3" '{ print $c }' "$2") \
      | awk 'NF == 2 { print $2 - $1 }')
  n=$(printf '%s\n' "$d" | grep -c .)
  [ "$n" -gt 0 ] || { echo "nan nan nan"; return; }
  printf '%s\n' "$d" | awk '{ d[NR] = $1 } END { for (i = 1; i <= NR; i++) for (j = i; j <= NR; j++) print (d[i] + d[j]) / 2 }' \
    | sort -g | awk -v n="$n" -v alpha="$CONF_ALPHA" '
    { w[NR] = $1 }
    END {
      m = NR
      hl = (m % 2) ? w[(m + 1) / 2] : (w[m / 2] + w[m / 2 + 1]) / 2
      # exact null distribution of the signed-rank statistic T+ (counts of subsets of 1..n by sum)
      top = n * (n + 1) / 2
      for (t = 0; t <= top; t++) cnt[t] = 0
      cnt[0] = 1
      for (k = 1; k <= n; k++) for (t = top; t >= k; t--) cnt[t] += cnt[t - k]
      total = 2 ^ n; cum = 0; c = 0
      # the largest c with P(T+ < c) <= alpha/2: CI = [w_(c), w_(m+1-c)], c >= 1
      for (t = 0; t <= top; t++) { cum += cnt[t]; if (cum / total <= alpha / 2) c = t + 1; else break }
      if (c < 1) c = 1
      print hl, w[c], w[m + 1 - c]
    }'
}

declare -A R_LINE R_STAGE1
analyse() { # scenario -> R_LINE[scn]: "scn|A cpu|B cpu|...|n|verdict|wall"
  local scn="$1" fa="$WORK/res/$1.A" fb="$WORK/res/$1.B"
  if [ ! -s "$fa" ] || [ ! -s "$fb" ]; then R_LINE[$scn]="$scn|-|-|-|-|-|-|-|-|-|-|0|FAILED|-"; return; fi
  local ma qa1 qa3 mb qb1 qb3 wa wb dmed dlo dhi wmed wlo whi n out
  read -r ma qa1 qa3 <<< "$(quart "$fa" 2)"
  read -r mb qb1 qb3 <<< "$(quart "$fb" 2)"
  read -r wa _ _ <<< "$(quart "$fa" 1)"
  read -r wb _ _ <<< "$(quart "$fb" 1)"
  read -r dmed dlo dhi <<< "$(paired "$fa" "$fb" 2)"
  read -r wmed wlo whi <<< "$(paired "$fa" "$fb" 1)"
  n=$(wc -l < "$fa")
  # outputs: A's own must be stable to compare with B's
  local sa sb
  sa=$(cat "$fa" "$WORK/res/$scn.A.warm" 2>/dev/null | awk '{ print $8 }' | sort -u)
  sb=$(cat "$fb" "$WORK/res/$scn.B.warm" 2>/dev/null | awk '{ print $8 }' | sort -u)
  if [ "$(printf '%s\n' "$sa" | wc -l)" -gt 1 ]; then out=vol
  elif [ "$sa" = "$sb" ]; then out=same
  else out=DIFF; fi
  local line
  line=$(awk -v ma="$ma" -v mb="$mb" -v qa1="$qa1" -v qa3="$qa3" -v qb1="$qb1" -v qb3="$qb3" \
      -v wa="$wa" -v wb="$wb" -v dm="$dmed" -v dl="$dlo" -v dh="$dhi" -v wm="$wmed" -v wl="$wlo" -v wh="$whi" \
      -v n="$n" -v out="$out" -v scn="$scn" -v bad="${SCN_BAD[$scn]:-0}" 'BEGIN {
    dp = (ma > 0) ? 100 * dm / ma : 0; nz = (ma > 0) ? 100 * (dh - dl) / 2 / ma : 0
    wp = (wa > 0) ? 100 * wm / wa : 0; wz = (wa > 0) ? 100 * (wh - wl) / 2 / wa : 0
    th = (nz > 2) ? nz : 2; wt = (wz > 2) ? wz : 2
    v = "ok"; if (dp > th) v = "REGRESSION"; else if (dp < -th) v = "FASTER"
    w = "ok"; if (wp > wt) w = "SLOWER"; else if (wp < -wt) w = "FASTER"
    # below 8 pairs no exact 99% Wilcoxon interval exists: no verdict
    if (n < 8) { v = "(n<8)"; w = "(n<8)" }
    if (bad) { v = "FAILED"; w = "-" }
    ia = (ma > 0) ? 100 * (qa3 - qa1) / ma : 0; ib = (mb > 0) ? 100 * (qb3 - qb1) / mb : 0
    printf "%s|%.1f|%.1f|%+.1f|%.1f|%.1f|%.1f|%+.1f|%.1f|%.0f/%.0f|%s|%d|%s|%s\n",
      scn, ma / 1000, mb / 1000, dp, nz, wa / 1000, wb / 1000, wp, wz, ia, ib, out, n, v, w }')
  R_LINE[$scn]=$line
}
flagged() { # $1 = a result line: is anything in it a verdict worth confirming?
  case "$1" in *"|REGRESSION|"*|*"|FASTER|"*|*"|SLOWER") return 0 ;; *"|FASTER") return 0 ;; esac
  return 1
}

print_table() {
  local hdr="scenario|A cpu|B cpu|dcpu%|noise%|A wall|B wall|dwall%|wnoise%|IQR% A/B|out|n|verdict|wall"
  local s
  {
    printf '%s\n' "$hdr"
    for s in "${SCENARIOS[@]}"; do printf '%s\n' "${R_LINE[$s]}"; done
  } | awk -F'|' '
    { for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } nf[NR] = NF }
    END {
      for (r = 1; r <= NR; r++) {
        line = ""
        for (i = 1; i <= nf[r]; i++) {
          if (i == 1 || i >= 13) line = line sprintf("%-" w[i] "s  ", c[r, i])
          else line = line sprintf("%" w[i] "s  ", c[r, i])
        }
        sub(/ +$/, "", line); print line
        if (r == 1) {
          line = ""
          for (i = 1; i <= nf[r]; i++) { d = sprintf("%" w[i] "s", ""); gsub(/ /, "-", d); line = line d "  " }
          sub(/ +$/, "", line); print line
        }
      }
    }'
  if [ -n "$OUT_TSV" ]; then
    { printf '%s\n' "$hdr"; for s in "${SCENARIOS[@]}"; do printf '%s\n' "${R_LINE[$s]}"; done; } | tr '|' '\t' > "$OUT_TSV"
  fi
}

# =====================================================================================
# Main
# =====================================================================================
NOW_PIN=$(( $(date +%s) + 60 ))
say "bench: A=$WT_A"
say "       B=$WT_B"
say "building the fixture in $WORK ..."
export_fixture_env
build_dirs
start_server
SOCK_PATH=$(tm display-message -p '#{socket_path}')
wait_settled
attach_client
claude_record
# A popup starts in the pressing pane's directory, and every callback inherits it
cd "$H/src/$CUR_SESSION" || die "no fixture dir for $CUR_SESSION"
say "  $(tm list-sessions | wc -l) sessions, $(tm list-windows -a | wc -l) windows, $(tm list-panes -a | wc -l) panes; zoxide $ZOX_N dirs; client $CLIENT_NAME"

for side in A B; do
  if [ "$side" = A ]; then wt=$WT_A; else wt=$WT_B; fi
  declare -a "POPUP_$side=()" "POPUPB_$side=()"
  popup_env "$wt" "POPUP_$side"
  popup_env "$wt" "POPUPB_$side" INTERDIMUX_USE_RUST=off
done

if [ -n "$EXEC_CMD" ]; then
  printf '%s\0' "${POPUP_A[@]}" > "$WORK/popup-A.env"
  printf '%s\0' "${POPUP_B[@]}" > "$WORK/popup-B.env"
  BENCH_SOCK=$SOCK BENCH_OSOCK=$OSOCK BENCH_FIX=$FIX BENCH_WORK=$WORK BENCH_HOME_DIR=$H \
  BENCH_POPUP_ENV_A="$WORK/popup-A.env" BENCH_POPUP_ENV_B="$WORK/popup-B.env" BENCH_RUNNER=$RUNNER \
  BENCH_TMUX=$TMUX_BIN BENCH_CUR_PANE=$CUR_PANE BENCH_SRV_PID=$SRV_PID IMUX_BENCH_ID=$BENCH_ID \
    bash -c "$EXEC_CMD"
  exit $?
fi

say "starting the holders (each worktree's real navigator and ctrl-o picker, stub fzf) ..."
for side in A B; do
  if [ "$side" = A ]; then wt=$WT_A; else wt=$WT_B; fi
  start_holder "$side-nav" "POPUP_$side" bash "$wt/scripts/interdimux.sh"
  start_holder "$side-navbash" "POPUPB_$side" bash "$wt/scripts/interdimux.sh"
  # ctrl-o: fzf's execute child, with the navigator's environment and fzf's
  declare -a _navenv=() _fz=()
  holder_env "$side-nav" _navenv
  local_rows=$(wc -l < "$WORK/hold/$side-nav.rows")
  fzf_env _fz nav ctrl-o async "" "$local_rows" "$local_rows" "" 0
  declare -a "DIRSENV_$side=()"
  declare -n _de="DIRSENV_$side"
  _de=("${_navenv[@]}" "${_fz[@]}")
  sq="'${wt//\'/\'\\\'\'}/scripts/interdimux.sh'"
  start_holder "$side-dirs" "DIRSENV_$side" sh -c "bash $sq --dirs"
  unset -n _de
done
build_scenarios

say "running ${#SCENARIOS[@]} scenario(s): $WARM warm-up pair(s), then up to $N_PAIRS pairs${BUDGET:+ (budget ${BUDGET}s each)}"
REGRESSED=() DIFFED=() ERRORED=()
progress() { # scenario seconds [label]
  local _ca _cb _dc _nz _out _n _v _wv
  IFS='|' read -r _ _ca _cb _dc _nz _ _ _ _ _ _out _n _v _wv <<< "${R_LINE[$1]}"
  say "$(printf '  %-17s %4ss  cpu %8s -> %8s ms  %6s%% (noise %s%%)  out %-4s  n=%-3s %s / wall %s%s' \
    "$1" "$2" "$_ca" "$_cb" "$_dc" "$_nz" "$_out" "$_n" "$_v" "$_wv" "${3:-}")"
}
T_START=$(date +%s)
for scn in "${SCENARIOS[@]}"; do
  ts=$(date +%s)
  run_scenario "$scn"
  # A flag is a screening result: measure again on a fresh, independent set of
  # pairs before believing it (see "verdict" in the header).
  if [ "$CONFIRM" = 1 ] && flagged "${R_LINE[$scn]}" && [ -z "${SCN_BAD[$scn]:-}" ]; then
    progress "$scn" $(( $(date +%s) - ts )) "  -> confirming"
    R_STAGE1[$scn]=${R_LINE[$scn]}
    for f in "$WORK/res/$scn".*; do mv "$f" "${f/\/res\//\/res\/stage1.}"; done
    run_scenario "$scn"
    stage2=${R_LINE[$scn]}
    # the decision is on both sets together (twice the pairs), and a flag
    # stands only if the confirming set, on its own, points the same way
    for side in A B; do
      cat "$WORK/res/stage1.$scn.$side" >> "$WORK/res/$scn.$side"
    done
    analyse "$scn"
    IFS='|' read -r _ _ _ _d1 _z1 _ _ _w1 _wz1 _ _ _ _v1 _wv1 <<< "${R_STAGE1[$scn]}"
    IFS='|' read -r _ _ _ _d2 _z2 _ _ _w2 _wz2 _ _ _ _v2 _wv2 <<< "$stage2"
    IFS='|' read -r -a _f <<< "${R_LINE[$scn]}"
    case "${_f[12]}" in
      REGRESSION) [ "$_v1" = REGRESSION ] && [[ "$_d2" == +* ]] && [ "$_d2" != +0.0 ] || _f[12]=ok ;;
      FASTER)     [ "$_v1" = FASTER ] && [[ "$_d2" == -* ]] || _f[12]=ok ;;
    esac
    case "${_f[13]}" in
      SLOWER) [ "$_wv1" = SLOWER ] && [[ "$_w2" == +* ]] && [ "$_w2" != +0.0 ] || _f[13]=ok ;;
      FASTER) [ "$_wv1" = FASTER ] && [[ "$_w2" == -* ]] || _f[13]=ok ;;
    esac
    _f[11]="${_f[11]}c"
    R_LINE[$scn]=$(IFS='|'; printf '%s' "${_f[*]}")
    SCN_NOTE[$scn]+="flagged, so measured again: first set cpu $_d1% (noise $_z1%) $_v1 / wall $_w1% $_wv1; second set cpu $_d2% (noise $_z2%) $_v2 / wall $_w2% $_wv2; the row is both sets together"$'\n'
  fi
  progress "$scn" $(( $(date +%s) - ts ))
  case "${R_LINE[$scn]}" in
    *"|REGRESSION|"*) REGRESSED+=("$scn") ;;
    *"|FAILED|"*) ERRORED+=("$scn") ;;
  esac
  case "${R_LINE[$scn]}" in *"|DIFF|"*) DIFFED+=("$scn") ;; esac
done
T_END=$(date +%s)

LOAD_END=$(load1)
HOGS_END=$(hogs)
echo
printf 'interdimux A/B  A=%s  B=%s\n' "$WT_A" "$WT_B"
# The load average is the whole machine's (inside a container too), so it is
# set against all of its CPUs, not the ones a --cpuset-cpus left this run.
CPUS_ALL=$(nproc --all 2>/dev/null || echo 1) CPUS_RUN=$(nproc 2>/dev/null || echo 1)
CPUS_NOTE="$CPUS_ALL CPUs"
[ "$CPUS_RUN" = "$CPUS_ALL" ] || CPUS_NOTE+=" ($CPUS_RUN for this run)"
printf 'fixture: %s sessions / %s windows / %s panes, popup %sx%s; %s s; load1 %s -> %s on %s\n' \
  "$(tm list-sessions | wc -l)" "$(tm list-windows -a | wc -l)" "$(tm list-panes -a | wc -l)" \
  "$POPUP_COLS" "$POPUP_ROWS" "$(( T_END - T_START ))" "$LOAD_START" "$LOAD_END" "$CPUS_NOTE"
echo "cpu = ms of user+sys (process tree + tmux server), wall = ms (first-frame*: to the first row)"
echo
print_table
echo
if [ -n "$HOGS_START$HOGS_END" ]; then
  echo "WARNING: other processes were using more than 50% of a CPU (results are noisier):"
  printf '%s' "$HOGS_START$HOGS_END" | sort -u
fi
awk -v a="$LOAD_START" -v b="$LOAD_END" -v c="$CPUS_ALL" \
  'BEGIN { if (a > c || b > c) printf "WARNING: load average (%s -> %s) exceeds the %s CPUs: expect wide noise%%\n", a, b, c }'
# what dev/run.sh saw: dev containers up when this one started, which it did
# not wait for (a shell, a watch, a `run`), and which no check in here can see
if [ -n "${IMUX_DEV_OTHERS:-}" ]; then
  echo "WARNING: other dev containers were up when this run started (results may be noisier):"
  printf '%s\n' "$IMUX_DEV_OTHERS" | tr ';' '\n' | sed '/^ *$/d; s/^ */    /'
fi
[ -z "$ZOXIDE_WARN" ] || echo "$ZOXIDE_WARN"
# What the tmux server's jobs cost, per run on average (the medians above
# miss a job of a few ms: its CPU arrives in whole 10 ms clock ticks)
for scn in "${SCENARIOS[@]}"; do
  _ja=$(awk '{ s += $9; n++ } END { if (n) printf "%.1f", s / n / 1000 }' "$WORK/res/$scn.A" 2>/dev/null)
  _jb=$(awk '{ s += $9; n++ } END { if (n) printf "%.1f", s / n / 1000 }' "$WORK/res/$scn.B" 2>/dev/null)
  case "${_ja:-0}${_jb:-0}" in *[1-9]*)
    SCN_NOTE[$scn]+="the tmux server's jobs cost A ${_ja:-0} ms, B ${_jb:-0} ms a run on average (counted in cpu, in whole clock ticks)"$'\n' ;;
  esac
done
for scn in "${SCENARIOS[@]}"; do
  [ -n "${SCN_NOTE[$scn]:-}" ] && printf '%s' "${SCN_NOTE[$scn]}" | awk -v s="$scn" 'NF && !seen[$0]++ { print "note " s ": " $0 }'
done
# An "ok" only says no effect bigger than the noise: name the scenarios where
# that noise was large (in % and in ms), so nobody reads them as a clean bill.
NOISY=()
for scn in "${SCENARIOS[@]}"; do
  IFS='|' read -r _ _ca _ _ _nz _ <<< "${R_LINE[$scn]}"
  awk -v z="$_nz" -v a="$_ca" 'BEGIN { exit !(z + 0 > 10 && z * a / 100 > 1) }' && NOISY+=("$scn (${_nz}%)")
done
if [ "${#NOISY[@]}" -gt 0 ]; then
  echo "noisy: ${NOISY[*]} -- an effect smaller than that is invisible here; re-run just these (-s) on a quieter machine"
fi
for scn in ${DIFFED[@]+"${DIFFED[@]}"}; do
  key=${scn//-/_}
  echo "output DIFF in $scn (A vs B, first lines that differ):"
  diff <(strip_ansi "$WORK/out/${key}_A.first") <(strip_ansi "$WORK/out/${key}_B.first") | head -8 | sed 's/^/    /'
done
if [ "${#ERRORED[@]}" -gt 0 ]; then
  echo "FAILED: ${ERRORED[*]} (see the notes)"; exit 1
fi
if [ "${#REGRESSED[@]}" -gt 0 ]; then
  echo "REGRESSION: ${REGRESSED[*]}"; exit 3
fi
if [ "${#DIFFED[@]}" -gt 0 ]; then
  echo "no CPU regression, but output differs: ${DIFFED[*]}"; exit 4
fi
echo "no CPU regression, outputs identical"
exit 0
