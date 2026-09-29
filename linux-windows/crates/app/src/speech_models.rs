//! The catalog's speech models on this computer ([`lt_transcription::catalog`]), as the Mac app's
//! SpeechModelDownloads and SpeechModelLibrary have them: where each is kept, downloading one
//! (fetching it, and unpacking it from its archive), checking it and removing it
//! ([`SpeechModelDownloads`]), and the one library of them the app has, which dictation and
//! Settings › Models share ([`SpeechModelLibrary`]).

mod archive;
mod downloads;
mod fetch;
// Settings › Models and dictation, which use all of it, are on Linux for now.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod library;

use std::path::{Path, PathBuf};

use lt_transcription::catalog::{Engine, SpeechModel, SpeechModelCatalog};

pub(crate) use downloads::SpeechModelDownloads;
pub(crate) use fetch::{Progress, Stage};
#[cfg(target_os = "linux")]
pub(crate) use library::EnsureError;
pub(crate) use library::{DownloadState, SpeechModelLibrary};

/// The model the app uses until another is chosen, by its catalog id: the Mac app's default, the
/// Sinhala fine-tune of Qwen3-ASR-0.6B, which Linux and Windows run on OpenVINO.
pub(crate) const DEFAULT_MODEL: &str = "qwen3-asr-0.6b-sinhala";

/// A speech model as the Speech-to-text setting (`sttModel`) or `--model` names it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ChosenModel {
    /// A catalog model, by its id: downloaded when it isn't here yet.
    Catalog(&'static SpeechModel),
    /// A folder the setup kit converted a Qwen3-ASR model into.
    Converted(PathBuf),
}

impl ChosenModel {
    /// The model `setting` names: a catalog model's id, or else a folder, in `models` or a path.
    pub(crate) fn named(setting: &str, catalog: &'static SpeechModelCatalog, models: &Path) -> Self {
        match catalog.model(setting) {
            Some(model) => Self::Catalog(model),
            None => Self::Converted(models.join(setting)),
        }
    }

    /// The model as Settings and the terminal name it.
    pub(crate) fn name(&self) -> String {
        match self {
            Self::Catalog(model) => model.name.clone(),
            Self::Converted(folder) => folder.display().to_string(),
        }
    }

    /// Whether our OpenVINO runtime runs it, where the device setting counts; sherpa-onnx runs
    /// the others on the CPU.
    pub(crate) fn runs_on_openvino(&self) -> bool {
        match self {
            Self::Catalog(model) => matches!(model.engine, Engine::OpenVino { .. }),
            Self::Converted(_) => true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_setting_is_a_catalog_model_or_a_folder() {
        let catalog = SpeechModelCatalog::bundled();
        let models = Path::new("/home/me/.local/share/live-transcribe/models");
        let ChosenModel::Catalog(model) = ChosenModel::named(DEFAULT_MODEL, catalog, models) else {
            panic!("the default is in the catalog");
        };
        assert!(matches!(model.engine, Engine::OpenVino { .. }));
        assert_eq!(
            ChosenModel::named("qwen3-asr-0.6b-v2", catalog, models),
            ChosenModel::Converted(models.join("qwen3-asr-0.6b-v2"))
        );
        assert_eq!(
            ChosenModel::named("/srv/models/mine", catalog, models),
            ChosenModel::Converted(PathBuf::from("/srv/models/mine"))
        );
        assert!(!ChosenModel::named("parakeet-tdt-0.6b-v2", catalog, models).runs_on_openvino());
    }
}
