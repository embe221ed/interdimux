#!/usr/bin/env bash
#
#   dev/install/zoxide.sh DIR
#
# Installs the pinned zoxide release binary (a static musl build) as
# DIR/zoxide, for this Linux machine's architecture.  Only the A/B harness
# (dev/perf/) runs it, through IMUX_PERF_ZOXIDE: the dev image keeps it off
# the PATH, since CI's runner has no zoxide and the suites must see the same.

set -euo pipefail
# shellcheck source=dev/install/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 1 ] || die "usage: $0 DIR"
dir=$1
arch=$(host_arch)
scratch
mkdir -p "$dir"

f=$(fetch zoxide "$(pinned ZOXIDE_VERSION)" "$IMUX_SCRATCH" linux "$arch")
tar -xzf "$f" -C "$IMUX_SCRATCH" zoxide
install -m 0755 "$IMUX_SCRATCH/zoxide" "$dir/zoxide"

"$dir/zoxide" --version
