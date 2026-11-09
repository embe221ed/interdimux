use std::alloc::{alloc_zeroed, dealloc, handle_alloc_error, Layout};
use std::marker::PhantomData;
use std::mem::size_of;
use std::panic::{RefUnwindSafe, UnwindSafe};
use std::ptr::{slice_from_raw_parts_mut, NonNull};

use crate::chars::Char;

const MAX_MATRIX_SIZE: usize = 100 * 1024; // 100*1024 = 100KB

// these two aren't hard maxima, instead we simply allow whatever will fit into memory
const MAX_HAYSTACK_LEN: usize = 2048; // 64KB
const MAX_NEEDLE_LEN: usize = 2048; // 64KB

struct MatrixLayout<C: Char> {
    haystack_len: usize,
    needle_len: usize,
    row_len: usize,
    matrix_len: usize,
    layout: Layout,
    haystack_off: usize,
    bonus_off: usize,
    rows_off: usize,
    score_off: usize,
    matrix_off: usize,
    _phantom: PhantomData<C>,
}
impl<C: Char> MatrixLayout<C> {
    fn new(haystack_len: usize, needle_len: usize) -> MatrixLayout<C> {
        assert!(haystack_len >= needle_len);
        assert!(haystack_len <= u32::MAX as usize);
        let mut layout = Layout::from_size_align(0, 1).unwrap();
        let haystack_layout = Layout::array::<C>(haystack_len).unwrap();
        let bonus_layout = Layout::array::<u8>(haystack_len).unwrap();
        let rows_layout = Layout::array::<u16>(needle_len).unwrap();
        let row_len = haystack_len + 1 - needle_len;
        let matrix_len = row_len * needle_len;
        let score_layout = Layout::array::<ScoreCell>(row_len).unwrap();
        let matrix_layout = Layout::array::<MatrixCell>(matrix_len).unwrap();

        let haystack_off;
        (layout, haystack_off) = layout.extend(haystack_layout).unwrap();
        let bonus_off;
        (layout, bonus_off) = layout.extend(bonus_layout).unwrap();
        let rows_off;
        (layout, rows_off) = layout.extend(rows_layout).unwrap();
        let score_off;
        (layout, score_off) = layout.extend(score_layout).unwrap();
        let matrix_off;
        (layout, matrix_off) = layout.extend(matrix_layout).unwrap();
        MatrixLayout {
            haystack_len,
            needle_len,
            row_len,
            matrix_len,
            layout,
            haystack_off,
            bonus_off,
            rows_off,
            score_off,
            matrix_off,
            _phantom: PhantomData,
        }
    }
    /// # Safety
    ///
    /// `ptr` must point to an allocation with at least `self.layout`'s size
    /// and alignment.
    #[allow(clippy::type_complexity)]
    unsafe fn fieds_from_ptr(
        &self,
        ptr: NonNull<u8>,
    ) -> (
        *mut [C],
        *mut [u8],
        *mut [u16],
        *mut [ScoreCell],
        *mut [MatrixCell],
    ) {
        let base = ptr.as_ptr();
        let haystack = base.add(self.haystack_off) as *mut C;
        let haystack = slice_from_raw_parts_mut(haystack, self.haystack_len);
        let bonus = base.add(self.bonus_off);
        let bonus = slice_from_raw_parts_mut(bonus, self.haystack_len);
        let rows = base.add(self.rows_off) as *mut u16;
        let rows = slice_from_raw_parts_mut(rows, self.needle_len);
        let cells = base.add(self.score_off) as *mut ScoreCell;
        let cells = slice_from_raw_parts_mut(cells, self.row_len);
        let matrix = base.add(self.matrix_off) as *mut MatrixCell;
        let matrix = slice_from_raw_parts_mut(matrix, self.matrix_len);
        (haystack, bonus, rows, cells, matrix)
    }
}

const _SIZE_CHECK: () = {
    if size_of::<ScoreCell>() != 8 {
        panic!()
    }
};

// make this act like a u64
#[repr(align(8))]
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) struct ScoreCell {
    pub score: u16,
    pub consecutive_bonus: u8,
    pub matched: bool,
}

pub(crate) struct MatcherDataView<'a, C: Char> {
    pub haystack: &'a mut [C],
    // stored as a separate array instead of struct
    // to avoid padding since char is too large and u8 too small :/
    pub bonus: &'a mut [u8],
    pub current_row: &'a mut [ScoreCell],
    pub row_offs: &'a mut [u16],
    pub matrix_cells: &'a mut [MatrixCell],
}
#[repr(transparent)]
pub struct MatrixCell(pub(crate) u8);

impl MatrixCell {
    pub fn set(&mut self, p_match: bool, m_match: bool) {
        self.0 = p_match as u8 | ((m_match as u8) << 1);
    }

