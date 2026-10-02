#!/usr/bin/env python3
"""Dictations written the way speech-to-text writes them, for transcript_seeds in the rules file.

They hold what a voice can't carry through TTS, because a synthetic voice says the word right and
the recognizer then writes it right:
- a common word the recognizer writes as a name ("We need to Harry", for hurry);
- letters it spells out ("the B B C").

Controls keep a name where it is one, and keep letters that aren't an acronym. The seeds are
general English and never come from anyone's dictation. Output is deterministic: printed as
{"train": [...], "valid": [...], "test": [...]}, or written into the rules file with --write.
A template's rows all go to one split, so the test seeds are sentences the adapter never saw.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

RULES = Path(__file__).resolve().parent.parent / "Packages/LiveTranscribeKit/Training/speech-to-text-rules.json"

# A common word, the name the recognizer writes for it, and sentences using the word mid-sentence
# ({W}), never where a sentence starts, since a capital there says nothing. {slot} fills vary.
MISHEARD = [
    ("hurry", "Harry", [
        "We need to {W} or we'll miss the {transport}.",
        "Tell the kids to {W} up, the {transport} is here.",
        "What's the {W}? The shop is open until {hour}.",
        "I'm in a bit of a {W} this morning, so I'll call you later.",
    ]),
    ("carry", "Carrie", [
        "Can you help me {W} the shopping inside?",
        "I'll {W} the boxes up to the {room} after lunch.",
        "The corner shop doesn't {W} that brand any more.",
        "Remember to {W} an umbrella, it's going to rain.",
    ]),
    ("jury", "Jerry", [
        "The {W} is still out on the new {thing}.",
        "She was called up for {W} service next month.",
        "The {W} took three days to reach a verdict.",
    ]),
    ("frank", "Frank", [
        "To be {W}, I didn't enjoy the {event}.",
        "We had a very {W} conversation about the budget.",
        "Thanks for your {W} feedback on the draft.",
    ]),
    ("summer", "Summer", [
        "We're going to {place} this {W}.",
        "The garden looks lovely in the {W}.",
        "Our {W} holiday is booked for the second week of August.",
    ]),
    ("bill", "Bill", [
        "Can you pay the {utility} {W} before {day}?",
        "The {W} came to forty pounds, including the tip.",
        "I've set up a direct debit for the electricity {W}.",
    ]),
    ("grace", "Grace", [
        "She handled the bad news with real {W}.",
        "We have a week's {W} before the rent is due.",
        "The dancers moved with such {W} on stage.",
    ]),
    ("rose", "Rose", [
        "Prices {W} again this month.",
        "She {W} early to catch the first flight.",
        "The river {W} after all the rain last week.",
    ]),
    ("mark", "Mark", [
        "Can you {W} the date in the calendar?",
        "There's a dirty {W} on the kitchen wall.",
        "Please {W} the boxes that need to go upstairs.",
    ]),
    ("drew", "Drew", [
        "My daughter {W} a picture of the dog.",
        "The match {W} a huge crowd on {day}.",
        "We {W} straws to see who would drive.",
    ]),
    ("will", "Will", [
        "She left the house to her nephew in her {W}.",
        "It takes a lot of {W} power to stay off sugar.",
        "He made a new {W} before the operation.",
    ]),
    ("dawn", "Dawn", [
        "We left at {W} to beat the traffic.",
        "The birds start singing just before {W}.",
        "It finally {W}ed on me that the shop was closed.",
    ]),
    ("miles", "Miles", [
        "The hotel is three {W} from the beach.",
        "We walked about ten {W} on {day}.",
        "My car has done a lot of {W} this year.",
    ]),
    ("nick", "Nick", [
        "We got there just in the {W} of time.",
        "Someone tried to {W} my bike from outside the station.",
        "There's a small {W} in the table from the move.",
    ]),
    ("chase", "Chase", [
        "The dog loves to {W} the ball in the park.",
        "I had to {W} them twice for the invoice.",
        "Let's cut to the {W} and talk about the price.",
    ]),
    ("jack", "Jack", [
        "We need a {W} to change the tyre.",
        "Plug the headphones into the {W} on the left.",
    ]),
    ("kneel", "Neil", [
        "You'll have to {W} down to reach the plug.",
        "Please {W} on the mat while you clean the floor.",
    ]),
    ("pat", "Pat", [
        "Give the dog a {W} on the head.",
        "You should {W} the fish dry before you cook it.",
    ]),
    ("merge", "Madge", [
        "The two lanes {W} just after the roundabout.",
        "We'll {W} the two guest lists into one.",
        "The councils plan to {W} next year.",
    ]),
]

# Acronyms the recognizer spells out letter by letter, in sentences using them ({A}).
ACRONYMS = [
    ("BBC", ["I heard it on the {A} news this morning.", "There's a good documentary on the {A} tonight."]),
    ("ATM", ["Is there an {A} near the station?", "The {A} kept my card again."]),
    ("PDF", ["Can you send the tickets as a {A}?", "I saved the menu as a {A} for you."]),
    ("GP", ["I've booked an appointment with my {A} for {day}.", "The {A} said to rest for a week."]),
    ("NHS", ["The {A} app has all my records.", "She's worked for the {A} for twenty years."]),
    ("UK", ["We're flying back to the {A} on {day}.", "Prices in the {A} have gone up again."]),
    ("EU", ["You don't need a visa to travel in the {A}."]),
    ("TV", ["The {A} in the kitchen has stopped working.", "Is there anything good on {A} tonight?"]),
    ("GPS", ["The {A} sent us the wrong way round the lake."]),
    ("ID", ["Remember to bring your {A} to the bank.", "They asked for photo {A} at the door."]),
    ("FAQ", ["The answer is in the {A} on their website."]),
    ("RSVP", ["Please {A} by the end of the week."]),
    ("ETA", ["What's your {A} for the party?"]),
    ("CV", ["I updated my {A} last night.", "Send your {A} to the hiring manager."]),
    ("HR", ["I emailed {A} about my holiday dates."]),
    ("VIP", ["We got {A} tickets for the concert."]),
    ("ASAP", ["Can you call me back {A}?"]),
    ("BBQ", ["We're having a {A} on {day} if it's sunny."]),
    ("DIY", ["The shelves were a {A} job, so they're a bit wonky."]),
    ("PIN", ["I forgot my {A} at the checkout."]),
    ("SUV", ["They bought a new {A} for the school run."]),
    ("MRI", ["The {A} scan is booked for {day} morning."]),
    ("USB", ["Plug the {A} stick into the side of the laptop."]),
    ("DVD", ["We watched an old {A} last night."]),
    ("CEO", ["The {A} is visiting the office on {day}."]),
]

# A name used as one, sometimes beside the word it sounds like: kept as said.
NAMES = [
    "Harry is picking us up at six.", "Ask Carrie if she wants to come to the cinema.",
    "Frank and Jerry are bringing the drinks.", "Summer starts her new job on Monday.",
    "Bill said the gas bill went up again.", "Will you ask Will to call me back?",
    "Grace sent a lovely card to say thanks.", "Rose and Mark are getting married in June.",
    "Drew drew a map of the route for us.", "Dawn is on holiday until Friday.",
    "Miles walked three miles to the station.", "Nick is driving, so Jack can relax.",
    "Neil asked us all to kneel for the photo.", "Pat gave the dog a pat on the head.",
    "Madge is coming to the party with her sister.", "I told Harry there's no hurry.",
    "Can you carry this bag for Carrie?", "We met Chase at the school gate.",
    "Thanks, Grace, that was really kind.", "I'll see Frank on Thursday.",
    "My brother Jack fixed the fence.", "Our neighbour Dawn feeds the cat when we're away.",
]

# Single letters that aren't an acronym: kept as said.
LETTERS = [
    "Is it plan A or plan B?", "I got a B in the maths test.", "Take vitamin C every morning.",
    "Our seats are in row E, near the front.", "Option B looks better to me.",
    "The flat is in block D, on the left.", "She's in group A this year.",
]

# Lists said as steps: (said, laid out), with {Name} and {A B} filled from MISHEARD and ACRONYMS.
LISTS = [
    ("Things to do this weekend. First, pay the gas {bill}. Second, call the {GP}. Third, {hurry} to the shop before it shuts.",
     "Things to do this weekend:\n1. Pay the gas bill.\n2. Call the GP.\n3. Hurry to the shop before it shuts."),
    ("Before the trip, {carry} the bags to the car, save the tickets as a {PDF} and charge the {GPS}.",
     "Before the trip:\n- Carry the bags to the car\n- Save the tickets as a PDF\n- Charge the GPS"),
    ("For the party. First, send the {RSVP} cards. Second, book the {BBQ}. Third, {mark} the date in the calendar.",
     "For the party:\n1. Send the RSVP cards.\n2. Book the BBQ.\n3. Mark the date in the calendar."),
    ("To get the flat ready, {carry} the boxes upstairs, {mark} the ones for the attic and fix the {TV}.",
     "To get the flat ready:\n- Carry the boxes upstairs\n- Mark the ones for the attic\n- Fix the TV"),
    ("My list for Monday. First, call {HR} about my {ID}. Second, book the {MRI}. Third, {chase} the plumber for the invoice.",
     "My list for Monday:\n1. Call HR about my ID.\n2. Book the MRI.\n3. Chase the plumber for the invoice."),
    ("Jobs for Saturday. First, pay the water {bill}. Second, drop my {CV} at the library. Third, {hurry} back for lunch.",
     "Jobs for Saturday:\n1. Pay the water bill.\n2. Drop my CV at the library.\n3. Hurry back for lunch."),
    ("Before the {BBQ}, {carry} the chairs outside, find the {USB} speaker and text everyone the {ETA}.",
     "Before the BBQ:\n- Carry the chairs outside\n- Find the USB speaker\n- Text everyone the ETA"),
]

# Sentences said before or after another, for dictations of more than one sentence.
NEUTRAL = [
    "It's been a long week.", "Let me know what you think.", "I'll be home by seven.",
    "Thanks again for dinner last night.", "The weather has been awful all week.",
    "I'll call you when I get there.", "See you on Saturday.", "Hope the kids are well.",
    "We're running a bit late.", "The traffic was terrible this morning.",
]

SLOTS = {
    "transport": ["train", "bus", "ferry", "coach"], "hour": ["nine", "ten", "eight"],
    "room": ["attic", "spare room", "loft"], "thing": ["menu", "timetable", "logo"],
    "event": ["film", "concert", "meal", "play"], "place": ["Spain", "Scotland", "the coast", "Italy"],
    "utility": ["gas", "phone", "water"], "day": ["Friday", "Monday", "Tuesday", "Saturday"],
}
NAME_FOR = {word: name for word, name, _ in MISHEARD}


def digest(*values):
    return hashlib.sha256(json.dumps(values, ensure_ascii=False).encode()).hexdigest()


def fills(template, count):
    """Up to ``count`` different fillings of ``template``'s slots, chosen by digest."""
    slots = re.findall(r"\{(\w+)\}", template)
    slots = [slot for slot in slots if slot in SLOTS]
    if not slots:
        return [{}]
    result = []
    for index in range(count):
        fill = {slot: SLOTS[slot][int(digest(template, slot, index)[:8], 16) % len(SLOTS[slot])] for slot in slots}
        if fill not in result:
            result.append(fill)
    return result


