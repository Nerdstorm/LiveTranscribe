use std::ops::Range;

use lt_shared::phrase_grammar::{self, is_word_in};
use lt_shared::swift_string::{self as s};
use lt_shared::{PhraseMatch, PhraseMatcher, Replacement, Role, TokenizedText, token_edges};

/// Common top-level domains, generic and country codes.
pub const COMMON_TOP_LEVEL_DOMAINS: &[&str] = &[
    "com",
    "org",
    "net",
    "edu",
    "gov",
    "mil",
    "int",
    "io",
    "ai",
    "co",
    "dev",
    "app",
    "me",
    "info",
    "biz",
    "xyz",
    "tech",
    "online",
    "site",
    "store",
    "shop",
    "cloud",
    "blog",
    "news",
    "design",
    "page",
    "ly",
    "tv",
    "fm",
    "gg",
    "so",
    "sh",
    "to",
    "us",
    "uk",
    "ca",
    "au",
    "nz",
    "in",
    "lk",
    "de",
    "fr",
    "es",
    "it",
    "nl",
    "se",
    "no",
    "dk",
    "fi",
    "ie",
    "ch",
    "at",
    "be",
    "pl",
    "pt",
    "jp",
    "cn",
    "kr",
    "sg",
    "hk",
    "my",
    "id",
    "ph",
    "th",
    "vn",
    "br",
    "mx",
    "ar",
    "cl",
    "za",
    "ng",
    "ke",
    "ae",
    "sa",
    "il",
    "tr",
    "ru",
    "ua",
    "eu",
    "asia",
    "email",
    "live",
    "art",
    "studio",
    "agency",
    "team",
    "works",
    "world",
    "life",
    "today",
    "space",
    "website",
    "tools",
    "software",
    "systems",
    "solutions",
    "digital",
    "network",
    "media",
    "social",
    "inc",
];

/// Words that make a plain name before "at" an email name: "email john at …", "it's to support
/// at …".
const EMAIL_CUES: &[&str] = &[
    "email", "e-mail", "emails", "emailing", "emailed", "mail", "mailing", "is", "was", "to", "at", "contact", "reach",
    "cc", "bcc", "from", "address",
];
/// Plain names that are never email names: "contact us at example.com".
const PRONOUNS: &[&str] = &[
    "me", "us", "you", "him", "her", "them", "it", "we", "i", "they", "she", "he", "one", "everyone", "someone",
    "anyone",
];
/// Domains of mail providers, before which a plain name is an email name: "alex at gmail dot com".
const MAIL_PROVIDERS: &[&str] = &[
    "gmail.com",
    "googlemail.com",
    "outlook.com",
    "hotmail.com",
    "live.com",
    "msn.com",
    "icloud.com",
    "me.com",
    "mac.com",
    "yahoo.com",
    "proton.me",
    "protonmail.com",
    "fastmail.com",
    "hey.com",
];
/// Words before "at" that are never an email name, even before a mail provider: verbs that take
/// "at", with the forms of "be" ("look at gmail.com", "she works at outlook.com", "it is at
/// icloud.com"), and the words that end such a verb ("sign up at gmail.com", "log in at …").
const NOT_EMAIL_NAMES: &[&str] = &[
    "look", "looks", "looked", "looking", "stare", "stares", "stared", "staring", "glance", "glances", "glanced",
    "glancing", "point", "points", "pointed", "pointing", "aim", "aims", "aimed", "aiming", "laugh", "laughs",
    "laughed", "laughing", "smile", "smiles", "smiled", "smiling", "wave", "waves", "waved", "waving", "shout",
    "shouts", "shouted", "shouting", "yell", "yells", "yelled", "yelling", "arrive", "arrives", "arrived", "arriving",
    "work", "works", "worked", "working", "meet", "meets", "met", "meeting", "stay", "stays", "stayed", "staying",
    "live", "lives", "lived", "living", "shop", "shops", "shopped", "shopping", "study", "studies", "studied",
    "studying", "start", "starts", "started", "starting", "is", "was", "are", "were", "be", "been", "being", "am",
    "up", "in", "on", "out", "off", "back", "down", "over", "here", "there", "now", "only", "just", "even", "also",
    "still", "right",
];
/// A spoken domain never starts with these: "the dot com bubble" is not the.com.
const NOT_DOMAIN_STARTS: &[&str] = &[
    "the", "a", "an", "and", "or", "but", "of", "in", "on", "at", "to", "for", "with", "is", "was", "are", "were",
    "be", "this", "that", "it", "its", "said", "says", "say",
];
/// Spoken separators inside an email name.
const NAME_SEPARATORS: [(&str, &str); 4] = [("dot", "."), ("underscore", "_"), ("dash", "-"), ("hyphen", "-")];

