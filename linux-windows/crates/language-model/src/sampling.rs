//! Choosing each token from the model's logits: greedily, as the Mac's cleanup does, or at random
//! from the likeliest, as Qwen3 recommends while it thinks (temperature 0.6, top-p 0.95, top-k 20).

/// How each token is chosen.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Sampling {
    /// The likeliest token, the first of equals.
    Greedy,
    /// A token drawn at random, as Hugging Face's `generate` draws one: the logits divided by
    /// `temperature`, then only the `top_k` likeliest kept (0 keeps all; a tie with the last is
    /// kept too), then only the likeliest whose probabilities add up to `top_p`. The same `seed`
    /// draws the same tokens from the same logits.
    Random {
        temperature: f32,
        top_p: f32,
        top_k: usize,
        seed: u64,
    },
}

impl Sampling {
    /// Qwen3's recommended settings while thinking.
    pub fn qwen3_thinking(seed: u64) -> Self {
        Self::Random {
            temperature: 0.6,
            top_p: 0.95,
            top_k: 20,
            seed,
        }
    }

    /// The settings a request gives, as the Mac's requests spell them: a temperature of 0 (or
    /// less) is greedy, whatever else is set.
    pub fn from_settings(temperature: f32, top_p: f32, top_k: usize, seed: u64) -> Self {
        if temperature <= 0.0 {
            Self::Greedy
        } else {
            Self::Random {
                temperature,
                top_p,
                top_k,
                seed,
            }
        }
    }
}

/// Chooses tokens for one reply.
#[derive(Debug)]
pub(crate) struct Sampler {
    sampling: Sampling,
    random: Xoshiro256,
}

impl Sampler {
    pub(crate) fn new(sampling: Sampling) -> Self {
        let seed = match sampling {
            Sampling::Greedy => 0,
            Sampling::Random { seed, .. } => seed,
        };
        Self {
            sampling,
            random: Xoshiro256::new(seed),
        }
    }

    /// The next token from one position's logits.
    pub(crate) fn choose(&mut self, logits: &[f32]) -> u32 {
        let index = match self.sampling {
            Sampling::Greedy => likeliest(logits),
            Sampling::Random {
                temperature,
                top_p,
                top_k,
                ..
            } => self.draw(logits, temperature, top_p, top_k),
        };
        u32::try_from(index).expect("a vocabulary fits in u32")
    }

    fn draw(&mut self, logits: &[f32], temperature: f32, top_p: f32, top_k: usize) -> usize {
        // Candidates, the likeliest first.
        let mut candidates: Vec<(usize, f32)> = logits
            .iter()
            .enumerate()
            .filter(|(_, logit)| !logit.is_nan())
            .map(|(index, &logit)| (index, logit / temperature))
            .collect();
        if candidates.is_empty() {
            return likeliest(logits);
        }
        if top_k > 0 && top_k < candidates.len() {
            candidates.select_nth_unstable_by(top_k - 1, |a, b| b.1.total_cmp(&a.1));
            let threshold = candidates[top_k - 1].1;
            candidates.retain(|&(_, logit)| logit >= threshold);
        }
        candidates.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
        let max = candidates[0].1;
        let mut probabilities: Vec<f64> = candidates
            .iter()
            .map(|&(_, logit)| f64::from(logit - max).exp())
            .collect();
        let total: f64 = probabilities.iter().sum();
        probabilities.iter_mut().for_each(|probability| *probability /= total);
        if top_p < 1.0 {
            // The smallest set of the likeliest whose probabilities reach top_p, at least one.
            let mut sum = 0.0;
            let kept = probabilities
                .iter()
                .position(|&probability| {
                    sum += probability;
                    sum >= f64::from(top_p)
                })
                .map_or(probabilities.len(), |last| last + 1);
            probabilities.truncate(kept);
        }
        let total: f64 = probabilities.iter().sum();
        let mut target = self.random.next_f64() * total;
        for (&(index, _), &probability) in candidates.iter().zip(&probabilities) {
            target -= probability;
            if target < 0.0 {
                return index;
            }
        }
        candidates[probabilities.len() - 1].0
    }
}

