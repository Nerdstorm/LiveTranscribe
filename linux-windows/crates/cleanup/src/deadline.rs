//! When a generation must stop: its time is up, or the cleanup was cancelled.
//!
//! The Mac app races the model against a timer (`withDeadline`, in Shared/Deadline.swift) and
//! cancels its task when the timer wins. This app runs the model synchronously on a thread of its
//! own, so the model is told when to stop instead: it checks [`Deadline::should_stop`] between
//! tokens, and the executor judges the outcome as the race would have ended.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// Where cleanup reads the time: the system's monotonic clock, or a test's.
pub trait Clock: Send + Sync {
    fn now(&self) -> Instant;
}

/// The system's monotonic clock.
#[derive(Clone, Copy, Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// Stops a cleanup from any thread: the model stops generating, and the cleanup falls back with
/// "cancelled". Clones share one flag.
#[derive(Clone, Debug, Default)]
pub struct CancelFlag(Arc<AtomicBool>);

impl CancelFlag {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }
}

/// One generation's limits: a time, and the cleanup's cancel flag.
pub struct Deadline<'a> {
    clock: &'a dyn Clock,
    /// `None`: too far away to happen.
    due: Option<Instant>,
    seconds: f64,
    cancel: &'a CancelFlag,
}

impl<'a> Deadline<'a> {
    /// A deadline `seconds` from now on `clock`. A time that is not positive has already passed.
    pub fn new(clock: &'a dyn Clock, seconds: f64, cancel: &'a CancelFlag) -> Self {
        let now = clock.now();
        let due = if seconds > 0.0 {
            Duration::try_from_secs_f64(seconds)
                .ok()
                .and_then(|limit| now.checked_add(limit))
        } else {
            Some(now)
        };
        Self {
            clock,
            due,
            seconds,
            cancel,
        }
    }

    /// The time the generation was given, as a timeout reports it.
    pub fn seconds(&self) -> f64 {
        self.seconds
    }

    /// Whether the time is up.
    pub fn has_passed(&self) -> bool {
        self.due.is_some_and(|due| self.clock.now() >= due)
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.is_cancelled()
    }

    /// Whether the model should stop generating now: the time is up, or the cleanup was cancelled.
    pub fn should_stop(&self) -> bool {
        self.is_cancelled() || self.has_passed()
    }

    /// The time left; `None` when there is no limit.
    pub fn remaining(&self) -> Option<Duration> {
        self.due.map(|due| due.saturating_duration_since(self.clock.now()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::FakeClock;

    #[test]
    fn a_deadline_passes_after_its_time() {
        let clock = FakeClock::new();
        let cancel = CancelFlag::new();
        let deadline = Deadline::new(clock.as_ref(), 0.5, &cancel);
        assert!(!deadline.should_stop());
        assert_eq!(deadline.remaining(), Some(Duration::from_millis(500)));
        clock.advance(Duration::from_millis(499));
        assert!(!deadline.has_passed());
        clock.advance(Duration::from_millis(1));
        assert!(deadline.has_passed() && deadline.should_stop());
        assert_eq!(deadline.remaining(), Some(Duration::ZERO));
        assert_eq!(deadline.seconds(), 0.5);
    }

    #[test]
    fn cancelling_stops_the_generation_from_any_clone() {
        let clock = FakeClock::new();
        let cancel = CancelFlag::new();
        let deadline = Deadline::new(clock.as_ref(), 10.0, &cancel);
        cancel.clone().cancel();
        assert!(deadline.is_cancelled() && deadline.should_stop());
        assert!(!deadline.has_passed());
    }

    #[test]
    fn a_time_that_is_not_positive_has_passed_and_an_unrepresentable_one_never_does() {
        let clock = FakeClock::new();
        let cancel = CancelFlag::new();
        assert!(Deadline::new(clock.as_ref(), 0.0, &cancel).has_passed());
        assert!(Deadline::new(clock.as_ref(), -1.0, &cancel).has_passed());
        assert!(Deadline::new(clock.as_ref(), f64::NAN, &cancel).has_passed());
        let endless = Deadline::new(clock.as_ref(), f64::INFINITY, &cancel);
        assert!(!endless.has_passed());
        assert_eq!(endless.remaining(), None);
    }
}
