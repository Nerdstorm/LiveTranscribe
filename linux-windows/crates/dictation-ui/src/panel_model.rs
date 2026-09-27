//! What the panel shows, and for how long: the Mac DictationController's notice handling and
//! HUDState's choice of content. Ordinary dictation is wordless; only a notice that needs
//! attention ([`Notice::needs_attention`]) is put in words, in a bubble beside the circle.
//!
//! - While recording: the microphone's level, and a ring when hands-free.
//! - While processing: a spinning ring.
//! - Either way, a message about the dictation in progress beside it, while it lasts.
//! - Between dictations: the messages the last one ended with, one after another, each for the
//!   notice time, followed by the messages it had during it. Text that went in, or a cancel, needs
//!   none: the panel just goes.
//!
//! Time is milliseconds from the caller's monotonic clock; [`PanelModel::next_deadline`] says when
//! to call [`PanelModel::advance`].

use std::collections::VecDeque;

use lt_dictation::{Notice, Phase};

/// What the panel shows: what its circle holds, and the message in the bubble beside it, if any.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PanelContent {
    pub indicator: Indicator,
    /// The bubble's text; `None` for no bubble.
    pub message: Option<String>,
}

/// What the panel's circle holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Indicator {
    /// The microphone's level, while recording. Hands-free adds a ring, because the recording
    /// ends only when the hotkey is pressed again.
    Level { hands_free: bool },
    /// A spinning ring, while transcribing.
    Spinner,
    /// A glyph for a message between dictations.
    Notice { problem: bool },
}

impl PanelContent {
    /// It moves (the level, the spinner), so it is drawn again every frame.
    pub fn is_animated(&self) -> bool {
        !matches!(self.indicator, Indicator::Notice { .. })
    }
}

#[derive(Clone, Debug)]
pub struct PanelModel {
    notice_ms: u64,
    phase: Phase,
    /// The message shown between dictations, and until when.
    message: Option<(Notice, u64)>,
    /// Messages to show after it.
    waiting: VecDeque<Notice>,
    /// A message about the dictation in progress, and until when.
    progress: Option<(Notice, u64)>,
    /// The dictation's progress messages, repeated once it ends: that is when someone watching
    /// their text rather than the panel sees them.
    carried: Vec<Notice>,
}

