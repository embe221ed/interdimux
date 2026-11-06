# Local matcher patch

This is the published `nucleo-matcher` 0.3.1 crate from
<https://crates.io/crates/nucleo-matcher/0.3.1>, maintained upstream at
<https://github.com/helix-editor/nucleo>. The upstream MPL-2.0 license is
preserved in `LICENSE`. Only `src/exact.rs` differs from the published source.
The published crate records upstream commit
`355938f0eeeeec040c02b93b8105aa508e6922b5`, subdirectory `matcher`.

The Unicode substring matcher omitted the last legal starting position by
iterating `haystack[start..end]`, where `end = haystack.len() - needle.len()`.
Interdimux changes that range to `start..=end`. Without this correction,
`'4999` and `'開発/4999` fail to match `/workspace/開発/4999`.

The optional `macos-picker` feature reaches this crate through pinned
`nucleo` 0.5.0. The ordinary core build does not compile it. Direct matcher
regressions are in `src/mac_picker.rs` in the parent Rust package; the process
integration test also exercises an exact Unicode path suffix after switching
search fields. No padding or modification of searchable text is used.
