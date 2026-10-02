"""Conservative, auditable reconciliation of synthetic dictation and speech output."""

from dataclasses import dataclass
from decimal import Decimal
import difflib
import re

import cleanup_scoring


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
ARTICLES = {"a", "an", "the"}
FILLERS = {"um", "uh", "erm", "ah", "er", "hmm"}
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
    # A compound written as one word or two ("frontend", "front end", "Wi-Fi") is one unit.
    spaced = {tuple(spacing.split()): joined for joined, spacing in policy.get("spacing_variants", [])}
    output, index = [], 0
    while index < len(tokens):
        token = tokens[index]
        value = word(token.group())
        key, end, kind, start = spellings.get(value, value), index + 1, "word", token.start()
        compound = next((length for length in (3, 2) if index + length <= len(tokens)
                         and tuple(word(t.group()) for t in tokens[index:index + length]) in spaced
                         and all(text[tokens[j].end():tokens[j + 1].start()].strip() in ("", "-")
                                 for j in range(index, index + length - 1))), None)
        if (token.group().startswith(("⟦", "https://", "http://", "www.")) or "@" in token.group()
                or re.fullmatch(r"[STU]\d+|v\d+(?:\.\d+)+|\d{4}-\d{2}-\d{2}", token.group())):
            key, kind = "literal:" + token.group(), "literal"
        elif compound:
            key = spaced[tuple(word(t.group()) for t in tokens[index:index + compound])]
            end, kind = index + compound, "spacing"
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
            if value in ("dollar", "dollars"):
                key = "unit:dollar"
        stop = tokens[end - 1].end()
        # "$20" is "twenty dollars": the sign joins the number, and the word it stands for follows.
        dollars = kind == "number" and start > 0 and text[start - 1] == "$"
        if dollars:
            start -= 1
        output.append(Unit(key, text[start:stop], start, stop, kind))
        if dollars:
            output.append(Unit("unit:dollar", "", stop, stop, "number"))
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
    name_variants = [{word(name) for name in group} for group in policy.get("name_variants", [])]
    variant_words = {word(v) for g in policy.get("spelling_variants", []) for v in g}
    changes, unresolved, replacements = [], [], {}
    confusions = [{" ".join(canonical(variant, policy)) for variant in group} for group in policy.get("sound_alikes", [])]
    # Which spoken word each target word was, where the target keeps it.
    alignment = difflib.SequenceMatcher(a=[unit.key for unit in before], b=expected_keys, autojunk=False)
    kept = {block.a + offset: block.b + offset for block in alignment.get_matching_blocks() for offset in range(block.size)}
    unplaced = {unit.key for index, unit in enumerate(expected) if index not in kept.values()}

    def outside_target(start, end, old_keys):
        """Whether the target keeps none of the words changed: they were taken back, a cue or garbled."""
        if set(old_keys) & unplaced:
            return False
        if end > start:
            return not any(index in kept for index in range(start, end))
        # Words added between two words the target keeps next to each other land inside it.
        previous, following = kept.get(start - 1), kept.get(start)
        if start == 0 or start == len(before):
            return (following if start == 0 else previous) is None
        return previous is None or following is None or following != previous + 1

    def remember(old, new, rule, source_index):
        changes.append({"rule": rule, "from": old.text, "to": new.text})
        replacements[source_index] = new.text

    matcher = difflib.SequenceMatcher(a=[u.key for u in before], b=[u.key for u in after], autojunk=False)
    for tag, start, end, next_start, next_end in matcher.get_opcodes():
        left, right = before[start:end], after[next_start:next_end]
        if tag == "equal":
            for offset, (old, new) in enumerate(zip(left, right)):
                if old.text.lower() == new.text.lower():
                    continue
                if old.kind == "number" or new.kind == "number" or old.key in ("am", "pm"):
                    remember(old, new, "number-format", start + offset)
                elif "spacing" in (old.kind, new.kind):
                    remember(old, new, "word-spacing", start + offset)
                elif old.kind == "contraction" or word(old.text) in variant_words:
                    remember(old, new, "spelling-or-contraction", start + offset)
            continue
        old_keys, new_keys = [u.key for u in left], [u.key for u in right]
        # A "$" speech-to-text wrote before a number said without a currency, which the number's
        # recognized form already brings into the target ("twelve thousand" → "$12,000").
        if tag == "insert" and all(u.key == "unit:dollar" and not u.text for u in right):
            changes.append({"rule": "number-format", "from": "", "to": "$"})
            continue
        if new_keys and contains(expected_keys, new_keys) and not contains(expected_keys, old_keys):
            changes.append({"rule": "planted-error-corrected", "from": " ".join(u.text for u in left), "to": " ".join(u.text for u in right)})
            continue
        single = len(left) == 1 and len(right) == 1
        # One name heard as another spelling of the same sound ("Hana", "Hannah").
        if single and any(left[0].key in group and right[0].key in group for group in name_variants):
            remember(left[0], right[0], "name-spelling", start)
            continue
        # Speech-to-text can't hear which article was said; no cleanup could restore it.
        if single and left[0].key in ARTICLES and right[0].key in ARTICLES:
            remember(left[0], right[0], "article-variant", start)
            continue
        # An apostrophe speech-to-text put in a plural ("the printer's are broken") is a fix the
        # target keeps, when the target has the plural as said; "speaker's" for "speakers'" is not.
        if (single and "'" in right[0].key and left[0].text.isalpha()
                and left[0].key == right[0].key.replace("'", "")
                and re.search(r"\b" + re.escape(left[0].text) + r"\b(?!['’])", original["target"], re.IGNORECASE)):
            changes.append({"rule": "apostrophe-retain-target", "from": left[0].text, "to": right[0].text})
            continue
        # A time written without the "am" or "pm" said; no cleanup could restore it.
        if tag == "delete" and old_keys in (["am"], ["pm"]) and start > 0 and before[start - 1].kind == "number":
            remember(left[0], Unit("", "", left[0].start, left[0].start), "number-format", start)
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
        if tag == "delete" and set(old_keys) <= FILLERS and not contains(expected_keys, old_keys):
            changes.append({"rule": "filler-not-transcribed", "from": said, "to": ""})
            continue
        # Deep's check still decides whether the target fits what was transcribed.
        if outside_target(start, end, old_keys):
            changes.append({"rule": "outside-target", "from": " ".join(u.text for u in left), "to": " ".join(u.text for u in right)})
            continue
        unresolved.append({"from": " ".join(u.text for u in left), "to": " ".join(u.text for u in right)})

    target = original["target"]
    target_replacements = {b: replacements[a] for a, b in kept.items() if a in replacements}
    # A word a correction moved ("Sorry, I mean Gita" → "Gita will …") keeps its recognized form
    # when exactly one spoken word outside the alignment says it.
    for index, unit in enumerate(expected):
        if index in kept.values():
            continue
        forms = {replacements[a] for a, said in enumerate(before) if a in replacements and a not in kept and said.key == unit.key}
        if len(forms) == 1:
            target_replacements[index] = forms.pop()
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
        begin, stop = unit.start, unit.end
        if replacement.endswith(".") and target[stop:stop + 1] == ".":
            stop += 1
        if not replacement and unit.text:
            # A word dropped takes the space before it.
            while begin > 0 and target[begin - 1] == " ":
                begin -= 1
        elif replacement and not unit.text:
            replacement = " " + replacement
        edits.append((begin, stop, replacement))
    for start, end, replacement in reversed(edits):
        target = target[:start] + replacement + target[end:]
    excluded = (not unresolved and original["category"] in ("recognition", "grammar")
                and canonical(observed, policy) == canonical(target, policy))
    return target, {"rules_version": policy["version"], "changes": changes,
                    "unresolved": unresolved, "source_target": original["target"],
                    "status": "review" if unresolved else "excluded" if excluded else "automatic",
                    "exclude_reason": "planted-error-already-corrected" if excluded else None}


