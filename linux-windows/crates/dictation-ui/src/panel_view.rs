//! Draws the panel as the Mac's DictationHUDView lays it out: a circle holding the microphone's
//! level, a spinning ring or a glyph, and beside it, when there is a message, a bubble with the
//! message on up to two lines. It has no words of its own and no buttons: Esc and the tray's menu
//! cancel.
//!
//! Lengths are in logical pixels, as the Mac's points: the platform gives the scale, and the
//! pixmap has that many pixels per logical pixel. A transparent margin round what is drawn holds
//! its shadow.

use std::f32::consts::{FRAC_PI_2, TAU};

use tiny_skia::{Color, FillRule, LineCap, Paint, Path, PathBuilder, Pixmap, Rect, Stroke, Transform};

use crate::text::Typeface;
use crate::theme::Palette;
use crate::{Indicator, PanelContent, Theme};

/// The circle's diameter.
const CIRCLE: f32 = 40.0;
/// Round what is drawn, for its shadow.
const SHADOW: f32 = 4.0;
/// The circle with the shadow's room on both sides: the square [`crate::PanelPlacement`] keeps by
/// the pointer, and the whole panel while there is no bubble.
pub const CIRCLE_SQUARE: f32 = CIRCLE + 2.0 * SHADOW;
/// The ring a hands-free recording adds, just inside the circle's edge.
const RING_RADIUS: f32 = 17.5;
const RING_WIDTH: f32 = 1.5;
/// The glyph for a message between dictations.
const GLYPH: f32 = 22.0;
/// Between the circle and the bubble.
const BUBBLE_GAP: f32 = 8.0;
const BUBBLE_PADDING_X: f32 = 12.0;
const BUBBLE_PADDING_Y: f32 = 8.0;
const BUBBLE_CORNER_RADIUS: f32 = 12.0;
/// The Mac's callout text.
const MESSAGE_EM: f32 = 12.0;
/// Widest a message gets before it wraps onto a second line.
const MESSAGE_MAX_WIDTH: f32 = 260.0;
/// The level at which the disc starts to grow, and the one at which it is full size: the first
/// and last thresholds of the five-bar meter it replaced, so it moves with normal speech.
const QUIET: f32 = 0.005;
const LOUD: f32 = 0.12;
/// The disc's radius in silence, and how much it grows from silence to [`LOUD`].
const DISC_MIN_RADIUS: f32 = 6.0;
const DISC_GROWTH: f32 = 10.0;
/// The spinner: an arc of three quarters of a ring, turning once a second.
const SPINNER_RADIUS: f32 = 8.0;
const SPINNER_WIDTH: f32 = 2.0;
const SPINNER_SWEEP: f32 = 0.75 * TAU;

/// What moves: the microphone's level, and how far round the spinner is (0 to 1).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Animation {
    pub level: f32,
    pub spin: f32,
}

/// Which side of the circle the bubble goes on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum BubbleSide {
    /// Right of the circle, while the panel is right of the pointer.
    #[default]
    Trailing,
    /// Left of the circle, while the panel is flipped to the pointer's left, so the circle stays
    /// next to the pointer.
    Leading,
}

/// A drawn panel.
pub struct Rendered {
    /// Premultiplied RGBA, `scale` pixels per logical pixel.
    pub pixmap: Pixmap,
    /// The panel's size in logical pixels.
    pub width: u32,
    pub height: u32,
}

impl Rendered {
    /// The pixels as Wayland's ARGB8888: premultiplied, little-endian, so B, G, R, A in memory.
    pub fn argb8888(&self) -> Vec<u8> {
        let mut bytes = self.pixmap.data().to_vec();
        for pixel in bytes.as_chunks_mut::<4>().0 {
            pixel.swap(0, 2);
        }
        bytes
    }
}

pub struct PanelView {
    typeface: Typeface,
}

