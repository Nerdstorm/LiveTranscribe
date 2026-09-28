//! The speech front end against the Mac app's, as `GoldenSpeechFeatureTests`
//! (Packages/LiveTranscribeKit/Tests/TranscriptionTests) records it in Fixtures/golden: the log-mel
//! features of three test clips, and for every clip length from one second to ten the prompt's
//! placeholders and the encoder's rows.

use std::path::PathBuf;

use lt_transcription::qwen3_asr::{EncoderLayout, LogMelExtractor, MEL_BINS};

/// How far a feature may be from the recorded one; the Swift test holds itself to the same.
const TOLERANCE: f32 = 1e-4;

fn golden() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../Fixtures/golden")
}

/// A test signal made with integer arithmetic only, so the Swift and Rust tests make the same
/// samples bit for bit: a sawtooth sweeping from about 60 Hz to 7.6 kHz every two seconds, with
/// noise, and 0.25 s of silence every 1.5 s. The same generator as the Swift test's.
struct SyntheticClip {
    name: &'static str,
    seed: u32,
    samples: usize,
}

const CLIPS: [SyntheticClip; 3] = [
    SyntheticClip {
        name: "one-second",
        seed: 1,
        samples: 16_000,
    },
    SyntheticClip {
        name: "short",
        seed: 2,
        samples: 9_920,
    },
    SyntheticClip {
        name: "longer",
        seed: 3,
        samples: 37_920,
    },
];

impl SyntheticClip {
    /// The samples, padded with silence to one second as the model's generate pads a shorter clip.
    fn padded_samples(&self) -> Vec<f32> {
        let mut noise = self.seed;
        let mut phase = 0u32;
        let mut values: Vec<f32> = (0..self.samples)
            .map(|n| {
                noise = noise.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                phase = phase.wrapping_add((16_000_000 + (n % 32_000) * 63_000) as u32);
                let saw = i32::from((phase >> 16) as u16 as i16);
                let hiss = i32::from((noise >> 16) as u16 as i16);
                let silent = n % 24_000 >= 20_000;
                if silent {
                    0.0
                } else {
                    (saw / 4 + hiss / 16) as f32 / 32_768.0
                }
            })
            .collect();
        values.resize(self.samples.max(16_000), 0.0);
        values
    }
}

#[test]
fn the_log_mel_features_match_the_mac_apps() {
    let extractor = LogMelExtractor::new();
    for clip in &CLIPS {
        let file = golden().join(format!("speech-features/{}.f32", clip.name));
        let bytes = std::fs::read(&file).unwrap_or_else(|error| panic!("reading {}: {error}", file.display()));
        let recorded: Vec<f32> = bytes
            .as_chunks::<4>()
            .0
            .iter()
            .map(|value| f32::from_le_bytes(*value))
            .collect();

        let computed = extractor.compute(&clip.padded_samples()).unwrap();
        assert_eq!(computed.frames(), 1 + clip.samples.max(16_000) / 160, "{}", clip.name);
        assert_eq!(
            computed.values().len(),
            recorded.len(),
            "{}: frames of {MEL_BINS}",
            clip.name
        );

        let (worst, at) = computed
            .values()
            .iter()
            .zip(&recorded)
            .enumerate()
            .map(|(index, (computed, recorded))| ((computed - recorded).abs(), index))
            .fold((0.0f32, 0), |best, next| if next.0 > best.0 { next } else { best });
        println!(
            "{}: {} frames, largest difference {worst:e}",
            clip.name,
            computed.frames()
        );
        assert!(
            worst <= TOLERANCE,
            "{}: frame {} band {} is {} where the Mac app has {}",
            clip.name,
            at / MEL_BINS,
            at % MEL_BINS,
            computed.values()[at],
            recorded[at]
        );
    }
}

#[test]
fn the_placeholder_and_row_counts_match_the_mac_apps() {
    let table = std::fs::read_to_string(golden().join("speech-layout.tsv")).unwrap();
    let mut lengths = 0;
    for line in table.lines().filter(|line| !line.starts_with('#')) {
        let columns: Vec<usize> = line.split('\t').map(|column| column.parse().unwrap()).collect();
        let [frames, placeholders, rows] = columns[..] else {
            panic!("speech-layout.tsv: {line:?} doesn't have three columns");
        };
        let layout = EncoderLayout::new(frames);
        assert_eq!(
            (layout.placeholders(), layout.rows()),
            (placeholders, rows),
            "{frames} frames: placeholders and encoder rows"
        );
        lengths += 1;
    }
    assert_eq!(lengths, 900, "every clip length from 101 to 1,000 frames");
}
