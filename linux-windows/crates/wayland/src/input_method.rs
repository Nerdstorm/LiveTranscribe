//! The input method (input-method-v2): what the focused field is, and typing straight into it.
//!
//! Apps whose fields speak text-input-v3 (GTK, Qt, Firefox, Chromium with Wayland IME, COSMIC's
//! apps, foot, kitty) activate the input method while a field has focus, and tell it the field's
//! purpose, its hints and the text around the cursor. Committed text goes into the field without
//! the clipboard. The session never grabs the keyboard, so typing is untouched. Only one input
//! method can hold a seat: with IBus or Fcitx running, the compositor says this one is unavailable,
//! and everything is pasted.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use lt_insertion::{Inserted, InsertionMethod, InsertionTarget};
use wayland_client::globals::GlobalList;
use wayland_client::protocol::wl_seat::WlSeat;
use wayland_client::{Connection, Dispatch, QueueHandle, WEnum, delegate_noop};
use wayland_protocols_misc::zwp_input_method_v2::client::zwp_input_method_manager_v2::ZwpInputMethodManagerV2;
use wayland_protocols_misc::zwp_input_method_v2::client::zwp_input_method_v2::{self, ZwpInputMethodV2};

use crate::event_loop::{State, Wayland};
use crate::session::{Done, SessionError};

// text-input-v3's content hints and purposes, as the compositor passes them on.
const HINT_HIDDEN_TEXT: u32 = 0x40;
const HINT_SENSITIVE_DATA: u32 = 0x80;
const HINT_MULTILINE: u32 = 0x200;
const PURPOSE_NORMAL: u32 = 0;
const PURPOSE_ALPHA: u32 = 1;
const PURPOSE_PASSWORD: u32 = 8;
const PURPOSE_PIN: u32 = 9;
const PURPOSE_TERMINAL: u32 = 13;

/// A Wayland message holds at most 4 KiB, so longer text goes in pieces of at most this many
/// bytes, each a commit of its own.
const MAX_PIECE_BYTES: usize = 3_800;
/// After each piece, how long the app gets to report its new state before the next goes anyway.
/// Every commit carries the number of states heard so far, and the compositor drops one that
/// carries a stale count, so the next piece waits for the report.
const PIECE_SETTLE: Duration = Duration::from_millis(200);

/// The focused field, as the compositor describes it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Field {
    hint: u32,
    purpose: u32,
    /// The text around the cursor, with the cursor's and the selection anchor's byte offsets.
    surrounding: Option<(String, u32, u32)>,
}

/// What the compositor has said to the input method. Events change the pending state, and `done`
/// makes it current.
#[derive(Default)]
pub(crate) struct InputMethodState {
    pending_active: bool,
    pending: Field,
    active: bool,
    field: Field,
    /// `done` events so far: what a commit carries.
    serial: u32,
    /// Another input method has the seat.
    pub(crate) unavailable: bool,
}

impl InputMethodState {
    /// A field with an input method has focus.
    pub(crate) fn is_active(&self) -> bool {
        self.active && !self.unavailable
    }

    /// The focused field; the default target when none takes an input method.
    pub(crate) fn target(&self) -> InsertionTarget {
        if !self.is_active() {
            return InsertionTarget::default();
        }
        target(&self.field)
    }

    fn apply(&mut self, event: zwp_input_method_v2::Event) {
        match event {
            zwp_input_method_v2::Event::Activate => {
                // A new field: nothing carries over from the last.
                self.pending_active = true;
                self.pending = Field::default();
            }
            zwp_input_method_v2::Event::Deactivate => self.pending_active = false,
            zwp_input_method_v2::Event::SurroundingText { text, cursor, anchor } => {
                self.pending.surrounding = Some((text, cursor, anchor));
            }
            zwp_input_method_v2::Event::ContentType { hint, purpose } => {
                self.pending.hint = match hint {
                    WEnum::Value(hint) => hint.bits(),
                    WEnum::Unknown(raw) => raw,
                };
                self.pending.purpose = match purpose {
                    WEnum::Value(purpose) => purpose.into(),
                    WEnum::Unknown(raw) => raw,
                };
            }
            zwp_input_method_v2::Event::Done => {
                self.serial = self.serial.wrapping_add(1);
                self.active = self.pending_active;
                self.field = self.pending.clone();
                // The text around the cursor comes afresh with each state; the type stays.
                self.pending.surrounding = None;
            }
            zwp_input_method_v2::Event::Unavailable => {
                self.unavailable = true;
                self.active = false;
            }
            _ => {}
        }
    }
}