/// Where things go in a panel of some content, in logical pixels.
struct Layout {
    width: f32,
    height: f32,
    /// The message's lines, and the bubble round them.
    lines: Vec<String>,
    bubble: Option<(f32, f32)>,
}

impl PanelView {
    pub fn new(typeface: Typeface) -> Self {
        Self { typeface }
    }

    /// The panel's size for `content` in logical pixels, which the bubble's side doesn't change.
    pub fn size(&self, content: &PanelContent) -> (u32, u32) {
        let layout = self.lay_out(content);
        (layout.width as u32, layout.height as u32)
    }

    pub fn render(
        &self,
        content: &PanelContent,
        animation: Animation,
        scale: f32,
        theme: Theme,
        side: BubbleSide,
    ) -> Rendered {
        let palette = theme.palette();
        let layout = self.lay_out(content);
        // The size is whole logical pixels; its pixels are that times the scale, rounded, as
        // Wayland's fractional scaling has them.
        let pixel_width = (layout.width * scale).round().max(1.0) as u32;
        let pixel_height = (layout.height * scale).round().max(1.0) as u32;
        let mut pixmap = Pixmap::new(pixel_width, pixel_height).expect("a panel has a positive size");
        let transform = Transform::from_scale(scale, scale);
        let middle = layout.height / 2.0;

        // The circle and the bubble side by side, centred on one line, as an HStack has them.
        let circle_left = match side {
            BubbleSide::Trailing => SHADOW,
            BubbleSide::Leading => layout.width - SHADOW - CIRCLE,
        };
        let circle = Rect::from_xywh(circle_left, middle - CIRCLE / 2.0, CIRCLE, CIRCLE).expect("a circle has a size");
        draw_raised(&mut pixmap, circle, CIRCLE / 2.0, &palette, transform);
        let (center_x, center_y) = (circle_left + CIRCLE / 2.0, middle);
        match content.indicator {
            Indicator::Level { hands_free } => {
                draw_level(
                    &mut pixmap,
                    center_x,
                    center_y,
                    animation.level,
                    hands_free,
                    &palette,
                    transform,
                );
            }
            Indicator::Spinner => draw_spinner(&mut pixmap, center_x, center_y, animation.spin, &palette, transform),
            Indicator::Notice { problem } => draw_glyph(&mut pixmap, center_x, center_y, problem, &palette, transform),
        }

        if let Some((bubble_width, bubble_height)) = layout.bubble {
            let bubble_left = match side {
                BubbleSide::Trailing => SHADOW + CIRCLE + BUBBLE_GAP,
                BubbleSide::Leading => SHADOW,
            };
            let top = middle - bubble_height / 2.0;
            let bubble = Rect::from_xywh(bubble_left, top, bubble_width, bubble_height).expect("a bubble has a size");
            draw_raised(&mut pixmap, bubble, BUBBLE_CORNER_RADIUS, &palette, transform);
            let mut line_top = top + BUBBLE_PADDING_Y;
            for line in &layout.lines {
                let baseline = line_top + self.typeface.ascent(MESSAGE_EM);
                self.typeface.draw(
                    &mut pixmap,
                    line,
                    MESSAGE_EM * scale,
                    (bubble_left + BUBBLE_PADDING_X) * scale,
                    baseline * scale,
                    palette.primary,
                );
                line_top += self.typeface.line_height(MESSAGE_EM);
            }
        }

        Rendered {
            pixmap,
            width: layout.width as u32,
            height: layout.height as u32,
        }
    }

