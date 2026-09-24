#!/usr/bin/env bash
#
# --doctor against the setup the POPUPS actually get, and the checks that used to
# green-tick a broken one.
#
# The picker runs in a display-popup, and a popup starts from the tmux SERVER's
# environment — its PATH, its locale, its $FZF_DEFAULT_OPTS — not from the shell
# --doctor was typed into.  Every case below that is about the environment sets
# it on the server (set-environment -g) and leaves the doctor's own shell
# healthy, because that is the shape of the real failure: fzf on PATH only via a
# shell rc, a locale only a login profile exports.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
SOCK="interdimux-doctor-env-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-doctor-env.XXXXXX")"
PASS=0
FAIL=0
ERRORS=""

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$TMPD"; }
trap cleanup EXIT

# Diagnostics pipe through grep; `|| true` on each, so a missing line is a
# reported failure rather than `set -e` ending the suite without a Results line.
report() {
  local name="$1" result="$2"
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); ERRORS+="  FAIL: $name"$'\n'; printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}
# $1 = name, $2 = haystack, $3 = needle: pass when the needle is in it.
has()    { case "$2" in *"$3"*) report "$1" pass ;; *) report "$1" fail; ERRORS+="      wanted: $3"$'\n' ;; esac; }
hasnt()  { case "$2" in *"$3"*) report "$1" fail; ERRORS+="      did not want: $3"$'\n' ;; *) report "$1" pass ;; esac; }

echo "interdimux doctor-environment tests"
echo

# Pinned before the server starts, because the server copies the environment it
# is started in and that is what --doctor reads: a healthy baseline must not
# depend on the developer's own locale or fzf opts.
export LC_ALL=C.UTF-8 LANG=C.UTF-8
unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE

tmux -f /dev/null -L "$SOCK" new-session -d -s envdoc -x 120 -y 40
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
# The version probes and the at job-runner are pinned as in test_doctor.sh; the
# tmux floor cases override TMUX_VNUM locally.
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_AT_DAEMON=up

setopt()   { tmux -L "$SOCK" set -g "@interdimux-$1" "$2"; }
unsetopt() { tmux -L "$SOCK" set -gu "@interdimux-$1" 2>/dev/null || true; }
senv()     { tmux -L "$SOCK" set-environment -g "$1" "$2"; }
unsenv()   { tmux -L "$SOCK" set-environment -gu "$1" 2>/dev/null || true; }
doctor()   { bash "$SCRIPT" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; return 0; }
doctor_rc() { bash "$SCRIPT" --doctor >/dev/null 2>&1; echo $?; }

SRV_PATH=$(tmux -L "$SOCK" show-environment -g PATH); SRV_PATH="${SRV_PATH#PATH=}"

bash "$SCRIPT" --bind-keys
# The baseline every case below is measured against.  If THIS fails, the rest
# are not about what they say.
if [ "$(doctor_rc)" = 0 ]; then
  report "baseline: a healthy install exits 0" pass
else
  report "baseline: a healthy install exits 0" fail
  ERRORS+="$(doctor | grep '✗' | sed 's/^/    /' || true)"$'\n'
fi

# --- tmux: 3.6 is a floor ---------------------------------------------------------
# tmux <= 3.5a rewrites the US row delimiter as `\037`, and the picker is blank
# (README, docs/CI.md: 3.4 -> 0 rows, 3.5a -> 0 rows).  3.4 is Ubuntu 24.04's and
# 3.5a Debian 13's; both used to get a green tick.
for v in 304 305; do
  want="tmux ${v:0:1}.${v:2} is older than 3.6"
  out=$(INTERDIMUX_TMUX_VNUM="$v" doctor)
  has "tmux $v is a problem, not a tick" "$out" "✗ $want"
  [ "$(INTERDIMUX_TMUX_VNUM="$v" doctor_rc)" = 1 ] \
    && report "...and --doctor exits 1 for it" pass \
    || report "...and --doctor exits 1 for it" fail
done
# The line names the version it JUDGED, not whatever `tmux -V` says now: it used
# to print this box's 3.7b while branching on the forwarded 3.4.
live=$(tmux -V); live="${live#tmux }"
out=$(INTERDIMUX_TMUX_VNUM=304 doctor | grep -E '^  . tmux ' || true)
if [ -z "$out" ]; then
  report "the tmux line names the version it judged (no tmux line at all)" fail
else
  hasnt "the tmux line names the version it judged, not the live one ($live)" "$out" "tmux $live "
fi
out=$(INTERDIMUX_TMUX_VNUM=306 doctor)
has "tmux 3.6 itself passes" "$out" "✓ tmux 3.6"
[ "$(INTERDIMUX_TMUX_VNUM=306 doctor_rc)" = 0 ] \
  && report "...and exits 0" pass || report "...and exits 0" fail

