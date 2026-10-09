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
#                  check-macos, msrv, bench, perfbench, uxdiff, watch, shell,
#                  run
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
#   IMUX_LOCK      how the run takes turns (below): unset, the default lock
#                  file ${XDG_RUNTIME_DIR:-/tmp}/interdimux-dev-<uid>.lock for
#                  the commands that take turns and for any image build; a
#                  file, that one, and every command takes turns; `none`, no
#                  lock and no waiting.
#
# Taking turns: the suites bound how long a screen may take to settle,
# perfbench compares CPU times, uxdiff waits for screens, and a build or a
# cargo run beside any of them skews it.  So test, smoke, ci, ci-sigpipe,
# bench, perfbench, uxdiff, msrv, check-macos, lint and image -- and every
# image build -- take an exclusive flock(1) on the lock file, then wait while
# a container of any other run that takes turns is up (they carry the label
# imux.turn), from any checkout, and only then start.  The containers are the
# part that holds when the lock cannot: a run whose docker client was killed
# (a tool's timeout sends SIGKILL) leaves its container running with the
# lock released; another lock file; macOS, which has no flock(1).  shell, run,
# watch and versions do not take turns unless IMUX_LOCK names a file; a run
# that takes turns names the other interdimux-dev containers still up.

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
# (dev/perf/ is not in it: the image does not use the harness, which runs from
# /work, so editing it rebuilds nothing.)
src_sum() {
  (cd "$ROOT" && find dev rust/Cargo.toml rust/Cargo.lock .dockerignore -path dev/perf -prune -o -type f -print |
     LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; cat "$f"; done) | cksum | tr ' ' -
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

# Taking turns (the header).  fd 9 holds the lock, and `exec docker run`
# below inherits it, so it is released when the run ends, however it ends.
turn=0
case $1 in
  test|smoke|ci|ci-sigpipe|bench|perfbench|uxdiff|msrv|check-macos|lint|image) turn=1 ;;
esac
lockfile=${IMUX_LOCK:-}
case $lockfile in
  none) lockfile="" ;;
  "") lockfile=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/interdimux-dev-$(id -u).lock ;;
  *) turn=1 ;;
esac
locked=0

describe() {  # container ids -> one line each: id (command, from checkout)
  [ $# -gt 0 ] || return 0
  docker inspect -f '    {{printf "%.12s" .ID}} ({{join .Config.Cmd " "}}, from {{range .Mounts}}{{if eq .Destination "/src"}}{{.Source}}{{end}}{{end}})' "$@" 2>/dev/null || true
}

take_lock() {
  [ -n "$lockfile" ] && [ "$locked" = 0 ] || return 0
  locked=1
  if ! command -v flock >/dev/null 2>&1; then
    echo "dev/run.sh: no flock(1) here: taking turns only by waiting for other runs' containers" >&2
    return 0
  fi
  if ! (: >>"$lockfile") 2>/dev/null; then
    echo "dev/run.sh: cannot open the lock file $lockfile: taking turns only by waiting for other runs' containers" >&2
    return 0
  fi
  exec 9>>"$lockfile"
  if ! flock -n 9; then
    echo "dev/run.sh: waiting for the lock $lockfile, held by: $(cat "$lockfile.holder" 2>/dev/null || echo '?')" >&2
    t0=$(date +%s)
    flock 9 || die "cannot lock $lockfile"
    echo "dev/run.sh: got the lock after $(( $(date +%s) - t0 )) s" >&2
  fi
  printf '%s: %s (pid %s, since %s)\n' "$ROOT" "$*" "$$" "$(date '+%Y-%m-%d %H:%M:%S')" > "$lockfile.holder" 2>/dev/null || true
}

# Wait while another turn's container is up.  (Not with IMUX_LOCK=none.)
wait_turns() {
  [ "${IMUX_LOCK:-}" != none ] || return 0
  t0=""
  while :; do
    ids=$(docker ps -q --filter label=imux.turn) || die "docker ps failed"
    [ -n "$ids" ] || break
    if [ -z "$t0" ]; then
      t0=$(date +%s)
      # shellcheck disable=SC2086  # one id per word
      printf 'dev/run.sh: waiting for the run(s) taking their turn now (docker stop ID ends one at once):\n%s\n' "$(describe $ids)" >&2
    fi
    sleep 2
  done
  [ -z "$t0" ] || echo "dev/run.sh: their turn ended after $(( $(date +%s) - t0 )) s" >&2
}

if [ "$turn" = 1 ]; then
  take_lock "$@"
  wait_turns
fi

[ "$1" = image ] && { build; exit 0; }

have=$(docker image inspect -f '{{ index .Config.Labels "imux.src" }}' "$IMAGE" 2>/dev/null || true)
if [ "$have" != "$sum" ]; then
  # a build takes its turn too, even for a run that does not; such a run lets
  # go of the lock once the image is built
  if [ "$turn" = 0 ]; then take_lock "$@"; wait_turns; fi
  if [ -n "$have" ]; then
    echo "dev/run.sh: dev/ changed since $IMAGE was built: rebuilding (only the stages that changed)" >&2
  else
    echo "dev/run.sh: building $IMAGE (the first build takes about six minutes on 4 cores)" >&2
  fi
  build
  if [ "$turn" = 0 ] && [ "$locked" = 1 ]; then exec 9>&-; fi
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

# A run that takes turns names the dev containers it does not wait for (a
# shell, a watch, `run`, an older dev/run.sh's), and tells the harness, which
# cannot see them from inside, so its report can say so too.
others=""
if [ "$turn" = 1 ]; then
  # shellcheck disable=SC2046  # one id per word
  others=$(describe $( { docker ps -q --filter label=imux.dev
                          docker ps --format '{{.ID}} {{.Image}}' | awk '$2 ~ /^interdimux-dev(:|$)/ { print $1 }'
                        } 2>/dev/null | sort -u))
  [ -z "$others" ] || printf 'dev/run.sh: NOTE: other dev containers are up, and this run does not wait for them (timings may suffer):\n%s\n' "$others" >&2
fi
turnlabel=""
[ "$turn" = 0 ] || turnlabel=--label=imux.turn=1

# shellcheck disable=SC2086  # each of these is one word or none
exec docker run --rm $it $term $net $cpus "$plat" --hostname=imux-dev \
  --label=imux.dev=1 $turnlabel --label="imux.cmd=$1" --label="imux.checkout=$ROOT" \
  --env=IMUX_RENDERER ${others:+"--env=IMUX_DEV_OTHERS=$(printf '%s' "$others" | sed 's/^ *//' | tr '\n' ';')"} \
  -v "$ROOT:/src:ro" -v "$VOLUME:/work" ${gitmnt:+"$gitmnt"} ${gitmnt2:+"$gitmnt2"} \
  "$IMAGE" "$@"
