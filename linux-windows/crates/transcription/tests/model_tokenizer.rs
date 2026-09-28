//! The tokenizer and prompt against a real Qwen3-ASR model folder, which CI doesn't have. Run with
//! the folder holding the model's vocab.json, tokenizer_config.json and config.json:
//!
//! ```text
//! LT_QWEN3_ASR_DIR=/path/to/Qwen3-ASR-0.6B cargo test -p lt-transcription -- --ignored
//! ```

use std::path::PathBuf;

use lt_transcription::qwen3_asr::{Languages, PromptFormat, Tokenizer};

fn model_folder() -> PathBuf {
    PathBuf::from(std::env::var("LT_QWEN3_ASR_DIR").expect("LT_QWEN3_ASR_DIR names a Qwen3-ASR model folder"))
}

#[test]
#[ignore = "needs a Qwen3-ASR model folder in LT_QWEN3_ASR_DIR"]
fn the_prompt_is_qwens_chat_template() {
    let tokenizer = Tokenizer::load(&model_folder()).unwrap();
    let ids = PromptFormat::new(&tokenizer).unwrap().ids(1);
    // <|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|><|audio_pad|>
    // <|audio_end|><|im_end|>\n<|im_start|>assistant\n
    assert_eq!(
        ids,
        [
            151_644, 8_948, 198, 151_645, 198, 151_644, 872, 198, 151_669, 151_676, 151_670, 151_645, 198, 151_644,
            77_091, 198
        ]
    );
}

#[test]
#[ignore = "needs a Qwen3-ASR model folder in LT_QWEN3_ASR_DIR"]
fn a_reply_decodes_to_its_language_and_transcript() {
    let folder = model_folder();
    let tokenizer = Tokenizer::load(&folder).unwrap();
    let languages = Languages::from_config(&std::fs::read_to_string(folder.join("config.json")).unwrap()).unwrap();
    // "language English" is the words' tokens; 151704 is <asr_text>.
    let text = tokenizer.decode(&[11_528, 6_364, 151_704]);
    assert_eq!(text, "language English<asr_text>");
    assert_eq!(languages.read(&text).language.as_deref(), Some("English"));
}