/// Email and web addresses said aloud, however speech-to-text wrote the dots: "john dot smith at
/// example dot com" or "john.smith at example.com" → "john.smith@example.com", "example dot com
/// slash pricing" → "example.com/pricing", "w w w dot example dot org" → "www.example.org".
///
/// A domain must end in a known top-level domain ("com", "org", "io", …), so "dot" in ordinary
/// speech stays a word. "at" makes an email only when the name before it looks like one: it has a
/// dot, underscore, hyphen or digit ("john.smith"), follows a word such as "email", "to" or "is"
/// ("email support at example.com"), or comes before a mail provider's domain ("alex at gmail dot
/// com"). "look at example.com" and "contact us at example.com" keep their "at", and so do a
/// pronoun, a verb that takes "at" or a word after a determiner before a mail provider ("look at
/// gmail.com", "she works at outlook.com", "my account at gmail.com"). A domain speech-to-text
/// already wrote as one word is left as it is unless it gains a name before it or a path after it;
/// an email address it already wrote ("John.Smith@example.com") is taken whole.
///
/// The address goes behind a placeholder, lowercased except for its path, so the model cannot
/// capitalise or split it.
#[derive(Clone, Copy, Debug, Default)]
pub struct AddressCommand;

impl PhraseMatcher for AddressCommand {
    fn matches(&self, text: &TokenizedText) -> Vec<PhraseMatch> {
        let tokens: Vec<AddressToken> = (0..text.tokens().len())
            .map(|index| AddressToken::new(text.token(index)))
            .collect();
        let words_of_token = word_ranges(text);
        let mut found = Vec::new();
        let mut index = 0;
        while index < tokens.len() {
            if let Some(email) = written_email(&tokens[index])
                && let Some(words) = words_of_token[index].clone()
            {
                found.push(address_match(words, email, &tokens[index], &tokens[index]));
                index += 1;
                continue;
            }
            let Some(domain) = domain(index, &tokens) else {
                index += 1;
                continue;
            };
            let (start, address) = if let Some((start, name)) = email_name(index, &domain.host, &tokens) {
                (start, format!("{name}@{}", domain.host))
            } else if domain.spoken || !domain.path.is_empty() {
                (index, format!("{}{}", domain.host, domain.path))
            } else {
                index = domain.end + 1;
                continue;
            };
            if let (Some(first), Some(last)) = (&words_of_token[start], &words_of_token[domain.end]) {
                found.push(address_match(
                    first.start..last.end,
                    address,
                    &tokens[start],
                    &tokens[domain.end],
                ));
            }
            index = domain.end + 1;
        }
        found
    }
}

fn address_match(words: Range<usize>, address: String, first: &AddressToken, last: &AddressToken) -> PhraseMatch {
    PhraseMatch {
        kept_leading: first.leading.to_owned(),
        kept_trailing: last.trailing.to_owned(),
        ..PhraseMatch::new(
            words,
            Replacement::Placeholder {
                trigger: address.clone(),
                expansion: address,
                role: Role::Content,
            },
        )
    }
}

// MARK: - Domains

struct Domain {
    /// Lowercased labels joined with dots.
    host: String,
    /// "/pricing/2026", as spoken; empty without one.
    path: String,
    /// Index of the last token.
    end: usize,
    /// Said with "dot" or spelled "w w w", rather than written by speech-to-text.
    spoken: bool,
}

