//! The tray's icon, drawn as the Mac's menu bar draws its symbols: in one colour, the panel's text
//! colour for the desktop's light or dark mode, on a 24-point grid scaled to the size asked for.

use tiny_skia::{Color, FillRule, LineCap, LineJoin, Paint, PathBuilder, Pixmap, Rect, Stroke, Transform};

use crate::panel_view::rounded_rect;
use crate::{MenuBarIcon, Theme};

const GRID: f32 = 24.0;
const LINE_WIDTH: f32 = 1.8;
const CENTER: f32 = GRID / 2.0;
const RING_RADIUS: f32 = 9.6;

/// An icon's pixels: RGBA, not premultiplied, rows packed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IconImage {
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// `icon`, `size` pixels square.
pub fn draw_icon(icon: MenuBarIcon, theme: Theme, size: u32) -> IconImage {
    let pixmap = draw_pixmap(icon, theme, size);
    let rgba = pixmap
        .pixels()
        .iter()
        .flat_map(|pixel| {
            let color = pixel.demultiply();
            [color.red(), color.green(), color.blue(), color.alpha()]
        })
        .collect();
    IconImage {
        rgba,
        width: pixmap.width(),
        height: pixmap.height(),
    }
}

fn draw_pixmap(icon: MenuBarIcon, theme: Theme, size: u32) -> Pixmap {
    let size = size.max(1);
    let mut pixmap = Pixmap::new(size, size).expect("an icon has a positive size");
    let scale = size as f32 / GRID;
    let transform = Transform::from_scale(scale, scale);
    let mut paint = Paint::default();
    paint.set_color(match theme {
        Theme::Dark => Color::from_rgba8(255, 255, 255, 240),
        Theme::Light => Color::from_rgba8(29, 29, 31, 240),
    });
    paint.anti_alias = true;
    let mut glyph = Glyph {
        pixmap: &mut pixmap,
        paint,
        transform,
    };
    match icon {
        MenuBarIcon::Waveform => glyph.waveform(),
        MenuBarIcon::Microphone => glyph.microphone(),
        MenuBarIcon::Ellipsis => {
            glyph.ring();
            for x in [7.8, CENTER, 16.2] {
                glyph.dot(x, CENTER, 1.5);
            }
        }
        MenuBarIcon::Warning => glyph.warning(),
        MenuBarIcon::Loading => {
            glyph.ring();
            glyph.line(&[(CENTER, 7.0), (CENTER, 16.6)], LINE_WIDTH);
            glyph.line(&[(8.2, 13.0), (CENTER, 16.8), (15.8, 13.0)], LINE_WIDTH);
        }
    }
    pixmap
}

struct Glyph<'a> {
    pixmap: &'a mut Pixmap,
    paint: Paint<'static>,
    transform: Transform,
}

