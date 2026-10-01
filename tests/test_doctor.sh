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
# --doctor reports on the INSTALL, and a renderer forced from outside is not
# part of one: under tests/run_all.sh's IMUX_RENDERER=bash the inherited
# INTERDIMUX_USE_RUST=off would make every report warn "rust helper disabled"
# and hide the helper checks below.  A case that wants a renderer pins it.
unset INTERDIMUX_USE_RUST
SOCK="interdimux-doctor-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-doctor.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMPD"; }
trap cleanup EXIT

# Every diagnostic below pipes through grep or sed, and the thing being
# diagnosed is by definition sometimes absent — at which point grep exits 1,
# `pipefail` promotes it, the assignment returns non-zero and `set -e` ends the
# run.  A real regression then arrives as "suite did not finish" with no
# Results line, which is the least useful shape a failure can take.  Hence the
# `|| true` on each of them.
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

# Two ambient inputs are pinned BEFORE the server starts.  The report checks the
# LOCALE (a container with none, or LC_ALL=C, is normal) and $FZF_DEFAULT_OPTS
# (most people have one) — and both feed assertions below about a HEALTHY
# install.  Unpinned, this suite failed 2/62 under `LC_ALL=C` and 1/62 with a
# --height in the developer's own fzf opts, neither of which is about the code.
# Before the server, because --doctor reads both from the tmux SERVER's
# environment — the one the popups get — and the server copies the environment
# it was started in.
export LC_ALL=C.UTF-8 LANG=C.UTF-8
unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE
# The agents section reads ~/.claude, ~/.codex and the title rules, which are
# the developer's, not the install's: a Claude that sends its alerts nowhere
# tmux can see would make "everything checks out" false for a reason that is
# not about this code (tests/test_doctor_agents.sh covers that section, with a
# fake HOME).  Pointed at directories that do not exist, each is one dim line.
export CLAUDE_CONFIG_DIR="$TMPD/no-claude" CODEX_HOME="$TMPD/no-codex" XDG_CONFIG_HOME="$TMPD/config"
unset INTERDIMUX_CLAUDE_DIR INTERDIMUX_TITLE_RULES CLAUDE_CODE_DISABLE_TERMINAL_TITLE

tmux -f /dev/null -L "$SOCK" new-session -d -s doc -x 120 -y 40
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307
# --doctor probes the live `at` job-runner (atd/atrun).  Its real state is a
# machine-global toggle that lives outside the repo — on a box with `at`
# installed but its daemon stopped (a default macOS is exactly this), the probe
# says "not active" and --doctor exits 1, which would make "a healthy install
# exits 0" flake for reasons the suite does not control.  Pin it, the same way
# INTERDIMUX_FZF_MINOR/TMUX_VNUM pin the version probes; the down/unknown paths
# get their own assertions below that override it locally.
export INTERDIMUX_AT_DAEMON=up

setopt()   { tmux -L "$SOCK" set -g "@interdimux-$1" "$2"; }
unsetopt() { tmux -L "$SOCK" set -gu "@interdimux-$1" 2>/dev/null || true; }
# The server's environment, which is what --doctor reads the locale, PATH and
# $FZF_DEFAULT_OPTS from.
senv()     { tmux -L "$SOCK" set-environment -g "$1" "$2"; }
unsenv()   { tmux -L "$SOCK" set-environment -gu "$1" 2>/dev/null || true; }
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
  ERRORS+="$(doctor | grep '✗' | sed 's/^/    /' || true)"$'\n'
fi
if doctor | grep -q '✓ prefix+f opens the navigator'; then
  report "the navigator binding is detected" pass
else
  report "the navigator binding is detected" fail
  ERRORS+="$(doctor | sed -n '/key bindings/,/^$/p' | sed 's/^/    /' || true)"$'\n'
fi

