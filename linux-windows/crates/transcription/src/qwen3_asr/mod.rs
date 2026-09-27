//! Qwen3-ASR as the Mac app runs it through mlx-audio-swift (Qwen3ASR.swift, at the revision the
//! Mac app pins), with the model's forward passes behind [`SpeechModel`].
//!
//! [`Transcriber::transcribe`] follows `MLXTranscriber.transcribe` and the model's `generate`:
//! clips under 100 ms give no text; the token limit follows the clip's length
//! ([`crate::output_limit`]); a clip under a second is padded with silence to one; its log-mel
//! features are encoded in chunks and windows ([`EncoderLayout`]); the audio rows replace the
//! prompt's first placeholders; the reply is decoded greedily ([`generation`]) and read as a
//! language and a transcript ([`Languages::read`]).

mod encoder_layout;
pub mod generation;
mod log_mel;
mod openvino_model;
mod prompt;
mod tokenizer;
mod transcript;

use std::fmt;

use lt_shared::audio_format::{SAMPLE_RATE, samples_for_milliseconds};

pub use encoder_layout::{CHUNK_FRAMES, CHUNKS_PER_WINDOW, EncoderLayout, placeholders};
pub use generation::{Decoded, Stop};
pub use log_mel::{HOP_LENGTH, LogMel, LogMelError, LogMelExtractor, MEL_BINS, N_FFT};
pub use openvino_model::{OpenError, OpenVinoError, OpenVinoModel, open_transcriber};
pub use prompt::PromptFormat;
pub use tokenizer::{Tokenizer, TokenizerError};
pub use transcript::{Languages, Reply};

/// Qwen3-ASR's own limit on a reply's tokens, before [`crate::output_limit`] lowers it.
pub const MODEL_MAX_TOKENS: usize = 8_192;

/// The longest clip transcribed in one piece. mlx-audio-swift splits a longer one at quiet points;
/// dictation records a few minutes at most, so a longer clip is refused instead.
pub const MAX_CLIP_SAMPLES: usize = 1_200 * SAMPLE_RATE;

/// The model's forward passes, which a runtime implements. Everything around them (features,
/// chunking, which rows are kept, the prompt, decoding) is this module's, so that every runtime
/// computes what the Mac app computes.
pub trait SpeechModel {
    type Error: std::error::Error + Send + Sync + 'static;

    /// The audio encoder's convolutions (with its positional embedding) over every chunk of a
    /// clip: `chunks.count()` chunks of [`MEL_BINS`] × `chunks.length()` frames. Returns, chunk
    /// after chunk, the rows the convolutions make of each (`layout.convolved_length()` rows).
    fn convolve(&mut self, chunks: &ChunkFrames) -> Result<Rows, Self::Error>;

    /// The audio encoder's attention layers and output projection over one window of rows, which
    /// attend to each other only. Returns one row, as wide as the text model's embeddings, per row.
    fn attend(&mut self, window: &Rows) -> Result<Rows, Self::Error>;

    /// Starts a reply: runs the prompt `ids` with `audio`'s rows in place of the embeddings from
    /// position `audio_start`, and returns the logits of the token that follows the prompt.
    fn prefill(&mut self, ids: &[u32], audio_start: usize, audio: &Rows) -> Result<Vec<f32>, Self::Error>;

    /// Continues the reply with `token`, and returns the logits of the token that follows it.
    fn step(&mut self, token: u32) -> Result<Vec<f32>, Self::Error>;
}

/// Rows of equal width, row after row.
#[derive(Clone, Debug, PartialEq)]
pub struct Rows {
    values: Vec<f32>,
    width: usize,
}

impl Rows {
    /// Panics unless `values` holds whole rows of `width`.
    pub fn new(values: Vec<f32>, width: usize) -> Self {
        assert!(
            width > 0 && values.len().is_multiple_of(width),
            "rows of {width} can't hold {} values",
            values.len()
        );
        Self { values, width }
    }

    pub fn width(&self) -> usize {
        self.width
    }

    pub fn count(&self) -> usize {
        self.values.len() / self.width
    }

    /// Every value, row after row.
    pub fn values(&self) -> &[f32] {
        &self.values
    }

    pub fn row(&self, index: usize) -> &[f32] {
        &self.values[index * self.width..(index + 1) * self.width]
    }

    fn range(&self, rows: std::ops::Range<usize>) -> Rows {
        Rows::new(
            self.values[rows.start * self.width..rows.end * self.width].to_vec(),
            self.width,
        )
    }
}

