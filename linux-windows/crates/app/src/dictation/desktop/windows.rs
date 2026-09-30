//! The desktop on Windows: lt-windows types the text, as Unicode keystrokes, and the panel is a
//! small window of the app's own ([`panel`]). Typing needs no permission and works in every
//! desktop Windows has, so nothing blocks dictation here but the hotkey: an unusable key, or a
//! keyboard hook Windows refused.

mod panel;

use std::sync::{Arc, Mutex, PoisonError};

use lt_dictation_ui::{Blocker, PanelContent};
use lt_hotkey::MonitorError;
use lt_insertion::{InsertionConfiguration, InsertionTarget};
use lt_windows::TypingSession;
use tauri::ipc::{Channel, Invoke, InvokeResponseBody};
use tauri::{AppHandle, State};

use super::{Desktop, InsertionDone, PanelConfiguration, capitalised};

/// Starts typing, and the panel if there is one.
pub(crate) fn connect(
    _insertion: InsertionConfiguration,
    panel: Option<PanelConfiguration>,
) -> Result<Box<dyn Desktop>, Blocker> {
    let typing = TypingSession::start()
        .map_err(|error| Blocker::Desktop(format!("Live Transcribe couldn't start typing: {error}.")))?;
    Ok(Box::new(WindowsDesktop {
        typing,
        panel: panel.map(panel::Panel::start),
    }))
}

struct WindowsDesktop {
    typing: TypingSession,
    panel: Option<panel::Panel>,
}

impl Desktop for WindowsDesktop {
    fn target(&self) -> InsertionTarget {
        self.typing.target()
    }

    fn prepare(&self) {
        // Typing leaves the clipboard alone, so there is nothing to save beforehand.
    }

    fn insert(&self, text: String, done: InsertionDone) {
        self.typing
            .insert(text, move |result| done(result.map_err(|error| error.to_string())));
    }

    fn copy(&self, text: String) {
        self.typing.copy(text);
    }

    fn set_insertion(&self, _configuration: InsertionConfiguration) {
        // The clipboard's timings are for pasting, which typing here never does.
    }

    fn show_panel(&self, content: Option<PanelContent>) {
        if let Some(panel) = &self.panel {
            panel.show(content);
        }
    }

    fn attach(&self, app: &AppHandle) {
        if let Some(panel) = &self.panel {
            panel.attach(app);
        }
    }
}

/// The commands the panel's page calls.
pub(crate) fn panel_commands() -> impl Fn(Invoke) -> bool + Send + Sync + 'static {
    tauri::generate_handler![panel_frames]
}

/// The panel's page asks for its frames here: each one drawn comes down `frames`.
#[tauri::command]
fn panel_frames(frames: Channel<InvokeResponseBody>, screen: State<'_, Screen>) {
    screen.connect(frames);
}

/// Where the panel's frames go: the channel its page opened, while its window is open.
#[derive(Clone, Default)]
struct Screen(Arc<Mutex<Option<Channel<InvokeResponseBody>>>>);

impl Screen {
    fn connect(&self, frames: Channel<InvokeResponseBody>) {
        *self.0.lock().unwrap_or_else(PoisonError::into_inner) = Some(frames);
    }

    /// Sends `frame` to the page; `false` until its page has asked for frames.
    fn send(&self, frame: Vec<u8>) -> bool {
        let channel = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        channel
            .as_ref()
            .is_some_and(|channel| channel.send(InvokeResponseBody::Raw(frame)).is_ok())
    }

    /// Its window has closed: frames wait for the next one's page.
    fn disconnect(&self) {
        *self.0.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }
}

/// Why the hotkey can't be watched, as Settings says it.
pub(crate) fn hotkey_blocker(error: &MonitorError) -> Blocker {
    Blocker::Hotkey(hotkey_problem(error))
}

/// What's wrong with watching the hotkey, for Settings and `livetranscribe keys`.
pub(crate) fn hotkey_problem(error: &MonitorError) -> String {
    let problem = capitalised(&error.to_string());
    match error {
        MonitorError::Hook => format!(
            "{problem}. Another program may be blocking it, such as security software; start Live \
             Transcribe again, or restart the computer."
        ),
        MonitorError::Hotkey(_) => format!("{problem}."),
    }
}

#[cfg(test)]
mod tests {
    use lt_hotkey::UnusableHotkey;

    use super::*;

    #[test]
    fn a_refused_hook_says_what_may_help() {
        let problem = hotkey_problem(&MonitorError::Hook);
        assert!(problem.starts_with("The keyboard can't be watched"), "{problem}");
        assert!(problem.contains("restart the computer"), "{problem}");
    }

    #[test]
    fn an_unusable_hotkey_says_why() {
        let problem = hotkey_problem(&MonitorError::Hotkey(UnusableHotkey::Unwatchable));
        assert!(problem.starts_with("That hotkey can't be used"), "{problem}");
        assert!(problem.ends_with('.'), "{problem}");
    }
}
