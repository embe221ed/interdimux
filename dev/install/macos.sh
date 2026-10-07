#!/usr/bin/env bash
#
#   dev/install/macos.sh PREFIX
#
# What CI's macOS job runs the plugin with, built into PREFIX (put PREFIX/bin
# first on PATH afterwards): bash 5.3 with its official patches, tmux with the
# libraries Homebrew builds it with, and fzf -- the versions dev/versions.env
# pins, the way a Mac user gets them from Homebrew.  From source, because
# Homebrew has no Intel builds any more (it would compile all of it, Go for
# fzf included, for over an hour), and so that both Macs and Linux run the
# same pinned tmux and fzf.
#
# Runs under macOS's own /bin/bash 3.2, which is what a runner has before
# this: hence no bash-4 features here or in lib.sh.  Needs the Xcode command
# line tools (cc, make, bison, patch) and pkg-config, all on the runner images.
#
# libevent and utf8proc are installed as static libraries only, so tmux
# carries them inside the binary.  jemalloc stays a dylib, as Homebrew links
# it: on macOS it takes over as the process's allocator through a malloc zone
# its constructor registers, which a static link could drop.  tmux finds it at
# run time through the rpath dev/install/tmux.sh gives it, so PREFIX must stay
# where it was built (CI restores its cache to the same path).
#
# jemalloc is configured with an EMPTY --with-jemalloc-prefix, as Homebrew's
# formula does: on Darwin its configure otherwise prefixes the whole API with
# je_, and tmux 3.7c calls mallctl() (proc.c), which would then neither
# compile nor link.

set -euo pipefail
# shellcheck source=dev/install/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 1 ] || die "usage: $0 PREFIX"
mkdir -p "$1"
prefix=$(CDPATH='' cd -- "$1" && pwd)
here=$(dirname "${BASH_SOURCE[0]}")
jobs=$(ncpu)
scratch

# step NAME COMMAND...: the command's output goes to a log, shown on failure
step() {
  local name=$1 log="$IMUX_SCRATCH/$1.log"; shift
  echo "==> $name"
  if ! "$@" > "$log" 2>&1; then tail -40 "$log"; die "$name failed"; fi
}

v=$(pinned LIBEVENT_VERSION)
f=$(fetch libevent "$v" "$IMUX_SCRATCH")
tar -xzf "$f" -C "$IMUX_SCRATCH"
( cd "$IMUX_SCRATCH/libevent-$v-stable" &&
  step libevent sh -c "./configure --prefix='$prefix' --disable-shared --disable-openssl --disable-samples --disable-libevent-regress && make -j$jobs && make install" )

v=$(pinned UTF8PROC_VERSION)
f=$(fetch utf8proc "$v" "$IMUX_SCRATCH")
tar -xzf "$f" -C "$IMUX_SCRATCH"
( cd "$IMUX_SCRATCH/utf8proc-$v" &&
  step utf8proc sh -c "make -j$jobs libutf8proc.a libutf8proc.pc prefix='$prefix' && make install prefix='$prefix'" )
rm -f "$prefix"/lib/libutf8proc*.dylib "$prefix"/lib/libutf8proc*.so*

v=$(pinned JEMALLOC_VERSION)
f=$(fetch jemalloc "$v" "$IMUX_SCRATCH")
tar -xjf "$f" -C "$IMUX_SCRATCH"
( cd "$IMUX_SCRATCH/jemalloc-$v" &&
  step jemalloc sh -c "./configure --prefix='$prefix' --with-jemalloc-prefix= && make -j$jobs && make install_bin install_include install_lib" )

step tmux bash "$here/tmux.sh" "$prefix"
"$prefix/bin/tmux" -V

# bash: the 5.3 tarball, then GNU's patches 1..N in order (-p0, as GNU ships
# them), MACOS_BASH_VERSION=5.3.N
v=$(pinned MACOS_BASH_VERSION)
base=${v%.*} n=${v##*.}
f=$(fetch bash-macos "$base" "$IMUX_SCRATCH")
tar -xzf "$f" -C "$IMUX_SCRATCH"
i=1
while [ "$i" -le "$n" ]; do
  p=$(fetch bash-macos "$base.$i" "$IMUX_SCRATCH")
  (cd "$IMUX_SCRATCH/bash-$base" && patch -s -p0 < "$p")
  i=$((i + 1))
done
( cd "$IMUX_SCRATCH/bash-$base" &&
  step bash sh -c "./configure --prefix='$prefix' && make -j$jobs && make install" )
# shellcheck disable=SC2016  # $BASH_VERSION is the new bash's own
"$prefix/bin/bash" -c 'echo "bash $BASH_VERSION"'

bash "$here/fzf.sh" "$prefix/bin"
