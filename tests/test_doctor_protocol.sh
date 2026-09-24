#!/usr/bin/env bash
#
# --doctor must not vouch for a Rust core the list refuses.
#
# The list asks the binary to speak IMUX_PROTO (the subcommand) and falls back
# to the bash renderer when it exits 2: it was built from other sources than
# this script.  After a `git pull` or a TPM update -- neither rebuilds rust/ --
# that is the NORMAL state, and the doctor only asked `--version`, which any
# build answers "imux <version>".  So it printed a green "✓ imux 0.1.0 at …"
# for the very binary every popup refused, and before the first list had been
# drawn nothing in the report mentioned it at all.
#
# The binaries here are stand-ins with the real one's contract (rust/src/main.rs):
# `--version` answers "imux <version>", and a subcommand it does not speak
# exits 2 -- one from before the protocol was versioned, and one from a newer
# checkout.  The premise below checks that the LIST refuses them, so the doctor
# is judged against what the popups actually do.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/interdimux.sh"
REAL="$SCRIPT_DIR/rust/target/release/imux"
# --doctor reports on the install; run_all.sh's IMUX_RENDERER=bash would make
# it warn "rust helper disabled" and skip the helper check altogether.
unset INTERDIMUX_USE_RUST INTERDIMUX_BIN
SOCK="interdimux-docproto-test-$$"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-docproto.XXXXXX")"
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
has()   { case "$2" in *"$3"*) report "$1" pass ;; *) report "$1" fail; ERRORS+="      wanted: $3"$'\n' ;; esac; }
hasnt() { case "$2" in *"$3"*) report "$1" fail; ERRORS+="      unwanted: $3"$'\n' ;; *) report "$1" pass ;; esac; }

echo "interdimux doctor protocol tests"
echo

# Pinned before the server starts, as tests/test_doctor.sh explains: --doctor
# reads the locale and fzf's options from the server's environment.
export LC_ALL=C.UTF-8 LANG=C.UTF-8
unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE
tmux -f /dev/null -L "$SOCK" new-session -d -s doc -x 120 -y 40 -c "$TMPD"
export TMUX="$(tmux -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
export XDG_DATA_HOME="$TMPD/data" XDG_STATE_HOME="$TMPD/state"
export INTERDIMUX_FZF_MINOR=74 INTERDIMUX_TMUX_VNUM=307 INTERDIMUX_AT_DAEMON=up
senv()   { tmux -L "$SOCK" set-environment -g "$1" "$2"; }
unsenv() { tmux -L "$SOCK" set-environment -gu "$1" 2>/dev/null || true; }
doctor() { bash "$SCRIPT" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; return 0; }
doctor_rc() { bash "$SCRIPT" --doctor >/dev/null 2>&1; echo $?; }
bash "$SCRIPT" --bind-keys   # so the report's only problem is the one under test

# stub NAME PROTO -- a build that speaks PROTO and nothing else
stub() {
  cat > "$TMPD/$1" <<EOF
#!/bin/sh
case "\$1" in
  --version) echo "imux 0.1.0" ;;
  $2) cat >/dev/null; exit 3 ;;
  *) echo "imux: usage: imux $2" >&2; exit 2 ;;
esac
EOF
  chmod +x "$TMPD/$1"
}
stub old gather     # before the protocol was versioned
stub newer gather9  # a checkout ahead of this script

for b in old newer; do
  senv INTERDIMUX_BIN "$TMPD/$b"
  out=$(doctor)
  has "the $b build the list refuses is a problem, before any list is drawn" "$out" \
    "✗ $TMPD/$b is from another version of interdimux (it does not speak gather2)"
  hasnt "...not a green tick" "$out" "✓ imux 0.1.0"
  has "...and it says how to get one that does" "$out" "rebuild it, or point INTERDIMUX_BIN at a build of this version"
  [ "$(doctor_rc)" = 1 ] && report "...and --doctor exits 1 for it" pass \
                         || report "...and --doctor exits 1 for it" fail
done

# The premise, checked the other way round: the list does refuse the old one.
senv INTERDIMUX_BIN "$TMPD/old"
rm -f "$XDG_STATE_HOME/interdimux/errors.log"
INTERDIMUX_BIN="$TMPD/old" INTERDIMUX_USE_RUST=on bash "$SCRIPT" --list >/dev/null 2>&1 || true
if grep -q 'does not speak gather2' "$XDG_STATE_HOME/interdimux/errors.log" 2>/dev/null; then
  report "premise: the list refuses that binary" pass
else
  report "premise: the list refuses that binary" fail
fi
has "...and after it has, the doctor still says why, on the binary's own line" "$(doctor)" \
  "✗ $TMPD/old is from another version of interdimux"
rm -f "$XDG_STATE_HOME/interdimux/errors.log" "$XDG_STATE_HOME/interdimux/imux-refused"
unsenv INTERDIMUX_BIN

# The control: a build of these sources speaks the protocol, and is a tick.
if [ -x "$REAL" ]; then
  senv INTERDIMUX_BIN "$REAL"
  out=$(doctor)
  has "control: a build of this checkout is a tick" "$out" "✓ imux "
  hasnt "...and not called another version" "$out" "is from another version"
  unsenv INTERDIMUX_BIN
else
  echo "  (skipped the real-helper control: no release binary built)"
fi

# The checkout's own binary, refused: the rebuild hint is the one with the
# command in it -- and the "older than its sources" warning, which says it is
# RENDERING last build's layout, is not added on top: the list does not run it.
mkdir -p "$TMPD/fakerepo/scripts" "$TMPD/fakerepo/rust/src" "$TMPD/fakerepo/rust/target/release"
cp "$SCRIPT" "$TMPD/fakerepo/scripts/interdimux.sh"
cp "$TMPD/old" "$TMPD/fakerepo/rust/target/release/imux"
touch -d '1990-01-01' "$TMPD/fakerepo/rust/target/release/imux" 2>/dev/null \
  || touch -t 199001010000 "$TMPD/fakerepo/rust/target/release/imux"
: > "$TMPD/fakerepo/rust/Cargo.toml"
: > "$TMPD/fakerepo/rust/src/main.rs"
out=$(bash "$TMPD/fakerepo/scripts/interdimux.sh" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)
has "the checkout's own refused build is a problem too" "$out" \
  "✗ $TMPD/fakerepo/rust/target/release/imux is from another version of interdimux"
# _build_hint's line: the cargo command for this checkout, or how to get cargo
has "...with the rebuild hint for this checkout" "$out" "rebuild it"
hasnt "...not the advice for a binary installed elsewhere" "$out" "at a build of this version"
hasnt "...and not also called a stale build that renders the list" "$out" "older than its sources"

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
