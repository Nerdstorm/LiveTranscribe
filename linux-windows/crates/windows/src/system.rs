//! The Win32 calls typing needs, through winsafe's safe wrappers: the window that has the
//! keyboard and its focused control, whether its process runs with more privileges than this one,
//! the modifier keys, and the keystrokes themselves.

use std::sync::OnceLock;

use winsafe::{self as w, co, prelude::*};

/// The window that has the keyboard, and the thread and process that own it.
pub(crate) struct Foreground {
    window: w::HWND,
    pub(crate) thread: u32,
    pub(crate) process: u32,
}

impl Foreground {
    /// The window, to tell whether it still has the keyboard later. A window handle is only a
    /// name for the window, and this only compares names.
    pub(crate) fn id(&self) -> usize {
        self.window.ptr() as usize
    }

    pub(crate) fn class(&self) -> String {
        self.window.GetClassName().unwrap_or_default()
    }

    pub(crate) fn is_visible(&self) -> bool {
        self.window.IsWindowVisible()
    }
}

/// The window that has the keyboard: none while the secure desktop (a UAC prompt, the lock
/// screen) has it, or for a moment as the focus moves.
pub(crate) fn foreground() -> Option<Foreground> {
    let window = w::HWND::GetForegroundWindow()?;
    let (thread, process) = window.GetWindowThreadProcessId();
    Some(Foreground {
        window,
        thread,
        process,
    })
}

/// The window class and style of the control with the keyboard focus in `thread`'s windows, when
/// it is a window of its own (as the system's edit controls are).
pub(crate) fn focused_control(thread: u32) -> Option<(String, u32)> {
    let info = w::GetGUIThreadInfo(thread)
        .inspect_err(|error| tracing::debug!("The focused control is unknown: {error}"))
        .ok()?;
    let focus = &info.hwndFocus;
    if *focus == w::HWND::NULL {
        return None;
    }
    let class = focus.GetClassName().ok()?;
    // A window's style is its low 32 bits.
    let style = focus.GetWindowLongPtr(co::GWLP::STYLE) as u32;
    Some((class, style))
}

/// This process's own id.
pub(crate) fn this_process() -> u32 {
    w::GetCurrentProcessId()
}

/// Whether keystrokes from this process reach `process`'s windows. Windows drops them, without a
/// word, for a process with more privileges (User Interface Privilege Isolation): an app run as
/// administrator, while this one isn't. A process whose token can't be read is taken to be one.
pub(crate) fn can_type_into(process: u32) -> bool {
    if is_elevated_self() {
        return true;
    }
    match process_is_elevated(process) {
        Ok(elevated) => !elevated,
        Err(co::ERROR::ACCESS_DENIED) => false,
        Err(error) => {
            tracing::debug!("Whether the focused app runs as administrator is unknown ({error}); typing into it");
            true
        }
    }
}

fn process_is_elevated(process: u32) -> w::SysResult<bool> {
    let handle = w::HPROCESS::OpenProcess(co::PROCESS::QUERY_LIMITED_INFORMATION, false, process)?;
    is_elevated(&handle)
}

fn is_elevated_self() -> bool {
    static ELEVATED: OnceLock<bool> = OnceLock::new();
    *ELEVATED.get_or_init(|| {
        is_elevated(&w::HPROCESS::GetCurrentProcess())
            .inspect_err(|error| tracing::warn!("Whether Live Transcribe runs as administrator is unknown: {error}"))
            .unwrap_or(false)
    })
}

fn is_elevated(process: &w::HPROCESS) -> w::SysResult<bool> {
    let token = process.OpenProcessToken(co::TOKEN::QUERY)?;
    Ok(
        match token.GetTokenInformation(co::TOKEN_INFORMATION_CLASS::Elevation)? {
            w::TokenInfo::Elevation(elevation) => elevation.TokenIsElevated(),
            _ => false,
        },
    )
}

/// A modifier key is down: Shift, Ctrl, Alt or Windows. Typed with one down, a character could
/// be taken as a shortcut.
pub(crate) fn modifier_held() -> bool {
    [co::VK::SHIFT, co::VK::CONTROL, co::VK::MENU, co::VK::LWIN, co::VK::RWIN]
        .into_iter()
        .any(w::GetAsyncKeyState)
}

/// Types UTF-16 `units`, each as a Unicode key press and release. Windows puts them in the input
/// stream together, with nothing the user types in between.
pub(crate) fn type_units(units: &[u16]) -> Result<(), String> {
    let inputs: Vec<w::HwKbMouse> = units
        .iter()
        .flat_map(|&unit| {
            [
                keystroke(unit, co::KEYEVENTF::UNICODE),
                keystroke(unit, co::KEYEVENTF::UNICODE | co::KEYEVENTF::KEYUP),
            ]
        })
        .collect();
    let sent = w::SendInput(&inputs).map_err(|error| format!("Windows didn't take the keystrokes: {error}"))?;
    if sent as usize != inputs.len() {
        return Err(format!(
            "Windows took {sent} of {} keystrokes; another program may be blocking input",
            inputs.len()
        ));
    }
    Ok(())
}

fn keystroke(unit: u16, flags: co::KEYEVENTF) -> w::HwKbMouse {
    w::HwKbMouse::Kb(w::KEYBDINPUT {
        wScan: unit,
        dwFlags: flags,
        ..Default::default()
    })
}