    fn lay_out(&self, content: &PanelContent) -> Layout {
        let lines = content
            .message
            .as_deref()
            .map(|text| self.typeface.wrap(text, MESSAGE_EM, MESSAGE_MAX_WIDTH, 2))
            .unwrap_or_default();
        let bubble = (!lines.is_empty()).then(|| {
            let text_width = lines
                .iter()
                .map(|line| self.typeface.width(line, MESSAGE_EM))
                .fold(0.0_f32, f32::max);
            let text_height = lines.len() as f32 * self.typeface.line_height(MESSAGE_EM);
            (
                (text_width + 2.0 * BUBBLE_PADDING_X).ceil(),
                (text_height + 2.0 * BUBBLE_PADDING_Y).ceil(),
            )
        });
        let (content_width, content_height) = match bubble {
            Some((width, height)) => (CIRCLE + BUBBLE_GAP + width, height.max(CIRCLE)),
            None => (CIRCLE, CIRCLE),
        };
        Layout {
            width: (content_width + 2.0 * SHADOW).ceil(),
            height: (content_height + 2.0 * SHADOW).ceil(),
            lines,
            bubble,
        }
    }
}

/// `level` between [`QUIET`] (0) and [`LOUD`] (1) on a log scale, clamped to 0 to 1; 0 for
/// silence, a negative level or NaN.
fn level_fraction(level: f32) -> f32 {
    if level.is_nan() || level <= 0.0 {
        return 0.0;
    }
    ((level.log10() - QUIET.log10()) / (LOUD.log10() - QUIET.log10())).clamp(0.0, 1.0)
}

/// The level disc's radius for `level`.
fn disc_radius(level: f32) -> f32 {
    DISC_MIN_RADIUS + DISC_GROWTH * level_fraction(level)
}

fn paint(color: Color) -> Paint<'static> {
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    paint
}

fn with_alpha(color: Color, factor: f32) -> Color {
    let mut color = color;
    color.apply_opacity(factor);
    color
}

/// A rectangle with its corners rounded by `radius`, as quarter circles.
pub(crate) fn rounded_rect(rect: Rect, radius: f32) -> Option<Path> {
    let radius = radius.min(rect.width() / 2.0).min(rect.height() / 2.0);
    // How far a cubic's control points sit along the tangent to draw a quarter circle.
    let control = radius * 0.552_284_8;
    let (left, top, right, bottom) = (rect.left(), rect.top(), rect.right(), rect.bottom());
    let mut path = PathBuilder::new();
    path.move_to(left + radius, top);
    path.line_to(right - radius, top);
    path.cubic_to(
        right - radius + control,
        top,
        right,
        top + radius - control,
        right,
        top + radius,
    );
    path.line_to(right, bottom - radius);
    path.cubic_to(
        right,
        bottom - radius + control,
        right - radius + control,
        bottom,
        right - radius,
        bottom,
    );
    path.line_to(left + radius, bottom);
    path.cubic_to(
        left + radius - control,
        bottom,
        left,
        bottom - radius + control,
        left,
        bottom - radius,
    );
    path.line_to(left, top + radius);
    path.cubic_to(
        left,
        top + radius - control,
        left + radius - control,
        top,
        left + radius,
        top,
    );
    path.close();
    path.finish()
}

fn circle(center_x: f32, center_y: f32, radius: f32) -> Option<Path> {
    PathBuilder::from_circle(center_x, center_y, radius)
}

/// An arc of `radius` round a centre, from `start` (radians, clockwise from the right, as y grows
/// downwards) through `sweep`, in cubics of at most a quarter turn.
fn arc(center_x: f32, center_y: f32, radius: f32, start: f32, sweep: f32) -> Option<Path> {
    let segments = (sweep / FRAC_PI_2).ceil().max(1.0);
    let step = sweep / segments;
    // How far a cubic's control points sit along the tangent to follow `step` of a circle.
    let control = radius * 4.0 / 3.0 * (step / 4.0).tan();
    let point = |angle: f32| (center_x + radius * angle.cos(), center_y + radius * angle.sin());
    let mut path = PathBuilder::new();
    let (x, y) = point(start);
    path.move_to(x, y);
    for segment in 0..segments as usize {
        let from = start + step * segment as f32;
        let to = from + step;
        let (from_x, from_y) = point(from);
        let (to_x, to_y) = point(to);
        path.cubic_to(
            from_x - control * from.sin(),
            from_y + control * from.cos(),
            to_x + control * to.sin(),
            to_y - control * to.cos(),
            to_x,
            to_y,
        );
    }
    path.finish()
}

