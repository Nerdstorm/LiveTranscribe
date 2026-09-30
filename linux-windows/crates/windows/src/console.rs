//! The console a command was typed in. The app is a windowed program, so that starting it from
//! the Start menu opens no console window; but a windowed program gets no console from the one it
//! was started in either, so what `livetranscribe models` prints would go nowhere.

use std::os::windows::io::AsRawHandle;

/// Sends the app's output to the console it was started in, if there is one and the output isn't
/// already going somewhere, such as a file.
pub fn attach_parent_console() {
    if !std::io::stdout().as_raw_handle().is_null() || !std::io::stderr().as_raw_handle().is_null() {
        return;
    }
    // Started from the Start menu or Explorer, there is none to attach to.
    let _ = winsafe::AttachConsole(winsafe::PidParent::Parent);
}
