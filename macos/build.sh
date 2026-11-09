#!/bin/bash
set -euo pipefail

macos_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$macos_dir/.." && pwd)
if [[ $(uname -s) != Darwin ]]; then
  echo 'The native picker requires macOS 13 or later.' >&2
  exit 1
fi
for tool in cargo xcrun; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing $tool; install Rust and the Xcode Command Line Tools before building." >&2
    exit 1
  fi
done

build="$macos_dir/build"
app="$build/Interdimux Picker.app"
mkdir -p "$build"
stage=$(mktemp -d "$build/.bundle.XXXXXX")
cleanup() {
  if [[ -d "$stage/previous.app" && ! -e "$app" ]]; then
    mv "$stage/previous.app" "$app"
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
bundle="$stage/Interdimux Picker.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Helpers" "$bundle/Contents/Resources"

# An explicit host target overrides both environment and Cargo config targets.
# With --target Cargo writes under target/<host>, never target/release.
host=$(cargo --version --verbose | sed -n 's/^host: //p')
case "$host" in
  ''|*[!a-zA-Z0-9_-]*) echo "Cannot determine Cargo's host target." >&2; exit 1 ;;
esac
cargo build --release --locked --features macos-picker --target "$host" \
  --manifest-path "$root/rust/Cargo.toml" --target-dir "$root/rust/target"
helper="$root/rust/target/$host/release/imux"
[ -x "$helper" ] || { echo 'Cargo did not produce the host helper.' >&2; exit 1; }
# Preserve the ordinary frontend's canonical path too. Copy to a sibling first
# so an existing helper is replaced only after the new copy is complete.
mkdir -p "$root/rust/target/release"
published=$(mktemp "$root/rust/target/release/.imux.XXXXXX")
if ! cp -p "$helper" "$published" || ! mv -f "$published" "$root/rust/target/release/imux"; then
  rm -f "$published"
  exit 1
fi
MACOSX_DEPLOYMENT_TARGET=13.0 xcrun swiftc -O \
  -target "$(uname -m)-apple-macosx13.0" \
  "$macos_dir"/Sources/*.swift -framework AppKit \
  -o "$bundle/Contents/MacOS/InterdimuxPicker"
cp "$helper" "$bundle/Contents/Helpers/imux"
cp "$macos_dir/Info.plist" "$bundle/Contents/Info.plist"
plutil -lint "$bundle/Contents/Info.plist" >/dev/null
touch "$bundle/Contents/Resources/build-stamp"

# Only replace the generated bundle after both compilers have succeeded.
if [[ -e "$app" ]]; then mv "$app" "$stage/previous.app"; fi
mv "$bundle" "$app"
printf 'Built %s\n' "$app"
