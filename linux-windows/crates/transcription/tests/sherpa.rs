//! The catalog's sherpa-onnx models, opened as the app opens them: checked against the catalog,
//! then loaded. Transcribing needs a model, which only the linux-windows workflow downloads:
//! Parakeet TDT 0.6B v2 (English, 480 MB to download), whose own test clip it transcribes. Run
//! with the folder its archive unpacks to:
//!
//! ```text
//! LT_SHERPA_PARAKEET_DIR=/path/to/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8 \
//!     cargo test -p lt-transcription --test sherpa -- --ignored
//! ```

use std::path::PathBuf;

use lt_transcription::catalog::{SpeechModel, SpeechModelCatalog, VerifyError};
use lt_transcription::qwen3_asr::DeviceChoice;
use lt_transcription::speech_to_text::SpeechToText;

fn parakeet() -> &'static SpeechModel {
    SpeechModelCatalog::bundled()
        .model("parakeet-tdt-0.6b-v2")
        .expect("the catalog has Parakeet v2 on this platform")
}

#[test]
fn a_folder_without_the_models_files_is_refused_before_sherpa_onnx_reads_it() {
    let folder = std::env::temp_dir().join("lt-transcription-no-such-model");
    match parakeet().verify(&folder, &mut |_, _| {}) {
        Err(VerifyError::Missing { file }) => assert_eq!(file, "encoder.int8.onnx"),
        Err(error) => panic!("refused for another reason: {error}"),
        Ok(_) => panic!("verified a folder that isn't there"),
    }
}

#[test]
#[ignore = "needs Parakeet v2's folder in LT_SHERPA_PARAKEET_DIR"]
fn parakeet_transcribes_its_test_clip() {
    let folder = PathBuf::from(
        std::env::var("LT_SHERPA_PARAKEET_DIR").expect("LT_SHERPA_PARAKEET_DIR names Parakeet v2's folder"),
    );
    let verified = parakeet()
        .verify(&folder, &mut |_, _| {})
        .expect("the folder holds Parakeet v2 as published");
    let mut speech = SpeechToText::open(&verified, &DeviceChoice::Auto, None).unwrap();

    let clip = folder.join("test_wavs").join("0.wav");
    let wave = sherpa_onnx::Wave::read(clip.to_str().unwrap()).expect("the model's test clip reads");
    assert_eq!(wave.sample_rate(), 16_000, "the rate the app records at");
    let transcript = speech.transcribe(wave.samples(), Some("de")).unwrap();
    assert_eq!(transcript.text, EXPECTED);
    assert_eq!(transcript.language, None, "Parakeet finds the language: it's told none");
    assert!(speech.placement().starts_with("CPU"), "{}", speech.placement());
}

const EXPECTED: &str = "Well, I don't wish to see it any more, observed Phebe, turning away her eyes. It is certainly very like the old portrait.";