# --- a binding set up for another fzf (BUG-100) ----------------------------------
# --bind-keys bakes fzf's minor version into prefix+f, and every fzf feature the
# picker uses is gated on it; nothing refreshes it until the plugin reloads.
# Baked from a stand-in fzf on either side of the real one, which is what the
# server's PATH -- and so the doctor -- finds.
live_minor=$(fzf --version 2>/dev/null | awk '{print $1}' | cut -d. -f2)
if [[ "${live_minor:-}" =~ ^[0-9]+$ ]] && [ "$live_minor" -gt 40 ]; then
  bake_for() { # $1 = the minor version the stand-in reports
    mkdir -p "$TMPD/fzf-$1"
    printf '#!/bin/sh\necho "0.%s.0 (stub)"\n' "$1" > "$TMPD/fzf-$1/fzf"
    chmod +x "$TMPD/fzf-$1/fzf"
    PATH="$TMPD/fzf-$1:$PATH" bash "$SCRIPT" --bind-keys
  }
  old_m=$((live_minor - 1)) new_m=$((live_minor + 1))
  bake_for "$old_m"
  out=$(doctor)
  if grep -q "⚠ prefix+f was set up for fzf 0.$old_m, older than the fzf 0.$live_minor" <<< "$out" \
     && grep -q 'reload the plugin, or run:' <<< "$out"; then
    report "a binding set up for an older fzf is a warning that says to reload" pass
  else
    report "a binding set up for an older fzf is a warning that says to reload" fail
    ERRORS+="$(sed -n '/key bindings/,/^$/p' <<< "$out" | sed 's/^/    /' || true)"$'\n'
  fi
  bake_for "$new_m"
  out=$(doctor)
  if grep -q "✗ prefix+f was set up for fzf 0.$new_m, newer than the fzf 0.$live_minor" <<< "$out" \
     && [ "$(doctor_rc)" = 1 ]; then
    report "...one set up for a newer fzf, which may not open, is a problem" pass
  else
    report "...one set up for a newer fzf, which may not open, is a problem" fail
    ERRORS+="$(sed -n '/key bindings/,/^$/p' <<< "$out" | sed 's/^/    /' || true)"$'\n'
  fi
  bash "$SCRIPT" --bind-keys
  if grep -q 'was set up for fzf' <<< "$(doctor)"; then
    report "...and one set up for the fzf the popups run says nothing" fail
  else
    report "...and one set up for the fzf the popups run says nothing" pass
  fi
fi

# --- a missing binding is reported, not assumed ---------------------------------
tmux -L "$SOCK" unbind-key f
if doctor | grep -q '✗ prefix+f is not bound'; then
  report "a missing binding is reported" pass
else
  report "a missing binding is reported" fail
fi
bash "$SCRIPT" --bind-keys

# --- ...and a present one is not reported missing, whatever the table's size ------
# The check matched the table with `printf … | grep -q` under pipefail: grep -q
# exits at its first match, the printf still writing the rest dies of SIGPIPE,
# and pipefail makes that "no match" -- "✗ no interdimux key bindings are
# installed" on a machine that had them.  Under load that was a race any table
# could lose (the suites flaked on it); with this much bound AFTER prefix+f
# (function and meta keys sort after the letters) it is lost every time.  The
# premise is the shell's own verdict on that pipeline.
long=$(printf 'x%.0s' $(seq 1 3000))
bigkeys="F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12 M-a M-b M-c M-d M-e M-h M-i M-j M-k M-l M-m M-q M-r M-s M-t M-u M-v M-w M-x M-y M-z"
for k in $bigkeys; do tmux -L "$SOCK" bind-key -T prefix "$k" display-message "$long"; done
table=$(tmux -L "$SOCK" list-keys -T prefix)
if printf '%s' "$table" | grep -q interdimux; then
  report "premise: a pipe into grep -q loses this table's match to SIGPIPE" fail
else
  out=$(doctor)
  case "$out" in
    *"✓ prefix+f opens the navigator"*) report "a big key table still shows prefix+f bound" pass ;;
    *) report "a big key table still shows prefix+f bound" fail
       ERRORS+="$(printf '%s\n' "$out" | sed -n '/key bindings/,/^$/p' | sed 's/^/    /' || true)"$'\n' ;;
  esac
  case "$out" in
    *"✓ prefix+g opens the dashboard"*) report "...and prefix+g" pass ;;
    *) report "...and prefix+g" fail ;;
  esac
fi
for k in $bigkeys; do tmux -L "$SOCK" unbind-key -T prefix "$k"; done

# --- a mistyped option name ------------------------------------------------------
setopt fzf-opt '--cycle'
out=$(doctor) || true
if grep -q 'unknown option @interdimux-fzf-opt' <<< "$out"; then
  report "a mistyped option name is reported" pass
else
  report "a mistyped option name is reported" fail
  ERRORS+="$(printf '%s' "$out" | sed -n '/options/,$p' | sed 's/^/    /' || true)"$'\n'
fi
if grep -q 'did you mean @interdimux-fzf-opts' <<< "$out"; then
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
if grep -q 'unknown option @interdimux-wibble' <<< "$out" && \
   ! grep -q 'wibble — did you mean' <<< "$out"; then
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
    ERRORS+="    $(doctor | grep "$opt" | sed 's/^ *//' || true)"$'\n'
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
  ERRORS+="$(printf '%s' "$bad_good" | sed 's/^/    /' || true)"$'\n'
fi
for opt in "${!GOOD[@]}"; do unsetopt "$opt"; done

