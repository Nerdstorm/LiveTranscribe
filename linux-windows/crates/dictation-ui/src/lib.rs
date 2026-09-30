//! The dictation UI, as the Mac app's DictationUI module has it: the panel that shows while you
//! dictate (DictationHUD, HUDView), and what the menu bar, here the tray, says (MenuBarStatus).
//!
//! The panel is a small circle by the mouse pointer that shows the microphone's level while you
//! speak and a spinning ring while the speech is transcribed, with a bubble beside it only when
//! something needs your attention. It never takes the keyboard or clicks. [`PanelModel`] decides
//! what it shows and for how long, [`PanelView`] draws it to pixels at any scale, and
//! [`PanelPlacement`] puts it by the pointer. [`MenuBarStatus`] is the tray's status line, icon
//! and menu, and [`draw_icon`] draws the icon.
//!
//! Platform-free, but for the desktop's light or dark mode and its interface font: where the
//! pointer is, how the panel reaches the screen, and the tray itself are each platform's part
//! (`lt-wayland` and the app on Linux, the app on Windows).

mod fonts;
mod menu_bar_status;
mod panel_model;
mod panel_placement;
mod panel_view;
mod text;
mod theme;
mod tray_icon;

pub use fonts::{FontError, load_interface_font};
pub use menu_bar_status::{Blocker, MenuBarIcon, MenuBarIndicator, MenuBarStatus, ModelState, shortened};
pub use panel_model::{Indicator, PanelContent, PanelModel};
pub use panel_placement::PanelPlacement;
pub use panel_view::{Animation, BubbleSide, CIRCLE_SQUARE, PanelView, Rendered};
pub use text::Typeface;
pub use theme::Theme;
pub use tray_icon::{IconImage, draw_icon};
