#!/usr/bin/env bash
#
#   dev/install/shellcheck.sh BINDIR
#
# Installs the pinned shellcheck release (SHELLCHECK_VERSION) as
# BINDIR/shellcheck, for this machine (Linux or macOS, x86_64 or arm64).
# tests/lint.sh calls this when the shellcheck on PATH is another version.

set -euo pipefail
# shellcheck source=dev/install/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 1 ] || die "usage: $0 BINDIR"
bindir=$1
v=$(pinned SHELLCHECK_VERSION)
scratch
tarball=$(fetch shellcheck "$v" "$IMUX_SCRATCH" "$(host_os)" "$(host_arch)")
tar -xJf "$tarball" -C "$IMUX_SCRATCH"
mkdir -p "$bindir"
mv "$IMUX_SCRATCH/shellcheck-v$v/shellcheck" "$bindir/shellcheck"
"$bindir/shellcheck" --version | sed -n 2p
