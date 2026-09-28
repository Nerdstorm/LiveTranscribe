//! The panel's text: one typeface, measured, wrapped to a width, and drawn into a pixmap.
//!
//! Sizes are em sizes in pixels, as the Mac and CSS give them. The panel's text is short English,
//! so glyphs are laid out one after another with the font's kerning; there is no shaping.

use ab_glyph::{Font, FontVec, GlyphId, PxScale, ScaleFont, point};
use tiny_skia::{Color, Pixmap, PremultipliedColorU8};

const ELLIPSIS: char = '…';

pub struct Typeface {
    font: FontVec,
}

impl Typeface {
    pub fn new(font: FontVec) -> Self {
        Self { font }
    }

    /// ab_glyph scales by the height from descender to ascender, not by the em.
    fn scale(&self, em: f32) -> PxScale {
        let units_per_em = self.font.units_per_em().unwrap_or(1_000.0);
        PxScale::from(em * self.font.height_unscaled() / units_per_em)
    }

    pub(crate) fn ascent(&self, em: f32) -> f32 {
        self.font.as_scaled(self.scale(em)).ascent()
    }

    /// From the top of the ascender to the bottom of the descender.
    pub(crate) fn line_height(&self, em: f32) -> f32 {
        let scaled = self.font.as_scaled(self.scale(em));
        scaled.ascent() - scaled.descent()
    }

    pub(crate) fn width(&self, text: &str, em: f32) -> f32 {
        let scaled = self.font.as_scaled(self.scale(em));
        let mut width = 0.0;
        let mut previous: Option<GlyphId> = None;
        for character in text.chars() {
            let id = scaled.glyph_id(character);
            if let Some(previous) = previous {
                width += scaled.kern(previous, id);
            }
            width += scaled.h_advance(id);
            previous = Some(id);
        }
        width
    }

    /// `text` in at most `max_lines` lines no wider than `max_width`, broken between words. What
    /// doesn't fit ends the last line with an ellipsis.
    pub(crate) fn wrap(&self, text: &str, em: f32, max_width: f32, max_lines: usize) -> Vec<String> {
        let words: Vec<&str> = text.split_whitespace().collect();
        let mut lines = Vec::new();
        let mut current = String::new();
        let mut next = 0;
        while next < words.len() && lines.len() < max_lines {
            let candidate = if current.is_empty() {
                words[next].to_owned()
            } else {
                format!("{current} {}", words[next])
            };
            if current.is_empty() || self.width(&candidate, em) <= max_width {
                current = candidate;
                next += 1;
            } else {
                lines.push(std::mem::take(&mut current));
            }
        }
        if !current.is_empty() && lines.len() < max_lines {
            lines.push(current);
        }
        let cut = next < words.len();
        for (index, line) in lines.iter_mut().enumerate() {
            let last = index + 1 == max_lines;
            if (last && cut) || self.width(line, em) > max_width {
                *line = self.ellipsized(line, em, max_width, last && cut);
            }
        }
        lines
    }

    /// `line` shortened to fit `max_width` with an ellipsis, which `always` adds even when it fits.
    fn ellipsized(&self, line: &str, em: f32, max_width: f32, always: bool) -> String {
        let mut kept: Vec<char> = line.chars().collect();
        if !always && self.width(line, em) <= max_width {
            return line.to_owned();
        }
        loop {
            let candidate: String = kept.iter().collect::<String>().trim_end().to_owned() + &ELLIPSIS.to_string();
            if kept.is_empty() || self.width(&candidate, em) <= max_width {
                return candidate;
            }
            kept.pop();
        }
    }

    /// Draws `text` with its baseline at `baseline`, starting at `x`; both in the pixmap's pixels,
    /// as is `em`.
    pub(crate) fn draw(&self, pixmap: &mut Pixmap, text: &str, em: f32, x: f32, baseline: f32, color: Color) {
        let scale = self.scale(em);
        let scaled = self.font.as_scaled(scale);
        let (width, height) = (pixmap.width() as i32, pixmap.height() as i32);
        let pixels = pixmap.pixels_mut();
        let mut caret = x;
        let mut previous: Option<GlyphId> = None;
        for character in text.chars() {
            let id = scaled.glyph_id(character);
            if let Some(previous) = previous {
                caret += scaled.kern(previous, id);
            }
            let glyph = id.with_scale_and_position(scale, point(caret, baseline));
            caret += scaled.h_advance(id);
            previous = Some(id);
            let Some(outlined) = self.font.outline_glyph(glyph) else {
                continue;
            };
            let bounds = outlined.px_bounds();
            outlined.draw(|glyph_x, glyph_y, coverage| {
                let pixel_x = bounds.min.x as i32 + glyph_x as i32;
                let pixel_y = bounds.min.y as i32 + glyph_y as i32;
                if (0..width).contains(&pixel_x) && (0..height).contains(&pixel_y) {
                    let pixel = &mut pixels[(pixel_y * width + pixel_x) as usize];
                    *pixel = blend(*pixel, color, coverage);
                }
            });
        }
    }
}

/// `color` at `coverage` over `under` (source-over, premultiplied).
fn blend(under: PremultipliedColorU8, color: Color, coverage: f32) -> PremultipliedColorU8 {
    let alpha = color.alpha() * coverage.clamp(0.0, 1.0);
    let keep = 1.0 - alpha;
    let channel = |source: f32, destination: u8| (source * alpha * 255.0 + f32::from(destination) * keep).round();
    let red = channel(color.red(), under.red());
    let green = channel(color.green(), under.green());
    let blue = channel(color.blue(), under.blue());
    let result_alpha = (alpha * 255.0 + f32::from(under.alpha()) * keep).round();
    let clamp = |value: f32| value.clamp(0.0, 255.0) as u8;
    let alpha_byte = clamp(result_alpha);
    PremultipliedColorU8::from_rgba(
        clamp(red).min(alpha_byte),
        clamp(green).min(alpha_byte),
        clamp(blue).min(alpha_byte),
        alpha_byte,
    )
    .unwrap_or(under)
}