# --- an unwritable state dir is reported, not silently swallowed --------------------
mkdir -p "$TMPD/ro"
chmod 500 "$TMPD/ro"
# capture first: under `set -o pipefail` the doctor's exit 1 -- which is exactly
# what it should return here -- would fail the pipeline even though grep matched
ro_out=$(XDG_DATA_HOME="$TMPD/ro" bash "$SCRIPT" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g') || true
if grep -q '✗ not writable' <<< "$ro_out"; then
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
  ERRORS+="    stderr: $(printf '%s' "$err" | head -3 | tr '\n' '|' || true)"$'\n'
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
if grep -q '✗ the navigator has logged 1 error' <<< "$out"; then
  report "a logged error is surfaced by --doctor" pass
else
  report "a logged error is surfaced by --doctor" fail
  ERRORS+="$(printf '%s' "$out" | grep -i 'error' | sed 's/^/    /' || true)"$'\n'
fi
if grep -q 'something went wrong' <<< "$out"; then
  report "...and it quotes the most recent one" pass
else
  report "...and it quotes the most recent one" fail
fi

# --- ...but a log you have seen does not keep it red for ever (UX-17) --------------
# Any entry at all used to fail --doctor until the file was deleted by hand.
# --doctor --ack marks what is logged as seen: still reported, as a warning,
# and the check fails again on the next new entry only.  The verdict is
# compared with the same report without the log, so nothing else in it counts.
ELOG="$XDG_STATE_HOME/interdimux/errors.log"
if grep -q 'most recent: 2026-01-01 00:00:00 — something went wrong' <<< "$out"; then
  report "the most recent error is dated" pass
else
  report "the most recent error is dated" fail
  ERRORS+="$(grep 'most recent' <<< "$out" | sed 's/^/    /' || true)"$'\n'
fi
# The flag ahead of the install path: the Health popup cuts a long line off,
# and a path that filled it hid the one thing the note is there to say.
if grep -q -- "^ *acknowledge[^']*--doctor --ack" <<< "$out"; then
  report "...and the report says how to acknowledge it, before the path" pass
else
  report "...and the report says how to acknowledge it, before the path" fail
  ERRORS+="$(grep 'acknowledge' <<< "$out" | sed 's/^/    /' || true)"$'\n'
fi
# a second entry, so that "everything so far" is more than the first one
printf '== 2026-01-02 08:00:00 navigator stderr\nsomething else\n' >> "$ELOG"
mv "$ELOG" "$TMPD/errors.held"; rc_clean=$(doctor_rc); mv "$TMPD/errors.held" "$ELOG"
ack=$(bash "$SCRIPT" --doctor --ack 2>&1) && ack_rc=0 || ack_rc=$?
if [ "$ack_rc" = 0 ] && grep -q '2 logged error(s) acknowledged' <<< "$ack"; then
  report "--doctor --ack acknowledges the logged errors" pass
else
  report "--doctor --ack acknowledges the logged errors (rc=$ack_rc: $ack)" fail
fi
out=$(doctor)
if grep -q '✗ the navigator has logged' <<< "$out"; then
  report "an acknowledged error is no longer a problem" fail
else
  report "an acknowledged error is no longer a problem" pass
fi
if grep -q '⚠ the navigator has logged 2 error(s), all acknowledged' <<< "$out" \
   && grep -q 'most recent: 2026-01-02 08:00:00 — something else' <<< "$out"; then
  report "...but still reported, as a warning naming the most recent" pass
else
  report "...but still reported, as a warning naming the most recent" fail
  ERRORS+="$(grep -A2 'navigator' <<< "$out" | sed 's/^/    /' || true)"$'\n'
fi
if [ "$(doctor_rc)" = "$rc_clean" ]; then
  report "...and does not fail --doctor (exit $rc_clean, as without the log)" pass
else
  report "...and does not fail --doctor (exit $rc_clean without the log)" fail
fi
[ "$(grep -c '^== ' "$ELOG")" = 2 ] \
  && report "...and the log itself is kept" pass \
  || report "...and the log itself is kept" fail
printf '== 2026-02-02 10:11:12 navigator stderr\n\nsomething new\n' >> "$ELOG"
out=$(doctor)
if grep -q '✗ the navigator has logged 1 new error(s)' <<< "$out" \
   && grep -q 'most recent: 2026-02-02 10:11:12 — something new' <<< "$out"; then
  report "a new error after the acknowledgement fails it again, counted alone" pass
else
  report "a new error after the acknowledgement fails it again, counted alone" fail
  ERRORS+="$(grep -A2 'navigator' <<< "$out" | sed 's/^/    /' || true)"$'\n'
fi
# Text above the first entry header -- a log cut by hand, or written by
# something else -- is an error like any other, and --ack must clear it too:
# counted as no entries at all, it stayed red while --ack said "no errors are
# logged".
printf 'junk with no header\n' > "$ELOG"
rm -f "$XDG_STATE_HOME/interdimux/errors.seen"
out=$(doctor)
if grep -q '✗ the navigator has logged 1 error(s)' <<< "$out" \
   && grep -q 'most recent: junk with no header' <<< "$out"; then
  report "text above the first entry is reported as an error" pass
else
  report "text above the first entry is reported as an error" fail
  ERRORS+="$(grep -A2 'navigator' <<< "$out" | sed 's/^/    /' || true)"$'\n'
fi
ack=$(bash "$SCRIPT" --doctor --ack 2>&1) && ack_rc=0 || ack_rc=$?
if [ "$ack_rc" = 0 ] && grep -q '1 logged error(s) acknowledged' <<< "$ack" \
   && [ "$(doctor_rc)" = "$rc_clean" ]; then
  report "...which --doctor --ack acknowledges like any other" pass
else
  report "...which --doctor --ack acknowledges like any other (rc=$ack_rc: $ack)" fail
fi
printf '== 2026-03-03 09:00:00 navigator stderr\nafter the junk\n' >> "$ELOG"
if grep -q '✗ the navigator has logged 1 new error(s)' <<< "$(doctor)"; then
  report "...and an entry after it is new" pass
else
  report "...and an entry after it is new" fail
fi
rm -f "$ELOG" "$XDG_STATE_HOME/interdimux/errors.seen"
ack=$(bash "$SCRIPT" --doctor --ack 2>&1) && ack_rc=0 || ack_rc=$?
[ "$ack_rc" = 0 ] && grep -q 'no errors are logged' <<< "$ack" \
  && report "--doctor --ack with nothing logged says so" pass \
  || report "--doctor --ack with nothing logged says so (rc=$ack_rc: $ack)" fail

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
  # Polled for the line the assertion wants, not for a non-empty file: the log
  # gets its "== <date>" header first and the stderr after it, and under load
  # the check landed in between.
  for _i in $(seq 1 80); do
    grep -q 'totally-bogus-flag' "$ERRD/interdimux/errors.log" 2>/dev/null && break
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
  if grep -q 'interdimux: unknown option' <<< "$(tmux -L "$SOCK" show-messages 2>/dev/null || true)"; then
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
# The loop pins each renderer in turn and then puts back what it INHERITED:
# `unset` here flipped the rest of this suite to the Rust core under
# IMUX_RENDERER=bash (tests/run_all.sh), silently.
_use_rust_was="${INTERDIMUX_USE_RUST-<unset>}"
for renderer in rust bash; do
  [ "$renderer" = bash ] && export INTERDIMUX_USE_RUST=off || export INTERDIMUX_USE_RUST=on
  for pair in "recent-limit:lots" "dirs-limit:many" "scan-depth:deep" "order:sideways"; do
    o="${pair%%:*}"; v="${pair#*:}"
    setopt "$o" "$v"
    err=$(bash "$SCRIPT" --list 2>&1 >/dev/null) || true
    if [ -z "$err" ]; then
      report "[$renderer] --list survives @interdimux-$o='$v' with no error output" pass
    else
      report "[$renderer] --list survives @interdimux-$o='$v' with no error output" fail
      ERRORS+="    stderr: $(printf '%s' "$err" | head -2 || true)"$'\n'
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
if [ "$_use_rust_was" = '<unset>' ]; then unset INTERDIMUX_USE_RUST
else export INTERDIMUX_USE_RUST="$_use_rust_was"; fi

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
    ERRORS+="    rc=$rc stderr: $(printf '%s' "$err" | head -2 || true)"$'\n'
  fi
  unsetopt scan-depth
done

# --- the at job-runner check reports each state correctly ------------------------
# Only meaningful where `at` is installed; where it is not, --doctor takes the
# "at is not installed" warning branch and never probes the daemon at all.
if command -v at >/dev/null 2>&1; then
  # down: a real problem — flagged red, with the enable command, and it makes
  # --doctor exit non-zero (a queued job that never fires is the whole point).
  out=$(INTERDIMUX_AT_DAEMON=down doctor)
  if grep -q "✗ at's job-runner is not active" <<< "$out" \
     && grep -q 'enable it:' <<< "$out"; then
    report "a stopped at job-runner is flagged with how to fix it" pass
  else
    report "a stopped at job-runner is flagged with how to fix it" fail
    ERRORS+="$(printf '%s' "$out" | grep -i 'job-runner\|enable' | sed 's/^/    /' || true)"$'\n'
  fi
  if [ "$(INTERDIMUX_AT_DAEMON=down doctor_rc)" = 1 ]; then
    report "a stopped at job-runner makes --doctor exit non-zero" pass
  else
    report "a stopped at job-runner makes --doctor exit non-zero" fail
  fi
  # unknown (BSD / no pgrep): we cannot tell, so it is a NOTE, never a failure —
  # the false "not active" alarm is exactly what this must not do.
  out=$(INTERDIMUX_AT_DAEMON=unknown doctor)
  if grep -q 'could not verify' <<< "$out" \
     && ! grep -q "✗ at's job-runner" <<< "$out"; then
    report "an unverifiable at job-runner is a note, not an alarm" pass
  else
    report "an unverifiable at job-runner is a note, not an alarm" fail
  fi
  if [ "$(INTERDIMUX_AT_DAEMON=unknown doctor_rc)" = 0 ]; then
    report "an unverifiable at job-runner does not fail --doctor" pass
  else
    report "an unverifiable at job-runner does not fail --doctor" fail
  fi
else
  echo "  (skipped at job-runner checks: 'at' is not installed)"
fi

# --- the report reads like a report -------------------------------------------
#
# The counts and the verdict are the first two lines because in a popup they are
# the ones you actually read; a total at the bottom of a scrolling report is a
# total you have to go looking for.  So their POSITION is the assertion, not
# merely their presence.
out=$(doctor)
head1=$(printf '%s\n' "$out" | sed -n 1p)
head3=$(printf '%s\n' "$out" | sed -n 3p)
case "$head1" in
  "interdimux doctor"*" ok"*) report "the first line is the title and the counts" pass ;;
  *) report "the first line is the title and the counts (got: $head1)" fail ;;
