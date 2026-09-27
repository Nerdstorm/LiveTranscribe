//! Draws the panel as the Mac's HUDView lays it out: in a capsule, the level meter, a spinner or a
//! symbol; then a title with a caption, or a message of up to two lines; then the × that cancels.
//!
//! Lengths are in logical pixels, as the Mac's points: the platform gives the scale, and the
//! pixmap has that many pixels per logical pixel. A transparent margin around the capsule holds
//! its shadow, and whatever gap the platform wants between the panel and what it points at.

use std::f32::consts::TAU;

use tiny_skia::{Color, FillRule, LineCap, Paint, Path, PathBuilder, Pixmap, Rect, Stroke, Transform};

use crate::text::Typeface;
use crate::theme::Palette;
use crate::{PanelContent, Theme};

const TITLE_EM: f32 = 13.0;
const CAPTION_EM: f32 = 11.0;
const PADDING_X: f32 = 14.0;
const PADDING_Y: f32 = 10.0;
const SPACING: f32 = 10.0;
const MIN_WIDTH: f32 = 180.0;
/// Around the capsule, for its shadow.
const SHADOW: f32 = 4.0;
/// Widest a message or caption gets before it wraps onto a second line.
const MESSAGE_MAX_WIDTH: f32 = 320.0;
const TITLE_CAPTION_GAP: f32 = 1.0;
const SYMBOL: f32 = 16.0;
const METER_BAR_WIDTH: f32 = 3.0;
const METER_GAP: f32 = 2.0;
const METER_HEIGHT: f32 = 18.0;
/// Level at which each bar lights, for a meter that moves with normal speech (the Mac's).
const METER_THRESHOLDS: [f32; 5] = [0.005, 0.015, 0.03, 0.06, 0.12];
const SPINNER_SPOKES: usize = 12;
/// The × is easier to hit than it is to see.
const CANCEL_SLOP: f32 = 4.0;

/// What moves: the microphone's level, and how far round the spinner is (0 to 1).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Animation {
    pub level: f32,
    pub spin: f32,
}

/// Transparent space above and below the capsule and its shadow, in logical pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Margins {
    pub top: f32,
    pub bottom: f32,
}

/// A drawn panel.
pub struct Rendered {
    /// Premultiplied RGBA, `scale` pixels per logical pixel.
    pub pixmap: Pixmap,
    /// The panel's size in logical pixels.
    pub width: u32,
    pub height: u32,
    /// Where a click cancels the dictation, in logical pixels.
    pub cancel: Option<Rect>,
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

    pub fn hits_cancel(&self, x: f32, y: f32) -> bool {
        self.cancel
            .is_some_and(|area| x >= area.left() && x <= area.right() && y >= area.top() && y <= area.bottom())
    }
}

pub struct PanelView {
    typeface: Typeface,
}

/// What sits before the text.
#[derive(Clone, Copy)]
enum Leading {
    Meter,
    Spinner,
    Symbol { problem: bool },
}

impl Leading {
    fn size(self) -> (f32, f32) {
        match self {
            Self::Meter => (5.0 * METER_BAR_WIDTH + 4.0 * METER_GAP, METER_HEIGHT),
            Self::Spinner | Self::Symbol { .. } => (SYMBOL, SYMBOL),
        }
    }
}

/// A line of text and how it is set.
struct Line {
    text: String,
    em: f32,
    secondary: bool,
}

impl PanelView {
    pub fn new(typeface: Typeface) -> Self {
        Self { typeface }
    }

