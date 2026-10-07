# shellcheck shell=bash
#
# Sourced by dev/install/*.sh and dev/pin.sh: where each pinned artifact comes
# from, and a download that is checked against dev/checksums/ before anything
# runs it.  One copy of each recipe, for the dev image and for CI alike, as
# tests/lint.sh is the one copy of the lint.
#
# bash 3.2 or newer: dev/pin.sh and tests/lint.sh run this on macOS too.  (No
# associative arrays, no mapfile, no ${x,,}.)

IMUX_DEV=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

# pinned NAME: the version to use.  The environment wins -- the Dockerfile's
# ARGs and CI's $GITHUB_ENV put it there, both read from dev/versions.env --
# and a run with nothing set reads the file itself.
pinned() {
  local val
  eval "val=\${$1:-}"
  if [ -z "$val" ] && [ -f "$IMUX_DEV/versions.env" ]; then
    val=$(sed -n "s/^$1=//p" "$IMUX_DEV/versions.env" | tail -n 1)
  fi
  [ -n "$val" ] || die "no $1 in the environment or in dev/versions.env"
  printf '%s\n' "$val"
}

# A comma-separated list, one item per line.
items() { printf '%s\n' "$1" | tr ',' '\n' | sed '/^$/d'; }

host_os() {
  case $(uname -s) in
    Linux) echo linux ;; Darwin) echo darwin ;;
    *) die "no pinned artifacts for $(uname -s)" ;;
  esac
}
host_arch() {
  case $(uname -m) in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;;
    *) die "no pinned artifacts for $(uname -m)" ;;
  esac
}

# artifact COMPONENT VERSION [OS ARCH]: prints three lines --
#   the artifact's name in dev/checksums/COMPONENT.sha256 (always naming its
#   version, and its platform when it has one),
#   the URLs to try, space-separated,
#   where the project publishes its own sha256 for it, or "-" (dev/pin.sh
#   cross-checks against that before recording one).
artifact() {
  local comp=$1 v=$2 os=${3:-} arch=${4:-} tag a
  case $comp in
    tmux)
      echo "tmux-$v.tar.gz"
      echo "https://github.com/tmux/tmux/releases/download/$v/tmux-$v.tar.gz"
      echo - ;;
    fzf|fzf-old)
      # fzf's release tags gained their `v` at 0.54.0: 0.53.0 and older are
      # tagged bare, and releases/download/v0.44.1/... is a 404.
      case $v in 0.[0-9].*|0.[0-4][0-9].*|0.5[0-3].*) tag=$v ;; *) tag=v$v ;; esac
      echo "fzf-$v-${os}_$arch.tar.gz"
      echo "https://github.com/junegunn/fzf/releases/download/$tag/fzf-$v-${os}_$arch.tar.gz"
      echo "https://github.com/junegunn/fzf/releases/download/$tag/fzf_${v}_checksums.txt" ;;
    bash-old)
      # ftp.gnu.org itself times out now and then; any mirror will do, since
      # the checksum decides.
      echo "bash-$v.tar.gz"
      echo "https://mirrors.kernel.org/gnu/bash/bash-$v.tar.gz https://ftp.gnu.org/gnu/bash/bash-$v.tar.gz"
      echo - ;;
    shellcheck)
      case $arch in amd64) a=x86_64 ;; arm64) a=aarch64 ;; esac
      echo "shellcheck-v$v.$os.$a.tar.xz"
      echo "https://github.com/koalaman/shellcheck/releases/download/v$v/shellcheck-v$v.$os.$a.tar.xz"
      echo - ;;
    actionlint)
      echo "actionlint_${v}_${os}_$arch.tar.gz"
      echo "https://github.com/rhysd/actionlint/releases/download/v$v/actionlint_${v}_${os}_$arch.tar.gz"
      echo "https://github.com/rhysd/actionlint/releases/download/v$v/actionlint_${v}_checksums.txt" ;;
    hadolint)
      case $arch in amd64) a=x86_64 ;; arm64) a=arm64 ;; esac
      echo "hadolint-$v-$os-$a"
      echo "https://github.com/hadolint/hadolint/releases/download/v$v/hadolint-$os-$a"
      echo "https://github.com/hadolint/hadolint/releases/download/v$v/checksums.sha256" ;;
    lychee)
      case $arch in amd64) a=x86_64 ;; arm64) a=aarch64 ;; esac
      echo "lychee-$v-$a-unknown-linux-gnu.tar.gz"
      echo "https://github.com/lycheeverse/lychee/releases/download/lychee-v$v/lychee-$a-unknown-linux-gnu.tar.gz"
      echo "https://github.com/lycheeverse/lychee/releases/download/lychee-v$v/lychee-$a-unknown-linux-gnu.tar.gz.sha256" ;;
    bash-macos)
      # MACOS_BASH_VERSION 5.3.20 is bash-5.3.tar.gz plus patches bash53-001
      # to bash53-020: "5.3" names the tarball, "5.3.N" patch N.
      case $v in
        *.*.*)
          local base=${v%.*} n=${v##*.} p
          p=bash$(printf '%s' "$base" | tr -d .)-$(printf '%03d' "$n")
          echo "$p"
          echo "https://mirrors.kernel.org/gnu/bash/bash-$base-patches/$p https://ftp.gnu.org/gnu/bash/bash-$base-patches/$p" ;;
        *)
          echo "bash-$v.tar.gz"
          echo "https://mirrors.kernel.org/gnu/bash/bash-$v.tar.gz https://ftp.gnu.org/gnu/bash/bash-$v.tar.gz" ;;
      esac
      echo - ;;
    libevent)
      echo "libevent-$v-stable.tar.gz"
      echo "https://github.com/libevent/libevent/releases/download/release-$v-stable/libevent-$v-stable.tar.gz"
      echo - ;;
    utf8proc)
      echo "utf8proc-$v.tar.gz"
      echo "https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v$v.tar.gz"
      echo - ;;
    jemalloc)
      echo "jemalloc-$v.tar.bz2"
      echo "https://github.com/jemalloc/jemalloc/releases/download/$v/jemalloc-$v.tar.bz2"
      echo - ;;
    zoxide)
      case $arch in amd64) a=x86_64 ;; arm64) a=aarch64 ;; esac
      echo "zoxide-$v-$a-unknown-linux-musl.tar.gz"
      echo "https://github.com/ajeetdsouza/zoxide/releases/download/v$v/zoxide-$v-$a-unknown-linux-musl.tar.gz"
      echo - ;;
    rustup)
      case $arch in amd64) a=x86_64 ;; arm64) a=aarch64 ;; esac
      echo "rustup-init-$v-$a-unknown-linux-gnu"
      echo "https://static.rust-lang.org/rustup/archive/$v/$a-unknown-linux-gnu/rustup-init"
      echo "https://static.rust-lang.org/rustup/archive/$v/$a-unknown-linux-gnu/rustup-init.sha256" ;;
    *) die "no artifact recipe for $comp" ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1"
  else shasum -a 256 < "$1"; fi | awk '{ print $1 }'
}

