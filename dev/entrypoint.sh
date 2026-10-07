#!/bin/bash
#
# The dev image's entrypoint (under tini, as PID 1's child).  It runs as root
# for the two things only root can do, then drops to the `dev` user for the
# rest (dev/cmd.sh).

set -euo pipefail

# 1. at's job runner.  A container has no systemd, so it is started here, as
#    systemd starts it on the VPS and `systemctl start atd` on the CI runner.
#    No suite needs a job to fire (they pin INTERDIMUX_AT_DAEMON), but
#    --doctor and the dashboard report whether it runs.
/usr/sbin/atd || echo "entrypoint: atd did not start: at jobs will queue but never run" >&2

# 2. The checkout.  /src is the host's, mounted READ-ONLY.  Everything runs on a
#    copy in /work, a volume of its own per architecture (so rust/target and
#    its build survive from one run to the next).  Nothing a run does can then
#    reach the host's tree -- in particular not its rust/target/release/imux,
#    which on the VPS is the binary the live plugin runs.
if [ ! -f /src/scripts/interdimux.sh ]; then
  echo "entrypoint: no interdimux checkout at /src -- run this image through dev/run.sh (make test, make shell, ...)" >&2
  exit 2
fi
# --no-D: a socket or fifo left in the tree (a dead `tmux -S` socket, say) is
# not copied.  What it does copy under rust/ is then touched: rsync keeps the
# source's mtime, and cargo, seeing a restored file OLDER than the build in
# the volume (an edit undone, a stash, a run that changed /work), would keep
# the stale binary.
rsync -a --no-D --delete --chown=dev:dev --exclude=/rust/target/ --out-format='%n' /src/ /work/ \
  | { grep '^rust/' || true; } | while IFS= read -r f; do [ -f "/work/$f" ] && touch "/work/$f"; done
mkdir -p /work/rust/target
chown dev:dev /work/rust/target

# 3. The rest as `dev`, never as root: as root, test_doctor and
#    test_doctor_agents fail and test_cli_guards skips (a read-only directory
#    is writable to root).  No --reset-env, which would reset PATH too.
export HOME=/home/dev USER=dev LOGNAME=dev SHELL=/bin/bash
exec setpriv --reuid=1000 --regid=1000 --init-groups -- /usr/local/lib/imux-dev/cmd.sh "$@"