esac
case "$head3" in
  *"everything checks out"*|*"needs attention"*|*"could be better"*)
    report "the verdict is on line 3, above the detail" pass ;;
  *) report "the verdict is on line 3, above the detail (got: $head3)" fail ;;
esac
# A healthy install must say so in words, not only by exiting 0.
case "$out" in
  *"everything checks out"*) report "a healthy install says everything checks out" pass ;;
  *) report "a healthy install says everything checks out" fail
     ERRORS+="      $(printf '%s\n' "$out" | sed -n 3p || true)"$'\n' ;;
esac
# ...and a broken one counts the problems rather than just listing them.
setopt order sideways
bad_out=$(doctor)
unsetopt order
case "$bad_out" in
  *"1 problem needs attention"*) report "one problem is counted as one problem" pass ;;
  *) report "one problem is counted as one problem" fail
     ERRORS+="      $(printf '%s\n' "$bad_out" | sed -n 3p || true)"$'\n' ;;
esac
case "$bad_out" in
  *"1 problem"*) report "the count rides in the title too" pass ;;
  *) report "the count rides in the title too" fail ;;
esac
# Every section still gets a heading, and the headings are ruled.
missing=""
for sec in environment "key bindings" options; do
  grep -q "^$sec ─" <<< "$out" || missing+=" $sec"
