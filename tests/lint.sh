#!/usr/bin/env bash
#
# The lint, exactly as CI runs it.  The workflow's shellcheck job is
# `bash tests/lint.sh`, so the two invocations below are the only copy, and a
# push is no longer the first place they run (docs/CI.md §9).
#
#   tests/lint.sh
#   SHELLCHECK=/path/to/shellcheck tests/lint.sh
#
# ONE shellcheck version, here and in CI: 0.10.0.  apt's is whatever the
# runner image ships (0.9.0 on ubuntu-24.04, 0.11.0 on 26.04), and a newer one
# brings new SC codes, which fail the job with no change to the code.  When the
# `shellcheck` on PATH is another version (or there is none), the release
# binary is fetched once into ~/.cache/shellcheck/v0.10.0/ -- checksummed,
# since it is then run -- and used from there.  SHELLCHECK names one to use
# instead, as it is.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SC_VERSION=0.10.0

sc_version() { "$1" --version 2>/dev/null | awk '$1 == "version:" { print $2 }'; }

# REPLY = a shellcheck of exactly $SC_VERSION, fetched when there is none.
pinned_shellcheck() {
  local dir asset sum tmp got
  if command -v shellcheck >/dev/null 2>&1 && [ "$(sc_version shellcheck)" = "$SC_VERSION" ]; then
    REPLY=$(command -v shellcheck); return 0
  fi
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/shellcheck/v$SC_VERSION"
  REPLY="$dir/shellcheck"
  [ -x "$REPLY" ] && [ "$(sc_version "$REPLY")" = "$SC_VERSION" ] && return 0

  # The release's own archives; the sums are of those, as fetched for this pin.
  case "$(uname -s).$(uname -m)" in
    Linux.x86_64)  asset=linux.x86_64   sum=6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87 ;;
    Linux.aarch64|Linux.arm64)
                   asset=linux.aarch64  sum=324a7e89de8fa2aed0d0c28f3dab59cf84c6d74264022c00c22af665ed1a09bb ;;
    Darwin.x86_64) asset=darwin.x86_64  sum=ef27684f23279d112d8ad84e0823642e43f838993bbb8c0963db9b58a90464c2 ;;
    Darwin.arm64)  asset=darwin.aarch64 sum=bbd2f14826328eee7679da7221f2bc3afb011f6a928b848c80c321f6046ddf81 ;;
    *) echo "lint.sh: no shellcheck $SC_VERSION release for $(uname -sm): install that version, or set SHELLCHECK" >&2
       return 1 ;;
  esac
  echo "lint.sh: fetching shellcheck $SC_VERSION into $dir" >&2
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/interdimux-lint.XXXXXX")
  # shellcheck disable=SC2064  # $tmp is fixed now, and wanted expanded
  trap "rm -rf '$tmp'" EXIT
  # (set -e does not reach in here, under the caller's ||: each step says so)
  curl -fsSL --retry 3 -o "$tmp/sc.tar.xz" \
    "https://github.com/koalaman/shellcheck/releases/download/v$SC_VERSION/shellcheck-v$SC_VERSION.$asset.tar.xz" \
    || return 1
  if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum < "$tmp/sc.tar.xz")
  else got=$(shasum -a 256 < "$tmp/sc.tar.xz"); fi
  if [ "${got%% *}" != "$sum" ]; then
    echo "lint.sh: the shellcheck $SC_VERSION download does not match its checksum" >&2
    return 1
  fi
  tar -xJf "$tmp/sc.tar.xz" -C "$tmp" || return 1
  mkdir -p "$dir" && mv "$tmp/shellcheck-v$SC_VERSION/shellcheck" "$REPLY"
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

[ "$rc" = 0 ] && echo "clean"
exit "$rc"
