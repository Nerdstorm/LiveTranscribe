//! Tauri's build step, for the tray, where dictation runs: Linux for now. And on Linux, where the
//! packaged app finds the sherpa-onnx libraries it links: the deb and rpm install them in
//! /usr/lib/live-transcribe/sherpa-onnx, beside /usr/bin. (The AppImage has them in usr/lib, where
//! linuxdeploy points the app.) `cargo run` and `cargo test` find them in target/sherpa-onnx/lib,
//! as the link path is in the target folder.

fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-arg-bins=-Wl,-rpath,$ORIGIN/../lib/live-transcribe/sherpa-onnx");
        tauri_build::build();
    }
}
