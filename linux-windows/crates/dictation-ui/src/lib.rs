//! The dictation UI, as the Mac app's DictationUI module has it: the panel that shows while you
//! dictate (DictationHUD, HUDView), and what the menu bar, here the tray, says (MenuBarStatus).
//!
//! The panel is a capsule that shows *Listening* with the microphone's level, *Transcribing…*, or
//! a short message, and never takes the keyboard. [`PanelModel`] decides what it shows and for how
//! long, and [`PanelView`] draws it to pixels at any scale. [`MenuBarStatus`] is the tray's status
//! line, icon and menu, and [`draw_icon`] draws the icon.
//!
//! Platform-free: where the panel goes, how it reaches the screen, and the tray itself are each
//! platform's part (`lt-wayland` and the app on Linux).

mod fonts;
mod menu_bar_status;
mod panel_model;
mod panel_view;
mod text;
mod theme;
mod tray_icon;

pub use fonts::{FontError, load_interface_font};
pub use menu_bar_status::{MenuBarIcon, MenuBarIndicator, MenuBarStatus, ModelState, shortened};
pub use panel_model::{PanelContent, PanelModel};
pub use panel_view::{Animation, Margins, PanelView, Rendered};
pub use text::Typeface;
pub use theme::Theme;
pub use tray_icon::{IconImage, draw_icon};