def spaced(acronym):
    return " ".join(acronym)


def row(raw, target, category, group, multiline=None):
    if multiline is None:
        multiline = int(digest("multiline", raw)[:8], 16) % 10 < 3
    return {"raw": raw, "target": target, "category": category, "multiline": multiline, "group": group}


def neighbour(text, index):
    """A neutral sentence said before or after ``text``."""
    other = NEUTRAL[int(digest("neutral", text, index)[:8], 16) % len(NEUTRAL)]
    return (other, text) if int(digest("order", text)[:2], 16) % 2 else (text, other)


def seeds():
    rows = []
    for word, name, templates in MISHEARD:
        for template in templates:
            assert not template.startswith("{W}") and ". {W}" not in template, template
            group = f"misheard:{template}"
            for index, fill in enumerate(fills(template, 2)):
                raw, target = template.format(W=name, **fill), template.format(W=word, **fill)
                rows.append(row(raw, target, "recognition", group))
                if index == 0:
                    before, after = neighbour(raw, index)
                    joined_target = " ".join(target if part == raw else part for part in (before, after))
                    rows.append(row(f"{before} {after}", joined_target, "recognition", group))
    for acronym, templates in ACRONYMS:
        for template in templates:
            group = f"acronym:{template}"
            fill = fills(template, 1)[0]
            target = template.format(A=acronym, **fill)
            rows.append(row(template.format(A=spaced(acronym), **fill), target, "recognition", group))
            # Some come written as they should be, and stay.
            if int(digest("joined", template)[:8], 16) % 4 == 0:
                rows.append(row(target, target, "unchanged", group))
    for text in NAMES:
        rows.append(row(text, text, "unchanged", f"name:{text}"))
    for text in LETTERS:
        rows.append(row(text, text, "unchanged", f"letters:{text}"))
    for said, laid_out in LISTS:
        def heard(match):
            key = match.group(1)
            return NAME_FOR[key] if key in NAME_FOR else spaced(key)
        rows.append(row(re.sub(r"\{(\w+)\}", heard, said), laid_out, "list-many", f"list:{said}", multiline=True))
    return rows


