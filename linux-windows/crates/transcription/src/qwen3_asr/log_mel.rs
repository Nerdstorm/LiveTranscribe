use std::fmt;
use std::sync::Arc;

use realfft::num_complex::Complex;
use realfft::{RealFftPlanner, RealToComplex};

/// Samples per analysis frame, and between frames, at 16 kHz.
pub const N_FFT: usize = 400;
pub const HOP_LENGTH: usize = 160;
/// Mel bands per frame.
pub const MEL_BINS: usize = 128;

const FREQUENCY_BINS: usize = N_FFT / 2 + 1;
const PADDING: usize = N_FFT / 2;

/// A clip's log-mel features: [`MEL_BINS`] values per frame, frame after frame.
#[derive(Clone, Debug, PartialEq)]
pub struct LogMel {
    values: Vec<f32>,
}

impl LogMel {
    pub fn frames(&self) -> usize {
        self.values.len() / MEL_BINS
    }

    /// Every value, frame after frame.
    pub fn values(&self) -> &[f32] {
        &self.values
    }

    pub fn frame(&self, index: usize) -> &[f32] {
        &self.values[index * MEL_BINS..(index + 1) * MEL_BINS]
    }
}

/// Why no features were computed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LogMelError {
    /// Reflect padding needs more samples than half a frame; callers pad a clip to a second first.
    TooShort { samples: usize },
}

impl fmt::Display for LogMelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooShort { samples } => {
                write!(
                    f,
                    "{samples} samples are too few for log-mel features; at least {} are needed",
                    PADDING + 1
                )
            }
        }
    }
}

impl std::error::Error for LogMelError {}

/// Qwen3-ASR's log-mel features, computed as mlx-audio-swift's `computeMelSpectrogram` computes
/// them with the arguments `Qwen3ASRModel.preprocessAudio` passes: 16 kHz, 400-sample frames every
/// 160 samples, 128 mel bands on the Slaney scale, and a periodic Hann window. That matches
/// transformers' WhisperFeatureExtractor, except that every frame is kept (Whisper drops the last):
///
/// - the clip is reflect-padded by 200 samples at each end and framed every 160 samples, so a clip
///   of n samples has 1 + n / 160 frames;
/// - each frame is windowed and transformed, and its power spectrum weighted into the mel bands,
///   whose triangles are normalised to equal area (Slaney);
/// - each band's log10, floored at 1e-10, is clamped to 8 below the clip's loudest band, then
///   scaled as (x + 4) / 4.
///
/// The arithmetic is float32 throughout and follows the Swift step by step, down to how the window
/// and the filters are computed, so the features agree with the recorded ones to about 1e-6.
pub struct LogMelExtractor {
    window: [f32; N_FFT],
    filters: Vec<MelFilter>,
    fft: Arc<dyn RealToComplex<f32>>,
}

/// One mel band's triangle: its weights for the frequency bins from `first_bin`.
struct MelFilter {
    first_bin: usize,
    weights: Vec<f32>,
}

impl Default for LogMelExtractor {
    fn default() -> Self {
        Self::new()
    }
}

impl LogMelExtractor {
    pub fn new() -> Self {
        Self {
            window: hann_window(),
            filters: slaney_mel_filters(),
            fft: RealFftPlanner::<f32>::new().plan_fft_forward(N_FFT),
        }
    }

    /// The features of `samples`, 16 kHz mono.
    pub fn compute(&self, samples: &[f32]) -> Result<LogMel, LogMelError> {
        if samples.len() <= PADDING {
            return Err(LogMelError::TooShort { samples: samples.len() });
        }
        let padded = reflect_padded(samples);
        let frames = 1 + (padded.len() - N_FFT) / HOP_LENGTH;

        let mut values: Vec<f32> = Vec::with_capacity(frames * MEL_BINS);
        let mut frame = self.fft.make_input_vec();
        let mut spectrum = self.fft.make_output_vec();
        let mut scratch = self.fft.make_scratch_vec();
        let mut power = [0f32; FREQUENCY_BINS];
        for index in 0..frames {
            let start = index * HOP_LENGTH;
            for (sample, (value, weight)) in frame
                .iter_mut()
                .zip(padded[start..start + N_FFT].iter().zip(&self.window))
            {
                *sample = value * weight;
            }
            self.fft
                .process_with_scratch(&mut frame, &mut spectrum, &mut scratch)
                .expect("the buffers come from the plan, so their lengths match it");
            for (bin, value) in power.iter_mut().zip(&spectrum) {
                *bin = magnitude_squared(*value);
            }
            for filter in &self.filters {
                let bins = &power[filter.first_bin..filter.first_bin + filter.weights.len()];
                values.push(
                    bins.iter()
                        .zip(&filter.weights)
                        .map(|(power, weight)| power * weight)
                        .sum(),
                );
            }
        }

        // Log scaling with clamping, the Whisper normalisation, over the whole clip.
        let mut loudest = f32::NEG_INFINITY;
        for value in &mut values {
            *value = value.max(1e-10).log10();
            loudest = loudest.max(*value);
        }
        let floor = loudest - 8.0;
        for value in &mut values {
            *value = (value.max(floor) + 4.0) / 4.0;
        }
        Ok(LogMel { values })
    }
}

/// MLX takes the complex magnitude, then squares it.
fn magnitude_squared(value: Complex<f32>) -> f32 {
    let magnitude = value.norm();
    magnitude * magnitude
}

