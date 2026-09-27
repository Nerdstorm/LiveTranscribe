//! What the dictation flow tells the user, worded as the Mac app's DictationNotice words it.
//!
//! Notices carry counts and error details, never what was said.

use lt_insertion::InsertionMethod;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Notice {
    /// The focused app took the text. For the log: the panel just goes away, as on the Mac.
    Typed {
        characters: usize,
        method: InsertionMethod,
        /// From the end of the recording to the text in the app.
        latency_ms: u64,
    },
    NothingHeard,
    Cancelled,
    /// Nothing took the text, so it was left on the clipboard.
    CopiedToClipboard,
    /// The focused field is a password field: nothing is recorded or typed there.
    SecureField,
    InsertionFailed(String),
    CaptureFailed(String),
    /// The microphone stopped partway through; what was heard before it did was typed.
    CaptureStoppedEarly {
        after_seconds: usize,
    },
    TranscriptionFailed(String),
    RecordingTruncated {
        seconds: u32,
    },
    /// The hotkey was pressed while the last dictation was still on its way, so nothing was
    /// recorded.
    StillProcessing,
}

impl Notice {
    pub fn message(&self) -> String {
        match self {
            Self::Typed {
                characters,
                method,
                latency_ms,
            } => format!(
                "Typed {characters} characters by {}, {}.{} s after the recording ended",
                method.as_str(),
                latency_ms / 1_000,
                latency_ms % 1_000 / 100
            ),
            Self::NothingHeard => "Didn't catch that".to_owned(),
            Self::Cancelled => "Cancelled".to_owned(),
            Self::CopiedToClipboard => "Copied: press Ctrl+V to paste (Ctrl+Shift+V in a terminal)".to_owned(),
            Self::SecureField => "Dictation is off in password fields".to_owned(),
            Self::InsertionFailed(detail) => format!("The text couldn't be typed: {detail}"),
            Self::CaptureFailed(detail) => format!("The microphone stopped: {detail}"),
            Self::CaptureStoppedEarly { after_seconds } => format!(
                "The microphone stopped after {}; the rest wasn't heard",
                duration(*after_seconds)
            ),
            Self::TranscriptionFailed(detail) => format!("Speech-to-text failed: {detail}"),
            Self::RecordingTruncated { seconds } => format!(
                "Recording stopped at {}; the rest wasn't heard",
                duration(*seconds as usize)
            ),
            Self::StillProcessing => "Press again to dictate: the last dictation was still being typed".to_owned(),
        }
    }

    /// Shown in the dictation panel. Text that went in needs no message: the panel just goes.
    pub fn in_panel(&self) -> bool {
        !matches!(self, Self::Typed { .. })
    }

    /// Shown as a problem rather than as information.
    pub fn is_problem(&self) -> bool {
        matches!(
            self,
            Self::SecureField
                | Self::InsertionFailed(_)
                | Self::CaptureFailed(_)
                | Self::CaptureStoppedEarly { .. }
                | Self::TranscriptionFailed(_)
                | Self::RecordingTruncated { .. }
        )
    }
}

/// A length in whole seconds as the Mac's HUD says it: "30 s", "1 min", "1 min 30 s".
fn duration(seconds: usize) -> String {
    match (seconds / 60, seconds % 60) {
        (0, rest) => format!("{rest} s"),
        (minutes, 0) => format!("{minutes} min"),
        (minutes, rest) => format!("{minutes} min {rest} s"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations_read_as_the_mac_says_them() {
        assert_eq!(duration(30), "30 s");
        assert_eq!(duration(60), "1 min");
        assert_eq!(duration(90), "1 min 30 s");
        assert_eq!(duration(300), "5 min");
    }

    #[test]
    fn messages_carry_counts_and_details() {
        let typed = Notice::Typed {
            characters: 42,
            method: InsertionMethod::InputMethod,
            latency_ms: 812,
        };
        assert_eq!(
            typed.message(),
            "Typed 42 characters by input method, 0.8 s after the recording ended"
        );
        assert_eq!(
            Notice::RecordingTruncated { seconds: 300 }.message(),
            "Recording stopped at 5 min; the rest wasn't heard"
        );
        assert_eq!(
            Notice::CaptureStoppedEarly { after_seconds: 12 }.message(),
            "The microphone stopped after 12 s; the rest wasn't heard"
        );
    }

    #[test]
    fn text_that_went_in_needs_no_panel() {
        let typed = Notice::Typed {
            characters: 1,
            method: InsertionMethod::Paste,
            latency_ms: 0,
        };
        assert!(!typed.in_panel());
        assert!(Notice::CopiedToClipboard.in_panel());
        assert!(Notice::Cancelled.in_panel());
    }

    #[test]
    fn only_what_went_wrong_is_a_problem() {
        assert!(Notice::CaptureFailed("unplugged".to_owned()).is_problem());
        assert!(Notice::RecordingTruncated { seconds: 300 }.is_problem());
        assert!(Notice::SecureField.is_problem());
        assert!(!Notice::Cancelled.is_problem());
        assert!(!Notice::NothingHeard.is_problem());
        assert!(!Notice::CopiedToClipboard.is_problem());
        assert!(!Notice::StillProcessing.is_problem());
    }
}
