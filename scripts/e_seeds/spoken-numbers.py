#!/usr/bin/env python3
"""Speech seeds for Deep candidate E: spoken numbers kept exactly as said.

Numbers are written as digits by deterministic rules outside the model, so Deep must hand on
every spoken number as it received it: no part dropped or merged ("two point four point one" is
not "two point one"), no value changed, no number word title-cased ("Zero Four Four Six"), and
no words turned into digits. Corrections over a number keep only the correction.

The rows cover versions, digit strings and references (with "oh" for zero in some), decimals,
money, percentages, times, years, counts and dates, several numbers in one dictation, and numbers
in longer dictations that also need capitals and punctuation. Some are lists counted "One, …
Two, …" with numbers inside the items: Deep keeps the markers as said, punctuated so the layout
rules number the list, and keeps the items' numbers as words.

Each sentence template sends all its rows to one split, so the test split holds sentences the
adapter never saw. Compound numbers are hyphenated as Deep's targets write them ("twenty-one",
"nine forty-five"); a raw text said in lower case without punctuation has them spaced, as speech
seeds do. The held-out gate, Training/eval/spoken-numbers.jsonl, is hand-written below with
frames and words no template uses.

Usage: python3 scripts/e_seeds/spoken-numbers.py [--check]
"""

import argparse
import json
import random
import re
import sys
import unicodedata
from pathlib import Path

FAMILY = "spoken-numbers"
SEED = 20261002
ROOT = Path(__file__).resolve().parents[2]
TRAINING = ROOT / "Packages/LiveTranscribeKit/Training"
OUTPUT = TRAINING / "generated-e"
GATE = TRAINING / "eval" / f"{FAMILY}.jsonl"
# Held-out sets no raw text of this family may repeat.
HELD_OUT = [
    *sorted((TRAINING / "eval").glob("*.jsonl")),
    TRAINING / "generated/test.jsonl",
    TRAINING / "prepared/deep-measured/test.jsonl",
    TRAINING / "prepared/deep-measured-d/test.jsonl",
]
ROWS_PER_TEMPLATE = {"train": 11, "valid": 10, "test": 10}

# MARK: - Number words

UNITS = ("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
         "fifteen sixteen seventeen eighteen nineteen").split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
ORDINAL_UNITS = ("_ first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth "
                 "thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth").split()
ORDINAL_TENS = "_ _ twentieth thirtieth".split()


