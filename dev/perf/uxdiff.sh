#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
#
# uxdiff.sh -- UX-identity diff harness for interdimux.
#
#   uxdiff.sh [-q] [-r N] [-f REGEX] [-k] <worktreeA> <worktreeB> [outdir]
#
# Renders the same deterministic fixture through worktree A and worktree B and
# compares what the user would see, byte for byte (colours included):
#
#   text/*    the script's text entry points: --list (both renderers, widths
#             80/94/120/160/200, preview shown/hidden, raw on/off, modes,
#             options), --preview of every row, the fzf callbacks (--footer-for,
#             --hint-ladder, --scope-prompt, --session-name-for,
#             --describe-create, --create-key), --dirs-list (deep queries too),
#             --dirs-preview, --dirs-hints, --doctor (errors.log empty and
#             seeded), usage/--help, --jump/--jobs-list/--sched-list, and
#             --bind-keys' effect (list-keys + options on a fresh server)
#   screen/*  real fzf in real tmux popups on a real client (an outer private
#             server's pane is attached to the fixture server) at 120x40 and
#             80x24 (+ an 80x16 client for the fallback dashboard): the
#             navigator by prefix+f (initial, query, raw dimmed row, preview,
#             scope), kill/rename/send dialogs and Esc, line editing, ctrl-o,
#             prefix+g's menu and its modes, schedule dialog, Health, Jobs
#             (empty queue), Agents; captured with capture-pane -e and reduced
#             to each cell's VISIBLE style (uxdiff-canon.pl)
#   both      also record what a user would notice besides the screen: status
#             line messages on the client, errors.log, the recent-dirs list
#
# One line per scenario, IDENTICAL or DIFF <diff file>, then a summary.  Exit 0
# when everything is identical, 1 when anything differs (or was skipped), 2 on
# a usage or setup error.  A full run takes ~6 min, -q under 1 min.
#
# Output: <outdir>/{A,B}/<scenario>.txt (normalised captures), diff/*.diff
# (plain-text diff first, then the exact bytes with cat -v), retry/ (earlier
# attempts of a retried screen scenario), summary.txt.  Default outdir: a new
# directory under $UXDIFF_SCRATCH (default ${TMPDIR:-/tmp}/uxdiff), where the
# fixture is built too.
#
# In the dev image: `make uxdiff REF=main [ARGS=-q]` from a checkout
# (dev/cmd.sh uxdiff: REF is extracted with git archive and gets its own Rust
# core, B is the container's copy of the checkout, /work; the outdir is kept
# in the checkout's work volume and the plain-text part of every diff is
# printed).  See docs/DEVENV.md.
#
# Requirements: bash >= 5.0, tmux (the first on PATH, or $UXDIFF_TMUX), fzf,
# perl, git, setsid, timeout, pgrep/pkill; Linux (/proc).  fd and zoxide are
# used when present.  The fixture's PATH starts with links to the tmux, fzf and
# bash this shell found, so the servers, the popups and the plugin all run
# those.  Nothing here reads the caller's terminal: it runs without one.
#
#   -q        quick: text scenarios only (no popups)
#   -r N      re-run a screen scenario that differs up to N times (default 2);
#             a scenario that matches on a retry is IDENTICAL, flagged
#             "retried"; one whose retry reproduces both sides byte for byte is
#             a DIFF at once ("reproduced").  -r 0: fastest report, no retries
#   -f REGEX  only the scenarios whose name (text/..., screen/WxH/...) matches
#   -k        keep the fixture directory (for debugging)
#
# Safety: every tmux call is $TMUXBIN -L imux-ux-<pid>[-o|-bk], with TMUX,
# TMUX_PANE and TMUX_TMPDIR unset; the user's server is never addressed.
# at/atq/atrm/batch are fakes (nothing is ever queued).  Every server, client,
# process and file the run creates is removed on exit (trap), sockets included
# (tmux 3.7 leaves them behind).

set -uo pipefail
# never the user's server: no inherited TMUX, and the default socket directory
unset TMUX TMUX_PANE TMUX_TMPDIR

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SCRATCH_ROOT="${UXDIFF_SCRATCH:-${TMPDIR:-/tmp}/uxdiff}"

usage() {
  sed -n '/^# uxdiff\.sh --/,/^# Safety:/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 2
}
die() { printf 'uxdiff: %s\n' "$*" >&2; exit 2; }

QUICK=0 RETRIES=2 KEEP=0 FILTER=""
while getopts ':qkr:f:h' o; do
  case "$o" in
    q) QUICK=1 ;;
    k) KEEP=1 ;;
    r) [[ "$OPTARG" =~ ^[0-9]+$ ]] || die "-r needs a number"; RETRIES="$OPTARG" ;;
    f) FILTER="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 2 ] && [ $# -le 3 ] || usage