/// What typing into `field` means for dictation.
fn target(field: &Field) -> InsertionTarget {
    let secure = matches!(field.purpose, PURPOSE_PASSWORD | PURPOSE_PIN) || field.hint & HINT_HIDDEN_TEXT != 0;
    // Line breaks, as the Mac app decides them: a field takes several lines unless it is certainly
    // single-line. A terminal is (a line break there runs the command), and so is a field for a
    // single value: a number, an address, a date. A field of ordinary text can't be told apart:
    // GTK never says a field takes several lines, and web text boxes seldom do.
    let allows_line_breaks = match field.purpose {
        PURPOSE_TERMINAL => false,
        PURPOSE_NORMAL | PURPOSE_ALPHA => true,
        _ => field.hint & HINT_MULTILINE != 0,
    };
    InsertionTarget {
        is_secure: secure,
        allows_line_breaks,
        // Typing replaces the selection, so what comes before the text is what's before it.
        preceding: field
            .surrounding
            .as_ref()
            .and_then(|(text, cursor, anchor)| preceding(text, (*cursor).min(*anchor))),
        is_private: field.hint & HINT_SENSITIVE_DATA != 0,
    }
}

/// The character before byte `offset` of `text`.
fn preceding(text: &str, offset: u32) -> Option<char> {
    text.get(..usize::try_from(offset).ok()?)?.chars().next_back()
}

/// `text` in pieces of at most `max_bytes`, split between characters.
fn pieces(text: &str, max_bytes: usize) -> impl Iterator<Item = &str> {
    let mut rest = text;
    std::iter::from_fn(move || {
        if rest.is_empty() {
            return None;
        }
        let mut end = rest.len().min(max_bytes);
        while !rest.is_char_boundary(end) {
            end -= 1;
        }
        if end == 0 {
            end = rest.chars().next().map_or(rest.len(), char::len_utf8);
        }
        let (piece, tail) = rest.split_at(end);
        rest = tail;
        Some(piece)
    })
}

/// Text going into the field a piece at a time.
struct Committing {
    pieces: VecDeque<String>,
    characters: usize,
    /// Characters committed so far.
    committed: usize,
    /// The count the last piece carried, and when it went.
    serial: u32,
    sent_at: Instant,
    started: Instant,
    done: Done,
}

pub(crate) struct InputMethod {
    object: ZwpInputMethodV2,
    committing: Option<Committing>,
}

impl InputMethod {
    /// Registers as the seat's input method, when the compositor has input-method-v2.
    pub(crate) fn bind(globals: &GlobalList, seat: &WlSeat, handle: &QueueHandle<State>) -> Option<Self> {
        let manager: ZwpInputMethodManagerV2 = globals.bind(handle, 1..=1, ()).ok()?;
        Some(Self {
            object: manager.get_input_method(seat, handle, ()),
            committing: None,
        })
    }

    pub(crate) fn object(&self) -> &ZwpInputMethodV2 {
        &self.object
    }

    pub(crate) fn is_busy(&self) -> bool {
        self.committing.is_some()
    }

    /// Starts typing `text` into the focused field. The caller has just made a round trip, so the
    /// field and the count of states are current.
    pub(crate) fn start(&mut self, wayland: &mut Wayland, text: String, done: Done) -> Result<(), String> {
        let state = &wayland.state.input_method;
        if state.target().is_secure {
            done.finish(Err(SessionError::SecureField));
            return Ok(());
        }
        let now = Instant::now();
        self.committing = Some(Committing {
            pieces: pieces(&text, MAX_PIECE_BYTES).map(str::to_owned).collect(),
            characters: text.chars().count(),
            committed: 0,
            serial: state.serial,
            sent_at: now,
            started: now,
            done,
        });
        self.send_piece(wayland)
    }

    /// When the next piece goes if the app hasn't reported the last.
    pub(crate) fn deadline(&self) -> Option<Instant> {
        let committing = self.committing.as_ref()?;
        Some(committing.sent_at + PIECE_SETTLE)
    }

