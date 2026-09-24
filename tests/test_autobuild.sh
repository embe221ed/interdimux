#!/usr/bin/env bash
#
# The Rust core builds itself.  Neither TPM nor a git clone ever ran cargo, so
# every install ran the bash fallback renderer unless the user read --doctor.
# interdimux.tmux now builds rust/target/release/imux when cargo is here and the
# binary is missing or older than its sources:
#
#   * in the BACKGROUND (a run-shell -b job): loading the plugin returns, and
#     the key bindings are in place, while the compiler is still running
#   * niced, with CARGO_TARGET_DIR pinned and --locked, logging to
#     $XDG_STATE_HOME/interdimux/build.log, and a status-line message when it is
#     done or has failed
#   * once: a reload while it builds starts no second build
#   * a failed build is not run again on every load: only once the sources or
#     the cargo change, or silently a day later; and said once, naming the log,
#     @interdimux-autobuild, and what the picker uses meanwhile
#   * never with @interdimux-autobuild off, without a cargo, or when the in-repo
#     build would not be used (INTERDIMUX_BIN, INTERDIMUX_USE_RUST=off)
#
# and --doctor's missing-binary advice depends on whether there is a cargo at all.
#
# Nothing is compiled: a stand-in cargo records each run (argv0, cwd, argv,
# CARGO_TARGET_DIR, niceness) and writes a stand-in imux.  It works on a COPY of
# the plugin, so no build lands in this checkout.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK="interdimux-autobuild-test-$$"
OUTER="${SOCK}-outer"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/interdimux-autobuild.XXXXXX")"
REAL_TMUX="$(command -v tmux)"
PASS=0
FAIL=0
ERRORS=""

cleanup() {
  rm -f "$TMPD/ctl/hold"   # let a held stand-in cargo go
  "$REAL_TMUX" -L "$OUTER" kill-server 2>/dev/null || true
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
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
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

echo "interdimux automatic Rust build tests"
echo

export LC_ALL=C.UTF-8 LANG=C.UTF-8
unset INTERDIMUX_BIN INTERDIMUX_USE_RUST

# --- a copy of the plugin -------------------------------------------------------
PLUG="$TMPD/plugin"
mkdir -p "$PLUG/scripts" "$PLUG/rust"
cp "$REPO/interdimux.tmux" "$PLUG/"
cp "$REPO/scripts/interdimux.sh" "$PLUG/scripts/"
cp -R "$REPO/rust/src" "$REPO/rust/Cargo.toml" "$REPO/rust/Cargo.lock" "$PLUG/rust/"
BIN="$PLUG/rust/target/release/imux"
LOCK="$PLUG/rust/target/.interdimux-autobuild.lock"
NOTE="$PLUG/rust/target/.interdimux-autobuild.failed"   # what a failed build leaves
SOURCES=("$PLUG/rust/src" "$PLUG/rust/Cargo.toml" "$PLUG/rust/Cargo.lock")
STATE="$TMPD/state"
BLOG="$STATE/interdimux/build.log"
CTL="$TMPD/ctl"
mkdir -p "$CTL" "$STATE"

# --- the stand-in cargo ---------------------------------------------------------
# One line per run in cargo.log: argv0 | cwd | args | CARGO_TARGET_DIR | niceness.
# $CTL/hold makes it wait (bounded) until the file is removed, $CTL/fail makes it
# fail like a compile error, $CTL/noop makes it succeed without touching the
# binary (what cargo does when it decides nothing changed), $CTL/edit makes it
# change a source while it builds.  `cargo --version` is answered, not logged:
# $CTL/version, or a default.
make_cargo() { # $1 = the path to install it at
  mkdir -p "${1%/*}"
  cat > "$1" <<EOF
#!/bin/sh
if [ "\$1" = --version ]; then cat '$CTL/version' 2>/dev/null || echo 'cargo 1.99.0 (stub)'; exit 0; fi
printf '%s|%s|%s|%s|%s\n' "\$0" "\$PWD" "\$*" "\${CARGO_TARGET_DIR:-}" "\$(nice)" >> '$CTL/cargo.log'
echo "stub cargo: compiling imux"
if [ -e '$CTL/hold' ]; then
  : > '$CTL/holding'
  n=0
  while [ -e '$CTL/hold' ] && [ \$n -lt 1200 ]; do sleep 0.05; n=\$((n + 1)); done
fi
[ -e '$CTL/edit' ] && touch src/main.rs
if [ -e '$CTL/fail' ]; then echo "error[E0999]: the stub was told to fail" >&2; exit 101; fi
[ -e '$CTL/noop' ] && exit 0
t="\${CARGO_TARGET_DIR:-\$PWD/target}"
mkdir -p "\$t/release"
printf '#!/bin/sh\necho "imux 0.0.0-stub"\n' > "\$t/release/imux"
chmod +x "\$t/release/imux"
echo "    Finished release"
EOF
  chmod +x "$1"
}
STUB="$TMPD/stub"
make_cargo "$STUB/cargo"
make_cargo "$TMPD/cargo-home/bin/cargo"      # where rustup puts it
mkdir -p "$TMPD/no-cargo-home"

# A tmux on PATH that notes every background job interdimux.tmux asks for, and
# every interdimux message a job asks it to show (msgs.log -- tmux's own
# show-messages leaves out what a client with no terminal asked for), and is
# otherwise the real one.
SHIM="$TMPD/shim"
mkdir -p "$SHIM"
cat > "$SHIM/tmux" <<EOF
#!/bin/sh
case "\$*" in
  *run-shell*--autobuild*) printf '%s\n' "\$*" >> '$CTL/jobs.log' ;;
  *display-message*interdimux:*) printf '%s\n' "\$*" >> '$CTL/msgs.log' ;;
