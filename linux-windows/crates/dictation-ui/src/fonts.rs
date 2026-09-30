//! Finding the desktop's interface font for the panel: COSMIC's choice where there is one, and
//! Segoe UI on Windows, then common sans-serif faces. Inside a toolbox, the host's fonts count too.

use std::fmt;
use std::path::PathBuf;

use ab_glyph::FontVec;
use fontdb::{Database, Family, Query, Stretch, Style, Weight};

use crate::Typeface;

/// Tried in order after COSMIC's interface font.
const FALLBACK_FAMILIES: [&str; 9] = [
    "Open Sans",
    "Noto Sans",
    "Cantarell",
    "Adwaita Sans",
    "Segoe UI",
    "Helvetica Neue",
    "Arial",
    "DejaVu Sans",
    "Liberation Sans",
];

#[derive(Debug)]
pub enum FontError {
    NotFound,
    Unreadable(String),
}

impl fmt::Display for FontError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound => formatter.write_str("no sans-serif font was found for the dictation panel"),
            Self::Unreadable(detail) => write!(formatter, "the dictation panel's font couldn't be read: {detail}"),
        }
    }
}

impl std::error::Error for FontError {}

pub fn load_interface_font() -> Result<Typeface, FontError> {
    let mut database = Database::new();
    database.load_system_fonts();
    for directory in extra_font_directories() {
        if directory.is_dir() {
            database.load_fonts_dir(directory);
        }
    }
    let configured = interface_family();
    let names = configured.iter().map(String::as_str).chain(FALLBACK_FAMILIES);
    let families: Vec<Family<'_>> = names.map(Family::Name).chain([Family::SansSerif]).collect();
    for family in &families {
        let query = Query {
            families: std::slice::from_ref(family),
            weight: Weight::NORMAL,
            stretch: Stretch::Normal,
            style: Style::Normal,
        };
        let Some(id) = database.query(&query) else {
            continue;
        };
        let font = database
            .with_face_data(id, |data, index| FontVec::try_from_vec_and_index(data.to_vec(), index))
            .ok_or(FontError::NotFound)?
            .map_err(|error| FontError::Unreadable(error.to_string()))?;
        tracing::info!("The dictation panel uses {family:?}");
        return Ok(Typeface::new(font));
    }
    Err(FontError::NotFound)
}

/// The host's fonts, seen from inside a toolbox, and the user's own.
fn extra_font_directories() -> Vec<PathBuf> {
    let mut directories = vec![PathBuf::from("/run/host/usr/share/fonts")];
    directories.extend(dirs::data_dir().map(|data| data.join("fonts")));
    directories
}

/// Windows' own interface font.
#[cfg(windows)]
fn interface_family() -> Option<String> {
    Some("Segoe UI".to_owned())
}

/// The family in COSMIC's interface font setting, a RON record such as
/// `(family: "Open Sans", weight: Normal, …)`.
#[cfg(not(windows))]
fn interface_family() -> Option<String> {
    let path = dirs::config_dir()?.join("cosmic/com.system76.CosmicTk/v1/interface_font");
    family_in(&std::fs::read_to_string(path).ok()?)
}

#[cfg(any(not(windows), test))]
fn family_in(setting: &str) -> Option<String> {
    let start = setting.find("family:")? + "family:".len();
    let rest = setting[start..].trim_start().strip_prefix('"')?;
    let family = &rest[..rest.find('"')?];
    (!family.is_empty()).then(|| family.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_family_from_cosmics_setting() {
        let setting =
            "(\n    family: \"Open Sans\",\n    weight: Normal,\n    stretch: Normal,\n    style: Normal,\n)\n";
        assert_eq!(family_in(setting).as_deref(), Some("Open Sans"));
        assert_eq!(family_in("(weight: Normal)"), None);
        assert_eq!(family_in("(family: \"\")"), None);
    }
}