done
[ -z "$missing" ] && report "every section is headed and ruled" pass \
                  || report "every section is headed and ruled (missing:$missing)" fail
# The layout width, asserted against the CAP and the FLOOR rather than against
# the longest line — which is whatever absolute path happens to be in the report,
# so it measured the checkout's depth and never reached either bound.  The rule
# under the title is exactly _doc_w cells, and term_cols prefers FZF_COLUMNS, so
# the width is drivable from here.
rule_cells() { printf '%s\n' "$1" | awk 'NR==2 { print length($0) }'; }
# The invariant is that the report NEVER exceeds what its display will show —
# fzf keeps two cells of gutter and the last column for its scrollbar, so the
# budget is `width - 6`.  A floor is the wrong shape here: any floor wider than
# the display puts the ellipsis back on exactly the narrow popup it was meant to
# help, which is how the 32 that used to be here was found.
ok=1
for cols in 200 120 100 96 80 60 44 40 34 24 12; do
  rep=$(FZF_COLUMNS="$cols" doctor)
  want=$(( cols - 6 )); [ "$want" -gt 96 ] && want=96; [ "$want" -lt 1 ] && want=1
  got=$(rule_cells "$rep")
  if [ "${got:-0}" != "$want" ]; then
    ok=0
    ERRORS+="     at $cols columns the rule is ${got:-0} cells, wanted $want"$'\n'
  fi
  # The TITLE row too, which is the one the counts are right-aligned against —
  # at 34 columns it was the rule that fitted and the title that got the ellipsis.
  # Lines 1-2 only: the verdict on line 3 is prose ("2 problems need attention"),
  # and below about 31 columns nothing sensible fits, so letting fzf ellipsize it
  # is the honest outcome.  What must never overrun is the chrome this code lays
  # out itself.
  widest=$(printf '%s\n' "$rep" | awk 'NR<=2 { if (length($0) > m) m = length($0) } END { print m+0 }')
  # The one thing allowed to overrun is the title itself, on a popup too narrow
  # for even that: "interdimux doctor" is 17 cells and cannot be shortened
  # without losing what it says, and below ~23 columns the picker is unusable
  # anyway.  Everything the layout computes must fit.
  floor=17; [ "$want" -gt "$floor" ] && floor="$want"
  if [ "$widest" -gt "$floor" ]; then
    ok=0
    ERRORS+="     at $cols columns the header block is $widest cells, over the $floor budget"$'\n'
  fi
