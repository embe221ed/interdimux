#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$CURRENT_DIR/scripts/interdimux.sh"
RUST_DIR="$CURRENT_DIR/rust"
IMUX="$RUST_DIR/target/release/imux"

# ---------------------------------------------------------------------------
# The Rust core, built in the background
# ---------------------------------------------------------------------------
#
# Neither TPM nor a git clone builds rust/, so without this every install ran
# the bash fallback renderer -- 1.7x slower at a dozen rows, 7.8x at five
# hundred (rust/README.md), and misaligned on CJK and emoji -- unless the user
# happened to read --doctor.  So when cargo is here and the binary is missing
# or older than its sources, the plugin builds it: as a tmux job (run-shell -b),
# so neither tmux's startup nor the key bindings ever wait for a compiler, and
# niced, because it competes with whatever the user is actually doing.  The
# output goes to $XDG_STATE_HOME/interdimux/build.log, and the status line says
# when it is done or has failed.  `set -g @interdimux-autobuild off` opts out.

# Prints the cargo to build with, or fails when there is nothing to build (or
# the user said not to).  Asked again by the job itself, under its lock: another
# job may have just finished the same build.
imux_build_cargo() {
  local c
  [ -f "$RUST_DIR/Cargo.toml" ] || return 1
  # Forced to the bash renderer, or pointed at a binary elsewhere: the in-repo
  # build would never be used.
  [ "${INTERDIMUX_USE_RUST:-on}" != off ] || return 1
  [ -n "${INTERDIMUX_BIN:-}" ] && [ -x "$INTERDIMUX_BIN" ] && return 1
  # Stale by the same test --doctor applies (sources newer than the binary).
  # -type f, or find lists the start directory itself.
  if [ -x "$IMUX" ] \
     && [ -z "$(find "$RUST_DIR/src" "$RUST_DIR/Cargo.toml" -type f -newer "$IMUX" 2>/dev/null)" ]; then
    return 1
  fi
  # On PATH, or where rustup puts it: a PATH that only a shell rc extends
  # (~/.cargo/env) is exactly what a tmux server started some other way has.
  if c=$(command -v cargo 2>/dev/null) && [ -n "$c" ]; then :
  else
    c="${CARGO_HOME:-$HOME/.cargo}/bin/cargo"
    [ -x "$c" ] || return 1
  fi
  # Last, because it is the one check that costs a tmux round-trip.
  [ "$(tmux show-option -gqv @interdimux-autobuild 2>/dev/null)" != off ] || return 1
  printf '%s' "$c"
}

# The job.  Runs under `run-shell -b`, from the tmux server's environment.
if [ "${1:-}" = --autobuild ]; then
  state="${XDG_STATE_HOME:-$HOME/.local/state}/interdimux"
  log="$state/build.log"
  mkdir -p "$state" "$RUST_DIR/target" 2>/dev/null || exit 0

  # One build at a time.  A config reload while cargo runs re-runs this file,
  # and cargo would only queue the second build behind its own lock -- and then
  # announce it a second time.  A symlink is created atomically WITH its
  # content, so the lock names its owner from the first instant; an owner that
  # is gone (a killed server took the job with it) leaves a lock to take over.
  lock="$RUST_DIR/target/.interdimux-autobuild.lock"
  if ! ln -s "$$" "$lock" 2>/dev/null; then
    owner=$(readlink "$lock" 2>/dev/null) || owner=""
    case "$owner" in
      ''|*[!0-9]*) ;;
      *) kill -0 "$owner" 2>/dev/null && exit 0 ;;
    esac
    rm -f "$lock"
    ln -s "$$" "$lock" 2>/dev/null || exit 0
  fi
  trap 'rm -f "$lock"' EXIT

  cargo=$(imux_build_cargo) || exit 0

  # --locked: this is TPM's git checkout, and a build that rewrote the tracked
  # Cargo.lock would leave it dirty, which can make the next `git pull` (TPM's
  # update) refuse.  CARGO_TARGET_DIR: a user-wide one would put the binary
  # somewhere the script never looks, and every load would build it again.
  {
    printf '== building %s with %s, %s\n' "$RUST_DIR" "$cargo" "$(date 2>/dev/null)"
    ( cd "$RUST_DIR" && CARGO_TARGET_DIR="$RUST_DIR/target" \
        nice -n 10 "$cargo" build --release --locked ) </dev/null 2>&1
  } > "$log" 2>&1
  rc=$?

  if [ "$rc" = 0 ] && [ -x "$IMUX" ]; then
    # cargo leaves the binary alone when it decides nothing changed -- after a
    # touch, or a checkout that restored the same content -- and the staleness
    # test above would then build again on every load.  cargo just said it is
    # current; make the timestamp say so too.
    touch "$IMUX" 2>/dev/null
    echo "== ok" >> "$log"
    msg="interdimux: the Rust core is built; the picker uses it from the next open"
  else
    echo "== failed (exit $rc)" >> "$log"
    msg="interdimux: building the Rust core failed (the bash renderer is used); see $log"
  fi
  # display-message format-expands its text: '##' is a literal '#'.  -d for
  # long enough to read; tmux < 3.2 has no -d, and gets the default instead.
  msg="${msg//'#'/##}"
  tmux display-message -d 5000 "$msg" >/dev/null 2>&1 \
    || tmux display-message "$msg" >/dev/null 2>&1
  exit 0
fi

# ---------------------------------------------------------------------------
# Key bindings
# ---------------------------------------------------------------------------

# The script installs its own bindings (--bind-keys).  On tmux >= 3.4 that
# binds prefix+f straight to display-popup via `run-shell -bC`, so opening the
# picker spawns no shell and no launcher process; below 3.4 it installs the
# original run-shell binding.  Either way the keys come from
# @interdimux-key / @interdimux-dashboard-key.
#
# If that fails for any reason, fall back here so the plugin is never left
# with no bindings at all.
if ! bash "$SCRIPT" --bind-keys 2>/dev/null; then
  interdimux_key=$(tmux show-option -gqv @interdimux-key)
  interdimux_key="${interdimux_key:-f}"
  dashboard_key=$(tmux show-option -gqv @interdimux-dashboard-key)
  dashboard_key="${dashboard_key:-g}"

  # run-shell FORMAT-EXPANDS its argument, so a '#' in the install path is eaten
  # at keypress ('#f' and '#S' are formats) and the binding silently does
  # nothing.  '##' is tmux's escape.  The quoted pattern is required: a bare '#'
  # in ${var//#/…} is the match-at-start anchor.
  sq="${SCRIPT//\'/\'\\\'\'}"
  fmt="${sq//'#'/##}"

  # TMUX_PANE=#{pane_id}: run-shell passes the SERVER's global TMUX_PANE, which
  # is whatever the process that started the server exported — not the pressing
  # client's pane.  Everything that asks "which pane am I in" depends on this.
  tmux bind-key "$interdimux_key" run-shell -b \
    "TMUX_PANE=#{pane_id} bash '$fmt' --launch switch"
  tmux bind-key "$dashboard_key" run-shell -b \
    "TMUX_PANE=#{pane_id} bash '$fmt' --dashboard-launch"
fi

# After the bindings, so they never wait on this.  An up-to-date install pays
# one `find` for it.
if imux_build_cargo >/dev/null; then
  self="$CURRENT_DIR/${BASH_SOURCE[0]##*/}"
  sq="${self//\'/\'\\\'\'}"
  tmux run-shell -b "bash '${sq//'#'/##}' --autobuild" 2>/dev/null
fi
