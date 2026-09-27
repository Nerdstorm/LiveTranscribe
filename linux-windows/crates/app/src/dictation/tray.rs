//! The tray icon and its menu, as the Mac app's menu bar extra (MenuBarContent) has them: the
//! status line, Start or Stop Dictation, Cancel Dictation, Copy Last Dictation, the Cleanup level,
//! and Quit. Tauri owns the main thread and the menu; the engine's status arrives from its thread,
//! and the menu's choices go back to it as messages. The icon is drawn for the desktop's light or
//! dark mode each time it changes.

use std::cell::Cell;
use std::sync::mpsc::Sender;

use anyhow::Context;
use lt_dictation_ui::{MenuBarIcon, MenuBarStatus, Theme, draw_icon};
use lt_shared::CleanupLevel;
use tauri::image::Image;
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::{TrayIcon, TrayIconBuilder};
use tauri::{AppHandle, RunEvent, Wry};

use super::engine::{MenuCommand, Message};

/// Pixels on a side of the tray icon; the tray scales it to fit.
const ICON_SIZE: u32 = 64;

/// What the tray shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TrayStatus {
    pub(crate) menu: MenuBarStatus,
    pub(crate) cleanup: CleanupLevel,
}

/// Where the engine sends the status, from its thread.
pub(crate) type StatusSink = Box<dyn Fn(&TrayStatus) + Send>;

/// Runs the app's main loop with the tray in it, calling `start` once the tray is up. Returns
/// only if the tray can't start: quitting ends the process.
pub(crate) fn run(
    messages: Sender<Message>,
    cleanup: CleanupLevel,
    start: impl FnOnce(StatusSink) + Send + 'static,
) -> anyhow::Result<()> {
    let app = tauri::Builder::default()
        .setup(move |app| {
            let tray = Tray::build(app.handle(), messages, cleanup)?;
            start(Box::new(move |status| tray.show(status)));
            Ok(())
        })
        .build(tauri::generate_context!())
        .context("couldn't start the tray")?;
    app.run(|_, event| {
        // Closing a window (Settings, one day) leaves the app running in the tray.
        if let RunEvent::ExitRequested { code: None, api, .. } = event {
            api.prevent_exit();
        }
    });
    Ok(())
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
    fn build(app: &AppHandle, messages: Sender<Message>, cleanup: CleanupLevel) -> tauri::Result<Self> {
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
                    "toggle" => Some(MenuCommand::ToggleDictation),
                    "cancel" => Some(MenuCommand::CancelDictation),
                    "copy" => Some(MenuCommand::CopyLastDictation),
                    "quit" => {
                        app.exit(0);
                        None
                    }
                    id => choices
                        .iter()
                        .find(|(level, _)| id == cleanup_id(*level))
                        .map(|(level, _)| {
                            // Each item ticks itself when chosen; the rest untick here, so the
                            // four read as one choice.
                            for (other, item) in &choices {
                                if let Err(error) = item.set_checked(other == level) {
                                    tracing::warn!("Couldn't update the Cleanup menu: {error}");
                                }
                            }
                            MenuCommand::SetCleanup(*level)
                        }),
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

    fn show(&self, status: &TrayStatus) {
        let menu = &status.menu;
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

fn cleanup_id(level: CleanupLevel) -> String {
    format!("cleanup-{}", level.as_str())
}

/// `icon` for the desktop's light or dark mode.
fn icon_image(icon: MenuBarIcon, theme: Theme) -> Image<'static> {
    let image = draw_icon(icon, theme, ICON_SIZE);
    Image::new_owned(image.rgba, image.width, image.height)
}
