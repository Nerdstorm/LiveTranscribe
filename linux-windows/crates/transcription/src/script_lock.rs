//! What Qwen3-ASR may write once it's told a language, as ScriptLock.swift and
//! WritingScript.swift decide it on the Mac: the language's letters ([`WritingScript`]), Latin
//! letters for words in English (as the Sinhala fine-tune writes them), and the digits,
//! punctuation and spaces every language shares.
//!
//! Telling Qwen3-ASR a language only stands in for its own guess at it, so a language spoken
//! clearly still came out in its own letters (LiveTranscribe-0415). Locked, a model told English
//! can't write Sinhala or Chinese, whatever it hears. It can still write German, which has the
//! same letters.
//!
//! The model writes UTF-8 a token at a time, and a token can hold part of a character, so the
//! lock reads a token's bytes after whatever character the tokens before it left unfinished
//! ([`PartialCharacter`]).

use std::ops::RangeInclusive;

use serde::{Deserialize, Serialize};

/// The letters a language is written in, by its ISO 15924 code, as the catalog's language
/// choices name them (`"script": "Sinh"`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize)]
pub enum WritingScript {
    #[serde(rename = "Latn")]
    Latin,
    #[serde(rename = "Cyrl")]
    Cyrillic,
    #[serde(rename = "Grek")]
    Greek,
    #[serde(rename = "Arab")]
    Arabic,
    #[serde(rename = "Deva")]
    Devanagari,
    #[serde(rename = "Sinh")]
    Sinhala,
    #[serde(rename = "Thai")]
    Thai,
    /// Chinese characters, for Chinese and Cantonese.
    #[serde(rename = "Hani")]
    Han,
    /// Chinese characters, hiragana and katakana.
    #[serde(rename = "Jpan")]
    Japanese,
    /// Hangul.
    #[serde(rename = "Kore")]
    Korean,
}

/// CJK symbols and punctuation (。、「」), and the full-width forms (，！？).
const CJK_PUNCTUATION: [RangeInclusive<u32>; 2] = [0x3000..=0x303F, 0xFF00..=0xFFEF];
/// The radicals, the unified ideographs and their extensions, and the compatibility ideographs.
const HAN_CHARACTERS: [RangeInclusive<u32>; 5] = [
    0x2E80..=0x2FDF,
    0x3400..=0x4DBF,
    0x4E00..=0x9FFF,
    0xF900..=0xFAFF,
    0x20000..=0x2FA1F,
];

impl WritingScript {
    /// Its letters and its own punctuation, as Unicode blocks.
    fn blocks(self) -> Vec<RangeInclusive<u32>> {
        match self {
            // Latin-1's letters, Extended-A and -B, the modifier letters (the ʻokina) and Extended
            // Additional (Vietnamese).
            Self::Latin => vec![0x00C0..=0x024F, 0x02B0..=0x02FF, 0x1E00..=0x1EFF],
            Self::Cyrillic => vec![RangeInclusive::new(0x0400, 0x052F)],
            Self::Greek => vec![0x0370..=0x03FF, 0x1F00..=0x1FFF],
            Self::Arabic => vec![
                0x0600..=0x06FF,
                0x0750..=0x077F,
                0x08A0..=0x08FF,
                0xFB50..=0xFDFF,
                0xFE70..=0xFEFF,
            ],
            Self::Devanagari => vec![0x0900..=0x097F, 0xA8E0..=0xA8FF],
            Self::Sinhala => vec![RangeInclusive::new(0x0D80, 0x0DFF)],
            Self::Thai => vec![RangeInclusive::new(0x0E00, 0x0E7F)],
            Self::Han => [CJK_PUNCTUATION.as_slice(), &HAN_CHARACTERS].concat(),
            Self::Japanese => [
                CJK_PUNCTUATION.as_slice(),
                &HAN_CHARACTERS,
                &[0x3040..=0x30FF, 0x31F0..=0x31FF],
            ]
            .concat(),
            Self::Korean => [
                CJK_PUNCTUATION.as_slice(),
                &[0x1100..=0x11FF, 0x3130..=0x318F, 0xAC00..=0xD7AF],
            ]
            .concat(),
        }
    }
}

