//! The tray icon and its menu, as the Mac app's menu bar extra (MenuBarContent) has them: the
//! status line, Start or Stop Dictation, Cancel Dictation, Copy Last Dictation, the Cleanup level,
//! Settings and Quit. Tauri owns the main thread, the menu and the Settings window; the engine's
//! status arrives from its thread, and the menu's choices go back to it as messages, or as changed
//! settings. The icon is drawn for the desktop's light or dark mode each time it changes.

use std::cell::Cell;
use std::sync::Arc;
use std::sync::mpsc::Sender;

use anyhow::Context;
use lt_dictation_ui::{Blocker, MenuBarIcon, MenuBarStatus, ModelState, Theme, draw_icon};
use lt_shared::CleanupLevel;
use serde_json::{Map, Value};
use tauri::image::Image;
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::{TrayIcon, TrayIconBuilder};
use tauri::{AppHandle, RunEvent, Wry};

use super::engine::{DictationStatus, MenuCommand, Message, StatusSink};
use crate::settings::{self, AppControl, BlockerView, SettingsService, StatusView, WindowState};
use crate::speech_models::{SpeechModelLibrary, Stage};

/// Pixels on a side of the tray icon; the tray scales it to fit.
const ICON_SIZE: u32 = 64;

/// Runs the app's main loop with the tray in it, calling `start` once the tray is up. Returns
/// only if the tray can't start: quitting ends the process.
///
/// `blocked`: dictation can't start, so Settings opens at once to say why, and closing it quits,
/// since there's nothing to leave running (and GNOME shows no tray to quit from).
pub(crate) fn run(
    messages: Sender<Message>,
    settings: Arc<SettingsService>,
    library: Arc<SpeechModelLibrary>,
    control: Box<dyn AppControl>,
    blocked: bool,
    start: impl FnOnce(StatusSink) + Send + 'static,
) -> anyhow::Result<()> {
    let app = tauri::Builder::default()
        .manage(WindowState::new(Arc::clone(&settings), Arc::clone(&library), control))
        .invoke_handler(settings::commands())
        .setup(move |app| {
            settings::follow_changes(app.handle(), &settings, &library);
            let tray = Tray::build(app.handle(), messages, settings)?;
            let handle = app.handle().clone();
            start(Box::new(move |status| {
                tray.show(status);
                settings::show_status(&handle, status_view(status));
            }));
            if blocked && let Err(error) = settings::open_window(app.handle()) {
                tracing::error!("Couldn't open the Settings window: {error}");
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .context("couldn't start the tray")?;
    app.run(move |_, event| {
        // Closing the Settings window leaves the app running in the tray.
        if let RunEvent::ExitRequested { code: None, api, .. } = event
            && !blocked
        {
            api.prevent_exit();
        }
    });
    Ok(())
}

/// How dictation stands, for the Settings window.
fn status_view(status: &DictationStatus) -> StatusView {
    let blocker = status.blocker.as_ref().map(|blocker| match blocker {
        Blocker::Hotkey(detail) => BlockerView {
            title: "The dictation shortcut couldn’t start",
            detail: detail.clone(),
        },
        Blocker::Desktop(detail) => BlockerView {
            title: "Dictation can’t type on this desktop yet",
            detail: detail.clone(),
        },
    });
    if blocker.is_some() {
        // The model isn't loaded while dictation can't start.
        return StatusView {
            model: "idle",
            detail: None,
            model_id: None,
            percent: None,
            blocker,
        };
    }
    let name = status.model_name.clone().unwrap_or_default();
    let (model, detail, percent) = match (&status.model, status.download) {
        (ModelState::Loading { .. }, Some(progress)) => {
            let percent = progress.percent();
            let (stage, detail) = match progress.stage {
                Stage::Downloading => (
                    "downloading",
                    format!("{percent}% of {:.1} GB: {name}", progress.total as f64 / 1e9),
                ),
                Stage::Unpacking => ("unpacking", format!("{percent}%: {name}")),
                Stage::Checking => (
                    "checking",
                    format!("{percent}% of {:.1} GB: {name}", progress.total as f64 / 1e9),
                ),
            };
            (stage, Some(detail), Some(percent))
        }
        (ModelState::Loading { .. }, None) => ("loading", Some(name), None),
        (ModelState::Ready, _) => (
            "ready",
            Some(match &status.placement {
                Some(placement) => format!("{name}: {placement}"),
                None => name,
            }),
            None,
        ),
        (ModelState::Failed(error), _) => ("failed", Some(error.clone()), None),
    };
    StatusView {
        model,
        detail,
        model_id: status.model_id.clone(),
        percent,
        blocker: None,
    }
}

struct Tray {
    icon: TrayIcon,
    status: MenuItem<Wry>,
    toggle: MenuItem<Wry>,
    cancel: MenuItem<Wry>,
    copy: MenuItem<Wry>,
    levels: Vec<(CleanupLevel, CheckMenuItem<Wry>)>,
    /// The icon showing, and the mode it was drawn for.
    drawn: Cell<Option<(MenuBarIcon, Theme)>>,
}

impl Tray {
    fn build(app: &AppHandle, messages: Sender<Message>, settings: Arc<SettingsService>) -> tauri::Result<Self> {
        let cleanup = settings.current().0.cleanup_level;
        let status = MenuItem::with_id(app, "status", "Loading speech models…", false, None::<&str>)?;
        let toggle = MenuItem::with_id(app, "toggle", "Start Dictation", false, None::<&str>)?;
        let cancel = MenuItem::with_id(app, "cancel", "Cancel Dictation", false, None::<&str>)?;
        let copy = MenuItem::with_id(app, "copy", "Copy Last Dictation", false, None::<&str>)?;
        let levels = CleanupLevel::ALL
            .into_iter()
            .map(|level| {
                CheckMenuItem::with_id(
                    app,
                    cleanup_id(level),
                    level.display_name(),
                    true,
                    level == cleanup,
                    None::<&str>,
                )
                .map(|item| (level, item))
            })
            .collect::<tauri::Result<Vec<_>>>()?;
        let level_items: Vec<&dyn IsMenuItem<Wry>> =
            levels.iter().map(|(_, item)| item as &dyn IsMenuItem<Wry>).collect();
        let cleanup_menu = Submenu::with_id_and_items(app, "cleanup", "Cleanup", true, &level_items)?;
        let open_settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
        let quit = MenuItem::with_id(app, "quit", "Quit Live Transcribe", true, None::<&str>)?;
        let menu = Menu::with_items(
            app,
            &[
                &status,
                &PredefinedMenuItem::separator(app)?,
                &toggle,
                &cancel,
                &copy,
                &PredefinedMenuItem::separator(app)?,
                &cleanup_menu,
                &open_settings,
                &PredefinedMenuItem::separator(app)?,
                &quit,
            ],
        )?;
        let choices = levels.clone();
        let theme = Theme::detect();
        let icon = TrayIconBuilder::with_id("live-transcribe")
            .icon(icon_image(MenuBarIcon::Loading, theme))
            .tooltip("Live Transcribe, loading speech models")
            .menu(&menu)
            .show_menu_on_left_click(true)
            .on_menu_event(move |app, event| {
                let command = match event.id().as_ref() {
                    "toggle" => Some(MenuCommand::Toggle),
                    "cancel" => Some(MenuCommand::Cancel),
                    "copy" => Some(MenuCommand::CopyLast),
                    "settings" => {
                        if let Err(error) = settings::open_window(app) {
                            tracing::error!("Couldn't open the Settings window: {error}");
                        }
                        None
                    }
                    "quit" => {
                        app.exit(0);
                        None
                    }
                    id => {
                        if let Some((level, _)) = choices.iter().find(|(level, _)| id == cleanup_id(*level)) {
                            choose_cleanup(&settings, &choices, *level);
                        }
                        None
                    }
                };
                if let Some(command) = command {
                    let _ = messages.send(Message::Menu(command));
                }
            })
            .build(app)?;
        Ok(Self {
            icon,
            status,
            toggle,
            cancel,
            copy,
            levels,
            drawn: Cell::new(Some((MenuBarIcon::Loading, theme))),
        })
    }

    fn show(&self, status: &DictationStatus) {
        let menu = &MenuBarStatus::new(
            status.phase,
            &status.model,
            status.hotkey.as_deref(),
            status.has_last_dictation,
            status.blocker.as_ref(),
        );
        let indicator = &menu.indicator;
        let mut results = vec![
            self.status.set_text(indicator.status_text()),
            self.toggle.set_text(menu.toggle_title),
            self.toggle.set_enabled(menu.can_toggle_dictation),
            self.cancel.set_enabled(menu.can_cancel),
            self.copy.set_enabled(menu.can_copy_last_dictation),
            self.icon.set_tooltip(Some(indicator.accessibility_label())),
        ];
        // Drawn again only when it changes, or the desktop has changed mode since.
        let wanted = (indicator.icon(), Theme::detect());
        if self.drawn.get() != Some(wanted) {
            results.push(self.icon.set_icon(Some(icon_image(wanted.0, wanted.1))));
            self.drawn.set(Some(wanted));
        }
        results.extend(
            self.levels
                .iter()
                .map(|(level, item)| item.set_checked(*level == status.cleanup)),
        );
        for error in results.into_iter().filter_map(Result::err) {
            tracing::warn!("Couldn't update the tray: {error}");
        }
    }
}

/// Saves the cleanup level chosen in the menu, which tells dictation and the Settings window.
fn choose_cleanup(settings: &SettingsService, choices: &[(CleanupLevel, CheckMenuItem<Wry>)], chosen: CleanupLevel) {
    let mut change = Map::new();
    change.insert("cleanupLevel".to_owned(), Value::from(chosen.as_str()));
    let level = match settings.change(&change) {
        Ok(settings) => settings.cleanup_level,
        Err(error) => {
            tracing::error!("Couldn't change the cleanup level: {error}");
            settings.current().0.cleanup_level
        }
    };
    // Each item ticks itself when chosen; the rest untick here, so the levels read as one choice.
    for (other, item) in choices {
        if let Err(error) = item.set_checked(*other == level) {
            tracing::warn!("Couldn't update the Cleanup menu: {error}");
        }
    }
}

fn cleanup_id(level: CleanupLevel) -> String {
    format!("cleanup-{}", level.as_str())
}

/// `icon` for the desktop's light or dark mode.
fn icon_image(icon: MenuBarIcon, theme: Theme) -> Image<'static> {
    let image = draw_icon(icon, theme, ICON_SIZE);
    Image::new_owned(image.rgba, image.width, image.height)
}
