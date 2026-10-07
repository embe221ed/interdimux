#!/usr/bin/env bash
#
#   dev/install/linters.sh BINDIR
#
# Installs the pinned actionlint, hadolint and lychee release binaries into
# BINDIR, for this Linux machine's architecture: what dev/lint-extra.sh runs.

set -euo pipefail
# shellcheck source=dev/install/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 1 ] || die "usage: $0 BINDIR"
bindir=$1
arch=$(host_arch)
scratch
mkdir -p "$bindir"

f=$(fetch actionlint "$(pinned ACTIONLINT_VERSION)" "$IMUX_SCRATCH" linux "$arch")
tar -xzf "$f" -C "$bindir" actionlint

f=$(fetch hadolint "$(pinned HADOLINT_VERSION)" "$IMUX_SCRATCH" linux "$arch")
install -m 0755 "$f" "$bindir/hadolint"

f=$(fetch lychee "$(pinned LYCHEE_VERSION)" "$IMUX_SCRATCH" linux "$arch")
tar -xzf "$f" -C "$IMUX_SCRATCH"
install -m 0755 "$(find "$IMUX_SCRATCH" -name lychee -type f | head -n 1)" "$bindir/lychee"

"$bindir/actionlint" --version | head -n 1
"$bindir/hadolint" --version
"$bindir/lychee" --version