check_wt() { # $1 = label, $2 = path; prints the resolved path
  local p
  p=$(cd "$2" 2>/dev/null && pwd -P) || die "$1: no such directory: $2"
  [ -f "$p/scripts/interdimux.sh" ] || die "$1: not an interdimux checkout (no scripts/interdimux.sh): $p"
  [ -x "$p/rust/target/release/imux" ] \
    || die "$1: rust/target/release/imux is not built -- run: (cd '$p/rust' && cargo build --release)"
  "$p/rust/target/release/imux" --version </dev/null >/dev/null 2>&1 \
    || die "$1: $p/rust/target/release/imux does not run (--version failed)"
  printf '%s' "$p"
}
WT_A=$(check_wt A "$1") || exit 2
WT_B=$(check_wt B "$2") || exit 2
for _w in "$WT_A" "$WT_B"; do
  _newer=$(find "$_w/rust/src" "$_w/rust/Cargo.toml" -type f -newer "$_w/rust/target/release/imux" 2>/dev/null | head -3)
  [ -z "$_newer" ] || printf 'uxdiff: WARNING: %s: rust sources are newer than the binary (rebuild it):\n%s\n' "$_w" "$_newer" >&2
done
command -v fzf >/dev/null 2>&1 || die "fzf is not on PATH"
TMUXBIN=${UXDIFF_TMUX:-$(command -v tmux 2>/dev/null)}
[ -n "$TMUXBIN" ] && [ -x "$TMUXBIN" ] || die "no tmux (${TMUXBIN:-none on PATH}): put one on PATH or set UXDIFF_TMUX"
TMUXBIN=$(readlink -f "$TMUXBIN")
command -v perl >/dev/null 2>&1 || die "perl is needed (fixture processes, normalisation)"
for _t in git setsid timeout pgrep pkill; do
  command -v "$_t" >/dev/null 2>&1 || die "$_t is needed"
done

