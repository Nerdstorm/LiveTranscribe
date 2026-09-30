//! The dictation flow, as the Mac app's DictationController runs it: the hotkey gesture (or the
//! menu) drives the recording, and each recording is transcribed, put through the text rules and
//! typed into the focused field, one dictation at a time.
//!
//! Platform-free and synchronous. The recorder, the speech model, cleanup's model, the focused
//! field and typing sit behind [`Dependencies`]; transcription, cleanup and typing finish later,
//! and their results come back through [`DictationController::transcribed`],
//! [`DictationController::cleaned`] and [`DictationController::inserted`]. The caller
//! owns the clock, passing milliseconds from one monotonic clock with every call, and runs the
//! timers the gesture asks for ([`DictationController::next_timer`]).
//!
//! What was said is never shown or logged.

use std::collections::VecDeque;

use lt_cleanup::{CleanedText, CleanupOptions};
use lt_hotkey::{HotkeyAction, HotkeyEvent, HotkeyGesture, HotkeyGestureConfiguration, HotkeyInput};
use lt_insertion::{Inserted, InsertionTarget};
use lt_shared::CleanupLevel;
use lt_shared::audio_format::milliseconds_for_samples;

use crate::{Configuration, Notice, Output, Pending, Prepared, insertion_spacing, prepare};

/// A recording, as the recorder hands it over.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Recording {
    /// 16 kHz mono samples.
    pub samples: Vec<f32>,
    /// It reached the length limit and the rest was dropped.
    pub truncated: bool,
    /// Capture failed partway; `samples` holds what arrived before it did.
    pub failure: Option<String>,
}

/// One dictation's transcription and typing, so that a late result from a cancelled one is
/// recognised and dropped.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Job(pub u64);

/// Where the dictation stands, for the panel and the menu.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Idle,
    Recording {
        hands_free: bool,
    },
    /// Transcribing what was said, cleaning it up, then typing it.
    Processing {
        audio_ms: usize,
    },
}

/// What the flow needs from the platform.
pub trait Dependencies {
    /// Opens the microphone and starts recording.
    fn start_recording(&mut self) -> Result<(), String>;
    /// Closes the microphone and hands over the recording.
    fn stop_recording(&mut self) -> Recording;
    /// Closes the microphone and throws the recording away.
    fn cancel_recording(&mut self);
    /// The field the text would go into, as it is now.
    fn target(&mut self) -> InsertionTarget;
    /// Starts transcribing; the result comes back through [`DictationController::transcribed`].
    fn transcribe(&mut self, job: Job, samples: Vec<f32>);
    /// Starts cleaning `text` up with cleanup's model, as `options` say; the result comes back
    /// through [`DictationController::cleaned`].
    fn clean(&mut self, job: Job, text: String, options: CleanupOptions);
    /// The cleanup of `job` is no longer wanted: stop it, and its result is dropped.
    fn cancel_cleanup(&mut self, job: Job);
    /// A dictation is on its way: whatever typing needs beforehand, such as saving the
    /// clipboard, can start while the model works.
    fn prepare_insertion(&mut self);
    /// Starts typing; the result comes back through [`DictationController::inserted`].
    fn insert(&mut self, job: Job, text: String);
    /// A dictation started, went hands-free, or moved on to processing.
    fn phase_changed(&mut self, phase: Phase);
    /// The dictation is over, however it ended: show `notices` in turn, the most important
    /// first. Empty when there is nothing to say.
    fn end_dictation(&mut self, notices: Vec<Notice>);
    /// A message about the dictation in progress, such as a press while it is being processed.
    fn show_progress(&mut self, notice: Notice);
}

#[derive(Clone, Debug, PartialEq)]
pub struct ControllerConfiguration {
    pub gesture: HotkeyGestureConfiguration,
    /// A recording shorter than this is nothing heard.
    pub min_utterance_ms: usize,
    /// The recorder's length limit, for the notice when a recording reaches it.
    pub max_recording_seconds: u32,
    /// The text rules. Whether the text may break across lines is decided per field.
    pub text: Configuration,
    /// Cleanup's language model is on (Settings › Advanced). Off, each level applies only its
    /// rules that need no model.
    pub cleans_with_model: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum State {
    Idle,
    Recording,
    Transcribing {
        job: Job,
        dictation: Dictation,
    },
    /// Cleanup's model is cleaning the transcript; what it needs afterwards is in `pending`.
    Cleaning {
        job: Job,
        dictation: Dictation,
    },
    /// The text is on its way into the app: too late to cancel.
    Inserting {
        job: Job,
        dictation: Dictation,
    },
}

/// What the rest of a dictation needs to know about its recording and field.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Dictation {
    released_at: u64,
    audio_ms: usize,
    truncated: bool,
    failure: Option<String>,
    multiline: bool,
}

pub struct DictationController<D: Dependencies> {
    dependencies: D,
    configuration: ControllerConfiguration,
    gesture: HotkeyGesture,
    /// When each timer the gesture asked for runs out. They all have the same length, so the
    /// soonest is first.
    timers: VecDeque<u64>,
    state: State,
    /// The dictation was started from the menu, so it is hands-free and the hotkey only stops it.
    started_from_menu: bool,
    next_job: u64,
    last_text: Option<String>,
    /// While cleaning, what turns the model's result into the text to insert.
    pending: Option<Box<Pending>>,
}

