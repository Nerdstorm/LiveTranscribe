use lt_shared::PhraseMatcher;
use lt_shared::phrase_grammar::CLAUSE_ENDERS;
use lt_shared::sentence_case::capitalizing_first_word;
use lt_shared::swift_string::{self as s, CharacterSet};

use crate::{AddressCommand, EmojiCommand, LineBreakCommand, PunctuationCommand};

/// The commands for one dictation, in priority order for matches that tie.
///
/// `multiline` says the field takes several lines. Elsewhere a spoken line break becomes a space,
/// since a newline could send a chat message or submit a form.
pub fn matchers(multiline: bool) -> Vec<Box<dyn PhraseMatcher>> {
    vec![
        Box::new(EmojiCommand::default()),
        Box::new(AddressCommand),
        Box::new(PunctuationCommand::default()),
        Box::new(LineBreakCommand::new(multiline)),
    ]
}

/// Tidies text whose line-break placeholders were just put back.
///
/// The model sees a break as a token between words, so it punctuates around it as it likes: "Hi
/// John ⟦S1⟧, thanks." Here the space around each break goes, punctuation the model put just after
/// a break moves back to the end of the line before it, the first word after a break is
/// capitalised, runs of spaces become one, and there is never more than one blank line in a row.
pub fn tidy_line_breaks(text: &str) -> String {
    let single_spaced = collapsing_runs(text, |scalar| scalar == ' ' || scalar == '\t', 2, " ");
    let mut lines: Vec<String> = single_spaced
        .split('\n')
        .map(|line| s::trimming(line, CharacterSet::Whitespaces).to_owned())
        .collect();
    for index in 1..lines.len() {
        let mut line = std::mem::take(&mut lines[index]);
        let punctuation = s::prefix_while(&line, |c| {
            s::is_one_of(c, &CLAUSE_ENDERS) || s::canonically_equal(c, " ")
        });
        if !punctuation.is_empty() {
            let moved: String = s::characters(punctuation)
                .filter(|c| !s::canonically_equal(c, " "))
                .collect();
            line = line[punctuation.len()..].to_owned();
            if let Some(previous) = lines[..index].iter().rposition(|line| !line.is_empty())
                && s::last_character(&lines[previous]).is_some_and(|end| !s::is_one_of(end, &CLAUSE_ENDERS))
            {
                lines[previous].push_str(&moved);
            }
        }
        lines[index] = capitalizing_first_word(&line);
    }
    collapsing_runs(&lines.join("\n"), |scalar| scalar == '\n', 3, "\n\n")
}

/// `text` with each run of at least `minimum` scalars that pass `is_member` replaced by
/// `replacement`, as the regular expressions `[ \t]{2,}` and `\n{3,}` replace them.
fn collapsing_runs(text: &str, is_member: impl Fn(char) -> bool, minimum: usize, replacement: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut run = String::new();
    let flush = |result: &mut String, run: &mut String| {
        result.push_str(if run.chars().count() >= minimum {
            replacement
        } else {
            run
        });
        run.clear();
    };
    for scalar in text.chars() {
        if is_member(scalar) {
            run.push(scalar);
        } else {
            flush(&mut result, &mut run);
            result.push(scalar);
        }
    }
    flush(&mut result, &mut run);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tidies_around_line_breaks() {
        assert_eq!(
            tidy_line_breaks("Hi John \n, thanks.  See you\n\n\n\nbye"),
            "Hi John,\nThanks. See you\n\nBye"
        );
        assert_eq!(tidy_line_breaks("Done.\n. next"), "Done.\nNext");
    }
}
