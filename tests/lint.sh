#!/usr/bin/env bash
#
# The lint, exactly as CI runs it.  The workflow's shellcheck job is
# `bash tests/lint.sh`, so the invocations below are the only copy, and a
# push is no longer the first place they run (docs/CI.md §9).
#
#   tests/lint.sh
#   SHELLCHECK=/path/to/shellcheck tests/lint.sh
#
# ONE shellcheck version, here, in CI and in the dev image: SHELLCHECK_VERSION
# in dev/versions.env.  apt's is whatever the runner image ships
# (0.9.0 on ubuntu-24.04, 0.11.0 on 26.04), and a newer one brings new SC
# codes, which fail the job with no change to the code.  When the `shellcheck`
# on PATH is another version (or there is none), the release binary is fetched
# once into ~/.cache/shellcheck/v<version>/ by dev/install/shellcheck.sh --
# checked against dev/checksums/shellcheck.sha256, since it is then run -- and
# used from there.  SHELLCHECK names one to use instead, as it is.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SC_VERSION=$(sed -n 's/^SHELLCHECK_VERSION=//p' dev/versions.env | tail -n 1)
[ -n "$SC_VERSION" ] || { echo "lint.sh: no SHELLCHECK_VERSION in dev/versions.env" >&2; exit 2; }

sc_version() { "$1" --version 2>/dev/null | awk '$1 == "version:" { print $2 }'; }

# REPLY = a shellcheck of exactly $SC_VERSION, fetched when there is none.
pinned_shellcheck() {
  local dir
  if command -v shellcheck >/dev/null 2>&1 && [ "$(sc_version shellcheck)" = "$SC_VERSION" ]; then
    REPLY=$(command -v shellcheck); return 0
  fi
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/shellcheck/v$SC_VERSION"
  REPLY="$dir/shellcheck"
  [ -x "$REPLY" ] && [ "$(sc_version "$REPLY")" = "$SC_VERSION" ] && return 0
  echo "lint.sh: fetching shellcheck $SC_VERSION into $dir" >&2
  # (set -e does not reach in here, under the caller's ||: say so)
  SHELLCHECK_VERSION=$SC_VERSION bash dev/install/shellcheck.sh "$dir" >/dev/null || {
    echo "lint.sh: install shellcheck $SC_VERSION, or set SHELLCHECK" >&2; return 1; }
}

if [ -n "${SHELLCHECK:-}" ]; then
  SC="$SHELLCHECK"
else
  pinned_shellcheck || exit 2
  SC="$REPLY"
fi
echo "shellcheck $(sc_version "$SC") ($SC)"

# Two invocations on purpose, with the SHIPPED code held to the stricter bar.
# A single call needs the union of both exclusion lists, and that union hid two
# genuinely dead variables in the script behind the test harnesses' deliberate
# SC2034s (docs/CI.md §9).  Both run even when the first fails, so one push
# shows everything.
rc=0

# scripts/ excludes only what is deliberate there:
#   SC2191  `--"$HINT_BAR"="$REPLY"` as an array element; the `=` is literal
#   SC2206  the RS split and the grouping loops' line and field splits in
#           gather_targets, unquoted on purpose under `set -f`
echo "==> the plugin"
"$SC" -S warning -e SC2191,SC2206 \
  scripts/interdimux.sh interdimux.tmux || rc=1

# tests/ additionally excludes the harness idioms:
#   SC2155  `export TMUX="$(tmux …)"` — the masked exit status is not wanted
#   SC2034  loop counters and flags read by an eval'd snippet
#   SC2164  `cd` in run_all.sh, guarded by its caller
#   SC2010  `ls | grep` over a tmux socket directory
#   SC2154  a variable defined by the `eval` on the line above
echo "==> the tests"
"$SC" -S warning -e SC2155,SC2034,SC2164,SC2010,SC2154 \
  tests/*.sh || rc=1

# dev/ -- the dev image's and CI's install recipes, the host-side dev/run.sh
# (POSIX sh, for macOS's /bin/sh), and the A/B harness in dev/perf/ -- is held
# to the plugin's bar, with nothing excluded.  -x follows each installer into
# dev/install/lib.sh, and uxdiff.sh into the parts it sources.
echo "==> the dev environment"
"$SC" -S warning -x dev/*.sh dev/install/*.sh dev/perf/*.sh || rc=1

[ "$rc" = 0 ] && echo "clean"
exit "$rc"
