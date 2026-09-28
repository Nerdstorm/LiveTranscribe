//! Speech to text, computed as the Mac app computes it.
//!
//! The Mac app runs Qwen3-ASR through mlx-audio-swift. This crate does the same work around the
//! model: the log-mel features, the prompt and where the audio goes in it, greedy decoding with
//! its stops, and reading the transcript out of the model's reply. The model's forward passes are
//! behind [`qwen3_asr::SpeechModel`], so a runtime (OpenVINO, first) only has to run tensors.
//!
//! - [`output_limit`] mirrors Packages/LiveTranscribeKit/Sources/Transcription/OutputLimit.swift.
//! - [`qwen3_asr`] mirrors mlx-audio-swift's Qwen3ASR.swift at the revision the Mac app pins. The
//!   golden files in `Fixtures/golden` (`speech-features/`, `speech-layout.tsv`) pin its front end,
//!   which the Sinhala model was trained on and so must not drift.
//!
//! Transcripts are never logged: log lines carry counts only.

pub mod output_limit;
pub mod qwen3_asr;
