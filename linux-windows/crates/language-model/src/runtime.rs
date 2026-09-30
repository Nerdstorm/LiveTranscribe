//! Which OpenVINO runtime the models run on: the copy an installed app ships with, when the app
//! names its folder ([`use_openvino_in`]), and otherwise the one `openvino-finder` finds
//! (`INTEL_OPENVINO_DIR`, the library path, the system's folders).
//!
//! A process holds one OpenVINO, loaded with the first model it opens, so speech to text
//! (lt-transcription) and the language models both load it through here.

use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// The folder of the app's own OpenVINO, if it has one.
static FOLDER: OnceLock<PathBuf> = OnceLock::new();

/// Loading it, which happens once, with the first model: the C API's path, or why it failed.
static LOADED: OnceLock<Result<PathBuf, String>> = OnceLock::new();

/// The OpenVINO the app was installed with couldn't be loaded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuntimeError {
    /// The folder it was to be loaded from.
    pub folder: PathBuf,
    pub problem: String,
}

impl fmt::Display for RuntimeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "the OpenVINO installed with the app, in {}, couldn't be loaded ({}); reinstalling the app puts it back",
            self.folder.display(),
            self.problem
        )
    }
}

impl std::error::Error for RuntimeError {}

/// Makes the models run on the OpenVINO runtime in `folder`, the copy the app was installed with,
/// rather than one found on the system. Call it before the first model opens; a later call
/// changes nothing.
pub fn use_openvino_in(folder: PathBuf) {
    if FOLDER.set(folder).is_err() {
        tracing::warn!("The OpenVINO folder was set already; the first one stays");
    }
}

/// Loads the app's own OpenVINO, if it named one, before the first model opens. Without one,
/// OpenVINO is found when the first model opens, as `openvino-finder` finds it.
pub fn load() -> Result<(), RuntimeError> {
    let Some(folder) = FOLDER.get() else {
        return Ok(());
    };
    match LOADED.get_or_init(|| load_from(folder)) {
        Ok(_) => Ok(()),
        Err(problem) => Err(RuntimeError {
            folder: folder.clone(),
            problem: problem.clone(),
        }),
    }
}

fn load_from(folder: &Path) -> Result<PathBuf, String> {
    match openvino::load_from_folder(folder) {
        Ok(c_api) => {
            tracing::info!(path = %c_api.display(), "Loaded the OpenVINO runtime installed with the app");
            Ok(c_api)
        }
        Err(error) => {
            tracing::error!(folder = %folder.display(), "Couldn't load the OpenVINO runtime installed with the app: {error}");
            Err(error.to_string())
        }
    }
}