    pub fn render(
        &self,
        content: &PanelContent,
        animation: Animation,
        scale: f32,
        theme: Theme,
        margins: Margins,
    ) -> Rendered {
        let palette = theme.palette();
        let (leading, lines) = self.lay_out(content);
        let cancels = content.can_cancel();

        // The text block: lines one under another, a hairline between title and caption.
        let text_width = lines
            .iter()
            .map(|line| self.typeface.width(&line.text, line.em))
            .fold(0.0_f32, f32::max);
        let text_height: f32 = lines
            .iter()
            .enumerate()
            .map(|(index, line)| {
                let gap = if index > 0 && line.em != lines[index - 1].em {
                    TITLE_CAPTION_GAP
                } else {
                    0.0
                };
                self.typeface.line_height(line.em) + gap
            })
            .sum();
        let (leading_width, leading_height) = leading.size();
        let cancel_width = if cancels { SPACING + SYMBOL } else { 0.0 };
        let row_width = leading_width + SPACING + text_width + cancel_width;
        let row_height = leading_height.max(text_height).max(if cancels { SYMBOL } else { 0.0 });
        let capsule_width = (row_width + 2.0 * PADDING_X).max(MIN_WIDTH).ceil();
        let capsule_height = (row_height + 2.0 * PADDING_Y).ceil();
        let width = capsule_width + 2.0 * SHADOW;
        let height = capsule_height + 2.0 * SHADOW + margins.top + margins.bottom;
        let capsule = Rect::from_xywh(SHADOW, SHADOW + margins.top, capsule_width, capsule_height)
            .expect("a capsule has a positive size");

        // The size is whole logical pixels; its pixels are that times the scale, rounded, as
        // Wayland's fractional scaling has them.
        let pixel_width = (width * scale).round().max(1.0) as u32;
        let pixel_height = (height * scale).round().max(1.0) as u32;
        let mut pixmap = Pixmap::new(pixel_width, pixel_height).expect("a panel has a positive size");
        let transform = Transform::from_scale(scale, scale);

        draw_capsule(&mut pixmap, capsule, &palette, transform);

        // The row, centred in the capsule as SwiftUI centres content narrower than its frame.
        let mut x = capsule.left() + (capsule_width - row_width) / 2.0;
        let middle = capsule.top() + capsule_height / 2.0;
        match leading {
            Leading::Meter => draw_meter(&mut pixmap, x, middle, animation.level, &palette, transform),
            Leading::Spinner => draw_spinner(&mut pixmap, x, middle, animation.spin, &palette, transform),
            Leading::Symbol { problem } => draw_symbol(&mut pixmap, x, middle, problem, &palette, transform),
        }
        x += leading_width + SPACING;

        let mut top = middle - text_height / 2.0;
        for (index, line) in lines.iter().enumerate() {
            if index > 0 && line.em != lines[index - 1].em {
                top += TITLE_CAPTION_GAP;
            }
            let baseline = top + self.typeface.ascent(line.em);
            let color = if line.secondary {
                palette.secondary
            } else {
                palette.primary
            };
            self.typeface.draw(
                &mut pixmap,
                &line.text,
                line.em * scale,
                x * scale,
                baseline * scale,
                color,
            );
            top += self.typeface.line_height(line.em);
        }

        let cancel = cancels.then(|| {
            let left = x + text_width + SPACING;
            draw_cancel(&mut pixmap, left, middle, &palette, transform);
            Rect::from_xywh(
                left - CANCEL_SLOP,
                middle - SYMBOL / 2.0 - CANCEL_SLOP,
                SYMBOL + 2.0 * CANCEL_SLOP,
                SYMBOL + 2.0 * CANCEL_SLOP,
            )
            .expect("the × has a positive size")
        });

        Rendered {
            pixmap,
            width: width.ceil() as u32,
            height: height.ceil() as u32,
            cancel,
        }
    }

