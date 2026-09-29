//! The catalog's other models through sherpa-onnx. Transcribing needs a model, which only the
//! linux-windows workflow downloads: sherpa-onnx's Moonshine tiny (English, 30 MB), whose own test
//! clip it transcribes. Run with the model's folder:
//!
//! ```text
//! LT_SHERPA_MOONSHINE_DIR=/path/to/sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27 \
//!     cargo test -p lt-transcription --test sherpa -- --ignored
//! ```

use std::path::PathBuf;

use lt_transcription::sherpa::{Family, OpenError, SherpaTranscriber};

#[test]
fn a_folder_without_the_models_files_is_refused_before_sherpa_onnx_reads_it() {
    let folder = std::env::temp_dir().join("lt-transcription-no-such-model");
    match SherpaTranscriber::open(&folder, Family::MoonshineV2, 1) {
        Err(OpenError::Missing(path)) => assert_eq!(path, folder.join("encoder_model.ort")),
        Err(error) => panic!("refused for another reason: {error}"),
        Ok(_) => panic!("opened a folder that isn't there"),
    }
}

#[test]
#[ignore = "needs Moonshine tiny's folder in LT_SHERPA_MOONSHINE_DIR"]
fn moonshine_transcribes_its_test_clip() {
    let folder = PathBuf::from(
        std::env::var("LT_SHERPA_MOONSHINE_DIR").expect("LT_SHERPA_MOONSHINE_DIR names Moonshine tiny's folder"),
    );
    let clip = folder.join("test_wavs").join("0.wav");
    let wave = sherpa_onnx::Wave::read(clip.to_str().unwrap()).expect("the model's test clip reads");
    // The clip is 24 kHz; the app records at 16 kHz.
    let samples = sherpa_onnx::LinearResampler::create(wave.sample_rate(), 16_000)
        .unwrap()
        .resample(wave.samples(), true);

    let transcriber = SherpaTranscriber::open(&folder, Family::MoonshineV2, 2).unwrap();
    let text = transcriber.transcribe(&samples).unwrap();
    assert_eq!(text, EXPECTED);
}

const EXPECTED: &str = "Ask not what your country can do for you. Ask what you can do for your country.";