fn domain(start: usize, tokens: &[AddressToken]) -> Option<Domain> {
    let mut labels: Vec<String> = Vec::new();
    let mut path = String::new();
    let mut spoken = false;
    let mut index = start;
    loop {
        let token = &tokens[index];
        if index > start && !token.leading.is_empty() {
            return None;
        }
        if token.is("w")
            && index + 2 < tokens.len()
            && tokens[index + 1].is("w")
            && tokens[index + 2].is("w")
            && token.trailing.is_empty()
            && tokens[index + 1].is_bare()
            && tokens[index + 2].leading.is_empty()
        {
            labels.push("www".to_owned());
            spoken = true;
            index += 2;
        } else {
            let parts = s::split_on(&token.core, "/", 1, false);
            let host_labels = s::split_on(parts[0], ".", usize::MAX, false);
            if !host_labels.iter().all(|label| is_label(label)) {
                return None;
            }
            labels.extend(host_labels.iter().map(|label| (*label).to_owned()));
            if let Some(&segment) = parts.get(1) {
                if !is_path(segment) {
                    return None;
                }
                path = format!("/{segment}");
                break;
            }
        }
        if !(index + 2 < tokens.len()
            && tokens[index].trailing.is_empty()
            && tokens[index + 1].is("dot")
            && tokens[index + 1].is_bare()
            && tokens[index + 2].leading.is_empty()
            && is_label(&tokens[index + 2].core))
        {
            break;
        }
        spoken = true;
        index += 2;
    }
    let top_level = labels.last()?;
    if labels.len() < 2 || !is_word_in(top_level, COMMON_TOP_LEVEL_DOMAINS) {
        return None;
    }
    if spoken && is_word_in(&labels[0], NOT_DOMAIN_STARTS) {
        return None;
    }

    let mut end = index;
    while tokens[end].trailing.is_empty() {
        let mut slash = end + 1;
        if slash < tokens.len() && tokens[slash].is("forward") && tokens[slash].is_bare() {
            slash += 1;
        }
        if !(slash + 1 < tokens.len()
            && tokens[slash].is("slash")
            && tokens[slash].is_bare()
            && tokens[slash + 1].leading.is_empty()
            && is_path(tokens[slash + 1].original_core))
        {
            break;
        }
        path.push('/');
        path.push_str(tokens[slash + 1].original_core);
        end = slash + 1;
    }
    Some(Domain {
        host: labels.join("."),
        path,
        end,
        spoken,
    })
}

// MARK: - Email names

/// An email address speech-to-text already wrote as one word, lowercased:
/// "John.Smith@example.com" → "john.smith@example.com". The model would otherwise capitalise the
/// name in it.
fn written_email(token: &AddressToken) -> Option<String> {
    let parts = s::split_on(&token.core, "@", usize::MAX, false);
    if parts.len() != 2 || !is_email_name(parts[0]) {
        return None;
    }
    let labels = s::split_on(parts[1], ".", usize::MAX, false);
    let top_level = labels.last()?;
    if labels.len() < 2
        || !labels.iter().all(|label| is_label(label))
        || !is_word_in(top_level, COMMON_TOP_LEVEL_DOMAINS)
    {
        return None;
    }
    Some(token.core.clone())
}

/// The email name before "at" and the domain `host` at `domain_start`, and the index of its first
/// token.
fn email_name(domain_start: usize, host: &str, tokens: &[AddressToken]) -> Option<(usize, String)> {
    let at = domain_start.checked_sub(1).filter(|&at| at >= 1)?;
    if !(tokens[at].is("at") && tokens[at].is_bare()) {
        return None;
    }
    let mut index = at - 1;
    if !(tokens[index].trailing.is_empty() && is_email_name(&tokens[index].core)) {
        return None;
    }
    let mut parts = vec![tokens[index].core.as_str()];
    while index >= 2
        && tokens[index].leading.is_empty()
        && let Some(separator) = name_separator(&tokens[index - 1].core)
        && tokens[index - 1].is_bare()
        && tokens[index - 2].trailing.is_empty()
        && is_email_name(&tokens[index - 2].core)
    {
        parts.splice(0..0, [tokens[index - 2].core.as_str(), separator]);
        index -= 2;
    }
    let name = parts.concat();
    let looks_like_an_address = s::any_character(&name, |c| s::is_one_of(c, &[".", "-", "_", "+"]) || s::is_number(c));
    if !looks_like_an_address {
        let word_before =
            (index >= 1 && tokens[index - 1].trailing.is_empty()).then(|| tokens[index - 1].core.as_str());
        let cued = word_before.is_some_and(|word| is_word_in(word, EMAIL_CUES));
        if is_word_in(&name, PRONOUNS) || !(cued || names_a_mailbox(&name, host, word_before)) {
            return None;
        }
    }
    Some((index, name))
}

/// Whether `name`, a plain word said before "at" and `host`, is a mailbox there: `host` is a mail
/// provider's, and `name` is no verb that takes "at" ("look at gmail.com") nor a word after a
/// determiner ("my account at gmail.com"). `word_before` is the word before `name` in the same
/// clause, if any.
fn names_a_mailbox(name: &str, host: &str, word_before: Option<&str>) -> bool {
    is_word_in(host, MAIL_PROVIDERS)
        && !is_word_in(name, NOT_EMAIL_NAMES)
        && !word_before.is_some_and(|word| is_word_in(word, &phrase_grammar::DETERMINERS))
}

