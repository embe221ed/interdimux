#!/bin/bash
#
# What the dev image does, run as the `dev` user in /work, the container's own
# copy of the checkout (dev/entrypoint.sh).  dev/run.sh on the host is the way
# in; `make help` lists the same commands.
#
#   test [FILTER...]   tests/run_all.sh, the Rust core built first
#   smoke              tests/smoke.sh, the end-to-end check CI runs on macOS
#   ci                 what CI's tests job runs, both renderer legs (or the one
#                      IMUX_RENDERER names), strict: a skip fails.  The rust
#                      leg includes check-macos, msrv and smoke, as in CI.
#   ci-sigpipe         the same with SIGPIPE ignored, as GitHub runs its steps
#   versions           every pinned tool, checked present and at its pin
#   lint               tests/lint.sh, then dev/lint-extra.sh
#   check-macos        type-checks the Rust core for x86_64 and arm64 macOS
#   msrv               builds and tests the Rust core with its rust-version
#   bench [ARGS]       tests/bench.sh
#   watch [FILTER...]  re-runs those suites whenever a file under /src changes
#   shell              an interactive shell (the default)
#   run CMD [ARGS]     any command

set -euo pipefail
cd /work

BOLD=$'\033[1m' RED=$'\033[31m' GREEN=$'\033[32m' RST=$'\033[0m'
say() { printf '%s==> %s%s\n' "$BOLD" "$*" "$RST"; }

pin() { sed -n "s/^$1=//p" dev/versions.env | tail -n 1; }
items() { printf '%s\n' "$1" | tr ',' '\n' | sed '/^$/d'; }

# The Rust core every renderer-comparing suite pins on, built against this
# container's glibc into the volume's rust/target.  Offline: the image fetched
# the crates.
build_core() {
  cargo build --release --locked --quiet --manifest-path rust/Cargo.toml
}

