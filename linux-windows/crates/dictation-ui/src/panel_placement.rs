//! Where the panel goes, as the Mac's HUDPlacement puts it: its circle just below and to the
//! right of the mouse pointer. Near the right edge of the screen it flips to the pointer's left,
//! with the bubble on the circle's left; near the bottom it flips above the pointer. It is always
//! kept on the screen.
//!
//! Lengths are the screen's logical pixels, from its top-left corner, y growing downwards.

use crate::{BubbleSide, CIRCLE_SQUARE};

/// Between the panel and the edges of the screen.
const MARGIN: f32 = 10.0;
/// Between the pointer and the circle's square: right of the pointer, or left of it when flipped.
const HORIZONTAL_GAP: f32 = 16.0;
/// Between the pointer and the circle's square: below the pointer, or above it when flipped.
const VERTICAL_GAP: f32 = 18.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PanelPlacement {
    /// The panel's top-left corner.
    pub x: f32,
    pub y: f32,
    pub side: BubbleSide,
}

impl PanelPlacement {
    /// Places a panel of `size` (its shadow's room included) next to `pointer`, on a screen of
    /// `screen`.
    ///
    /// Normally the top-left corner of the circle's square is [`HORIZONTAL_GAP`] right of the
    /// pointer and [`VERTICAL_GAP`] below it. A message on two lines makes the panel taller than
    /// the square, with the circle centred, and the circle, not the panel's edge, is what stays by
    /// the pointer. When the panel would cross the screen's right edge (less the margin) it flips
    /// left, its right edge [`HORIZONTAL_GAP`] left of the pointer, and the bubble goes on the
    /// circle's leading side. When it would cross the bottom it flips up, the circle's square
    /// [`VERTICAL_GAP`] above the pointer. Then it is kept inside the screen, less the margin.
    pub fn beside(pointer: (f32, f32), size: (f32, f32), screen: (f32, f32)) -> Self {
        let ((pointer_x, pointer_y), (width, height), (screen_width, screen_height)) = (pointer, size, screen);
        // How far the circle's square is from the panel's top and bottom edges.
        let inset = (height - CIRCLE_SQUARE).max(0.0) / 2.0;

        let mut side = BubbleSide::Trailing;
        let mut x = pointer_x + HORIZONTAL_GAP;
        if x + width > screen_width - MARGIN {
            side = BubbleSide::Leading;
            x = pointer_x - HORIZONTAL_GAP - width;
        }
        let mut y = pointer_y + VERTICAL_GAP - inset;
        if y + height > screen_height - MARGIN {
            y = pointer_y - VERTICAL_GAP - CIRCLE_SQUARE - inset;
        }
        Self {
            x: clamped(x, MARGIN, screen_width - width - MARGIN),
            y: clamped(y, MARGIN, screen_height - height - MARGIN),
            side,
        }
    }
}

