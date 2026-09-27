//! How long a transcript may run, set by the length of its audio.
//!
//! A speech-to-text model that falls into repeating a phrase carries on to its own limit: 8,192
//! tokens for Qwen3-ASR, about a minute of decoding, and all of it typed. The decoder's own guard
//! stops a loop only when its last 24 tokens hold 3 or fewer different tokens, and a Sinhala word
//! is often 8 tokens or more, as is a short English phrase. Speech takes about 3.6 tokens a second
//! in English and 8.2 in Sinhala, so 64 tokens plus 30 a second leaves real speech room to spare
//! and stops a loop within the length of its clip.

use lt_shared::audio_format::SAMPLE_RATE;

const BASE_TOKENS: usize = 64;
const TOKENS_PER_SECOND: usize = 30;

/// The most tokens a transcript of `sample_count` samples of 16 kHz audio may take.
pub fn max_tokens(sample_count: usize) -> usize {
    let seconds = sample_count as f64 / SAMPLE_RATE as f64;
    BASE_TOKENS + (seconds * TOKENS_PER_SECOND as f64).ceil() as usize
}

/// `limit` lowered to the limit for `sample_count` samples. The limit only ever lowers: a model
/// whose own limit is already lower keeps it, and so does one that doesn't count tokens (0).
pub fn capping(limit: usize, sample_count: usize) -> usize {
    limit.min(max_tokens(sample_count))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_sixty_four_tokens_and_thirty_a_second() {
        assert_eq!(max_tokens(0), 64);
        assert_eq!(max_tokens(SAMPLE_RATE), 94);
        assert_eq!(max_tokens(30 * SAMPLE_RATE), 964);
        // Part of a second rounds up: 8.88 s is 266.4 tokens' worth.
        assert_eq!(max_tokens(142_080), 331);
    }

    #[test]
    fn only_ever_lowers_a_limit() {
        assert_eq!(capping(8_192, 142_080), 331);
        assert_eq!(capping(200, 10 * SAMPLE_RATE), 200);
        assert_eq!(capping(0, 10 * SAMPLE_RATE), 0);
    }
}
