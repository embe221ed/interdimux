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
# --doctor reports on the INSTALL, and a renderer forced from outside is not
# part of one: under tests/run_all.sh's IMUX_RENDERER=bash the inherited
# INTERDIMUX_USE_RUST=off would make every report warn "rust helper disabled"
# and hide the helper checks below.  A case that wants a renderer pins it.
unset INTERDIMUX_USE_RUST
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
# $1 = name, $2 = the exit status wanted, then the environment to run it in (as
# for env(1)).  On a mismatch the report's problem lines go into the failure.
rc_is() {
  local name="$1" want="$2" rep rc; shift 2
  rc=0; rep=$(env "$@" bash "$SCRIPT" --doctor 2>&1) || rc=$?   # set -e: exit 1 is an answer
  if [ "$rc" = "$want" ]; then report "$name" pass
  else
    report "$name" fail
    ERRORS+="      exit $rc, wanted $want:"$'\n'"$(printf '%s\n' "$rep" | sed 's/\x1b\[[0-9;]*m//g' | grep '[✗⚠]' | sed 's/^/      /' || true)"$'\n'
  fi
}

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

# The fzf the popups run is the one JUDGED, by its own --version -- not this
# shell's, and not INTERDIMUX_FZF_MINOR (pinned to 74 above, as a binding bakes
# it).  A distro's old fzf ahead of the one you installed is the usual shape:
# the report used to say "✓ fzf 0.74" and exit 0 while every popup failed.  The
# stubs answer the one thing the doctor asks an fzf, the way that version would.
mkdir -p "$TMPD/fzf030" "$TMPD/fzf060"
printf '#!/bin/sh\necho "0.30.0 (stub)"\n' > "$TMPD/fzf030/fzf"
printf '#!/bin/sh\necho "0.60.0 (stub)"\n' > "$TMPD/fzf060/fzf"
chmod +x "$TMPD/fzf030/fzf" "$TMPD/fzf060/fzf"
senv PATH "$TMPD/fzf030:$SRV_PATH"
out=$(doctor)
has "an fzf older than 0.40 first on the server's PATH is a problem" "$out" "✗ fzf 0.30.0 is older than 0.40"
hasnt "...not a tick for this shell's fzf" "$out" "✓ fzf "
has "...naming where it is" "$out" "that is $TMPD/fzf030/fzf, first on the tmux server's PATH"
rc_is "...and --doctor exits 1" 1
# The tiers follow the same fzf: 0.60 is below every tier the pinned 74 passes.
senv PATH "$TMPD/fzf060:$SRV_PATH"
has "the feature tier is the server fzf's, not the pinned minor" "$(doctor)" "⚠ fzf 0.60.0 — 0.63 moves the key hints"
senv PATH "$SRV_PATH"

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
  nofzf_doctor() { PATH="$TMPD/farm" bash "$SCRIPT" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true; }
  # ...while the server's PATH has one, which is all a popup needs: this shell's
  # PATH is not the popups'.  It used to be "✗ fzf is not on PATH", exit 1.
  out=$(nofzf_doctor)
  has "with no fzf in this shell, --doctor still reports" "$out" "interdimux doctor"
  has "...judging the server's fzf, which is fine" "$out" "✓ fzf "
  hasnt "...not calling fzf missing" "$out" "✗ fzf is not"
  has "...and saying this shell's has none" "$out" "this shell finds none"
  rc_is "...and --doctor exits 0" 0 PATH="$TMPD/farm"
  # The option check asks the same fzf: a flag it rejects is still caught.
  setopt fzf-opts '--bogus-flag'
  has "...and @interdimux-fzf-opts is still checked against it" "$(nofzf_doctor)" \
    "✗ @interdimux-fzf-opts = '--bogus-flag' — fzf rejects it"
  unsetopt fzf-opts
  # With none on the server's PATH either, that is the problem.
  senv PATH "$TMPD/farm"
  has "with no fzf anywhere, it says so, of the server's PATH" "$(nofzf_doctor)" \
    "✗ fzf is not on the tmux server's PATH"
  senv PATH "$SRV_PATH"
