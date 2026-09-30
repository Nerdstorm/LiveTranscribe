//! The console a command was typed in. The app is a windowed program, so that starting it from
//! the Start menu opens no console window; but a windowed program gets no console from the one it
//! was started in either, so what `livetranscribe models` prints would go nowhere.

use std::os::windows::io::AsRawHandle;

use winsafe::{self as w, co, prelude::*};

/// Sends the app's output to the console it was started in, if there is one and the output isn't
/// already going somewhere, such as a file. Says whether it goes anywhere now: not when the app
/// was started from the Start menu or Explorer.
pub fn attach_parent_console() -> bool {
    if !std::io::stdout().as_raw_handle().is_null() || !std::io::stderr().as_raw_handle().is_null() {
        return true;
    }
    w::AttachConsole(w::PidParent::Parent).is_ok()
}

/// Shows why the app stopped in a message box, for an app started without a console to say it in:
/// a second copy of the app, say, which would otherwise vanish without a word.
pub fn show_error(message: &str) {
    let flags = co::MB::OK | co::MB::ICONERROR | co::MB::SETFOREGROUND;
    if let Err(error) = w::HWND::NULL.MessageBox(message, "Live Transcribe", flags) {
        tracing::error!("Couldn't show why Live Transcribe stopped: {error}");
    }
}
