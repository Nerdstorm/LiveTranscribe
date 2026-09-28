//! Where the app keeps its files: the platform's data, config and cache folders (on Linux,
//! `$XDG_DATA_HOME`, `$XDG_CONFIG_HOME` and `$XDG_CACHE_HOME`, or `~/.local/share`, `~/.config`
//! and `~/.cache`), in `live-transcribe`.

use std::path::{Path, PathBuf};

use anyhow::Context;

const APP_FOLDER: &str = "live-transcribe";

/// The OpenVINO runtime the app was installed with, if it was, beside the `bin` folder the app is
/// in: the deb and rpm put it in `/usr/lib/live-transcribe/openvino`, and the AppImage in its
/// `usr/share/live-transcribe/openvino`, since linuxdeploy, which makes the AppImage, would change
/// Intel's libraries in `usr/lib` (it sets their RUNPATH), which their licence doesn't allow. None
/// when the app runs from elsewhere, such as a build folder; then OpenVINO is found as
/// `INTEL_OPENVINO_DIR` or the library path says.
pub fn bundled_openvino() -> Option<PathBuf> {
    let app = std::env::current_exe()
        .inspect_err(|error| tracing::warn!("The app's own path is unknown: {error}"))
        .ok()?;
    bundled_openvino_beside(&app)
}

fn bundled_openvino_beside(app: &Path) -> Option<PathBuf> {
    let prefix = app.parent()?.parent()?;
    ["lib", "share"]
        .into_iter()
        .map(|folder| prefix.join(folder).join(APP_FOLDER).join("openvino"))
        .find(|folder| folder.is_dir())
}

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

/// The settings file.
#[cfg(target_os = "linux")]
pub fn settings_file() -> anyhow::Result<PathBuf> {
    Ok(dirs::config_dir()
        .context("the config folder is unknown; set HOME or XDG_CONFIG_HOME")?
        .join(APP_FOLDER)
        .join("settings.json"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bundled_openvino_is_beside_the_apps_bin_folder() {
        let root = std::env::temp_dir().join(format!("lt-paths-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let app = root.join("usr/bin/livetranscribe");
        std::fs::create_dir_all(app.parent().unwrap()).unwrap();
        assert_eq!(bundled_openvino_beside(&app), None, "a build folder has none");

        let appimage = root.join("usr/share/live-transcribe/openvino");
        std::fs::create_dir_all(&appimage).unwrap();
        assert_eq!(bundled_openvino_beside(&app), Some(appimage), "the AppImage's");

        let packaged = root.join("usr/lib/live-transcribe/openvino");
        std::fs::create_dir_all(&packaged).unwrap();
        assert_eq!(
            bundled_openvino_beside(&app),
            Some(packaged),
            "the deb's and rpm's first"
        );
        let _ = std::fs::remove_dir_all(root);
    }
}