/// A shape raised off the screen: a soft shadow, a translucent fill and a hairline border inside
/// its edge, as SwiftUI's strokeBorder draws it.
fn draw_raised(pixmap: &mut Pixmap, rect: Rect, radius: f32, palette: &Palette, transform: Transform) {
    // The shape's outline, grown a little at a time and a little lower, each faint.
    for step in 1..=3 {
        let grow = step as f32;
        if let Some(outline) = Rect::from_ltrb(
            rect.left() - grow,
            rect.top() - grow + 1.0,
            rect.right() + grow,
            rect.bottom() + grow + 1.0,
        )
        .and_then(|grown| rounded_rect(grown, radius + grow))
        {
            let shadow = with_alpha(palette.shadow, 0.35 / grow);
            pixmap.fill_path(&outline, &paint(shadow), FillRule::Winding, transform, None);
        }
    }
    if let Some(shape) = rounded_rect(rect, radius) {
        pixmap.fill_path(&shape, &paint(palette.background), FillRule::Winding, transform, None);
    }
    if let Some(inner) = Rect::from_ltrb(
        rect.left() + 0.5,
        rect.top() + 0.5,
        rect.right() - 0.5,
        rect.bottom() - 0.5,
    )
    .and_then(|inner| rounded_rect(inner, radius - 0.5))
    {
        let stroke = Stroke {
            width: 1.0,
            ..Stroke::default()
        };
        pixmap.stroke_path(&inner, &paint(palette.border), &stroke, transform, None);
    }
}

/// A red disc that grows with the microphone's level, and a ring round it when hands-free.
fn draw_level(
    pixmap: &mut Pixmap,
    center_x: f32,
    center_y: f32,
    level: f32,
    hands_free: bool,
    palette: &Palette,
    transform: Transform,
) {
    if hands_free && let Some(ring) = circle(center_x, center_y, RING_RADIUS) {
        let stroke = Stroke {
            width: RING_WIDTH,
            ..Stroke::default()
        };
        pixmap.stroke_path(&ring, &paint(palette.secondary), &stroke, transform, None);
    }
    if let Some(disc) = circle(center_x, center_y, disc_radius(level)) {
        pixmap.fill_path(&disc, &paint(palette.meter), FillRule::Winding, transform, None);
    }
}

/// Three quarters of a ring, turning clockwise with `spin`.
fn draw_spinner(pixmap: &mut Pixmap, center_x: f32, center_y: f32, spin: f32, palette: &Palette, transform: Transform) {
    // From the top at no spin.
    let start = spin.rem_euclid(1.0) * TAU - FRAC_PI_2;
    if let Some(ring) = arc(center_x, center_y, SPINNER_RADIUS, start, SPINNER_SWEEP) {
        let stroke = Stroke {
            width: SPINNER_WIDTH,
            line_cap: LineCap::Round,
            ..Stroke::default()
        };
        pixmap.stroke_path(&ring, &paint(palette.secondary), &stroke, transform, None);
    }
}

/// A filled circle with its mark cut out, as the Mac's SF Symbols: an orange "!" for a problem,
/// a grey "i" otherwise.
fn draw_glyph(
    pixmap: &mut Pixmap,
    center_x: f32,
    center_y: f32,
    problem: bool,
    palette: &Palette,
    transform: Transform,
) {
    let color = if problem { palette.warning } else { palette.secondary };
    if let Some(disc) = circle(center_x, center_y, GLYPH / 2.0) {
        pixmap.fill_path(&disc, &paint(color), FillRule::Winding, transform, None);
    }
    // The bar and the dot: the bar above the dot for "!", below it for "i".
    let (bar, dot) = if problem {
        ((center_y - 5.5, center_y + 1.5), center_y + 5.0)
    } else {
        ((center_y - 1.5, center_y + 5.5), center_y - 5.0)
    };
    let mut line = PathBuilder::new();
    line.move_to(center_x, bar.0);
    line.line_to(center_x, bar.1);
    let stroke = Stroke {
        width: 2.2,
        line_cap: LineCap::Round,
        ..Stroke::default()
    };
    if let Some(line) = line.finish() {
        pixmap.stroke_path(&line, &paint(palette.background), &stroke, transform, None);
    }
    if let Some(dot) = circle(center_x, dot, 1.3) {
        pixmap.fill_path(&dot, &paint(palette.background), FillRule::Winding, transform, None);
    }
}

