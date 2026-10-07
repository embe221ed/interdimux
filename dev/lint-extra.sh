#!/usr/bin/env bash
#
# The linters for what tests/lint.sh does not cover, at the versions
# dev/versions.env pins (the dev image has them; `make lint` runs this after
# tests/lint.sh):
#
#   actionlint  .github/workflows/ci.yml, with each run: block checked by
#               the pinned shellcheck too
#   hadolint    dev/Dockerfile
#   lychee      every link and #anchor between README.md and docs/, offline

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

rc=0
echo "==> actionlint"
actionlint -no-color || rc=1
echo "==> hadolint"
hadolint dev/Dockerfile || rc=1
echo "==> lychee (offline: local links and anchors only)"
lychee --offline --include-fragments --no-progress README.md rust/README.md docs/*.md || rc=1

[ "$rc" = 0 ] && echo "clean"
exit "$rc"
