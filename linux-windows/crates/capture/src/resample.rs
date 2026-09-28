//! Converting a recording to the models' 16 kHz: rubato's FFT resampler over the whole clip,
//! with its delay trimmed so the output lines up with the input.

use lt_shared::audio_format::SAMPLE_RATE;
use rubato::audioadapter_buffers::direct::InterleavedSlice;
use rubato::{Fft, FixedSync, Resampler};

/// Frames per resampler chunk: small enough that its delay is a few milliseconds.
const CHUNK_FRAMES: usize = 1_024;

#[derive(Debug)]
pub struct ResampleError(String);

impl std::fmt::Display for ResampleError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ResampleError {}

/// Mono samples at `sample_rate` as mono samples at 16 kHz.
pub fn to_model_rate(samples: &[f32], sample_rate: u32) -> Result<Vec<f32>, ResampleError> {
    let rate = sample_rate as usize;
    if rate == SAMPLE_RATE || samples.is_empty() {
        return Ok(samples.to_vec());
    }
    let failed = |error: &dyn std::fmt::Display| ResampleError(format!("{sample_rate} Hz to 16 kHz: {error}"));
    let mut resampler =
        Fft::<f32>::new(rate, SAMPLE_RATE, CHUNK_FRAMES, 1, FixedSync::Input).map_err(|error| failed(&error))?;
    let input = InterleavedSlice::new(samples, 1, samples.len()).map_err(|error| failed(&error))?;
    let output = resampler
        .process_all(&input, samples.len(), None)
        .map_err(|error| failed(&error))?;
    Ok(output.take_data())
}

#[cfg(test)]
mod tests {
    use std::f32::consts::TAU;

    use super::*;

    fn tone(frequency: f32, sample_rate: usize, seconds: f32) -> Vec<f32> {
        let count = (sample_rate as f32 * seconds) as usize;
        (0..count)
            .map(|index| 0.5 * (TAU * frequency * index as f32 / sample_rate as f32).sin())
            .collect()
    }

    #[test]
    fn keeps_16_khz_as_it_is() {
        let samples = tone(440.0, SAMPLE_RATE, 0.1);
        assert_eq!(to_model_rate(&samples, 16_000).unwrap(), samples);
        assert!(to_model_rate(&[], 48_000).unwrap().is_empty());
    }

    #[test]
    fn converts_common_rates_keeping_the_signal_in_place() {
        for rate in [44_100, 48_000] {
            let samples = to_model_rate(&tone(440.0, rate, 1.0), rate as u32).unwrap();
            assert_eq!(samples.len(), SAMPLE_RATE, "{rate} Hz");
            // Away from the edges the tone is the same tone, in phase: the delay is trimmed, to
            // within a fraction of a sample where the rates don't divide (44.1 kHz).
            let expected = tone(440.0, SAMPLE_RATE, 1.0);
            let worst = samples[1_000..15_000]
                .iter()
                .zip(&expected[1_000..15_000])
                .map(|(actual, expected)| (actual - expected).abs())
                .fold(0.0_f32, f32::max);
            assert!(worst < 0.03, "{rate} Hz: off by {worst}");
        }
    }

    #[test]
    fn removes_what_16_khz_cant_hold() {
        // 12 kHz is above 16 kHz's 8 kHz limit: it must not fold back as a lower tone.
        let samples = to_model_rate(&tone(12_000.0, 48_000, 1.0), 48_000).unwrap();
        let loudest = samples[1_000..15_000]
            .iter()
            .fold(0.0_f32, |max, sample| max.max(sample.abs()));
        assert!(loudest < 0.01, "aliased to {loudest}");
    }
}