done
[ "$ok" = 1 ] && report "neither the title nor the rule outruns the display, at any width" pass \
              || report "neither the title nor the rule outruns the display, at any width" fail
# ...and the cap is real, not just "never wider": a 300-column terminal must not
# get a 294-cell rule.
got=$(rule_cells "$(FZF_COLUMNS=300 doctor)")
[ "${got:-0}" = 96 ] && report "a very wide terminal is capped at 96 cells" pass \
                     || report "a very wide terminal is capped at 96 cells (got ${got:-0})" fail

# --- the checks added for the Health entry ------------------------------------

# `sort -s` is the one non-POSIX flag the tool depends on, and without it the
# session list would be EMPTY rather than merely misordered — so --doctor checks
# it instead of assuming.  Simulated with a sort that rejects the flag.
mkdir -p "$TMPD/nosort"
printf '#!/bin/sh\ncase " $* " in *" -s "*) echo "sort: bad flag" >&2; exit 2 ;; esac\nexec /usr/bin/sort "$@"\n' \
  > "$TMPD/nosort/sort"
chmod +x "$TMPD/nosort/sort"
case "$(PATH="$TMPD/nosort:$PATH" doctor)" in
  *"rejects -s"*) report "a sort without -s is reported as a problem" pass ;;
  *) report "a sort without -s is reported as a problem" fail
     ERRORS+="      $(PATH="$TMPD/nosort:$PATH" doctor | grep -i 'sort' | head -2 || true)"$'\n' ;;
esac
case "$(doctor)" in
  *"sort -s is supported"*) report "...and this one is confirmed to have it" pass ;;
  *) report "...and this one is confirmed to have it" fail ;;
esac

# A non-UTF-8 locale is a warning, not a failure: the tool works, its tree
# glyphs do not.  Set where the popups get it — the server's environment; the
# shell --doctor happens to run in is not what the picker sees.
senv LC_ALL C; senv LANG C
case "$(doctor)" in
  *"is not UTF-8"*) report "a non-UTF-8 locale is reported" pass ;;
  *) report "a non-UTF-8 locale is reported" fail ;;
esac
[ "$(doctor_rc)" = 0 ] \
  && report "...as a warning, not a failure" pass \
  || report "...as a warning, not a failure" fail
senv LC_ALL C.UTF-8; senv LANG C.UTF-8

# $FZF_DEFAULT_OPTS is invisible to the option validator.  Its geometry flags
# used to be reported here, because they move fzf's window WITHOUT moving
# FZF_COLUMNS -- but build_fzf_theme now resets them after it (tests/test_theme.sh
# draws the picker full-pane with them set), so they cannot reach a picker, and
# the old advice to move them to @interdimux-fzf-opts was the one way to bring
# the broken layout back.  Accepted by fzf, they are fine: a tick, no warning.
# In the server's environment too, for the same reason as the locale.
for fdo in '--border --margin=2' '--height 40% --padding 1' '--color=fg:blue --cycle'; do
  if ! FZF_DEFAULT_OPTS="$fdo" fzf --version >/dev/null 2>&1; then
    report "premise: fzf accepts [$fdo]" fail; continue
  fi
  senv FZF_DEFAULT_OPTS "$fdo"
  out=$(doctor)
  case "$out" in
    *'✓ $FZF_DEFAULT_OPTS is set, and fzf accepts it'*) report "[$fdo] in \$FZF_DEFAULT_OPTS gets a tick" pass ;;
    *) report "[$fdo] in \$FZF_DEFAULT_OPTS gets a tick" fail
       ERRORS+="      $(printf '%s\n' "$out" | grep -i -A2 fzf_default | head -3 || true)"$'\n' ;;
  esac
  case "$out" in
    *"everything checks out"*) report "...and is not nagged about" pass ;;
    *) report "...and is not nagged about" fail
       ERRORS+="      $(printf '%s\n' "$out" | grep '⚠\|✗' | head -3 || true)"$'\n' ;;
  esac
done
[ "$(doctor_rc)" = 0 ] && report "...nor does it fail the run" pass \
                       || report "...nor does it fail the run" fail
unsenv FZF_DEFAULT_OPTS