@dataclass(frozen=True)
class _Spot:
    """Where a comma after one word of a text goes, for ``carry_optional_commas``."""

    word: str
    # The punctuation after the word in its chunk, when that is all of it; None otherwise.
    tail: str | None
    # Where that punctuation starts in the text.
    at: int
    # Whether the next word of the line starts the next chunk, with nothing before it.
    next_word_follows: bool


def _spots(text):
    """For each word of ``text`` as the scorer reads it, where a comma after it goes."""
    spots, offset = [], 0
    for line in text.split("\n"):
        marker = cleanup_scoring.MARKER.match(line)
        body = marker.end() if marker else 0
        line_spots = []
        for number, chunk in enumerate(re.finditer(r"\S+", line[body:])):
            parts = cleanup_scoring.pieces(chunk.group())
            for part in parts:
                opening, core, trailing = cleanup_scoring.split_chunk(part)
                if not core or cleanup_scoring.PLACEHOLDER.fullmatch(core):
                    continue
                whole = len(parts) == 1
                tail = part[len(opening) + len(core):] if whole else None
                at = offset + body + chunk.start() + len(opening) + len(core)
                line_spots.append((number, whole and not opening, _Spot(core, tail if tail == trailing else None, at, True)))
        for index, (number, _, spot) in enumerate(line_spots):
            if index + 1 < len(line_spots):
                following, clean, _ = line_spots[index + 1]
                spot = _Spot(spot.word, spot.tail, spot.at, following == number + 1 and clean)
            spots.append(spot)
        offset += len(line) + 1
    return spots


