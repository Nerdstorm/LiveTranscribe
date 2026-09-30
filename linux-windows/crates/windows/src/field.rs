//! What Windows says about where dictated text would go, from window classes and styles.
//!
//! Only the system's own edit controls say anything about the field: Edit and RichEdit, and
//! Windows Forms' wrappers of them, whose styles say whether they hide what is typed (a password
//! field) and whether they take several lines. Browsers, Office and most other apps draw their
//! own fields inside one window, which says neither; such a field is typed into as one nothing is
//! known about is, on one line.

use lt_insertion::InsertionTarget;

/// The edit control hides what is typed into it.
const ES_PASSWORD: u32 = 0x0020;
/// The edit control takes several lines.
const ES_MULTILINE: u32 = 0x0004;

/// The shell's own windows: the desktop and the taskbar, with its notification area. Typed into,
/// dictated text would select desktop icons or search the Start menu, so it waits on the
/// clipboard instead, for the field the user picks.
const SHELL_CLASSES: [&str; 6] = [
    "Progman",
    "WorkerW",
    "Shell_TrayWnd",
    "Shell_SecondaryTrayWnd",
    "NotifyIconOverflowWindow",
    "TopLevelWindowForOverflowXamlIsland",
];

/// The focused field as dictation sees it, from its control's window class and style.
pub(crate) fn target(class: &str, style: u32) -> InsertionTarget {
    if !is_edit_control(class) {
        return InsertionTarget::default();
    }
    InsertionTarget {
        is_secure: style & ES_PASSWORD != 0,
        allows_line_breaks: style & ES_MULTILINE != 0,
        ..InsertionTarget::default()
    }
}

/// A window class whose styles are an edit control's: others may use the same bits for other
/// things, and would read as password fields.
fn is_edit_control(class: &str) -> bool {
    let class = class.to_ascii_lowercase();
    class == "edit"
        || class.starts_with("richedit")
        || class.starts_with("windowsforms10.edit.")
        || class.starts_with("windowsforms10.richedit")
}

/// The foreground window is the shell's rather than an app's.
pub(crate) fn is_shell(class: &str) -> bool {
    SHELL_CLASSES.contains(&class)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_password_edit_control_is_secure() {
        assert!(target("Edit", 0x5001_00A0).is_secure);
        assert!(target("WindowsForms10.EDIT.app.0.141b42a_r6_ad1", ES_PASSWORD).is_secure);
        assert!(target("RichEdit20W", ES_PASSWORD).is_secure);
    }

    #[test]
    fn a_multiline_edit_control_takes_line_breaks() {
        let notepad = target("RichEditD2DPT", 0x5031_1144);
        assert!(notepad.allows_line_breaks);
        assert!(!notepad.is_secure);
        assert!(target("RICHEDIT50W", ES_MULTILINE).allows_line_breaks);
        assert!(!target("Edit", 0x5001_0080).allows_line_breaks);
    }

    #[test]
    fn other_controls_say_nothing_whatever_their_style() {
        assert_eq!(
            target("Chrome_RenderWidgetHostHWND", ES_PASSWORD | ES_MULTILINE),
            InsertionTarget::default()
        );
        assert_eq!(target("_WwG", u32::MAX), InsertionTarget::default());
        assert_eq!(target("EditorPane", ES_PASSWORD), InsertionTarget::default());
    }

    #[test]
    fn the_desktop_and_taskbar_are_the_shells() {
        assert!(is_shell("Progman"));
        assert!(is_shell("Shell_TrayWnd"));
        assert!(!is_shell("Notepad"));
        assert!(
            !is_shell("Windows.UI.Core.CoreWindow"),
            "the Start menu's search takes text"
        );
    }
}
