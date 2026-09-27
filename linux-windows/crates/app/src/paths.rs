//! Where the app keeps its files: the platform's data and cache folders (on Linux,
//! `$XDG_DATA_HOME` and `$XDG_CACHE_HOME`, or `~/.local/share` and `~/.cache`), in `live-transcribe`.

use std::path::PathBuf;

use anyhow::Context;

const APP_FOLDER: &str = "live-transcribe";

/// The speech model's folder, where the setup kit's export writes it.
pub fn default_model() -> anyhow::Result<PathBuf> {
    Ok(dirs::data_dir()
        .context("the data folder is unknown; set HOME or XDG_DATA_HOME, or pass --model")?
        .join(APP_FOLDER)
        .join("models")
        .join("qwen3-asr-0.6b"))
}

/// Where OpenVINO keeps compiled models between runs.
pub fn openvino_cache() -> Option<PathBuf> {
    dirs::cache_dir().map(|cache| cache.join(APP_FOLDER).join("openvino"))
}
