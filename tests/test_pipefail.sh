#!/usr/bin/env bash
#
# Accepting a row before a streaming producer has finished must not be read as
# a cancel.
#
# The script runs under `set -o pipefail`, and both pickers are shaped
# `sel=$(producer | fzf …) || exit 1`.  Both producers STREAM: gather_targets
# emits tmux rows as they are built, and --dirs-list is a filesystem scan
# (measured 76 ms with a default $HOME, seconds against a large project tree).
# Press Enter while rows are still arriving and fzf closes the pipe, the
# producer dies with SIGPIPE, and pipefail reports that 141 instead of fzf's 0.
# `|| exit 1` then treats a deliberate keystroke as a cancel and the selection
# is silently dropped — no error, nothing on screen, just nothing happening.
#
# PIPESTATUS cannot fix this: inside a command substitution it describes the
# substitution, not the inner pipeline, and ${PIPESTATUS[1]} is fatal under
# `set -u`.  Turning pipefail off for the pipeline is the fix.
#
# Two halves: the mechanism (does the producer really take SIGPIPE, and does
# pipefail really surface it), and a structural check that no future picker
# reintroduces the shape.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-pipefail-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-pf.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMPD"; }
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

echo "interdimux pipefail / early-accept tests"
echo

tmux -f /dev/null -L "$SOCK" new-session -d -s pf -x 120 -y 40
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data" INTERDIMUX_OPTS_PRIMED=1
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_USE_ZOXIDE=off
mkdir -p "$XDG_DATA_HOME/interdimux" "$TMPD/d1" "$TMPD/d2"
printf '%s\n%s\n' "$TMPD/d1" "$TMPD/d2" > "$XDG_DATA_HOME/interdimux/recent_dirs"

# A project tree big enough that the scan is still running when the reader stops.
# DURATION is what matters, not volume -- an earlier version of this comment
# claimed the tree existed to overflow the 64 KB pipe buffer, and that was
# measured false: --dirs-list emits 36,070 bytes here (47,330 at its widest,
# since DIRS_PATH_W clamps at 64), and a 2-row 178-byte fixture still yields
# 141.  What makes SIGPIPE deterministic is that the scan takes ~0.9 s and
# printf-writes one unbuffered row at a time, so the producer is always still
# writing when the reader goes away.  The tree also keeps the end-to-end
# accept-during-scan check below honest.
mkdir -p "$TMPD/big"
for i in $(seq 1 400); do mkdir -p "$TMPD/big/proj$i/sub"; done
export INTERDIMUX_PROJECT_DIRS="$TMPD/big"

# Restore SIGPIPE's default disposition for the probe below.  A parent that
# ignores SIGPIPE passes SIG_IGN across execve, and bash CANNOT undo that --
# `trap - PIPE` is a no-op for a signal ignored at shell entry (measured: it
# yields PIPESTATUS 1, not 141).  Both systemd (IgnoreSIGPIPE defaults to true)
# and GitHub Actions run us that way, and there the producer cannot die of
# SIGPIPE at all, so the assertion would be testing the harness rather than the
# script.  Nothing to reset when SIGPIPE is already default, so this is a no-op
# in a normal shell.
if env --default-signal=PIPE true 2>/dev/null; then
  DFLPIPE=(env --default-signal=PIPE)          # coreutils >= 8.30
elif command -v perl >/dev/null 2>&1; then
  DFLPIPE=(perl -e '$SIG{PIPE}="DEFAULT"; exec @ARGV')   # macOS / BSD env
else
  DFLPIPE=()
fi

# --- the mechanism: the producer really does die on a short read -----------------
st=$(${DFLPIPE[@]+"${DFLPIPE[@]}"} bash -c "bash '$SCRIPT' --dirs-list 2>/dev/null | head -1 >/dev/null; echo \"\${PIPESTATUS[0]}\"")
if [ "$st" = 141 ]; then
  report "--dirs-list dies with SIGPIPE when the reader stops early (rc $st)" pass
else
  report "--dirs-list dies with SIGPIPE when the reader stops early (rc $st, expected 141)" fail
fi

