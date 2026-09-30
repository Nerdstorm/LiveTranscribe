//! Dictated text as keystrokes. Each character is typed as a Unicode keystroke, the way Windows
//! types a character no key on the keyboard makes (SendInput's KEYEVENTF_UNICODE), so any script
//! goes in whatever the keyboard layout: Sinhala and its joiners, and emoji, which are two UTF-16
//! units each. The text goes in pieces, so the app keeps up, and so a change of focus between
//! pieces stops the typing before the rest lands somewhere else.

use unicode_segmentation::UnicodeSegmentation;

/// Letters (grapheme clusters, as a reader counts them) in a piece: a few words, which even a
/// busy app takes in during the pause before the next.
pub(crate) const PIECE_LETTERS: usize = 32;

/// The text as it is typed into a field. A line break is a Return (`\r`, which is what the Enter
/// key types) where the field takes several lines, and a space where it may not: there, Return
/// could send a message or submit a form. A tab is likewise a tab or a space. Other control
/// characters are left out: typed, they act as keys do (backspace, escape), rather than being
/// text.
pub(crate) fn typeable(text: &str, multiline: bool) -> String {
    let mut typed = String::with_capacity(text.len());
    let mut characters = text.chars().peekable();
    while let Some(character) = characters.next() {
        let breaks_line = matches!(character, '\r' | '\n' | '\u{0085}' | '\u{2028}' | '\u{2029}');
        if breaks_line || character == '\t' {
            if character == '\r' && characters.peek() == Some(&'\n') {
                characters.next();
            }
            match (multiline, breaks_line) {
                (true, true) => typed.push('\r'),
                (true, false) => typed.push('\t'),
                // One space where the text had a break or a tab, and none at the start.
                (false, _) if typed.is_empty() || typed.ends_with(' ') => {}
                (false, _) => typed.push(' '),
            }
        } else if !character.is_control() {
            typed.push(character);
        }
    }
    typed
}

/// Part of the text: its UTF-16 units, each typed as a key press and release, and how many
/// characters they are.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Piece {
    pub(crate) units: Vec<u16>,
    pub(crate) characters: usize,
}

/// The text in pieces of at most `letters` letters. A letter as Unicode counts them is never split
/// between pieces, so a consonant with its vowel sign, or an emoji with its skin tone or family,
/// goes in whole.
pub(crate) fn pieces(text: &str, letters: usize) -> Vec<Piece> {
    let mut pieces = Vec::new();
    let mut piece = Piece::default();
    let mut in_piece = 0;
    for letter in text.graphemes(true) {
        if in_piece == letters.max(1) {
            pieces.push(std::mem::take(&mut piece));
            in_piece = 0;
        }
        piece.units.extend(letter.encode_utf16());
        piece.characters += letter.chars().count();
        in_piece += 1;
    }
    if in_piece > 0 {
        pieces.push(piece);
    }
    pieces
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_field_on_one_line_gets_spaces_for_line_breaks_and_tabs() {
        assert_eq!(typeable("Kind regards,\nSam", false), "Kind regards, Sam");
        assert_eq!(typeable("One\r\n\r\nTwo\tthree", false), "One Two three");
        assert_eq!(typeable("\nStarts on a new line", false), "Starts on a new line");
        assert_eq!(typeable("Ends with a space \n", false), "Ends with a space ");
        assert_eq!(typeable("Line\u{2028}separator", false), "Line separator");
    }

    #[test]
    fn a_field_on_several_lines_gets_returns() {
        assert_eq!(typeable("Kind regards,\nSam", true), "Kind regards,\rSam");
        assert_eq!(typeable("One\r\n\r\nTwo\tthree", true), "One\r\rTwo\tthree");
        assert_eq!(typeable("Old Mac\rbreak", true), "Old Mac\rbreak");
    }

    #[test]
    fn control_characters_are_left_out() {
        assert_eq!(typeable("a\u{8}b\u{1b}c\u{7f}d\u{0}", false), "abcd");
    }

    #[test]
    fn joiners_and_emoji_are_kept_as_they_are() {
        // Sinhala "ශ්‍රී", with its zero-width joiner, and a family emoji.
        let text = "ශ්\u{200d}රී 👩\u{200d}👩\u{200d}👧";
        assert_eq!(typeable(text, false), text);
    }

    #[test]
    fn pieces_hold_whole_letters_as_utf16() {
        let pieces = pieces("abcde", 2);
        let units: Vec<Vec<u16>> = pieces.iter().map(|piece| piece.units.clone()).collect();
        assert_eq!(units, [vec![97, 98], vec![99, 100], vec![101]]);
        assert_eq!(pieces.iter().map(|piece| piece.characters).sum::<usize>(), 5);
    }

    #[test]
    fn a_letter_of_several_characters_is_never_split() {
        // "රී", a consonant and its vowel sign; a family emoji, joined; and an emoji of two UTF-16
        // units.
        let pieces = pieces("රී👩\u{200d}👧😀", 1);
        assert_eq!(pieces.len(), 3);
        assert_eq!(pieces[0].characters, 2);
        assert_eq!(pieces[0].units, [0x0DBB, 0x0DD3]);
        assert_eq!(pieces[1].characters, 3);
        assert_eq!(pieces[2].units, [0xD83D, 0xDE00]);
        assert_eq!(pieces[2].characters, 1);
    }

    #[test]
    fn no_text_is_no_pieces() {
        assert!(pieces("", PIECE_LETTERS).is_empty());
    }
}
