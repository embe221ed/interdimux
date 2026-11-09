#!/usr/bin/env bash
# Tiny real Cargo crates verify both native and tmux artifact publication.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/test_cargo_artifacts.py"