# ...and that pipefail is what turns that into a false cancel
rc=$(bash -c 'set -o pipefail; out=$( (echo row; sleep 1; echo more) | head -1 ); echo $?' 2>/dev/null || true)
rc_off=$(bash -c 'set +o pipefail; out=$( (echo row; sleep 1; echo more) | head -1 ); echo $?' 2>/dev/null || true)
if [ "$rc" != "0" ] && [ "$rc_off" = "0" ]; then
  report "pipefail is what reports the producer's death instead of the reader's success" pass
else
  report "pipefail is what reports the producer's death (on=$rc off=$rc_off)" fail
fi

# --- STRUCTURAL: every streaming `| fzf` whose status is consumed is guarded ------
# A rule rather than a list of known sites, so a picker added later is covered.
# printf-fed pipelines are exempt on purpose: their producer is an in-memory
# string that the reader drains far faster than any accept can arrive (pushed to
# a 5 MB list with Enter pre-stuffed — never reproduced), and printf into a pipe
# has no meaningful failure to mask.
unguarded=""
while IFS=: read -r lineno _; do
  [ -n "$lineno" ] || continue
  producer=$(sed -n "${lineno}p" "$SCRIPT")
  case "$producer" in
    *'printf '*'| fzf'*) continue ;;      # in-memory, cannot lose the race
    *'# '*)              continue ;;      # a comment mentioning the shape
  esac
  # look back for `set +o pipefail` without an intervening `set -o pipefail`
  guarded=0
  for back in $(seq 1 40); do
    probe=$(( lineno - back ))
    [ "$probe" -ge 1 ] || break
    ctx=$(sed -n "${probe}p" "$SCRIPT")
    case "$ctx" in
      *'set +o pipefail'*) guarded=1; break ;;
      *'set -o pipefail'*) break ;;
    esac
  done
  [ "$guarded" = 1 ] || unguarded+="$lineno "
done < <(grep -n '| fzf' "$SCRIPT")

if [ -z "$unguarded" ]; then
  report "every streaming '| fzf' pipeline sits inside a 'set +o pipefail' window" pass
else
  report "every streaming '| fzf' pipeline sits inside a 'set +o pipefail' window" fail
  for l in $unguarded; do
    ERRORS+="    unguarded at line $l: $(sed -n "${l}p" "$SCRIPT" | sed 's/^ *//')"$'\n'
  done
fi

# and the guard is closed again, so the rest of the script keeps pipefail
opened=$(grep -c 'set +o pipefail' "$SCRIPT" || true)
closed=$(grep -c '^ *set -o pipefail' "$SCRIPT" || true)
if [ "$opened" = "$closed" ]; then
  report "each pipefail window is closed again ($opened opened, $closed closed)" pass
else
  report "each pipefail window is closed again ($opened opened, $closed closed)" fail
fi

# --- END TO END: accept a directory row while the scan is still running -----------
# Uses the same deliberately-slow project tree built above, so the scan reliably
# outlives the accept.
OUTER="${SOCK}-outer"
trap 'tmux -L "$SOCK" kill-server 2>/dev/null || true; tmux -L "$OUTER" kill-server 2>/dev/null || true; rm -rf "$TMPD"' EXIT

early_accept_creates_a_session() { # -> prints "yes"/"no"
  local before after i
  before=$(tmux -L "$SOCK" list-sessions -F '#{session_name}' 2>/dev/null | sort)
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 130 -y 45 \
    "env TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' XDG_DATA_HOME='$XDG_DATA_HOME' \
         INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
         INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_PROJECT_DIRS='$TMPD/big' \
         bash '$SCRIPT' --dirs; sleep 4"
  # accept as soon as the FIRST rows paint — the scan is still running then
  for i in $(seq 1 100); do
    tmux -L "$OUTER" capture-pane -t '=drv:' -p 2>/dev/null | grep -q '★\|◆\|·' && break
    sleep 0.05
  done
  tmux -L "$OUTER" send-keys -t '=drv:' Enter
  for i in $(seq 1 80); do
    after=$(tmux -L "$SOCK" list-sessions -F '#{session_name}' 2>/dev/null | sort)
    [ "$after" != "$before" ] && { echo yes; return; }
    sleep 0.1
  done
  echo no
}

got=$(early_accept_creates_a_session)
if [ "$got" = yes ]; then
  report "accepting before the directory scan finishes still opens the directory" pass
else
  report "accepting before the directory scan finishes still opens the directory" fail
  ERRORS+="    the selection was silently dropped"$'\n'
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