# A hide pattern that matches nothing looks exactly like one that works.
setopt hide 'nosuch-session-xyz'
case "$(doctor)" in
  *"matches no session right now"*) report "a hide pattern that matches nothing is reported" pass ;;
  *) report "a hide pattern that matches nothing is reported" fail ;;
esac
# ...and the pattern it reports must be the pattern, not whatever the cwd
# happened to contain.  This is how the pathname-expansion bug in the hide loops
# was noticed: the report named two FILES.
mkdir -p "$TMPD/globtrap"
: > "$TMPD/globtrap/nosuch-session-aaa"
: > "$TMPD/globtrap/nosuch-session-bbb"
setopt hide 'nosuch-session-*'
globbed=$(cd "$TMPD/globtrap" && doctor)
if grep -q "pattern 'nosuch-session-\*'" <<< "$globbed"; then
  report "the reported pattern is the pattern, not a filename from the cwd" pass
else
  report "the reported pattern is the pattern, not a filename from the cwd" fail
  ERRORS+="      $(printf '%s\n' "$globbed" | grep -i 'hide pattern' | head -2 || true)"$'\n'
fi

# A pattern that matches a session which is NOT the current one.
tmux -L "$SOCK" new-session -d -s hideme -x 120 -y 40 2>/dev/null || true
setopt hide 'hideme'
case "$(doctor)" in
  *"pattern 'hideme' matches a session"*) report "...and one that matches is confirmed" pass ;;
  *) report "...and one that matches is confirmed" fail
     ERRORS+="      $(doctor | grep -i 'hide pattern' | head -2 || true)"$'\n' ;;
esac

# ...and the case the real filter treats specially: the CURRENT session is never
# hidden, so a pattern whose only match is the session you are in does nothing.
# Saying "matches a session" there is a true sentence about a filter that is not
# running — and the harness session being called `doc` is what made the earlier
# version of this assertion lock in the wrong answer.
setopt hide 'doc'
case "$(doctor)" in
  *"matches only the session you are in"*)
    report "a pattern matching only the current session is called out" pass ;;
  *) report "a pattern matching only the current session is called out" fail
     ERRORS+="      $(doctor | grep -i 'hide pattern' | head -2 || true)"$'\n' ;;
esac
unsetopt hide
[ "$(doctor_rc)" = 0 ] && report "neither hide case fails the run" pass \
                       || report "neither hide case fails the run" fail

# A binary older than its sources renders last build's layout, silently.
# The check only fires for a binary belonging to the checkout being run, so the
# fixture is a whole miniature checkout rather than a stray copy: a binary
# installed elsewhere has no relationship to these sources, and a fresh clone
# (which stamps every source with the checkout time) would otherwise report any
# previously-built binary stale for ever.
if [ -x "$SCRIPT_DIR/rust/target/release/imux" ]; then
  mkdir -p "$TMPD/fakerepo/scripts" "$TMPD/fakerepo/rust/src" "$TMPD/fakerepo/rust/target/release"
  cp "$SCRIPT" "$TMPD/fakerepo/scripts/interdimux.sh"
  cp "$SCRIPT_DIR/rust/target/release/imux" "$TMPD/fakerepo/rust/target/release/imux"
  : > "$TMPD/fakerepo/rust/Cargo.toml"
  : > "$TMPD/fakerepo/rust/src/main.rs"
  fake() { bash "$TMPD/fakerepo/scripts/interdimux.sh" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; return 0; }

  touch -d '1990-01-01' "$TMPD/fakerepo/rust/target/release/imux" 2>/dev/null \
    || touch -t 199001010000 "$TMPD/fakerepo/rust/target/release/imux"
  case "$(fake)" in
    *"older than its sources"*) report "a stale rust binary is reported" pass ;;
    *) report "a stale rust binary is reported" fail
       ERRORS+="      $(fake | grep -i 'rust helper' | head -2 || true)"$'\n' ;;
  esac
  # ...naming the sources, and only files — `find` returns its start directory
  # too, which used to eat one of the three slots.
  case "$(fake)" in
    *"newer: rust/src/main.rs"*) report "...and it names a source that is newer" pass ;;
    *) report "...and it names a source that is newer" fail ;;
  esac
  if fake | grep -qE 'newer: rust/src$'; then
    report "...without listing the directory itself" fail
  else
    report "...without listing the directory itself" pass
  fi

  touch "$TMPD/fakerepo/rust/target/release/imux"
  case "$(fake)" in
    *"older than its sources"*) report "a fresh one is not" fail ;;
    *) report "a fresh one is not" pass ;;
  esac

  # The helper judged is the one the POPUPS run, picked by the tmux server's
  # environment.  This shell's INTERDIMUX_BIN names a fresh build elsewhere;
  # the server's names none, so the popups run the checkout's own -- stale.
  touch -d '1990-01-01' "$TMPD/fakerepo/rust/target/release/imux" 2>/dev/null \
    || touch -t 199001010000 "$TMPD/fakerepo/rust/target/release/imux"
  cp "$SCRIPT_DIR/rust/target/release/imux" "$TMPD/fresh-elsewhere"
  case "$(INTERDIMUX_BIN="$TMPD/fresh-elsewhere" fake)" in
    *"older than its sources"*) report "the popups' stale helper is reported, whatever this shell would run" pass ;;
    *) report "the popups' stale helper is reported, whatever this shell would run" fail ;;
  esac

  # A binary from somewhere else is not this checkout's business.  Named where
  # the popups read it, the server's environment.
  cp "$SCRIPT_DIR/rust/target/release/imux" "$TMPD/elsewhere"
  touch -d '1990-01-01' "$TMPD/elsewhere" 2>/dev/null || touch -t 199001010000 "$TMPD/elsewhere"
  senv INTERDIMUX_BIN "$TMPD/elsewhere"
  case "$(fake)" in
    *"older than its sources"*) report "a binary installed elsewhere is not called stale" fail ;;
    *) report "a binary installed elsewhere is not called stale" pass ;;
  esac
  unsenv INTERDIMUX_BIN