/// A clip's mel frames cut into chunks for the encoder's convolutions: `count` chunks, each
/// [`MEL_BINS`] rows (one per mel band) of `length` frames, zero-padded past the chunk's own
/// frames. That is the layout the model reads, [chunks, 128, length].
#[derive(Clone, Debug, PartialEq)]
pub struct ChunkFrames {
    values: Vec<f32>,
    count: usize,
    length: usize,
}

impl ChunkFrames {
    pub fn new(features: &LogMel, layout: &EncoderLayout) -> Self {
        let count = layout.chunk_lengths().len();
        let length = layout.padded_length();
        let mut values = vec![0.0; count * MEL_BINS * length];
        let mut first_frame = 0;
        for (chunk, &frames) in layout.chunk_lengths().iter().enumerate() {
            for offset in 0..frames {
                for (band, &value) in features.frame(first_frame + offset).iter().enumerate() {
                    values[(chunk * MEL_BINS + band) * length + offset] = value;
                }
            }
            first_frame += frames;
        }
        Self { values, count, length }
    }

    pub fn count(&self) -> usize {
        self.count
    }

    pub fn length(&self) -> usize {
        self.length
    }

    /// Every value, [chunks, 128, length] in row-major order.
    pub fn values(&self) -> &[f32] {
        &self.values
    }
}

/// A clip's transcript, and what it took.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Transcription {
    pub text: String,
    /// The language the model named, as its supported languages spell it.
    pub language: Option<String>,
    /// Tokens in the reply, and why it ended.
    pub tokens: usize,
    pub stop: Option<Stop>,
}

impl Transcription {
    fn empty() -> Self {
        Self {
            text: String::new(),
            language: None,
            tokens: 0,
            stop: None,
        }
    }
}

/// Why a clip wasn't transcribed.
#[derive(Debug)]
pub enum TranscribeError<E> {
    /// The runtime failed.
    Model(E),
    /// The runtime returned the wrong number of rows.
    Shape {
        stage: &'static str,
        expected: usize,
        got: usize,
    },
    /// The clip is longer than [`MAX_CLIP_SAMPLES`].
    TooLong { samples: usize },
}

impl<E: fmt::Display> fmt::Display for TranscribeError<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Model(error) => write!(f, "the speech model failed: {error}"),
            Self::Shape { stage, expected, got } => {
                write!(
                    f,
                    "the speech model's {stage} returned {got} rows where {expected} were expected"
                )
            }
            Self::TooLong { samples } => write!(
                f,
                "a clip of {} s is longer than the {} s that can be transcribed at once",
                samples / SAMPLE_RATE,
                MAX_CLIP_SAMPLES / SAMPLE_RATE
            ),
        }
    }
}

impl<E: std::error::Error + 'static> std::error::Error for TranscribeError<E> {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Model(error) => Some(error),
            _ => None,
        }
    }
}

/// Transcribes clips with one model. Build it once: the tokenizer, the prompt and the features'
/// window, filters and transform plan are prepared here.
pub struct Transcriber<M> {
    model: M,
    tokenizer: Tokenizer,
    prompt: PromptFormat,
    languages: Languages,
    log_mel: LogMelExtractor,
}

/// Clips shorter than 100 ms hold no word, so they give no text without running the model.
const MINIMUM_SAMPLES: usize = samples_for_milliseconds(100);

impl<M: SpeechModel> Transcriber<M> {
    pub fn new(model: M, tokenizer: Tokenizer, languages: Languages) -> Result<Self, TokenizerError> {
        Ok(Self {
            model,
            prompt: PromptFormat::new(&tokenizer)?,
            tokenizer,
            languages,
            log_mel: LogMelExtractor::new(),
        })
    }

