//! The clipboard, for dictated text nothing could take, and for *Copy Last Dictation*.

use std::thread;
use std::time::Duration;

use clipboard_win::{Clipboard, raw, register_format};

/// Another program may have the clipboard open for a moment: it is tried again this many times,
/// this far apart.
const OPEN_ATTEMPTS: u32 = 10;
const OPEN_RETRY: Duration = Duration::from_millis(20);

/// Formats that keep an entry out of Windows' clipboard history (Win+V) and off the cloud
/// clipboard, each set to a DWORD of 0: as the Mac app marks its pasteboard items transient, and
/// the Linux app hints to clipboard managers.
const PRIVATE_FORMATS: [&str; 2] = ["CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"];

/// Leaves dictated text on the clipboard for the user to paste, out of the clipboard history.
pub(crate) fn leave(text: &str) -> Result<(), String> {
    set(text, true)
}

/// Puts text on the clipboard as copying it in an app would: in the history like any copy.
pub(crate) fn copy(text: &str) -> Result<(), String> {
    set(text, false)
}

fn set(text: &str, private: bool) -> Result<(), String> {
    let _open = open()?;
    raw::set_string(text).map_err(|error| format!("couldn't put the text on the clipboard: {error}"))?;
    if private {
        for name in PRIVATE_FORMATS {
            let marked = register_format(name)
                .ok_or_else(|| "the format isn't known".to_owned())
                .and_then(|format| {
                    raw::set_without_clear(format.get(), &0u32.to_le_bytes()).map_err(|e| e.to_string())
                });
            if let Err(error) = marked {
                // The text is there to paste; only the history keeps it too.
                tracing::warn!("Couldn't keep the text out of the clipboard history ({name}): {error}");
            }
        }
    }
    Ok(())
}

/// Opens the clipboard, which stays open, and this process's, until the guard goes.
fn open() -> Result<Clipboard, String> {
    let mut attempt = 1;
    loop {
        match Clipboard::new() {
            Ok(clipboard) => return Ok(clipboard),
            Err(error) if attempt >= OPEN_ATTEMPTS => {
                return Err(format!(
                    "couldn't open the clipboard, which another program has open: {error}"
                ));
            }
            Err(_) => {
                attempt += 1;
                thread::sleep(OPEN_RETRY);
            }
        }
    }
}
