"""Scores a cleanup answer by its meaning and the punctuation English requires, not by a house style.

The headline, ``meaning``, holds when an answer has

- the target's words, names and numbers, so a correction is resolved the same way (``words``);
- the capitals English requires: a sentence's first word, names, "I" and acronyms (``capitals``);
- its sentence ends: no two sentences run together or joined by a comma, and no full stop, colon
  or semicolon in the middle of a phrase (``sentence_ends``);
- its question marks, and none anywhere else (``question_marks``);
- its lines, the list a dictation lays out and the colon before it, and a full stop or question
  mark where a line ends a sentence (``layout``, ``line_ends``).

Punctuation a writer may choose either way counts neither way: a comma before "and" or "but", a
comma after an opening phrase, a dash, colon or full stop between two sentences that could stand
apart, how a greeting or sign-off is punctuated, a full stop after a list item, a capital after a
colon or starting a list item.

Commas English requires, between list items and either side of a name being addressed, are
reported as ``required_commas``, outside the headline: telling them from optional commas takes a
guess about the sentence. ``exact_text`` is reported too.

usage: cleanup_scoring.py <measure-report.json>... [--by-category] [--output <file.json>]
"""

import argparse
from dataclasses import dataclass
import difflib
import json
from pathlib import Path
import re
import unicodedata

MARKER = re.compile(r"^\s*(?:[-•*]|(\d{1,2})[.)])\s+")
PLACEHOLDER = re.compile(r"⟦[^⟧]+⟧|[STU]\d+")
DOTTED = re.compile(r"(?:[A-Za-z]\.){2,}")
TITLES = {"dr", "mr", "mrs", "ms", "mx", "prof", "st", "mt", "jr", "sr", "vs"}
OPENING = "\"'([{¿¡"
CLOSING = ".,;:!?…\"')]}"
MARKS = set(".,;:!?…\"'()[]{}—–-")
# Stands for a placeholder (an emoji, a link) between two words: it may end a sentence.
HOLD = "\u0000"
NONE, WEAK, STRONG, END = range(4)

SUBJECTS = {
    "i", "we", "you", "he", "she", "it", "they", "i'm", "i'll", "i've", "i'd", "we're", "we'll",
    "we've", "we'd", "you're", "you'll", "you've", "you'd", "he's", "he'll", "she's", "she'll",
    "it's", "it'll", "they're", "they'll", "they've", "there", "there's", "that's", "let's",
}
SUBORDINATORS = {
    "when", "if", "after", "before", "because", "since", "once", "while", "although", "though",
    "unless", "until", "whenever", "whereas",
}
CLAUSE_WORDS = SUBJECTS | SUBORDINATORS | {
    "and", "or", "but", "so", "yet", "nor", "then", "next", "finally", "lastly", "first", "second",
    "third", "fourth", "fifth", "also", "please", "thanks", "thank", "which", "who", "whose",
    "where", "that", "otherwise", "however", "plus", "except", "including", "like", "especially",
    "not", "just", "even", "actually", "anyway", "sorry", "no", "yes", "okay", "ok", "well", "oh",
    "too", "instead", "as",
}
# Openers that put a phrase, not a list item, before the first comma.
OPENERS = SUBORDINATORS | {"to", "in", "on", "at", "by", "for", "with", "during", "from", "as"}
GREETINGS = {"hi", "hello", "hey", "dear", "morning", "afternoon", "evening", "thanks", "thank", "cheers"}
# Capitalised openers that are not names.
NOT_NAMES = GREETINGS | CLAUSE_WORDS | {
    "yesterday", "today", "tomorrow", "tonight", "now", "sure", "right", "great", "cool", "perfect",
    "fine", "alright", "again", "still", "besides", "meanwhile", "overall", "um", "uh", "look",
    "listen", "anyway", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    "sunday", "january", "february", "march", "april", "may", "june", "july", "august",
    "september", "october", "november", "december", "one", "two", "three", "four", "five", "six",
    "seven", "eight", "nine", "ten",
}
HEADLINE = ("words", "capitals", "sentence_ends", "question_marks", "line_ends", "layout")
COMPONENTS = ("meaning",) + HEADLINE + ("required_commas", "exact_text")