    /// The transcript of `samples`, 16 kHz mono.
    pub fn transcribe(&mut self, samples: &[f32]) -> Result<Transcription, TranscribeError<M::Error>> {
        if samples.len() < MINIMUM_SAMPLES {
            return Ok(Transcription::empty());
        }
        if samples.len() > MAX_CLIP_SAMPLES {
            return Err(TranscribeError::TooLong { samples: samples.len() });
        }
        let max_tokens = crate::output_limit::capping(MODEL_MAX_TOKENS, samples.len());

        let mut padded = samples.to_vec();
        padded.resize(samples.len().max(SAMPLE_RATE), 0.0);
        let features = self
            .log_mel
            .compute(&padded)
            .expect("a clip padded to a second has enough samples for its features");
        let layout = EncoderLayout::new(features.frames());
        let mut audio = encode(&mut self.model, &features, &layout)?;

        // The rows replace the placeholders from the first; any placeholders past the rows keep
        // the placeholder token's embedding, and rows past the placeholders are dropped.
        let placeholders = layout.placeholders();
        if audio.count() > placeholders {
            audio = audio.range(0..placeholders);
        }
        let ids = self.prompt.ids(placeholders);
        let first = self
            .model
            .prefill(&ids, self.prompt.audio_start(), &audio)
            .map_err(TranscribeError::Model)?;
        let model = &mut self.model;
        let decoded = generation::decode_greedily(&first, max_tokens, |token| model.step(token))
            .map_err(TranscribeError::Model)?;
        if max_tokens > 0 && decoded.tokens.len() >= max_tokens {
            tracing::warn!(
                "Speech to text stopped at its limit of {max_tokens} tokens for {} ms of audio; the model was probably repeating itself",
                samples.len() * 1_000 / SAMPLE_RATE
            );
        }

        let reply = self.languages.read(&self.tokenizer.decode(&decoded.tokens));
        tracing::debug!(
            "Transcribed {} ms of audio: {} placeholders, {} audio rows, {} tokens ({:?})",
            samples.len() * 1_000 / SAMPLE_RATE,
            placeholders,
            audio.count(),
            decoded.tokens.len(),
            decoded.stop
        );
        Ok(Transcription {
            text: reply.text,
            language: reply.language,
            tokens: decoded.tokens.len(),
            stop: Some(decoded.stop),
        })
    }
}