# download FILE URL...: the first URL that answers.
download() {
  local out=$1 url; shift
  for url in "$@"; do
    curl -fsSL --retry 3 --connect-timeout 30 -o "$out" "$url" && return 0
    echo "${0##*/}: could not fetch $url" >&2
  done
  return 1
}

# fetch COMPONENT VERSION DIR [OS ARCH]: downloads the artifact into DIR and
# prints its path, but only once its sha256 matches dev/checksums/.  A version
# with no recorded checksum is refused before anything is downloaded.
fetch() {
  local comp=$1 v=$2 dir=$3 os=${4:-} arch=${5:-} spec name urls want got
  spec=$(artifact "$comp" "$v" "$os" "$arch")
  name=$(printf '%s\n' "$spec" | sed -n 1p)
  urls=$(printf '%s\n' "$spec" | sed -n 2p)
  want=$(awk -v n="$name" '$2 == n { print $1 }' "$IMUX_DEV/checksums/$comp.sha256" 2>/dev/null)
  [ -n "$want" ] || die "$name has no sha256 in dev/checksums/$comp.sha256 -- after changing dev/versions.env, run 'make pin' (dev/pin.sh)"
  # shellcheck disable=SC2086  # $urls is a space-separated list of URLs
  download "$dir/$name" $urls || die "could not download $name"
  got=$(sha256_of "$dir/$name")
  [ "$got" = "$want" ] || die "$name: sha256 is $got, dev/checksums/$comp.sha256 says $want"
  printf '%s\n' "$dir/$name"
}

# A scratch directory that goes when the installer exits.
scratch() {
  IMUX_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/imux-install.XXXXXX") || die "mktemp failed"
  trap 'rm -rf "$IMUX_SCRATCH"' EXIT
}

ncpu() { getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2; }