impl PanelModel {
    /// `notice_ms`: how long each message shows (the Mac's default is 2.5 s).
    pub fn new(notice_ms: u64) -> Self {
        Self {
            notice_ms,
            phase: Phase::Idle,
            message: None,
            waiting: VecDeque::new(),
            progress: None,
            carried: Vec::new(),
        }
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    /// A dictation started, went hands-free, or moved on to processing.
    pub fn phase_changed(&mut self, phase: Phase) {
        if self.phase == Phase::Idle && phase != Phase::Idle {
            // Messages about the last dictation are dropped.
            self.message = None;
            self.waiting.clear();
            self.progress = None;
            self.carried.clear();
        }
        self.phase = phase;
    }

    /// The dictation is over: its messages show in turn, then the ones it carried.
    pub fn end_dictation(&mut self, notices: Vec<Notice>, now_ms: u64) {
        self.phase = Phase::Idle;
        self.progress = None;
        let carried = std::mem::take(&mut self.carried);
        self.waiting = notices
            .into_iter()
            .chain(carried)
            .filter(Notice::needs_attention)
            .collect();
        self.message = self.waiting.pop_front().map(|notice| (notice, now_ms + self.notice_ms));
    }

    /// A message about the dictation in progress. Between dictations it is an ordinary message.
    pub fn show_progress(&mut self, notice: Notice, now_ms: u64) {
        if self.phase == Phase::Idle {
            return self.end_dictation(vec![notice], now_ms);
        }
        if !notice.needs_attention() {
            return;
        }
        self.carried.retain(|carried| carried != &notice);
        self.carried.push(notice.clone());
        self.progress = Some((notice, now_ms + self.notice_ms));
    }

    /// When a message runs out: call [`Self::advance`] then.
    pub fn next_deadline(&self) -> Option<u64> {
        let message = self.message.as_ref().map(|(_, until)| *until);
        let progress = self.progress.as_ref().map(|(_, until)| *until);
        message.into_iter().chain(progress).min()
    }

    /// Retires messages whose time is up, showing the next one waiting.
    pub fn advance(&mut self, now_ms: u64) {
        if self.progress.as_ref().is_some_and(|(_, until)| *until <= now_ms) {
            self.progress = None;
        }
        if self.message.as_ref().is_some_and(|(_, until)| *until <= now_ms) {
            self.message = self.waiting.pop_front().map(|notice| (notice, now_ms + self.notice_ms));
        }
    }

    /// What the panel shows now; `None` hides it.
    pub fn content(&self) -> Option<PanelContent> {
        let progress = self.progress.as_ref().map(|(notice, _)| notice.message());
        match self.phase {
            Phase::Recording { hands_free } => Some(PanelContent {
                indicator: Indicator::Level { hands_free },
                message: progress,
            }),
            Phase::Processing { .. } => Some(PanelContent {
                indicator: Indicator::Spinner,
                message: progress,
            }),
            Phase::Idle => self.message.as_ref().map(|(notice, _)| PanelContent {
                indicator: Indicator::Notice {
                    problem: notice.is_problem(),
                },
                message: Some(notice.message()),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use lt_insertion::InsertionMethod;

    use super::*;

    const NOTICE_MS: u64 = 2_500;

    fn model() -> PanelModel {
        PanelModel::new(NOTICE_MS)
    }

    fn message(notice: &Notice) -> Option<PanelContent> {
        Some(PanelContent {
            indicator: Indicator::Notice {
                problem: notice.is_problem(),
            },
            message: Some(notice.message()),
        })
    }

    fn wordless(indicator: Indicator) -> Option<PanelContent> {
        Some(PanelContent {
            indicator,
            message: None,
        })
    }

    #[test]
    fn dictating_is_wordless() {
        let mut panel = model();
        assert_eq!(panel.content(), None);
        panel.phase_changed(Phase::Recording { hands_free: false });
        assert_eq!(panel.content(), wordless(Indicator::Level { hands_free: false }));
        panel.phase_changed(Phase::Recording { hands_free: true });
        assert_eq!(panel.content(), wordless(Indicator::Level { hands_free: true }));
        panel.phase_changed(Phase::Processing { audio_ms: 900 });
        assert_eq!(panel.content(), wordless(Indicator::Spinner));
    }

    #[test]
    fn a_cancel_hides_the_panel_without_a_word() {
        let mut panel = model();
        panel.phase_changed(Phase::Recording { hands_free: false });
        panel.end_dictation(vec![Notice::Cancelled], 1_000);
        assert_eq!(panel.content(), None);
        assert_eq!(panel.next_deadline(), None);
    }

    #[test]
    fn text_that_went_in_hides_the_panel() {
        let mut panel = model();
        panel.phase_changed(Phase::Recording { hands_free: false });
        panel.end_dictation(
            vec![Notice::Typed {
                characters: 5,
                method: InsertionMethod::InputMethod,
                latency_ms: 700,
            }],
            1_000,
        );
        assert_eq!(panel.content(), None);
        assert_eq!(panel.next_deadline(), None);
    }

    #[test]
    fn messages_follow_one_another_then_the_panel_goes() {
        let mut panel = model();
        panel.phase_changed(Phase::Recording { hands_free: false });
        let first = Notice::CopiedToClipboard;
        let second = Notice::RecordingTruncated { seconds: 300 };
        panel.end_dictation(vec![first.clone(), second.clone()], 1_000);
        assert_eq!(panel.content(), message(&first));
        assert_eq!(panel.next_deadline(), Some(3_500));
        panel.advance(3_499);
        assert_eq!(panel.content(), message(&first));
        panel.advance(3_500);
        assert_eq!(panel.content(), message(&second));
        panel.advance(6_000);
        assert_eq!(panel.content(), None);
    }

    #[test]
    fn a_progress_message_shows_beside_the_circle_then_again_at_the_end() {
        let mut panel = model();
        panel.phase_changed(Phase::Processing { audio_ms: 900 });
        panel.show_progress(Notice::StillProcessing, 0);
        panel.show_progress(Notice::StillProcessing, 100);
        assert_eq!(
            panel.content(),
            Some(PanelContent {
                indicator: Indicator::Spinner,
                message: Some(Notice::StillProcessing.message()),
            })
        );
        panel.advance(2_600);
        assert_eq!(panel.content(), wordless(Indicator::Spinner));

        panel.end_dictation(vec![Notice::CopiedToClipboard], 3_000);
        assert_eq!(panel.content(), message(&Notice::CopiedToClipboard));
        panel.advance(5_500);
        assert_eq!(
            panel.content(),
            message(&Notice::StillProcessing),
            "shown once, however often it came"
        );
        panel.advance(8_000);
        assert_eq!(panel.content(), None);
    }

    #[test]
    fn a_new_dictation_drops_what_was_left_to_say() {
        let mut panel = model();
        panel.end_dictation(vec![Notice::Cancelled, Notice::NothingHeard], 0);
        panel.phase_changed(Phase::Recording { hands_free: false });
        panel.end_dictation(Vec::new(), 500);
        assert_eq!(panel.content(), None);
        assert_eq!(panel.next_deadline(), None);
    }

    #[test]
    fn the_level_and_the_spinner_move_and_a_message_doesnt() {
        assert!(wordless(Indicator::Level { hands_free: false }).is_some_and(|content| content.is_animated()));
        assert!(wordless(Indicator::Spinner).is_some_and(|content| content.is_animated()));
        assert!(message(&Notice::NothingHeard).is_some_and(|content| !content.is_animated()));
    }
}
