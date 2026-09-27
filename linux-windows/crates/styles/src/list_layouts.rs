use lt_shared::swift_string::{self as s};

use crate::layout::LayoutRule;
use crate::list_formatter::ListFormatter;
use crate::list_style::ListStyle;

/// Lists spoken with markers ("number one …, number two …", "bullet point … bullet point …"),
/// whose markers `ListMarkerCommand` has already turned into "1. " and "- " at the start of
/// lines: the line before gets its colon, the items their capitals and full stops (see
/// [`ListStyle`]), and any sentence after the last item starts a new paragraph.
#[derive(Clone, Debug, Default)]
pub struct MarkedListLayout {
    style: ListStyle,
}

impl MarkedListLayout {
    pub fn new(style: ListStyle) -> Self {
        Self { style }
    }
}

impl LayoutRule for MarkedListLayout {
    fn arrange(&self, lines: &[String]) -> Option<Vec<String>> {
        let mut result: Vec<String> = Vec::new();
        let mut index = 0;
        let mut changed = false;
        while index < lines.len() {
            let Some(first) = ListStyle::marker(&lines[index]) else {
                result.push(lines[index].clone());
                index += 1;
                continue;
            };
            let mut prefixes = Vec::new();
            let mut texts = Vec::new();
            while index < lines.len()
                && let Some(marker) = ListStyle::marker(&lines[index])
                && marker.is_numbered == first.is_numbered
            {
                texts.push(s::drop_first(&lines[index], s::character_count(&marker.prefix)).to_owned());
                prefixes.push(marker.prefix);
                index += 1;
            }
            if let Some(previous) = result.last_mut()
                && ListStyle::marker(previous).is_none()
                && let Some(lead_in) = self.style.lead_in(previous)
            {
                *previous = lead_in;
            }
            let mut after = None;
            if let Some(last) = texts.last_mut()
                && let Some((sentence, rest)) = ListStyle::split_after_first_sentence(last)
            {
                *last = sentence;
                after = Some(rest);
            }
            result.extend(
                prefixes
                    .iter()
                    .zip(self.style.items(&texts))
                    .map(|(prefix, item)| format!("{prefix}{item}")),
            );
            // What follows the list starts a paragraph, unless it is the next item said inline.
            if let Some(after) = after {
                if ListStyle::marker(&after).is_none() {
                    result.push(String::new());
                }
                result.push(after);
            }
            changed = true;
        }
        changed.then_some(result)
    }
}

/// Lists spoken with ordinals ("first, …; second, …") or cardinals ("one is …, two is …"), found
/// in each line of prose by [`ListFormatter`]. Lines that are already list items are left alone.
#[derive(Clone, Debug, Default)]
pub struct OrdinalListLayout {
    formatter: ListFormatter,
}

impl OrdinalListLayout {
    pub fn new(formatter: ListFormatter) -> Self {
        Self { formatter }
    }
}

impl LayoutRule for OrdinalListLayout {
    fn arrange(&self, lines: &[String]) -> Option<Vec<String>> {
        let mut result = Vec::new();
        let mut changed = false;
        for line in lines {
            if ListStyle::marker(line).is_none()
                && let Some(list) = self.formatter.lines(line)
            {
                result.extend(list);
                changed = true;
            } else {
                result.push(line.clone());
            }
        }
        changed.then_some(result)
    }
}