def cardinal(n):
    """``n`` as said in British English, compounds hyphenated: "one hundred and twenty-five"."""
    if n < 20:
        return UNITS[n]
    if n < 100:
        return TENS[n // 10] + ("-" + UNITS[n % 10] if n % 10 else "")
    if n < 1000:
        rest = n % 100
        return UNITS[n // 100] + " hundred" + (" and " + cardinal(rest) if rest else "")
    rest = n % 1000
    head = cardinal(n // 1000) + " thousand"
    if not rest:
        return head
    return head + (" " if rest >= 100 else " and ") + cardinal(rest)


def ordinal(n):
    if n < 20:
        return ORDINAL_UNITS[n]
    if n % 10 == 0:
        return ORDINAL_TENS[n // 10]
    return TENS[n // 10] + "-" + ORDINAL_UNITS[n % 10]


def digit_words(digits, oh=False):
    return " ".join("oh" if oh and d == "0" else UNITS[int(d)] for d in digits)


# MARK: - Values

NAMES = ["Ava", "Omar", "Lena", "Kofi", "Mei", "Ravi", "Sofia", "Tariq", "Ines", "Mateo", "Zara", "Hugo",
         "Nina", "Felix", "Anya", "Bruno", "Clara", "Dev", "Elsa", "Jonah", "Kira", "Luca", "Maren", "Noor"]
WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
          "October", "November", "December"]
CITIES = ["Lisbon", "Oslo", "Denver", "Perth", "Nairobi", "Lyon", "Osaka", "Halifax", "Porto", "Tallinn"]


def v_count(rng):
    n = rng.choice([rng.randint(11, 99), rng.randint(11, 99), rng.randint(2, 9), rng.randint(100, 480)])
    return cardinal(n)


def v_small(rng):
    return cardinal(rng.randint(2, 9))


def v_many(rng):
    """A count of ten or more, so it is always more than a ``small`` part of it."""
    return cardinal(rng.choice([rng.randint(10, 99), rng.randint(10, 99), rng.randint(100, 480)]))


def v_big(rng):
    return cardinal(rng.choice([rng.randint(100, 999), rng.randint(1000, 9999), rng.randint(11, 20) * 1000]))


def v_digits(rng, length, oh_rate=0.0):
    digits = "".join(str(rng.randint(0, 9)) for _ in range(length))
    if rng.random() < 0.35:
        digits = "0" + digits[1:]
    return digit_words(digits, oh=rng.random() < oh_rate)


def v_digits4(rng):
    return v_digits(rng, 4)


def v_digits6(rng):
    return v_digits(rng, 6, oh_rate=0.3)


def v_room(rng):
    return f"{UNITS[rng.randint(1, 9)]} {rng.choice(['oh', 'zero', UNITS[rng.randint(1, 4)]])} {UNITS[rng.randint(1, 9)]}"


def v_phone(rng):
    return "oh four " + digit_words("".join(str(rng.randint(0, 9)) for _ in range(8)), oh=rng.random() < 0.5)


def v_version(rng):
    parts = [rng.randint(1, 12), rng.choice([0, rng.randint(1, 12), rng.randint(1, 12)])]
    if rng.random() < 0.7:
        parts.append(rng.choice([0, rng.randint(1, 9)]))
    return " point ".join(cardinal(p) for p in parts)


def v_decimal(rng):
    whole = rng.choice([0, rng.randint(1, 9), rng.randint(1, 30)])
    fraction = str(rng.randint(1, 9)) if rng.random() < 0.6 else f"{rng.randint(0, 9)}{rng.randint(1, 9)}"
    return f"{cardinal(whole)} point {digit_words(fraction)}"


CURRENCIES = ["dollars", "dollars", "euros", "pounds"]


def v_money(rng, currency):
    kind = rng.random()
    if kind < 0.45:
        return f"{cardinal(rng.randint(2, 999))} {currency}"
    if kind < 0.65:
        return f"{cardinal(rng.randint(1, 60) * 50)} {currency}"
    if kind < 0.8:
        return f"{cardinal(rng.randint(5, 95))} cents"
    if kind < 0.9:
        return f"{cardinal(rng.randint(2, 99))} {currency} and {cardinal(rng.randint(5, 95))} cents"
    return f"{cardinal(rng.randint(2, 40))} {currency} {cardinal(rng.choice([20, 25, 50, 75, 95, 99]))}"


def v_dollars(rng):
    """Whole dollars, for a correction that changes the sum but not the currency. At most six
    words: Deep's check turns down a correction of seven words or more after the sentence."""
    return f"{cardinal(rng.choice([rng.randint(2, 99), rng.randint(100, 999), rng.randint(1, 19) * 100]))} dollars"


def v_amount(rng, currency):
    """A round sum, as budgets are said: "fifty thousand dollars"."""
    return f"{cardinal(rng.randint(2, 95) * 1000)} {currency}"


def v_percent(rng):
    if rng.random() < 0.75:
        return f"{cardinal(rng.randint(2, 99))} percent"
    return f"{cardinal(rng.randint(0, 20))} point {UNITS[rng.randint(1, 9)]} percent"


def v_time(rng):
    hour = rng.randint(1, 12)
    kind = rng.random()
    if kind < 0.45:
        minute = rng.choice([15, 20, 30, 40, 45, 50, 10, 25, 35, 55])
        text = f"{UNITS[hour]} {cardinal(minute)}"
    elif kind < 0.6:
        text = f"{UNITS[hour]} oh {UNITS[rng.randint(1, 9)]}"
    elif kind < 0.8:
        text = f"{rng.choice(['half past', 'quarter past', 'quarter to'])} {UNITS[hour]}"
    else:
        text = UNITS[hour]
    if rng.random() < 0.4 and hour < 12 and not text.startswith(("half", "quarter")):
        text += rng.choice([" am", " pm"])
    return text


def said_year(year):
    if year < 2000:
        return f"nineteen {cardinal(year - 1900)}"
    if year < 2010:
        return "two thousand" + (f" and {UNITS[year - 2000]}" if year > 2000 else "")
    return f"twenty {cardinal(year - 2000)}"


def v_year(rng):
    """A year gone by, for the past tense: "We opened the shop in twenty twelve"."""
    return said_year(rng.choice([rng.randint(1990, 1999), rng.randint(2000, 2009), rng.randint(2010, 2026), rng.randint(2010, 2026)]))


def v_later_year(rng):
    """A year to come, for what runs until then."""
    return said_year(rng.randint(2027, 2035))


DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]


def v_date(rng):
    month = rng.randrange(12)
    return f"the {ordinal(rng.randint(1, DAYS_IN_MONTH[month]))} of {MONTHS[month]}"


NUMBER_KINDS = {
    "count": v_count, "small": v_small, "many": v_many, "big": v_big, "digits4": v_digits4, "digits6": v_digits6,
    "room": v_room, "phone": v_phone, "version": v_version, "decimal": v_decimal, "money": v_money,
    "dollars": v_dollars, "amount": v_amount, "percent": v_percent, "time": v_time, "year": v_year,
    "later_year": v_later_year, "date": v_date,
}
# Kinds said with the row's one currency, so a price list or a corrected sum keeps it.
CURRENCY_KINDS = {"money", "amount"}
WORD_KINDS = {
    "name": lambda rng: rng.choice(NAMES), "weekday": lambda rng: rng.choice(WEEKDAYS),
    "month": lambda rng: rng.choice(MONTHS), "city": lambda rng: rng.choice(CITIES),
}

# Correction cues as a cased transcript writes them: within the sentence, and starting the next.
SAME_CUES = [", I mean", ", sorry,", ", no wait,", ", or rather,", ", no, sorry,", ", make that", " sorry", ", I meant"]
CROSS_CUES = ["Sorry,", "No, sorry,", "I mean,", "Actually, no,", "Sorry, I meant", "Wait, no,", "Make that", "Sorry, no,"]

# MARK: - Templates

# (category, said, written). `{kind}` is a fresh value; `{kind:tag}` repeats the value of the same
# tag, and values of one kind with different tags differ. `{cue}` and `{xcue}` are correction cues.
F, SAME, CROSS = "facts", "same-sentence", "cross-sentence"
TEMPLATES = {
    "train": [
        (F, "We shipped version {version} this morning.", None),
        (F, "Can you check whether version {version} fixes the login bug?", None),
        (F, "{name} is still on version {version:a}, not version {version:b}.", None),
        (F, "Release {version} goes out on {weekday}, so please test it before then.", None),
        (F, "The release notes for version {version} are in the shared folder.", None),
        (F, "Tickets {digits4:a} and {digits4:b} are both closed now.", None),
        (F, "Your order number is {digits4}.", None),
        (F, "Please quote reference {digits6} when you call the help desk.", None),
        (F, "The gate code is {digits4:a}, and the alarm code is {digits4:b}.", None),
        (F, "Call me on {phone} after lunch.", None),
        (F, "My new extension is {digits4}, if anyone asks.", None),
        (F, "Room {room} is booked for {name} all afternoon.", None),
        (F, "The parcel weighs {decimal} kilos.", None),
        (F, "We ran {decimal} kilometres before breakfast.", None),
        (F, "The average response time is {decimal} seconds, which is too slow.", None),
        (F, "The repair came to {money}.", None),
        (F, "Tickets are {money:a} each, or {money:b} for a family.", None),
        (F, "{name} paid {money} for the new kettle.", None),
        (F, "Our budget for the open day is {amount}.", None),
        (F, "Sales went up {percent} last quarter.", None),
        (F, "The battery is at {percent}, so bring the charger.", None),
        (F, "Only {percent} of the survey replies were negative.", None),
        (F, "The train leaves at {time}.", None),
        (F, "Let's meet at {time} outside the library.", None),
        (F, "The doctor can see you at {time} on {weekday}.", None),
        (F, "I set the alarm for {time:a}, not {time:b}.", None),
        (F, "We moved to {city} in {year}.", None),
        (F, "The house was built in {year}, and the roof is original.", None),
        (F, "The contract runs until {later_year}.", None),
        (F, "We need {count} chairs for the hall.", None),
        (F, "There are {count} people on the waiting list.", None),
        (F, "I've got {small} things to sort out before {weekday}.", None),
        (F, "{name} answered {count} emails today.", None),
        (F, "Only {small} of the {many} boxes arrived.", None),
        (F, "Order {digits4} has {count} items and comes to {money}.", None),
        (F, "The meeting is at {time} in room {room}, and it runs for {count} minutes.", None),
        (F, "Version {version} cut the load time by {percent}.", None),
        (F, "We sold {big} tickets in {year}.", None),
        (F, "Invoice {digits4} for {money} is due on {date}.", None),
        (F, "{name} called about ticket {digits4}. It's still open, and the customer wants an update by {time}.", None),
        (F, "I checked the order. It weighs {decimal} kilos, so the postage is {money}.", None),
        (F, "Thanks for the quote. We'll take {count} units at {money} each.", None),
        (F, "I'll take the one for {money}, not the cheaper one.", None),
        (F, "No one has replied about ticket {digits4} yet.", None),
        (SAME, "The budget is {amount:a}{cue} {amount:b}.", "The budget is {amount:b}."),
        (SAME, "Meet me at {time:a}{cue} {time:b} at the front desk.", "Meet me at {time:b} at the front desk."),
        (SAME, "We need {count:a}{cue} {count:b} chairs for the hall.", "We need {count:b} chairs for the hall."),
        (SAME, "Please update to version {version:a}{cue} {version:b}.", "Please update to version {version:b}."),
        (SAME, "The door code is {digits4:a}{cue} {digits4:b}.", "The door code is {digits4:b}."),
        (CROSS, "The parcel to {city} weighs {decimal:a} kilos. {xcue} {decimal:b} kilos.", "The parcel to {city} weighs {decimal:b} kilos."),
        (CROSS, "Sales grew {percent:a} this year. {xcue} {percent:b}.", "Sales grew {percent:b} this year."),
        (CROSS, "We opened the shop in {year:a}. {xcue} in {year:b}.", "We opened the shop in {year:b}."),
        (CROSS, "Your booking reference is {digits6:a}. {xcue} {digits6:b}.", "Your booking reference is {digits6:b}."),
        (CROSS, "The rent is {dollars:a} a month. {xcue} {dollars:b}.", "The rent is {dollars:b} a month."),
    ],
    "valid": [
        (F, "The firmware on the router is version {version}.", None),
        (F, "Locker {digits4} is the one by the window.", None),
        (F, "The bridge is {decimal} metres high, so the van won't fit.", None),
        (F, "Parking costs {money} for the whole day.", None),
        (SAME, "The coach leaves at {time:a}{cue} {time:b} from the depot.", "The coach leaves at {time:b} from the depot."),
    ],
    "test": [
        (F, "{name} said the patch is version {version:a}, and the server runs version {version:b}.", None),
        (F, "Write down account {digits6} and the amount, {money}.", None),
        (F, "Unemployment fell to {percent} in {year}.", None),
        (F, "The pool opens at {time} and closes at {time:b}.", None),
        (F, "We counted {count} birds at the lake on {date}.", None),
        (SAME, "The deposit is {dollars:a}{cue} {dollars:b} for the van.", "The deposit is {dollars:b} for the van."),
        (CROSS, "The ferry carries {count:a} cars. {xcue} {count:b} cars.", "The ferry carries {count:b} cars."),
    ],
}

# Lists counted "One, … Two, …", items with numbers inside and a word last, so no number runs
# into the next marker: "after ten two print …" could be a time, "ten two". Deep keeps the markers
# as said; the layout rules number the list.
SERIES = {
    "train": {
        "intros": ["Three things before {weekday}", "For the open day", "Jobs for this week", "Before the trip", ""],
        "items": [
            "order {count} chairs for the hall", "book the room for {time} on {weekday}",
            "pay the deposit of {money} today", "update the laptops to version {version} tonight",
            "ring the supplier about order {digits4} today", "print {count} copies of the agenda",
            "check the scales read {decimal} kilos exactly", "raise the price by {percent} in {month}",
            "send {name} the {year} accounts", "call the office on {phone} this afternoon",
        ],
    },
    "valid": {
        "intros": ["For the move", ""],
        "items": ["hire a van for {time} on {weekday}", "pack {count} boxes of books for the attic",
                  "leave {money} for the cleaner", "give the landlord key {digits4} back"],
    },
    "test": {
        "intros": ["Before the concert", ""],
        "items": ["print version {version} of the running order", "set out {count} music stands",
                  "collect a float of {money} from the bank", "open the doors at {time} sharp"],
    },
}
SERIES_TEMPLATES = {"train": 5, "valid": 1, "test": 1}
MARKERS = ["One", "Two", "Three", "Four"]

# MARK: - Filling

SLOT = re.compile(r"\{(\w+)(?::(\w+))?\}")
OPEN, CLOSE = "«", "»"


def fill(said, written, rng):
    """The said and written texts with values chosen, number words between « and ».

    An untagged slot is matched by its order among its kind's untagged slots, so the k-th
    "{count}" said is the k-th written. Every sum in a row is in one currency."""
    chosen, used = {}, {}
    cue = (rng.choice(SAME_CUES), rng.choice(CROSS_CUES))
    currency = rng.choice(CURRENCIES)

    def substitute(text):
        order = {}

        def value(match):
            kind, tag = match.group(1), match.group(2)
            if kind in ("cue", "xcue"):
                return cue[kind == "xcue"]
            if not tag:
                tag = f"_{order.setdefault(kind, 0)}"
                order[kind] += 1
            if (kind, tag) in chosen:
                return chosen[(kind, tag)]
            maker = NUMBER_KINDS.get(kind) or WORD_KINDS[kind]
            for _ in range(50):
                text = maker(rng, currency) if kind in CURRENCY_KINDS else maker(rng)
                if text not in used.setdefault(kind, set()):
                    break
            used[kind].add(text)
            chosen[(kind, tag)] = OPEN + text + CLOSE if kind in NUMBER_KINDS else text
            return chosen[(kind, tag)]

        return SLOT.sub(value, text)

    said_text = substitute(said)
    return said_text, substitute(written) if written else said_text


def sentence_case(text):
    """A capital at the start of the text and of each sentence, number words included."""
    def upper(match):
        return match.group(1) + match.group(2).upper()
    return re.sub(r"(^[«]?|[.?!:]\s+[«]?)([a-z])", upper, text)


def plain(text):
    return text.replace(OPEN, "").replace(CLOSE, "")


def lower_form(text):
    """As a recognizer that writes no capitals or punctuation does; compounds said spaced."""
    text = plain(text).lower().replace("-", " ")
    text = re.sub(r"[.,?!:;]", "", text)
    return " ".join(text.split())


# Words a speaker doesn't pause after.
NEVER_LAST = {"the", "a", "an", "to", "at", "of", "and", "or", "is", "for", "on", "in", "my", "your", "our",
              "by", "from", "with", "me", "are", "it's", "i'll", "i've", "we'll", "was", "has", "not",
              # nor inside a correction cue: "I mean", "make that".
              "i", "make", "this", "that", "these", "those"}


def odd_form(text, rng):
    """Full stops or commas where the speaker paused, never inside a number."""
    tokens = text.split(" ")
    # Whether a number is still open after each token: no pause goes inside one, or straight
    # after one, between it and what it counts.
    open_after, depth = [], 0
    for token in tokens:
        depth += token.count(OPEN) - token.count(CLOSE)
        open_after.append(depth > 0)
    choices = [i for i in range(1, len(tokens) - 2)
               if not open_after[i] and not re.search(r"[.,?!:;»]$", tokens[i])
               and plain(tokens[i]).lower() not in NEVER_LAST
               # No sentence of one word on either side of the pause.
               and not re.search(r"[.?!]»?$", tokens[i - 1]) and not re.search(r"[.?!]»?$", tokens[i + 1])]
    if not choices:
        return plain(text)
    edits = 1 + (len(choices) >= 5 and rng.random() < 0.4)
    for index in sorted(rng.sample(choices, min(edits, len(choices))), reverse=True):
        following = tokens[index + 1]
        if following.startswith(OPEN) or rng.random() < 0.45:
            tokens[index] += ","
        else:
            tokens[index] += "."
            tokens[index + 1] = re.sub(r"^(«?)([a-z])", lambda m: m.group(1) + m.group(2).upper(), following)
    result = " ".join(tokens)
    if rng.random() < 0.3:
        # A comma the speaker's pause didn't bring.
        commas = [m.start() for m in re.finditer(r",(?= )", result)]
        if commas:
            spot = rng.choice(commas)
            result = result[:spot] + result[spot + 1:]
    return plain(result)


def raw_form(said, rng):
    """About half as a good recognizer writes it, 30% lower case without punctuation, 20% with
    odd stops or commas."""
    pick = rng.random()
    if pick < 0.5:
        text = plain(said)
        if rng.random() < 0.05:
            text = text[0].lower() + text[1:]
        return text, "cased"
    if pick < 0.8:
        return lower_form(said), "lower"
    return odd_form(said, rng), "odd"


def series_texts(spec, rng):
    """A counted list: said with the markers as speech writes them, written as Deep keeps them."""
    count = rng.choice([2, 2, 3, 3, 4])
    items = rng.sample(spec["items"], count)
    intro = rng.choice(spec["intros"])
    if intro.startswith("Three things"):
        count = 3
        items = items[:3] if len(items) >= 3 else rng.sample(spec["items"], 3)
    template = (intro + ": " if intro else "") + " ".join(f"{MARKERS[i]}, {item}." for i, item in enumerate(items))
    said, written = fill(template, None, rng)
    written = sentence_case(written)
    pick = rng.random()
    if pick < 0.45:
        raw = plain(written)
        if intro and rng.random() < 0.5:
            raw = raw.replace(": One,", ": one,")
        if rng.random() < 0.3:
            # Items run on with semicolons, as some recognizers write them.
            raw = re.sub(r"\. (Two|Three|Four),", lambda m: "; " + m.group(1).lower() + ",", raw)
        form = "cased"
    elif pick < 0.75:
        raw, form = lower_form(written), "lower"
    else:
        # The comma after the item rather than the marker: "one, A, two B".
        text = plain(written)
        text = re.sub(r"\. (Two|Three|Four), ", lambda m: ", " + m.group(1).lower() + " ", text)
        raw, form = text.rstrip("."), "odd"
    return raw, plain(written), form


def generate():
    rng = random.Random(SEED)
    rows = {split: [] for split in ROWS_PER_TEMPLATE}
    for split, templates in TEMPLATES.items():
        for category, said, written in templates:
            seen = set()
            made, attempts = 0, 0
            while made < ROWS_PER_TEMPLATE[split] and attempts < 200:
                attempts += 1
                said_text, written_text = fill(said, written, rng)
                said_text, written_text = sentence_case(said_text), sentence_case(written_text)
                raw, _ = raw_form(said_text, rng)
                if raw in seen:
                    continue
                seen.add(raw)
                rows[split].append(row(category, raw, plain(written_text), rng.random() < 0.3))
                made += 1
        for _ in range(SERIES_TEMPLATES[split]):
            made, seen = 0, set()
            while made < ROWS_PER_TEMPLATE[split]:
                raw, target, _ = series_texts(SERIES[split], rng)
                if raw in seen:
                    continue
                seen.add(raw)
                rows[split].append(row("series", raw, target, rng.random() < 0.3))
                made += 1
    return rows


def row(category, raw, target, multiline):
    return {"category": category, "context": [], "letterBody": False, "multiline": multiline,
            "raw": raw, "source": f"e:{FAMILY}", "target": target}


# MARK: - Gate

# Hand-written held-out cases: frames and words no template above uses. `keep` is the number as
# said; `avoid` a shortened or wrong value, or a retracted one.
GATE_CASES = [
    ("the dishwasher shows error code three oh one", "The dishwasher shows error code three oh one.", ["three oh one"], ["three one", "301"]),
    ("Our app store build is two point zero point four.", "Our app store build is two point zero point four.", ["two point zero point four"], ["two point four", "2.0.4"]),
    ("we tested build eleven point three point zero last night", "We tested build eleven point three point zero last night.", ["eleven point three point zero"], ["eleven point zero", "11.3.0"]),
    ("Membership number zero zero seven one nine is expired.", "Membership number zero zero seven one nine is expired.", ["zero zero seven one nine"], ["number zero seven one nine", "00719"]),
    ("The pin for the side entrance is nine nine zero four.", "The pin for the side entrance is nine nine zero four.", ["nine nine zero four"], ["entrance is nine zero four", "9904"]),
    ("text the courier on oh four nine one, two two eight, five three oh", "Text the courier on oh four nine one, two two eight, five three oh.", ["oh four nine one", "two two eight", "five three oh"], ["0491"]),
    ("The recipe needs one point two five litres of stock.", "The recipe needs one point two five litres of stock.", ["one point two five"], ["one point five", "1.25"]),
    ("the baby weighed three point four eight kilos at birth", "The baby weighed three point four eight kilos at birth.", ["three point four eight"], ["three point eight", "3.48"]),
    ("A pint of milk is now ninety-five cents at the corner store.", "A pint of milk is now ninety-five cents at the corner store.", ["ninety-five cents"], ["95"]),
    ("the plumber charged three hundred and forty-two dollars for the visit", "The plumber charged three hundred and forty-two dollars for the visit.", ["three hundred and forty-two dollars"], ["three hundred dollars", "342"]),
    ("Entry is eleven euros fifty for adults.", "Entry is eleven euros fifty for adults.", ["eleven euros fifty"], ["11.50"]),
    ("interest rates rose to four point seven five percent", "Interest rates rose to four point seven five percent.", ["four point seven five percent"], ["four point five percent", "4.75"]),
    ("Attendance was down. Sixty-two percent of members came.", "Attendance was down. Sixty-two percent of members came.", ["sixty-two percent"], ["62"]),
    ("the yoga class starts at six forty-five am", "The yoga class starts at six forty-five am.", ["six forty-five"], ["six forty am", "6:45"]),
    ("My shift ends at quarter to eleven tonight.", "My shift ends at quarter to eleven tonight.", ["quarter to eleven"], ["10:45"]),
    ("the vet is free at two oh five or three twenty", "The vet is free at two oh five or three twenty.", ["two oh five", "three twenty"], ["2:05", "3:20"]),
    ("Grandad bought the farm in nineteen fifty-three.", "Grandad bought the farm in nineteen fifty-three.", ["nineteen fifty-three"], ["1953"]),
    ("the warranty lasts until twenty thirty-one", "The warranty lasts until twenty thirty-one.", ["twenty thirty-one"], ["2031"]),
    ("Thirty-seven runners finished the race.", "Thirty-seven runners finished the race.", ["thirty-seven"], ["37"]),
    ("we planted four hundred and six trees along the river", "We planted four hundred and six trees along the river.", ["four hundred and six"], ["four hundred trees", "406"]),
    ("I have two questions about the lease.", "I have two questions about the lease.", ["two questions"], ["2 questions"]),
    ("the choir has fifty-eight singers. Twelve of them are new", "The choir has fifty-eight singers. Twelve of them are new.", ["fifty-eight", "twelve"], ["58"]),
    ("Seat fourteen C is next to seat fourteen D.", "Seat fourteen C is next to seat fourteen D.", ["fourteen c", "fourteen d"], ["14"]),
    ("the fridge in flat six oh two is leaking again", "The fridge in flat six oh two is leaking again.", ["six oh two"], ["six two", "602"]),
    ("The changelog for build nine point one, sorry, nine point one point two is ready.", "The changelog for build nine point one point two is ready.", ["nine point one point two"], ["sorry"]),
    ("the pin is five five one eight no wait five five one nine", "The pin is five five one nine.", ["five five one nine"], ["five five one eight"]),
    ("The kayak costs six hundred dollars. Sorry, six hundred and fifty dollars.", "The kayak costs six hundred and fifty dollars.", ["six hundred and fifty dollars"], ["six hundred dollars"]),
    ("we need eighteen volunteers i mean twenty-three volunteers for saturday", "We need twenty-three volunteers for Saturday.", ["twenty-three"], ["eighteen"]),
    ("Turnout was forty-one percent. No, sorry, forty-four percent.", "Turnout was forty-four percent.", ["forty-four percent"], ["forty-one"]),
    ("the clinic opens at eight fifteen sorry eight fifty on mondays", "The clinic opens at eight fifty on Mondays.", ["eight fifty"], ["eight fifteen"]),
    ("The bakery opened in twenty eleven. Actually, no, in twenty twelve.", "The bakery opened in twenty twelve.", ["twenty twelve"], ["twenty eleven"]),
    ("Membership number zero four four two, I mean zero four four three, needs renewing.", "Membership number zero four four three needs renewing.", ["zero four four three"], ["zero four four two"]),
    ("Bring forty-five dollars and two point five metres of rope to the camp.", "Bring forty-five dollars and two point five metres of rope to the camp.", ["forty-five dollars", "two point five"], ["two point five dollars"]),
    ("the score was three one at half time and five two at the end", "The score was three one at half time and five two at the end.", ["three one", "five two"], ["thirty-one", "fifty-two"]),
    ("Gym fees rise from thirty-nine to forty-four dollars in twenty twenty-seven.", "Gym fees rise from thirty-nine to forty-four dollars in twenty twenty-seven.", ["thirty-nine", "forty-four dollars", "twenty twenty-seven"], ["2027"]),
    ("one, water the tomatoes with two litres each, two collect the eggs before nine", "One, water the tomatoes with two litres each. Two, collect the eggs before nine.", ["one water the tomatoes", "two litres", "two collect the eggs before nine"], ["1", "2"]),
    ("Weekend plan: One, fix the fence with twelve new boards. Two, drive the kids to football at ten thirty.", "Weekend plan: One, fix the fence with twelve new boards. Two, drive the kids to football at ten thirty.", ["one fix the fence", "twelve new boards", "two drive the kids", "ten thirty"], ["1", "2", "10:30"]),
    ("three jobs for the garage one sweep the floor two sell the old bike for eighty dollars three hang the shelves by sunday", "Three jobs for the garage: One, sweep the floor. Two, sell the old bike for eighty dollars. Three, hang the shelves by Sunday.", ["three jobs", "one sweep the floor", "two sell the old bike for eighty dollars", "three hang the shelves"], ["1", "2", "3", "80"]),
    ("Tell the team the update to build four point zero point one ships on the twenty-second of May.", "Tell the team the update to build four point zero point one ships on the twenty-second of May.", ["four point zero point one", "twenty-second of may"], ["four point one", "4.0.1"]),
    ("no one picked up when I rang two nine eight three", "No one picked up when I rang two nine eight three.", ["no one", "two nine eight three"], ["2983"]),
    # Counted "one, A, two B", a comma after the first marker and after each item, as lists are
    # often dictated: the markers stay words with a comma after each, so the layout rules number them.
    ("one, renew the car insurance for twelve months, two book the boiler service for the fourth of june", "One, renew the car insurance for twelve months. Two, book the boiler service for the fourth of June.", ["one renew the car insurance", "twelve months", "two book the boiler service", "fourth of june"], ["1", "2", "12"]),
    ("before friday one return the library books two pay the gas bill of sixty one pounds three water the plants", "Before Friday: One, return the library books. Two, pay the gas bill of sixty-one pounds. Three, water the plants.", ["one return the library books", "two pay the gas bill", "sixty-one pounds", "three water the plants"], ["1", "2", "3", "61"]),
]
# The counted lists, in fields that take several lines.
GATE_MULTILINE = {35, 36, 37, 40, 41}


def gate_rows():
    rows = []
    for index, (raw, target, keep, avoid) in enumerate(GATE_CASES):
        rows.append({"id": f"{FAMILY}-{index + 1:02d}", "category": FAMILY, "raw": raw, "target": target,
                     "alternatives": [], "multiline": index in GATE_MULTILINE, "keep": keep, "avoid": avoid})
    return rows


# MARK: - Output and checks

def normalized(text):
    """Words only, as leakage is compared: lower case, no punctuation, hyphens as spaces."""
    text = text.lower().replace("’", "'").replace("-", " ")
    return " ".join(re.sub(r"[^\w' ]+", " ", text).split())


def eval_words(text):
    """The words as Shared.EditDistance compares them: lower case, dashes as spaces, no marks."""
    chars = []
    for char in text.lower().replace("’", "'"):
        if char in "-—–":
            chars.append(" ")
        elif char == "'" or unicodedata.category(char)[0] not in "PS":
            chars.append(char)
    return " ".join(word.strip("'") for word in "".join(chars).split() if word.strip("'"))


def write(path, rows, sort_keys=True, compact=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    separators = (",", ":") if compact else (", ", ": ")
    path.write_text("".join(json.dumps(r, ensure_ascii=False, sort_keys=sort_keys, separators=separators) + "\n" for r in rows))


def check(rows, gate):
    """Leakage against the held-out sets, across this family's splits, and gate against rows."""
    held = {}
    for path in HELD_OUT:
        if not path.exists() or path == GATE:
            continue
        for line in path.read_text().splitlines():
            if line.strip():
                held.setdefault(normalized(json.loads(line)["raw"]), path.name)
    problems = []
    by_split = {split: {normalized(r["raw"]) for r in split_rows} for split, split_rows in rows.items()}
    for split, split_rows in rows.items():
        for r in split_rows:
            if normalized(r["raw"]) in held:
                problems.append(f"{split} raw repeats {held[normalized(r['raw'])]}: {r['raw']}")
    for a, b in (("train", "valid"), ("train", "test"), ("valid", "test")):
        for raw in by_split[a] & by_split[b]:
            problems.append(f"{a} and {b} share: {raw}")
    every = set().union(*by_split.values())
    for case in gate:
        if normalized(case["raw"]) in every or normalized(case["target"]) in every:
            problems.append(f"gate repeats a row: {case['raw']}")
        if normalized(case["raw"]) in held:
            problems.append(f"gate repeats {held[normalized(case['raw'])]}: {case['raw']}")
    # No gate case shares a run of four words, numbers aside, with a template.
    template_runs = set()
    texts = [t for templates in TEMPLATES.values() for _, said, written in templates for t in (said, written or "")]
    texts += [t for spec in SERIES.values() for t in spec["items"] + spec["intros"]]
    for text in texts:
        for part in SLOT.sub("|", text).split("|"):
            words = normalized(part).split()
            template_runs |= {tuple(words[i:i + 4]) for i in range(len(words) - 3)}
    numbers = set(UNITS) | set(TENS) | set(ORDINAL_UNITS) | {"hundred", "thousand", "point", "oh", "and"}
    for case in gate:
        words = normalized(case["target"]).split()
        runs = {tuple(words[i:i + 4]) for i in range(len(words) - 3)}
        shared = [run for run in runs & template_runs if not set(run) & numbers]
        if shared:
            problems.append(f"gate shares a template's words {' '.join(shared[0])}: {case['raw']}")
    # A counted list's item ends in a word, so no number runs into the next marker.
    for spec in SERIES.values():
        for item in spec["items"]:
            last = item.split()[-1]
            slot = SLOT.fullmatch(last)
            if (slot and slot.group(1) in NUMBER_KINDS) or (not slot and normalized(last) in numbers):
                problems.append(f"list item ends in a number: {item}")
    # As EvalLayoutTests asks of layout.jsonl: every kept phrase is in the target, no avoided one is.
    for case in gate:
        target = f" {eval_words(case['target'])} "
        for phrase in case["keep"]:
            if not eval_words(phrase) or f" {eval_words(phrase)} " not in target:
                problems.append(f"{case['id']} keeps {phrase!r}, not in its target")
        for phrase in case["avoid"]:
            if not eval_words(phrase) or f" {eval_words(phrase)} " in target:
                problems.append(f"{case['id']} avoids {phrase!r}, which its target has")
    for r in (r for split_rows in rows.values() for r in split_rows):
        # A number word title-cased anywhere but a sentence's first word is the defect E fixes.
        for match in re.finditer(r"(?<![.?!:] )(?<!^)\b(Zero|One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten|Twenty|Thirty|Forty|Fifty|Hundred|Thousand|Point|Oh)\b", r["target"]):
            before = r["target"][:match.start()].rstrip()
            if before and before[-1] not in ".?!:":
                problems.append(f"title-cased number word in target: {r['target']}")
                break
        if re.search(r"\d", r["target"]) or re.search(r"\d", r["raw"]):
            problems.append(f"digit in a speech seed: {r['raw']}")
    return problems, len(held)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="also report leakage against the held-out sets")
    options = parser.parse_args()
    rows = generate()
    gate = gate_rows()
    for split, split_rows in rows.items():
        write(OUTPUT / f"{FAMILY}-{split}.jsonl", split_rows)
    write(GATE, gate, sort_keys=False, compact=False)
    counts = {split: len(split_rows) for split, split_rows in rows.items()}
    print(json.dumps({"family": FAMILY, **counts, "gate": len(gate)}))
    if options.check:
        problems, held = check(rows, gate)
        print(json.dumps({"held_out_raws": held, "problems": len(problems)}))
        for problem in problems:
            print("  " + problem)
        if problems:
            sys.exit(1)


if __name__ == "__main__":
    main()
