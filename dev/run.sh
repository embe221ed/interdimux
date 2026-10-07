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
#   clean          remove the dev images (both architectures) and this
#                  checkout's work volumes
#   clean-volumes  remove the work volumes of checkouts that are gone
#   anything else  dev/cmd.sh COMMAND: test, ci, ci-sigpipe, versions, lint,
#                  check-macos, msrv, bench, watch, shell, run
#
# The container sees the checkout READ-ONLY at /src and works on a copy in a
# volume of its own (interdimux-dev-work-<arch>-<dir name>-<hash of the
# checkout's path>, one per checkout and architecture, so two worktrees never
# share one), so no run can write into the checkout -- or rebuild the
# rust/target/release/imux a live plugin runs from it.  It mounts nothing else
# of the host -- no /tmp, no tmux socket, no home, so a bare `tmux` inside can
# only reach the container's own servers -- except, for a git worktree, its
# repository's git dir, read-only (below).
#
# Environment:
#   IMUX_PLATFORM  linux/amd64 or linux/arm64; default the docker host's own.
#                  (amd64 is this VPS's, CI's and an Intel Mac's; arm64 an
#                  Apple Silicon Mac's.  The other one runs emulated, slowly.)
#   IMUX_RENDERER  rust or bash: the one CI leg to run, or test's renderer
#   IMUX_CPUSET    pin the container to these CPUs (docker --cpuset-cpus).
#                  There is deliberately no --cpus: CFS throttling stalls the
#                  tmux server mid-format and trips its 100 ms budget.
#   IMUX_LOCK      a file: the run (and an image build before it) holds an
#                  exclusive flock(1) on it throughout, so runs that name the
#                  same file -- from several checkouts at once -- take turns
#                  instead of overlapping.  For timing-sensitive runs
#                  (benchmarks, the suites).  Where there is no flock
#                  (macOS), the run goes ahead unlocked and says so.

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
# This checkout's work volume: its directory's name, for `docker volume ls`,
# and a hash of its path, so two checkouts never share one.  Labelled with the
# path, which clean-volumes reads.
ckey=$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1)
cname=$(printf '%s' "${ROOT##*/}" | LC_ALL=C tr -c 'A-Za-z0-9_.-' '_' | cut -c1-40)
volume_of() { printf 'interdimux-dev-work-%s-%s-%s' "$1" "$cname" "$ckey"; }
VOLUME=$(volume_of "$arch")
# Always named, even for the docker host's own arch, so that a
# DOCKER_DEFAULT_PLATFORM in the environment (common on Apple Silicon) cannot
# build or run the image under emulation behind a tag that says otherwise.
plat=--platform=linux/$arch

work_volumes() {  # every checkout's, and the old per-architecture ones
  docker volume ls -q --filter name=interdimux-dev-work- | grep '^interdimux-dev-work-' || true
}
case $1 in
  clean)
    for a in amd64 arm64; do
      if docker image rm "interdimux-dev:$a" >/dev/null 2>&1; then echo "removed image interdimux-dev:$a"; fi
      v=$(volume_of "$a")
      if docker volume rm "$v" >/dev/null 2>&1; then echo "removed volume $v (this checkout's work volume)"; fi
    done
    n=$(work_volumes | grep -cvx -e "$(volume_of amd64)" -e "$(volume_of arm64)" || true)
    [ "$n" = 0 ] || echo "$n work volume(s) of other checkouts are left: dev/run.sh clean-volumes removes those whose checkout is gone"
    exit 0 ;;
  clean-volumes)
    # Stale: the checkout its label names is gone.  One without a label was
    # made by a dev/run.sh from before volumes were per checkout, which a
    # checkout not yet updated still uses: named, not removed.  docker refuses
    # to remove a volume a run is using.
    for v in $(work_volumes); do
      co=$(docker volume inspect -f '{{ index .Labels "imux.checkout" }}' "$v" 2>/dev/null || true)
      [ "$co" != '<no value>' ] || co=""
      if [ -z "$co" ]; then
        echo "kept    $v (no checkout recorded: an older dev/run.sh's; docker volume rm $v)"
      elif [ -f "$co/dev/run.sh" ]; then
        echo "kept    $v ($co)"
      elif docker volume rm "$v" >/dev/null 2>&1; then
        echo "removed $v ($co is gone)"
      else
        echo "kept    $v (a run is using it)"
      fi
    done
    exit 0 ;;
esac

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

# IMUX_LOCK: fd 9 holds the lock, and `exec docker run` below inherits it, so it
# is released when the run ends, however it ends.
if [ -n "${IMUX_LOCK:-}" ]; then
  if command -v flock >/dev/null 2>&1; then
    exec 9>>"$IMUX_LOCK"
    if ! flock -n 9; then
      echo "dev/run.sh: waiting for the lock $IMUX_LOCK, held by: $(cat "$IMUX_LOCK.holder" 2>/dev/null || echo '?')" >&2
      t0=$(date +%s)
      flock 9 || die "cannot lock $IMUX_LOCK"
      echo "dev/run.sh: got the lock after $(( $(date +%s) - t0 )) s" >&2
    fi
    printf '%s: %s (pid %s, since %s)\n' "$ROOT" "$*" "$$" "$(date '+%Y-%m-%d %H:%M:%S')" > "$IMUX_LOCK.holder" 2>/dev/null || true
  else
    echo "dev/run.sh: IMUX_LOCK is set but there is no flock(1) here: running without the lock" >&2
  fi
fi

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

# One run at a time per checkout and architecture: every run re-copies the
# checkout into its volume, and rebuilds rust/target there, under the feet of
# any other.  (Other checkouts have volumes of their own.)
busy=$(docker ps -q --filter "volume=$VOLUME")
[ -z "$busy" ] || die "another run is using $VOLUME (container $busy): wait for it, or stop it with: docker stop $busy"
docker volume inspect "$VOLUME" >/dev/null 2>&1 \
  || docker volume create --label "imux.checkout=$ROOT" "$VOLUME" >/dev/null \
  || die "cannot create the volume $VOLUME"

# A git worktree's .git is a file that names its git dir, inside the main
# repository's .git (the common dir), outside this checkout.  Mounted
# read-only at the same path, git works inside -- on /work, whose .git is the
# same file.  (A plain checkout's .git is a directory, copied into /work with
# the rest.)
gitmnt="" gitmnt2=""
if [ -f "$ROOT/.git" ]; then
  gd=$(sed -n 's/^gitdir: //p' "$ROOT/.git")
  case $gd in
    /*)
      common=$gd
      if [ -f "$gd/commondir" ]; then
        c=$(cat "$gd/commondir")
        case $c in /*) common=$c ;; *) common=$gd/$c ;; esac
      fi
      common=$(CDPATH='' cd -- "$common" 2>/dev/null && pwd) || common=""
      case $common$gd in
        *:*|*,*) echo "dev/run.sh: a ':' or ',' in $gd: its git dir is not mounted, git does not work inside" >&2 ;;
        *)
          if [ -n "$common" ]; then
            gitmnt="--volume=$common:$common:ro"
            case $gd/ in "$common"/*) ;; *) gitmnt2="--volume=$gd:$gd:ro" ;; esac
          fi ;;
      esac ;;
    *) echo "dev/run.sh: this worktree's .git names its git dir by a relative path: it is not mounted, git does not work inside" >&2 ;;
  esac
fi

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
  -v "$ROOT:/src:ro" -v "$VOLUME:/work" ${gitmnt:+"$gitmnt"} ${gitmnt2:+"$gitmnt2"} \
  "$IMAGE" "$@"
