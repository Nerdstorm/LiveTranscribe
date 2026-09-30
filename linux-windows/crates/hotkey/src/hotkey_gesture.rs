//! The push-to-talk gesture as a pure state machine, ported from the Mac app's
//! HotkeyGesture.swift with its tests.
//!
//! - Hold for at least `tap_max_ms`, then release: the recording is processed.
//! - Tap, then press again within `double_tap_window_ms`: hands-free. The second press's release
//!   is ignored; the next press stops and processes, and its release is ignored too.
//! - A lone tap is cancelled: too short to be speech.
//! - Esc while recording (held, waiting for a second tap, or hands-free) cancels.
//! - Another key while the hotkey is held (before hands-free) cancels: the user is typing a
//!   shortcut. In hands-free the user is expected to type, so other keys are ignored.
//!
//! Recording starts on the first press, so audio from the first word is never lost while the
//! gesture decides what the press was. Inputs that make no sense in the current state are
//! ignored, and `StartRecording` is never emitted twice without a stop or cancel between.
//!
//! Time comes in as milliseconds from one monotonic clock, so the machine is deterministic and
//! needs no real timers: when it needs one it asks with [`HotkeyAction::ScheduleTimer`].
//!
//! The gesture ends at `StopAndProcess`. Cancelling the processing that follows (Esc while
//! transcribing) is the dictation flow's job: here Esc when idle is ignored.

/// Timing for [`HotkeyGesture`]. The values come from settings; there are deliberately no
/// defaults here, so the app's choices live in one place.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HotkeyGestureConfiguration {
    /// A press released sooner than this is a tap; held this long or longer it is push-to-talk.
    pub tap_max_ms: u64,
    /// After a tap, a second press within this window starts hands-free recording.
    pub double_tap_window_ms: u64,
    /// Whether a double tap starts hands-free recording. When off, every tap is cancelled.
    pub hands_free_enabled: bool,
}

/// What happened to the hotkey, as the gesture sees it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HotkeyInput {
    Pressed,
    Released,
    /// Esc was pressed.
    Escape,
    /// Another key was pressed while the hotkey was held.
    OtherKey,
    /// The timer from the last [`HotkeyAction::ScheduleTimer`] ran out.
    TimerFired,
}

/// What the dictation flow should do in response to an input.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HotkeyAction {
    /// Start capturing audio.
    StartRecording,
    /// Stop capturing and transcribe, clean up and insert what was said.
    StopAndProcess,
    /// Stop capturing and throw the audio away.
    Cancel,
    /// A double tap turned the recording into hands-free: it continues without the key held.
    EnteredHandsFree,
    /// Call [`HotkeyGesture::handle`] with [`HotkeyInput::TimerFired`] after `ms`.
    ///
    /// Every timer asked for must fire exactly once and is never cancelled; timers fire in the
    /// order they were asked for (they all have the same length). The time passed with the firing
    /// should come from the same clock as the other inputs. A timer left over from an earlier tap
    /// is recognised and ignored.
    ScheduleTimer { ms: u64 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Idle,
    /// Recording with the key down since `pressed_at`; not yet known to be a hold or a tap.
    Held {
        pressed_at: u64,
    },
    /// Recording after a tap released at `released_at`; a second press makes it hands-free.
    AwaitingSecondPress {
        released_at: u64,
    },
    /// Recording hands-free. `key_down` is true while the press that started it is still held.
    HandsFree {
        key_down: bool,
    },
}

#[derive(Clone, Debug)]
pub struct HotkeyGesture {
    configuration: HotkeyGestureConfiguration,
    /// The configuration for the next gesture, set while one was in progress.
    next: Option<HotkeyGestureConfiguration>,
    phase: Phase,
    /// Timers asked for and not yet fired. Timers are never cancelled, so one from an earlier
    /// tap can still be pending when a new tap waits for its second press.
    timers_pending: u32,
}

impl HotkeyGesture {
    pub fn new(configuration: HotkeyGestureConfiguration) -> Self {
        Self {
            configuration,
            next: None,
            phase: Phase::Idle,
            timers_pending: 0,
        }
    }

    /// The configuration the gesture in progress uses, or the next one will.
    pub fn configuration(&self) -> HotkeyGestureConfiguration {
        self.next.unwrap_or(self.configuration)
    }

