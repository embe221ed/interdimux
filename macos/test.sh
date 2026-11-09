#!/bin/bash
# Offscreen native checks only; live Rex actions and UI benchmarks are opt-in.
set -uo pipefail

macos_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ $(uname -s) != Darwin ]]; then
  echo 'Native picker checks require macOS.' >&2
  exit 1
fi

failed=0
for suite in backend dialogs launcher tree responses preview geometry navigation selection opening rex_theme theme dashboard picker_cell; do
  printf '\nNative picker checks: %s\n' "$suite"
  if ! python3 "$macos_dir/test_$suite.py"; then
    failed=1
  fi
done
exit "$failed"