/// What every language may write: ASCII; Latin-1's symbols and punctuation (« » ¿ ° × ÷); the
/// combining diacritics; general punctuation (– — “ ” …, and the zero-width joiners Sinhala's
/// conjuncts are written with); currency; letterlike symbols and number forms (℃ ½).
const SHARED: [RangeInclusive<u32>; 8] = [
    0x0000..=0x007F,
    0x00A0..=0x00BF,
    0x00D7..=0x00D7,
    0x00F7..=0x00F7,
    0x0300..=0x036F,
    0x2000..=0x206F,
    0x20A0..=0x20CF,
    0x2100..=0x218F,
];

/// What a told language lets Qwen3-ASR write.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ScriptLock {
    script: WritingScript,
    /// The code points it allows, in order and apart.
    allowed: Vec<RangeInclusive<u32>>,
}

impl ScriptLock {
    pub fn new(script: WritingScript) -> Self {
        let mut ranges = SHARED.to_vec();
        if script != WritingScript::Latin {
            ranges.extend(WritingScript::Latin.blocks());
        }
        ranges.extend(script.blocks());
        ranges.sort_by_key(|range| *range.start());
        let mut allowed: Vec<RangeInclusive<u32>> = Vec::new();
        for range in ranges {
            match allowed.last_mut() {
                Some(last) if *range.start() <= last.end() + 1 => {
                    *last = *last.start()..=(*last.end()).max(*range.end());
                }
                _ => allowed.push(range),
            }
        }
        Self { script, allowed }
    }

    pub fn script(&self) -> WritingScript {
        self.script
    }

    pub fn allows(&self, scalar: u32) -> bool {
        self.allows_any(scalar, scalar)
    }

    /// Whether it allows any code point from `low` through `high`.
    pub fn allows_any(&self, low: u32, high: u32) -> bool {
        self.allowed
            .iter()
            .any(|range| *range.start() <= high && low <= *range.end())
    }

    /// The character left unfinished once `bytes` follow `partial`, the one the tokens before
    /// them left unfinished: [`PartialCharacter::NOTHING`] if they end on a whole character.
    /// `None` if they write a character the lock doesn't allow, begin one no allowed character
    /// begins with, or aren't UTF-8.
    pub fn partial_after(&self, partial: PartialCharacter, bytes: &[u8]) -> Option<PartialCharacter> {
        let mut partial = partial;
        for &byte in bytes {
            let next = partial.appending(byte)?;
            if next.is_whole() {
                if !self.allows(next.value) {
                    return None;
                }
                partial = PartialCharacter::NOTHING;
            } else {
                if !self.allows_any(next.lowest(), next.highest()) {
                    return None;
                }
                partial = next;
            }
        }
        Some(partial)
    }
}

/// A character whose first UTF-8 bytes are written and whose last aren't yet.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PartialCharacter {
    /// How many bytes the character takes, which its first byte says.
    length: u32,
    /// How many of them are written.
    count: u32,
    /// The bits of the code point the written bytes hold.
    value: u32,
}

impl PartialCharacter {
    /// No character is unfinished.
    pub const NOTHING: Self = Self {
        length: 0,
        count: 0,
        value: 0,
    };

    /// Its bytes are all written, or none is unfinished.
    pub fn is_whole(self) -> bool {
        self.count == self.length
    }

    /// The lowest code point the character can still turn out to be, leaving out the overlong
    /// encodings, which write a code point in more bytes than it takes.
    fn lowest(self) -> u32 {
        let minimum = [0, 0, 0x80, 0x800, 0x1_0000][self.length as usize];
        (self.value << (6 * (self.length - self.count))).max(minimum)
    }

    /// The highest code point the character can still turn out to be.
    fn highest(self) -> u32 {
        let missing = 6 * (self.length - self.count);
        (self.value << missing) | ((1 << missing) - 1)
    }

