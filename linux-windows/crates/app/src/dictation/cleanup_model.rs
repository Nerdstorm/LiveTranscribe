//! Cleanup's language model on OpenVINO (lt-language-model) behind lt-cleanup's [`CleanupModel`],
//! with the Mac app's two adapters, so each level cleans up as the Mac app does.

use std::path::Path;

use lt_cleanup::{Adapter, CleanupModel, CleanupRequest, Deadline, Role};
use lt_language_model::{GenerateError, LanguageModel, Message, Request, Sampling};

/// An adapter the app carries: one of the Mac app's, as its package bundles them.
pub(crate) struct BundledAdapter {
    pub(crate) adapter: Adapter,
    /// Its folder in the Mac app's package, for the log.
    pub(crate) origin: &'static str,
    /// `adapter_config.json`.
    pub(crate) config: &'static [u8],
    /// `adapters.safetensors`.
    pub(crate) weights: &'static [u8],
}

/// The Mac app's adapters, compiled into the app: the self-correction adapter, which Medium and
/// High use, and Deep's. About 10 MB each.
pub(crate) const BUNDLED_ADAPTERS: [BundledAdapter; 2] = [
    BundledAdapter {
        adapter: Adapter::Medium,
        origin: "Packages/LiveTranscribeKit/Sources/Cleanup/Adapter",
        config: include_bytes!("../../../../../Packages/LiveTranscribeKit/Sources/Cleanup/Adapter/adapter_config.json"),
        weights: include_bytes!(
            "../../../../../Packages/LiveTranscribeKit/Sources/Cleanup/Adapter/adapters.safetensors"
        ),
    },
    BundledAdapter {
        adapter: Adapter::Deep,
        origin: "Packages/LiveTranscribeKit/Sources/Cleanup/DeepAdapter",
        config: include_bytes!(
            "../../../../../Packages/LiveTranscribeKit/Sources/Cleanup/DeepAdapter/adapter_config.json"
        ),
        weights: include_bytes!(
            "../../../../../Packages/LiveTranscribeKit/Sources/Cleanup/DeepAdapter/adapters.safetensors"
        ),
    },
];

/// The cleanup model, with the adapters it took.
pub(crate) struct OpenVinoCleanup {
    model: LanguageModel,
    adapters: Vec<Adapter>,
}

impl OpenVinoCleanup {
    /// `model`, with the bundled adapters it takes: none when it was exported without adapter
    /// inputs. Without the self-correction adapter, Light, Medium and High ask for nothing to be
    /// removed, as the Mac app does when its adapter can't be used, and Deep runs on the base
    /// model.
    pub(crate) fn new(mut model: LanguageModel) -> Self {
        let mut adapters = Vec::new();
        if model.takes_adapters() {
            for bundled in &BUNDLED_ADAPTERS {
                let name = bundled.adapter.as_str();
                match model.load_adapter_from_bytes(name, Path::new(bundled.origin), bundled.config, bundled.weights) {
                    Ok(_) => adapters.push(bundled.adapter),
                    Err(error) => tracing::error!("The cleanup model's {name} adapter wasn't loaded: {error}"),
                }
            }
        } else {
            tracing::warn!("The cleanup model takes no adapters; cleanup runs on the base model");
        }
        Self { model, adapters }
    }

    /// The adapters it took.
    pub(crate) fn adapters(&self) -> &[Adapter] {
        &self.adapters
    }

    /// The OpenVINO device it runs on.
    pub(crate) fn device(&self) -> &str {
        self.model.device()
    }
}

impl CleanupModel for OpenVinoCleanup {
    type Error = GenerateError;

    fn generate(&mut self, request: &CleanupRequest, deadline: &Deadline<'_>) -> Result<String, GenerateError> {
        let request = runtime_request(request, &self.adapters);
        let reply = self.model.generate(&request, &|| deadline.should_stop())?;
        Ok(reply.text)
    }
}

