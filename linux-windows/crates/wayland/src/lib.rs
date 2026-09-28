//! The app's Wayland session on Linux: one connection, on a thread of its own, for everything the
//! app does in the desktop. It types dictated text (through the input method when the focused
//! field takes one, otherwise by pasting), tells the dictation flow about the focused field, and
//! shows the dictation panel by the mouse pointer.
//!
//! It needs a compositor that lets ordinary programs manage the clipboard (ext-data-control-v1)
//! and type keys (virtual-keyboard-v1), and for the rest, be the input method (input-method-v2),
//! show overlays (wlr-layer-shell) and say where the pointer is (ext-image-copy-capture-v1's
//! cursor sessions), as COSMIC does. Dictated text is never logged.
#![cfg(target_os = "linux")]

mod event_loop;
mod input_method;
mod panel;
mod paste;
mod pointer;
mod session;
mod shm;

pub use session::{Capabilities, PanelConfiguration, SessionConfiguration, SessionError, WaylandSession};