@dataclass
class Word:
    text: str
    before: str = ""
    placeholder: bool = False


@dataclass
class Line:
    marker: str | None
    words: list
    end: str


@dataclass
class Token:
    """A word that isn't a placeholder, with the punctuation after it: up to the next such word in
    its line, or to the line's end."""

    text: str
    line: int
    after: str = ""
    last: bool = False
    start: bool = False
    loose: bool = False


@dataclass
class Reading:
    lines: list
    tokens: list
    words: list
    layout: list
    endings: list


def normalized(text):
    text = unicodedata.normalize("NFC", text.replace("\r\n", "\n")).strip()
    return text.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')


def split_chunk(chunk):
    """The marks before the word in ``chunk``, the word and the punctuation after it; no word when
    the chunk is only marks. A dotted abbreviation keeps its full stop ("p.m."), a plural possessive
    its apostrophe, and a title's full stop is no punctuation ("Dr." is "Dr")."""
    if all(char in MARKS for char in chunk):
        return "", "", chunk
    lead = 0
    while lead < len(chunk) and chunk[lead] in OPENING:
        lead += 1
    end = len(chunk)
    while end > lead and chunk[end - 1] in CLOSING:
        end -= 1
    core, trailing = chunk[lead:end], chunk[end:]
    if not core:
        return "", "", chunk
    if trailing.startswith(".") and DOTTED.fullmatch(core + "."):
        core, trailing = core + ".", trailing[1:]
    elif trailing.startswith(".") and core.lower() in TITLES:
        trailing = trailing[1:]
    if trailing.startswith("'") and core.endswith("s") and not chunk[:lead].endswith("'"):
        core, trailing = core + "'", trailing[1:]
    return chunk[:lead], core, trailing


def pieces(chunk):
    """The parts of a chunk read as words of their own: a dash or an ellipsis inside it ("six—no")
    stands between two words."""
    return [piece for piece in re.split(r"(—|…|\.{3,})", chunk) if piece]


def _take(chunk, words, pending):
    """Adds the word in ``chunk`` to ``words`` and returns the punctuation after it."""
    opening, core, trailing = split_chunk(chunk)
    if not core:
        return pending + " " + chunk
    words.append(Word(core, pending + " " + opening, bool(PLACEHOLDER.fullmatch(core))))
    return trailing


def parse(text):
    lines = []
    for raw_line in normalized(text).split("\n"):
        match = MARKER.match(raw_line)
        marker = (match.group(1) or "-") if match else None
        words, pending = [], ""
        for chunk in raw_line[match.end() if match else 0:].split():
            for piece in pieces(chunk):
                pending = _take(piece, words, pending)
        if words:
            lines.append(Line(marker, words, pending))
    return lines


def gap_kind(gap):
    gap = gap.replace("...", "…")
    if any(mark in gap for mark in ".?!"):
        return END
    if any(mark in gap for mark in ";:—–-…") or HOLD in gap:
        return STRONG
    if any(mark in gap for mark in ",()[]"):
        return WEAK
    return NONE


def _ending(gap):
    gap = gap.replace("...", "…")
    if "?" in gap:
        return "?"
    if ":" in gap:
        return ":"
    if any(mark in gap for mark in ".!…") or HOLD in gap:
        return "."
    if "," in gap:
        return ","
    return ";" if ";" in gap else ""