impl Glyph<'_> {
    /// Bars of a sound wave, rounded at the ends.
    fn waveform(&mut self) {
        const HEIGHTS: [f32; 7] = [6.0, 12.0, 18.0, 10.0, 15.0, 8.0, 4.0];
        const WIDTH: f32 = 2.0;
        const GAP: f32 = 1.4;
        let mut x = (GRID - (7.0 * WIDTH + 6.0 * GAP)) / 2.0;
        for height in HEIGHTS {
            self.fill_rounded(x, CENTER - height / 2.0, WIDTH, height, WIDTH / 2.0);
            x += WIDTH + GAP;
        }
    }

    /// A microphone in its cradle, on a stand.
    fn microphone(&mut self) {
        self.fill_rounded(8.5, 2.0, 7.0, 12.5, 3.5);
        let mut cradle = PathBuilder::new();
        cradle.move_to(5.5, 10.5);
        cradle.cubic_to(5.5, 14.8, 8.4, 17.6, CENTER, 17.6);
        cradle.cubic_to(15.6, 17.6, 18.5, 14.8, 18.5, 10.5);
        if let Some(path) = cradle.finish() {
            self.pixmap
                .stroke_path(&path, &self.paint, &stroke(LINE_WIDTH), self.transform, None);
        }
        self.line(&[(CENTER, 17.6), (CENTER, 21.0)], LINE_WIDTH);
        self.line(&[(8.5, 21.2), (15.5, 21.2)], LINE_WIDTH);
    }

    /// A triangle with an exclamation mark.
    fn warning(&mut self) {
        let mut triangle = PathBuilder::new();
        triangle.move_to(CENTER, 3.2);
        triangle.line_to(21.4, 19.8);
        triangle.line_to(2.6, 19.8);
        triangle.close();
        if let Some(path) = triangle.finish() {
            self.pixmap
                .stroke_path(&path, &self.paint, &stroke(LINE_WIDTH), self.transform, None);
        }
        self.line(&[(CENTER, 9.0), (CENTER, 13.8)], 2.0);
        self.dot(CENTER, 16.8, 1.2);
    }

    fn ring(&mut self) {
        if let Some(path) = PathBuilder::from_circle(CENTER, CENTER, RING_RADIUS) {
            self.pixmap
                .stroke_path(&path, &self.paint, &stroke(LINE_WIDTH), self.transform, None);
        }
    }

    fn dot(&mut self, x: f32, y: f32, radius: f32) {
        if let Some(path) = PathBuilder::from_circle(x, y, radius) {
            self.pixmap
                .fill_path(&path, &self.paint, FillRule::Winding, self.transform, None);
        }
    }

    fn line(&mut self, points: &[(f32, f32)], width: f32) {
        let mut line = PathBuilder::new();
        for (index, &(x, y)) in points.iter().enumerate() {
            if index == 0 {
                line.move_to(x, y);
            } else {
                line.line_to(x, y);
            }
        }
        if let Some(path) = line.finish() {
            self.pixmap
                .stroke_path(&path, &self.paint, &stroke(width), self.transform, None);
        }
    }

    fn fill_rounded(&mut self, x: f32, y: f32, width: f32, height: f32, radius: f32) {
        if let Some(path) = Rect::from_xywh(x, y, width, height).and_then(|rect| rounded_rect(rect, radius)) {
            self.pixmap
                .fill_path(&path, &self.paint, FillRule::Winding, self.transform, None);
        }
    }
}

fn stroke(width: f32) -> Stroke {
    Stroke {
        width,
        line_cap: LineCap::Round,
        line_join: LineJoin::Round,
        ..Stroke::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Set LT_PANEL_SNAPSHOTS to a folder to see every icon, at 64 px, in both themes.
    #[test]
    fn every_icon_draws_inside_its_square() {
        let folder = std::env::var_os("LT_PANEL_SNAPSHOTS").map(std::path::PathBuf::from);
        for icon in MenuBarIcon::ALL {
            for theme in [Theme::Dark, Theme::Light] {
                let pixmap = draw_pixmap(icon, theme, 64);
                let painted = pixmap.pixels().iter().filter(|pixel| pixel.alpha() > 128).count();
                assert!(painted > 150, "{icon:?} paints something: {painted} pixels");
                for (x, y) in [(0, 0), (63, 0), (0, 63), (63, 63)] {
                    assert_eq!(pixmap.pixel(x, y).map(|pixel| pixel.alpha()), Some(0), "{icon:?}");
                }
                if let Some(folder) = &folder {
                    std::fs::create_dir_all(folder).expect("the snapshot folder");
                    let file = folder.join(format!("tray-{icon:?}-{theme:?}.png").to_lowercase());
                    pixmap.save_png(file).expect("a snapshot");
                }
            }
        }
    }

    #[test]
    fn the_icons_tell_the_states_apart() {
        let images: Vec<_> = MenuBarIcon::ALL
            .into_iter()
            .map(|icon| draw_icon(icon, Theme::Dark, 32).rgba)
            .collect();
        for (index, image) in images.iter().enumerate() {
            assert!(images[index + 1..].iter().all(|other| other != image));
        }
    }

    #[test]
    fn the_colour_follows_the_theme_and_is_not_premultiplied() {
        let dark = draw_icon(MenuBarIcon::Microphone, Theme::Dark, 32);
        let light = draw_icon(MenuBarIcon::Microphone, Theme::Light, 32);
        assert_eq!(dark.rgba.len(), 32 * 32 * 4);
        let solid = |image: &IconImage| {
            image
                .rgba
                .as_chunks::<4>()
                .0
                .iter()
                .find(|pixel| pixel[3] == 240)
                .map(|pixel| pixel[0])
        };
        assert_eq!(solid(&dark), Some(255), "white on a dark panel");
        assert_eq!(solid(&light), Some(29), "near black on a light one");
    }
}
