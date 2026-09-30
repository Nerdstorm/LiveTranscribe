//! Which OpenVINO runtime the models run on: the copy an installed app ships with, when the app
//! names its folder ([`use_openvino_in`]), and otherwise the one `openvino-finder` finds
//! (`INTEL_OPENVINO_DIR`, the library path, the system's folders).
//!
//! lt-language-model loads it, once for the process, so speech to text and the cleanup model run
//! on the same one, whichever opens first.

pub use lt_language_model::runtime::use_openvino_in;

use super::OpenVinoError;

/// Loads the app's own OpenVINO, if it named one, before the first model opens. Without one,
/// OpenVINO is found when the first model opens, as `openvino-finder` finds it.
pub(super) fn load() -> Result<(), OpenVinoError> {
    lt_language_model::runtime::load().map_err(|error| OpenVinoError::Runtime {
        folder: error.folder,
        problem: error.problem,
    })
}
