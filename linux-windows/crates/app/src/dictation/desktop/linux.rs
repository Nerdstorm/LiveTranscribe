//! The desktop on Linux: the app's Wayland session (lt-wayland), which types through the input
//! method or by pasting, and shows the panel as an overlay. It needs a compositor with the
//! protocols typing takes, and the hotkey needs the keyboards to be readable: when either is
//! missing, Settings says why and what to do.

use lt_dictation_ui::{Blocker, PanelContent};
use lt_hotkey::MonitorError;
use lt_insertion::{InsertionConfiguration, InsertionTarget};
use lt_wayland::{SessionConfiguration, SessionError, WaylandSession};

use super::{Desktop, InsertionDone, PanelConfiguration, capitalised};

/// Connects to the compositor, or says why dictation can't type on this desktop.
pub(crate) fn connect(
    insertion: InsertionConfiguration,
    panel: Option<PanelConfiguration>,
) -> Result<Box<dyn Desktop>, Blocker> {
    let session = WaylandSession::connect(SessionConfiguration {
        insertion,
        panel: panel.map(|panel| lt_wayland::PanelConfiguration {
            view: panel.view,
            level: panel.level,
        }),
    })
    .map_err(|error| desktop_blocker(&error))?;
    Ok(Box::new(session))
}

impl Desktop for WaylandSession {
    fn target(&self) -> InsertionTarget {
        WaylandSession::target(self)
    }

    fn prepare(&self) {
        WaylandSession::prepare(self);
    }

    fn insert(&self, text: String, done: InsertionDone) {
        WaylandSession::insert(self, text, move |result| {
            done(result.map_err(|error| error.to_string()))
        });
    }

    fn copy(&self, text: String) {
        WaylandSession::copy(self, text);
    }

    fn set_insertion(&self, configuration: InsertionConfiguration) {
        WaylandSession::set_insertion(self, configuration);
    }

    fn show_panel(&self, content: Option<PanelContent>) {
        WaylandSession::show_panel(self, content);
    }
}

/// Why the desktop can't take dictated text, and where it can, as Settings says it.
fn desktop_blocker(error: &SessionError) -> Blocker {
    const WHERE: &str = "For now dictation types on COSMIC, Sway and Hyprland; GNOME, KDE Plasma and X11 \
                         desktops come in a later version.";
    let desktop = desktop_name(&std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default());
    Blocker::Desktop(match error {
        SessionError::NoDisplay(_) => {
            format!("{desktop} isn't running on Wayland, which Live Transcribe types through. {WHERE}")
        }
        SessionError::Unsupported { protocol } => {
            format!("{desktop} doesn't let apps {protocol}, which Live Transcribe types with. {WHERE}")
        }
        other => format!("Live Transcribe couldn't connect to the desktop: {other}."),
    })
}

/// Why the hotkey can't be watched, and what to do about it, as Settings says it.
pub(crate) fn hotkey_blocker(error: &MonitorError) -> Blocker {
    Blocker::Hotkey(hotkey_problem(error))
}

/// What's wrong with watching the hotkey, and what allows it, for Settings and `livetranscribe
/// keys`.
pub(crate) fn hotkey_problem(error: &MonitorError) -> String {
    problem_and_remedy(error, std::env::var_os("APPIMAGE").is_some())
}

/// What's wrong with watching the hotkey, and for a keyboard that can't be read, what allows it:
/// the deb's and rpm's udev rule, which the AppImage (`in_appimage`) carries but can't install.
fn problem_and_remedy(error: &MonitorError, in_appimage: bool) -> String {
    let problem = capitalised(&error.to_string());
    if !matches!(error, MonitorError::PermissionDenied { .. }) {
        return format!("{problem}.");
    }
    let remedy = if in_appimage {
        "The AppImage can't allow that itself: README.Linux, in linux-windows/packaging/linux on the \
         project's GitHub, gives the udev rule that does and the commands that add it. Then start \
         Live Transcribe again."
    } else {
        "The deb and rpm packages install a udev rule that allows whoever is logged in at the \
         machine to; with one installed, restart the computer."
    };
    format!("{problem}, which hold-to-talk needs to watch for the hotkey. {remedy}")
}

/// The desktop as people call it, from `XDG_CURRENT_DESKTOP` (such as `ubuntu:GNOME`, `KDE` or
/// `X-Cinnamon`).
fn desktop_name(current_desktop: &str) -> String {
    let names: Vec<&str> = current_desktop
        .split(':')
        .map(|name| name.strip_prefix("X-").unwrap_or(name))
        .filter(|name| !name.is_empty())
        .collect();
    let is = |wanted: &str| names.iter().any(|name| name.eq_ignore_ascii_case(wanted));
    if is("KDE") {
        "KDE Plasma".to_owned()
    } else if is("GNOME") {
        "GNOME".to_owned()
    } else if is("COSMIC") {
        "COSMIC".to_owned()
    } else {
        names
            .last()
            .map_or_else(|| "This desktop".to_owned(), |name| (*name).to_owned())
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    #[test]
    fn desktops_are_named_as_people_know_them() {
        assert_eq!(desktop_name("KDE"), "KDE Plasma");
        assert_eq!(desktop_name("ubuntu:GNOME"), "GNOME");
        assert_eq!(desktop_name("COSMIC"), "COSMIC");
        assert_eq!(desktop_name("X-Cinnamon"), "Cinnamon");
        assert_eq!(desktop_name(""), "This desktop");
    }

    #[test]
    fn an_unsupported_desktop_says_what_it_lacks_and_where_the_app_works() {
        let Blocker::Desktop(detail) = desktop_blocker(&SessionError::Unsupported {
            protocol: "type keys (zwp-virtual-keyboard-v1)",
        }) else {
            panic!("a desktop problem");
        };
        assert!(
            detail.contains("doesn't let apps type keys (zwp-virtual-keyboard-v1)"),
            "{detail}"
        );
        assert!(detail.contains("COSMIC, Sway and Hyprland"), "{detail}");
    }

    #[test]
    fn an_unreadable_keyboard_says_what_allows_reading_it() {
        let denied = MonitorError::PermissionDenied {
            paths: vec![PathBuf::from("/dev/input/event3")],
        };
        let packaged = problem_and_remedy(&denied, false);
        assert!(packaged.starts_with("The keyboard can't be read"), "{packaged}");
        assert!(packaged.contains("/dev/input/event3"), "{packaged}");
        assert!(
            packaged.contains("deb and rpm packages install a udev rule"),
            "{packaged}"
        );
        let appimage = problem_and_remedy(&denied, true);
        assert!(appimage.contains("README.Linux"), "{appimage}");
    }
}
