//! A chat model: a Qwen3 model folder's tokenizer, chat template and OpenVINO model together,
//! generating one reply to a chat at a time.

use std::fmt;
use std::path::{Path, PathBuf};
use std::time::Instant;

use serde::Deserialize;

use crate::adapter::{Adapter, AdapterError};
use crate::chat::{self, ChatError, Message};
use crate::openvino_model::{ModelError, OpenVinoModel, Options};
use crate::sampling::{Sampler, Sampling};
use crate::tokenizer::{Tokenizer, TokenizerError};

/// What to generate.
#[derive(Clone, Debug, PartialEq)]
pub struct Request {
    pub messages: Vec<Message>,
    /// Qwen3's `enable_thinking`: off, the reply starts after an empty think block; on, the model
    /// writes its reasoning in `<think>…</think>` first, which the reply keeps.
    pub thinking: bool,
    /// The most tokens the reply may have, its reasoning included.
    pub max_tokens: usize,
    pub sampling: Sampling,
    /// The adapter this reply runs with, by the name it was loaded as
    /// ([`LanguageModel::load_adapter`]), or none: the base model.
    pub adapter: Option<String>,
}

/// Why a reply ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stop {
    /// The model ended its reply (`<|im_end|>` or `<|endoftext|>`).
    EndOfReply,
    /// The reply reached `max_tokens`.
    MaxTokens,
    /// The caller asked for it to stop.
    Cancelled,
}

impl Stop {
    /// As the bench's output spells it.
    pub fn name(self) -> &'static str {
        match self {
            Self::EndOfReply => "eos",
            Self::MaxTokens => "max_tokens",
            Self::Cancelled => "cancelled",
        }
    }
}

/// A reply, and what it took.
#[derive(Clone, Debug, PartialEq)]
pub struct Reply {
    /// The reply's text, as generated: without the token that ended it, with any `<think>` block.
    pub text: String,
    pub prompt_tokens: usize,
    pub reply_tokens: usize,
    /// Running the prompt, up to the first token's logits.
    pub prefill_ms: f64,
    /// Every step after that: one a token, and one more for the token that ended the reply.
    pub decode_ms: f64,
    pub stop: Stop,
}

impl Reply {
    /// How many steps the decoding ran, each a pass of one token.
    pub fn decode_steps(&self) -> usize {
        match self.stop {
            Stop::EndOfReply => self.reply_tokens,
            Stop::MaxTokens | Stop::Cancelled => self.reply_tokens.saturating_sub(1),
        }
    }
}

/// Why a model folder couldn't be opened.
#[derive(Debug)]
pub enum OpenError {
    Model(ModelError),
    Tokenizer(TokenizerError),
    /// The folder's chat template isn't Qwen3's, which is the only one this build renders.
    ChatTemplate {
        path: PathBuf,
    },
    Read {
        path: PathBuf,
        problem: String,
    },
}

impl fmt::Display for OpenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Model(error) => error.fmt(f),
            Self::Tokenizer(error) => write!(f, "the model's tokenizer: {error}"),
            Self::ChatTemplate { path } => write!(
                f,
                "{} has a chat template other than Qwen3's, which is the only one this build renders",
                path.display()
            ),
            Self::Read { path, problem } => write!(f, "couldn't read {}: {problem}", path.display()),
        }
    }
}

impl std::error::Error for OpenError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Model(error) => Some(error),
            Self::Tokenizer(error) => Some(error),
            _ => None,
        }
    }
}

/// Why a reply couldn't be generated.
#[derive(Debug)]
pub enum GenerateError {
    Chat(ChatError),
    Tokenizer(TokenizerError),
    Model(ModelError),
    /// The request asked for an adapter that isn't loaded.
    UnknownAdapter {
        name: String,
    },
}

impl fmt::Display for GenerateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Chat(error) => error.fmt(f),
            Self::Tokenizer(error) => write!(f, "the model's tokenizer: {error}"),
            Self::Model(error) => error.fmt(f),
            Self::UnknownAdapter { name } => write!(f, "the adapter {name:?} was asked for, and isn't loaded"),
        }
    }
}

impl std::error::Error for GenerateError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Chat(error) => Some(error),
            Self::Tokenizer(error) => Some(error),
            Self::Model(error) => Some(error),
            Self::UnknownAdapter { .. } => None,
        }
    }
}

