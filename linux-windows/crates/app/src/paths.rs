//! Where the app keeps its files: the platform's data and cache folders (on Linux,
//! `$XDG_DATA_HOME` and `$XDG_CACHE_HOME`, or `~/.local/share` and `~/.cache`), in `live-transcribe`.

use std::path::PathBuf;

use anyhow::Context;

const APP_FOLDER: &str = "live-transcribe";

/// The default speech model's folder in [`models_folder`]: the Mac app's default model, the
/// Sinhala fine-tune of Qwen3-ASR-0.6B, which the setup kit converts.
pub const DEFAULT_MODEL: &str = "qwen3-asr-0.6b-sinhala";

/// Where the setup kit's export writes the speech models, a folder each.
pub fn models_folder() -> anyhow::Result<PathBuf> {
    Ok(dirs::data_dir()
        .context("the data folder is unknown; set HOME or XDG_DATA_HOME, or pass --model")?
        .join(APP_FOLDER)
        .join("models"))
}

/// The default speech model's folder.
pub fn default_model() -> anyhow::Result<PathBuf> {
    Ok(models_folder()?.join(DEFAULT_MODEL))
}

/// Where OpenVINO keeps compiled models between runs.
pub fn openvino_cache() -> Option<PathBuf> {
    dirs::cache_dir().map(|cache| cache.join(APP_FOLDER).join("openvino"))
}