fn name_separator(word: &str) -> Option<&'static str> {
    NAME_SEPARATORS
        .iter()
        .find(|(spoken, _)| s::canonically_equal(spoken, word))
        .map(|&(_, written)| written)
}

// MARK: - Characters

fn is_ascii_letter_or_digit(character: &str) -> bool {
    s::is_ascii(character) && (s::is_letter(character) || s::is_number(character))
}

fn is_label(label: &str) -> bool {
    let (Some(first), Some(last)) = (s::first_character(label), s::last_character(label)) else {
        return false;
    };
    if s::canonically_equal(first, "-") || s::canonically_equal(last, "-") {
        return false;
    }
    s::characters(label).all(|c| is_ascii_letter_or_digit(c) || s::canonically_equal(c, "-"))
}

fn is_email_name(name: &str) -> bool {
    if name.is_empty() || s::canonically_equal(name, "at") || s::canonically_equal(name, "dot") {
        return false;
    }
    s::characters(name).all(|c| is_ascii_letter_or_digit(c) || s::is_one_of(c, &[".", "-", "_", "+", "%"]))
}

fn is_path(segment: &str) -> bool {
    !segment.is_empty()
        && s::characters(segment).all(|c| is_ascii_letter_or_digit(c) || s::is_one_of(c, &["-", ".", "_", "~", "/"]))
}

/// Each token's word indices; `None` for a token without words.
fn word_ranges(text: &TokenizedText) -> Vec<Option<Range<usize>>> {
    let mut ranges: Vec<Option<Range<usize>>> = vec![None; text.tokens().len()];
    for (index, word) in text.words().iter().enumerate() {
        let lower = ranges[word.token].as_ref().map_or(index, |range| range.start);
        ranges[word.token] = Some(lower..index + 1);
    }
    ranges
}

/// A token split into its punctuation and the characters between.
struct AddressToken<'t> {
    leading: &'t str,
    /// Between the leading and trailing punctuation, lowercased.
    core: String,
    /// The same characters as they were written, for a path.
    original_core: &'t str,
    trailing: &'t str,
}

impl<'t> AddressToken<'t> {
    fn new(token: &'t str) -> Self {
        let leading = token_edges::leading(token);
        let trailing = token_edges::trailing(token);
        let original_core = s::drop_last(
            s::drop_first(token, s::character_count(leading)),
            s::character_count(trailing),
        );
        Self {
            leading,
            core: s::lowercased(original_core),
            original_core,
            trailing,
        }
    }

    /// No punctuation on either side.
    fn is_bare(&self) -> bool {
        self.leading.is_empty() && self.trailing.is_empty()
    }

    fn is(&self, word: &str) -> bool {
        s::canonically_equal(&self.core, word)
    }
}

#[cfg(test)]
mod tests {
    use lt_shared::PhraseProtector;

    use super::*;

    fn expanded(spoken: &str) -> String {
        PhraseProtector::new(vec![Box::new(AddressCommand)])
            .protect(spoken)
            .expanded()
    }

    #[test]
    fn a_plain_name_before_a_mail_provider_is_an_email_name() {
        for (spoken, expected) in [
            ("alex at gmail dot com", "alex@gmail.com"),
            ("Sam at Outlook.com.", "sam@outlook.com."),
            ("Hi, alex at icloud dot com is best.", "Hi, alex@icloud.com is best."),
            ("write to me or sam at proton dot me", "write to me or sam@proton.me"),
            (
                "alex at yahoo.com or sam at hey dot com",
                "alex@yahoo.com or sam@hey.com",
            ),
        ] {
            assert_eq!(expanded(spoken), expected, "{spoken}");
        }
    }

    #[test]
    fn keeps_at_before_a_mail_provider_after_a_pronoun_a_verb_that_takes_it_or_a_determiner() {
        for (spoken, expected) in [
            ("look at gmail.com", "look at gmail.com"),
            ("look at gmail dot com", "look at gmail.com"),
            ("she works at outlook dot com", "she works at outlook.com"),
            ("I signed up at gmail.com", "I signed up at gmail.com"),
            ("the app is at icloud.com", "the app is at icloud.com"),
            ("my account at gmail dot com is full", "my account at gmail.com is full"),
            ("find us at hotmail.com", "find us at hotmail.com"),
            ("alex at example.com", "alex at example.com"),
        ] {
            assert_eq!(expanded(spoken), expected, "{spoken}");
        }
    }
}
