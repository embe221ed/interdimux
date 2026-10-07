#!/usr/bin/env bash
#
#   dev/install/bash-old.sh DIR
#
# Builds every OLD_BASH_VERSIONS bash from its GNU tarball as
# DIR/<major.minor>/bash, where tests/test_bash_floor.sh looks when
# INTERDIMUX_OLD_BASH_DIR=DIR.  (Each goes under its major.minor cut from the
# tarball's name: "5.0", where the suite looks, and not "5", which ${v%.*}
# would make of it.)
#
# What the build needs, each found by running it (docs/CI.md section 12):
#
# * -std=gnu89 and the -Wno-implicit-*, -Wno-int-conversion and
#   -Wno-incompatible-pointer-types flags, in CFLAGS AND in CFLAGS_FOR_BUILD.
#   These K&R-era sources lean on exactly what gcc 14 turned from warnings into
#   errors, and 3.2's and 4.2's configure set CFLAGS_FOR_BUILD -- what the
#   build-time helpers (mkbuiltins, ...) are compiled with -- to a bare -g, so
#   under gcc 15's C23 default `int f();` means f(void) and mkbuiltins.c stops.
# * NO -O2, so CFLAGS must be given (configure's default is -g -O2): with it,
#   3.2's configure spins in its mktime probe, a loop that relies on signed
#   overflow wrapping.
# * make -j races in 3.2's lib/readline on a small machine (`ar: xmalloc.o: No
#   such file or directory`), so a failed parallel make is followed by a serial
#   one, which finishes what it left.
# * On arm64 (an Apple Silicon Mac's container), 3.2's and 4.2's config.guess
#   predate aarch64 and cannot name the machine.  Only when the bundled one
#   fails are config.guess and config.sub replaced with the system's
#   (autotools-dev), so the amd64 build is exactly what CI has always run.

set -euo pipefail
# shellcheck source=dev/install/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 1 ] || die "usage: $0 DIR"
dir=$1
F="-std=gnu89 -Wno-implicit-function-declaration -Wno-implicit-int -Wno-int-conversion -Wno-incompatible-pointer-types"
scratch
for v in $(items "$(pinned OLD_BASH_VERSIONS)"); do
  tarball=$(fetch bash-old "$v" "$IMUX_SCRATCH")
  tar -xzf "$tarball" -C "$IMUX_SCRATCH"
  src="$IMUX_SCRATCH/bash-$v"
  if ! (cd "$src" && sh support/config.guess) >/dev/null 2>&1; then
    for f in config.guess config.sub; do
      [ -f /usr/share/misc/$f ] || die "bash $v's support/config.guess cannot name this machine, and there is no /usr/share/misc/$f (autotools-dev) to replace it with"
      cp /usr/share/misc/$f "$src/support/$f"
    done
  fi
  log="$IMUX_SCRATCH/bash-$v.log"
  if ! (cd "$src" && ./configure --without-bash-malloc CFLAGS="$F" CFLAGS_FOR_BUILD="$F" \
          && { make -j"$(ncpu)" || make; }) > "$log" 2>&1; then
    tail -40 "$log"; die "bash $v did not build"
  fi
  d=$(echo "$v" | cut -d. -f1,2)
  mkdir -p "$dir/$d"
  cp "$src/bash" "$dir/$d/bash"
  # shellcheck disable=SC2016  # $BASH_VERSION is the old bash's own
  "$dir/$d/bash" -c 'echo "bash $BASH_VERSION"'
done
