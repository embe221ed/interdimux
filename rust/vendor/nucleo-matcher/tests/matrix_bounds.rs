use nucleo_matcher::{Matcher, Utf32Str};

fn check_short_needle(fill: &str, lengths: &[usize]) {
    let mut matcher = Matcher::default();
    let mut haystack_buf = Vec::new();
    for &gap in lengths {
        // Miri checks allocation/fallback boundaries directly in matrix's
        // typed-view test. Keep public matching bounded under the interpreter.
        if cfg!(miri) && gap > 1000 {
            continue;
        }
        let text = format!("a{}b", fill.repeat(gap));
        let haystack = Utf32Str::new(&text, &mut haystack_buf);
        let needle = Utf32Str::Ascii(b"ab");
        let score = matcher.fuzzy_match(haystack, needle);
        let mut indices = Vec::new();
        assert!(score.is_some(), "gap={gap}, fill={fill:?}");
        assert_eq!(matcher.fuzzy_indices(haystack, needle, &mut indices), score);
        assert_eq!(indices, [0, gap as u32 + 1]);
    }
}

// Run with `cargo +nightly miri test --test matrix_bounds`: the 500-character
// cases created an out-of-allocation matrix reference before the extent fix.
#[test]
fn short_needles_in_long_ascii_haystacks() {
    check_short_needle("x", &[100, 500, 1000, 2048, 11091, 11092, 51198, 51199]);
}

#[test]
fn short_needles_in_long_unicode_haystacks() {
    check_short_needle("界", &[100, 500, 1000, 2048, 8872, 8873, 51198, 51199]);
}
