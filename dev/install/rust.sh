#!/usr/bin/env bash
#
#   dev/install/rust.sh MANIFEST
#
# The dev image's Rust: rustup at RUSTUP_INIT_VERSION, into $RUSTUP_HOME and
# $CARGO_HOME (minimal profile), with
#
# * RUST_VERSION as the default toolchain, plus clippy and rustfmt;
# * the MSRV toolchain, read from MANIFEST's rust-version, for `make msrv` --
#   nothing else ever compiles the crate with it;
# * the two macOS std targets, for `make check-macos`: the crate has no build.rs
#   and only std FFI, so `cargo check --target *-apple-darwin` type-checks the
#   macOS process backend (rust/src/macproc.rs) on Linux, where it is not even
#   compiled otherwise;
# * the crates MANIFEST's Cargo.lock names, fetched by both toolchains (cargo
#   names its registry cache by a hash that changed after 1.74, so one fetch
#   does not serve the other), so that builds run with the network off.

set -euo pipefail
# shellcheck source=dev/install/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 1 ] || die "usage: $0 MANIFEST"
manifest=$1
: "${RUSTUP_HOME:?}" "${CARGO_HOME:?}"
rust=$(pinned RUST_VERSION)
msrv=$(sed -n 's/^rust-version *= *"\([^"]*\)".*/\1/p' "$manifest")
[ -n "$msrv" ] || die "no rust-version in $manifest"

scratch
init=$(fetch rustup "$(pinned RUSTUP_INIT_VERSION)" "$IMUX_SCRATCH" linux "$(host_arch)")
chmod +x "$init"
"$init" -y --no-modify-path --profile minimal --default-toolchain "$rust" \
  --component clippy --component rustfmt
PATH="$CARGO_HOME/bin:$PATH"
rustup toolchain install "$msrv" --profile minimal
rustup target add --toolchain "$rust" x86_64-apple-darwin aarch64-apple-darwin

cargo +"$rust" fetch --locked --manifest-path "$manifest"
cargo +"$msrv" fetch --locked --manifest-path "$manifest"

rustc --version
rustc +"$msrv" --version
