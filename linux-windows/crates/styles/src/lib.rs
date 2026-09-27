//! The deterministic text rules the cleanup levels turn on: filler removal, and the layout of
//! spoken lists and letters in fields that take several lines.
//!
//! Each module mirrors the file of the same name in the Mac app's `Styles` module
//! (Packages/LiveTranscribeKit/Sources/Styles).

mod filler_remover;
mod layout;
mod letter_frame;
mod list_formatter;
mod list_layouts;
mod list_marker_command;
mod list_style;

pub use filler_remover::{FillerRemover, STANDARD_FILLERS};
pub use layout::{FrameRule, Layout, LayoutRule, TextFrame};
pub use letter_frame::LetterFrame;
pub use list_formatter::ListFormatter;
pub use list_layouts::{MarkedListLayout, OrdinalListLayout};
pub use list_marker_command::ListMarkerCommand;
pub use list_style::ListStyle;