#[cfg(test)]
mod tests {
    use lt_dictation::Notice;

    use super::*;
    use crate::load_interface_font;

    fn view() -> PanelView {
        PanelView::new(load_interface_font().expect("a sans-serif font for the tests"))
    }

    fn contents() -> Vec<(&'static str, PanelContent)> {
        let content = |indicator, message: Option<String>| PanelContent { indicator, message };
        vec![
            ("listening", content(Indicator::Level { hands_free: false }, None)),
            ("hands-free", content(Indicator::Level { hands_free: true }, None)),
            ("transcribing", content(Indicator::Spinner, None)),
            (
                "still-processing",
                content(Indicator::Spinner, Some(Notice::StillProcessing.message())),
            ),
            (
                "nothing-heard",
                content(
                    Indicator::Notice { problem: false },
                    Some(Notice::NothingHeard.message()),
                ),
            ),
            (
                "copied",
                content(
                    Indicator::Notice { problem: false },
                    Some(Notice::CopiedToClipboard.message()),
                ),
            ),
            (
                "microphone-stopped",
                content(
                    Indicator::Notice { problem: true },
                    Some(
                        Notice::CaptureFailed(
                            "the input device was disconnected while the recording was in progress".to_owned(),
                        )
                        .message(),
                    ),
                ),
            ),
        ]
    }

    /// The pixel at `x`, `y` in logical pixels of a panel drawn at 2×.
    fn alpha_at(rendered: &Rendered, x: f32, y: f32) -> u8 {
        rendered
            .pixmap
            .pixel((x * 2.0) as u32, (y * 2.0) as u32)
            .map_or(0, |pixel| pixel.alpha())
    }

    /// Set LT_PANEL_SNAPSHOTS to a folder to see every panel, at 2×, in both themes, with the
    /// bubble on either side.
    #[test]
    fn every_panel_draws_inside_its_bounds() {
        let view = view();
        let folder = std::env::var_os("LT_PANEL_SNAPSHOTS").map(std::path::PathBuf::from);
        for (name, content) in contents() {
            for theme in [Theme::Dark, Theme::Light] {
                for side in [BubbleSide::Trailing, BubbleSide::Leading] {
                    let animation = Animation { level: 0.04, spin: 0.3 };
                    let rendered = view.render(&content, animation, 2.0, theme, side);
                    assert_eq!((rendered.width, rendered.height), view.size(&content), "{name}");
                    assert_eq!(rendered.pixmap.width(), rendered.width * 2, "{name}");
                    let (width, height) = (rendered.width as f32, rendered.height as f32);
                    if content.message.is_none() {
                        assert_eq!((width, height), (CIRCLE_SQUARE, CIRCLE_SQUARE), "{name}");
                    } else {
                        assert!(width > CIRCLE_SQUARE && width <= 360.0, "{name}: {width} wide");
                        assert!((CIRCLE_SQUARE..=64.0).contains(&height), "{name}: {height} high");
                    }
                    // The circle is painted where the side puts it; the corners hold nothing.
                    let circle_x = match side {
                        BubbleSide::Trailing => CIRCLE_SQUARE / 2.0,
                        BubbleSide::Leading => width - CIRCLE_SQUARE / 2.0,
                    };
                    assert!(alpha_at(&rendered, circle_x, height / 2.0) > 200, "{name}");
                    assert_eq!(alpha_at(&rendered, 0.0, 0.0), 0, "{name}");
                    assert_eq!(alpha_at(&rendered, width - 0.5, height - 0.5), 0, "{name}");
                    if let Some(folder) = &folder {
                        std::fs::create_dir_all(folder).expect("the snapshot folder");
                        let file = folder.join(format!("{name}-{theme:?}-{side:?}.png").to_lowercase());
                        rendered.pixmap.save_png(file).expect("a snapshot");
                    }
                }
            }
        }
    }

