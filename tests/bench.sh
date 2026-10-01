#!/usr/bin/env bash
#
# A/B timing of the paths a keypress waits on, this checkout against a commit:
#
#   tests/bench.sh [-n PAIRS] [-s SCENARIO,...] [REF]     REF defaults to HEAD
#
# Not a suite -- run_all.sh runs only test_*.sh -- because a timing moves with
# the machine's load: it informs a change, it cannot gate one.  The gate is
# tests/test_exec_budget.sh, which counts what these paths execute.  Paste the
# table into a perf-relevant change's description.
#
# A is REF, extracted with `git archive` and given its OWN Rust core (a binary
# built from this checkout cannot serve an older script: the stdin protocol is
# versioned); B is this working tree, as it is, with the core it has built.
# Unlike cores make it a comparison of renderers, not of commits, so it stops
# rather than print one: when REF's core does not build, or this checkout's is
# missing or older than rust/.  Both run against one private tmux server of
# SESSIONS x WINDOWS (default 6 x 4, every pane `sleep`) and a ~/work of DIRS
# project directories (default 30, all named svc-N), with the environment a
# popup or fzf gives them, in pairs whose order alternates, so a load burst
# lands on both.  It needs bash 5.0 or newer for $EPOCHREALTIME -- the
# script's own floor, 4.3, is not this tool's.
#
# Per scenario: the median CPU (user+sys of the run and every child it waits
# for -- not the tmux server's own work) and wall time, A and B, and B's change
# in %.  Differences under ~5% are noise on a busy machine; rerun before
# believing one.
#
#   first-row   the navigator, to the first row its fzf receives (a stand-in
#               fzf stamps it); CPU is the whole open-and-cancel
#   list        a --list reload (Rust core, then the bash renderer)
#   preview-S/W a cursor move's --preview of a session and a window row
#   preview-D   ...and of a directory row: a dirty git repo with a README
#   footer      --footer-for with a query typed (each keystroke)
#   scope       --scope-prompt (bash startup and parse, little else)
#   dirs-list   the ctrl-o picker's list (and each of its ctrl-r reloads)
#   dirs-deep   ctrl-f's --dirs-list --deep svc, which matches every DIRS
#   doctor      --doctor (stand-ins for at/atq: no at queue is read)
#   parse       bash -n on the script

set -euo pipefail

PAIRS=20
ALL="first-row list list-bash preview-S preview-W preview-D footer scope dirs-list dirs-deep doctor parse"
PICK=""
while getopts n:s: o; do
  case $o in
    n) PAIRS=$OPTARG ;;
    s) PICK=$OPTARG ;;
    *) echo "usage: tests/bench.sh [-n PAIRS] [-s SCENARIO,...] [REF]" >&2; exit 2 ;;
  esac
done
read -r -a SCENARIOS <<< "${PICK:+${PICK//,/ }}"
[ "${#SCENARIOS[@]}" -gt 0 ] || read -r -a SCENARIOS <<< "$ALL"
for sc in "${SCENARIOS[@]}"; do
  case " $ALL " in *" $sc "*) ;; *) echo "bench.sh: no scenario '$sc' (there are: $ALL)" >&2; exit 2 ;; esac
done
shift $((OPTIND - 1))
REF="${1:-HEAD}"
case "$PAIRS" in ''|*[!0-9]*|0) echo "bench.sh: -n wants a positive number" >&2; exit 2 ;; esac
[ -n "${EPOCHREALTIME:-}" ] || { echo "bench.sh: needs bash 5.0 or newer (\$EPOCHREALTIME)" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK="interdimux-bench-$$"
TMPD="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/interdimux-bench.XXXXXX")" && pwd -P)"
SESSIONS="${IMUX_BENCH_SESSIONS:-6}" WINDOWS="${IMUX_BENCH_WINDOWS:-4}" DIRS="${IMUX_BENCH_DIRS:-30}"

SOCK_PATH=""
# kill-server leaves the socket file behind (tmux 3.7b): remove it by name
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -f ${SOCK_PATH:+"$SOCK_PATH"}; rm -rf "$TMPD"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
unset TMUX TMUX_PANE INTERDIMUX_BIN INTERDIMUX_USE_RUST INTERDIMUX_PROJECT_DIRS

# --- B: this checkout, with the core built from it ---------------------------
BBIN="$ROOT/rust/target/release/imux"
if [ ! -x "$BBIN" ] || [ -n "$(find "$ROOT/rust/src" "$ROOT/rust/Cargo.toml" -newer "$BBIN" -print 2>/dev/null | head -1)" ]; then
  echo "bench.sh: this checkout's Rust core is missing or older than rust/: (cd rust && cargo build --release)" >&2
  exit 2