    /// Uses `configuration` from the next gesture on: one in progress keeps the timing it
    /// started with, so a change never cuts a tap's window short or turns a hold into a tap.
    pub fn set_configuration(&mut self, configuration: HotkeyGestureConfiguration) {
        self.next = Some(configuration);
        self.take_next_if_idle();
    }

    fn take_next_if_idle(&mut self) {
        if self.phase == Phase::Idle
            && let Some(next) = self.next.take()
        {
            self.configuration = next;
        }
    }

    /// Whether audio is being recorded: from `StartRecording` until `StopAndProcess` or `Cancel`.
    pub fn is_recording(&self) -> bool {
        self.phase != Phase::Idle
    }

    /// Whether the recording continues without the key held.
    pub fn is_hands_free(&self) -> bool {
        matches!(self.phase, Phase::HandsFree { .. })
    }

    /// Returns to idle without emitting anything. Timers already asked for may still fire; they
    /// are ignored as usual.
    ///
    /// For when the owner has already stopped or abandoned the recording itself (the recording
    /// could not start, or the flow refused to record), so a release that will never arrive
    /// does not leave the gesture held.
    pub fn reset(&mut self) {
        self.phase = Phase::Idle;
        self.take_next_if_idle();
    }

    /// Advances the machine and returns what to do, in order. Empty when the input is ignored.
    pub fn handle(&mut self, input: HotkeyInput, now_ms: u64) -> Vec<HotkeyAction> {
        use HotkeyAction as Action;
        use HotkeyInput as Input;

        if input == Input::TimerFired {
            self.timers_pending = self.timers_pending.saturating_sub(1);
        }
        self.take_next_if_idle();
        let window = self.configuration.double_tap_window_ms;
        match (self.phase, input) {
            (Phase::Idle, Input::Pressed) => {
                self.phase = Phase::Held { pressed_at: now_ms };
                vec![Action::StartRecording]
            }

            (Phase::Held { pressed_at }, Input::Released) => {
                if now_ms.saturating_sub(pressed_at) >= self.configuration.tap_max_ms {
                    self.phase = Phase::Idle;
                    return vec![Action::StopAndProcess];
                }
                if !self.configuration.hands_free_enabled {
                    self.phase = Phase::Idle;
                    return vec![Action::Cancel];
                }
                self.phase = Phase::AwaitingSecondPress { released_at: now_ms };
                self.timers_pending += 1;
                vec![Action::ScheduleTimer { ms: window }]
            }

            (Phase::Held { .. }, Input::Escape | Input::OtherKey) => {
                self.phase = Phase::Idle;
                vec![Action::Cancel]
            }

            (Phase::AwaitingSecondPress { released_at }, Input::Pressed) => {
                if now_ms.saturating_sub(released_at) <= window {
                    self.phase = Phase::HandsFree { key_down: true };
                    return vec![Action::EnteredHandsFree];
                }
                // The window ran out before its timer was delivered: the first tap was a lone
                // tap, and this press starts a new gesture rather than being lost.
                self.phase = Phase::Held { pressed_at: now_ms };
                vec![Action::Cancel, Action::StartRecording]
            }

            (Phase::AwaitingSecondPress { released_at }, Input::TimerFired) => {
                // A timer from an earlier tap must not cut this window short. A timer is ignored
                // only when both signs say it is stale: a later timer is still pending, and this
                // tap's deadline has not passed. If only one says so, the window ends anyway, so
                // a caller whose timer clock differs slightly from the inputs', or who lost a
                // timer, can never leave a recording running.
                let is_stale = self.timers_pending > 0 && now_ms.saturating_sub(released_at) < window;
                if is_stale {
                    return Vec::new();
                }
                self.phase = Phase::Idle;
                vec![Action::Cancel]
            }

            (Phase::AwaitingSecondPress { .. }, Input::Escape) => {
                self.phase = Phase::Idle;
                vec![Action::Cancel]
            }

            (Phase::HandsFree { key_down: true }, Input::Released) => {
                self.phase = Phase::HandsFree { key_down: false };
                Vec::new()
            }

            (Phase::HandsFree { key_down: false }, Input::Pressed) => {
                // Stop on press; the release that follows arrives in idle and is ignored.
                self.phase = Phase::Idle;
                vec![Action::StopAndProcess]
            }

            (Phase::HandsFree { .. }, Input::Escape) => {
                self.phase = Phase::Idle;
                vec![Action::Cancel]
            }

            // Duplicate presses, releases with nothing held, stale timers, other keys in
            // hands-free or when idle: nothing to do.
            _ => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::HotkeyAction::*;
    use super::HotkeyInput::*;
    use super::*;

    const TAP_MAX_MS: u64 = 300;
    const WINDOW_MS: u64 = 300;

    fn gesture(hands_free: bool) -> HotkeyGesture {
        HotkeyGesture::new(HotkeyGestureConfiguration {
            tap_max_ms: TAP_MAX_MS,
            double_tap_window_ms: WINDOW_MS,
            hands_free_enabled: hands_free,
        })
    }

    /// Feeds `steps` (input at a time in ms) and returns the actions of each step.
    fn run(gesture: &mut HotkeyGesture, steps: &[(HotkeyInput, u64)]) -> Vec<Vec<HotkeyAction>> {
        steps.iter().map(|&(input, at)| gesture.handle(input, at)).collect()
    }

    const TIMER: HotkeyAction = ScheduleTimer { ms: WINDOW_MS };

    // Push-to-talk

    #[test]
    fn a_hold_of_at_least_tap_max_ms_is_processed_on_release() {
        for held_ms in [300, 301, 5_000] {
            let mut gesture = gesture(true);
            assert_eq!(
                run(&mut gesture, &[(Pressed, 0), (Released, held_ms)]),
                [vec![StartRecording], vec![StopAndProcess]]
            );
            assert!(!gesture.is_recording());
        }
    }

    #[test]
    fn recording_starts_on_press() {
        let mut gesture = gesture(true);
        assert_eq!(gesture.handle(Pressed, 1_000), [StartRecording]);
        assert!(gesture.is_recording());
        assert!(!gesture.is_hands_free());
    }

    #[test]
    fn new_timing_waits_for_the_gesture_in_progress_to_end() {
        let mut gesture = gesture(true);
        let slower = HotkeyGestureConfiguration {
            tap_max_ms: 600,
            double_tap_window_ms: 500,
            hands_free_enabled: false,
        };
        gesture.handle(Pressed, 0);
        gesture.set_configuration(slower);
        assert_eq!(gesture.configuration(), slower, "what the next gesture uses");
        // Still the old timing: a 400 ms hold is a hold, not a tap.
        assert_eq!(gesture.handle(Released, 400), [StopAndProcess]);
        // The next gesture has the new timing: 400 ms is a tap now, and without hands-free a tap
        // is cancelled.
        assert_eq!(
            run(&mut gesture, &[(Pressed, 1_000), (Released, 1_400)]),
            [vec![StartRecording], vec![Cancel]]
        );
    }

    #[test]
    fn new_timing_applies_at_once_between_gestures() {
        let mut gesture = gesture(true);
        gesture.set_configuration(HotkeyGestureConfiguration {
            tap_max_ms: 100,
            double_tap_window_ms: WINDOW_MS,
            hands_free_enabled: true,
        });
        assert_eq!(
            run(&mut gesture, &[(Pressed, 0), (Released, 150)]),
            [vec![StartRecording], vec![StopAndProcess]]
        );
    }

    // Taps

    #[test]
    fn a_short_tap_waits_for_a_second_press() {
        for held_ms in [0, 150, 299] {
            let mut gesture = gesture(true);
            assert_eq!(
                run(&mut gesture, &[(Pressed, 0), (Released, held_ms)]),
                [vec![StartRecording], vec![TIMER]]
            );
            assert!(
                gesture.is_recording(),
                "audio keeps recording in case this is a double tap"
            );
        }
    }

    #[test]
    fn a_lone_tap_is_cancelled_when_the_timer_fires() {
        let mut gesture = gesture(true);
        let actions = run(&mut gesture, &[(Pressed, 0), (Released, 100), (TimerFired, 400)]);
        assert_eq!(actions.last().unwrap(), &[Cancel]);
        assert!(!gesture.is_recording());
    }

    #[test]
    fn a_tap_is_cancelled_at_once_when_hands_free_is_off() {
        let mut gesture = gesture(false);
        assert_eq!(
            run(&mut gesture, &[(Pressed, 0), (Released, 100)]),
            [vec![StartRecording], vec![Cancel]]
        );
        assert!(!gesture.is_recording());
    }

    #[test]
    fn a_hold_still_works_when_hands_free_is_off() {
        let mut gesture = gesture(false);
        assert_eq!(
            run(&mut gesture, &[(Pressed, 0), (Released, 800)]),
            [vec![StartRecording], vec![StopAndProcess]]
        );
    }

    // Hands-free

    #[test]
    fn a_second_press_within_the_window_enters_hands_free() {
        for gap_ms in [0, 150, 300] {
            let mut gesture = gesture(true);
            let actions = run(&mut gesture, &[(Pressed, 0), (Released, 100), (Pressed, 100 + gap_ms)]);
            assert_eq!(actions.last().unwrap(), &[EnteredHandsFree]);
            assert!(gesture.is_recording());
            assert!(gesture.is_hands_free());
        }
    }

    #[test]
    fn hands_free_ignores_the_second_release_and_stops_on_the_next_press() {
        let mut gesture = gesture(true);
        let actions = run(
            &mut gesture,
            &[
                (Pressed, 0),
                (Released, 100),
                (Pressed, 200),    // double tap
                (Released, 2_000), // release of the second press: ignored
                (Pressed, 9_000),  // stop on press
                (Released, 9_100), // its release: ignored
            ],
        );
        assert_eq!(
            actions,
            [
                vec![StartRecording],
                vec![TIMER],
                vec![EnteredHandsFree],
                vec![],
                vec![StopAndProcess],
                vec![]
            ]
        );
        assert!(!gesture.is_recording());
        assert!(!gesture.is_hands_free());
    }

    #[test]
    fn a_timer_that_fires_after_entering_hands_free_is_ignored() {
        let mut gesture = gesture(true);
        let actions = run(
            &mut gesture,
            &[(Pressed, 0), (Released, 100), (Pressed, 200), (TimerFired, 400)],
        );
        assert_eq!(actions.last().unwrap(), &[]);
        assert!(gesture.is_hands_free());
    }

    #[test]
    fn a_press_after_the_window_cancels_the_tap_and_starts_anew() {
        let mut gesture = gesture(true);
        let actions = run(&mut gesture, &[(Pressed, 0), (Released, 100), (Pressed, 401)]);
        assert_eq!(
            actions.last().unwrap(),
            &[Cancel, StartRecording],
            "the late timer had not arrived yet"
        );
        assert!(gesture.is_recording());
        assert!(!gesture.is_hands_free());
        // The new press behaves like any first press, and the stale timer no longer matters.
        assert_eq!(
            run(&mut gesture, &[(TimerFired, 402), (Released, 1_000)]),
            [vec![], vec![StopAndProcess]]
        );
    }

    /// Timers are never cancelled. A quick double tap, a stop and a new tap all within one window
    /// leave the first tap's timer running; it must not end the new tap's window early.
    #[test]
    fn an_earlier_taps_timer_does_not_cut_a_new_window_short() {
        let mut gesture = gesture(true);
        let actions = run(
            &mut gesture,
            &[
                (Pressed, 0),
                (Released, 50), // timer A, due at 350
                (Pressed, 100),
                (Released, 150), // hands-free
                (Pressed, 200),
                (Released, 220), // stop
                (Pressed, 250),
                (Released, 300),   // a new tap: timer B, due at 600
                (TimerFired, 350), // timer A
                (Pressed, 500),    // within the new window
            ],
        );
        assert_eq!(
            actions,
            [
                vec![StartRecording],
                vec![TIMER],
                vec![EnteredHandsFree],
                vec![],
                vec![StopAndProcess],
                vec![],
                vec![StartRecording],
                vec![TIMER],
                vec![],
                vec![EnteredHandsFree],
            ]
        );
        assert!(gesture.is_hands_free());
    }

    #[test]
    fn the_windows_own_timer_ends_it_however_late() {
        for delay_ms in [300, 301, 2_000] {
            let mut gesture = gesture(true);
            run(&mut gesture, &[(Pressed, 0), (Released, 100)]);
            assert_eq!(gesture.handle(TimerFired, 100 + delay_ms), [Cancel]);
            assert!(!gesture.is_recording());
        }
    }

    /// A caller whose timer clock runs slightly ahead of the inputs' must not leave a recording
    /// running: the only pending timer is this tap's, whatever its time says.
    #[test]
    fn the_only_pending_timer_ends_the_window_even_if_it_looks_early() {
        let mut gesture = gesture(true);
        run(&mut gesture, &[(Pressed, 0), (Released, 100)]);
        assert_eq!(gesture.handle(TimerFired, 350), [Cancel]);
        assert!(!gesture.is_recording());
    }

    /// If the earlier tap's timer is delivered late, past the new tap's deadline, it ends the
    /// window just as the new tap's own timer would; that timer is then ignored.
    #[test]
    fn a_late_stale_timer_past_the_new_deadline_ends_the_window() {
        let mut gesture = gesture(true);
        run(
            &mut gesture,
            &[
                (Pressed, 0),
                (Released, 50),
                (Pressed, 100),
                (Released, 150), // hands-free
                (Pressed, 200),
                (Released, 220), // stop
                (Pressed, 250),
                (Released, 300), // a new tap, due at 600
            ],
        );
        assert_eq!(gesture.handle(TimerFired, 600), [Cancel]);
        assert_eq!(gesture.handle(TimerFired, 610), []);
        assert!(!gesture.is_recording());
    }

    // Esc

    #[test]
    fn escape_cancels_in_every_recording_state() {
        let cases: [&[(HotkeyInput, u64)]; 4] = [
            &[(Pressed, 0)],
            &[(Pressed, 0), (Released, 100)],
            &[(Pressed, 0), (Released, 100), (Pressed, 200)],
            &[(Pressed, 0), (Released, 100), (Pressed, 200), (Released, 300)],
        ];
        for steps in cases {
            let mut gesture = gesture(true);
            run(&mut gesture, steps);
            assert!(gesture.is_recording());
            assert_eq!(gesture.handle(Escape, 5_000), [Cancel]);
            assert!(!gesture.is_recording());
            assert!(!gesture.is_hands_free());
        }
    }

    #[test]
    fn escape_when_idle_is_ignored() {
        assert_eq!(gesture(true).handle(Escape, 0), []);
    }

    #[test]
    fn the_release_after_an_escape_is_ignored() {
        let mut gesture = gesture(true);
        assert_eq!(
            run(&mut gesture, &[(Pressed, 0), (Escape, 500), (Released, 900)]),
            [vec![StartRecording], vec![Cancel], vec![]]
        );
    }

    // Other keys

    #[test]
    fn another_key_while_held_cancels() {
        let mut gesture = gesture(true);
        assert_eq!(
            run(&mut gesture, &[(Pressed, 0), (OtherKey, 500), (Released, 900)]),
            [vec![StartRecording], vec![Cancel], vec![]]
        );
        assert!(!gesture.is_recording());
    }

    #[test]
    fn other_keys_are_ignored_in_hands_free() {
        let cases: [&[(HotkeyInput, u64)]; 2] = [
            &[(Pressed, 0), (Released, 100), (Pressed, 200)],
            &[(Pressed, 0), (Released, 100), (Pressed, 200), (Released, 300)],
        ];
        for steps in cases {
            let mut gesture = gesture(true);
            run(&mut gesture, steps);
            assert_eq!(gesture.handle(OtherKey, 1_000), []);
            assert!(gesture.is_hands_free());
        }
    }

    #[test]
    fn another_key_after_a_tap_is_ignored() {
        let mut gesture = gesture(true);
        run(&mut gesture, &[(Pressed, 0), (Released, 100)]);
        assert_eq!(gesture.handle(OtherKey, 150), []);
        assert!(gesture.is_recording());
    }

    // Ignored inputs

    #[test]
    fn inputs_that_make_no_sense_when_idle_are_ignored() {
        for input in [Released, Escape, OtherKey, TimerFired] {
            let mut gesture = gesture(true);
            assert_eq!(gesture.handle(input, 0), []);
            assert!(!gesture.is_recording());
        }
    }

    #[test]
    fn a_repeated_press_while_held_is_ignored() {
        let mut gesture = gesture(true);
        assert_eq!(
            run(&mut gesture, &[(Pressed, 0), (Pressed, 50), (TimerFired, 60)]),
            [vec![StartRecording], vec![], vec![]]
        );
    }

    #[test]
    fn a_repeated_press_in_hands_free_before_the_release_is_ignored() {
        let mut gesture = gesture(true);
        let actions = run(
            &mut gesture,
            &[(Pressed, 0), (Released, 100), (Pressed, 200), (Pressed, 250)],
        );
        assert_eq!(actions.last().unwrap(), &[]);
        assert!(
            gesture.is_hands_free(),
            "only a press after the second release stops hands-free"
        );
    }

    #[test]
    fn a_release_while_waiting_for_the_second_press_is_ignored() {
        let mut gesture = gesture(true);
        let actions = run(&mut gesture, &[(Pressed, 0), (Released, 100), (Released, 150)]);
        assert_eq!(actions.last().unwrap(), &[]);
    }

    #[test]
    fn reset_returns_to_idle_silently() {
        let mut gesture = gesture(true);
        run(&mut gesture, &[(Pressed, 0), (Released, 100), (Pressed, 200)]);
        gesture.reset();
        assert!(!gesture.is_recording());
        assert!(!gesture.is_hands_free());
        assert_eq!(gesture.handle(Pressed, 300), [StartRecording]);
    }

    // Invariants: properties that must hold for any input sequence, not just the scripted ones.

    /// A small deterministic generator, so the randomised tests are reproducible from the seed.
    struct SplitMix64(u64);

    impl SplitMix64 {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = self.0;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }
    }

    /// Random input sequences never start recording twice without a stop or cancel between, and
    /// `is_recording` always agrees with the actions emitted so far.
    #[test]
    fn never_starts_twice_without_a_stop_or_cancel() {
        let inputs = [Pressed, Released, Escape, OtherKey, TimerFired];
        for seed in 0..20_u64 {
            let mut random = SplitMix64(seed);
            let mut gesture = gesture(seed % 2 == 0);
            let mut recording = false;
            let mut now = 0;
            for _ in 0..500 {
                now += random.next() % 700;
                let input = inputs[(random.next() % inputs.len() as u64) as usize];
                for action in gesture.handle(input, now) {
                    match action {
                        StartRecording => {
                            assert!(!recording, "StartRecording while already recording (seed {seed})");
                            recording = true;
                        }
                        StopAndProcess | Cancel => {
                            assert!(recording, "{action:?} without a recording (seed {seed})");
                            recording = false;
                        }
                        EnteredHandsFree => assert!(recording),
                        ScheduleTimer { .. } => {}
                    }
                }
                assert_eq!(gesture.is_recording(), recording);
                if gesture.is_hands_free() {
                    assert!(gesture.is_recording());
                }
            }
        }
    }

    /// Real key presses with timers delivered as a controller would (each once, in order, at its
    /// deadline): a timer only ends a tap's window once that window is over, and no recording
    /// is left running after the key is released and every timer has fired.
    #[test]
    fn timers_never_end_a_window_early_or_leave_a_recording_running() {
        for seed in 0..20_u64 {
            let mut random = SplitMix64(seed);
            let mut run = TimedRun {
                gesture: gesture(true),
                deadlines: VecDeque::new(),
                last_tap_released_at: 0,
                seed,
            };
            let mut key_down = false;
            let mut now = 0;
            for _ in 0..300 {
                now += random.next() % 400;
                run.deliver_timers(now);
                let input = match random.next() % 10 {
                    0 => Escape,
                    1 if key_down => OtherKey,
                    _ if key_down => Released,
                    _ => Pressed,
                };
                if matches!(input, Pressed | Released) {
                    key_down = !key_down;
                }
                run.input(input, now);
            }
            if key_down {
                now += 1;
                run.input(Released, now);
            }
            run.deliver_timers(u64::MAX);
            assert!(
                !run.gesture.is_recording() || run.gesture.is_hands_free(),
                "seed {seed}"
            );
        }
    }

    /// A gesture driven like the controller drives it, with the timers it asks for queued.
    struct TimedRun {
        gesture: HotkeyGesture,
        deadlines: VecDeque<u64>,
        last_tap_released_at: u64,
        seed: u64,
    }

    impl TimedRun {
        fn input(&mut self, input: HotkeyInput, now: u64) {
            for action in self.gesture.handle(input, now) {
                if let ScheduleTimer { ms } = action {
                    self.deadlines.push_back(now + ms);
                    self.last_tap_released_at = now;
                }
            }
        }

        fn deliver_timers(&mut self, until: u64) {
            while let Some(&deadline) = self.deadlines.front()
                && deadline <= until
            {
                self.deadlines.pop_front();
                if self.gesture.handle(TimerFired, deadline) == [Cancel] {
                    assert!(
                        deadline - self.last_tap_released_at >= WINDOW_MS,
                        "a stale timer cut a window short (seed {})",
                        self.seed
                    );
                }
            }
        }
    }
}