    pub fn get(&self, m_matrix: bool) -> bool {
        let mask = m_matrix as u8 + 1;
        (self.0 & mask) != 0
    }
}

// we only use this to construct the layout for the slab allocation
#[allow(unused)]
struct MatcherData {
    haystack: [char; MAX_HAYSTACK_LEN],
    bonus: [u8; MAX_HAYSTACK_LEN],
    row_offs: [u16; MAX_NEEDLE_LEN],
    scratch_space: [ScoreCell; MAX_HAYSTACK_LEN],
    matrix: [u8; MAX_MATRIX_SIZE],
}

pub(crate) struct MatrixSlab(NonNull<u8>);
unsafe impl Sync for MatrixSlab {}
unsafe impl Send for MatrixSlab {}
impl UnwindSafe for MatrixSlab {}
impl RefUnwindSafe for MatrixSlab {}

impl MatrixSlab {
    pub fn new() -> Self {
        let layout = Layout::new::<MatcherData>();
        // safety: the matrix is never zero sized (hardcoded constants)
        let ptr = unsafe { alloc_zeroed(layout) };
        let Some(ptr) = NonNull::new(ptr) else {
            handle_alloc_error(layout)
        };
        MatrixSlab(ptr.cast())
    }

    pub(crate) fn alloc<C: Char>(
        &mut self,
        haystack_: &[C],
        needle_len: usize,
    ) -> Option<MatcherDataView<'_, C>> {
        let cells = haystack_.len() * needle_len;
        if cells > MAX_MATRIX_SIZE
            || haystack_.len() > u16::MAX as usize
            // ensures that scores never overflow
            || needle_len > MAX_NEEDLE_LEN
        {
            return None;
        }
        let matrix_layout = MatrixLayout::<C>::new(haystack_.len(), needle_len);
        if matrix_layout.layout.size() > size_of::<MatcherData>() {
            return None;
        }
        unsafe {
            // Safety: the layout size check above ensures that every field
            // fits in the slab, whose alignment is sufficient for all fields.
            let (haystack, bonus, rows, current_row, matrix_cells) =
                matrix_layout.fieds_from_ptr(self.0);
            // copy haystack before creating references to ensure we don't create
            // references to invalid chars (which may or may not be UB)
            haystack_
                .as_ptr()
                .copy_to_nonoverlapping(haystack as *mut _, haystack_.len());
            Some(MatcherDataView {
                haystack: &mut *haystack,
                row_offs: &mut *rows,
                bonus: &mut *bonus,
                current_row: &mut *current_row,
                matrix_cells: &mut *matrix_cells,
            })
        }
    }
}

impl Drop for MatrixSlab {
    fn drop(&mut self) {
        unsafe { dealloc(self.0.as_ptr(), Layout::new::<MatcherData>()) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check_layout<C: Char>(haystack: &[C], needle_len: usize) -> bool {
        let layout = MatrixLayout::<C>::new(haystack.len(), needle_len);
        let expected = haystack.len() * needle_len <= MAX_MATRIX_SIZE
            && layout.layout.size() <= size_of::<MatcherData>();
        let mut slab = MatrixSlab::new();
        let view = slab.alloc(haystack, needle_len);
        assert_eq!(view.is_some(), expected);
        if let Some(view) = view {
            let row_len = haystack.len() + 1 - needle_len;
            assert_eq!(view.haystack.len(), haystack.len());
            assert_eq!(view.bonus.len(), haystack.len());
            assert_eq!(view.row_offs.len(), needle_len);
            assert_eq!(view.current_row.len(), row_len);
            assert_eq!(view.matrix_cells.len(), row_len * needle_len);
        }
        expected
    }

    #[test]
    fn typed_views_fit_at_slab_and_fallback_boundaries() {
        use crate::chars::AsciiChar;

        for needle_len in [2, 32, 128] {
            // Find the last accepted length with a binary search so Miri can
            // exercise the actual references at either side of the boundary.
            let mut low = needle_len;
            let mut high = u16::MAX as usize + 1;
            while low < high {
                let mid = low + (high - low) / 2;
                let layout = MatrixLayout::<char>::new(mid, needle_len);
                if mid * needle_len <= MAX_MATRIX_SIZE
                    && layout.layout.size() <= size_of::<MatcherData>()
                {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }
            for len in [needle_len, 502.max(needle_len), low - 1, low] {
                check_layout(&vec!['界'; len], needle_len);
                check_layout(&vec![AsciiChar(b'x'); len], needle_len);
            }
            assert!(check_layout(&vec!['界'; low - 1], needle_len));
            assert!(!check_layout(&vec!['界'; low], needle_len));
        }
        assert!(!check_layout(&vec!['界'; MAX_NEEDLE_LEN], MAX_NEEDLE_LEN));
    }
}