    /// The character with `byte` written next, or the one `byte` begins once this one is whole;
    /// `None` if UTF-8 can't have `byte` next.
    fn appending(self, byte: u8) -> Option<Self> {
        if !self.is_whole() {
            if byte & 0xC0 != 0x80 {
                return None;
            }
            return Some(Self {
                count: self.count + 1,
                value: (self.value << 6) | u32::from(byte & 0x3F),
                ..self
            });
        }
        let (length, value) = match byte {
            0x00..=0x7F => (1, u32::from(byte)),
            0xC2..=0xDF => (2, u32::from(byte & 0x1F)),
            0xE0..=0xEF => (3, u32::from(byte & 0x0F)),
            0xF0..=0xF4 => (4, u32::from(byte & 0x07)),
            _ => return None,
        };
        Some(Self {
            length,
            count: 1,
            value,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(text: &str, script: WritingScript) -> Option<PartialCharacter> {
        ScriptLock::new(script).partial_after(PartialCharacter::NOTHING, text.as_bytes())
    }

    #[test]
    fn english_writes_latin_letters_digits_and_punctuation() {
        let whole = Some(PartialCharacter::NOTHING);
        assert_eq!(
            read(
                "Send the café’s report — 10% off, “naïve” résumé.\n- Item 2",
                WritingScript::Latin
            ),
            whole
        );
        assert_eq!(read("Việt Nam, Łódź, ʻŌlelo", WritingScript::Latin), whole);
        assert_eq!(read("ක", WritingScript::Latin), None);
        assert_eq!(read("我们", WritingScript::Latin), None);
        assert_eq!(read("。", WritingScript::Latin), None, "CJK punctuation is CJK's");
        assert_eq!(read("Привет", WritingScript::Latin), None);
    }

    /// The Sinhala fine-tune writes English words in English letters, and every lock but Latin's
    /// allows them.
    #[test]
    fn other_languages_write_their_letters_and_english_words() {
        let whole = Some(PartialCharacter::NOTHING);
        assert_eq!(read("මම Zoom meeting එකට යනවා.", WritingScript::Sinhala), whole);
        assert_eq!(
            read("ප්‍රශ්නය", WritingScript::Sinhala),
            whole,
            "with its conjuncts' joiner"
        );
        assert_eq!(read("我们", WritingScript::Sinhala), None);
        assert_eq!(read("我们开会。Hello", WritingScript::Han), whole);
        assert_eq!(read("ひらがなとカタカナと漢字", WritingScript::Japanese), whole);
        assert_eq!(read("한국어", WritingScript::Korean), whole);
        assert_eq!(read("한국어", WritingScript::Japanese), None);
    }

    /// "ක" is E0 B6 9A, and a token can end after its first bytes.
    #[test]
    fn a_character_split_across_tokens_is_read_across_them() {
        let sinhala = ScriptLock::new(WritingScript::Sinhala);
        let english = ScriptLock::new(WritingScript::Latin);
        let started = sinhala.partial_after(PartialCharacter::NOTHING, &[0xE0, 0xB6]).unwrap();
        assert!(!started.is_whole());
        assert_eq!(sinhala.partial_after(started, &[0x9A]), Some(PartialCharacter::NOTHING));
        assert_eq!(
            sinhala.partial_after(started, &[0x61]),
            None,
            "it must be finished first"
        );
        // Told English, the first byte already can't begin anything it allows.
        assert_eq!(english.partial_after(PartialCharacter::NOTHING, &[0xE0]), None);
        // "—" (U+2014, E2 80 94) is allowed, so its first byte is.
        assert!(english.partial_after(PartialCharacter::NOTHING, &[0xE2]).is_some());
    }

    #[test]
    fn bytes_that_arent_utf8_are_refused() {
        let english = ScriptLock::new(WritingScript::Latin);
        for bytes in [&[0x80][..], &[0xC0, 0x80], &[0xFF]] {
            assert_eq!(
                english.partial_after(PartialCharacter::NOTHING, bytes),
                None,
                "{bytes:x?}"
            );
        }
    }

    #[test]
    fn scripts_are_read_by_their_iso_15924_codes() {
        assert_eq!(
            serde_json::from_str::<WritingScript>(r#""Sinh""#).unwrap(),
            WritingScript::Sinhala
        );
        assert!(serde_json::from_str::<WritingScript>(r#""Sinhala""#).is_err());
    }
}
