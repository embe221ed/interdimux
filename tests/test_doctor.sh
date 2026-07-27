#!/usr/bin/env bash
#
# --doctor, and the runtime guards behind it.
#
# The two halves are different in kind and both matter:
#
#   * --doctor REPORTS.  A user option is free-form as far as tmux is concerned,
#     so `@interdimux-fzf-opt` (no 's') was never an error — the setting just
#     never applied, with nothing to tell the user why.
#   * the numeric guards PROTECT.  A non-numeric @interdimux-recent-limit made
#     `[ "$count" -ge "$RECENT_LIMIT" ]` print "integer expression expected", and
#     that stderr lands on the popup, over the list.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-doctor-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-doctor.XXXXXX")"
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

echo "interdimux doctor tests"
echo

tmux -f /dev/null -L "$SOCK" new-session -d -s doc -x 120 -y 40
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307

setopt()   { tmux -L "$SOCK" set -g "@interdimux-$1" "$2"; }
unsetopt() { tmux -L "$SOCK" set -gu "@interdimux-$1" 2>/dev/null || true; }
# --doctor exits 1 when it finds a problem, which is the point of it -- so
# every caller must defuse it or `set -e` ends the suite at the first bad config.
doctor()   { bash "$SCRIPT" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; return 0; }
doctor_rc() { bash "$SCRIPT" --doctor >/dev/null 2>&1; echo $?; }

# --- a healthy install passes ---------------------------------------------------
bash "$SCRIPT" --bind-keys
if [ "$(doctor_rc)" = 0 ]; then
  report "a healthy install exits 0" pass
else
  report "a healthy install exits 0" fail
  ERRORS+="$(doctor | grep '✗' | sed 's/^/    /')"$'\n'
fi
if doctor | grep -q '✓ prefix+f opens the navigator'; then
  report "the navigator binding is detected" pass
else
  report "the navigator binding is detected" fail
  ERRORS+="$(doctor | sed -n '/key bindings/,/^$/p' | sed 's/^/    /')"$'\n'
fi

# --- a missing binding is reported, not assumed ---------------------------------
tmux -L "$SOCK" unbind-key f
if doctor | grep -q '✗ prefix+f is not bound'; then
  report "a missing binding is reported" pass
else
  report "a missing binding is reported" fail
fi
bash "$SCRIPT" --bind-keys

# --- a mistyped option name ------------------------------------------------------
setopt fzf-opt '--cycle'
out=$(doctor) || true
if printf '%s' "$out" | grep -q 'unknown option @interdimux-fzf-opt'; then
  report "a mistyped option name is reported" pass
else
  report "a mistyped option name is reported" fail
  ERRORS+="$(printf '%s' "$out" | sed -n '/options/,$p' | sed 's/^/    /')"$'\n'
fi
if printf '%s' "$out" | grep -q 'did you mean @interdimux-fzf-opts'; then
  report "...with the intended name suggested" pass
else
  report "...with the intended name suggested" fail
fi
if [ "$(doctor_rc)" = 1 ]; then
  report "a bad config exits non-zero" pass
else
  report "a bad config exits non-zero" fail
fi
unsetopt fzf-opt

# --- an unrecognisable name gets no bogus suggestion ------------------------------
setopt wibble x
out=$(doctor) || true
if printf '%s' "$out" | grep -q 'unknown option @interdimux-wibble' && \
   ! printf '%s' "$out" | grep -q 'wibble — did you mean'; then
  report "an unrecognisable name is reported without a made-up suggestion" pass
else
  report "an unrecognisable name is reported without a made-up suggestion" fail
fi
unsetopt wibble

# --- out-of-domain values ---------------------------------------------------------
declare -A BAD=(
  [order]='recent'
  [show-preview]='true'
  [recent-limit]='lots'
  [color-accent]='#ab'
  [popup-width]='wide'
  [key]='ff'
)
for opt in "${!BAD[@]}"; do
  setopt "$opt" "${BAD[$opt]}"
  if doctor | grep -q "✗ @interdimux-$opt = '${BAD[$opt]}'"; then
    report "@interdimux-$opt='${BAD[$opt]}' is rejected" pass
  else
    report "@interdimux-$opt='${BAD[$opt]}' is rejected" fail
    ERRORS+="    $(doctor | grep "$opt" | sed 's/^ *//')"$'\n'
  fi
  unsetopt "$opt"
done

