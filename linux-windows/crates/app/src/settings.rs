//! Settings: `settings.json`, the service that changes it while the app runs and tells dictation,
//! and the Settings window, a Tauri page, that shows and changes it.

mod model;
mod service;
mod store;
mod window;

pub(crate) use model::Settings;
pub(crate) use service::SettingsService;
pub(crate) use store::SettingsStore;
pub(crate) use window::{
    AppControl, BlockerView, StatusView, WindowState, commands, follow_changes, open_window, show_status,
};