/// `request` as the runtime takes it, with the adapter it runs with, of those `loaded`.
fn runtime_request(request: &CleanupRequest, loaded: &[Adapter]) -> Request {
    let adapter = request.adapter.resolved(loaded);
    let sampling = request.sampling;
    Request {
        messages: request
            .messages
            .iter()
            .map(|message| {
                let content = message.content.clone();
                match message.role {
                    Role::System => Message::system(content),
                    Role::User => Message::user(content),
                    Role::Assistant => Message::assistant(content),
                }
            })
            .collect(),
        thinking: request.thinks(),
        max_tokens: request.max_tokens,
        sampling: Sampling::from_settings(
            sampling.temperature,
            sampling.top_p,
            sampling.top_k,
            sampling.seed.unwrap_or(0),
        ),
        adapter: (adapter != Adapter::Off).then(|| adapter.as_str().to_owned()),
    }
}

#[cfg(test)]
mod tests {
    use lt_cleanup::{CleanupExecutor, CleanupOptions, DeepCleanup, OutputGuard, PromptBuilder};
    use lt_shared::CleanupLevel;

    use super::*;

    fn request_at(level: CleanupLevel, adapted: bool) -> CleanupRequest {
        CleanupExecutor::new(3, 3.0, OutputGuard::default(), PromptBuilder::new(adapted)).request(
            "send it to john i mean jane",
            &[],
            &CleanupOptions::new(level),
        )
    }

    #[test]
    fn a_request_keeps_its_prompt_and_budget() {
        let request = request_at(CleanupLevel::Medium, true);
        let runtime = runtime_request(&request, &[Adapter::Medium, Adapter::Deep]);
        assert_eq!(runtime.messages.len(), request.messages.len());
        assert_eq!(
            runtime.messages[0],
            Message::system(request.messages[0].content.clone())
        );
        assert_eq!(runtime.messages[1], Message::user(request.messages[1].content.clone()));
        assert_eq!(runtime.max_tokens, request.max_tokens);
        assert!(!runtime.thinking);
        assert_eq!(runtime.sampling, Sampling::Greedy);
        assert_eq!(runtime.adapter.as_deref(), Some("medium"));
    }

    #[test]
    fn each_level_runs_with_the_adapter_the_model_has() {
        let adapter = |level, loaded: &[Adapter]| runtime_request(&request_at(level, true), loaded).adapter;
        let both = [Adapter::Medium, Adapter::Deep];
        assert_eq!(adapter(CleanupLevel::Light, &both), None);
        assert_eq!(adapter(CleanupLevel::High, &both).as_deref(), Some("medium"));
        assert_eq!(adapter(CleanupLevel::Deep, &both).as_deref(), Some("deep"));
        assert_eq!(
            adapter(CleanupLevel::Deep, &[Adapter::Medium]).as_deref(),
            Some("medium"),
            "Deep without its own adapter runs with the self-correction adapter"
        );
        assert_eq!(
            adapter(CleanupLevel::Medium, &[]),
            None,
            "a model without adapters runs on its own"
        );
    }

    #[test]
    fn a_request_that_thinks_samples_as_it_asks() {
        let executor =
            CleanupExecutor::new(3, 3.0, OutputGuard::default(), PromptBuilder::new(true)).with_deep(DeepCleanup {
                thinking: true,
                ..DeepCleanup::SHIPPED
            });
        let request = executor.request(
            "the demo is tuesday sorry wednesday",
            &[],
            &CleanupOptions::new(CleanupLevel::Deep),
        );
        let runtime = runtime_request(&request, &[Adapter::Medium, Adapter::Deep]);
        assert!(runtime.thinking);
        let seed = request.sampling.seed.expect("a seed");
        assert_eq!(runtime.sampling, Sampling::qwen3_thinking(seed));
    }

    #[test]
    fn the_bundled_adapters_are_the_mac_apps() {
        for bundled in &BUNDLED_ADAPTERS {
            let config: serde_json::Value = serde_json::from_slice(bundled.config).expect("an adapter config");
            assert_eq!(
                config["base_model"], "mlx-community/Qwen3-1.7B-4bit",
                "{}",
                bundled.origin
            );
            assert!(bundled.weights.len() > 1_000_000, "{}", bundled.origin);
        }
    }
}