impl<D: Dependencies> DictationController<D> {
    pub fn new(configuration: ControllerConfiguration, dependencies: D) -> Self {
        Self {
            dependencies,
            gesture: HotkeyGesture::new(configuration.gesture),
            configuration,
            timers: VecDeque::new(),
            state: State::Idle,
            started_from_menu: false,
            next_job: 1,
            last_text: None,
            pending: None,
        }
    }

    pub fn dependencies(&self) -> &D {
        &self.dependencies
    }

    pub fn dependencies_mut(&mut self) -> &mut D {
        &mut self.dependencies
    }

    pub fn phase(&self) -> Phase {
        match &self.state {
            State::Idle => Phase::Idle,
            State::Recording => Phase::Recording {
                hands_free: self.started_from_menu || self.gesture.is_hands_free(),
            },
            State::Transcribing { dictation, .. }
            | State::Cleaning { dictation, .. }
            | State::Inserting { dictation, .. } => Phase::Processing {
                audio_ms: dictation.audio_ms,
            },
        }
    }

    /// No dictation is being recorded, transcribed or typed.
    pub fn is_idle(&self) -> bool {
        self.state == State::Idle
    }

    pub fn is_recording(&self) -> bool {
        self.state == State::Recording
    }

    pub fn cleanup_level(&self) -> CleanupLevel {
        self.configuration.text.level
    }

    /// How much the text rules may change what is said from now on, as the menu's *Cleanup*
    /// picker sets it. A dictation already transcribed keeps the level it had.
    pub fn set_cleanup_level(&mut self, level: CleanupLevel) {
        self.configuration.text.level = level;
    }

    /// Settings changed: the text rules and limits apply from the next dictation transcribed, and
    /// the gesture's timing from the next gesture.
    pub fn set_configuration(&mut self, configuration: ControllerConfiguration) {
        self.gesture.set_configuration(configuration.gesture);
        self.configuration = configuration;
    }

    /// The last text dictated, as the text rules made it, for *Copy Last Dictation*. Nothing
    /// after a dictation into a private field.
    pub fn last_text(&self) -> Option<&str> {
        self.last_text.as_deref()
    }

    /// When the soonest timer runs out: call [`Self::timer_fired`] then.
    pub fn next_timer(&self) -> Option<u64> {
        self.timers.front().copied()
    }

    /// The soonest timer has run out.
    pub fn timer_fired(&mut self, now_ms: u64) {
        if self.timers.pop_front().is_some() {
            self.apply(HotkeyInput::TimerFired, now_ms);
        }
    }

    pub fn hotkey(&mut self, event: HotkeyEvent, now_ms: u64) {
        let input = event.gesture_input();
        if !self.gesture.is_recording() {
            // One dictation at a time: a recording started now would lose its first words
            // waiting for this one's text to go in.
            match (&self.state, input) {
                (State::Transcribing { .. } | State::Cleaning { .. }, HotkeyInput::Escape) => return self.cancel(),
                (
                    State::Transcribing { .. } | State::Cleaning { .. } | State::Inserting { .. },
                    HotkeyInput::Pressed,
                ) => {
                    return self.dependencies.show_progress(Notice::StillProcessing);
                }
                (State::Transcribing { .. } | State::Cleaning { .. } | State::Inserting { .. }, _) => return,
                // A dictation started from the menu is hands-free: Esc cancels it and the
                // hotkey finishes it.
                (State::Recording, HotkeyInput::Escape) if self.started_from_menu => return self.cancel(),
                (State::Recording, HotkeyInput::Pressed) if self.started_from_menu => {
                    return self.toggle_dictation(now_ms);
                }
                (State::Recording, _) if self.started_from_menu => return,
                _ => {}
            }
        }
        self.apply(input, now_ms);
    }

    /// Starts a hands-free dictation, or finishes the one being recorded: the menu's *Start
    /// Dictation* and *Stop Dictation*.
    pub fn toggle_dictation(&mut self, now_ms: u64) {
        match self.state {
            State::Idle => {
                self.gesture.reset();
                self.started_from_menu = true;
                self.begin_recording();
            }
            State::Recording => {
                self.gesture.reset();
                self.finish_recording(now_ms);
            }
            State::Transcribing { .. } | State::Cleaning { .. } | State::Inserting { .. } => {}
        }
    }

    /// Cancels whatever is in progress: Esc, the menu's *Cancel Dictation*, the panel's ×. Once
    /// typing has started it is too late.
    pub fn cancel(&mut self) {
        match self.state {
            State::Recording => {
                self.gesture.reset();
                self.discard_recording(true);
            }
            // The late result is recognised by its job and dropped.
            State::Transcribing { .. } => self.end(vec![Notice::Cancelled]),
            State::Cleaning { job, .. } => {
                self.dependencies.cancel_cleanup(job);
                self.end(vec![Notice::Cancelled]);
            }
            State::Idle | State::Inserting { .. } => {}
        }
    }