else
  echo "  (skipped the stale-binary check: no release binary built)"
fi

# The dashboard has two forms and they look different; --doctor says which one
# this client is about to get.  THIS harness attaches no client, so only the
# give-up arm is reachable here — which is the arm worth pinning here, because a
# check that guessed instead of admitting it could not tell would be worse than
# no check.  The two real arms are asserted in tests/test_dashboard.sh, which has
# clients of known height.
case "$(doctor)" in
  *"no client attached here"*)
    report "with no client attached, --doctor says so rather than guessing" pass ;;
  *) report "with no client attached, --doctor says so rather than guessing" fail
     ERRORS+="      $(doctor | grep -i 'dashboard\|client' | head -2 || true)"$'\n' ;;
esac

# --- the pending-jobs note ------------------------------------------------------
# Driven with a stub `atq` rather than by scheduling anything: the note is about
# the COUNT and its singular/plural, and queueing real jobs in a test is how you
# end up with real jobs firing after the test is over.
if command -v at >/dev/null 2>&1; then
  mkdir -p "$TMPD/atq"
  printf '#!/bin/sh\ni=0\nwhile [ "$i" -lt "${STUB_JOBS:-0}" ]; do echo "$i\tSat Jan 1 00:00:00 2000 x user"; i=$((i+1)); done\n' \
    > "$TMPD/atq/atq"
  chmod +x "$TMPD/atq/atq"
  jobs_line() { PATH="$TMPD/atq:$PATH" STUB_JOBS="$1" doctor | grep -i 'scheduled' | head -1; }
  case "$(jobs_line 1)" in
    *"1 command is scheduled"*) report "one pending job is counted in the singular" pass ;;
    *) report "one pending job is counted in the singular (got: $(jobs_line 1))" fail ;;
  esac
  case "$(jobs_line 3)" in
    *"3 commands are scheduled"*) report "three are counted in the plural" pass ;;
    *) report "three are counted in the plural (got: $(jobs_line 3))" fail ;;
  esac
  case "$(jobs_line 0)" in
    *"command"*"scheduled"*) report "an empty queue says nothing about jobs" fail ;;
    *) report "an empty queue says nothing about jobs" pass ;;
  esac
else
  echo "  (skipped the pending-jobs note: 'at' is not installed)"
fi

# --- the popup viewer ---------------------------------------------------------
# The dashboard's Health entry runs --doctor-view, which pages the report through
# fzf.  Its contract is narrow: it must not alter the report, and it must not
# leak the non-zero status --doctor uses to mean "found a problem".
# The handler itself, by its dispatch line.  `grep -c doctor-view >= 2` passed
# with the entire block deleted, because the two `cmd=` lines in --launch already
# make two.  (What the viewer actually DOES is asserted in test_dashboard.sh,
# which drives prefix+g then h on a real client.)
if grep -q '^if \[ "\${1:-}" = "--doctor-view" \]; then$' "$SCRIPT"; then
  report "--doctor-view has a handler" pass
else
  report "--doctor-view has a handler" fail
fi
if grep -q "ctrl-r:reload(bash '\$SQ_SCRIPT' --doctor)" "$SCRIPT"; then
  report "...with a recheck binding" pass
else
  report "...with a recheck binding" fail
fi
if grep -q "doctor) cmd=\"bash '\$sp' --doctor-view\"" "$SCRIPT"; then
  report "--launch doctor opens the viewer in a popup" pass
else
  report "--launch doctor opens the viewer in a popup" fail
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
