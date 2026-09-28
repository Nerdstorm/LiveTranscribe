use std::collections::HashSet;

/// Tokens that end a reply, and are not part of it: `<|im_end|>` and `<|endoftext|>`.
pub const END_OF_REPLY: [u32; 2] = [151_645, 151_643];

/// Tokens of the loop guard's window, and the most different tokens a window may hold before the
/// reply counts as a loop.
const LOOP_WINDOW: usize = 24;
const LOOP_MAX_DISTINCT: usize = 3;

/// Why a reply ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stop {
    /// The model ended its reply.
    EndOfReply,
    /// The last 24 tokens held 3 or fewer different tokens: the model was looping.
    Loop,
    /// The reply reached its token limit.
    Limit,
}

/// A reply's tokens, and why it ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Decoded {
    pub tokens: Vec<u32>,
    pub stop: Stop,
}

/// Greedy decoding, as mlx-audio-swift's Qwen3-ASR runs it at temperature 0 with no repetition
/// penalty (the Mac app's settings):
///
/// - the first token is the likeliest after the prompt (`first_logits`); every next one is the
///   likeliest after the tokens so far, which `next_logits` gives for the token just chosen;
/// - an end-of-reply token ends the reply and is not part of it;
/// - once the reply has 24 tokens, it ends as soon as its last 24 hold 3 or fewer different tokens;
/// - it ends at `max_tokens` tokens.
pub fn decode_greedily<E>(
    first_logits: &[f32],
    max_tokens: usize,
    mut next_logits: impl FnMut(u32) -> Result<Vec<f32>, E>,
) -> Result<Decoded, E> {
    let mut tokens = Vec::new();
    let mut next = likeliest(first_logits);
    for index in 0..max_tokens {
        if END_OF_REPLY.contains(&next) {
            return Ok(Decoded {
                tokens,
                stop: Stop::EndOfReply,
            });
        }
        tokens.push(next);
        if is_looping(&tokens) {
            return Ok(Decoded {
                tokens,
                stop: Stop::Loop,
            });
        }
        if index == max_tokens - 1 {
            break;
        }
        next = likeliest(&next_logits(next)?);
    }
    Ok(Decoded {
        tokens,
        stop: Stop::Limit,
    })
}

/// The index of the largest logit, the first of equals.
fn likeliest(logits: &[f32]) -> u32 {
    let mut best = 0;
    for (index, &logit) in logits.iter().enumerate() {
        if logit > logits[best] {
            best = index;
        }
    }
    u32::try_from(best).expect("a vocabulary fits in u32")
}

fn is_looping(tokens: &[u32]) -> bool {
    tokens.len() >= LOOP_WINDOW
        && tokens[tokens.len() - LOOP_WINDOW..]
            .iter()
            .collect::<HashSet<_>>()
            .len()
            <= LOOP_MAX_DISTINCT
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Logits that pick `token` out of 151,936.
    fn picking(token: u32) -> Vec<f32> {
        let mut logits = vec![0.0; 151_936];
        logits[token as usize] = 1.0;
        logits
    }

    /// Decodes a scripted reply: each call returns the logits for the next scripted token.
    fn decode(script: &[u32], max_tokens: usize) -> (Decoded, usize) {
        let mut steps = 0;
        let decoded = decode_greedily::<()>(&picking(script[0]), max_tokens, |_| {
            steps += 1;
            Ok(picking(script[steps]))
        })
        .unwrap();
        (decoded, steps)
    }

    #[test]
    fn ends_at_the_end_of_the_reply() {
        let (decoded, steps) = decode(&[10, 11, 151_645, 12], 100);
        assert_eq!(decoded.tokens, [10, 11]);
        assert_eq!(decoded.stop, Stop::EndOfReply);
        assert_eq!(steps, 2);
    }

    #[test]
    fn ends_at_the_limit_without_a_step_past_it() {
        let (decoded, steps) = decode(&[1, 2, 3, 4, 5, 6], 3);
        assert_eq!(decoded.tokens, [1, 2, 3]);
        assert_eq!(decoded.stop, Stop::Limit);
        assert_eq!(steps, 2);
        assert!(decode(&[1], 0).0.tokens.is_empty());
    }

    #[test]
    fn ends_a_loop_of_three_tokens_after_twenty_four() {
        let script: Vec<u32> = (0..100).map(|n| 7 + n % 3).collect();
        let (decoded, _) = decode(&script, 1_000);
        assert_eq!(decoded.tokens.len(), 24);
        assert_eq!(decoded.stop, Stop::Loop);
    }

    #[test]
    fn a_loop_of_four_tokens_runs_to_the_limit() {
        // A Sinhala word is often more tokens than the guard's three: the output limit stops it.
        let script: Vec<u32> = (0..1_000).map(|n| 7 + n % 4).collect();
        let (decoded, _) = decode(&script, 300);
        assert_eq!(decoded.tokens.len(), 300);
        assert_eq!(decoded.stop, Stop::Limit);
    }

    #[test]
    fn ties_go_to_the_first_token() {
        assert_eq!(likeliest(&[0.5, 2.0, 2.0, 1.0]), 1);
    }
}