def split(rows):
    """Each template's rows to one split: of each kind's templates, ordered by digest, about a fifth
    are held out for test and a seventh for validation."""
    result = {"train": [], "valid": [], "test": []}
    groups = {}
    for item in rows:
        groups.setdefault(item["group"].split(":")[0], {}).setdefault(item["group"], []).append(item)
    seen = set()
    for kind in sorted(groups):
        ordered = sorted(groups[kind], key=lambda group: digest("split", group))
        test, valid = round(len(ordered) * 0.2), round(len(ordered) * 0.14)
        for index, group in enumerate(ordered):
            name = "test" if index < test else "valid" if index < test + valid else "train"
            for item in groups[kind][group]:
                if item["raw"] not in seen:
                    seen.add(item["raw"])
                    result[name].append({key: value for key, value in item.items() if key != "group"})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rules", type=Path, default=RULES)
    parser.add_argument("--write", action="store_true", help="replace transcript_seeds in the rules file")
    options = parser.parse_args()
    result = split(seeds())
    if options.write:
        rules = json.loads(options.rules.read_text())
        rules["transcript_seeds"] = result
        options.rules.write_text(json.dumps(rules, ensure_ascii=False, indent=2) + "\n")
    else:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({name: len(rows) for name, rows in result.items()}), file=sys.stderr)


if __name__ == "__main__":
    main()
