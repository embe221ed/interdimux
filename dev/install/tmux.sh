#!/usr/bin/env bash
#
#   dev/install/tmux.sh PREFIX
#
# Builds the pinned tmux (TMUX_VERSION) from its release tarball into PREFIX,
# as CI and the dev image both do: no distro on the CI image ships one new
# enough (dev/versions.env has why 3.6 is the floor).  Needs build-essential,
# libevent-dev, libncurses-dev, bison and pkg-config.
#
# Stock ./configure, nothing enabled: in particular no --enable-utf8proc, which
# would replace glibc's character widths with utf8proc's and make the width
# tests disagree with the host's tmux and CI's.  The tmux-256color terminfo
# entry must be installed while this runs (ncurses-base): configure probes for
# it to choose the default-terminal it compiles in.

set -euo pipefail
# shellcheck source=dev/install/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 1 ] || die "usage: $0 PREFIX"
prefix=$1
v=$(pinned TMUX_VERSION)
scratch
tarball=$(fetch tmux "$v" "$IMUX_SCRATCH")
tar -xzf "$tarball" -C "$IMUX_SCRATCH"
cd "$IMUX_SCRATCH/tmux-$v"
./configure --prefix="$prefix"
make -j"$(ncpu)"
make install
"$prefix/bin/tmux" -V
