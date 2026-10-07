#!/usr/bin/env bash
#
#   dev/install/fzf.sh BINDIR
#
# Installs the pinned fzf release binary (FZF_VERSION) as BINDIR/fzf, for this
# machine (Linux or macOS, x86_64 or arm64).  The distro packages lag far
# behind the 0.74 floor.

set -euo pipefail
# shellcheck source=dev/install/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 1 ] || die "usage: $0 BINDIR"
bindir=$1
v=$(pinned FZF_VERSION)
scratch
tarball=$(fetch fzf "$v" "$IMUX_SCRATCH" "$(host_os)" "$(host_arch)")
mkdir -p "$bindir"
tar -xzf "$tarball" -C "$bindir" fzf
"$bindir/fzf" --version
