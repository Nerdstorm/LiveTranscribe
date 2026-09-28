//! What the tray says about dictation, as the Mac's MenuBarStatus says it in the menu bar. The
//! status line at the top of the menu, the icon and the icon's tooltip all come from one
//! [`MenuBarIndicator`], so they never disagree; what the menu allows comes from the dictation's
//! phase.
//!
//! Pure, so every combination is tested; the platform's tray only shows it.

use lt_dictation::Phase;

/// Longest error detail shown in the menu. A menu is as wide as its widest item, so a long error
/// would stretch the whole menu.
const DETAIL_LIMIT: usize = 80;

/// Why dictation can't start at all, whatever the model does: something the user can fix, or
/// should know.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Blocker {
    /// The hotkey can't be watched, such as the keyboard not being readable.
    Hotkey(String),
    /// The desktop can't take typed text from the app.
    Desktop(String),
}

/// Where the speech model stands.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ModelState {
    /// Loading, or first downloading, which is `percent` done.
    Loading {
        percent: Option<u8>,
    },
    Ready,
    Failed(String),
}

/// The one thing the tray says about dictation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MenuBarIndicator {
    /// Waiting for the hotkey, named as the user sees it ("Right Ctrl").
    Ready {
        hotkey: String,
    },
    Recording {
        hands_free: bool,
    },
    Processing,
    /// The hotkey couldn't start. Settings says why: too much for a menu item.
    HotkeyFailed,
    /// The desktop can't take typed text from the app. Settings says why.
    DesktopUnsupported,
    /// The speech model failed to load.
    ModelsFailed(String),
    /// The speech model is loading, or first downloading, which is `percent` done.
    ModelsLoading {
        percent: Option<u8>,
    },
    /// The dictation hotkey is turned off in Settings.
    Off,
}

/// The tray's icons, after the Mac's SF Symbols.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MenuBarIcon {
    /// "waveform"
    Waveform,
    /// "mic.fill"
    Microphone,
    /// "ellipsis.circle"
    Ellipsis,
    /// "exclamationmark.triangle"
    Warning,
    /// "arrow.down.circle"
    Loading,
    /// "mic.slash"
    MicrophoneOff,
}

impl MenuBarIcon {
    pub const ALL: [Self; 6] = [
        Self::Waveform,
        Self::Microphone,
        Self::Ellipsis,
        Self::Warning,
        Self::Loading,
        Self::MicrophoneOff,
    ];
}

impl MenuBarIndicator {
    /// A dictation in progress comes first (one started from the menu runs with the hotkey off),
    /// then the hotkey turned off, then what stops dictation starting, then the speech model, then
    /// the hotkey. `hotkey` is its name, or `None` when dictation is turned off in Settings.
    ///
    /// Turned off outranks the rest, as on the Mac: fixing a problem or loading the model wouldn't
    /// turn it back on.
    pub fn new(phase: Phase, model: &ModelState, hotkey: Option<&str>, blocker: Option<&Blocker>) -> Self {
        match phase {
            Phase::Recording { hands_free } => return Self::Recording { hands_free },
            Phase::Processing { .. } => return Self::Processing,
            Phase::Idle => {}
        }
        let Some(hotkey) = hotkey else {
            return Self::Off;
        };
        match blocker {
            Some(Blocker::Hotkey(_)) => return Self::HotkeyFailed,
            Some(Blocker::Desktop(_)) => return Self::DesktopUnsupported,
            None => {}
        }
        match model {
            ModelState::Loading { percent } => Self::ModelsLoading { percent: *percent },
            ModelState::Failed(detail) => Self::ModelsFailed(detail.clone()),
            ModelState::Ready => Self::Ready {
                hotkey: hotkey.to_owned(),
            },
        }
    }

    /// The status line at the top of the menu.
    pub fn status_text(&self) -> String {
        match self {
            Self::Ready { hotkey } => format!("Hold {hotkey} to dictate"),
            Self::Recording { hands_free: true } => "Listening, hands-free…".to_owned(),
            Self::Recording { hands_free: false } => "Listening…".to_owned(),
            Self::Processing => "Transcribing…".to_owned(),
            Self::HotkeyFailed => "The dictation shortcut couldn't start: see Settings".to_owned(),
            Self::DesktopUnsupported => "Dictation can't type on this desktop yet: see Settings".to_owned(),
            Self::ModelsFailed(detail) => format!("Speech-to-text isn't available: {}", shortened(detail)),
            Self::ModelsLoading { percent: Some(percent) } => format!("Downloading speech models… {percent}%"),
            Self::ModelsLoading { percent: None } => "Loading speech models…".to_owned(),
            Self::Off => "Dictation is off".to_owned(),
        }
    }

    pub fn icon(&self) -> MenuBarIcon {
        match self {
            Self::Ready { .. } => MenuBarIcon::Waveform,
            Self::Recording { .. } => MenuBarIcon::Microphone,
            Self::Processing => MenuBarIcon::Ellipsis,
            Self::HotkeyFailed | Self::DesktopUnsupported | Self::ModelsFailed(_) => MenuBarIcon::Warning,
            Self::ModelsLoading { .. } => MenuBarIcon::Loading,
            Self::Off => MenuBarIcon::MicrophoneOff,
        }
    }

