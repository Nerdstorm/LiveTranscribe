//! The tray icon and its menu, as the Mac app's menu bar extra (MenuBarContent) has them: the
//! status line, Start or Stop Dictation, Cancel Dictation, Copy Last Dictation, the Cleanup level,
//! the speech model's Language, Settings and Quit. Tauri owns the main thread, the menu and the Settings window; the engine's
//! status arrives from its thread, and the menu's choices go back to it as messages, or as changed
//! settings. The icon is drawn for the taskbar's light or dark mode (the desktop's, on Linux) each
//! time it changes.

use std::cell::Cell;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, PoisonError};

use anyhow::Context;
use lt_dictation_ui::{Blocker, MenuBarIcon, MenuBarStatus, ModelState, Theme, draw_icon};
use lt_shared::CleanupLevel;
use lt_transcription::catalog::SpeechModel;
use serde_json::{Map, Value};
use tauri::image::Image;
use tauri::ipc::Invoke;
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::{TrayIcon, TrayIconBuilder};
use tauri::{AppHandle, RunEvent, Wry};

use super::engine::{CleanupModelStatus, DictationStatus, MenuCommand, Message, StatusSink};
use crate::settings::{self, AppControl, BlockerView, SettingsService, StatusView, WindowState};
use crate::speech_models::{SpeechModelLibrary, Stage};

/// Pixels on a side of the tray icon; the tray scales it to fit.
const ICON_SIZE: u32 = 64;