    fn apply(&mut self, input: HotkeyInput, now_ms: u64) {
        for action in self.gesture.handle(input, now_ms) {
            match action {
                HotkeyAction::StartRecording => self.begin_recording(),
                HotkeyAction::EnteredHandsFree => {
                    if self.state == State::Recording {
                        self.dependencies.phase_changed(self.phase());
                    }
                }
                HotkeyAction::StopAndProcess => self.finish_recording(now_ms),
                // A lone tap, or a shortcut typed with the hotkey held, is not a mistake worth a
                // message.
                HotkeyAction::Cancel => self.discard_recording(input == HotkeyInput::Escape),
                HotkeyAction::ScheduleTimer { ms } => self.timers.push_back(now_ms.saturating_add(ms)),
            }
        }
    }

    fn begin_recording(&mut self) {
        if self.state != State::Idle {
            self.gesture.reset();
            return;
        }
        // Nothing said into a password field is ever recorded.
        if self.dependencies.target().is_secure {
            self.gesture.reset();
            return self.end(vec![Notice::SecureField]);
        }
        self.state = State::Recording;
        self.dependencies.phase_changed(self.phase());
        if let Err(detail) = self.dependencies.start_recording() {
            // The release that ends this press must not stop a recording that never began.
            self.gesture.reset();
            self.end(vec![Notice::CaptureFailed(detail)]);
        }
    }

    fn discard_recording(&mut self, by_escape: bool) {
        if self.state != State::Recording {
            return;
        }
        self.dependencies.cancel_recording();
        self.end(if by_escape { vec![Notice::Cancelled] } else { Vec::new() });
    }

    fn finish_recording(&mut self, now_ms: u64) {
        if self.state != State::Recording {
            return;
        }
        let recording = self.dependencies.stop_recording();
        let audio_ms = milliseconds_for_samples(recording.samples.len());
        if audio_ms < self.configuration.min_utterance_ms {
            // Too little arrived before capture failed to transcribe: the failure is the news.
            return self.end(vec![
                recording.failure.map_or(Notice::NothingHeard, Notice::CaptureFailed),
            ]);
        }
        let target = self.dependencies.target();
        if target.is_secure {
            return self.end(vec![Notice::SecureField]);
        }
        let job = Job(self.next_job);
        self.next_job += 1;
        self.state = State::Transcribing {
            job,
            dictation: Dictation {
                released_at: now_ms,
                audio_ms,
                truncated: recording.truncated,
                failure: recording.failure,
                multiline: target.allows_line_breaks,
            },
        };
        self.dependencies.phase_changed(self.phase());
        self.dependencies.prepare_insertion();
        self.dependencies.transcribe(job, recording.samples);
    }

    /// The speech model has finished `job`, with the transcript or what went wrong.
    pub fn transcribed(&mut self, job: Job, result: Result<String, String>) {
        let dictation = match &self.state {
            State::Transcribing {
                job: current,
                dictation,
            } if *current == job => dictation.clone(),
            _ => return,
        };
        let transcript = match result {
            Ok(transcript) => transcript,
            Err(detail) => return self.end(vec![Notice::TranscriptionFailed(detail)]),
        };
        let configuration = Configuration {
            multiline: dictation.multiline,
            ..self.configuration.text.clone()
        };
        match prepare(&transcript, &configuration) {
            Prepared::Done(output) => self.insert_output(job, dictation, &transcript, output),
            Prepared::Pending(pending) if !self.configuration.cleans_with_model => {
                self.insert_output(job, dictation, &transcript, pending.without_the_model());
            }
            Prepared::Pending(pending) => {
                let (text, options) = (pending.text().to_owned(), pending.options().clone());
                self.pending = Some(pending);
                self.state = State::Cleaning { job, dictation };
                self.dependencies.clean(job, text, options);
            }
        }
    }

    /// Cleanup's model has finished `job`: what it made of the text, or the text it was given
    /// when it fell back.
    pub fn cleaned(&mut self, job: Job, cleaned: CleanedText) {
        let dictation = match &self.state {
            State::Cleaning {
                job: current,
                dictation,
            } if *current == job => dictation.clone(),
            _ => return,
        };
        let Some(pending) = self.pending.take() else {
            return;
        };
        if let Some(reason) = &cleaned.fallback_reason {
            tracing::info!("Cleanup fell back to the text before it: {reason}");
        }
        let transcript = pending.text().to_owned();
        self.insert_output(job, dictation, &transcript, pending.finish(cleaned));
    }

    /// Types `output`'s text into the field, unless there is nothing to type or the field is now
    /// one nothing may be typed into.
    fn insert_output(&mut self, job: Job, dictation: Dictation, transcript: &str, output: Output) {
        tracing::debug!(
            "The text rules made {} characters of {}",
            output.text.chars().count(),
            transcript.chars().count()
        );
        if output.is_empty() {
            return self.end(vec![
                dictation.failure.map_or(Notice::NothingHeard, Notice::CaptureFailed),
            ]);
        }
        // The field is read again: focus can move while the model works.
        let target = self.dependencies.target();
        if target.is_secure {
            return self.end(vec![Notice::SecureField]);
        }
        let text = insertion_spacing::adjusted(&output.text, target.preceding);
        self.last_text = (!target.is_private).then_some(output.text);
        self.state = State::Inserting { job, dictation };
        self.dependencies.insert(job, text);
    }