    /// What the icon's tooltip, and a screen reader, say.
    pub fn accessibility_label(&self) -> String {
        let state = match self {
            Self::Ready { .. } => "ready",
            Self::Recording { .. } => "listening",
            Self::Processing => "transcribing",
            Self::HotkeyFailed | Self::DesktopUnsupported | Self::ModelsFailed(_) => "needs attention",
            Self::ModelsLoading { .. } => "loading speech models",
            Self::Off => "dictation off",
        };
        format!("Live Transcribe, {state}")
    }

    /// Something is wrong that the user can fix.
    pub fn needs_attention(&self) -> bool {
        matches!(
            self,
            Self::HotkeyFailed | Self::DesktopUnsupported | Self::ModelsFailed(_)
        )
    }
}

/// Everything the menu shows and allows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MenuBarStatus {
    pub indicator: MenuBarIndicator,
    /// "Start Dictation" or "Stop Dictation".
    pub toggle_title: &'static str,
    pub can_toggle_dictation: bool,
    /// *Cancel Dictation* has something to cancel.
    pub can_cancel: bool,
    /// *Copy Last Dictation* has something to copy.
    pub can_copy_last_dictation: bool,
}

impl MenuBarStatus {
    /// `hotkey`: its name, or `None` when dictation is turned off in Settings, which leaves the
    /// menu's *Start Dictation* working. `has_last_dictation`: the controller has a last dictation
    /// to copy. `blocker`: why dictation can't start at all, if it can't.
    pub fn new(
        phase: Phase,
        model: &ModelState,
        hotkey: Option<&str>,
        has_last_dictation: bool,
        blocker: Option<&Blocker>,
    ) -> Self {
        let (toggle_title, can_toggle_dictation, can_cancel) = match phase {
            // Without the model the controller would refuse; disabling says so before the click.
            Phase::Idle => (
                "Start Dictation",
                *model == ModelState::Ready && blocker.is_none(),
                false,
            ),
            Phase::Recording { .. } => ("Stop Dictation", true, true),
            Phase::Processing { .. } => ("Stop Dictation", false, true),
        };
        Self {
            indicator: MenuBarIndicator::new(phase, model, hotkey, blocker),
            toggle_title,
            can_toggle_dictation,
            can_cancel,
            can_copy_last_dictation: has_last_dictation,
        }
    }
}

