#!/bin/sh
#
#   dev/run.sh COMMAND [ARGS...]        (make COMMAND, see `make help`)
#
# The host side of the dev image: builds it when dev/ changed, and runs
# dev/cmd.sh COMMAND in a fresh container.  POSIX sh and nothing but docker, so
# it runs alike on the VPS (dash) and on a Mac (/bin/sh, bash 3.2).
#
#   image          build the image now (other commands build it when dev/ or
#                  rust/Cargo.* changed since it was built)
#   pin            dev/pin.sh: record checksums after editing dev/versions.env
#   clean          remove the dev images and work volumes, both architectures
#   anything else  dev/cmd.sh COMMAND: test, ci, ci-sigpipe, versions, lint,
#                  check-macos, msrv, bench, watch, shell, run
#
# The container sees the checkout READ-ONLY at /src and works on a copy in a
# volume of its own (interdimux-dev-work-<arch>), so no run can write into the
# checkout -- or rebuild the rust/target/release/imux a live plugin runs from
# it.  It mounts nothing else of the host: no /tmp, no tmux socket, no home,
# so a bare `tmux` inside can only reach the container's own servers.
#
# Environment:
#   IMUX_PLATFORM  linux/amd64 or linux/arm64; default the docker host's own.
#                  (amd64 is this VPS's, CI's and an Intel Mac's; arm64 an
#                  Apple Silicon Mac's.  The other one runs emulated, slowly.)
#   IMUX_RENDERER  rust or bash: the one CI leg to run, or test's renderer
#   IMUX_CPUSET    pin the container to these CPUs (docker --cpuset-cpus).
#                  There is deliberately no --cpus: CFS throttling stalls the
#                  tmux server mid-format and trips its 100 ms budget.

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
VERSIONS=$ROOT/dev/versions.env

die() { printf 'dev/run.sh: %s\n' "$*" >&2; exit 1; }

# Each pin is passed to docker as one --build-arg, and the file is appended to
# CI's $GITHUB_ENV as it is: hold it to its format.
bad=$(grep -nvE '^(#.*|[A-Z][A-Z0-9_]*=[A-Za-z0-9._:/@,+-]+|[[:space:]]*)$' "$VERSIONS" || true)
[ -z "$bad" ] || die "dev/versions.env, not KEY=value with a plain value: $bad"

case ${1:-help} in
  pin) shift; exec bash "$ROOT/dev/pin.sh" "$@" ;;
  help|-h|--help) sed -n '/^#   /s/^#   //p' "$0"; exit 0 ;;
esac

command -v docker >/dev/null 2>&1 || die "needs docker"
platform=${IMUX_PLATFORM:-}
if [ -n "$platform" ]; then
  arch=${platform#linux/}
else
  arch=$(docker version --format '{{.Server.Arch}}' 2>/dev/null) || die "docker is not running"
fi
case $arch in
  amd64|arm64) ;;
  *) die "no image for '$arch': IMUX_PLATFORM is linux/amd64 or linux/arm64" ;;
esac
IMAGE=interdimux-dev:$arch
VOLUME=interdimux-dev-work-$arch
# Always named, even for the docker host's own arch, so that a
# DOCKER_DEFAULT_PLATFORM in the environment (common on Apple Silicon) cannot
# build or run the image under emulation behind a tag that says otherwise.
plat=--platform=linux/$arch

if [ "$1" = clean ]; then
  for a in amd64 arm64; do
    if docker image rm "interdimux-dev:$a" >/dev/null 2>&1; then echo "removed image interdimux-dev:$a"; fi
    if docker volume rm "interdimux-dev-work-$a" >/dev/null 2>&1; then echo "removed volume interdimux-dev-work-$a"; fi
  done
  exit 0
fi

# Everything the image is built from (.dockerignore lets in nothing else), as
# one checksum.  The image carries it as a label, so a run whose image is
# current starts without asking the builder -- or the registry, which a build
# would ask about the base image even when every layer is cached.
src_sum() {
  (cd "$ROOT" && find dev rust/Cargo.toml rust/Cargo.lock .dockerignore -type f | LC_ALL=C sort |
     while IFS= read -r f; do printf '%s\n' "$f"; cat "$f"; done) | cksum | tr ' ' -
}
sum=$(src_sum)

build() {
  set --
  # (|| [ -n "$line" ]: a last line with no newline still counts)
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in ''|'#'*) continue ;; esac
    set -- "$@" --build-arg "$line"
  done < "$VERSIONS"
  docker build "$plat" --label "imux.src=$sum" -f "$ROOT/dev/Dockerfile" -t "$IMAGE" "$@" "$ROOT"
}

[ "$1" = image ] && { build; exit 0; }

have=$(docker image inspect -f '{{ index .Config.Labels "imux.src" }}' "$IMAGE" 2>/dev/null || true)
if [ "$have" != "$sum" ]; then
  if [ -n "$have" ]; then
    echo "dev/run.sh: dev/ changed since $IMAGE was built: rebuilding (only the stages that changed)" >&2
  else
    echo "dev/run.sh: building $IMAGE (the first build takes about six minutes on 4 cores)" >&2
  fi
  build
fi

# One run at a time per architecture: every run re-copies the checkout into the
# same volume, and rebuilds rust/target there, under the feet of any other.
busy=$(docker ps -q --filter "volume=$VOLUME")
[ -z "$busy" ] || die "another run is using $VOLUME (container $busy): wait for it, or stop it with: docker stop $busy"

# A terminal only where one is used: the suites run without one, as on CI,
# where `stty size </dev/tty` has nothing to report.  (`watch` is the
# exception: entr needs one, so suites there can see its size.)
it="" term="" net=--network=none
case $1 in
  shell|watch) it=-it term=--env=TERM ;;
esac
case $1 in
  shell|run) net="" ;;   # a shell may want the network; tests never do
esac
cpus=${IMUX_CPUSET:+--cpuset-cpus=$IMUX_CPUSET}

# shellcheck disable=SC2086  # each of these is one word or none
exec docker run --rm $it $term $net $cpus "$plat" --hostname=imux-dev \
  --env=IMUX_RENDERER \
  -v "$ROOT:/src:ro" -v "$VOLUME:/work" \
  "$IMAGE" "$@"
