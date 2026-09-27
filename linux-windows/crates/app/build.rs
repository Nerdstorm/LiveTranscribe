//! Tauri's build step, for the tray, where dictation runs: Linux for now.

fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        tauri_build::build();
    }
}