fi

# --- A: REF, with its own core --------------------------------------------
mkdir -p "$TMPD/a"
git -C "$ROOT" archive "$REF" | tar -x -C "$TMPD/a"
ACORE="its own Rust core"
if [ ! -d "$TMPD/a/rust" ]; then
  ACORE="the bash renderer: REF has no Rust core"
else
  command -v cargo >/dev/null 2>&1 || { echo "bench.sh: no cargo to build $REF's Rust core" >&2; exit 2; }
  # this checkout's build tree as a cache: only what differs is rebuilt
  [ -d "$ROOT/rust/target" ] && cp -a "$ROOT/rust/target" "$TMPD/a/rust/" 2>/dev/null || true
  echo "building $REF's Rust core..." >&2
  cargo build --release --quiet --manifest-path "$TMPD/a/rust/Cargo.toml" >&2 \
    || { echo "bench.sh: $REF's Rust core did not build" >&2; exit 1; }
fi
A="$TMPD/a/scripts/interdimux.sh" B="$ROOT/scripts/interdimux.sh"

# --- the server ---------------------------------------------------------------
mkdir -p "$TMPD/home" "$TMPD/run" "$TMPD/fzf"
chmod 700 "$TMPD/run"
for s in $(seq 1 "$SESSIONS"); do
  if [ "$s" = 1 ]; then
    tmux -f /dev/null -L "$SOCK" new-session -d -s "s$s" -x 158 -y 35 -c "$TMPD/home" 'exec sleep 3600'
    tmux -L "$SOCK" set -g automatic-rename off
  else
    tmux -L "$SOCK" new-session -d -s "s$s" -x 158 -y 35 -c "$TMPD/home" 'exec sleep 3600'
  fi
  for w in $(seq 2 "$WINDOWS"); do
    tmux -L "$SOCK" new-window -d -t "=s$s:" -n "w$w" -c "$TMPD/home" 'exec sleep 3600'
  done
  tmux -L "$SOCK" split-window -d -t "=s$s:1" -c "$TMPD/home" 'exec sleep 3600'
done
SOCK_PATH="$(tmux -L "$SOCK" display-message -p '#{socket_path}')"
export TMUX="$SOCK_PATH,99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -t '=s1:1' -F '#{pane_id}' | head -1)"
export HOME="$TMPD/home" XDG_RUNTIME_DIR="$TMPD/run" XDG_DATA_HOME="$TMPD/home/.local/share"
unset XDG_CONFIG_HOME
export INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
export INTERDIMUX_NOW="$(date +%s)"
# ~/work: DIRS directories that `svc` matches, each with a subdirectory, and
# the first a git repo with a commit, a README and an uncommitted change (made
# under the fixture HOME, so no git or fd config of yours applies)
for d in $(seq 1 "$DIRS"); do mkdir -p "$TMPD/home/work/svc-$d/src"; done
REPO="$TMPD/home/work/svc-1"
printf '# svc-1\n\nThe first service.\n' > "$REPO/README.md"
git -C "$REPO" init -q && git -C "$REPO" add README.md \
  && git -C "$REPO" -c user.name=bench -c user.email=bench@example.invalid commit -qm init \
  && echo change >> "$REPO/README.md" || echo "  (no git repo: preview-D previews a plain directory)" >&2
# at, atq, atrm and batch for --doctor: nothing reads or touches a real queue
mkdir -p "$TMPD/stubs"
for t in at atq atrm batch; do printf '#!/bin/sh\nexit 0\n' > "$TMPD/stubs/$t"; chmod +x "$TMPD/stubs/$t"; done
# the stand-in fzf: stamps the first row it is handed, reads the rest, cancels
cat > "$TMPD/fzf/fzf" <<'FZF'
#!/usr/bin/env bash
case " $* " in *" --version "*) echo "0.74.3 (stand-in)"; exit 0 ;; esac
IFS= read -r _ && printf '%s\n' "$EPOCHREALTIME" > "$IMUX_BENCH_STAMP"
while IFS= read -r _; do :; done
exit 130
FZF
chmod +x "$TMPD/fzf/fzf"
FZFENV=(FZF_COLUMNS=158 FZF_LINES=35 FZF_PREVIEW_COLUMNS=63 FZF_PREVIEW_LINES=33)

