//! 5×7 bitmap glyph table for the debug overlay.
//!
//! Each glyph is a `[u8; 7]` row array. Bit 4 (`0b10000`) is the leftmost
//! pixel; bit 0 (`0b00001`) is the rightmost. Bits 5–7 are unused. Pixel
//! iteration is `(byte >> (4 - x)) & 1 == 1` for `x` in `0..5`.
//!
//! Unknown characters fall back to a hollow rectangle placeholder so missing
//! glyphs stay visually obvious without crashing.

/// Width of each glyph in pixels.
pub const GLYPH_WIDTH: usize = 5;

/// Height of each glyph in pixels.
pub const GLYPH_HEIGHT: usize = 7;

const MISSING: [u8; 7] = [
    0b00000, 0b01110, 0b01010, 0b01010, 0b01010, 0b01110, 0b00000,
];

/// Look up the 5×7 bitmap for `c`. Unknown chars return the MISSING placeholder.
pub fn glyph_for(c: char) -> &'static [u8; 7] {
    let code = c as u32;
    if code < 128 {
        &FONT[code as usize]
    } else {
        &MISSING
    }
}

// The 5×7 glyph table. Initialized in a const block so unmapped ASCII slots
// inherit MISSING rather than blank bitmaps. Rust 1.83+ allows mutating a
// local array inside a `static` initializer.
#[rustfmt::skip]
static FONT: [[u8; 7]; 128] = {
    let mut t = [MISSING; 128];

    t[b'0' as usize] = [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110];
    t[b'1' as usize] = [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110];
    t[b'2' as usize] = [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111];
    t[b'3' as usize] = [0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110];
    t[b'4' as usize] = [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010];
    t[b'5' as usize] = [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110];
    t[b'6' as usize] = [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110];
    t[b'7' as usize] = [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000];
    t[b'8' as usize] = [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110];
    t[b'9' as usize] = [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100];

    t[b'A' as usize] = [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001];
    t[b'B' as usize] = [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110];
    t[b'C' as usize] = [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110];
    t[b'D' as usize] = [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110];
    t[b'E' as usize] = [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111];
    t[b'F' as usize] = [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000];
    t[b'G' as usize] = [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110];
    t[b'H' as usize] = [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001];
    t[b'I' as usize] = [0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110];
    t[b'J' as usize] = [0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100];
    t[b'K' as usize] = [0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001];
    t[b'L' as usize] = [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111];
    t[b'M' as usize] = [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001];
    t[b'N' as usize] = [0b10001, 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001];
    t[b'O' as usize] = [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110];
    t[b'P' as usize] = [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000];
    t[b'Q' as usize] = [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101];
    t[b'R' as usize] = [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001];
    t[b'S' as usize] = [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110];
    t[b'T' as usize] = [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100];
    t[b'U' as usize] = [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110];
    t[b'V' as usize] = [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100];
    t[b'W' as usize] = [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010];
    t[b'X' as usize] = [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001];
    t[b'Y' as usize] = [0b10001, 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100];
    t[b'Z' as usize] = [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111];

    t[b'a' as usize] = [0b00000, 0b00000, 0b01110, 0b00001, 0b01111, 0b10001, 0b01111];
    t[b'b' as usize] = [0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b11110];
    t[b'c' as usize] = [0b00000, 0b00000, 0b01110, 0b10001, 0b10000, 0b10001, 0b01110];
    t[b'd' as usize] = [0b00001, 0b00001, 0b01101, 0b10011, 0b10001, 0b10001, 0b01111];
    t[b'e' as usize] = [0b00000, 0b00000, 0b01110, 0b10001, 0b11111, 0b10000, 0b01110];
    t[b'f' as usize] = [0b00110, 0b01001, 0b01000, 0b11110, 0b01000, 0b01000, 0b01000];
    t[b'g' as usize] = [0b00000, 0b00000, 0b01111, 0b10001, 0b01111, 0b00001, 0b01110];
    t[b'h' as usize] = [0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001];
    t[b'i' as usize] = [0b00100, 0b00000, 0b01100, 0b00100, 0b00100, 0b00100, 0b01110];
    t[b'j' as usize] = [0b00010, 0b00000, 0b00110, 0b00010, 0b00010, 0b10010, 0b01100];
    t[b'k' as usize] = [0b10000, 0b10000, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010];
    t[b'l' as usize] = [0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110];
    t[b'm' as usize] = [0b00000, 0b00000, 0b11010, 0b10101, 0b10101, 0b10001, 0b10001];
    t[b'n' as usize] = [0b00000, 0b00000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001];
    t[b'o' as usize] = [0b00000, 0b00000, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110];
    t[b'p' as usize] = [0b00000, 0b00000, 0b11110, 0b10001, 0b11110, 0b10000, 0b10000];
    t[b'q' as usize] = [0b00000, 0b00000, 0b01111, 0b10001, 0b01111, 0b00001, 0b00001];
    t[b'r' as usize] = [0b00000, 0b00000, 0b10110, 0b11001, 0b10000, 0b10000, 0b10000];
    t[b's' as usize] = [0b00000, 0b00000, 0b01111, 0b10000, 0b01110, 0b00001, 0b11110];
    t[b't' as usize] = [0b01000, 0b01000, 0b11110, 0b01000, 0b01000, 0b01001, 0b00110];
    t[b'u' as usize] = [0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b10011, 0b01101];
    t[b'v' as usize] = [0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100];
    t[b'w' as usize] = [0b00000, 0b00000, 0b10001, 0b10001, 0b10101, 0b10101, 0b01010];
    t[b'x' as usize] = [0b00000, 0b00000, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001];
    t[b'y' as usize] = [0b00000, 0b00000, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110];
    t[b'z' as usize] = [0b00000, 0b00000, 0b11111, 0b00010, 0b00100, 0b01000, 0b11111];

    t[b' ' as usize] = [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000];
    t[b':' as usize] = [0b00000, 0b00000, 0b00100, 0b00000, 0b00000, 0b00100, 0b00000];
    t[b'.' as usize] = [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00110, 0b00110];
    t[b'%' as usize] = [0b11001, 0b11001, 0b00010, 0b00100, 0b01000, 0b10011, 0b10011];
    t[b'+' as usize] = [0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000];
    t[b'-' as usize] = [0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000];
    t[b'/' as usize] = [0b00001, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b10000];

    // DEL (0x7F) is repurposed as a 5×7 solid block. The debug overlay reuses
    // the glyph pipeline to draw background rectangles by emitting a code-127
    // instance scaled to the rect's dimensions — no shader branching needed.
    t[127] = [0b11111; 7];

    t
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_char_returns_missing_placeholder() {
        // Non-ASCII char takes the `code >= 128` fallback branch.
        assert_eq!(glyph_for('☃'), &MISSING);
        // ASCII slot with no glyph data inherits MISSING from the const-init default.
        assert_eq!(glyph_for('\u{0}'), &MISSING);
        assert_eq!(glyph_for('@'), &MISSING);
    }

    #[test]
    fn digit_zero_has_expected_top_and_bottom_rows() {
        // Visual: top row `.###.` and bottom row `.###.` should both encode to 0b01110.
        let g = glyph_for('0');
        assert_eq!(g[0], 0b01110, "top row of '0' should be .###.");
        assert_eq!(g[6], 0b01110, "bottom row of '0' should be .###.");
    }

    #[test]
    fn all_overlay_format_chars_are_mapped() {
        // Every char used in the two Swift-reference overlay format strings,
        // plus the hex digits a-f that can appear in a git short hash.
        let needed = "FPS:CPUbuild0123456789abcdef. %";
        for c in needed.chars() {
            assert_ne!(
                glyph_for(c),
                &MISSING,
                "char {c:?} is unexpectedly mapped to MISSING"
            );
        }
    }

    #[test]
    fn del_code_is_solid_block_for_bg_rect_reuse() {
        // Regression here makes BG rects silently vanish (no crash).
        let g = glyph_for('\u{7F}');
        for (row_idx, row) in g.iter().enumerate() {
            assert_eq!(
                *row, 0b11111,
                "DEL row {row_idx} expected solid 0b11111, got {row:#07b}"
            );
        }
    }
}