# Every tool a strict run needs, present and at its pin.  Mirrors ci.yml's
# "Versions under test" step, plus what a container could get wrong that a
# runner cannot.
versions() {
  local bad=() v d got want
  check() {  # check LABEL COMMAND... : prints the command's first line, or fails
    local out
    if out=$("${@:2}" 2>&1 | head -n 1) && [ -n "$out" ]; then
      printf '  %-14s %s\n' "$1" "$out"
    else
      printf '  %-14s %sMISSING%s\n' "$1" "$RED" "$RST"; bad+=("$1")
    fi
  }
  want_eq() {  # want_eq LABEL GOT WANT
    [ "$2" = "$3" ] || { printf '  %-14s %sis %s, dev/versions.env pins %s%s\n' "$1" "$RED" "$2" "$3" "$RST"; bad+=("$1"); }
  }
  check tmux tmux -V
  want_eq tmux "$(tmux -V | awk '{ print $2 }')" "$(pin TMUX_VERSION)"
  check fzf fzf --version
  want_eq fzf "$(fzf --version | awk '{ print $1 }')" "$(pin FZF_VERSION)"
  for v in $(items "$(pin OLD_FZF_VERSIONS)"); do
    check "fzf $v" "$INTERDIMUX_OLD_FZF_DIR/$v/fzf" --version
    want_eq "fzf $v" "$("$INTERDIMUX_OLD_FZF_DIR/$v/fzf" --version 2>/dev/null | awk '{ print $1 }')" "$v"
  done
  check bash bash -c 'echo "bash $BASH_VERSION"'
  for v in $(items "$(pin OLD_BASH_VERSIONS)"); do
    d=$(echo "$v" | cut -d. -f1,2)
    # shellcheck disable=SC2016  # $BASH_VERSION is the old bash's own
    check "bash $d" "$INTERDIMUX_OLD_BASH_DIR/$d/bash" -c 'echo "bash $BASH_VERSION"'
    # as tests/test_bash_floor.sh insists: $BASH_VERSION starts with the pin
    # shellcheck disable=SC2016
    got=$("$INTERDIMUX_OLD_BASH_DIR/$d/bash" -c 'echo "$BASH_VERSION"' 2>/dev/null)
    case $got in "$v"*) ;; *) want_eq "bash $d" "$got" "$v" ;; esac
  done
  check zsh zsh --version
  check dash sh -c 'readlink -f /bin/sh'
  check awk awk --version
  check strace strace -V
  check at sh -c 'dpkg-query -W -f="at \${Version}\n" at'
  check cargo cargo --version
  want_eq rustc "$(rustc --version | awk '{ print $2 }')" "$(pin RUST_VERSION)"
  check shellcheck sh -c 'shellcheck --version | sed -n 2p'
  want_eq shellcheck "$(shellcheck --version 2>/dev/null | awk '$1 == "version:" { print $2 }')" "$(pin SHELLCHECK_VERSION)"
  check actionlint actionlint --version
  want_eq actionlint "$(actionlint --version 2>/dev/null | head -n 1)" "$(pin ACTIONLINT_VERSION)"
  check hadolint hadolint --version
  want_eq hadolint "$(hadolint --version 2>/dev/null | awk '{ print $NF }')" "$(pin HADOLINT_VERSION)"
  check lychee lychee --version
  want_eq lychee "$(lychee --version 2>/dev/null | awk '{ print $2 }')" "$(pin LYCHEE_VERSION)"
  check locale locale charmap
  check en_US.UTF-8 sh -c 'locale -a | grep -ix en_US.utf8'
  for v in ps pgrep setsid script perl python3 fdfind git timeout entr rsync; do
    check "$v" sh -c "command -v $v"
  done
  check atd pgrep -ax atd
  check '/proc kids' sh -c '[ -r /proc/$$/task/$$/children ] && echo "/proc/<pid>/task/<pid>/children readable"'
  check user sh -c '[ "$(id -u)" != 0 ] && echo "$(id -un) (uid $(id -u))"'
  got=$(tmux -f /dev/null -L imux-versions start-server \; show-options -sv default-terminal 2>&1; tmux -L imux-versions kill-server 2>/dev/null || true)
  want=tmux-256color
  printf '  %-14s %s\n' default-term "$got"
  want_eq default-term "$got" "$want"
  if [ ${#bad[@]} -gt 0 ]; then
    printf '%smissing or wrong: %s%s\n' "$RED" "${bad[*]}" "$RST"; return 1
  fi
  printf '%severy pinned tool is here%s\n' "$GREEN" "$RST"
}

# The macOS process backend (rust/src/macproc.rs) is not even compiled on
# Linux; the std targets are enough to type-check it, tests included.
check_macos() {
  say "cargo check for macOS, x86_64 and arm64 (ci.yml: The Rust core type-checks for macOS)"
  cargo check --locked --all-targets --manifest-path rust/Cargo.toml \
    --target x86_64-apple-darwin --target aarch64-apple-darwin
}

# rust/Cargo.toml's rust-version, which nothing else compiles with.
msrv_test() {
  local msrv
  msrv=$(sed -n 's/^rust-version *= *"\([^"]*\)".*/\1/p' rust/Cargo.toml)
  say "build and test with Rust $msrv (ci.yml: The Rust core builds and passes on its rust-version)"
  CARGO_TARGET_DIR=rust/target/msrv cargo +"$msrv" test --release --locked --manifest-path rust/Cargo.toml
}

# One CI leg, as ci.yml's tests job runs it.  (Called under ||, where set -e
# does not reach, so each step's status is kept by hand.)
ci_leg() {
  local leg=$1 rc=0
  if [ "$leg" = rust ]; then
    say "rust tests (ci.yml: Rust tests)"
    cargo test --release --locked --manifest-path rust/Cargo.toml || rc=1
    check_macos || rc=1
    msrv_test || rc=1
  fi
  say "shell tests, $leg renderer (ci.yml: Shell tests)"
  IMUX_STRICT=1 INTERDIMUX_TEST_DOCKER=off IMUX_SKIP_RUST=1 IMUX_RENDERER=$leg \
    bash tests/run_all.sh || rc=1
  if [ "$leg" = rust ]; then
    say "smoke test (ci.yml: Smoke test; the macos job runs it on real Macs)"
    SMOKE_STRICT=1 bash tests/smoke.sh || rc=1
  fi
  return "$rc"
}

ci() {
  local legs leg failed=()
  say "versions under test"
  versions
  say "build the Rust core"
  build_core
  legs=${IMUX_RENDERER:-rust bash}
  for leg in $legs; do
    ci_leg "$leg" || failed+=("$leg")
  done
  if [ ${#failed[@]} -gt 0 ]; then
    printf '%sCI legs that failed: %s%s\n' "$RED" "${failed[*]}" "$RST"; return 1
  fi
  printf '%sCI legs passed: %s%s\n' "$GREEN" "$legs" "$RST"
}

sync_src() {  # the entrypoint's copy again, as dev (who owns /work already)
  rsync -rlpt --no-D --delete --exclude=/rust/target/ --out-format='%n' /src/ /work/ \
    | { grep '^rust/' || true; } | while IFS= read -r f; do [ -f "/work/$f" ] && touch "/work/$f"; done
}

case "${1:-shell}" in
  test)
    shift; build_core; exec bash tests/run_all.sh "$@" ;;
  smoke)
    build_core; SMOKE_STRICT=1 exec bash tests/smoke.sh ;;
  ci)
    ci ;;
  ci-sigpipe)
    # GitHub starts every run: step with SIGPIPE ignored, and SIG_IGN survives
    # execve, so everything the suites spawn inherits it.  Only there does
    # this project run that way, and it found a real bug (docs/CI.md section
    # 10).  Docker starts processes with the default disposition, so this is
    # the one way to get CI's.
    trap '' PIPE; ci ;;
  versions)
    versions ;;
  lint)
    # both, even when the first fails, so one run shows everything
    rc=0
    say "tests/lint.sh"; bash tests/lint.sh || rc=1
    say "dev/lint-extra.sh"; bash dev/lint-extra.sh || rc=1
    exit "$rc" ;;
  check-macos)
    check_macos
    printf '%sthe Rust core type-checks for both macOS targets%s\n' "$GREEN" "$RST" ;;
  msrv)
    msrv_test ;;
  bench)
    shift; build_core; exec bash tests/bench.sh "$@" ;;
  watch)
    shift
    [ -t 0 ] || { echo "watch needs a terminal: dev/run.sh gives it one" >&2; exit 2; }
    build_core
    files() { find /src -path /src/.git -prune -o -path /src/rust/target -prune -o -type f -print; }
    list=$(files)
    while :; do
      # No -r: a restart would kill run_all.sh but not the suite it was
      # waiting for (timeout gives each suite a process group of its own), so
      # a change made during a run starts one more run once this one ends.
      # entr ends with 2 when a file is added (-d) and with 1 when a watched
      # one goes; either way the loop watches the new list.
      rc=0
      printf '%s\n' "$list" | entr -d -c /usr/local/lib/imux-dev/cmd.sh _watch-step "$@" || rc=$?
      new=$(files)
      case $rc in
        2) ;;
        1) [ "$new" != "$list" ] || exit 1 ;;
        *) exit "$rc" ;;
      esac
      list=$new
    done ;;
  _watch-step)
    shift; sync_src; build_core; bash tests/run_all.sh "$@" || true ;;
  shell)
    # An unknown TERM (Ghostty's xterm-ghostty, say) has no terminfo here, and
    # a tmux client would refuse to start: fall back to one that has.
    if [ -n "${TERM:-}" ] && ! infocmp "$TERM" >/dev/null 2>&1; then export TERM=xterm-256color; fi
    printf '%sinterdimux dev shell%s: /work is a copy of your checkout (re-copied each run).\n' "$BOLD" "$RST"
    printf 'tmux here starts this container'\''s own servers; your host'\''s are out of reach.\n'
    printf 'Try: tests/run_all.sh raw | tmux | bash scripts/interdimux.sh --doctor (inside tmux)\n\n'
    exec bash -l ;;
  run)
    shift; exec "$@" ;;
  *)
    sed -n '/^#   /s/^#   //p' "$0" >&2; exit 2 ;;
esac