mkdir -p "$SCRATCH_ROOT" || die "cannot create $SCRATCH_ROOT"
if [ $# -eq 3 ]; then
  OUT="$3"
  if [ -d "$OUT" ] && [ -n "$(command ls -A "$OUT" 2>/dev/null)" ]; then
    [ -f "$OUT/.uxdiff" ] || die "outdir $OUT is not empty and was not made by uxdiff"
    rm -rf "${OUT:?}/A" "${OUT:?}/B" "${OUT:?}/diff" "${OUT:?}/retry" "$OUT/summary.txt"
  fi
  mkdir -p "$OUT" || die "cannot create $OUT"
else
  OUT=$(mktemp -d "$SCRATCH_ROOT/out.XXXXXX") || die "mktemp failed"
fi
OUT=$(cd "$OUT" && pwd -P)
: > "$OUT/.uxdiff"
mkdir -p "$OUT/A" "$OUT/B" "$OUT/diff"

UXID=$$
SOCK="imux-ux-$UXID" OSOCK="imux-ux-$UXID-o" BKSOCK="imux-ux-$UXID-bk"
RUN=$(mktemp -d "$SCRATCH_ROOT/fx.XXXXXX") || die "mktemp failed"
FH="$RUN/home"
TSTART=$EPOCHREALTIME
# The pinned clock: 2.5 days after the fixture is built, so every tmux-derived
# age reads "2d" whatever second a render lands on, and the agent registry's
# timestamps (written relative to it) read exactly "5m" and "2h".
FXNOW=$(( ${EPOCHREALTIME%.*} + 216000 ))

# shellcheck source=uxdiff-fixture.sh
source "$SELF_DIR/uxdiff-fixture.sh"
# shellcheck source=uxdiff-text.sh
source "$SELF_DIR/uxdiff-text.sh"
# shellcheck source=uxdiff-screen.sh
source "$SELF_DIR/uxdiff-screen.sh"

# ---------------------------------------------------------------------------
# cleanup: servers, clients, processes, sockets, fixture
# ---------------------------------------------------------------------------
server_dead() { ! "$TMUXBIN" -L "$1" list-sessions >/dev/null 2>&1; }
cleanup() {
  set +e
  trap - EXIT INT TERM HUP
  local s pid i
  for s in "$OSOCK" "$SOCK" "$BKSOCK"; do
    "$TMUXBIN" -L "$s" kill-server >/dev/null 2>&1
  done
  for s in "$OSOCK" "$SOCK" "$BKSOCK"; do
    for (( i = 0; i < 100; i++ )); do server_dead "$s" && break; sleep 0.05; done
    # tmux 3.7 does not unlink its socket on kill-server
    server_dead "$s" && rm -f "/tmp/tmux-$(id -u)/$s"
  done
  # pane processes get SIGHUP from the dying server; anything that survived:
  if [ -f "$RUN/pane-pids" ]; then
    while read -r pid; do
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    done < "$RUN/pane-pids"
  fi
  pkill -9 -f -- "$RUN/" 2>/dev/null
  # anchored: another run whose pid merely starts with ours must not match
  pkill -9 -f -- "^sleep-hold-$UXID( |$)" 2>/dev/null
  pkill -9 -f -- "-L imux-ux-$UXID(-o|-bk)?( |$)" 2>/dev/null
  if [ "$KEEP" = 1 ]; then
    printf 'uxdiff: fixture kept at %s\n' "$RUN" >&2
  else
    chmod -R u+rwX "$RUN" 2>/dev/null
    rm -rf "${RUN:?}"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ---------------------------------------------------------------------------
# normalisation and comparison
# ---------------------------------------------------------------------------
# Only what is volatile between two runs and never part of what interdimux
# decides: the fixture's temporary path, the worktree paths, this run's id in
# socket names, pty numbers, pids in temp file names.  The worktree is run
# through the SAME symlink ($RUN/plugin) for both sides, so its path is
# identical in everything rendered (and truncated) anyway.
# (The worktree paths whole only, longest first: in the dev image B is /work,
# which would otherwise match inside any .../work/... path.)
norm() {
  NR_RUN="$RUN" NR_A="$WT_A" NR_B="$WT_B" NR_ID="$UXID" perl -pe '
    BEGIN { @wt = sort { length($b) <=> length($a) } grep { length } ($ENV{NR_A}, $ENV{NR_B});
            $wt = join "|", map { quotemeta } @wt; }
    s/\Q$ENV{NR_RUN}\E/<FIX>/g;
    s{(?<![\w.-])(?:$wt)(?![\w.-])}{<WT>}g;
    s/imux-ux-\Q$ENV{NR_ID}\E/imux-ux-<ID>/g;
    s{/dev/pts/\d+}{/dev/pts/<N>}g;
    s/\bclient-\d+/client-<N>/g;
    s/(interdimux-[a-z]+(?:-[a-z]+)*)\.\d+/$1.<PID>/g;
    s/\bfx\.[A-Za-z0-9]{6}\b/fx.<RUN>/g;
    s/\bINTERDIMUX_NOW=\d+/INTERDIMUX_NOW=<NOW>/g;
  '
}

declare -i N_SC=0 N_SAME=0 N_DIFF=0 N_RETRIED=0 N_SKIP=0
SIDES=(A B)
declare -A WT_OF=([A]="$WT_A" [B]="$WT_B")
SCRIPT="$RUN/plugin/scripts/interdimux.sh"

use_side() { # $1 = A|B: point the shared plugin path at that worktree
  ln -sfn "${WT_OF[$1]}" "$RUN/plugin"
  CUR_SIDE="$1"
}

# compare one scenario's two files; sets CMP_DIFF to the diff path or ""
compare_files() { # $1 = relative path
  local rel="$1" a="$OUT/A/$1" b="$OUT/B/$1"
  CMP_DIFF=""
  if [ -f "$a" ] && [ -f "$b" ] && cmp -s "$a" "$b"; then return 0; fi
  CMP_DIFF="$OUT/diff/${rel%.txt}.diff"
  mkdir -p "$(dirname "$CMP_DIFF")"
  {
    printf '# uxdiff %s\n# A: %s\n# B: %s\n' "$rel" "$WT_A" "$WT_B"
    if [ ! -f "$a" ] || [ ! -f "$b" ]; then
      printf '# missing on side %s\n' "$([ -f "$a" ] && echo B || echo A)"
    fi
    printf '\n# --- plain text (SGR stripped) ---\n'
    diff -u --label "A/$rel" --label "B/$rel" \
      <(plain < "$a" 2>/dev/null) <(plain < "$b" 2>/dev/null)
    printf '\n# --- exact bytes (cat -v: colours and attributes) ---\n'
    diff -u --label "A/$rel" --label "B/$rel" \
      <(cat -v "$a" 2>/dev/null) <(cat -v "$b" 2>/dev/null)
  } > "$CMP_DIFF"
  return 1
}
plain() { perl -pe 's/\e\[[0-9;:]*[A-Za-z]//g; s/\e\][^\a]*\a//g'; }

want() { [ -z "$FILTER" ] || [[ "$1" =~ $FILTER ]]; }

# run_scenario KIND NAME FUNC [ARGS...]: FUNC writes $SC_FILE for the current side
run_scenario() {
  local kind="$1" name="$2" fn="$3"; shift 3
  local rel="$kind/$name.txt" side attempt=0 line prev="" repro=0
  want "$kind/$name" || return 0
  (( N_SC += 1 ))
  if [ "$kind" = screen ] && [ "${FIXTURE_BROKEN:-0}" = 1 ]; then
    (( N_SKIP += 1 ))
    printf 'SKIPPED    %s (an earlier scenario changed the fixture)\n' "$kind/$name" | tee -a "$OUT/summary.txt"
    return 0
  fi
  while :; do
    for side in "${SIDES[@]}"; do
      use_side "$side"
      fx_restore
      SC_FILE="$OUT/$side/$rel"
      mkdir -p "$(dirname "$SC_FILE")"; : > "$SC_FILE"
      [ "$kind" = text ] && msg_mark
      "$fn" "$@"
      [ "$kind" = text ] && side_effects
    done
    compare_files "$rel" && break
    [ "$kind" = screen ] && [ "$attempt" -lt "$RETRIES" ] && [ "${FIXTURE_BROKEN:-0}" = 0 ] || break
    # A retry that reproduces BOTH sides byte for byte is a real difference,
    # not a timing artefact: stop there.
    if [ "$attempt" -gt 0 ] && cmp -s "$OUT/A/$rel" "$prev.A" && cmp -s "$OUT/B/$rel" "$prev.B"; then
      repro=1; break
    fi
    attempt=$((attempt + 1))
    # keep each attempt's evidence
    prev="$OUT/retry/${rel%.txt}.attempt$attempt"
    mkdir -p "$(dirname "$prev")"
    cp "$CMP_DIFF" "$prev.diff" 2>/dev/null
    cp "$OUT/A/$rel" "$prev.A"; cp "$OUT/B/$rel" "$prev.B"
  done
  if [ -z "$CMP_DIFF" ]; then
    (( N_SAME += 1 ))
    if [ "$attempt" -gt 0 ]; then
      (( N_RETRIED += 1 ))
      line=$(printf 'IDENTICAL  %-44s (retried %d: first attempt(s) differed, see %s)' "$kind/$name" "$attempt" "$OUT/retry")
    else
      line=$(printf 'IDENTICAL  %s' "$kind/$name")
    fi
  else
    (( N_DIFF += 1 ))
    line=$(printf 'DIFF       %-44s %s' "$kind/$name" "$CMP_DIFF")
    [ "$repro" = 1 ] && line+="  (reproduced on a retry)"
  fi
  printf '%s\n' "$line" | tee -a "$OUT/summary.txt"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
commit_of() {
  local c
  c=$(git -C "$1" log -1 --format='%h %s' 2>/dev/null | cut -c1-70)
  printf '%s' "${c:-not a git checkout}"
}
{
  printf 'uxdiff: A = %s  (%s)\n' "$WT_A" "$(commit_of "$WT_A")"
  printf 'uxdiff: B = %s  (%s)\n' "$WT_B" "$(commit_of "$WT_B")"
  printf 'uxdiff: out = %s\n' "$OUT"
  if [ -n "${IMUX_DEV_OTHERS:-}" ]; then
    printf 'uxdiff: WARNING: other dev containers were up when this run started (screens may settle late):\n'
    printf '%s\n' "$IMUX_DEV_OTHERS" | tr ';' '\n' | sed '/^ *$/d; s/^ */    /'
  fi
} | tee "$OUT/summary.txt"

fx_build || die "the fixture could not be built (see above)"
scr_attach 120 40 || die "the fixture client could not attach"
# The pristine fixture: every scenario must leave it like this.
fx_layout > "$RUN/layout.0"

text_scenarios

if [ "$QUICK" = 0 ]; then
  screen_scenarios
fi

# the fixture's fake at must never have been called
if [ -s "$RUN/at-calls.log" ]; then
  printf 'uxdiff: WARNING: something called at/atrm (recorded, nothing queued):\n' | tee -a "$OUT/summary.txt"
  norm < "$RUN/at-calls.log" | sed 's/^/    /' | tee -a "$OUT/summary.txt"
fi

ELAPSED=$(perl -e 'printf "%.1f", $ARGV[0] - $ARGV[1]' "$EPOCHREALTIME" "$TSTART")
{
  printf -- '----\n'
  printf 'uxdiff: %d scenarios: %d identical, %d DIFF' "$N_SC" "$N_SAME" "$N_DIFF"
  [ "$N_RETRIED" -gt 0 ] && printf ' (%d identical only on a retry)' "$N_RETRIED"
  [ "$N_SKIP" -gt 0 ] && printf ', %d SKIPPED' "$N_SKIP"
  [ "${N_TIMEOUTS:-0}" -gt 0 ] && printf ', %d screen settle timeouts' "$N_TIMEOUTS"
  printf ' -- %ss%s\n' "$ELAPSED" "$([ "$QUICK" = 1 ] && echo ' (quick: text only)')"
  [ "$N_DIFF" -gt 0 ] && printf 'uxdiff: diffs under %s\n' "$OUT/diff"
} | tee -a "$OUT/summary.txt"

if [ "$N_DIFF" = 0 ] && [ "$N_SKIP" = 0 ]; then exit 0; fi
exit 1