fi

# A literal `~` in the server's PATH: `export PATH="~/bin:$PATH"`, quoted by
# mistake, works silently, because bash -- which runs fzf for every picker --
# tilde-expands a PATH element (/bin/sh does not).  A literal lookup called fzf
# missing, exit 1, on a working setup.  The ~ is the server's $HOME, which is
# the one a popup's bash expands; a directory name no real home has.
tdir="imux-tilde-$$"
mkdir -p "$TMPD/home/$tdir"
ln -s "$(command -v fzf)" "$TMPD/home/$tdir/fzf"
senv HOME "$TMPD/home"
senv PATH "~/$tdir:$TMPD/nofzf"
# bash's own search is the authority: it finds fzf there, and a literal one does not.
if [ -n "$(env HOME="$TMPD/home" PATH="~/$tdir:$TMPD/nofzf" bash -c 'type -P fzf')" ] \
   && ! [ -x "~/$tdir/fzf" ]; then
  out=$(doctor)
  hasnt "a ~ in the server's PATH is searched as bash searches it" "$out" "✗ fzf is not on the tmux server's PATH"
  has "...so the fzf there is judged" "$out" "✓ fzf "
  rc_is "...and --doctor exits 0" 0
else
  report "premise: bash finds fzf through a literal ~ in PATH" fail
fi
senv HOME "$HOME"
senv PATH "$SRV_PATH"

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
# An option fzf does not know kills every picker: fzf parses its defaults before
# any flag.  That is the one thing in there that can.  fzf's own verdict is the
# premise.
if FZF_DEFAULT_OPTS='--no-such-fzf-flag' fzf --version >/dev/null 2>&1; then
  report "premise: fzf rejects --no-such-fzf-flag" fail
else
  # The shell's own copy is not the one judged: the pickers never see it.
  hasnt "this shell's \$FZF_DEFAULT_OPTS is not the one judged" \
    "$(FZF_DEFAULT_OPTS='--no-such-fzf-flag' doctor)" "fzf rejects its default options"
  senv FZF_DEFAULT_OPTS '--no-such-fzf-flag'
  out=$(doctor)
  has "default options fzf rejects are a problem" "$out" "✗ fzf rejects its default options"
  has "...said to be the server's copy, since this shell has none" "$out" "that is the tmux server's \$FZF_DEFAULT_OPTS"
  # A value that spans lines -- the dump shows only its first line, and a
  # long one is usually written that way.
  senv FZF_DEFAULT_OPTS $'--cycle\n--no-such-fzf-flag'
  has "a rejected flag on the second line of a multi-line value is found" "$(doctor)" \
    "✗ fzf rejects its default options"
  unsenv FZF_DEFAULT_OPTS
fi

# Its layout flags are not a problem.  build_fzf_theme resets --tmux/--popup,
# --height, --border, --margin, --padding and --style after it, on every fzf
# that parses them (tests/test_theme.sh draws the picker full-pane with each of
# these set).  --doctor used to warn about them -- "fzf's own popup opens
# underneath" -- and advise moving them to @interdimux-fzf-opts: the one place
# they DO take effect.  So: accepted by fzf -> a tick and a clean report.  An
# fzf too old to parse one rejects it, which is the problem to name instead.
# Server and doctor both set, as in the Health popup.
for opt in '--tmux 80%' '--popup=center' '--border --height 40%' \
           '--height 40% --border --margin 1 --padding 1 --style full' $'--cycle\n--tmux'; do
  lbl="${opt//$'\n'/\\n}"
  senv FZF_DEFAULT_OPTS "$opt"
  out=$(FZF_DEFAULT_OPTS="$opt" doctor)
  if FZF_DEFAULT_OPTS="$opt" fzf --version >/dev/null 2>&1; then
    has "[$lbl] in \$FZF_DEFAULT_OPTS, which fzf accepts, gets a tick" "$out" \
      '✓ $FZF_DEFAULT_OPTS is set, and fzf accepts it'
    has "...and no warning: everything checks out" "$out" "everything checks out"
    case "$out" in *"everything checks out"*) ;;
      *) ERRORS+="$(printf '%s\n' "$out" | grep -A2 '[✗⚠]' | sed 's/^/      /' || true)"$'\n' ;; esac
  else
    has "[$lbl], which this fzf rejects, is reported as that" "$out" "✗ fzf rejects its default options"
  fi
