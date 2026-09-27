//! The audio format shared by every stage after capture.
//!
//! This is a model requirement rather than a tunable: Silero VAD and Qwen3-ASR both expect 16 kHz
//! mono float32 samples.

pub const SAMPLE_RATE: usize = 16_000;

pub const fn milliseconds_for_samples(count: usize) -> usize {
    count * 1_000 / SAMPLE_RATE
}

pub const fn samples_for_milliseconds(milliseconds: usize) -> usize {
    milliseconds * SAMPLE_RATE / 1_000
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_between_samples_and_milliseconds() {
        assert_eq!(samples_for_milliseconds(100), 1_600);
        assert_eq!(milliseconds_for_samples(16_000), 1_000);
        assert_eq!(milliseconds_for_samples(159), 9);
    }
}