esac
exec '$REAL_TMUX' "\$@"
EOF
chmod +x "$SHIM/tmux"

# $PATH with no cargo on it.  A directory that has one is replaced by a farm of
# links to everything else in it, so nothing else goes missing with it (a
# distro cargo lives in /usr/bin).
NOPATH=""
_i=0
IFS=: read -r -a _dirs <<< "$PATH"
for _d in ${_dirs[@]+"${_dirs[@]}"}; do
  [ -n "$_d" ] || continue
  if [ -e "$_d/cargo" ]; then
    _i=$((_i + 1)); _farm="$TMPD/farm$_i"; mkdir -p "$_farm"
    for _f in "$_d"/*; do
      [ "${_f##*/}" = cargo ] || ln -s "$_f" "$_farm/${_f##*/}" 2>/dev/null || true
    done
    _d="$_farm"
  fi
  NOPATH="${NOPATH:+$NOPATH:}$_d"
done
CPATH="$SHIM:$STUB:$NOPATH"   # the stand-in is the only cargo
NPATH="$SHIM:$NOPATH"         # no cargo at all
PATH="$NOPATH" command -v cargo >/dev/null 2>&1 && { echo "could not build a PATH without cargo"; exit 1; }

# --- the server, with a client attached so status messages are drawn -------------
env PATH="$CPATH" XDG_STATE_HOME="$STATE" CARGO_HOME="$TMPD/no-cargo-home" \
  "$REAL_TMUX" -f /dev/null -L "$SOCK" new-session -d -s main -x 120 -y 30 'sleep 900'
export TMUX="$("$REAL_TMUX" -L "$SOCK" display-message -p '#{socket_path}'),99999,0"
export TMUX_PANE="$("$REAL_TMUX" -L "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
"$REAL_TMUX" -f /dev/null -L "$OUTER" new-session -d -s drv -x 250 -y 12 \
  "env -u TMUX -u TMUX_PANE '$REAL_TMUX' -L '$SOCK' attach -t main"
for _ in $(seq 1 100); do
  [ -n "$("$REAL_TMUX" -L "$SOCK" list-clients 2>/dev/null)" ] && break
  sleep 0.1
done

# The tmux server's environment: what the plugin, and its job, run with.
server_env() { # $1 = PATH, $2 = CARGO_HOME
  "$REAL_TMUX" -L "$SOCK" set-environment -g PATH "$1"
  "$REAL_TMUX" -L "$SOCK" set-environment -g CARGO_HOME "$2"
}
reset() {
  local _
  # a job a previous case started must not reach into this one
  for _ in $(seq 1 100); do [ -L "$LOCK" ] || break; sleep 0.1; done
  rm -rf "$PLUG/rust/target" "$STATE/interdimux"
  rm -f "$CTL"/*.log "$CTL/hold" "$CTL/holding" "$CTL/fail" "$CTL/noop" "$CTL/version" "$CTL/edit"
  "$REAL_TMUX" -L "$SOCK" set -gu @interdimux-autobuild
  server_env "$CPATH" "$TMPD/no-cargo-home"
}
# Load the plugin the way ~/.tmux.conf does (and TPM, under it): run-shell,
# which returns once interdimux.tmux has.  RC=124 means it was still running
# after 10 s -- i.e. it waited for the build.
load_plugin() {
  RC=0
  timeout 10 "$REAL_TMUX" -L "$SOCK" run-shell "$PLUG/interdimux.tmux" >/dev/null 2>&1 || RC=$?
}
# The build job itself, in the foreground, so that when it returns it has
# decided: nothing it might start is still on its way.  $1 = PATH, $2 =
# CARGO_HOME, then VAR=value pairs.
run_job() {
  local p="$1" ch="$2"; shift 2
  JRC=0
  env PATH="$p" CARGO_HOME="$ch" XDG_STATE_HOME="$STATE" "$@" \
    timeout 10 bash "$PLUG/interdimux.tmux" --autobuild >/dev/null 2>&1 || JRC=$?
}
runs() { [ -s "$CTL/cargo.log" ] && grep -c . "$CTL/cargo.log" || echo 0; }
# How many of the messages the jobs asked for say $1.
said() { local n; n=$(grep -cF -- "$1" "$CTL/msgs.log" 2>/dev/null) || :; echo "${n:-0}"; }
field() { awk -F'|' -v n="$1" 'NR == 1 { print $n }' "$CTL/cargo.log"; }
# The job has finished: its log has a verdict, and the lock is gone.
wait_done() {
  local _
  for _ in $(seq 1 300); do
    if [ ! -L "$LOCK" ] && [ -s "$BLOG" ]; then
      case "$(tail -n 1 "$BLOG")" in "== ok"*|"== failed"*) return 0 ;; esac
    fi
    sleep 0.1
  done
  return 1
}
# The attached client's status line shows $1 (within the message's 5 s).
status_says() {
  local _
  for _ in $(seq 1 50); do
    "$REAL_TMUX" -L "$OUTER" capture-pane -p -t '=drv:' 2>/dev/null | grep -qF -- "$1" && return 0
    sleep 0.1
  done
  return 1
}
bound() { "$REAL_TMUX" -L "$SOCK" list-keys -T prefix 2>/dev/null | awk '$4 == "f"' | grep -q interdimux; }
fresh() { [ -x "$BIN" ] && [ -z "$(find "$PLUG/rust/src" "$PLUG/rust/Cargo.toml" -type f -newer "$BIN")" ]; }
doctor() { # $1 = PATH, $2 = CARGO_HOME
  env PATH="$1" CARGO_HOME="$2" XDG_STATE_HOME="$STATE" \
    timeout 30 bash "$PLUG/scripts/interdimux.sh" --doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true
}

# --- 1. a fresh install: the plugin builds the binary, in the background -----------
echo "a missing binary is built when the plugin loads"
reset
load_plugin
check "loading the plugin succeeds (rc $RC)" '[ "$RC" = 0 ]'
check "...and asks tmux for a background job" '[ -s "$CTL/jobs.log" ]'
check "the job finishes, with a verdict in the log" wait_done
check "cargo ran once (ran $(runs))" '[ "$(runs)" = 1 ]'
check "...the stand-in on the server's PATH" '[ "$(field 1)" = "$STUB/cargo" ]'
check "...in the plugin's rust/ (got $(field 2))" '[ "$(field 2)" = "$PLUG/rust" ]'
check "...as 'build --release --locked' (got '$(field 3)')" '[ "$(field 3)" = "build --release --locked" ]'
check "...with its target dir pinned to rust/target (got '$(field 4)')" \
  '[ "$(field 4)" = "$PLUG/rust/target" ]'
srv_nice=$(ps -o ni= -p "$("$REAL_TMUX" -L "$SOCK" display-message -p '#{pid}')" | tr -d ' ')
if [ "${srv_nice:-19}" -lt 19 ]; then
  check "...niced below the tmux server (server $srv_nice, cargo $(field 5))" \
    '[ "$(field 5)" -gt "$srv_nice" ]'
fi
check "the binary is there, and newer than its sources" fresh
check "build.log holds cargo's output" 'grep -q "stub cargo: compiling imux" "$BLOG"'
check "...and ends in the verdict" '[ "$(tail -n 1 "$BLOG")" = "== ok" ]'
check "the status line says it is built" 'status_says "the Rust core is built"'
check "the key bindings are installed too" bound

# --- 2. up to date: nothing is started ------------------------------------------------
echo
echo "an up-to-date binary is left alone"
rm -f "$CTL"/*.log
load_plugin
check "loading the plugin starts no job" '[ "$RC" = 0 ] && [ ! -s "$CTL/jobs.log" ]'
run_job "$CPATH" "$TMPD/no-cargo-home"
check "the job, run anyway, runs no cargo (ran $(runs))" '[ "$JRC" = 0 ] && [ "$(runs)" = 0 ]'

# --- 3. stale: a source newer than the binary ----------------------------------------
echo
echo "a binary older than its sources is rebuilt"
touch -d '2 minutes ago' "$BIN"
check "control: the binary is now stale" '! fresh'
run_job "$CPATH" "$TMPD/no-cargo-home"
check "the job runs cargo (ran $(runs))" '[ "$JRC" = 0 ] && [ "$(runs)" = 1 ]'
check "...and the binary is fresh again" fresh
# cargo leaves the binary alone when it decides nothing changed; the timestamp
# must still end up current, or every load would build again.
rm -f "$CTL"/*.log
touch -d '2 minutes ago' "$BIN"
: > "$CTL/noop"
run_job "$CPATH" "$TMPD/no-cargo-home"
rm -f "$CTL/noop"
check "a build that changes nothing still leaves the binary current" \
  '[ "$(runs)" = 1 ] && fresh'
rm -f "$CTL"/*.log
run_job "$CPATH" "$TMPD/no-cargo-home"
check "...so the next load does not build again (ran $(runs))" '[ "$(runs)" = 0 ]'

# --- 4. when not to build -------------------------------------------------------------
echo
echo "no build when it is off, impossible, or pointless"
reset
"$REAL_TMUX" -L "$SOCK" set -g @interdimux-autobuild off
run_job "$CPATH" "$TMPD/no-cargo-home"
check "@interdimux-autobuild off: the job runs no cargo (ran $(runs))" \
  '[ "$JRC" = 0 ] && [ "$(runs)" = 0 ]'
load_plugin
check "...and loading the plugin starts no job" '[ "$RC" = 0 ] && [ ! -s "$CTL/jobs.log" ]'
check "...and the key bindings are still installed" bound

reset
server_env "$NPATH" "$TMPD/no-cargo-home"
run_job "$NPATH" "$TMPD/no-cargo-home"
check "no cargo anywhere: the job attempts no build (no build.log)" \
  '[ "$JRC" = 0 ] && [ ! -e "$BLOG" ]'
load_plugin
check "...loading the plugin starts no job" '[ "$RC" = 0 ] && [ ! -s "$CTL/jobs.log" ]'
check "...and the key bindings are still installed" bound

reset
run_job "$NPATH" "$TMPD/cargo-home"
check "cargo only in \$CARGO_HOME/bin (rustup's place, off PATH): that one is used" \
  '[ "$(runs)" = 1 ] && [ "$(field 1)" = "$TMPD/cargo-home/bin/cargo" ] && fresh'

reset
run_job "$CPATH" "$TMPD/no-cargo-home" INTERDIMUX_BIN="$STUB/cargo"
check "INTERDIMUX_BIN names an executable: no build (ran $(runs))" '[ "$JRC" = 0 ] && [ "$(runs)" = 0 ]'
run_job "$CPATH" "$TMPD/no-cargo-home" INTERDIMUX_BIN="$TMPD/not-there"
check "...but one that does not exist does not stop it (ran $(runs))" '[ "$(runs)" = 1 ]'

reset
run_job "$CPATH" "$TMPD/no-cargo-home" INTERDIMUX_USE_RUST=off
check "INTERDIMUX_USE_RUST=off: no build (ran $(runs))" '[ "$JRC" = 0 ] && [ "$(runs)" = 0 ]'

reset
mv "$PLUG/rust/Cargo.toml" "$TMPD/Cargo.toml.away"
run_job "$CPATH" "$TMPD/no-cargo-home"
mv "$TMPD/Cargo.toml.away" "$PLUG/rust/Cargo.toml"
check "no rust/Cargo.toml (an install without the sources): no build (ran $(runs))" \
  '[ "$JRC" = 0 ] && [ "$(runs)" = 0 ]'

# --- 5. a failed build ---------------------------------------------------------------
echo
echo "a failed build says so, once, and is not run again for nothing"
reset
: > "$CTL/fail"
load_plugin
check "the job finishes" wait_done
check "build.log holds the compiler's error" 'grep -q "E0999" "$BLOG"'
check "...and ends in the verdict" 'has "$(tail -n 1 "$BLOG")" "== failed"'
check "the status line says it failed" 'status_says "building the Rust core failed"'
check "...that the bash renderer is used meanwhile" 'status_says "failed (the bash renderer is used)"'
check "...where the log is" 'status_says "$BLOG"'
check "...and how to stop these builds" 'status_says "set @interdimux-autobuild off"'
check "no binary was left behind" '[ ! -e "$BIN" ]'
out=$(doctor "$CPATH" "$TMPD/no-cargo-home")
check "--doctor names the failed build and its log" \
  'has "$out" "the plugin'"'"'s last build of it failed: $BLOG"'

# The same sources with the same cargo would only fail again.  This cost a whole
# compile (a missing linker fails only after it) and the same message on every
# tmux start and every source-file.
rm -f "$CTL/jobs.log" "$CTL/msgs.log"
load_plugin
check "loading the plugin again starts no build job" '[ "$RC" = 0 ] && [ ! -s "$CTL/jobs.log" ]'
check "...and the key bindings are installed" bound
run_job "$CPATH" "$TMPD/no-cargo-home"
check "the job, run anyway, runs no cargo either (ran $(runs))" '[ "$JRC" = 0 ] && [ "$(runs)" = 1 ]'
check "...and nothing more is said" '[ "$(said interdimux:)" = 0 ]'
check "--doctor still names the failed build" \
  'has "$(doctor "$CPATH" "$TMPD/no-cargo-home")" "last build of it failed: $BLOG"'

# Changed sources are another build: tried at once, and news again.
rm -f "$CTL/msgs.log" "$BLOG"
touch "$PLUG/rust/src/main.rs"
load_plugin
wait_done || :
check "a changed source: the next load builds again (ran $(runs))" '[ "$(runs)" = 2 ]'
check "...and says it failed" '[ "$(said "building the Rust core failed")" = 1 ]'
# So is a source changed WHILE it compiled: the note is dated when it started.
touch "$PLUG/rust/src/main.rs"
: > "$CTL/edit"
run_job "$CPATH" "$TMPD/no-cargo-home"
rm -f "$CTL/edit"
check "a build that fails while a source is edited (ran $(runs))..." '[ "$(runs)" = 3 ]'
run_job "$CPATH" "$TMPD/no-cargo-home"
check "...is followed by one of the edited sources (ran $(runs))" '[ "$(runs)" = 4 ]'
run_job "$CPATH" "$TMPD/no-cargo-home"
check "...and then by none (ran $(runs))" '[ "$(runs)" = 4 ]'

# Another cargo -- a rustup update, a newer distro package -- may succeed.
rm -f "$CTL/msgs.log" "$BLOG"
echo 'cargo 1.99.1 (stub)' > "$CTL/version"
load_plugin
wait_done || :
check "another cargo version: the next load builds again (ran $(runs))" '[ "$(runs)" = 5 ]'
check "...and says it failed" '[ "$(said "building the Rust core failed")" = 1 ]'

# A day later with nothing changed it is tried once more -- the linker or the
# network may be back -- but failing again is not news.
rm -f "$CTL/jobs.log" "$CTL/msgs.log" "$BLOG"
find "${SOURCES[@]}" -type f -exec touch -d '3 days ago' {} +
touch -d '2 days ago' "$NOTE"
load_plugin
wait_done || :
check "a day later, the same build is tried again (ran $(runs))" '[ "$(runs)" = 6 ]'
check "...without a word" '[ "$(said interdimux:)" = 0 ]'
check "...though build.log has it" 'has "$(tail -n 1 "$BLOG")" "== failed"'
rm -f "$CTL/jobs.log"
load_plugin
check "...and the load after that waits another day" '[ "$RC" = 0 ] && [ ! -s "$CTL/jobs.log" ]'
find "${SOURCES[@]}" -type f -exec touch {} +

# A failed REbuild leaves the binary from before, which the list goes on using.
reset
run_job "$CPATH" "$TMPD/no-cargo-home"
check "control: a binary is built" fresh
touch -d '2 minutes ago' "$BIN"
: > "$CTL/fail"
rm -f "$CTL/msgs.log" "$BLOG"
load_plugin
check "a failed rebuild finishes" wait_done
check "...and leaves the previous binary" '[ -x "$BIN" ] && [ "$(runs)" = 2 ]'
check "...which the status line says is kept" 'status_says "failed (the previous build is kept)"'
check "...not that the bash renderer is used" '[ "$(said "bash renderer")" = 0 ]'
rm -f "$CTL/fail"

# --- 6. in the background, and only once ------------------------------------------------
echo
echo "the build never holds up tmux, and a reload does not start a second one"
reset
: > "$CTL/hold"
load_plugin
check "loading the plugin returns while cargo is still running (rc $RC)" '[ "$RC" = 0 ]'
for _ in $(seq 1 100); do [ -e "$CTL/holding" ] && break; sleep 0.1; done
check "...cargo is running" '[ -e "$CTL/holding" ] && [ "$(runs)" = 1 ]'
check "...and the key bindings are already installed" bound
check "--doctor says a build is under way" \
  'has "$(doctor "$CPATH" "$TMPD/no-cargo-home")" "the plugin is building it in the background right now"'
# A reload during the build: the job it starts returns at once and runs no cargo.
run_job "$CPATH" "$TMPD/no-cargo-home"
check "a second job during the build returns at once (rc $JRC)" '[ "$JRC" = 0 ]'
check "...without a second cargo (ran $(runs))" '[ "$(runs)" = 1 ]'
rm -f "$CTL/hold"
check "the build finishes once released" wait_done
check "...and succeeds" '[ "$(tail -n 1 "$BLOG")" = "== ok" ] && fresh'
check "...with cargo still run just once (ran $(runs))" '[ "$(runs)" = 1 ]'

# A lock left by a job that died (the server was killed mid-build) must not stop
# every later build.
reset
mkdir -p "${LOCK%/*}"
sh -c 'exit 0' & dead=$!; wait "$dead" || true
ln -s "$dead" "$LOCK"
run_job "$CPATH" "$TMPD/no-cargo-home"
check "a lock whose owner is gone is taken over (ran $(runs))" '[ "$(runs)" = 1 ] && fresh'
check "...and released afterwards" '[ ! -L "$LOCK" ]'

# --- 7. --doctor's advice, and the option -----------------------------------------------
echo
echo "--doctor: how to get the binary, with and without a cargo"
reset
out=$(doctor "$CPATH" "$TMPD/no-cargo-home")
check "control: the binary is reported missing" 'has "$out" "rust helper not found"'
check "with cargo: the build command" \
  'has "$out" "build it with: (cd '"'"'$PLUG/rust'"'"' && cargo build --release)"'
check "...and no 'install Rust'" '! has "$out" "rustup"'
out=$(doctor "$NOPATH" "$TMPD/cargo-home")
check "with cargo only in \$CARGO_HOME/bin: the command names that cargo" \
  'has "$out" "&& $TMPD/cargo-home/bin/cargo build --release)"'
# The state dir is shared by every checkout; another one's failed build is not
# this one's.
mkdir -p "${BLOG%/*}"
printf '== building %s with cargo, today\nerror\n== failed (exit 101)\n' "$TMPD/elsewhere/rust" > "$BLOG"
out=$(doctor "$CPATH" "$TMPD/no-cargo-home")
check "a failed build of another checkout is not reported as this one's" \
  '! has "$out" "last build of it failed"'
out=$(doctor "$NOPATH" "$TMPD/no-cargo-home")
check "without cargo: no build command" '! has "$out" "build --release"'
check "...but where to get Rust" 'has "$out" "install Rust (https://rustup.rs)"'
check "...or how to use a prebuilt binary" 'has "$out" "point INTERDIMUX_BIN at a prebuilt imux"'
mv "$PLUG/rust/Cargo.toml" "$TMPD/Cargo.toml.away"
out=$(doctor "$CPATH" "$TMPD/no-cargo-home")
mv "$TMPD/Cargo.toml.away" "$PLUG/rust/Cargo.toml"
check "no rust/ sources: no build command, even with cargo" '! has "$out" "build --release"'
check "...only the prebuilt binary" 'has "$out" "no rust/ sources to build: point INTERDIMUX_BIN at a prebuilt imux"'

"$REAL_TMUX" -L "$SOCK" set -g @interdimux-autobuild off
out=$(doctor "$CPATH" "$TMPD/no-cargo-home")
check "@interdimux-autobuild is a known option" \
  'has "$out" "✓ @interdimux-autobuild = '"'"'off'"'"'" && ! has "$out" "unknown option @interdimux-autobuild"'
"$REAL_TMUX" -L "$SOCK" set -g @interdimux-autobuild maybe
out=$(doctor "$CPATH" "$TMPD/no-cargo-home")
check "...and its value is checked" \
  'has "$out" "✗ @interdimux-autobuild = '"'"'maybe'"'"' — expected '"'"'on'"'"' or '"'"'off'"'"'"'
"$REAL_TMUX" -L "$SOCK" set -gu @interdimux-autobuild

echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then echo; printf '%s' "$ERRORS"; exit 1; fi