    /// Typing `job`'s text has finished.
    pub fn inserted(&mut self, job: Job, result: Result<Inserted, String>, now_ms: u64) {
        let dictation = match &self.state {
            State::Inserting {
                job: current,
                dictation,
            } if *current == job => dictation.clone(),
            _ => return,
        };
        // Where the text went comes first: it may be waiting on the clipboard.
        let mut notices = vec![match result {
            Ok(inserted) if inserted.read => Notice::Typed {
                characters: inserted.characters,
                method: inserted.method,
                latency_ms: now_ms.saturating_sub(dictation.released_at),
            },
            Ok(_) => Notice::CopiedToClipboard,
            Err(detail) => Notice::InsertionFailed(detail),
        }];
        notices.extend(self.recording_notice(&dictation));
        self.end(notices);
    }

    /// Back to idle, however the dictation ended, with what to say about it.
    fn end(&mut self, notices: Vec<Notice>) {
        self.state = State::Idle;
        self.pending = None;
        self.started_from_menu = false;
        self.dependencies.end_dictation(notices);
    }

    /// What the user should know about a recording that did not hear all they said: it hit the
    /// length limit, or the microphone stopped partway through.
    fn recording_notice(&self, dictation: &Dictation) -> Option<Notice> {
        if dictation.truncated {
            return Some(Notice::RecordingTruncated {
                seconds: self.configuration.max_recording_seconds,
            });
        }
        dictation.failure.as_ref()?;
        // Rounded, and never "after 0 s": something was heard.
        Some(Notice::CaptureStoppedEarly {
            after_seconds: ((dictation.audio_ms + 500) / 1_000).max(1),
        })
    }
}

#[cfg(test)]
mod tests {
    use lt_hotkey::HotkeyGestureConfiguration;
    use lt_insertion::InsertionMethod;
    use lt_shared::CleanupLevel;
    use lt_shared::audio_format::samples_for_milliseconds;

    use super::*;
    use crate::finish;

    /// Records what the flow asked of the platform.
    #[derive(Default)]
    struct Fake {
        starts: usize,
        stops: usize,
        cancels: usize,
        /// What the next recording holds.
        recording_ms: usize,
        recording_truncated: bool,
        recording_failure: Option<String>,
        start_failure: Option<String>,
        /// The focused field, as each read of it finds it.
        target: InsertionTarget,
        transcribing: Vec<(Job, usize)>,
        /// What cleanup's model was asked to clean.
        cleaning: Vec<(Job, String, CleanupOptions)>,
        cleanups_cancelled: Vec<Job>,
        prepared: usize,
        inserted: Vec<(Job, String)>,
        phases: Vec<Phase>,
        /// What each dictation ended with.
        endings: Vec<Vec<Notice>>,
        progress: Vec<Notice>,
    }

    impl Dependencies for Fake {
        fn start_recording(&mut self) -> Result<(), String> {
            self.starts += 1;
            self.start_failure.clone().map_or(Ok(()), Err)
        }

        fn stop_recording(&mut self) -> Recording {
            self.stops += 1;
            Recording {
                samples: vec![0.1; samples_for_milliseconds(self.recording_ms)],
                truncated: self.recording_truncated,
                failure: self.recording_failure.clone(),
            }
        }

        fn cancel_recording(&mut self) {
            self.cancels += 1;
        }

        fn target(&mut self) -> InsertionTarget {
            self.target
        }

        fn transcribe(&mut self, job: Job, samples: Vec<f32>) {
            self.transcribing.push((job, samples.len()));
        }

        fn clean(&mut self, job: Job, text: String, options: CleanupOptions) {
            self.cleaning.push((job, text, options));
        }

        fn cancel_cleanup(&mut self, job: Job) {
            self.cleanups_cancelled.push(job);
        }

        fn prepare_insertion(&mut self) {
            self.prepared += 1;
        }

        fn insert(&mut self, job: Job, text: String) {
            self.inserted.push((job, text));
        }

        fn phase_changed(&mut self, phase: Phase) {
            self.phases.push(phase);
        }

        fn end_dictation(&mut self, notices: Vec<Notice>) {
            self.endings.push(notices);
        }

        fn show_progress(&mut self, notice: Notice) {
            self.progress.push(notice);
        }
    }

    fn controller() -> DictationController<Fake> {
        DictationController::new(
            ControllerConfiguration {
                gesture: HotkeyGestureConfiguration {
                    tap_max_ms: 300,
                    double_tap_window_ms: 300,
                    hands_free_enabled: true,
                },
                min_utterance_ms: 300,
                max_recording_seconds: 300,
                text: Configuration {
                    level: CleanupLevel::Medium,
                    snippets: Vec::new(),
                    vocabulary: Vec::new(),
                    vocabulary_prompt_limit: Configuration::VOCABULARY_PROMPT_LIMIT,
                    vocabulary_similarity_threshold: Configuration::VOCABULARY_SIMILARITY_THRESHOLD,
                    multiline: false,
                },
                cleans_with_model: false,
            },
            Fake {
                recording_ms: 500,
                ..Fake::default()
            },
        )
    }

