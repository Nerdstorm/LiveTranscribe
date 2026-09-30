//! The panel's colours, after the Mac HUD's: a translucent circle and bubble, primary and
//! secondary text, a red level and an orange warning.

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
    pub meter: Color,
    pub warning: Color,
}

impl Theme {
    /// The desktop's light or dark mode for apps: COSMIC's setting where there is one, dark
    /// otherwise.
    #[cfg(not(windows))]
    pub fn detect() -> Self {
        let setting = dirs::config_dir()
            .map(|config| config.join("cosmic/com.system76.CosmicTheme.Mode/v1/is_dark"))
            .and_then(|path| std::fs::read_to_string(path).ok());
        match setting.as_deref().map(str::trim) {
            Some("false") => Self::Light,
            _ => Self::Dark,
        }
    }

    /// The desktop's light or dark mode for apps: Windows' app mode (Settings, Personalisation,
    /// Colours), light unless set otherwise, as Windows has it.
    #[cfg(windows)]
    pub fn detect() -> Self {
        windows_mode("AppsUseLightTheme", Self::Light)
    }

    /// The mode of the taskbar, where the tray icon shows. On Windows it is the system's mode,
    /// which can differ from the apps' (a dark taskbar with light apps is Windows' default); on
    /// Linux, the desktop's.
    #[cfg(not(windows))]
    pub fn detect_taskbar() -> Self {
        Self::detect()
    }

    /// The mode of the taskbar, where the tray icon shows: Windows' own mode, dark unless set
    /// otherwise, as Windows has it.
    #[cfg(windows)]
    pub fn detect_taskbar() -> Self {
        windows_mode("SystemUsesLightTheme", Self::Dark)
    }

    pub(crate) fn palette(self) -> Palette {
        match self {
            Self::Dark => Palette {
                background: rgba(38, 38, 40, 0.96),
                border: rgba(255, 255, 255, 0.12),
                shadow: rgba(0, 0, 0, 0.22),
                primary: rgba(255, 255, 255, 0.94),
                secondary: rgba(235, 235, 245, 0.62),
                meter: rgba(255, 69, 58, 1.0),
                warning: rgba(255, 159, 10, 1.0),
            },
            Self::Light => Palette {
                background: rgba(248, 248, 248, 0.97),
                border: rgba(0, 0, 0, 0.12),
                shadow: rgba(0, 0, 0, 0.14),
                primary: rgba(0, 0, 0, 0.86),
                secondary: rgba(60, 60, 67, 0.64),
                meter: rgba(255, 59, 48, 1.0),
                warning: rgba(255, 149, 0, 1.0),
            },
        }
    }
}

/// A mode from Windows' personalisation settings: `value` is 1 for light, 0 for dark, and missing
/// before Windows had the choice.
#[cfg(windows)]
fn windows_mode(value: &str, unset: Theme) -> Theme {
    use winsafe::{HKEY, RegistryValue, co};

    const PERSONALIZE: &str = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    match HKEY::CURRENT_USER.RegGetValue(Some(PERSONALIZE), Some(value), co::RRF::RT_REG_DWORD) {
        Ok(RegistryValue::Dword(0)) => Theme::Dark,
        Ok(RegistryValue::Dword(_)) => Theme::Light,
        _ => unset,
    }
}

fn rgba(red: u8, green: u8, blue: u8, alpha: f32) -> Color {
    Color::from_rgba8(red, green, blue, (alpha * 255.0).round() as u8)
}