# one SCENARIO SCRIPT SIDE: CPU and wall, in microseconds, appended to the
# scenario's file for SIDE (A or B)
TIMEFORMAT='%3U %3S'
one() {
  local sc="$1" script="$2" side="$3" t0 t1 cpu first=""
  local -a cmd
  case "$sc" in
    first-row) cmd=(env PATH="$TMPD/fzf:$PATH" IMUX_BENCH_STAMP="$TMPD/stamp" bash "$script") ;;
    list)      cmd=(env "${FZFENV[@]}" bash "$script" --list) ;;
    list-bash) cmd=(env "${FZFENV[@]}" INTERDIMUX_USE_RUST=off bash "$script" --list) ;;
    preview-S) cmd=(env "${FZFENV[@]}" bash "$script" --preview S:s2) ;;
    preview-W) cmd=(env "${FZFENV[@]}" bash "$script" --preview W:s2:2) ;;
    preview-D) cmd=(env "${FZFENV[@]}" bash "$script" --preview "D:$REPO") ;;
    footer)    cmd=(env "${FZFENV[@]}" FZF_QUERY=s2 FZF_MATCH_COUNT=5 bash "$script" --footer-for W:s2:2) ;;
    scope)     cmd=(env "${FZFENV[@]}" FZF_NTH=1 bash "$script" --scope-prompt) ;;
    dirs-list) cmd=(env "${FZFENV[@]}" INTERDIMUX_PROJECT_DIRS="$TMPD/home/work" bash "$script" --dirs-list) ;;
    dirs-deep) cmd=(env "${FZFENV[@]}" INTERDIMUX_PROJECT_DIRS="$TMPD/home/work" bash "$script" --dirs-list --deep svc) ;;
    doctor)    cmd=(env PATH="$TMPD/stubs:$PATH" bash "$script" --doctor) ;;
    parse)     cmd=(bash -n "$script") ;;
  esac
  rm -f "$TMPD/stamp"
  t0=$EPOCHREALTIME
  cpu=$( { time "${cmd[@]}" </dev/null >/dev/null 2>&1; } 2>&1 ) || :
  t1=$EPOCHREALTIME
  [ "$sc" = first-row ] && [ -s "$TMPD/stamp" ] && read -r first < "$TMPD/stamp" && t1="$first"
  # user + sys, and the wall time, both in microseconds
  set -- $cpu
  printf '%s %s\n' "$(( (10#${1/./} + 10#${2/./}) * 1000 ))" "$(( 10#${t1/./} - 10#${t0/./} ))" >> "$TMPD/$sc.$side"
}

median() { sort -n | awk '{ v[NR] = $1 } END { if (NR) printf "%.1f", (NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2) / 1000 }'; }

printf 'A = %s (%s, %s), B = this checkout; %s pairs, %s sessions x %s windows, %s dirs; load %s\n\n' \
  "$REF" "$(git -C "$ROOT" rev-parse --short "$REF")" "$ACORE" "$PAIRS" "$SESSIONS" "$WINDOWS" "$DIRS" \
  "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo ?)"
printf '%-11s %9s %9s %7s   %9s %9s %7s\n' scenario 'A cpu ms' 'B cpu ms' 'cpu' 'A wall' 'B wall' 'wall'
for sc in "${SCENARIOS[@]}"; do
  one "$sc" "$A" A; one "$sc" "$B" B          # warm-up, discarded
  : > "$TMPD/$sc.A"; : > "$TMPD/$sc.B"
  for i in $(seq 1 "$PAIRS"); do
    if [ $((i % 2)) = 1 ]; then one "$sc" "$A" A; one "$sc" "$B" B
    else one "$sc" "$B" B; one "$sc" "$A" A; fi
  done
  ac=$(cut -d' ' -f1 "$TMPD/$sc.A" | median); bc=$(cut -d' ' -f1 "$TMPD/$sc.B" | median)
  aw=$(cut -d' ' -f2 "$TMPD/$sc.A" | median); bw=$(cut -d' ' -f2 "$TMPD/$sc.B" | median)
  printf '%-11s %9s %9s %6s%%   %9s %9s %6s%%\n' "$sc" "$ac" "$bc" \
    "$(awk -v a="$ac" -v b="$bc" 'BEGIN { printf "%+.1f", (a > 0 ? (b - a) * 100 / a : 0) }')" "$aw" "$bw" \
    "$(awk -v a="$aw" -v b="$bw" 'BEGIN { printf "%+.1f", (a > 0 ? (b - a) * 100 / a : 0) }')"
done
