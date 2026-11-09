# Local matcher patch

This is the published `nucleo-matcher` 0.3.1 crate from
<https://crates.io/crates/nucleo-matcher/0.3.1>, maintained upstream at
<https://github.com/helix-editor/nucleo>. The upstream MPL-2.0 license is
preserved in `LICENSE`. Local fixes affect `src/exact.rs`, `src/lib.rs`,
`src/pattern.rs`, `src/matrix.rs` and `src/chars/normalize.rs`, with regression
coverage alongside them.
The published crate records upstream commit
`355938f0eeeeec040c02b93b8105aa508e6922b5`, subdirectory `matcher`.

The Unicode substring matcher omitted the last legal starting position by
iterating `haystack[start..end]`, where `end = haystack.len() - needle.len()`.
Interdimux changes that range to `start..=end`. Without this correction,
`'4999` and `'開発/4999` fail to match `/workspace/開発/4999`.

Additional corrections from the November source review:

* M-578: case-insensitive ASCII substring matching prefilters only the leading
  nonletter portion of the needle, then normalizes the remaining suffix.
  Searching the entire needle in the shortened prefilter haystack lost valid
  mixed-case and end-of-string matches such as `'12ab` in `prefix12AB`.
* M-585: Unicode atom parsing removes the already-appended backslash when
  escaping a space and leaves literal backslashes singly appended otherwise.
  It now follows the ASCII parser's escaping rules.
* M-586: case-sensitive ASCII exact matching compares `haystack[start..end]`
  with the needle, honoring prefix/postfix bounds instead of comparing the
  entire haystack.
* M-602: the matrix slab allocation and raw slices use the same row and matrix
  element counts. The prior raw matrix slice used the haystack length where
  the needle length was required, creating a reference beyond its allocation.
  The public `fuzzy_match` reproduction is `ab` against `a` + 500 `x`s + `b`;
  `tests/matrix_bounds.rs` also covers indices and allocation/fallback bounds.
* M-601: each normalization table is initialized with identity values, then
  overlaid with its own sparse mappings. Bounds use the minimum and maximum
  declared keys, since DATA2 has interleaved blocks. The previous generator
  indexed DATA1 for every table, assumed sorted input and cut off DATA2's
  final three declared mappings. Tests verify all 453 declared mappings and
  identity for every unmapped Unicode scalar.

Normalization policy remains the declared single-character Latin mappings.
Smart normalization applies when the query atom itself needs no normalization;
accented query literals keep their existing matching rules. Canonical Unicode
composition/decomposition and multi-character transliteration are separate
policy choices.

The optional `macos-picker` feature reaches this crate through pinned
`nucleo` 0.5.0. The ordinary core build does not compile it. Direct matcher
regressions are in `src/mac_picker.rs` in the parent Rust package and in the
vendored crate's parser and matrix tests. The parent process integration test
exercises Unicode suffixes, literal escaping, ASCII anchors, numeric prefixes
and incremental syntax changes using selected opaque IDs. No padding or
modification of searchable text is used.