/// `text` on one line, cut at [`DETAIL_LIMIT`] characters with an ellipsis.
pub fn shortened(text: &str) -> String {
    let single_line = text.lines().collect::<Vec<_>>().join(" ");
    if single_line.chars().count() <= DETAIL_LIMIT {
        return single_line;
    }
    let cut: String = single_line.chars().take(DETAIL_LIMIT - 1).collect();
    format!("{}…", cut.trim_end())
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOTKEY: &str = "Right Ctrl";

    fn status(phase: Phase, model: &ModelState) -> MenuBarStatus {
        MenuBarStatus::new(phase, model, Some(HOTKEY), true, None)
    }

    #[test]
    fn ready_names_the_hotkey() {
        let ready = status(Phase::Idle, &ModelState::Ready);
        assert_eq!(ready.indicator.status_text(), "Hold Right Ctrl to dictate");
        assert_eq!(ready.indicator.icon(), MenuBarIcon::Waveform);
        assert_eq!(ready.indicator.accessibility_label(), "Live Transcribe, ready");
    }

    #[test]
    fn a_dictation_in_progress_outranks_everything_else() {
        let failed = ModelState::Failed("x".to_owned());
        let busy = status(Phase::Recording { hands_free: true }, &failed);
        assert_eq!(busy.indicator, MenuBarIndicator::Recording { hands_free: true });
        assert_eq!(busy.indicator.status_text(), "Listening, hands-free…");
        assert_eq!(
            status(Phase::Recording { hands_free: false }, &ModelState::Ready)
                .indicator
                .status_text(),
            "Listening…"
        );
        let processing = status(
            Phase::Processing { audio_ms: 900 },
            &ModelState::Loading { percent: None },
        );
        assert_eq!(processing.indicator.status_text(), "Transcribing…");
        assert_eq!(processing.indicator.icon(), MenuBarIcon::Ellipsis);
    }

    #[test]
    fn the_model_comes_before_the_hotkey() {
        let loading = status(Phase::Idle, &ModelState::Loading { percent: None });
        assert_eq!(loading.indicator.status_text(), "Loading speech models…");
        assert_eq!(loading.indicator.icon(), MenuBarIcon::Loading);
        assert!(!loading.can_toggle_dictation, "nothing to dictate with yet");

        let downloading = status(Phase::Idle, &ModelState::Loading { percent: Some(42) });
        assert_eq!(downloading.indicator.status_text(), "Downloading speech models… 42%");
        assert_eq!(
            downloading.indicator.icon(),
            MenuBarIcon::Loading,
            "progress changes the text only"
        );
        assert_eq!(
            downloading.indicator.accessibility_label(),
            "Live Transcribe, loading speech models"
        );

        let failed = status(Phase::Idle, &ModelState::Failed("no such folder".to_owned()));
        assert_eq!(
            failed.indicator.status_text(),
            "Speech-to-text isn't available: no such folder"
        );
        assert_eq!(failed.indicator.icon(), MenuBarIcon::Warning);
        assert!(failed.indicator.needs_attention());
        assert_eq!(
            failed.indicator.accessibility_label(),
            "Live Transcribe, needs attention"
        );
    }

    #[test]
    fn what_stops_dictation_outranks_the_model_but_not_dictation_turned_off() {
        let keyboard = Blocker::Hotkey("the keyboard can't be read".to_owned());
        let blocked = MenuBarStatus::new(
            Phase::Idle,
            &ModelState::Loading { percent: Some(3) },
            Some(HOTKEY),
            false,
            Some(&keyboard),
        );
        assert_eq!(
            blocked.indicator.status_text(),
            "The dictation shortcut couldn't start: see Settings"
        );
        assert_eq!(blocked.indicator.icon(), MenuBarIcon::Warning);
        assert!(blocked.indicator.needs_attention());
        assert!(!blocked.can_toggle_dictation, "there's nothing to dictate with");

        let desktop = Blocker::Desktop("KDE Plasma has no virtual keyboard".to_owned());
        let unsupported = MenuBarStatus::new(Phase::Idle, &ModelState::Ready, Some(HOTKEY), false, Some(&desktop));
        assert_eq!(
            unsupported.indicator.status_text(),
            "Dictation can't type on this desktop yet: see Settings"
        );
        assert!(!unsupported.can_toggle_dictation);

        let off = MenuBarStatus::new(Phase::Idle, &ModelState::Ready, None, false, Some(&desktop));
        assert_eq!(off.indicator, MenuBarIndicator::Off);
    }

    #[test]
    fn the_menu_follows_the_phase() {
        let idle = status(Phase::Idle, &ModelState::Ready);
        assert_eq!(
            (idle.toggle_title, idle.can_toggle_dictation, idle.can_cancel),
            ("Start Dictation", true, false)
        );
        let recording = status(Phase::Recording { hands_free: false }, &ModelState::Ready);
        assert_eq!(
            (
                recording.toggle_title,
                recording.can_toggle_dictation,
                recording.can_cancel
            ),
            ("Stop Dictation", true, true)
        );
        let processing = status(Phase::Processing { audio_ms: 900 }, &ModelState::Ready);
        assert_eq!(
            (
                processing.toggle_title,
                processing.can_toggle_dictation,
                processing.can_cancel
            ),
            ("Stop Dictation", false, true)
        );
        assert!(
            !MenuBarStatus::new(Phase::Idle, &ModelState::Ready, Some(HOTKEY), false, None).can_copy_last_dictation
        );
    }

    #[test]
    fn dictation_turned_off_outranks_the_model_but_not_a_dictation_from_the_menu() {
        for model in [
            ModelState::Ready,
            ModelState::Loading { percent: None },
            ModelState::Loading { percent: Some(5) },
            ModelState::Failed("x".to_owned()),
        ] {
            let off = MenuBarStatus::new(Phase::Idle, &model, None, false, None);
            assert_eq!(off.indicator, MenuBarIndicator::Off, "{model:?}");
        }
        let off = MenuBarStatus::new(Phase::Idle, &ModelState::Ready, None, false, None);
        assert_eq!(off.indicator.status_text(), "Dictation is off");
        assert_eq!(off.indicator.icon(), MenuBarIcon::MicrophoneOff);
        assert_eq!(off.indicator.accessibility_label(), "Live Transcribe, dictation off");
        assert!(!off.indicator.needs_attention());
        assert!(off.can_toggle_dictation, "the menu still starts a dictation");
        let recording = MenuBarStatus::new(
            Phase::Recording { hands_free: true },
            &ModelState::Ready,
            None,
            false,
            None,
        );
        assert_eq!(recording.indicator, MenuBarIndicator::Recording { hands_free: true });
    }

    #[test]
    fn icons_tell_the_states_apart() {
        let icons = [
            MenuBarIndicator::Ready {
                hotkey: HOTKEY.to_owned(),
            },
            MenuBarIndicator::Recording { hands_free: false },
            MenuBarIndicator::Processing,
            MenuBarIndicator::ModelsFailed("x".to_owned()),
            MenuBarIndicator::ModelsLoading { percent: None },
            MenuBarIndicator::Off,
        ]
        .map(|indicator| indicator.icon());
        assert_eq!(icons, MenuBarIcon::ALL);
    }

    #[test]
    fn long_details_are_cut_to_one_line() {
        assert_eq!(shortened("first\nsecond"), "first second");
        let long = "word ".repeat(40);
        let cut = shortened(&long);
        assert_eq!(cut.chars().count(), DETAIL_LIMIT, "the ellipsis included");
        assert!(cut.ends_with("word…"));
        assert_eq!(shortened("short"), "short");
    }
}