/// The index of the largest logit, the first of equals.
pub(crate) fn likeliest(logits: &[f32]) -> usize {
    let mut best = 0;
    for (index, &logit) in logits.iter().enumerate() {
        if logit > logits[best] {
            best = index;
        }
    }
    best
}

/// xoshiro256**, seeded through SplitMix64: small, fast, and the same everywhere, so a seed
/// replays a reply.
#[derive(Debug)]
struct Xoshiro256 {
    state: [u64; 4],
}

impl Xoshiro256 {
    fn new(seed: u64) -> Self {
        let mut split_mix = seed;
        let mut next = || {
            split_mix = split_mix.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = split_mix;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        };
        Self {
            state: [next(), next(), next(), next()],
        }
    }

    fn next_u64(&mut self) -> u64 {
        let result = self.state[1].wrapping_mul(5).rotate_left(7).wrapping_mul(9);
        let shifted = self.state[1] << 17;
        self.state[2] ^= self.state[0];
        self.state[3] ^= self.state[1];
        self.state[1] ^= self.state[2];
        self.state[0] ^= self.state[3];
        self.state[2] ^= shifted;
        self.state[3] = self.state[3].rotate_left(45);
        result
    }

    /// Uniform in [0, 1).
    fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1_u64 << 53) as f64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greedy_takes_the_first_of_the_likeliest() {
        let mut sampler = Sampler::new(Sampling::Greedy);
        assert_eq!(sampler.choose(&[0.5, 2.0, 2.0, 1.0]), 1);
    }

    #[test]
    fn a_temperature_of_zero_is_greedy() {
        assert_eq!(Sampling::from_settings(0.0, 1.0, 0, 7), Sampling::Greedy);
    }

    #[test]
    fn draws_only_from_the_top_k() {
        let logits = [5.0, 4.9, 1.0, 0.5, 4.8];
        let mut sampler = Sampler::new(Sampling::Random {
            temperature: 1.0,
            top_p: 1.0,
            top_k: 2,
            seed: 1,
        });
        for _ in 0..200 {
            assert!([0, 1].contains(&sampler.choose(&logits)));
        }
    }

    #[test]
    fn draws_only_from_the_nucleus() {
        // The first two hold about 0.88 of the probability; top-p 0.8 keeps them only.
        let logits = [3.0, 2.5, 0.0, 0.0, 0.0];
        let mut sampler = Sampler::new(Sampling::Random {
            temperature: 1.0,
            top_p: 0.8,
            top_k: 0,
            seed: 2,
        });
        let mut seen = [0; 5];
        for _ in 0..500 {
            seen[sampler.choose(&logits) as usize] += 1;
        }
        assert_eq!(seen[2..], [0, 0, 0]);
        assert!(seen[0] > seen[1] && seen[1] > 0, "{seen:?}");
    }

    #[test]
    fn a_seed_replays_its_draws() {
        let logits: Vec<f32> = (0..100).map(|index| (index % 7) as f32).collect();
        let draws = |seed| {
            let mut sampler = Sampler::new(Sampling::qwen3_thinking(seed));
            (0..50).map(|_| sampler.choose(&logits)).collect::<Vec<_>>()
        };
        assert_eq!(draws(42), draws(42));
        assert_ne!(draws(42), draws(43));
    }

    #[test]
    fn the_generator_matches_the_reference_output() {
        // xoshiro256** from state [1, 2, 3, 4]: the first outputs from the reference C code.
        let mut random = Xoshiro256 { state: [1, 2, 3, 4] };
        assert_eq!(random.next_u64(), 11_520);
        assert_eq!(random.next_u64(), 0);
        assert_eq!(random.next_u64(), 1_509_978_240);
        assert_eq!(random.next_u64(), 1_215_971_899_390_074_240);
    }
}
