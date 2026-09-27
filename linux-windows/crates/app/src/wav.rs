//! Reading WAV files as the model's input: 16 kHz, one channel, samples in [-1, 1].

use std::path::Path;

use anyhow::{Context, bail};
use hound::{SampleFormat, WavReader};
use lt_shared::audio_format::SAMPLE_RATE;

/// The file's samples, its channels averaged into one. Only 16 kHz files are read: resampling
/// is left to tools made for it (`ffmpeg -i in.wav -ar 16000 out.wav`).
pub fn read_mono(path: &Path) -> anyhow::Result<Vec<f32>> {
    let reader = WavReader::open(path).with_context(|| format!("couldn't open {}", path.display()))?;
    let spec = reader.spec();
    if usize::try_from(spec.sample_rate).ok() != Some(SAMPLE_RATE) {
        bail!(
            "{} is {} Hz; the model reads 16 kHz (ffmpeg -i in.wav -ar 16000 out.wav converts it)",
            path.display(),
            spec.sample_rate
        );
    }
    let interleaved: Vec<f32> = match (spec.sample_format, spec.bits_per_sample) {
        (SampleFormat::Float, 32) => reader.into_samples::<f32>().collect::<Result<_, _>>(),
        (SampleFormat::Int, bits @ 8..=32) => {
            let scale = 1.0 / f64::from(1_u32 << (bits - 1));
            reader
                .into_samples::<i32>()
                .map(|sample| sample.map(|value| (f64::from(value) * scale) as f32))
                .collect::<Result<_, _>>()
        }
        (format, bits) => bail!(
            "{} holds {bits}-bit {format:?} samples, which aren't read",
            path.display()
        ),
    }
    .with_context(|| format!("couldn't read {}", path.display()))?;
    Ok(mix_to_mono(&interleaved, usize::from(spec.channels)))
}

fn mix_to_mono(interleaved: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    interleaved
        .chunks_exact(channels)
        .map(|frame| frame.iter().sum::<f32>() / channels as f32)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn averages_the_channels() {
        assert_eq!(mix_to_mono(&[0.5, -0.5, 1.0, 0.0], 2), [0.0, 0.5]);
        assert_eq!(mix_to_mono(&[0.25, 0.5], 1), [0.25, 0.5]);
    }
}