/// The tokens that end a reply when generation_config.json doesn't say: `<|im_end|>` and
/// `<|endoftext|>`.
const END_OF_REPLY: [&str; 2] = ["<|im_end|>", "<|endoftext|>"];

/// A Qwen3 model, ready to reply to chats, with the adapters loaded for it.
pub struct LanguageModel {
    model: OpenVinoModel,
    tokenizer: Tokenizer,
    end_of_reply: Vec<u32>,
    adapters: Vec<Adapter>,
}

impl LanguageModel {
    /// Opens the model in `folder`: its OpenVINO model (`openvino_model.xml` and `.bin`), compiled
    /// as `options` say, and its tokenizer (`vocab.json`, `merges.txt`, `tokenizer_config.json`,
    /// whose chat template must be Qwen3's), and the tokens that end a reply
    /// (`generation_config.json`'s `eos_token_id`, when it has one).
    pub fn open(folder: &Path, options: &Options) -> Result<Self, OpenError> {
        let tokenizer = Tokenizer::load_with_merges(folder).map_err(OpenError::Tokenizer)?;
        check_chat_template(folder)?;
        let end_of_reply = end_of_reply(folder, &tokenizer)?;
        let model = OpenVinoModel::load(folder, options).map_err(OpenError::Model)?;
        Ok(Self {
            model,
            tokenizer,
            end_of_reply,
            adapters: Vec::new(),
        })
    }

    /// Whether the model takes adapters: whether it was exported with adapter inputs.
    pub fn takes_adapters(&self) -> bool {
        !self.model.adapter_inputs().is_empty()
    }

    /// Loads the adapter in `folder` (`adapters.safetensors` and `adapter_config.json`, as mlx-lm
    /// writes them) for requests to use as `name`, in place of any adapter loaded as `name`
    /// before. It must have a matrix for each of the model's adapter inputs, and only those.
    pub fn load_adapter(&mut self, name: &str, folder: &Path) -> Result<&Adapter, AdapterError> {
        if !self.takes_adapters() {
            return Err(AdapterError::NotAdaptable);
        }
        let adapter = Adapter::load(name, folder, self.model.adapter_inputs())?;
        tracing::info!(
            adapter = name,
            rank = adapter.rank(),
            scale = adapter.scale(),
            base = adapter.base().unwrap_or("unknown"),
            "Loaded the adapter from {}",
            folder.display()
        );
        self.adapters.retain(|loaded| loaded.name() != name);
        self.adapters.push(adapter);
        Ok(self.adapters.last().expect("just loaded"))
    }

    /// The adapters loaded, in the order they were.
    pub fn adapters(&self) -> &[Adapter] {
        &self.adapters
    }

    /// The OpenVINO device it runs on.
    pub fn device(&self) -> &str {
        self.model.device()
    }

    pub fn tokenizer(&self) -> &Tokenizer {
        &self.tokenizer
    }

    /// The prompt's ids for `messages`, as Hugging Face's `apply_chat_template(messages,
    /// tokenize=True, add_generation_prompt=True, enable_thinking=thinking)` gives them.
    pub fn prompt(&self, messages: &[Message], thinking: bool) -> Result<Vec<u32>, GenerateError> {
        let text = chat::render(messages, thinking).map_err(GenerateError::Chat)?;
        self.tokenizer.encode(&text).map_err(GenerateError::Tokenizer)
    }

    /// Generates the reply to `request`. `cancelled` is asked before the prompt runs and between
    /// tokens; once it says so, the reply ends there ([`Stop::Cancelled`]) with what it has. A
    /// deadline is a `cancelled` that watches the clock.
    pub fn generate(&mut self, request: &Request, cancelled: &dyn Fn() -> bool) -> Result<Reply, GenerateError> {
        let adapter = match &request.adapter {
            Some(name) => Some(
                self.adapters
                    .iter()
                    .position(|adapter| adapter.name() == name)
                    .ok_or_else(|| GenerateError::UnknownAdapter { name: name.clone() })?,
            ),
            None => None,
        };
        let prompt = self.prompt(&request.messages, request.thinking)?;
        let mut reply = Reply {
            text: String::new(),
            prompt_tokens: prompt.len(),
            reply_tokens: 0,
            prefill_ms: 0.0,
            decode_ms: 0.0,
            stop: Stop::MaxTokens,
        };
        if request.max_tokens == 0 {
            return Ok(reply);
        }
        if cancelled() {
            reply.stop = Stop::Cancelled;
            return Ok(reply);
        }
        let started = Instant::now();
        let result = self.decode(&prompt, request, adapter, cancelled, &mut reply, started);
        // The cache goes as soon as the reply ends, not with the next prompt.
        self.model.finish();
        let tokens = result?;
        reply.reply_tokens = tokens.len();
        reply.text = self.tokenizer.decode(&tokens);
        Ok(reply)
    }

