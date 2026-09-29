//! Refuses to build without SHERPA_ONNX_LIB_DIR, the speech-only sherpa-onnx libraries'
//! folder, which linux-windows/.cargo/config.toml sets. Without it the sherpa-onnx crate's build
//! script downloads sherpa-onnx's default libraries, unchecked, and they link espeak-ng (GPL-3.0).
//! Cargo reads that file only when it runs in linux-windows or a folder in it.

fn main() {
    println!("cargo:rerun-if-env-changed=SHERPA_ONNX_LIB_DIR");
    if std::env::var_os("SHERPA_ONNX_LIB_DIR").is_none() {
        panic!(
            "SHERPA_ONNX_LIB_DIR isn't set. Run cargo in linux-windows, whose .cargo/config.toml sets it, \
             after packaging/fetch-sherpa-onnx.sh has fetched the speech-only sherpa-onnx libraries"
        );
    }
}
