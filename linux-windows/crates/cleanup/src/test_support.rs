//! A clock and a model for tests, so timing and generation are scripted rather than waited for.

use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::{CleanupModel, CleanupRequest, Clock, Deadline};

/// A clock that moves only when told to, or by `tick` every time it is read.
pub(crate) struct FakeClock {
    start: Instant,
    elapsed: Mutex<Duration>,
    tick: Duration,
}

impl FakeClock {
    pub(crate) fn new() -> Arc<Self> {
        Self::ticking(Duration::ZERO)
    }

    /// A clock that moves on by `tick` after every reading.
    pub(crate) fn ticking(tick: Duration) -> Arc<Self> {
        Arc::new(Self {
            start: Instant::now(),
            elapsed: Mutex::new(Duration::ZERO),
            tick,
        })
    }

    pub(crate) fn advance(&self, by: Duration) {
        *self.elapsed.lock().expect("the clock is not poisoned") += by;
    }
}

impl Clock for FakeClock {
    fn now(&self) -> Instant {
        let mut elapsed = self.elapsed.lock().expect("the clock is not poisoned");
        let now = self.start + *elapsed;
        *elapsed += self.tick;
        now
    }
}

/// A failure a scripted model reports, with the message the fallback reason carries.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ScriptedFailure(pub(crate) String);

impl fmt::Display for ScriptedFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ScriptedFailure {}

/// A model that answers each request with `respond`, which is given how many requests came
/// before, and records every request.
pub(crate) struct ScriptedModel<F> {
    respond: F,
    pub(crate) requests: Vec<CleanupRequest>,
}

impl<F> ScriptedModel<F>
where
    F: FnMut(usize, &CleanupRequest, &Deadline<'_>) -> Result<String, ScriptedFailure>,
{
    pub(crate) fn new(respond: F) -> Self {
        Self {
            respond,
            requests: Vec::new(),
        }
    }
}

impl<F> CleanupModel for ScriptedModel<F>
where
    F: FnMut(usize, &CleanupRequest, &Deadline<'_>) -> Result<String, ScriptedFailure>,
{
    type Error = ScriptedFailure;

    fn generate(&mut self, request: &CleanupRequest, deadline: &Deadline<'_>) -> Result<String, ScriptedFailure> {
        let index = self.requests.len();
        self.requests.push(request.clone());
        (self.respond)(index, request, deadline)
    }
}

/// A model that replies `reply` to every request.
pub(crate) fn replying(
    reply: &str,
) -> ScriptedModel<impl FnMut(usize, &CleanupRequest, &Deadline<'_>) -> Result<String, ScriptedFailure>> {
    let reply = reply.to_owned();
    ScriptedModel::new(move |_, _, _| Ok(reply.clone()))
}
