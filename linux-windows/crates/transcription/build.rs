//! Refuses to build without SHERPA_ONNX_LIB_DIR, the speech-only sherpa-onnx libraries'
//! folder, which linux-windows/.cargo/config.toml sets. Without it the sherpa-onnx crate's build
//! script downloads sherpa-onnx's default libraries, unchecked, and they link espeak-ng (GPL-3.0).
//! Cargo reads that file only when it runs in linux-windows or a folder in it.
//!
//! On Windows it also puts the libraries' DLLs beside the test executables (see
//! [`copy_dlls_beside_tests`]).

use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=SHERPA_ONNX_LIB_DIR");
    let Some(libraries) = std::env::var_os("SHERPA_ONNX_LIB_DIR") else {
        panic!(
            "SHERPA_ONNX_LIB_DIR isn't set. Run cargo in linux-windows, whose .cargo/config.toml sets it, \
             after packaging/fetch-sherpa-onnx.sh has fetched the speech-only sherpa-onnx libraries"
        );
    };
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        copy_dlls_beside_tests(Path::new(&libraries));
    }
}

/// Windows looks for a DLL in the executable's folder, then in System32, and only then on the
/// PATH, where cargo puts the folder the sherpa-onnx crate copies the DLLs to. System32 has an
/// ONNX Runtime of its own (1.17.1 on GitHub's runners), too old for sherpa-onnx, which then
/// crashes: "The requested API version [28] is not available". Test executables are in
/// target/<profile>/deps, so the DLLs go there. The app must carry them beside its own executable.
fn copy_dlls_beside_tests(libraries: &Path) {
    let out_dir = PathBuf::from(std::env::var_os("OUT_DIR").expect("cargo sets OUT_DIR"));
    // OUT_DIR is target/<profile>/build/<package>-<hash>/out.
    let deps = out_dir
        .ancestors()
        .nth(3)
        .expect("OUT_DIR is inside target/<profile>")
        .join("deps");
    std::fs::create_dir_all(&deps).unwrap_or_else(|error| panic!("couldn't create {}: {error}", deps.display()));
    let entries = std::fs::read_dir(libraries)
        .unwrap_or_else(|error| panic!("couldn't read SHERPA_ONNX_LIB_DIR, {}: {error}", libraries.display()));
    for entry in entries {
        let path = entry.expect("SHERPA_ONNX_LIB_DIR can be listed").path();
        if path
            .extension()
            .is_some_and(|extension| extension.eq_ignore_ascii_case("dll"))
        {
            println!("cargo:rerun-if-changed={}", path.display());
            let destination = deps.join(path.file_name().expect("a DLL has a name"));
            std::fs::copy(&path, &destination).unwrap_or_else(|error| {
                panic!("couldn't copy {} to {}: {error}", path.display(), destination.display())
            });
        }
    }
}
