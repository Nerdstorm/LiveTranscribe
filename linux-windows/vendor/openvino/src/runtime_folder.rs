//! Loading OpenVINO from a folder an application ships it in, rather than from wherever
//! `openvino-finder` finds it.
//!
//! Not in openvino 0.11.0: added by LiveTranscribe (see `VENDORED.md`).

use crate::LoadingError;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// The libraries the C API needs, loaded first and in this order, each by its full path. Intel's
/// libraries have no RUNPATH, so the dynamic linker wouldn't look for them beside the C API; once
/// loaded, they satisfy the C API's and the plugins' dependencies by their sonames (on Windows,
/// by their names). hwloc is for tbbbind, which TBB loads from its own folder to learn the CPU's
/// core types. One missing from the folder is left to the system's library path.
#[cfg(not(windows))]
const DEPENDENCIES: [&str; 3] = ["libhwloc.so", "libtbb.so", "libopenvino.so"];
#[cfg(windows)]
const DEPENDENCIES: [&str; 2] = ["tbb12.dll", "openvino.dll"];

/// The C API, which `openvino-sys` loads.
#[cfg(not(windows))]
const C_API: &str = "libopenvino_c.so";
#[cfg(windows)]
const C_API: &str = "openvino_c.dll";

/// The C API [`load_from_folder`] loaded, and the libraries it loaded before it, which stay loaded
/// for as long as the process runs.
static LOADED: OnceLock<(PathBuf, Vec<libloading::Library>)> = OnceLock::new();

/// Loads OpenVINO from `folder`, where an application keeps its own copy of the runtime (the C
/// API, the core library and its plugins, and TBB), and returns the C API's path. After it,
/// [`Core::new`](crate::Core::new) uses this copy and searches the system for none.
///
/// On Linux a library may have its soname's version after its name, as `libopenvino.so.2621`,
/// which is how a folder without symlinks has it.
///
/// Call it once, before anything else in this crate: a process can hold only one OpenVINO, and a
/// call after the library was loaded, from here or from the system, changes nothing.
///
/// # Errors
///
/// When the folder has no C API, or a library in it can't be loaded.
pub fn load_from_folder(folder: &Path) -> Result<PathBuf, LoadingError> {
    if let Some((path, _)) = LOADED.get() {
        return Ok(path.clone());
    }
    let Some(c_api) = library_in(folder, C_API) else {
        return Err(LoadingError::SystemFailure(format!(
            "{} has no {C_API}",
            folder.display()
        )));
    };
    let mut dependencies = Vec::with_capacity(DEPENDENCIES.len());
    for path in DEPENDENCIES.iter().filter_map(|name| library_in(folder, name)) {
        // Loading runs the library's initialisers, as linking to it would.
        let library = unsafe { libloading::Library::new(&path) }.map_err(|error| {
            LoadingError::SystemFailure(format!("{} could not be loaded: {error}", path.display()))
        })?;
        dependencies.push(library);
    }
    openvino_sys::library::load_from(&c_api).map_err(LoadingError::SystemFailure)?;
    Ok(LOADED.get_or_init(|| (c_api, dependencies)).0.clone())
}

/// The library `name` in `folder`: the file of that name, or on Linux one with a version after it
/// (`libopenvino.so.2621` for `libopenvino.so`).
fn library_in(folder: &Path, name: &str) -> Option<PathBuf> {
    let exact = folder.join(name);
    if exact.is_file() || cfg!(windows) {
        return exact.is_file().then_some(exact);
    }
    let versioned = format!("{name}.");
    let mut found: Vec<PathBuf> = std::fs::read_dir(folder)
        .ok()?
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .file_name()
                .to_str()
                .is_some_and(|file| file.starts_with(&versioned))
        })
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .collect();
    // Several are one library's names, linked to one file.
    found.sort();
    found.into_iter().next()
}

/// The C API [`load_from_folder`] loaded, if it did.
pub(crate) fn loaded_c_api() -> Option<&'static Path> {
    LOADED.get().map(|(path, _)| path.as_path())
}

#[cfg(all(test, not(windows)))]
mod tests {
    use super::*;

    #[test]
    fn a_library_is_found_by_its_name_or_its_soname() {
        let folder = std::env::temp_dir().join(format!("openvino-runtime-folder-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(&folder).unwrap();
        for file in ["libopenvino.so.2621", "libopenvino_c.so.2621", "libtbbmalloc.so.2"] {
            std::fs::write(folder.join(file), b"").unwrap();
        }
        assert_eq!(library_in(&folder, "libopenvino.so"), Some(folder.join("libopenvino.so.2621")));
        assert_eq!(library_in(&folder, "libopenvino_c.so"), Some(folder.join("libopenvino_c.so.2621")));
        assert_eq!(library_in(&folder, "libtbb.so"), None, "libtbbmalloc isn't libtbb");
        std::fs::write(folder.join("libtbb.so"), b"").unwrap();
        assert_eq!(library_in(&folder, "libtbb.so"), Some(folder.join("libtbb.so")));
        let _ = std::fs::remove_dir_all(folder);
    }
}