# --- fzf and bash, on the SERVER's PATH ---------------------------------------------
# The premise: this shell has fzf, so a doctor reading its own PATH says ✓.
command -v fzf >/dev/null 2>&1 && report "premise: this shell finds fzf" pass \
                               || report "premise: this shell finds fzf" fail
# A server PATH with bash on it but no fzf: every popup exits at the preflight.
mkdir -p "$TMPD/nofzf"
ln -s "$(command -v bash)" "$TMPD/nofzf/bash"
senv PATH "$TMPD/nofzf"
out=$(doctor)
has "fzf missing from the server's PATH is a problem" "$out" "✗ fzf is not on the tmux server's PATH"
has "...naming the PATH the server has" "$out" "the server's PATH: $TMPD/nofzf"
[ "$(doctor_rc)" = 1 ] && report "...and --doctor exits 1" pass || report "...and --doctor exits 1" fail
# A server PATH whose bash is macOS's 3.2.  The stub answers the one thing a
# bash 3.2 would be asked, the way 3.2 would answer it.
mkdir -p "$TMPD/oldbash"
printf '#!/bin/sh\nprintf "3 2 2"\n' > "$TMPD/oldbash/bash"; chmod +x "$TMPD/oldbash/bash"
ln -s "$(command -v fzf)" "$TMPD/oldbash/fzf"
senv PATH "$TMPD/oldbash"
out=$(doctor)
has "a bash older than 4.3 on the server's PATH is a problem" "$out" "✗ bash 3.2 on the tmux server's PATH is older than 4.3"
senv PATH "$SRV_PATH"
# ...and the healthy one names the version, as bash itself reports it.
bv=$(bash --version | sed -n '1s/.*version \([0-9]*\.[0-9]*\).*/\1/p')
has "a modern bash on the server's PATH is named with its version" "$(doctor)" "✓ bash $bv on the tmux server's PATH"