    #[test]
    fn the_disc_grows_with_the_level_on_a_log_scale() {
        assert_eq!(disc_radius(0.0), DISC_MIN_RADIUS);
        assert_eq!(disc_radius(-1.0), DISC_MIN_RADIUS);
        assert_eq!(disc_radius(f32::NAN), DISC_MIN_RADIUS);
        assert_eq!(disc_radius(QUIET), DISC_MIN_RADIUS);
        assert_eq!(disc_radius(LOUD), DISC_MIN_RADIUS + DISC_GROWTH);
        assert_eq!(disc_radius(1.0), DISC_MIN_RADIUS + DISC_GROWTH);
        // Halfway on the log scale is the geometric mean.
        let middle = (QUIET * LOUD).sqrt();
        assert!((level_fraction(middle) - 0.5).abs() < 1e-4);
        assert!(disc_radius(0.01) < disc_radius(0.03) && disc_radius(0.03) < disc_radius(0.06));

        // A loud level paints more of the circle red than a quiet one.
        let view = view();
        let content = PanelContent {
            indicator: Indicator::Level { hands_free: false },
            message: None,
        };
        let red = |level| {
            let rendered = view.render(
                &content,
                Animation { level, spin: 0.0 },
                1.0,
                Theme::Dark,
                BubbleSide::Trailing,
            );
            rendered
                .pixmap
                .pixels()
                .iter()
                .filter(|pixel| pixel.red() > 200 && pixel.green() < 100)
                .count()
        };
        assert!(red(0.1) > 3 * red(0.005));
    }

    #[test]
    fn the_spinner_turns() {
        let view = view();
        let content = PanelContent {
            indicator: Indicator::Spinner,
            message: None,
        };
        let draw = |spin| {
            view.render(
                &content,
                Animation { level: 0.0, spin },
                2.0,
                Theme::Dark,
                BubbleSide::Trailing,
            )
            .pixmap
        };
        assert_ne!(draw(0.0).data(), draw(0.5).data());
        assert_eq!(draw(0.25).data(), draw(1.25).data(), "a turn a second");
    }

    #[test]
    fn a_long_message_wraps_to_two_lines_and_ends_in_an_ellipsis() {
        let typeface = load_interface_font().expect("a font");
        let text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen \
                    sixteen seventeen eighteen nineteen twenty twenty-one twenty-two twenty-three";
        let lines = typeface.wrap(text, MESSAGE_EM, MESSAGE_MAX_WIDTH, 2);
        assert_eq!(lines.len(), 2);
        assert!(lines[1].ends_with('…'));
        assert!(
            lines
                .iter()
                .all(|line| typeface.width(line, MESSAGE_EM) <= MESSAGE_MAX_WIDTH)
        );
        assert_eq!(
            typeface.wrap("Didn't catch that", MESSAGE_EM, MESSAGE_MAX_WIDTH, 2),
            ["Didn't catch that"]
        );
    }

    #[test]
    fn pixels_convert_to_waylands_order() {
        let mut pixmap = Pixmap::new(1, 1).expect("a pixel");
        pixmap.fill(Color::from_rgba8(10, 20, 30, 255));
        let rendered = Rendered {
            pixmap,
            width: 1,
            height: 1,
        };
        assert_eq!(rendered.argb8888(), [30, 20, 10, 255]);
    }
}
