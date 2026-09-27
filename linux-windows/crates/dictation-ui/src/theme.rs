//! The panel's colours, after the Mac HUD's: a translucent capsule, primary and secondary text,
//! a red level meter and an orange warning.

use tiny_skia::Color;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Theme {
    Dark,
    Light,
}

pub(crate) struct Palette {
    pub background: Color,
    pub border: Color,
    pub shadow: Color,
    pub primary: Color,
    pub secondary: Color,
    /// Unlit meter bars.
    pub quaternary: Color,
    pub meter: Color,
    pub warning: Color,
}

impl Theme {
    /// The desktop's light or dark mode: COSMIC's setting where there is one, dark otherwise.
    pub fn detect() -> Self {
        let setting = dirs::config_dir()
            .map(|config| config.join("cosmic/com.system76.CosmicTheme.Mode/v1/is_dark"))
            .and_then(|path| std::fs::read_to_string(path).ok());
        match setting.as_deref().map(str::trim) {
            Some("false") => Self::Light,
            _ => Self::Dark,
        }
    }

    pub(crate) fn palette(self) -> Palette {
        match self {
            Self::Dark => Palette {
                background: rgba(38, 38, 40, 0.96),
                border: rgba(255, 255, 255, 0.12),
                shadow: rgba(0, 0, 0, 0.22),
                primary: rgba(255, 255, 255, 0.94),
                secondary: rgba(235, 235, 245, 0.62),
                quaternary: rgba(255, 255, 255, 0.18),
                meter: rgba(255, 69, 58, 1.0),
                warning: rgba(255, 159, 10, 1.0),
            },
            Self::Light => Palette {
                background: rgba(248, 248, 248, 0.97),
                border: rgba(0, 0, 0, 0.12),
                shadow: rgba(0, 0, 0, 0.14),
                primary: rgba(0, 0, 0, 0.86),
                secondary: rgba(60, 60, 67, 0.64),
                quaternary: rgba(0, 0, 0, 0.12),
                meter: rgba(255, 59, 48, 1.0),
                warning: rgba(255, 149, 0, 1.0),
            },
        }
    }
}

fn rgba(red: u8, green: u8, blue: u8, alpha: f32) -> Color {
    Color::from_rgba8(red, green, blue, (alpha * 255.0).round() as u8)
}
