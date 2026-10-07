#!/usr/bin/env bash
#
#   dev/install/fzf-old.sh DIR
#
# Installs every OLD_FZF_VERSIONS release as DIR/<version>/fzf, where
# tests/test_old_fzf.sh looks when INTERDIMUX_OLD_FZF_DIR=DIR.  Real release
# binaries, since neither failure that suite guards can be emulated on a new
# fzf: 0.44 refuses to start on an event it does not know, and 0.52 and older
# draw their whole interface on stderr.

set -euo pipefail
# shellcheck source=dev/install/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 1 ] || die "usage: $0 DIR"
dir=$1
arch=$(host_arch)
scratch
for v in $(items "$(pinned OLD_FZF_VERSIONS)"); do
  tarball=$(fetch fzf-old "$v" "$IMUX_SCRATCH" linux "$arch")
  mkdir -p "$dir/$v"
  tar -xzf "$tarball" -C "$dir/$v" fzf
  # the suite insists on this: the first word of --version must be <v>
  got=$("$dir/$v/fzf" --version | awk '{ print $1 }')
  [ "$got" = "$v" ] || die "$dir/$v/fzf says it is $got"
  echo "fzf $v"
done