/// The audio encoder over a clip, as mlx-audio-swift runs it: the convolutions over every chunk,
/// the rows [`EncoderLayout`] keeps of each, and attention within each window of kept rows.
fn encode<M: SpeechModel>(
    model: &mut M,
    features: &LogMel,
    layout: &EncoderLayout,
) -> Result<Rows, TranscribeError<M::Error>> {
    let convolved = model
        .convolve(&ChunkFrames::new(features, layout))
        .map_err(TranscribeError::Model)?;
    let expected = layout.chunk_lengths().len() * layout.convolved_length();
    if convolved.count() != expected {
        return Err(TranscribeError::Shape {
            stage: "convolutions",
            expected,
            got: convolved.count(),
        });
    }

    let mut kept = Vec::with_capacity(layout.rows() * convolved.width());
    for (chunk, &rows) in layout.chunk_rows().iter().enumerate() {
        let first = chunk * layout.convolved_length();
        kept.extend_from_slice(&convolved.values()[first * convolved.width()..(first + rows) * convolved.width()]);
    }
    let kept = Rows::new(kept, convolved.width());

    let mut encoded: Option<Rows> = None;
    for window in layout.windows() {
        let attended = model
            .attend(&kept.range(window.clone()))
            .map_err(TranscribeError::Model)?;
        if attended.count() != window.len() {
            return Err(TranscribeError::Shape {
                stage: "attention",
                expected: window.len(),
                got: attended.count(),
            });
        }
        match &mut encoded {
            Some(rows) => rows.values.extend_from_slice(attended.values()),
            None => encoded = Some(attended),
        }
    }
    Ok(encoded.expect("a clip has at least one window"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A model whose rows record where they came from, and whose reply is scripted.
    struct FakeModel {
        reply: Vec<u32>,
        replied: usize,
        convolved_chunks: Vec<(usize, usize)>,
        windows: Vec<usize>,
        prefilled: Option<(Vec<u32>, usize, Vec<f32>)>,
    }

    #[derive(Debug)]
    struct NoError;

    impl fmt::Display for NoError {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str("no error")
        }
    }

    impl std::error::Error for NoError {}

    impl FakeModel {
        fn replying(reply: &[u32]) -> Self {
            Self {
                reply: reply.to_vec(),
                replied: 0,
                convolved_chunks: Vec::new(),
                windows: Vec::new(),
                prefilled: None,
            }
        }

        fn next_logits(&mut self) -> Vec<f32> {
            let mut logits = vec![0.0; 151_936];
            logits[self.reply[self.replied] as usize] = 1.0;
            self.replied += 1;
            logits
        }
    }

    impl SpeechModel for FakeModel {
        type Error = NoError;

        /// Row r of chunk c is the single value c × 100 + r.
        fn convolve(&mut self, chunks: &ChunkFrames) -> Result<Rows, NoError> {
            self.convolved_chunks.push((chunks.count(), chunks.length()));
            let rows = EncoderLayout::new(chunks.length()).convolved_length();
            let values = (0..chunks.count())
                .flat_map(|chunk| (0..rows).map(move |row| (chunk * 100 + row) as f32))
                .collect();
            Ok(Rows::new(values, 1))
        }

        fn attend(&mut self, window: &Rows) -> Result<Rows, NoError> {
            self.windows.push(window.count());
            Ok(window.clone())
        }

        fn prefill(&mut self, ids: &[u32], audio_start: usize, audio: &Rows) -> Result<Vec<f32>, NoError> {
            self.prefilled = Some((ids.to_vec(), audio_start, audio.values().to_vec()));
            Ok(self.next_logits())
        }

        fn step(&mut self, _token: u32) -> Result<Vec<f32>, NoError> {
            Ok(self.next_logits())
        }
    }

    fn transcriber_replying(reply: &[u32]) -> Transcriber<FakeModel> {
        let vocab = r#"{"system": 8948, "user": 872, "assistant": 77091, "Ċ": 198, "language": 11528,
            "ĠEnglish": 6364, "Ship": 29170, "Ġit": 432, ".": 13}"#;
        let config = r#"{"added_tokens_decoder": {
            "151643": {"content": "<|endoftext|>"}, "151644": {"content": "<|im_start|>"},
            "151645": {"content": "<|im_end|>"}, "151669": {"content": "<|audio_start|>"},
            "151670": {"content": "<|audio_end|>"}, "151676": {"content": "<|audio_pad|>"},
            "151704": {"content": "<asr_text>"}
        }}"#;
        Transcriber::new(
            FakeModel::replying(reply),
            Tokenizer::from_json(vocab, config).unwrap(),
            Languages::new(["English".to_owned()]),
        )
        .unwrap()
    }

    #[test]
    fn transcribes_a_clip() {
        let mut transcriber = transcriber_replying(&[11528, 6364, 151_704, 29170, 432, 13, 151_645]);
        let transcription = transcriber.transcribe(&[0.01; 94_560]).unwrap();
        assert_eq!(transcription.text, "Ship it.");
        assert_eq!(transcription.language.as_deref(), Some("English"));
        assert_eq!(transcription.tokens, 6);
        assert_eq!(transcription.stop, Some(Stop::EndOfReply));

        // 94,560 samples are 592 frames: six chunks padded to 100 frames, one window.
        let model = &transcriber.model;
        assert_eq!(model.convolved_chunks, [(6, 100)]);
        assert_eq!(model.windows, [78]);
        let (ids, audio_start, audio) = model.prefilled.clone().unwrap();
        assert_eq!(audio_start, 9);
        // 88 placeholders, of which the 78 audio rows fill the first.
        assert_eq!(ids.len(), 9 + 88 + 6);
        assert_eq!(audio.len(), 78);
        // Every chunk's first 13 rows, the last chunk's taken over its padding too.
        assert_eq!(audio[..3], [0.0, 1.0, 2.0]);
        assert_eq!(audio[13], 100.0);
        assert_eq!(audio[77], 512.0);
    }

    #[test]
    fn pads_a_short_clip_to_a_second_and_gives_nothing_for_a_click() {
        let mut transcriber = transcriber_replying(&[151_645]);
        let transcription = transcriber.transcribe(&[0.01; 3_200]).unwrap();
        assert_eq!(transcription.text, "");
        assert_eq!(transcriber.model.convolved_chunks, [(2, 100)]);

        let mut transcriber = transcriber_replying(&[151_645]);
        assert_eq!(transcriber.transcribe(&[0.01; 1_599]).unwrap(), Transcription::empty());
        assert!(transcriber.model.convolved_chunks.is_empty());
    }

    #[test]
    fn limits_the_reply_by_the_clip_length() {
        // A second of audio allows 94 tokens.
        let mut transcriber = transcriber_replying(&vec![432; 200]);
        let transcription = transcriber.transcribe(&[0.01; 16_000]).unwrap();
        assert_eq!(transcription.stop, Some(Stop::Loop));
        let looping: Vec<u32> = (0..200).map(|n| [432, 13, 29170, 6364][n % 4]).collect();
        let mut transcriber = transcriber_replying(&looping);
        let transcription = transcriber.transcribe(&[0.01; 16_000]).unwrap();
        assert_eq!(transcription.tokens, 94);
        assert_eq!(transcription.stop, Some(Stop::Limit));
    }

    #[test]
    fn refuses_a_clip_over_twenty_minutes() {
        let mut transcriber = transcriber_replying(&[151_645]);
        let error = transcriber.transcribe(&vec![0.0; MAX_CLIP_SAMPLES + 1]).unwrap_err();
        assert!(matches!(error, TranscribeError::TooLong { .. }));
    }
}