    fn lay_out(&self, content: &PanelContent) -> (Leading, Vec<Line>) {
        let caption = |text: &str| {
            self.typeface
                .wrap(text, CAPTION_EM, MESSAGE_MAX_WIDTH, 2)
                .into_iter()
                .map(|text| Line {
                    text,
                    em: CAPTION_EM,
                    secondary: true,
                })
        };
        let title = |text: &str| Line {
            text: text.to_owned(),
            em: TITLE_EM,
            secondary: false,
        };
        match content {
            PanelContent::Listening {
                hands_free,
                caption: hint,
            } => {
                let heading = if *hands_free {
                    "Listening, hands-free"
                } else {
                    "Listening"
                };
                (
                    Leading::Meter,
                    std::iter::once(title(heading)).chain(caption(hint)).collect(),
                )
            }
            PanelContent::Transcribing { caption: progress } => {
                let mut lines = vec![title("Transcribing…")];
                lines.extend(progress.iter().flat_map(|text| caption(text)));
                (Leading::Spinner, lines)
            }
            PanelContent::Message { text, problem } => {
                let lines = self
                    .typeface
                    .wrap(text, TITLE_EM, MESSAGE_MAX_WIDTH, 2)
                    .into_iter()
                    .map(|text| Line {
                        text,
                        em: TITLE_EM,
                        secondary: false,
                    })
                    .collect();
                (Leading::Symbol { problem: *problem }, lines)
            }
        }
    }
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

fn draw_capsule(pixmap: &mut Pixmap, capsule: Rect, palette: &Palette, transform: Transform) {
    // A soft shadow: the capsule's outline, grown a little at a time, each faint.
    for step in 1..=3 {
        let grow = step as f32;
        if let Some(outline) = Rect::from_ltrb(
            capsule.left() - grow,
            capsule.top() - grow + 1.0,
            capsule.right() + grow,
            capsule.bottom() + grow + 1.0,
        )
        .and_then(|rect| rounded_rect(rect, rect.height() / 2.0))
        {
            let shadow = with_alpha(palette.shadow, 0.35 / grow);
            pixmap.fill_path(&outline, &paint(shadow), FillRule::Winding, transform, None);
        }
    }
    if let Some(shape) = rounded_rect(capsule, capsule.height() / 2.0) {
        pixmap.fill_path(&shape, &paint(palette.background), FillRule::Winding, transform, None);
    }
    // The border sits inside the capsule's edge, as SwiftUI's strokeBorder draws it.
    if let Some(inner) = Rect::from_ltrb(
        capsule.left() + 0.5,
        capsule.top() + 0.5,
        capsule.right() - 0.5,
        capsule.bottom() - 0.5,
    )
    .and_then(|rect| rounded_rect(rect, rect.height() / 2.0))
    {
        let stroke = Stroke {
            width: 1.0,
            ..Stroke::default()
        };
        pixmap.stroke_path(&inner, &paint(palette.border), &stroke, transform, None);
    }
}

/// Five bars that rise with the microphone's level.
fn draw_meter(pixmap: &mut Pixmap, left: f32, middle: f32, level: f32, palette: &Palette, transform: Transform) {
    for (index, threshold) in METER_THRESHOLDS.iter().enumerate() {
        let bar_height = 6.0 + 3.0 * index as f32;
        let x = left + index as f32 * (METER_BAR_WIDTH + METER_GAP);
        let color = if level >= *threshold {
            palette.meter
        } else {
            palette.quaternary
        };
        if let Some(bar) = Rect::from_xywh(x, middle - bar_height / 2.0, METER_BAR_WIDTH, bar_height)
            .and_then(|rect| rounded_rect(rect, METER_BAR_WIDTH / 2.0))
        {
            pixmap.fill_path(&bar, &paint(color), FillRule::Winding, transform, None);
        }
    }
}

/// Spokes round a centre, the leading one darkest, turning with `spin`.
fn draw_spinner(pixmap: &mut Pixmap, left: f32, middle: f32, spin: f32, palette: &Palette, transform: Transform) {
    let (center_x, center_y) = (left + SYMBOL / 2.0, middle);
    let stroke = Stroke {
        width: 1.6,
        line_cap: LineCap::Round,
        ..Stroke::default()
    };
    // The spinner steps from spoke to spoke, as the Mac's does.
    let step = (spin.rem_euclid(1.0) * SPINNER_SPOKES as f32).floor();
    for spoke in 0..SPINNER_SPOKES {
        let angle = (spoke as f32 + step) / SPINNER_SPOKES as f32 * TAU;
        let (sin, cos) = angle.sin_cos();
        let mut path = PathBuilder::new();
        path.move_to(center_x + cos * 3.6, center_y + sin * 3.6);
        path.line_to(center_x + cos * 7.0, center_y + sin * 7.0);
        let fade = 0.15 + 0.85 * (spoke as f32 + 1.0) / SPINNER_SPOKES as f32;
        if let Some(path) = path.finish() {
            pixmap.stroke_path(
                &path,
                &paint(with_alpha(palette.primary, fade)),
                &stroke,
                transform,
                None,
            );
        }
    }
}

/// A filled warning triangle for a problem, a filled check mark otherwise, with their marks cut
/// out in the capsule's colour.
fn draw_symbol(pixmap: &mut Pixmap, left: f32, middle: f32, problem: bool, palette: &Palette, transform: Transform) {
    let (center_x, center_y) = (left + SYMBOL / 2.0, middle);
    let mark = Stroke {
        width: 1.8,
        line_cap: LineCap::Round,
        ..Stroke::default()
    };
    if problem {
        let mut triangle = PathBuilder::new();
        triangle.move_to(center_x, center_y - 7.0);
        triangle.line_to(center_x + 7.8, center_y + 6.5);
        triangle.line_to(center_x - 7.8, center_y + 6.5);
        triangle.close();
        if let Some(triangle) = triangle.finish() {
            let rounded = Stroke {
                width: 1.6,
                line_join: tiny_skia::LineJoin::Round,
                ..Stroke::default()
            };
            pixmap.fill_path(&triangle, &paint(palette.warning), FillRule::Winding, transform, None);
            pixmap.stroke_path(&triangle, &paint(palette.warning), &rounded, transform, None);
        }
        let mut bar = PathBuilder::new();
        bar.move_to(center_x, center_y - 2.6);
        bar.line_to(center_x, center_y + 1.6);
        if let Some(bar) = bar.finish() {
            pixmap.stroke_path(&bar, &paint(palette.background), &mark, transform, None);
        }
        if let Some(dot) = circle(center_x, center_y + 4.2, 1.0) {
            pixmap.fill_path(&dot, &paint(palette.background), FillRule::Winding, transform, None);
        }
    } else {
        if let Some(disc) = circle(center_x, center_y, SYMBOL / 2.0) {
            pixmap.fill_path(&disc, &paint(palette.secondary), FillRule::Winding, transform, None);
        }
        let mut check = PathBuilder::new();
        check.move_to(center_x - 3.6, center_y + 0.2);
        check.line_to(center_x - 1.0, center_y + 2.8);
        check.line_to(center_x + 3.8, center_y - 2.6);
        if let Some(check) = check.finish() {
            pixmap.stroke_path(&check, &paint(palette.background), &mark, transform, None);
        }
    }
}

/// A filled circle with a × cut out.
fn draw_cancel(pixmap: &mut Pixmap, left: f32, middle: f32, palette: &Palette, transform: Transform) {
    let (center_x, center_y) = (left + SYMBOL / 2.0, middle);
    if let Some(disc) = circle(center_x, center_y, SYMBOL / 2.0) {
        pixmap.fill_path(&disc, &paint(palette.secondary), FillRule::Winding, transform, None);
    }
    let arm = 2.9;
    let mut cross = PathBuilder::new();
    cross.move_to(center_x - arm, center_y - arm);
    cross.line_to(center_x + arm, center_y + arm);
    cross.move_to(center_x + arm, center_y - arm);
    cross.line_to(center_x - arm, center_y + arm);
    let stroke = Stroke {
        width: 1.6,
        line_cap: LineCap::Round,
        ..Stroke::default()
    };
    if let Some(cross) = cross.finish() {
        pixmap.stroke_path(&cross, &paint(palette.background), &stroke, transform, None);
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
        vec![
            (
                "listening",
                PanelContent::Listening {
                    hands_free: false,
                    caption: "Release Right Ctrl to finish · esc to cancel".to_owned(),
                },
            ),
            (
                "hands-free",
                PanelContent::Listening {
                    hands_free: true,
                    caption: "Press Right Ctrl to finish · esc to cancel".to_owned(),
                },
            ),
            ("transcribing", PanelContent::Transcribing { caption: None }),
            (
                "still-processing",
                PanelContent::Transcribing {
                    caption: Some(Notice::StillProcessing.message()),
                },
            ),
            (
                "nothing-heard",
                PanelContent::Message {
                    text: Notice::NothingHeard.message(),
                    problem: false,
                },
            ),
            (
                "copied",
                PanelContent::Message {
                    text: Notice::CopiedToClipboard.message(),
                    problem: false,
                },
            ),
            (
                "microphone-stopped",
                PanelContent::Message {
                    text: Notice::CaptureFailed(
                        "the input device was disconnected while the recording was in progress".to_owned(),
                    )
                    .message(),
                    problem: true,
                },
            ),
        ]
    }

    /// Set LT_PANEL_SNAPSHOTS to a folder to see every panel, at 2×, in both themes.
    #[test]
    fn every_panel_draws_inside_its_bounds() {
        let view = view();
        let folder = std::env::var_os("LT_PANEL_SNAPSHOTS").map(std::path::PathBuf::from);
        for (name, content) in contents() {
            for theme in [Theme::Dark, Theme::Light] {
                let animation = Animation { level: 0.04, spin: 0.3 };
                let rendered = view.render(&content, animation, 2.0, theme, Margins::default());
                assert_eq!(rendered.pixmap.width(), rendered.width * 2, "{name}");
                assert!(
                    rendered.width >= 188 && rendered.width <= 460,
                    "{name}: {} wide",
                    rendered.width
                );
                assert!(
                    rendered.height >= 40 && rendered.height <= 90,
                    "{name}: {} high",
                    rendered.height
                );
                // The capsule's middle is painted; the corners hold only the shadow's edge.
                let middle = rendered
                    .pixmap
                    .pixel(rendered.pixmap.width() / 2, rendered.pixmap.height() / 2);
                assert!(middle.is_some_and(|pixel| pixel.alpha() > 200), "{name}");
                assert_eq!(
                    rendered.pixmap.pixel(0, 0).map(|pixel| pixel.alpha()),
                    Some(0),
                    "{name}"
                );
                assert_eq!(rendered.cancel.is_some(), content.can_cancel(), "{name}");
                if let Some(folder) = &folder {
                    std::fs::create_dir_all(folder).expect("the snapshot folder");
                    let file = folder.join(format!("{name}-{theme:?}.png").to_lowercase());
                    rendered.pixmap.save_png(file).expect("a snapshot");
                }
            }
        }
    }

    #[test]
    fn the_cancel_button_is_where_it_is_drawn() {
        let content = PanelContent::Listening {
            hands_free: false,
            caption: "Release Right Ctrl to finish · esc to cancel".to_owned(),
        };
        let rendered = view().render(&content, Animation::default(), 1.0, Theme::Dark, Margins::default());
        let area = rendered.cancel.expect("a ×");
        assert!(rendered.hits_cancel(area.left() + area.width() / 2.0, area.top() + area.height() / 2.0));
        assert!(!rendered.hits_cancel(10.0, 10.0));
        assert!(area.right() <= rendered.width as f32, "inside the panel");
    }

    #[test]
    fn margins_make_room_above_and_below() {
        let content = PanelContent::Transcribing { caption: None };
        let view = view();
        let plain = view.render(&content, Animation::default(), 1.0, Theme::Dark, Margins::default());
        let spaced = view.render(
            &content,
            Animation::default(),
            1.0,
            Theme::Dark,
            Margins { top: 10.0, bottom: 0.0 },
        );
        assert_eq!(spaced.height, plain.height + 10);
        let shifted = spaced.cancel.expect("a ×").top() - plain.cancel.expect("a ×").top();
        assert!((shifted - 10.0).abs() < 1e-3);
    }

    #[test]
    fn long_messages_wrap_to_two_lines_and_end_in_an_ellipsis() {
        let typeface = load_interface_font().expect("a font");
        let text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen \
                    sixteen seventeen eighteen nineteen twenty twenty-one twenty-two twenty-three";
        let lines = typeface.wrap(text, TITLE_EM, MESSAGE_MAX_WIDTH, 2);
        assert_eq!(lines.len(), 2);
        assert!(lines[1].ends_with('…'));
        assert!(
            lines
                .iter()
                .all(|line| typeface.width(line, TITLE_EM) <= MESSAGE_MAX_WIDTH)
        );
        assert_eq!(
            typeface.wrap("Didn't catch that", TITLE_EM, MESSAGE_MAX_WIDTH, 2),
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
            cancel: None,
        };
        assert_eq!(rendered.argb8888(), [30, 20, 10, 255]);
    }
}
