//! What the clipboard holds: data for each type it is offered as, in the order offered.

use std::sync::Arc;

/// The types text is offered as, as wl-copy offers it: the MIME types, then the X11 names that
/// XWayland apps ask for.
const TEXT_TYPES: [&str; 5] = [
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
];

/// Tells clipboard managers that honour it (KDE's, and others that follow it) to leave the entry
/// out of their history: the Mac app marks its pasteboard items transient for the same reason.
const PASSWORD_MANAGER_HINT: &str = "x-kde-passwordManagerHint";

/// X11 selection targets that describe the selection rather than hold its data.
const META_TYPES: [&str; 7] = [
    "TARGETS",
    "MULTIPLE",
    "TIMESTAMP",
    "SAVE_TARGETS",
    "DELETE",
    "INSERT_PROPERTY",
    "INSERT_SELECTION",
];

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ClipboardContents {
    entries: Vec<(String, Arc<[u8]>)>,
}

impl ClipboardContents {
    /// Dictated text on its way into an app: UTF-8 under every text type, kept out of clipboard
    /// histories.
    pub fn text(text: &str) -> Self {
        let mut contents = Self::copied_text(text);
        contents
            .entries
            .push((PASSWORD_MANAGER_HINT.to_owned(), Arc::from(&b"secret"[..])));
        contents
    }

    /// Text the user copies, as *Copy Last Dictation* copies it: UTF-8 under every text type, and
    /// in clipboard histories like any other copy.
    pub fn copied_text(text: &str) -> Self {
        let data: Arc<[u8]> = Arc::from(text.as_bytes());
        let entries = TEXT_TYPES
            .iter()
            .map(|mime_type| ((*mime_type).to_owned(), Arc::clone(&data)))
            .collect();
        Self { entries }
    }

    /// Adds `data` as `mime_type`; a type added twice keeps its first data.
    pub fn push(&mut self, mime_type: &str, data: Vec<u8>) {
        if self.get(mime_type).is_none() {
            self.entries.push((mime_type.to_owned(), Arc::from(data)));
        }
    }

    pub fn get(&self, mime_type: &str) -> Option<Arc<[u8]>> {
        self.entries
            .iter()
            .find(|(offered, _)| offered == mime_type)
            .map(|(_, data)| Arc::clone(data))
    }

    pub fn mime_types(&self) -> impl Iterator<Item = &str> {
        self.entries.iter().map(|(mime_type, _)| mime_type.as_str())
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The bytes held, counting data shared between types once per type.
    pub fn byte_count(&self) -> usize {
        self.entries.iter().map(|(_, data)| data.len()).sum()
    }
}

/// Whether reading `mime_type` from dictated text reads the text itself, rather than the hint
/// for clipboard histories.
pub fn is_text(mime_type: &str) -> bool {
    TEXT_TYPES.contains(&mime_type)
}

/// Whether a type the clipboard offers is worth saving to put back: not a description of the
/// selection itself.
pub fn holds_data(mime_type: &str) -> bool {
    !META_TYPES.contains(&mime_type)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_is_offered_under_every_text_type_and_hidden_from_histories() {
        let contents = ClipboardContents::text("Hello, 世界");
        let types: Vec<_> = contents.mime_types().collect();
        assert_eq!(
            types,
            [
                "text/plain;charset=utf-8",
                "text/plain",
                "UTF8_STRING",
                "STRING",
                "TEXT",
                "x-kde-passwordManagerHint"
            ]
        );
        assert_eq!(&*contents.get("UTF8_STRING").unwrap(), "Hello, 世界".as_bytes());
        assert_eq!(&*contents.get("x-kde-passwordManagerHint").unwrap(), b"secret");
        assert!(contents.get("image/png").is_none());
    }

    #[test]
    fn text_the_user_copies_goes_into_histories() {
        let contents = ClipboardContents::copied_text("Ship it.");
        assert!(contents.get("x-kde-passwordManagerHint").is_none());
        assert_eq!(contents.mime_types().count(), 5);
        assert_eq!(&*contents.get("text/plain").unwrap(), b"Ship it.");
    }

    #[test]
    fn keeps_what_was_saved_in_order() {
        let mut contents = ClipboardContents::default();
        assert!(contents.is_empty());
        contents.push("image/png", vec![1, 2, 3]);
        contents.push("text/html", b"<b>x</b>".to_vec());
        contents.push("image/png", vec![9]);
        assert_eq!(contents.mime_types().collect::<Vec<_>>(), ["image/png", "text/html"]);
        assert_eq!(&*contents.get("image/png").unwrap(), [1, 2, 3]);
        assert_eq!(contents.byte_count(), 11);
    }

    #[test]
    fn only_the_text_types_hold_the_text() {
        assert!(is_text("text/plain;charset=utf-8"));
        assert!(is_text("UTF8_STRING"));
        assert!(!is_text("x-kde-passwordManagerHint"));
        assert!(!is_text("image/png"));
    }

    #[test]
    fn descriptions_of_the_selection_are_not_saved() {
        assert!(!holds_data("TARGETS"));
        assert!(!holds_data("SAVE_TARGETS"));
        assert!(holds_data("text/plain"));
        assert!(holds_data("image/png"));
    }
}