/// Runs the app's main loop with the tray in it, calling `start` once the tray is up, with the
/// app's handle for windows of its own. Returns only if the tray can't start: quitting ends the
/// process.
///
/// `blocked`: dictation can't start, so Settings opens at once to say why, and closing it quits,
/// since there's nothing to leave running (and GNOME shows no tray to quit from).
pub(crate) fn run(
    messages: Sender<Message>,
    settings: Arc<SettingsService>,
    library: Arc<SpeechModelLibrary>,
    control: Box<dyn AppControl>,
    blocked: bool,
    start: impl FnOnce(&AppHandle, StatusSink) + Send + 'static,
) -> anyhow::Result<()> {
    let app = tauri::Builder::default()
        .manage(WindowState::new(Arc::clone(&settings), Arc::clone(&library), control))
        .invoke_handler(commands())
        .setup(move |app| {
            settings::follow_changes(app.handle(), &settings, &library);
            let tray = Tray::build(app.handle(), messages, settings, library)?;
            let handle = app.handle().clone();
            start(
                app.handle(),
                Box::new(move |status| {
                    tray.show(status);
                    settings::show_status(&handle, status_view(status));
                }),
            );
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

/// The commands the app's pages call: the Settings window's, and on Windows the dictation
/// panel's, which asks for the frames it shows.
fn commands() -> impl Fn(Invoke) -> bool + Send + Sync + 'static {
    let settings = settings::commands();
    #[cfg(windows)]
    let panel = super::desktop::panel_commands();
    move |invoke: Invoke| {
        #[cfg(windows)]
        if invoke.message.command() == "panel_frames" {
            return panel(invoke);
        }
        settings(invoke)
    }
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
            cleanup_model: "off",
            cleanup_detail: None,
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
    let (cleanup_model, cleanup_detail) = cleanup_model_view(status.cleanup_model.as_ref());
    StatusView {
        model,
        detail,
        model_id: status.model_id.clone(),
        percent,
        cleanup_model,
        cleanup_detail,
        blocker: None,
    }
}

/// How cleanup's language model stands, as Settings › Advanced shows it.
fn cleanup_model_view(status: Option<&CleanupModelStatus>) -> (&'static str, Option<String>) {
    let Some(status) = status else {
        return ("off", None);
    };
    match (&status.state, status.download) {
        (ModelState::Loading { .. }, Some(progress)) => {
            let size = format!("{}% of {:.1} GB", progress.percent(), progress.total as f64 / 1e9);
            match progress.stage {
                Stage::Checking => ("checking", Some(size)),
                Stage::Downloading | Stage::Unpacking => ("downloading", Some(size)),
            }
        }
        (ModelState::Loading { .. }, None) => ("loading", None),
        (ModelState::Ready, _) => ("ready", status.placement.clone()),
        (ModelState::Failed(error), _) => ("failed", Some(error.clone())),
    }
}

struct Tray {
    icon: TrayIcon,
    status: MenuItem<Wry>,
    toggle: MenuItem<Wry>,
    cancel: MenuItem<Wry>,
    copy: MenuItem<Wry>,
    levels: Vec<(CleanupLevel, CheckMenuItem<Wry>)>,
    languages: Arc<Mutex<LanguageMenu>>,
    /// The icon showing, and the mode it was drawn for.
    drawn: Cell<Option<(MenuBarIcon, Theme)>>,
}

impl Tray {
    fn build(
        app: &AppHandle,
        messages: Sender<Message>,
        settings: Arc<SettingsService>,
        library: Arc<SpeechModelLibrary>,
    ) -> tauri::Result<Self> {
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
        let languages = Arc::new(Mutex::new(LanguageMenu::new(app, library)?));
        let language_menu = lock(&languages).submenu.clone();
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
                &language_menu,
                &open_settings,
                &PredefinedMenuItem::separator(app)?,
                &quit,
            ],
        )?;
        let choices = levels.clone();
        let chosen_languages = Arc::clone(&languages);
        let theme = Theme::detect_taskbar();
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
                        } else if let Some(language) = LanguageMenu::setting_of(id) {
                            choose_language(&settings, &chosen_languages, language);
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
            languages,
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
        // Drawn again only when it changes, or the taskbar has changed mode since.
        let wanted = (indicator.icon(), Theme::detect_taskbar());
        if self.drawn.get() != Some(wanted) {
            results.push(self.icon.set_icon(Some(icon_image(wanted.0, wanted.1))));
            self.drawn.set(Some(wanted));
        }
        results.extend(
            self.levels
                .iter()
                .map(|(level, item)| item.set_checked(*level == status.cleanup)),
        );
        results.push(lock(&self.languages).show(status.model_id.as_deref(), status.language.as_deref()));
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

/// The Language submenu, as the Mac's menu bar has it: Automatic, then the languages the speech
/// model in use can be told. It's drawn again when the model changes, and greyed out with
/// Automatic alone for a model that can't be told one (Parakeet) or isn't in the catalog.
struct LanguageMenu {
    app: AppHandle,
    library: Arc<SpeechModelLibrary>,
    submenu: Submenu<Wry>,
    separator: PredefinedMenuItem<Wry>,
    /// The catalog model it was drawn for (`None` for no model, or one outside the catalog);
    /// `None` until it's drawn.
    drawn_for: Option<Option<String>>,
    /// Automatic (`None`), then each language by its code, with its item, as the menu lists them.
    items: Vec<(Option<String>, CheckMenuItem<Wry>)>,
}

impl LanguageMenu {
    const AUTOMATIC: &'static str = "language-automatic";

    fn new(app: &AppHandle, library: Arc<SpeechModelLibrary>) -> tauri::Result<Self> {
        Ok(Self {
            app: app.clone(),
            library,
            submenu: Submenu::with_id(app, "language", "Language", false)?,
            separator: PredefinedMenuItem::separator(app)?,
            drawn_for: None,
            items: Vec::new(),
        })
    }

    /// The Language setting an item's id stands for: `Some(None)` for Automatic, and `None` for
    /// an id that isn't a language's.
    fn setting_of(id: &str) -> Option<Option<String>> {
        if id == Self::AUTOMATIC {
            return Some(None);
        }
        id.strip_prefix("language-").map(|code| Some(code.to_owned()))
    }

    fn id(code: &str) -> String {
        format!("language-{code}")
    }

    /// Lists the languages of the model `model_id` names, drawing the menu again if it was
    /// drawn for another, and ticks the setting's, or Automatic.
    fn show(&mut self, model_id: Option<&str>, setting: Option<&str>) -> tauri::Result<()> {
        if self.drawn_for.as_ref().map(Option::as_deref) != Some(model_id) {
            self.draw(model_id)?;
        }
        self.tick(setting)
    }

    /// Ticks the setting's language if the menu has it, and otherwise Automatic.
    fn tick(&self, setting: Option<&str>) -> tauri::Result<()> {
        let listed = setting.filter(|code| self.items.iter().any(|(item, _)| item.as_deref() == Some(*code)));
        for (code, item) in &self.items {
            item.set_checked(code.as_deref() == listed)?;
        }
        Ok(())
    }

    fn draw(&mut self, model_id: Option<&str>) -> tauri::Result<()> {
        let had_languages = self.items.len() > 1;
        for (_, item) in self.items.drain(..) {
            self.submenu.remove(&item)?;
        }
        if had_languages {
            self.submenu.remove(&self.separator)?;
        }
        let model = model_id.and_then(|id| self.library.catalog().model(id));
        let choices = model.map(|model| model.language_choices.as_slice()).unwrap_or_default();
        let automatic = match model.and_then(SpeechModel::automatic_choice) {
            Some(choice) => format!("Automatic ({})", choice.name),
            None => "Automatic".to_owned(),
        };
        let mut items = vec![(
            None,
            CheckMenuItem::with_id(&self.app, Self::AUTOMATIC, automatic, true, false, None::<&str>)?,
        )];
        for choice in choices {
            let item = CheckMenuItem::with_id(
                &self.app,
                Self::id(&choice.code),
                &choice.name,
                true,
                false,
                None::<&str>,
            )?;
            items.push((Some(choice.code.clone()), item));
        }
        for (index, (_, item)) in items.iter().enumerate() {
            self.submenu.append(item)?;
            if index == 0 && !choices.is_empty() {
                self.submenu.append(&self.separator)?;
            }
        }
        self.submenu.set_enabled(!choices.is_empty())?;
        self.items = items;
        self.drawn_for = Some(model_id.map(str::to_owned));
        Ok(())
    }
}

/// Saves the language chosen in the menu (`None` for Automatic), which tells dictation and the
/// Settings window.
fn choose_language(settings: &SettingsService, menu: &Mutex<LanguageMenu>, chosen: Option<String>) {
    let mut change = Map::new();
    change.insert("sttLanguage".to_owned(), chosen.map_or(Value::Null, Value::from));
    let language = match settings.change(&change) {
        Ok(settings) => settings.stt_language,
        Err(error) => {
            tracing::error!("Couldn't change the language: {error}");
            settings.current().0.stt_language
        }
    };
    // Each item ticks itself when chosen, and unticks when chosen again; the menu reads as one
    // choice once the rest follow.
    if let Err(error) = lock(menu).tick(language.as_deref()) {
        tracing::warn!("Couldn't update the Language menu: {error}");
    }
}

fn lock(menu: &Mutex<LanguageMenu>) -> std::sync::MutexGuard<'_, LanguageMenu> {
    menu.lock().unwrap_or_else(PoisonError::into_inner)
}

/// `icon` for the taskbar's light or dark mode.
fn icon_image(icon: MenuBarIcon, theme: Theme) -> Image<'static> {
    let image = draw_icon(icon, theme, ICON_SIZE);
    Image::new_owned(image.rgba, image.width, image.height)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_language_items_id_is_the_setting_it_stands_for() {
        assert_eq!(LanguageMenu::setting_of(LanguageMenu::AUTOMATIC), Some(None));
        assert_eq!(
            LanguageMenu::setting_of(&LanguageMenu::id("en")),
            Some(Some("en".to_owned()))
        );
        assert_eq!(LanguageMenu::setting_of("cleanup-standard"), None);
    }
}