    fn pasted(characters: usize) -> Inserted {
        Inserted {
            characters,
            method: InsertionMethod::Paste,
            read: true,
            restored: true,
        }
    }

    fn typed(latency_ms: u64) -> Notice {
        Notice::Typed {
            characters: 18,
            method: InsertionMethod::Paste,
            latency_ms,
        }
    }

    fn last_job(controller: &DictationController<Fake>) -> Job {
        controller
            .dependencies()
            .transcribing
            .last()
            .expect("a transcription")
            .0
    }

    fn last_ending(controller: &DictationController<Fake>) -> &[Notice] {
        controller.dependencies().endings.last().expect("an ending")
    }

    /// Holds the hotkey from `at` for `held_ms`, then returns the job it started.
    fn dictate(controller: &mut DictationController<Fake>, at: u64, held_ms: u64) -> Job {
        controller.hotkey(HotkeyEvent::Pressed, at);
        controller.hotkey(HotkeyEvent::Released, at + held_ms);
        last_job(controller)
    }

    #[test]
    fn holding_the_key_dictates_into_the_focused_field() {
        let mut c = controller();
        c.hotkey(HotkeyEvent::Pressed, 0);
        assert_eq!(c.phase(), Phase::Recording { hands_free: false });
        c.hotkey(HotkeyEvent::Released, 500);
        let job = last_job(&c);
        assert_eq!(c.dependencies().transcribing, [(job, 8_000)]);
        assert_eq!(
            c.dependencies().prepared,
            1,
            "the clipboard is saved while the model works"
        );
        assert_eq!(c.phase(), Phase::Processing { audio_ms: 500 });

        c.transcribed(job, Ok("Um, ship it on Friday.".to_owned()));
        assert_eq!(c.dependencies().inserted, [(job, "Ship it on Friday.".to_owned())]);
        c.inserted(job, Ok(pasted(18)), 1_400);
        assert!(c.is_idle());
        assert_eq!(
            c.dependencies().phases,
            [
                Phase::Recording { hands_free: false },
                Phase::Processing { audio_ms: 500 }
            ]
        );
        assert_eq!(c.dependencies().endings, [vec![typed(900)]]);
        assert_eq!(c.last_text(), Some("Ship it on Friday."));
    }

    #[test]
    fn a_lone_tap_is_cancelled_silently() {
        let mut c = controller();
        c.hotkey(HotkeyEvent::Pressed, 0);
        c.hotkey(HotkeyEvent::Released, 100);
        assert_eq!(c.next_timer(), Some(400));
        c.timer_fired(400);
        assert!(c.is_idle());
        assert_eq!(c.next_timer(), None);
        assert_eq!(c.dependencies().cancels, 1);
        assert_eq!(c.dependencies().endings, [Vec::<Notice>::new()]);
        assert!(c.dependencies().transcribing.is_empty());
    }

    #[test]
    fn a_double_tap_dictates_hands_free_until_the_next_press() {
        let mut c = controller();
        c.hotkey(HotkeyEvent::Pressed, 0);
        c.hotkey(HotkeyEvent::Released, 100);
        c.hotkey(HotkeyEvent::Pressed, 200);
        c.hotkey(HotkeyEvent::Released, 300);
        c.timer_fired(400);
        assert_eq!(
            c.phase(),
            Phase::Recording { hands_free: true },
            "neither the second release nor the timer stops it"
        );
        c.hotkey(HotkeyEvent::Pressed, 3_000);
        c.hotkey(HotkeyEvent::Released, 3_100);
        assert_eq!(c.dependencies().transcribing.len(), 1);
        assert_eq!(c.dependencies().starts, 1);
        assert_eq!(
            c.dependencies().phases[..2],
            [
                Phase::Recording { hands_free: false },
                Phase::Recording { hands_free: true }
            ]
        );
    }

    #[test]
    fn escape_while_recording_cancels() {
        let mut c = controller();
        c.hotkey(HotkeyEvent::Pressed, 0);
        c.hotkey(HotkeyEvent::Escape, 500);
        assert!(c.is_idle());
        c.hotkey(HotkeyEvent::Released, 900);
        assert_eq!(c.dependencies().cancels, 1);
        assert_eq!(c.dependencies().endings, [vec![Notice::Cancelled]]);
        assert!(c.dependencies().transcribing.is_empty());
    }

    #[test]
    fn another_key_while_holding_cancels_silently() {
        let mut c = controller();
        c.hotkey(HotkeyEvent::Pressed, 0);
        c.hotkey(HotkeyEvent::OtherKey, 200);
        assert!(c.is_idle());
        assert_eq!(c.dependencies().cancels, 1);
        assert_eq!(c.dependencies().endings, [Vec::<Notice>::new()]);
    }

    #[test]
    fn too_short_a_recording_is_nothing_heard() {
        let mut c = controller();
        c.dependencies_mut().recording_ms = 250;
        c.hotkey(HotkeyEvent::Pressed, 0);
        c.hotkey(HotkeyEvent::Released, 400);
        assert!(c.is_idle());
        assert_eq!(last_ending(&c), [Notice::NothingHeard]);
        assert!(c.dependencies().transcribing.is_empty());
    }