    /// Sends the next piece once the app has reported the last one, or had long enough to.
    pub(crate) fn advance(&mut self, wayland: &mut Wayland, now: Instant) -> Result<(), String> {
        let Some(committing) = &self.committing else {
            return Ok(());
        };
        let state = &wayland.state.input_method;
        if state.serial == committing.serial && now < committing.sent_at + PIECE_SETTLE {
            return Ok(());
        }
        if !state.is_active() || state.target().is_secure {
            let committed = committing.committed;
            if let Some(committing) = self.committing.take() {
                tracing::warn!(
                    "Focus left the field after {committed} of {} characters",
                    committing.characters
                );
                committing
                    .done
                    .finish(Err(SessionError::FocusLost { characters: committed }));
            }
            return Ok(());
        }
        self.send_piece(wayland)
    }

    /// The session is stopping: the text going in fails with it.
    pub(crate) fn abandon(&mut self, error: &str) {
        if let Some(committing) = self.committing.take() {
            committing.done.finish(Err(SessionError::Connection(error.to_owned())));
        }
    }

    /// The compositor made it inert: text going in stops there.
    pub(crate) fn destroy(mut self) {
        if let Some(committing) = self.committing.take() {
            let characters = committing.committed;
            committing.done.finish(Err(SessionError::FocusLost { characters }));
        }
        self.object.destroy();
    }

    fn send_piece(&mut self, wayland: &mut Wayland) -> Result<(), String> {
        let Some(committing) = &mut self.committing else {
            return Ok(());
        };
        if let Some(piece) = committing.pieces.pop_front() {
            let serial = wayland.state.input_method.serial;
            committing.committed += piece.chars().count();
            self.object.commit_string(piece);
            self.object.commit(serial);
            committing.serial = serial;
            committing.sent_at = Instant::now();
        }
        if !committing.pieces.is_empty() {
            return wayland.flush();
        }
        // The compositor has the text once it answers.
        wayland.roundtrip()?;
        if let Some(committing) = self.committing.take() {
            tracing::info!(
                "Committed {} characters through the input method in {} ms",
                committing.characters,
                committing.started.elapsed().as_millis()
            );
            committing.done.finish(Ok(Inserted {
                characters: committing.characters,
                method: InsertionMethod::InputMethod,
                read: true,
                restored: true,
            }));
        }
        Ok(())
    }
}

delegate_noop!(State: ZwpInputMethodManagerV2);

impl Dispatch<ZwpInputMethodV2, ()> for State {
    fn event(
        state: &mut Self,
        _: &ZwpInputMethodV2,
        event: zwp_input_method_v2::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        state.input_method.apply(event);
    }
}

#[cfg(test)]
mod tests {
    use wayland_protocols::wp::text_input::zv3::client::zwp_text_input_v3::{ContentHint, ContentPurpose};
    use zwp_input_method_v2::Event;

    use super::*;

    fn focused(hint: ContentHint, purpose: ContentPurpose, surrounding: Option<(&str, u32, u32)>) -> InputMethodState {
        let mut state = InputMethodState::default();
        state.apply(Event::Activate);
        state.apply(Event::ContentType {
            hint: WEnum::Value(hint),
            purpose: WEnum::Value(purpose),
        });
        if let Some((text, cursor, anchor)) = surrounding {
            state.apply(Event::SurroundingText {
                text: text.to_owned(),
                cursor,
                anchor,
            });
        }
        state.apply(Event::Done);
        state
    }

    #[test]
    fn nothing_is_known_without_a_focused_field() {
        let state = InputMethodState::default();
        assert!(!state.is_active());
        assert_eq!(state.target(), InsertionTarget::default());
    }

    #[test]
    fn password_and_pin_fields_are_secure() {
        for purpose in [ContentPurpose::Password, ContentPurpose::Pin] {
            assert!(focused(ContentHint::None, purpose, None).target().is_secure);
        }
        let hidden = focused(ContentHint::HiddenText, ContentPurpose::Normal, None);
        assert!(hidden.target().is_secure);
        assert!(
            !focused(ContentHint::None, ContentPurpose::Normal, None)
                .target()
                .is_secure
        );
    }

    #[test]
    fn sensitive_fields_take_text_but_keep_none() {
        let target = focused(ContentHint::SensitiveData, ContentPurpose::Normal, None).target();
        assert!(!target.is_secure);
        assert!(target.is_private);
    }