# fzf missing from --doctor's OWN PATH: the preflight used to stop the report
# with one line ("fzf is not installed"), so the check written for exactly this
# case never ran.  The PATH here is everything this one has, minus fzf.
mkdir -p "$TMPD/farm"
IFS=: read -r -a _pdirs <<< "$PATH"
for d in "${_pdirs[@]}"; do
  [ -d "$d" ] || continue
  ln -s "$d"/* "$TMPD/farm/" 2>/dev/null || true
done
rm -f "$TMPD/farm/fzf"
if PATH="$TMPD/farm" command -v fzf >/dev/null 2>&1; then
  report "premise: the stripped PATH has no fzf" fail
else
  out=$(PATH="$TMPD/farm" bash "$SCRIPT" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)
  has "with no fzf at all, --doctor still reports" "$out" "interdimux doctor"
  has "...and says fzf is missing" "$out" "✗ fzf is not on PATH"
fi

# --- the locale, measured in the popups' environment --------------------------------
# A UTF-8 name that is not installed: bash falls back to C and counts bytes.  The
# premise is that it really is not installed here, by `locale -a`.
# Run the way the Health popup runs it — the doctor in that same environment —
# because that is where the name used to be taken at its word.
if command -v locale >/dev/null 2>&1 && ! locale -a 2>/dev/null | grep -qi '^xx_XX'; then
  senv LC_ALL xx_XX.UTF-8
  out=$(LC_ALL=xx_XX.UTF-8 doctor)
  has "a UTF-8 locale that is not installed is a problem" "$out" "✗ locale 'xx_XX.UTF-8' is not installed"
  hasnt "...not a tick for its name" "$out" "✓ character encoding is UTF-8 (xx_XX.UTF-8)"
  [ "$(LC_ALL=xx_XX.UTF-8 doctor_rc)" = 1 ] && report "...and --doctor exits 1" pass || report "...and --doctor exits 1" fail
  senv LC_ALL C.UTF-8
else
  echo "  (skipped the uninstalled-locale case: cannot confirm xx_XX is absent)"
fi
# The server's locale is the one that counts, whatever this shell has: a C shell
# looking at a UTF-8 server is fine, and says whose locale it judged.
out=$(LC_ALL=C LANG=C doctor)
has "the server's UTF-8 locale passes even from a C shell" "$out" "✓ character encoding is UTF-8 (C.UTF-8)"
has "...and says this shell's differs" "$out" "this shell's is 'C'"

# --- $FZF_DEFAULT_OPTS, as the server has it -----------------------------------------
# The shell's own copy is not the one judged: the pickers never see it.
out=$(FZF_DEFAULT_OPTS='--tmux --border' doctor)
hasnt "this shell's \$FZF_DEFAULT_OPTS is not the one judged" "$out" 'FZF_DEFAULT_OPTS sets'

# --tmux (--popup since 0.74) opens fzf's own popup underneath the picker's.
# Server and doctor both set, as in the Health popup.
senv FZF_DEFAULT_OPTS '--tmux 80%'
out=$(FZF_DEFAULT_OPTS='--tmux 80%' doctor)
has "--tmux in the server's \$FZF_DEFAULT_OPTS is warned about" "$out" '⚠ $FZF_DEFAULT_OPTS sets --tmux'
hasnt "...instead of being called harmless" "$out" "none of it changes fzf's geometry"
senv FZF_DEFAULT_OPTS '--popup=center'
has "...and so is its 0.74 spelling, --popup" "$(doctor)" '⚠ $FZF_DEFAULT_OPTS sets --popup'
# fzf honours the LAST of --tmux / --no-tmux.
senv FZF_DEFAULT_OPTS '--tmux 80% --no-tmux'
hasnt "a --tmux cancelled by a later --no-tmux is not" "$(doctor)" 'sets --tmux'
# A value that spans lines — the dump shows only its first line.
senv FZF_DEFAULT_OPTS $'--cycle\n--tmux'
has "a --tmux on the second line of a multi-line value is found" "$(doctor)" '⚠ $FZF_DEFAULT_OPTS sets --tmux'
unsenv FZF_DEFAULT_OPTS

# An option fzf does not know kills every picker.  fzf's own verdict is the premise.
senv FZF_DEFAULT_OPTS '--no-such-fzf-flag'
if FZF_DEFAULT_OPTS='--no-such-fzf-flag' fzf --version >/dev/null 2>&1; then
  report "premise: fzf rejects --no-such-fzf-flag" fail
else
  has "default options fzf rejects are a problem" "$(doctor)" "✗ fzf rejects its default options"
fi
unsenv FZF_DEFAULT_OPTS

# --- @interdimux-fzf-opts --------------------------------------------------------------
# fzf's own parse is the oracle for what is valid.
setopt fzf-opts '--bogus-flag'
has "an option fzf rejects is a problem" "$(doctor)" "✗ @interdimux-fzf-opts = '--bogus-flag' — fzf rejects it"
setopt fzf-opts "--color=fg:'red"
has "an unbalanced quote is a problem (the whole value is dropped)" "$(doctor)" \
  "✗ @interdimux-fzf-opts = '--color=fg:'red' — does not parse"
setopt fzf-opts '--tmux 80%'
has "--tmux here is a problem: these words come last, nothing cancels them" "$(doctor)" \
  "✗ @interdimux-fzf-opts = '--tmux 80%'"
# Values fzf accepts, including two that show-options prints escaped (\" and
# \$).  The premise is fzf's verdict on the same shell words the pickers pass.
for good in '--color=bg+:237' '--bind "ctrl-x:execute(echo hi)"' "--prompt='\$ '" '--tmux --no-tmux'; do
  if eval "fzf --version $good" >/dev/null 2>&1; then
    setopt fzf-opts "$good"
    hasnt "fzf-opts [$good], which fzf accepts, is not flagged" "$(doctor)" "✗ @interdimux-fzf-opts"
  else
    report "premise: fzf accepts [$good]" fail
  fi
done
unsetopt fzf-opts

# --- key names: anything tmux can bind ------------------------------------------------
for k in C-f M-g F5 Space; do
  setopt key "$k"
  bash "$SCRIPT" --bind-keys
  out=$(doctor)
  # tmux's own verdict first: the key-bindings section looks the binding up.
  has "prefix+$k is bound by --bind-keys (tmux accepts it)" "$out" "✓ prefix+$k opens the navigator"
  hasnt "...and @interdimux-key '$k' is not called wrong" "$out" "✗ @interdimux-key"
  tmux -L "$SOCK" unbind-key -T prefix "$k" 2>/dev/null || true
done
unsetopt key
setopt dashboard-key M-g
bash "$SCRIPT" --bind-keys
hasnt "@interdimux-dashboard-key 'M-g' is not called wrong" "$(doctor)" "✗ @interdimux-dashboard-key"
[ "$(doctor_rc)" = 0 ] && report "...and a multi-character key config exits 0" pass \
                       || report "...and a multi-character key config exits 0" fail
tmux -L "$SOCK" unbind-key -T prefix M-g 2>/dev/null || true
unsetopt dashboard-key
bash "$SCRIPT" --bind-keys
# A key tmux refuses is still refused.
setopt key 'ff'
has "a key tmux does not know is still a problem" "$(doctor)" "✗ @interdimux-key = 'ff'"
unsetopt key

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