# --- ...and legitimate ones are not ------------------------------------------------
declare -A GOOD=(
  [order]='index'
  [show-preview]='on'
  [recent-limit]='25'
  [color-accent]='#e78a4e'
  [color-path]='180'
  [color-git]='default'
  [popup-width]='80%'
  [popup-height]='40'
  [key]='j'
)
for opt in "${!GOOD[@]}"; do setopt "$opt" "${GOOD[$opt]}"; done
out=$(doctor) || true
bad_good=$(printf '%s' "$out" | grep '✗ @interdimux-' || true)
if [ -z "$bad_good" ]; then
  report "a valid config produces no option complaints" pass
else
  report "a valid config produces no option complaints" fail
  ERRORS+="$(printf '%s' "$bad_good" | sed 's/^/    /')"$'\n'
fi
for opt in "${!GOOD[@]}"; do unsetopt "$opt"; done

# --- an unwritable state dir is reported, not silently swallowed --------------------
mkdir -p "$TMPD/ro"
chmod 500 "$TMPD/ro"
# capture first: under `set -o pipefail` the doctor's exit 1 -- which is exactly
# what it should return here -- would fail the pipeline even though grep matched
ro_out=$(XDG_DATA_HOME="$TMPD/ro" bash "$SCRIPT" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g') || true
if printf '%s' "$ro_out" | grep -q '✗ not writable'; then
  report "an unwritable data dir is reported" pass
else
  report "an unwritable data dir is reported" fail
fi

# ...and, more importantly, does not spill onto the popup.  Remembering a
# directory is a convenience; an unwritable data dir must cost the user nothing
# but that convenience.  Observed before the fix: mkdir and mktemp each printed
# "Permission denied" over the rendered rows, and the empty $tmp made
# `echo > ""` a third error.
mkdir -p "$TMPD/ro2" && chmod 500 "$TMPD/ro2"
# a plain name: resolve_session_name rewrites '.' (tmux cannot address a session
# whose name contains one), so $TMPD's own mktemp suffix would not be the name
mkdir -p "$TMPD/rwproj"
err=$(XDG_DATA_HOME="$TMPD/ro2" bash "$SCRIPT" --connect-dir "$TMPD/rwproj" 2>&1 >/dev/null) || true
if [ -z "$err" ]; then
  report "an unwritable data dir produces no output on the popup" pass
else
  report "an unwritable data dir produces no output on the popup" fail
  ERRORS+="    stderr: $(printf '%s' "$err" | head -3 | tr '\n' '|')"$'\n'
fi
# and the switch it was asked for still happened
if tmux -L "$SOCK" has-session -t '=rwproj' 2>/dev/null; then
  report "...and the session was still created" pass
else
  report "...and the session was still created" fail
fi
chmod 700 "$TMPD/ro2"
chmod 700 "$TMPD/ro"

# --- navigator errors are logged, not painted over the list ------------------------
# The popup's stderr IS the popup: anything written there lands across the
# rendered rows and then vanishes with the popup.  A read-only data dir used to
# produce three "Permission denied" lines smeared over the tree.  Now stderr
# goes to the status line and a log, and --doctor is where you find the log.
if doctor | grep -q '✓ no navigator errors logged'; then
  report "a clean install reports no logged errors" pass
else
  report "a clean install reports no logged errors" fail
fi

mkdir -p "$XDG_STATE_HOME/interdimux"
printf '== 2026-01-01 00:00:00 navigator stderr\nsomething went wrong\n' \
  > "$XDG_STATE_HOME/interdimux/errors.log"
out=$(doctor)
if printf '%s' "$out" | grep -q '✗ the navigator has logged 1 error'; then
  report "a logged error is surfaced by --doctor" pass
else
  report "a logged error is surfaced by --doctor" fail
  ERRORS+="$(printf '%s' "$out" | grep -i 'error' | sed 's/^/    /')"$'\n'
fi
if printf '%s' "$out" | grep -q 'something went wrong'; then
  report "...and it quotes the most recent one" pass
else
  report "...and it quotes the most recent one" fail
fi
rm -f "$XDG_STATE_HOME/interdimux/errors.log"

# The whole point: an error must reach the log rather than the rendered rows.
# Driven end to end, because the redirect happens in the navigator and a
# --list-style child keeps its real stderr on purpose.
if command -v fzf >/dev/null 2>&1; then
  ERRD="$TMPD/errstate"
  OUTER="${SOCK}-errouter"
  tmux -f /dev/null -L "$OUTER" new-session -d -s drv -x 120 -y 30 \
    "env TMUX='$TMUX' TMUX_PANE='$TMUX_PANE' XDG_STATE_HOME='$ERRD' \
         INTERDIMUX_OPTS_PRIMED=1 INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 \
         INTERDIMUX_USE_ZOXIDE=off INTERDIMUX_FZF_OPTS='--totally-bogus-flag' \
         bash '$SCRIPT'; sleep 5"
  for _i in $(seq 1 80); do
    [ -s "$ERRD/interdimux/errors.log" ] && break
    sleep 0.1
  done
  if grep -q 'totally-bogus-flag' "$ERRD/interdimux/errors.log" 2>/dev/null; then
    report "a real navigator failure reaches the error log" pass
  else
    report "a real navigator failure reaches the error log" fail
    # `|| true`: under `set -o pipefail` a missing log makes the whole
    # substitution non-zero, and the assignment then kills the suite --
    # the failure branch must not be able to take the harness down with it
    ERRORS+="    log: $( (cat "$ERRD/interdimux/errors.log" 2>/dev/null || true) | head -2 | tr '\n' '|')"$'\n'
  fi
  # ...and it was ALSO announced, so the user is not expected to go looking
  if tmux -L "$SOCK" show-messages 2>/dev/null | grep -q 'interdimux: unknown option'; then
    report "...and announced on the status line" pass
  else
    report "...and announced on the status line" fail
  fi
  tmux -L "$OUTER" kill-server 2>/dev/null || true
fi

# --- THE BEHAVIOURAL HALF: junk numerics must not reach the popup -------------------
# Before the guard, a non-numeric limit turned every recent-dir comparison into
# "integer expression expected" on stderr, which display-popup paints over the
# list.  Assert on stderr specifically: the list itself still rendered, so a
# stdout-only check passed while the popup was visibly broken.
mkdir -p "$XDG_DATA_HOME/interdimux" "$TMPD/d1" "$TMPD/d2"
printf '%s\n%s\n' "$TMPD/d1" "$TMPD/d2" > "$XDG_DATA_HOME/interdimux/recent_dirs"
# BOTH renderers: the Rust core reads the limits from the environment itself, so
# the bash guard is what keeps the two agreeing.  Testing only the Rust path
# would miss the `[ -ge ]` failure entirely -- that lives in the bash fallback.
for renderer in rust bash; do
  [ "$renderer" = bash ] && export INTERDIMUX_USE_RUST=off || unset INTERDIMUX_USE_RUST
  for pair in "recent-limit:lots" "dirs-limit:many" "scan-depth:deep" "order:sideways"; do
    o="${pair%%:*}"; v="${pair#*:}"
    setopt "$o" "$v"
    err=$(bash "$SCRIPT" --list 2>&1 >/dev/null) || true
    if [ -z "$err" ]; then
      report "[$renderer] --list survives @interdimux-$o='$v' with no error output" pass
    else
      report "[$renderer] --list survives @interdimux-$o='$v' with no error output" fail
      ERRORS+="    stderr: $(printf '%s' "$err" | head -2)"$'\n'
    fi
    unsetopt "$o"
  done

  # and the fallback value is actually applied, not just "no crash" -- a limit of
  # zero would also produce no errors, and no directory rows either
  for o in recent-limit dirs-limit; do
    setopt "$o" 'lots'
    n=$(bash "$SCRIPT" --list 2>/dev/null | grep -c $'\tD:' || true)
    if [ "$n" -ge 1 ]; then
      report "[$renderer] a junk $o falls back to the default, not to zero rows" pass
    else
      report "[$renderer] a junk $o falls back to the default, not to zero rows" fail
    fi
    unsetopt "$o"
  done
done
unset INTERDIMUX_USE_RUST

# --- the same, for the dirs picker path --------------------------------------------
# scan-depth is only read here.  It is the quiet one: bash arithmetic reads a
# bare word as an unset variable and yields 0, so a junk value degrades the
# search silently instead of erroring -- but it must still be a number before the
# clamp compares it.  '40' is the other half: numeric but absurd, and
# `find -maxdepth 40` over $HOME does not return inside a popup's lifetime.
for v in 'deep' '40'; do
  setopt scan-depth "$v"
  err=$(timeout 30 bash "$SCRIPT" --dirs-list 'zz' 2>&1 >/dev/null); rc=$?
  if [ -z "$err" ] && [ "$rc" -ne 124 ]; then
    report "--dirs-list survives @interdimux-scan-depth='$v'" pass
  else
    report "--dirs-list survives @interdimux-scan-depth='$v'" fail
    ERRORS+="    rc=$rc stderr: $(printf '%s' "$err" | head -2)"$'\n'
  fi
  unsetopt scan-depth
done

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