def read(text):
    lines = parse(text)
    tokens, endings = [], []
    for number, line in enumerate(lines):
        first, gap = len(tokens), ""
        for word in line.words:
            if word.placeholder:
                gap += word.before + HOLD
                continue
            if len(tokens) > first:
                tokens[-1].after = gap + word.before
            tokens.append(Token(word.text, number))
            gap = ""
        if len(tokens) == first:
            endings.append(".")
            continue
        tokens[-1].after, tokens[-1].last = gap + line.end, True
        for index in range(first, len(tokens)):
            token = tokens[index]
            # A dotted abbreviation's own full stop may end its sentence ("at 9 p.m. Then …").
            if DOTTED.fullmatch(token.text) and (token.last or tokens[index + 1].text[:1].isupper()):
                token.after = "." + token.after
            if index == first:
                token.start, token.loose = line.marker is None, line.marker is not None
            else:
                before = tokens[index - 1].after
                token.start = gap_kind(before) == END
                token.loose = not token.start and (":" in before or HOLD in before)
        endings.append(_ending(tokens[-1].after))
    words = [part for line in lines for word in line.words for part in word.text.lower().split("-") if part]
    layout = [(line.marker, sum(len([p for p in w.text.split("-") if p]) for w in line.words)) for line in lines]
    return Reading(lines, tokens, words, layout, endings)


def _names(tokens):
    """Words the target capitalises where no sentence starts."""
    return {token.text.lower() for token in tokens if token.text[:1].isupper() and not token.start and not token.loose}


def _case_ok(want, got, names):
    if want.text == got.text:
        return not (got.start and want.text[:1].isalpha() and want.text.islower())
    if want.text.lower() != got.text.lower() or want.text[1:] != got.text[1:]:
        return False
    if (want.text.lower() in names or want.text == "I" or want.text.startswith("I'")
            or (len(want.text) > 1 and want.text.isupper())):
        return False
    if got.start:
        return got.text[:1].isupper()
    return want.start or want.loose or got.loose


def sentence(tokens, index):
    """The first and last token of the sentence holding ``tokens[index]``."""
    first = index
    while first > 0 and tokens[first - 1].line == tokens[index].line and not tokens[first].start:
        first -= 1
    last = index
    while not tokens[last].last and gap_kind(tokens[last].after) != END:
        last += 1
    return first, last


def _is_name(token):
    word = token.text
    return (word[:1].isupper() and word.replace("'", "").isalpha() and word.lower() not in NOT_NAMES
            and word.lower() not in SUBJECTS and not word.lower().endswith("ly"))


def required_commas(tokens):
    """The target's commas a reader needs, by the token they follow: ``series`` between list
    items, ``before`` an addressed name ending its sentence, ``after`` one opening it."""
    required = {}
    for index, token in enumerate(tokens):
        if token.last or "," not in token.after or gap_kind(token.after) != WEAK:
            continue
        first, last = sentence(tokens, index)
        following = tokens[index + 1:last + 1]
        if 1 <= len(following) <= 2 and all(_is_name(word) for word in following):
            required[index] = "before"
            continue
        opening = [word.text.lower() for word in tokens[first:index + 1]]
        named = tokens[first:index + 1]
        if opening and opening[0] in GREETINGS:
            named = named[2:] if opening[:2] == ["thank", "you"] else named[1:]
            if 1 <= len(named) <= 2 and all(_is_name(word) for word in named):
                required[index] = "after"
                continue
        elif len(named) == 1 and _is_name(named[0]) and last > index:
            required[index] = "after"
            continue
        if _series(tokens, index, first, last):
            required[index] = "series"
    return required


def _series(tokens, index, first, last):
    if tokens[index + 1].text.lower() in CLAUSE_WORDS:
        return False
    if not any("," in tokens[k].after for k in range(first, index)) and tokens[first].text.lower() in OPENERS:
        return False
    length = 0
    for position in range(index + 1, last + 1):
        word = tokens[position].text.lower()
        if word in SUBJECTS:
            return False
        if word in ("and", "or") and position > index + 1:
            return True
        length = 0 if "," in tokens[position].after else length + 1
        if length > 6:
            return False
    return False


def aligned(want, got):
    matcher = difflib.SequenceMatcher(None, [t.text.lower() for t in want], [t.text.lower() for t in got], autojunk=False)
    return [(block.a + k, block.b + k) for block in matcher.get_matching_blocks() for k in range(block.size)]