    #[test]
    fn a_press_while_processing_says_so_instead_of_recording_late() {
        let mut c = controller();
        let job = dictate(&mut c, 0, 500);
        c.hotkey(HotkeyEvent::Pressed, 600);
        c.hotkey(HotkeyEvent::Released, 1_200);
        c.transcribed(job, Ok("Ship it on Friday.".to_owned()));
        c.hotkey(HotkeyEvent::Pressed, 1_300);
        c.hotkey(HotkeyEvent::Released, 1_400);
        assert_eq!(
            c.dependencies().progress,
            [Notice::StillProcessing, Notice::StillProcessing]
        );
        c.inserted(job, Ok(pasted(18)), 1_500);
        assert!(c.is_idle());
        assert_eq!(
            c.dependencies().starts,
            1,
            "the presses while processing never opened the microphone"
        );
        assert_eq!(c.dependencies().stops, 1);
    }

    #[test]
    fn escape_while_transcribing_cancels_and_the_late_result_is_dropped() {
        let mut c = controller();
        let job = dictate(&mut c, 0, 500);
        c.hotkey(HotkeyEvent::Escape, 600);
        assert!(c.is_idle());
        assert_eq!(last_ending(&c), [Notice::Cancelled]);

        // A new dictation can start at once; the cancelled one's result means nothing to it.
        c.hotkey(HotkeyEvent::Pressed, 700);
        c.transcribed(job, Ok("Ship it on Friday.".to_owned()));
        assert!(c.is_recording());
        c.hotkey(HotkeyEvent::Released, 1_500);
        let next = last_job(&c);
        assert_ne!(next, job);
        c.transcribed(job, Ok("Ship it on Friday.".to_owned()));
        assert!(c.dependencies().inserted.is_empty());
        c.transcribed(next, Ok("Um, ship it on Monday.".to_owned()));
        assert_eq!(c.dependencies().inserted, [(next, "Ship it on Monday.".to_owned())]);
    }