/// `value` kept within `lower` to `upper`; `lower` wins when the range is empty, so a panel wider
/// or taller than the screen keeps its left or top edge on it.
fn clamped(value: f32, lower: f32, upper: f32) -> f32 {
    value.min(upper).max(lower)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCREEN: (f32, f32) = (1_440.0, 900.0);
    const CIRCLE_ONLY: (f32, f32) = (CIRCLE_SQUARE, CIRCLE_SQUARE);
    const WITH_BUBBLE: (f32, f32) = (300.0, CIRCLE_SQUARE);
    /// A message on two lines: the panel is 6 taller than the circle's square.
    const TWO_LINES: (f32, f32) = (300.0, CIRCLE_SQUARE + 6.0);

    fn place(pointer: (f32, f32), size: (f32, f32)) -> PanelPlacement {
        PanelPlacement::beside(pointer, size, SCREEN)
    }

    fn at(x: f32, y: f32, side: BubbleSide) -> PanelPlacement {
        PanelPlacement { x, y, side }
    }

    #[test]
    fn goes_below_and_right_of_the_pointer() {
        assert_eq!(
            place((700.0, 400.0), CIRCLE_ONLY),
            at(716.0, 418.0, BubbleSide::Trailing)
        );
        assert_eq!(
            place((700.0, 400.0), WITH_BUBBLE),
            at(716.0, 418.0, BubbleSide::Trailing)
        );
    }

    #[test]
    fn a_two_line_bubble_leaves_the_circle_where_it_was() {
        let placement = place((700.0, 400.0), TWO_LINES);
        assert_eq!(placement, at(716.0, 415.0, BubbleSide::Trailing));
        assert_eq!(
            placement.y + 3.0,
            400.0 + 18.0,
            "the circle's square starts 18 below the pointer"
        );
    }

    #[test]
    fn flips_left_near_the_right_edge_with_the_bubble_on_the_leading_side() {
        let placement = place((1_200.0, 400.0), WITH_BUBBLE);
        assert_eq!(placement, at(1_200.0 - 16.0 - 300.0, 418.0, BubbleSide::Leading));
    }

    #[test]
    fn flips_left_only_when_the_panel_would_cross_the_margin() {
        // 1,366 + 16 + 48 = 1,430: exactly the margin.
        assert_eq!(place((1_366.0, 400.0), CIRCLE_ONLY).side, BubbleSide::Trailing);
        assert_eq!(
            place((1_367.0, 400.0), CIRCLE_ONLY),
            at(1_367.0 - 64.0, 418.0, BubbleSide::Leading)
        );
    }

    #[test]
    fn a_bubble_can_flip_a_circle_that_fits_on_its_own() {
        let pointer = (1_300.0, 400.0);
        assert_eq!(place(pointer, CIRCLE_ONLY).side, BubbleSide::Trailing);
        assert_eq!(place(pointer, WITH_BUBBLE).side, BubbleSide::Leading);
    }

    #[test]
    fn flips_above_the_pointer_near_the_bottom() {
        let placement = place((700.0, 850.0), CIRCLE_ONLY);
        assert_eq!(placement, at(716.0, 850.0 - 18.0 - 48.0, BubbleSide::Trailing));
    }

    #[test]
    fn flips_above_only_when_the_panel_would_cross_the_margin() {
        // 824 + 18 + 48 = 890: exactly the margin.
        assert_eq!(place((700.0, 824.0), CIRCLE_ONLY).y, 842.0);
        assert_eq!(place((700.0, 825.0), CIRCLE_ONLY).y, 825.0 - 18.0 - 48.0);
    }

    #[test]
    fn a_two_line_bubble_flipped_above_leaves_the_circle_above_the_pointer() {
        let placement = place((700.0, 880.0), TWO_LINES);
        assert_eq!(
            placement.y + 3.0 + CIRCLE_SQUARE,
            880.0 - 18.0,
            "the circle's square ends 18 above the pointer"
        );
    }

    #[test]
    fn flips_left_and_above_in_the_bottom_right_corner() {
        let placement = place((1_400.0, 880.0), WITH_BUBBLE);
        assert_eq!(
            placement,
            at(1_400.0 - 16.0 - 300.0, 880.0 - 18.0 - 48.0, BubbleSide::Leading)
        );
    }

    #[test]
    fn stays_on_the_screen_at_its_top_left_corner() {
        assert_eq!(place((0.0, 0.0), WITH_BUBBLE), at(16.0, 18.0, BubbleSide::Trailing));
        // Flipped left against the left edge: kept inside, the bubble still on the leading side.
        let narrow = PanelPlacement::beside((150.0, 100.0), WITH_BUBBLE, (400.0, 900.0));
        assert_eq!(narrow, at(MARGIN, 118.0, BubbleSide::Leading));
    }

    #[test]
    fn stays_on_a_short_screen_when_flipped_above() {
        let placement = PanelPlacement::beside((100.0, 60.0), CIRCLE_ONLY, (800.0, 100.0));
        assert_eq!(placement.y, MARGIN);
    }

    #[test]
    fn a_panel_wider_than_the_screen_keeps_its_left_edge_on_it() {
        let placement = PanelPlacement::beside((100.0, 100.0), WITH_BUBBLE, (200.0, 900.0));
        assert_eq!(placement.x, MARGIN);
    }
}