done
unsenv FZF_DEFAULT_OPTS
# $FZF_DEFAULT_OPTS_FILE is read the same way and reset the same way, so it is
# judged the same way: it used to be a warning whatever it held.
printf -- '--border --height 40%%\n' > "$TMPD/fzfopts"
senv FZF_DEFAULT_OPTS_FILE "$TMPD/fzfopts"
if FZF_DEFAULT_OPTS_FILE="$TMPD/fzfopts" fzf --version >/dev/null 2>&1; then
  out=$(doctor)
  has "layout flags in \$FZF_DEFAULT_OPTS_FILE, which fzf accepts, get a tick" "$out" \
    '✓ $FZF_DEFAULT_OPTS_FILE is set, and fzf accepts it'
  has "...and no warning" "$out" "everything checks out"
else
  report "premise: fzf accepts '--border --height 40%' from its options file" fail
fi
printf -- '--no-such-fzf-flag\n' > "$TMPD/fzfopts"
has "a flag fzf rejects in \$FZF_DEFAULT_OPTS_FILE is a problem" "$(doctor)" "✗ fzf rejects its default options"
unsenv FZF_DEFAULT_OPTS_FILE

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

# A valid key that is not BOUND yet -- set after the plugin loaded, the case this
# report exists for.  tmux 3.6, the floor, fails `list-keys -T prefix <key>` for
# it ("unknown key: C-f"), where 3.7 returns 0 and only an unparseable name gets
# "invalid key".  The check read the exit status, so on 3.6 it called C-f "not a
# key tmux knows" while listing C-f as an example.  Every case above runs
# --bind-keys first, so none of them could see it.  Run against 3.6's behaviour:
# the real tmux, except that list-keys fails the way 3.6's does
# (cmd-list-keys.c: `if (only != KEYC_UNKNOWN && !found)`).  On a real 3.6 the
# wrapper changes nothing.
REAL_TMUX=$(command -v tmux)
mkdir -p "$TMPD/tmux36"
cat > "$TMPD/tmux36/tmux" <<EOF
#!/bin/sh
if [ "\$1" = list-keys ] && [ "\$2" = -T ] && [ \$# = 4 ]; then
  '$REAL_TMUX' list-keys -T "\$3" "\$4" >/dev/null || exit \$?
  '$REAL_TMUX' list-keys -T "\$3" | awk -v k="\$4" '\$4 == k { f = 1 } END { exit !f }' && exit 0
  echo "unknown key: \$4" >&2; exit 1
fi
exec '$REAL_TMUX' "\$@"
EOF
chmod +x "$TMPD/tmux36/tmux"
T36="$TMPD/tmux36:$PATH"
e36=$(PATH="$T36" tmux list-keys -T prefix C-f 2>&1 >/dev/null) || true
if [ "$e36" = "unknown key: C-f" ]; then
  setopt key C-f
  setopt dashboard-key M-g
  out=$(PATH="$T36" doctor)
  hasnt "a valid key that is not bound yet is not called unknown (tmux 3.6)" "$out" "not a key tmux knows"
  has "...its missing binding is what is reported" "$out" "✗ prefix+C-f is not bound to the navigator"
  has "...and the option itself is a tick" "$out" "✓ @interdimux-key = 'C-f'"
  has "...as is the dashboard's" "$out" "✓ @interdimux-dashboard-key = 'M-g'"
  setopt key 'ff'
  has "...while a name tmux cannot parse is still refused there" "$(PATH="$T36" doctor)" \
    "✗ @interdimux-key = 'ff' — not a key tmux knows"
  unsetopt key
  unsetopt dashboard-key
else
  report "premise: the 3.6 stand-in fails list-keys for an unbound key (got: $e36)" fail
fi

# --- colours: exactly #rrggbb, 0-255, -1, default --------------------------------------
# color-border feeds only fzf's --color, so a bad value there cannot stop the
# script before the report.
setopt color-border '#zzzzzz'
has "a '#' and six non-hex characters is not a colour" "$(doctor)" "✗ @interdimux-color-border = '#zzzzzz'"
for good in '#E78A4E' '-1' 'default' '255'; do
  setopt color-border "$good"
  hasnt "color-border '$good' is accepted" "$(doctor)" "✗ @interdimux-color-border"
done
unsetopt color-border

# --- the helper binary ------------------------------------------------------------------
# @interdimux-binary was accepted and green-ticked while nothing read it.
setopt binary /bin/true
out=$(doctor)
has "@interdimux-binary is reported as unknown" "$out" "✗ unknown option @interdimux-binary"
has "...and points at the variable that does work" "$out" "INTERDIMUX_BIN"
unsetopt binary
# INTERDIMUX_BIN is read from the tmux SERVER's environment, like everything
# else a popup runs with: `tmux set-environment -g INTERDIMUX_BIN`, which is what
# the README and the notes here tell you to do.  The check used to vet THIS
# shell's pick -- the in-repo build -- while every popup ran the server's.
# Premise: a job the server starts really gets the server's value.
printf '#!/bin/sh\necho "hello from not-imux"\n' > "$TMPD/hello"; chmod +x "$TMPD/hello"
senv INTERDIMUX_BIN "$TMPD/hello"
got=$(tmux -L "$SOCK" run-shell 'printf "%s\n" "$INTERDIMUX_BIN"')
if [ "$got" = "$TMPD/hello" ]; then
  out=$(doctor)
  # Any executable passes the -x test; only imux answers `--version` with "imux".
  has "the server's INTERDIMUX_BIN, when it is not imux, is a problem" "$out" \
    "✗ $TMPD/hello is not the interdimux helper"
  hasnt "...not a tick for the helper this shell would pick" "$out" "✓ imux "
  has "...and it says this shell's pick differs" "$out" "this shell's environment picks"
else
  report "premise: a server job gets the server's INTERDIMUX_BIN (got '$got')" fail
fi
unsenv INTERDIMUX_BIN
# ...and this shell's own is not the one judged.
out=$(INTERDIMUX_BIN="$TMPD/hello" doctor)
hasnt "this shell's INTERDIMUX_BIN is not the one judged" "$out" "$TMPD/hello is not the interdimux helper"
has "...though it is named, as this shell's pick" "$out" "this shell's environment picks $TMPD/hello"
if [ -x "$SCRIPT_DIR/rust/target/release/imux" ]; then
  senv INTERDIMUX_BIN "$SCRIPT_DIR/rust/target/release/imux"
  has "...and the real one is still a tick" "$(doctor)" "✓ imux "
  unsenv INTERDIMUX_BIN
else
  echo "  (skipped the real-helper case: no release binary built)"
fi
senv INTERDIMUX_BIN "$TMPD/no-such-imux"
has "an INTERDIMUX_BIN that is not executable is said to be ignored" \
  "$(doctor)" "⚠ INTERDIMUX_BIN=$TMPD/no-such-imux is not an executable file"
unsenv INTERDIMUX_BIN
senv INTERDIMUX_USE_RUST off
has "INTERDIMUX_USE_RUST=off on the server is what disables the helper" "$(doctor)" \
  "⚠ rust helper disabled by INTERDIMUX_USE_RUST=off"
unsenv INTERDIMUX_USE_RUST

# --- the navigator's scratch dir -------------------------------------------------------
# $TMPDIR as the server has it; with no runtime dir, that is where the resume
# flag goes, and a missing one used to kill the navigator unexplained.
unsenv XDG_RUNTIME_DIR
senv TMPDIR "$TMPD/gone"
has "an unusable tmp dir is reported" "$(doctor)" "⚠ cannot create a file in $TMPD/gone"
senv TMPDIR "$TMPD"
has "...and a usable one is confirmed" "$(doctor)" "✓ writable: $TMPD (the navigator's scratch files)"
unsenv TMPDIR

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