    #[test]
    fn fields_take_line_breaks_unless_certainly_single_line() {
        let lines = |hint, purpose| focused(hint, purpose, None).target().allows_line_breaks;
        assert!(
            lines(ContentHint::None, ContentPurpose::Normal),
            "GTK's text views say nothing"
        );
        assert!(lines(ContentHint::Multiline, ContentPurpose::Normal));
        assert!(lines(ContentHint::None, ContentPurpose::Alpha));
        assert!(
            !lines(ContentHint::Multiline, ContentPurpose::Terminal),
            "a line break runs the command"
        );
        for single_value in [
            ContentPurpose::Email,
            ContentPurpose::Url,
            ContentPurpose::Number,
            ContentPurpose::Date,
        ] {
            assert!(!lines(ContentHint::None, single_value), "{single_value:?}");
        }
        assert!(
            lines(ContentHint::Multiline, ContentPurpose::Name),
            "unless it says otherwise"
        );
        assert!(
            !InputMethodState::default().target().allows_line_breaks,
            "a field without an input method, which could be a terminal, stays on one line"
        );
    }

    #[test]
    fn the_character_before_the_cursor_or_selection_comes_from_the_surrounding_text() {
        let after_word = focused(ContentHint::None, ContentPurpose::Normal, Some(("Hello world", 5, 5)));
        assert_eq!(after_word.target().preceding, Some('o'));
        let selection = focused(ContentHint::None, ContentPurpose::Normal, Some(("Hello world", 11, 6)));
        assert_eq!(selection.target().preceding, Some(' '), "the selection is replaced");
        let start = focused(ContentHint::None, ContentPurpose::Normal, Some(("Hello", 0, 0)));
        assert_eq!(start.target().preceding, None);
        let sinhala = focused(ContentHint::None, ContentPurpose::Normal, Some(("අම්මා", 15, 15)));
        assert_eq!(sinhala.target().preceding, Some('ා'));
        let inside_a_character = focused(ContentHint::None, ContentPurpose::Normal, Some(("අ", 1, 1)));
        assert_eq!(inside_a_character.target().preceding, None);
        let silent = focused(ContentHint::None, ContentPurpose::Normal, None);
        assert_eq!(silent.target().preceding, None);
    }

    #[test]
    fn state_changes_at_done_and_a_new_field_starts_afresh() {
        let mut state = focused(ContentHint::None, ContentPurpose::Password, Some(("secret", 6, 6)));
        assert_eq!(state.serial, 1);
        state.apply(Event::Deactivate);
        assert!(state.is_active(), "not until done");
        state.apply(Event::Done);
        assert!(!state.is_active());

        state.apply(Event::Activate);
        state.apply(Event::Done);
        assert!(state.is_active());
        assert_eq!(state.serial, 3);
        assert!(
            !state.target().is_secure,
            "the password field's type doesn't carry over"
        );
        assert_eq!(state.target().preceding, None);
    }

    #[test]
    fn the_surrounding_text_lasts_one_state_and_the_type_stays() {
        let mut state = focused(ContentHint::SensitiveData, ContentPurpose::Normal, Some(("Hi", 2, 2)));
        state.apply(Event::Done);
        assert_eq!(state.target().preceding, None, "the app sent no text this time");
        assert!(state.target().is_private);
    }

    #[test]
    fn another_input_method_holding_the_seat_leaves_nothing_active() {
        let mut state = focused(ContentHint::None, ContentPurpose::Normal, None);
        state.apply(Event::Unavailable);
        assert!(!state.is_active());
        assert_eq!(state.target(), InsertionTarget::default());
    }

    #[test]
    fn long_text_goes_in_pieces_split_between_characters() {
        assert_eq!(pieces("", 4).count(), 0);
        assert_eq!(pieces("abcdefghij", 4).collect::<Vec<_>>(), ["abcd", "efgh", "ij"]);
        let sinhala = "අම්මා";
        let split: Vec<_> = pieces(sinhala, 7).collect();
        assert_eq!(split, ["අම", "්ම", "ා"]);
        assert_eq!(split.concat(), sinhala);
        assert_eq!(pieces("😀", 2).collect::<Vec<_>>(), ["😀"], "a character never splits");
        let long = "word ".repeat(2_000);
        assert!(pieces(&long, MAX_PIECE_BYTES).all(|piece| piece.len() <= MAX_PIECE_BYTES));
        assert_eq!(pieces(&long, MAX_PIECE_BYTES).collect::<String>(), long);
    }
}