/// `samples` with 200 samples mirrored at each end, the edge sample itself not repeated: numpy's
/// and mlx-audio-swift's "reflect".
fn reflect_padded(samples: &[f32]) -> Vec<f32> {
    let count = samples.len();
    let mut padded = Vec::with_capacity(count + 2 * PADDING);
    padded.extend(samples[1..=PADDING].iter().rev());
    padded.extend_from_slice(samples);
    padded.extend(samples[count - PADDING - 1..count - 1].iter().rev());
    padded
}

/// The periodic Hann window (torch.hann_window's), computed as mlx-audio-swift's `hanningWindow`.
fn hann_window() -> [f32; N_FFT] {
    let denominator = N_FFT as f32;
    std::array::from_fn(|n| 0.5 * (1.0 - (2.0 * std::f32::consts::PI * n as f32 / denominator).cos()))
}

/// The mel filterbank as mlx-audio-swift's `melFilters` computes it with `.slaney` and the Slaney
/// normalisation: triangles spaced evenly on the Slaney mel scale from 0 Hz to 8 kHz, each scaled
/// to unit area. Only each triangle's non-zero weights are kept.
fn slaney_mel_filters() -> Vec<MelFilter> {
    const SAMPLE_RATE: f32 = 16_000.0;
    const F_MIN: f32 = 0.0;
    const F_SP: f32 = 200.0 / 3.0;
    const MIN_LOG_HZ: f32 = 1_000.0;
    let min_log_mel = (MIN_LOG_HZ - F_MIN) / F_SP;
    let log_step = 6.4f32.ln() / 27.0;
    let hz_to_mel = |frequency: f32| {
        if frequency < MIN_LOG_HZ {
            (frequency - F_MIN) / F_SP
        } else {
            min_log_mel + (frequency / MIN_LOG_HZ).ln() / log_step
        }
    };
    let mel_to_hz = |mel: f32| {
        if mel < min_log_mel {
            F_MIN + F_SP * mel
        } else {
            MIN_LOG_HZ * (log_step * (mel - min_log_mel)).exp()
        }
    };

    let bin_frequencies: Vec<f32> = (0..FREQUENCY_BINS)
        .map(|bin| bin as f32 * SAMPLE_RATE / N_FFT as f32)
        .collect();
    let mel_min = hz_to_mel(F_MIN);
    let mel_max = hz_to_mel(SAMPLE_RATE / 2.0);
    let edges: Vec<f32> = (0..MEL_BINS + 2)
        .map(|index| mel_to_hz(mel_min + index as f32 * (mel_max - mel_min) / (MEL_BINS + 1) as f32))
        .collect();

    (0..MEL_BINS)
        .map(|band| {
            let (low, center, high) = (edges[band], edges[band + 1], edges[band + 2]);
            let area = 2.0 / (high - low);
            let weights: Vec<(usize, f32)> = bin_frequencies
                .iter()
                .enumerate()
                .filter_map(|(bin, &frequency)| {
                    let weight = if frequency >= low && frequency < center {
                        (frequency - low) / (center - low)
                    } else if frequency >= center && frequency <= high {
                        (high - frequency) / (high - center)
                    } else {
                        0.0
                    };
                    (weight != 0.0).then_some((bin, weight * area))
                })
                .collect();
            // A triangle's bins are consecutive; a band too narrow to cover a bin has no weights.
            let first_bin = weights.first().map_or(0, |(bin, _)| *bin);
            debug_assert!(
                weights
                    .iter()
                    .enumerate()
                    .all(|(offset, (bin, _))| *bin == first_bin + offset)
            );
            MelFilter {
                first_bin,
                weights: weights.into_iter().map(|(_, weight)| weight).collect(),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_clip_has_one_frame_per_hop_plus_one() {
        let extractor = LogMelExtractor::new();
        assert_eq!(extractor.compute(&[0.0; 16_000]).unwrap().frames(), 101);
        assert_eq!(extractor.compute(&[0.0; 16_159]).unwrap().frames(), 101);
        assert_eq!(extractor.compute(&[0.0; 16_160]).unwrap().frames(), 102);
        assert_eq!(
            extractor.compute(&[0.0; 200]),
            Err(LogMelError::TooShort { samples: 200 })
        );
    }

    #[test]
    fn silence_sits_at_the_floor() {
        // log10(1e-10) = -10 everywhere, which is also the loudest band: (-10 + 4) / 4.
        let features = LogMelExtractor::new().compute(&[0.0; 16_000]).unwrap();
        assert!(features.values().iter().all(|&value| value == -1.5));
    }

    #[test]
    fn reflect_padding_mirrors_without_repeating_the_edge() {
        let samples: Vec<f32> = (0..300).map(|n| n as f32).collect();
        let padded = reflect_padded(&samples);
        assert_eq!(padded.len(), 700);
        assert_eq!(padded[..3], [200.0, 199.0, 198.0]);
        assert_eq!(padded[199..202], [1.0, 0.0, 1.0]);
        assert_eq!(padded[497..502], [297.0, 298.0, 299.0, 298.0, 297.0]);
        assert_eq!(padded[699], 99.0);
    }

    #[test]
    fn the_window_is_periodic() {
        let window = hann_window();
        assert_eq!(window[0], 0.0);
        assert!((window[N_FFT / 2] - 1.0).abs() < 1e-7);
        // Periodic: symmetric about the middle, with no second zero at the end.
        assert!((window[1] - window[N_FFT - 1]).abs() < 1e-6);
        assert!(window[N_FFT - 1] > 0.0);
    }

    #[test]
    fn every_band_has_weights_and_the_bands_rise() {
        let filters = slaney_mel_filters();
        assert_eq!(filters.len(), MEL_BINS);
        assert!(filters.iter().all(|filter| !filter.weights.is_empty()));
        assert!(filters.windows(2).all(|pair| pair[0].first_bin <= pair[1].first_bin));
    }
}
