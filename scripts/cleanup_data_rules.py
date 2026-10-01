"""Conservative, auditable reconciliation of synthetic dictation and speech output."""

from dataclasses import dataclass
from decimal import Decimal
import difflib
import re


TOKEN = re.compile(
    r"⟦[^⟧]+⟧|\b[STU]\d+\b|https?://[^\s]+|www\.[^\s]+|"
    r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|\bv\d+(?:\.\d+)+\b|\d{4}-\d{2}-\d{2}|"
    r"\d{1,2}:\d{2}(?::\d{2})?|[+-]?\d+(?:,\d{3})*(?:\.\d+)?(?:st|nd|rd|th)?|"
    r"(?:[A-Za-z]\.){2,}|[^\W\d_]+(?:['’][^\W\d_]+)*", re.UNICODE
)
SMALL = dict(zip("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split(), range(20)))
TENS = dict(zip("twenty thirty forty fifty sixty seventy eighty ninety".split(), range(20, 100, 10)))
ORDINALS = dict(zip("first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth twentieth".split(), range(1, 21)))
SCALES = {"hundred": 100, "thousand": 1000, "million": 1000000}
CONTRACTIONS = {
    "i'm": "i am", "you're": "you are", "we're": "we are", "they're": "they are",
    "it's": "it is", "that's": "that is", "there's": "there is", "here's": "here is",
    "isn't": "is not", "aren't": "are not", "wasn't": "was not", "weren't": "were not",
    "don't": "do not", "doesn't": "does not", "didn't": "did not", "can't": "can not",
    "cannot": "can not", "won't": "will not", "haven't": "have not", "hasn't": "has not",
    "hadn't": "had not", "i'll": "i will", "we'll": "we will", "you'll": "you will",
    "they'll": "they will", "i've": "i have", "we've": "we have", "you've": "you have",
    "they've": "they have", "shouldn't": "should not", "couldn't": "could not",
}
AMBIGUOUS_NAME_WORDS = set("you your yours me my mine we our us they their them he him his she her it its beyond to too no not yes and or actually sorry said called may will can do go macs merge".split())


def word(text):
    return text.lower().replace("’", "'").replace(".", "")


def number_value(words):
    if len(words) == 1:
        token = words[0]
        if re.fullmatch(r"\d{1,2}:\d{2}", token):
            hour, minute = map(int, token.split(":"))
            if hour < 24 and minute < 60:
                return f"clock:{hour}:{minute:02d}"
        if re.fullmatch(r"[+-]?\d+(?:,\d{3})*(?:\.\d+)?(?:st|nd|rd|th)?", token):
            ordinal = re.search(r"(st|nd|rd|th)$", token)
            digits = (token[:ordinal.start()] if ordinal else token).replace(",", "")
            unsigned = digits.lstrip("+-")
            if len(unsigned) > 1 and unsigned.startswith("0") and not unsigned.startswith("0."):
                return "literal:" + token
            value = Decimal(digits)
            exact = format(value, "f")
            if "." in exact:
                exact = exact.rstrip("0").rstrip(".")
            return ("ordinal:" if ordinal else "number:") + exact
    # Spoken clock forms are distinct from quantities: two thirty is 2:30, not 32.
    if len(words) >= 2 and 0 < SMALL.get(words[0], 0) <= 12:
        if len(words) == 3 and words[1] == "oh" and words[2] in SMALL:
            return f"clock:{SMALL[words[0]]}:{SMALL[words[2]]:02d}"
        tail = number_value(words[1:])
        if tail and tail.startswith("number:"):
            minutes = Decimal(tail.split(":", 1)[1])
            if minutes == int(minutes) and 10 <= minutes <= 59:
                return f"clock:{SMALL[words[0]]}:{int(minutes):02d}"
    total = current = 0
    last = "none"
    for index, token in enumerate(words):
        if token == "and" and last in ("hundred", "scale") and index + 1 < len(words):
            continue
        if token in SMALL and last in ("none", "tens", "hundred", "scale"):
            current += SMALL[token]
            last = "unit" if SMALL[token] < 10 else "teen"
        elif token in TENS and last in ("none", "hundred", "scale"):
            current += TENS[token]
            last = "tens"
        elif token in ORDINALS and index == len(words) - 1 and (
            last in ("none", "hundred", "scale") or last == "tens" and ORDINALS[token] < 10
        ):
            return f"ordinal:{total + current + ORDINALS[token]}"
        elif token == "hundred" and last in ("none", "unit"):
            current = max(current, 1) * 100
            last = "hundred"
        elif token in ("thousand", "million") and last != "scale":
            total += max(current, 1) * SCALES[token]
            current, last = 0, "scale"
        else:
            return None
    return f"number:{total + current}" if words else None


@dataclass(frozen=True)
class Unit:
    key: str
    text: str
    start: int
    end: int
    kind: str = "word"


def units(text, policy):
    tokens = list(TOKEN.finditer(text))
    spellings = {word(variant): word(group[0]) for group in policy.get("spelling_variants", []) for variant in group}
    expanded = {tuple(value.split()): value for value in CONTRACTIONS.values()}
    output, index = [], 0
    while index < len(tokens):
        token = tokens[index]
        value = word(token.group())
        key, end, kind = spellings.get(value, value), index + 1, "word"
        if (token.group().startswith(("⟦", "https://", "http://", "www.")) or "@" in token.group()
                or re.fullmatch(r"[STU]\d+|v\d+(?:\.\d+)+|\d{4}-\d{2}-\d{2}", token.group())):
            key, kind = "literal:" + token.group(), "literal"
        elif value in CONTRACTIONS:
            key, kind = CONTRACTIONS[value], "contraction"
        elif tuple(word(t.group()) for t in tokens[index:index + 2]) in expanded:
            key = expanded[tuple(word(t.group()) for t in tokens[index:index + 2])]
            end, kind = index + 2, "contraction"
        else:
            for length in range(min(8, len(tokens) - index), 0, -1):
                chunk = [t.group().lower() for t in tokens[index:index + length]]
                # A punctuation boundary cannot turn two separate numbers into one quantity.
                gaps = [text[tokens[j].end():tokens[j + 1].start()] for j in range(index, index + length - 1)]
                if any(gap.strip() not in ("", "-") for gap in gaps):
                    continue
                number = number_value(chunk)
                if number is not None:
                    key, end, kind = number, index + length, "number"
                    break
        stop = tokens[end - 1].end()
        output.append(Unit(key, text[token.start():stop], token.start(), stop, kind))
        index = end
    # With an explicit am/pm marker, two and 2:00 denote the same clock value.
    for index, unit in enumerate(output[:-1]):
        if unit.key.startswith("number:") and output[index + 1].key in ("am", "pm"):
            value = Decimal(unit.key.split(":", 1)[1])
            if value == int(value) and 1 <= value <= 12:
                output[index] = Unit(f"clock:{int(value)}:00", unit.text, unit.start, unit.end, "number")
    return output


def canonical(text, policy):
    return [unit.key for unit in units(text, policy)]


def contains(sequence, part):
    return bool(part) and any(sequence[i:i + len(part)] == part for i in range(len(sequence) - len(part) + 1))


def reconcile(original, spoken, observed, policy):
    """Return a target, an audit trail and unresolved changes. Never alter the ASR input."""
    before, after = units(spoken, policy), units(observed, policy)
    expected = units(original["target"], policy)
    expected_keys = [unit.key for unit in expected]
    names = {name.lower() for name in policy.get("names", [])}
    changes, unresolved, replacements = [], [], {}
    confusions = [{" ".join(canonical(variant, policy)) for variant in group} for group in policy.get("sound_alikes", [])]

    def remember(old, new, rule, source_index):
        changes.append({"rule": rule, "from": old.text, "to": new.text})
        replacements[source_index] = new.text

    matcher = difflib.SequenceMatcher(a=[u.key for u in before], b=[u.key for u in after], autojunk=False)
    for tag, start, end, next_start, next_end in matcher.get_opcodes():
        left, right = before[start:end], after[next_start:next_end]
        if tag == "equal":
            for offset, (old, new) in enumerate(zip(left, right)):
                if old.text.lower() != new.text.lower() and (
                    old.kind in ("number", "contraction") or old.key in ("am", "pm")
                    or word(old.text) in {word(v) for g in policy.get("spelling_variants", []) for v in g}
                ):
                    remember(old, new, "number-format" if old.kind == "number" or old.key in ("am", "pm") else "spelling-or-contraction", start + offset)
            continue
        old_keys, new_keys = [u.key for u in left], [u.key for u in right]
        if new_keys and contains(expected_keys, new_keys) and not contains(expected_keys, old_keys):
            changes.append({"rule": "planted-error-corrected", "from": " ".join(u.text for u in left), "to": " ".join(u.text for u in right)})
            continue
        if len(left) == 1 and left[0].key in names:
            joined = "".join(u.key for u in right)
            if len(right) > 1 and joined == left[0].key and all(u.text.isalpha() for u in right):
                new = Unit(joined, observed[right[0].start:right[-1].end], right[0].start, right[-1].end)
                remember(left[0], new, "name-spelling", start)
                continue
            new = right[0] if len(right) == 1 else None
            if new is not None and new.text.isalpha() and new.text[0].isupper() and new.key not in names | AMBIGUOUS_NAME_WORDS:
                remember(left[0], new, "name-spelling", start)
                continue
            unresolved.append({"from": left[0].text, "to": " ".join(u.text for u in right)})
            continue
        said, heard = " ".join(old_keys), " ".join(new_keys)
        if any(said in group and heard in group for group in confusions):
            changes.append({"rule": "sound-alike-retain-target", "from": said, "to": heard})
            continue
        if tag == "delete" and set(old_keys) <= {"um", "uh", "erm", "ah", "er", "hmm"} and not contains(expected_keys, old_keys):
            changes.append({"rule": "filler-not-transcribed", "from": said, "to": ""})
            continue
        unresolved.append({"from": " ".join(u.text for u in left), "to": " ".join(u.text for u in right)})

    target = original["target"]
    target_replacements = {}
    alignment = difflib.SequenceMatcher(a=[unit.key for unit in before], b=expected_keys, autojunk=False)
    for block in alignment.get_matching_blocks():
        for offset in range(block.size):
            if block.a + offset in replacements:
                target_replacements[block.b + offset] = replacements[block.a + offset]
    edits = []
    for index, unit in enumerate(expected):
        if index not in target_replacements:
            continue
        # List numbering belongs to the target layout, not the speech model's number style.
        line_prefix = target[target.rfind("\n", 0, unit.start) + 1:unit.start]
        if not line_prefix.strip() and re.match(r"\d+[.)] ", target[unit.start:]):
            continue
        replacement = target_replacements[index]
        if unit.text[:1].isupper():
            replacement = replacement[:1].upper() + replacement[1:]
        stop = unit.end
        if replacement.endswith(".") and target[stop:stop + 1] == ".":
            stop += 1
        edits.append((unit.start, stop, replacement))
    for start, end, replacement in reversed(edits):
        target = target[:start] + replacement + target[end:]
    excluded = (not unresolved and original["category"] in ("recognition", "grammar")
                and canonical(observed, policy) == canonical(target, policy))
    return target, {"rules_version": policy["version"], "changes": changes,
                    "unresolved": unresolved, "source_target": original["target"],
                    "status": "review" if unresolved else "excluded" if excluded else "automatic",
                    "exclude_reason": "planted-error-already-corrected" if excluded else None}
