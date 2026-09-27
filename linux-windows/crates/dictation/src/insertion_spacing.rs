//! Adds the space a typist would when dictated text lands straight after a word, so dictating
//! "world" after "Hello" gives "Hello world", not "Helloworld". Ported from the Mac app's
//! InsertionSpacing.swift with its tests.

/// Characters after which text follows without a space.
const OPENERS: [char; 14] = ['(', '[', '{', '"', '\'', '“', '‘', '`', '/', '@', '#', '-', '_', '<'];
/// Characters that attach to the text before them.
const CLOSERS: [char; 14] = ['.', ',', ';', ':', '!', '?', ')', ']', '}', '”', '’', '%', '…', '>'];

/// `text` with a leading space when `preceding`, the character before the cursor, is part of a
/// word. Unchanged when the character is unknown (the field doesn't say) or the text is empty.
pub fn adjusted(text: &str, preceding: Option<char>) -> String {
    let (Some(preceding), Some(first)) = (preceding, text.chars().next()) else {
        return text.to_owned();
    };
    if preceding.is_whitespace() || OPENERS.contains(&preceding) {
        return text.to_owned();
    }
    if first.is_whitespace() || CLOSERS.contains(&first) {
        return text.to_owned();
    }
    format!(" {text}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_space_is_added_after_a_word() {
        for (preceding, text, expected) in [
            ('o', "world", " world"),
            ('.', "Next sentence.", " Next sentence."),
            (',', "and then", " and then"),
            ('7', "items", " items"),
        ] {
            assert_eq!(adjusted(text, Some(preceding)), expected);
        }
    }

    #[test]
    fn no_space_where_a_typist_would_not_add_one() {
        for (preceding, text) in [
            (None, "Hello"),
            (Some(' '), "world"),
            (Some('\n'), "New line"),
            (Some('('), "aside"),
            (Some('“'), "quoted"),
            (Some('@'), "mention"),
            (Some('o'), ", and more"),
            (Some('o'), "."),
            (Some('o'), ""),
        ] {
            assert_eq!(adjusted(text, preceding), text);
        }
    }
}