def _line_ends(want, got):
    if len(want.lines) != len(got.lines):
        return False
    several = len(want.lines) > 1
    for line, size, expected, ending in zip(want.lines, (n for _, n in want.layout), want.endings, got.endings):
        if "?" in (expected, ending) or ":" in (expected, ending):
            right = expected == ending
        elif line.marker is not None:
            right = True
        elif expected == ".":
            # A short line in a letter, like a greeting or a sign-off, may end with a comma.
            right = ending == "." or (ending == "," and several and size <= 4)
        elif expected == ",":
            right = ending in (",", ".", "")
        else:
            right = ending in ("", ".", ",", ";")
        if not right:
            return False
    return True


def compare(shown, target):
    """Each component for one answer against one target."""
    got, want = read(shown), read(target)
    pairs = aligned(want.tokens, got.tokens)
    position = dict(pairs)
    names = _names(want.tokens)
    required = required_commas(want.tokens)
    capitals = sentence_ends = commas = True
    questions = sum("?" in t.after for t in want.tokens) == sum("?" in t.after for t in got.tokens)
    for i, j in pairs:
        expected, answer = want.tokens[i], got.tokens[j]
        capitals = capitals and _case_ok(expected, answer, names)
        if expected.last and answer.last:
            questions = questions and ("?" in expected.after) == ("?" in answer.after)
        if expected.last or answer.last or position.get(i + 1) != j + 1:
            continue
        questions = questions and ("?" in expected.after) == ("?" in answer.after)
        wanted, given = gap_kind(expected.after), gap_kind(answer.after)
        if wanted == END and given < STRONG:
            # Two sentences run together, or joined by a comma.
            sentence_ends = False
        if wanted == NONE and (given == END or any(mark in answer.after for mark in ":;")):
            # A full stop, colon or semicolon in the middle of a phrase.
            sentence_ends = False
        if given == END and (required.get(i) in ("series", "before")
                             or (wanted == WEAK and got.tokens[sentence(got.tokens, j)[0]].text.lower() in SUBORDINATORS)):
            # A full stop splitting a list, cutting off an addressed name, or after a clause like
            # "When you get home".
            sentence_ends = False
        if i in required and given == NONE:
            commas = False
    result = {
        "words": got.words == want.words,
        "capitals": capitals,
        "sentence_ends": sentence_ends,
        "question_marks": questions,
        "line_ends": _line_ends(want, got),
        "layout": got.layout == want.layout,
        "required_commas": commas,
        "exact_text": normalized(shown) == normalized(target),
    }
    return {"meaning": all(result[name] for name in HEADLINE), **result}


def score_case(shown, target, alternatives=()):
    """The best comparison of ``shown`` with the target or any of its alternatives."""
    results = [compare(shown, expected) for expected in [target, *alternatives] if expected]
    return max(results, key=lambda result: (result["meaning"], sum(result.values())))


def score_report(report):
    """Scores every result of a ``Train measure`` report."""
    return [{"id": case["id"], "category": case["category"],
             **score_case(case["shown"], case["target"], case.get("alternatives", ()))}
            for case in report["results"]]


def counts(rows):
    return {"total": len(rows), **{name: sum(row[name] for row in rows) for name in COMPONENTS}}


def summarize(scored):
    return {"overall": counts(scored),
            "categories": {name: counts([row for row in scored if row["category"] == name])
                           for name in sorted({row["category"] for row in scored})}}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--by-category", action="store_true")
    parser.add_argument("--output", type=Path)
    options = parser.parse_args()
    summary = {}
    for path in options.reports:
        scored = score_report(json.loads(path.read_text()))
        summary[str(path)] = {**summarize(scored), "results": scored}
        overall = summary[str(path)]["overall"]
        print(f"{path.name}: " + "  ".join(f"{name} {overall[name]}/{overall['total']}" if name == "meaning"
                                           else f"{name} {overall[name]}" for name in COMPONENTS))
        if options.by_category:
            for name, row in summary[str(path)]["categories"].items():
                print(f"    {name:20s} meaning {row['meaning']}/{row['total']}")
    if options.output:
        options.output.write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