# Words that open a sentence and may take a comma after them ("Actually, it works").
INTRODUCTORY = {
    "actually", "however", "yes", "no", "okay", "ok", "well", "so", "anyway", "now", "then",
    "also", "plus", "first", "second", "third", "finally", "lastly", "next", "yesterday", "today",
    "tomorrow", "tonight", "sure", "oh", "right", "alright", "besides", "otherwise", "instead",
    "still", "again", "overall", "meanwhile", "unfortunately", "honestly", "basically",
}
CONJUNCTIONS = {"and", "but", "so", "or", "yet"}


def _optional_comma(tokens, index):
    """Whether a comma after ``tokens[index]`` is one English leaves to the writer: before a
    conjunction ("…green, and Priya…", "eggs, and bread"), or after an opening phrase or word
    ("For the next raid, I'll…", "Actually, it…"). Any other comma is the target's to keep."""
    if tokens[index + 1].text.lower() in CONJUNCTIONS:
        return True
    first, _ = cleanup_scoring.sentence(tokens, index)
    if any("," in token.after for token in tokens[first:index]):
        return False
    opener = tokens[first].text.lower()
    if index == first:
        return opener in INTRODUCTORY or (opener.endswith("ly") and len(opener) > 4)
    return opener in cleanup_scoring.OPENERS and index - first < 10


def carry_optional_commas(target, heard):
    """``target`` with the optional commas of ``heard``, the input it answers.

    Punctuation English requires is the target's: sentence ends, question marks, colons, commas
    between list items and beside an addressed name, and a comma between clauses with no word
    joining them. A comma a writer may leave out follows the input: before "and", "but", "so",
    "or" or "yet", after an opening phrase or word, and after a greeting or sign-off on a line of
    its own. Where both texts have the same two words next to each other there, the target loses
    its comma when the input has none, and gains one where the input has one; an odd full stop or
    colon in the input changes nothing. So an answer keeps the optional punctuation it was given
    and leaves out what it wasn't, whoever wrote the example.
    """
    if cleanup_scoring.normalized(target) != target:
        return target
    want, got = cleanup_scoring.read(target), cleanup_scoring.read(heard)
    spots = _spots(target)
    if [spot.word for spot in spots] != [token.text for token in want.tokens]:
        return target
    required = cleanup_scoring.required_commas(want.tokens)
    position = dict(cleanup_scoring.aligned(want.tokens, got.tokens))
    edits = []
    for index, (token, spot) in enumerate(zip(want.tokens, spots)):
        j = position.get(index)
        if (j is None or index + 1 >= len(want.tokens) or position.get(index + 1) != j + 1
                or index in required or spot.tail not in ("", ",") or not spot.next_word_follows):
            continue
        if token.last:
            # A line a short greeting or sign-off ends, not a list item's.
            line = want.lines[token.line]
            if line.marker is not None or want.layout[token.line][1] > 4:
                continue
        elif (cleanup_scoring.gap_kind(token.after) not in (cleanup_scoring.NONE, cleanup_scoring.WEAK)
              or not _optional_comma(want.tokens, index)):
            continue
        heard_gap = got.tokens[j].after
        kind = cleanup_scoring.gap_kind(heard_gap)
        if kind == cleanup_scoring.NONE and spot.tail == ",":
            edits.append((spot.at, spot.at + 1, ""))
        elif kind == cleanup_scoring.WEAK and "," in heard_gap and spot.tail == "":
            edits.append((spot.at, spot.at, ","))
    for start, end, text in reversed(edits):
        target = target[:start] + text + target[end:]
    return target