    #[test]
    fn escape_once_typing_has_started_changes_nothing() {
        let mut c = controller();
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Ok("Ship it on Friday.".to_owned()));
        c.hotkey(HotkeyEvent::Escape, 700);
        c.cancel();
        assert!(c.dependencies().endings.is_empty());
        c.inserted(job, Ok(pasted(18)), 900);
        assert_eq!(c.dependencies().endings, [vec![typed(400)]]);
    }

    #[test]
    fn text_nothing_took_is_on_the_clipboard() {
        let mut c = controller();
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Ok("Ship it on Friday.".to_owned()));
        let unread = Inserted {
            read: false,
            restored: false,
            ..pasted(18)
        };
        c.inserted(job, Ok(unread), 2_600);
        assert_eq!(last_ending(&c), [Notice::CopiedToClipboard]);
    }

    #[test]
    fn a_microphone_that_wont_open_leaves_the_hotkey_working() {
        let mut c = controller();
        c.dependencies_mut().start_failure = Some("no microphone".to_owned());
        c.hotkey(HotkeyEvent::Pressed, 0);
        assert!(c.is_idle());
        assert_eq!(
            c.dependencies().endings,
            [vec![Notice::CaptureFailed("no microphone".to_owned())]]
        );
        c.hotkey(HotkeyEvent::Released, 500);
        assert_eq!(c.dependencies().stops, 0);

        c.dependencies_mut().start_failure = None;
        c.hotkey(HotkeyEvent::Pressed, 1_000);
        assert!(c.is_recording());
    }

    #[test]
    fn a_microphone_that_stops_early_is_reported() {
        let mut c = controller();
        c.dependencies_mut().recording_failure = Some("unplugged".to_owned());
        c.dependencies_mut().recording_ms = 100;
        c.hotkey(HotkeyEvent::Pressed, 0);
        c.hotkey(HotkeyEvent::Released, 500);
        assert_eq!(last_ending(&c), [Notice::CaptureFailed("unplugged".to_owned())]);
        assert!(c.dependencies().transcribing.is_empty());

        // With enough heard first, that much is typed, and the notice follows.
        c.dependencies_mut().recording_ms = 2_400;
        let job = dictate(&mut c, 1_000, 3_000);
        c.transcribed(job, Ok("Ship it.".to_owned()));
        c.inserted(job, Ok(pasted(18)), 4_500);
        assert_eq!(
            last_ending(&c),
            [typed(500), Notice::CaptureStoppedEarly { after_seconds: 2 }]
        );
    }

    #[test]
    fn a_recording_cut_at_the_limit_says_so_after_the_text() {
        let mut c = controller();
        c.dependencies_mut().recording_truncated = true;
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Ok("Ship it.".to_owned()));
        c.inserted(job, Ok(pasted(18)), 900);
        assert_eq!(
            last_ending(&c),
            [typed(400), Notice::RecordingTruncated { seconds: 300 }]
        );
    }

    #[test]
    fn failures_after_the_recording_end_the_dictation() {
        let mut c = controller();
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Err("the model stopped".to_owned()));
        assert!(c.is_idle());
        assert_eq!(
            last_ending(&c),
            [Notice::TranscriptionFailed("the model stopped".to_owned())]
        );

        let job = dictate(&mut c, 1_000, 500);
        c.transcribed(job, Ok("Ship it.".to_owned()));
        c.inserted(job, Err("no clipboard".to_owned()), 2_000);
        assert!(c.is_idle());
        assert_eq!(last_ending(&c), [Notice::InsertionFailed("no clipboard".to_owned())]);
    }

    #[test]
    fn a_transcript_of_nothing_is_nothing_heard() {
        let mut c = controller();
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Ok("  ".to_owned()));
        assert!(c.is_idle());
        assert!(c.dependencies().inserted.is_empty());
        assert_eq!(last_ending(&c), [Notice::NothingHeard]);
    }

    #[test]
    fn results_for_a_job_not_in_progress_are_ignored() {
        let mut c = controller();
        c.transcribed(Job(7), Ok("Ship it.".to_owned()));
        c.inserted(Job(7), Ok(pasted(8)), 100);
        assert!(c.is_idle());
        assert!(c.dependencies().endings.is_empty());

        let job = dictate(&mut c, 0, 500);
        c.inserted(job, Ok(pasted(8)), 600);
        assert!(!c.is_idle(), "typing results mean nothing while transcribing");
    }

    #[test]
    fn nothing_is_recorded_in_a_password_field() {
        let mut c = controller();
        c.dependencies_mut().target.is_secure = true;
        c.hotkey(HotkeyEvent::Pressed, 0);
        c.hotkey(HotkeyEvent::Released, 500);
        assert!(c.is_idle());
        assert_eq!(c.dependencies().starts, 0, "the microphone never opened");
        assert_eq!(c.dependencies().endings, [vec![Notice::SecureField]]);
    }

    #[test]
    fn focus_moving_to_a_password_field_stops_the_text() {
        let mut c = controller();
        let job = dictate(&mut c, 0, 500);
        c.dependencies_mut().target.is_secure = true;
        c.transcribed(job, Ok("Ship it.".to_owned()));
        assert!(c.dependencies().inserted.is_empty());
        assert_eq!(last_ending(&c), [Notice::SecureField]);
        assert_eq!(c.last_text(), None);
    }

    #[test]
    fn a_space_goes_before_text_that_follows_a_word() {
        let mut c = controller();
        c.dependencies_mut().target.preceding = Some('o');
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Ok("Ship it.".to_owned()));
        assert_eq!(c.dependencies().inserted, [(job, " Ship it.".to_owned())]);
        assert_eq!(c.last_text(), Some("Ship it."), "copied without the space");
    }

    /// A controller whose levels clean up with the model.
    fn cleaning_controller() -> DictationController<Fake> {
        let mut c = controller();
        let configuration = ControllerConfiguration {
            cleans_with_model: true,
            ..c.configuration.clone()
        };
        c.set_configuration(configuration);
        c
    }

    fn accepted(text: &str) -> CleanedText {
        CleanedText {
            text: text.to_owned(),
            fallback_reason: None,
            latency_ms: 240,
        }
    }

    #[test]
    fn the_model_cleans_the_transcript_before_it_is_typed() {
        let mut c = cleaning_controller();
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Ok("um ship it on friday no wait monday".to_owned()));
        assert!(
            c.dependencies().inserted.is_empty(),
            "nothing is typed while the model works"
        );
        assert_eq!(c.phase(), Phase::Processing { audio_ms: 500 });
        let (cleaning, text, options) = c.dependencies().cleaning.last().cloned().expect("a cleanup");
        assert_eq!(cleaning, job);
        assert_eq!(
            text, "um ship it on friday no wait monday",
            "fillers go in the model's own step"
        );
        assert_eq!(options.level, CleanupLevel::Medium);
        assert!(!options.multiline);

        c.cleaned(job, accepted("Ship it on Monday."));
        assert_eq!(c.dependencies().inserted, [(job, "Ship it on Monday.".to_owned())]);
        c.inserted(job, Ok(pasted(18)), 1_200);
        assert!(c.is_idle());
    }

    #[test]
    fn a_fallback_types_the_text_the_model_was_given() {
        let mut c = cleaning_controller();
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Ok("um ship it on friday".to_owned()));
        c.cleaned(
            job,
            CleanedText {
                text: "ship it on friday".to_owned(),
                fallback_reason: Some(lt_cleanup::FallbackReason::TimedOut { seconds: 3.0 }),
                latency_ms: 3_000,
            },
        );
        assert_eq!(c.dependencies().inserted, [(job, "ship it on friday".to_owned())]);
    }

    #[test]
    fn levels_without_the_model_and_the_model_turned_off_type_at_once() {
        let mut c = cleaning_controller();
        c.set_cleanup_level(CleanupLevel::None);
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Ok("Um, ship it on Friday.".to_owned()));
        assert!(c.dependencies().cleaning.is_empty());
        assert_eq!(c.dependencies().inserted, [(job, "Um, ship it on Friday.".to_owned())]);

        let mut c = controller();
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Ok("Um, ship it on Friday.".to_owned()));
        assert!(c.dependencies().cleaning.is_empty());
        assert_eq!(c.dependencies().inserted, [(job, "Ship it on Friday.".to_owned())]);
    }

    #[test]
    fn escape_while_cleaning_stops_the_model_and_drops_its_result() {
        let mut c = cleaning_controller();
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Ok("ship it on friday".to_owned()));
        c.hotkey(HotkeyEvent::Pressed, 600);
        assert_eq!(c.dependencies().progress, [Notice::StillProcessing]);
        c.hotkey(HotkeyEvent::Escape, 700);
        assert!(c.is_idle());
        assert_eq!(c.dependencies().cleanups_cancelled, [job]);
        assert_eq!(last_ending(&c), [Notice::Cancelled]);
        c.cleaned(job, accepted("Ship it on Friday."));
        assert!(c.dependencies().inserted.is_empty());
    }

    #[test]
    fn a_letter_s_body_is_cleaned_and_its_greeting_and_sign_off_kept() {
        let mut c = cleaning_controller();
        c.dependencies_mut().target.allows_line_breaks = true;
        let job = dictate(&mut c, 0, 500);
        c.transcribed(
            job,
            // Names are known by the capitals speech to text gives them.
            Ok("hi John thanks for the update I will review it tomorrow cheers Sam".to_owned()),
        );
        let (_, text, options) = c.dependencies().cleaning.last().cloned().expect("a cleanup");
        assert_eq!(text, "thanks for the update I will review it tomorrow");
        assert!(options.multiline);
        c.cleaned(job, accepted("Thanks for the update. I will review it tomorrow."));
        assert_eq!(
            c.dependencies().inserted,
            [(
                job,
                "Hi John,\n\nThanks for the update. I will review it tomorrow.\n\nCheers,\nSam".to_owned()
            )]
        );
    }

    #[test]
    fn the_cleanup_level_set_from_the_menu_applies_to_what_is_transcribed_next() {
        let said = "Um, ship it on Friday.";
        let at = |level| {
            finish(
                said,
                &Configuration {
                    level,
                    ..controller().configuration.text.clone()
                },
            )
            .text
        };
        assert_ne!(at(CleanupLevel::None), at(CleanupLevel::Medium), "fillers stay at None");

        let mut c = controller();
        let job = dictate(&mut c, 0, 500);
        c.set_cleanup_level(CleanupLevel::None);
        assert_eq!(c.cleanup_level(), CleanupLevel::None);
        c.transcribed(job, Ok(said.to_owned()));
        assert_eq!(c.dependencies().inserted, [(job, at(CleanupLevel::None))]);
    }

    #[test]
    fn text_for_a_private_field_goes_in_but_isnt_kept() {
        let mut c = controller();
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Ok("Ship it.".to_owned()));
        assert_eq!(c.last_text(), Some("Ship it."));

        c.inserted(job, Ok(pasted(8)), 600);
        c.dependencies_mut().target.is_private = true;
        let job = dictate(&mut c, 1_000, 1_500);
        c.transcribed(job, Ok("My card number.".to_owned()));
        assert_eq!(
            c.dependencies().inserted.last(),
            Some(&(job, "My card number.".to_owned()))
        );
        assert_eq!(c.last_text(), None, "not even the dictation before it");
    }

    #[test]
    fn fields_that_take_several_lines_get_line_breaks() {
        let said = "First point new line second point.";
        let one_line = finish(said, &controller().configuration.text).text;
        let lines = finish(
            said,
            &Configuration {
                multiline: true,
                ..controller().configuration.text.clone()
            },
        )
        .text;
        assert_ne!(one_line, lines, "the rules lay spoken line breaks out differently");

        let mut c = controller();
        c.dependencies_mut().target.allows_line_breaks = true;
        let job = dictate(&mut c, 0, 500);
        c.transcribed(job, Ok(said.to_owned()));
        assert_eq!(c.dependencies().inserted, [(job, lines)]);
    }

    #[test]
    fn the_menu_starts_a_hands_free_dictation_the_hotkey_finishes() {
        let mut c = controller();
        c.toggle_dictation(0);
        assert_eq!(c.phase(), Phase::Recording { hands_free: true });
        c.hotkey(HotkeyEvent::OtherKey, 1_000);
        assert!(c.is_recording(), "typing doesn't cancel it");
        c.hotkey(HotkeyEvent::Pressed, 3_000);
        assert_eq!(c.phase(), Phase::Processing { audio_ms: 500 });
        c.hotkey(HotkeyEvent::Released, 3_100);
        assert_eq!(c.dependencies().starts, 1);
        assert_eq!(c.dependencies().transcribing.len(), 1);
    }

    #[test]
    fn the_menu_stops_and_cancels_too() {
        let mut c = controller();
        c.toggle_dictation(0);
        c.toggle_dictation(2_000);
        assert_eq!(c.dependencies().transcribing.len(), 1);
        c.cancel();
        assert!(c.is_idle());
        assert_eq!(last_ending(&c), [Notice::Cancelled]);

        c.toggle_dictation(5_000);
        c.hotkey(HotkeyEvent::Escape, 6_000);
        assert!(c.is_idle());
        assert_eq!(c.dependencies().cancels, 1);
        assert_eq!(last_ending(&c), [Notice::Cancelled]);

        // The next dictation from the hotkey is an ordinary one.
        c.hotkey(HotkeyEvent::Pressed, 7_000);
        assert_eq!(c.phase(), Phase::Recording { hands_free: false });
    }
}