    /// The reply's tokens, with the adapter at `adapter` in [`Self::adapters`] or none, filling
    /// in `reply`'s timings and why it stopped.
    fn decode(
        &mut self,
        prompt: &[u32],
        request: &Request,
        adapter: Option<usize>,
        cancelled: &dyn Fn() -> bool,
        reply: &mut Reply,
        started: Instant,
    ) -> Result<Vec<u32>, GenerateError> {
        let mut sampler = Sampler::new(request.sampling);
        let adapter = adapter.map(|index| &self.adapters[index]);
        let logits = self.model.prefill(prompt, adapter).map_err(GenerateError::Model)?;
        let prefilled = Instant::now();
        reply.prefill_ms = milliseconds(prefilled - started);
        let mut next = sampler.choose(&logits);
        let mut tokens = Vec::new();
        let stop = loop {
            if self.end_of_reply.contains(&next) {
                break Stop::EndOfReply;
            }
            tokens.push(next);
            if tokens.len() >= request.max_tokens {
                break Stop::MaxTokens;
            }
            if cancelled() {
                break Stop::Cancelled;
            }
            let logits = self.model.step(next).map_err(GenerateError::Model)?;
            next = sampler.choose(&logits);
        };
        reply.decode_ms = milliseconds(prefilled.elapsed());
        reply.stop = stop;
        Ok(tokens)
    }
}

fn milliseconds(duration: std::time::Duration) -> f64 {
    duration.as_secs_f64() * 1_000.0
}

/// Refuses a tokenizer_config.json whose chat template [`chat::render`] doesn't render.
fn check_chat_template(folder: &Path) -> Result<(), OpenError> {
    #[derive(Deserialize)]
    struct Config {
        chat_template: Option<String>,
    }
    let path = folder.join("tokenizer_config.json");
    let text = std::fs::read_to_string(&path).map_err(|error| OpenError::Read {
        path: path.clone(),
        problem: error.to_string(),
    })?;
    let config: Config = serde_json::from_str(&text).map_err(|error| OpenError::Read {
        path: path.clone(),
        problem: error.to_string(),
    })?;
    match config.chat_template {
        Some(template) if chat::is_known_template(&template) => Ok(()),
        _ => Err(OpenError::ChatTemplate { path }),
    }
}

/// The tokens that end a reply: generation_config.json's `eos_token_id` (one or a list) and
/// `<|im_end|>`, which ends every turn of the chat template; or, without that file,
/// [`END_OF_REPLY`].
fn end_of_reply(folder: &Path, tokenizer: &Tokenizer) -> Result<Vec<u32>, OpenError> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Ids {
        One(u32),
        Many(Vec<u32>),
    }
    #[derive(Deserialize)]
    struct Config {
        eos_token_id: Option<Ids>,
    }
    let path = folder.join("generation_config.json");
    let configured = match std::fs::read_to_string(&path) {
        Ok(text) => {
            serde_json::from_str::<Config>(&text)
                .map_err(|error| OpenError::Read {
                    path: path.clone(),
                    problem: error.to_string(),
                })?
                .eos_token_id
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => {
            return Err(OpenError::Read {
                path,
                problem: error.to_string(),
            });
        }
    };
    let mut ids = match configured {
        Some(Ids::One(id)) => vec![id],
        Some(Ids::Many(ids)) => ids,
        None => END_OF_REPLY
            .iter()
            .map(|token| tokenizer.id(token))
            .collect::<Result<_, _>>()
            .map_err(OpenError::Tokenizer)?,
    };
    let turn_end = tokenizer.id(END_OF_REPLY[0]).map_err(OpenError::Tokenizer)?;
    if !ids.contains(&turn_end) {
        ids.push(turn_end);
    }
    Ok(ids)
}
