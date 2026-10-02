#!/usr/bin/env python3
"""Deep candidate E seeds, family "marker-lists".

Two kinds of example, each written the way speech-to-text hands them to Deep:

- series: steps counted out loud and kept as said ("One, go to the shops. Two, talk to the
  mechanic."), with plain or mixed markers ("One, … Number two, …", "First, … Two, …"). Deep
  leaves the words where they are and fixes only capitals and punctuation, so each marker starts
  its sentence with a comma after it; the layout rules number the list after the model. This is
  the convention of countedSteps in DeepLayoutGenerator.swift. Number words inside an item ("if
  we get one and two done") stay lowercase, mid-sentence.
- placeholder: a protected token, such as an email address or a link, at the very start of the
  text or alone ("⟦S1⟧." or "⟦S1⟧ is my new address."). The token stays exactly as it is, and the
  word after a token that is the sentence's subject stays lowercase. A token before a sentence of
  its own gets no full stop the recognizer did not write, as in Deep's other placeholder examples.

Pure "number one … number two …" runs and pure "first … second …" runs are left out: Deep's
other training lays those out itself, and the app takes keyworded runs out before the model.

Every template's rows go to one split, so the test rows are sentences the adapter never saw.
Deterministic: the same seed writes the same files. Python 3 standard library only.

    python3 scripts/e_seeds/marker-lists.py
"""

import json
import random
import re
from pathlib import Path

FAMILY = "marker-lists"
SEED = 20261002
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Packages/LiveTranscribeKit/Training/generated-e"

# Rows from each layout scenario, and how many scenarios go to test and valid.
LAYOUT_ROWS_PER_SCENARIO = 7
LAYOUT_TEST_SCENARIOS = 4
LAYOUT_VALID_SCENARIOS = 3
PLACEHOLDER_TEST_TEMPLATES = 4
PLACEHOLDER_VALID_TEMPLATES = 3

# MARK: - Layout scenarios

# (lead sentence, lead that takes a colon, items, closing sentence). Items start in lower case and
# have no full stop; a number word never starts a clause inside one, so the rules count only the
# markers.
SCENARIOS = [
    ("I need a couple of things done today.", "My errands for today are",
     ["go to the shops for bread and milk", "talk to the mechanic about the brakes",
      "drop the parcel at the post office", "pick up two bags of compost"],
     "That's all for now."),
    ("Here's the plan for the move.", "The plan for the move is",
     ["book the van for Saturday morning", "pack the kitchen last",
      "ask the neighbours to keep a parking space free", "leave the spare keys with the agent"],
     "Call me if anything changes."),
    ("There are a few jobs left before the party.", "The jobs before the party are",
     ["order the cake from the bakery", "borrow ten folding chairs from the hall",
      "hang the lights in the back yard", "buy ice on the day"],
     "Let me know which ones you can take."),
    ("I've got a few things for the team this week.", "This week's priorities are",
     ["finish the budget review by Wednesday", "send the slides to the board",
      "book a room for the retro", "if we get one and two done, the rollout can start on time"],
     "Thanks, everyone."),
    ("This is how to reset the alarm.", "To reset the alarm",
     ["open the panel by the front door", "hold the grey button for five seconds",
      "type the four digit code", "wait for the green light"],
     "It should beep twice when it's done."),
    ("Before you leave the office tonight, please do this.", "The checklist for tonight is",
     ["switch off the monitors", "lock the filing cabinet",
      "check the back door", "set the alarm on your way out"],
     "Thanks for helping out."),
    ("I have a few jobs at the hardware store.", "My jobs at the hardware store are",
     ["get a box of screws for the shelf", "ask about a replacement hinge",
      "pick up one tin of white paint and two brushes", "return the broken drill"],
     "I'll be back by lunch."),
    ("I'd like to go over the agenda for Monday.", "The agenda for Monday is",
     ["welcome the new starters", "review last month's sales",
      "agree on the holiday roster", "close with any other business"],
     "The meeting should take an hour."),
    ("We have a few things to sort out for the trip.", "The jobs for the trip are",
     ["renew the passports", "book the airport parking",
      "change some money at the bank", "find someone to feed the cat"],
     "We leave in two weeks."),
    ("Here's how to make the sauce.", "The method for the sauce is",
     ["melt the butter in a small pan", "stir in the flour for one minute",
      "add the milk a little at a time", "season it with salt and pepper"],
     "It keeps in the fridge for three days."),
    ("We need to fix a few things on the website.", "The fixes for the website are",
     ["update the opening hours", "replace the broken link on the contact page",
      "shrink the photos on the home page", "once one and two are live, add the new menu"],
     "None of these are urgent."),
    ("I have some requests for the landlord.", "My requests for the landlord are",
     ["fix the leak under the sink", "replace the smoke alarm battery",
      "look at the damp patch in the bedroom", "send a copy of the new lease"],
     "I'll email him tomorrow."),
    ("This is the order for the morning.", "The order for the morning is",
     ["get the kids dressed by seven", "pack the lunch boxes",
      "walk the dog around the block", "leave for school at eight fifteen"],
     "Let's try it tomorrow."),
    ("Here are the steps to join the call.", "To join the call",
     ["open the invite in your calendar", "click the link at the bottom",
      "allow the microphone when it asks", "wait for the host to let you in"],
     "Ring me if you get stuck."),
    ("I want to go through the house rules with you.", "The house rules are",
     ["shoes off at the door", "no phones at dinner",
      "lights out by ten on school nights", "whoever cooks doesn't wash up"],
     "They start this weekend."),
    ("We should plan the allotment this spring.", "The allotment plan is",
     ["dig over the vegetable bed", "plant two rows of beans",
      "move the compost bin behind the hut", "fix the fence by the path"],
     "We can start on Sunday if it's dry."),
    ("I'll explain how to set up the printer.", "To set up the printer",
     ["plug it in and turn it on", "connect it to the office network",
      "install the driver from the website", "print one test page"],
     "After that it should just work."),
    ("There's a bit to do before the inspection.", "The list for the inspection is",
     ["clean the oven", "repaint the scuffed wall in the hall",
      "replace one cracked tile in the kitchen", "mow the front lawn"],
     "The agent comes on Thursday."),
    ("Here's what happens at the open day.", "The running order for the open day is",
     ["the doors open at ten", "the head teacher gives a short talk",
      "parents tour the classrooms", "we serve tea in the hall"],
     "It finishes at about noon."),
    ("I'd like you to follow up on a few things.", "The follow ups are",
     ["chase the invoice from March", "confirm the venue for the conference",
      "update the contact list", "check if we need one or two extra staff on the day"],
     "Thanks in advance."),
    ("These are the steps for returning a laptop.", "To return a laptop",
     ["back up your files to the shared drive", "sign out of every account",
      "wipe the laptop with the reset tool", "hand it in at the front desk"],
     "The help desk will send you a receipt."),
    ("I've made a plan for the weekend.", "The plan for the weekend is",
     ["sleep in on Saturday", "take the bikes to the lake",
      "have lunch at the cafe by the pier", "be home in time for the match"],
     "Tell me what you think."),
    ("We need to decide a few things about the wedding.", "The wedding decisions left are",
     ["pick the menu for the dinner", "choose between the two bands",
      "send the invitations by the end of the month", "agree on a budget for flowers"],
     "Let's talk tonight."),
    ("Here's how the fire drill works.", "The fire drill works like this",
     ["leave the building by the nearest exit", "don't stop for your bags",
      "meet at the car park on the corner", "wait for the warden to take the names"],
     "It should take ten minutes at most."),
    ("I want to change how we do the handover.", "The new handover is",
     ["write down any open jobs before you leave", "walk the next shift through them",
      "sign the log book", "call the manager if something can't wait"],
     "We'll start next Monday."),
    ("This is how to get ready for the school camp.", "To get ready for the school camp",
     ["label every piece of clothing", "pack a warm jacket and a hat",
      "put the medicine in a clear bag", "charge the torch the night before"],
     "The bus leaves at eight."),
    ("There are some changes to the rota.", "The changes to the rota are",
     ["the new starter moves to the early shift", "the Friday late shift ends at ten",
      "weekends swap every two weeks", "nobody works more than five days in a row"],
     "Ask me if you have questions."),
    ("I'll walk you through the budget.", "The budget in short is",
     ["rent takes up half of it", "food and bills come to about a quarter",
      "we save a tenth every month", "the rest goes on travel"],
     "It's tight but it works."),
    ("This is what the doctor said.", "The doctor's advice was",
     ["rest for two days", "drink plenty of water",
      "take one tablet in the morning and one at night", "come back if the fever doesn't go down"],
     "I feel better already."),
    ("We need a plan for the leak.", "The plan for the leak is",
     ["turn off the water at the main", "move the boxes out of the cupboard",
      "call the plumber in the morning", "tell the insurer before Friday"],
     "I'll make the calls."),
    ("I'd like to set some goals for the term.", "My goals for the term are",
     ["read one book a month", "practise the piano every day",
      "get to bed before eleven", "hand in every essay on time"],
     "Hold me to it."),
    ("Here's how to check in for the flight.", "To check in for the flight",
     ["open the airline app", "enter the booking code",
      "choose your seat", "save the boarding pass to your phone"],
     "Do it at least two hours before you leave."),
    ("I have a few reminders for the volunteers.", "The reminders for the volunteers are",
     ["sign in at the desk when you arrive", "wear the yellow vests at all times",
      "keep the fire exits clear", "hand back the radios at the end"],
     "Thank you for giving up your Saturday."),
    ("We have to get the car ready for the road trip.", "The jobs on the car are",
     ["check the tyre pressure", "top up the oil",
      "put two bottles of water in the back", "if we finish one and two early, clean out the boot as well"],
     "After that we're good to go."),
    ("Let me explain how the vote works.", "The voting works like this",
     ["each member gets one vote", "the votes are counted on the night",
      "a tie goes to the chair", "the result goes up the next morning"],
     "Just ask if anything is unclear."),
    ("I've got a few notes on the draft.", "My notes on the draft are",
     ["the opening is too long", "the middle chapter needs a stronger ending",
      "check the dates in the timeline", "cut one of the two case studies"],
     "Overall it's a good start."),
    ("Here's what to do if the power goes out.", "If the power goes out",
     ["check the fuse box in the garage", "unplug the fridge and the freezer",
      "use the torch in the kitchen drawer", "ring the power company"],
     "Don't open the freezer more than you need to."),
    ("We need to tidy up the shared drive.", "The plan for the shared drive is",
     ["delete any files older than two years", "move the contracts into one folder",
      "rename the folders by year", "give the interns read only access"],
     "I'll start on Friday."),
    ("Here's the plan for the bake sale.", "The plan for the bake sale is",
     ["bake four trays of brownies", "make price labels for every table",
      "bring a float of small change", "pack up by three"],
     "Every penny goes to the school."),
    ("I want to explain how the new parking works.", "The new parking rules are",
     ["staff park on the top level", "visitors use the bays by the entrance",
      "permits stay on the dashboard", "the gates close at seven"],
     "It starts next month."),
]

# Items that speak of the items before them ("if we get one and two done"), so they come third or
# later, never as item one or two. Each is the last of its scenario's items.
LATE_ITEMS = {
    "if we get one and two done, the rollout can start on time",
    "once one and two are live, add the new menu",
    "if we finish one and two early, clean out the boot as well",
}

CARDINALS = ["one", "two", "three", "four"]
ORDINALS = ["first", "second"]


def markers(style, count, rng):
    """The words that mark each item's place, lower case, for `count` items."""
    if style == "plain":
        return CARDINALS[:count]
    if style == "keyword-first":
        return ["number one"] + CARDINALS[1:count]
    if style == "keyword-later":
        said = ["one"] + [f"number {word}" if rng.random() < 0.6 else word for word in CARDINALS[1:count]]
        if not any(word.startswith("number") for word in said):
            said[-1] = f"number {said[-1]}"
        return said
    if style == "first-then-cardinal":
        return ["first"] + CARDINALS[1:count]
    if style == "first-second-cardinal":
        return ORDINALS + CARDINALS[2:count]
    raise ValueError(style)


def pick_style(count, rng):
    styles = [("plain", 0.35), ("keyword-first", 0.15), ("keyword-later", 0.2), ("first-then-cardinal", 0.15)]
    # "First, A. Second, B." alone is a pure ordinal run, which Deep's other training lays out.
    if count >= 3:
        styles.append(("first-second-cardinal", 0.15))
    roll = rng.random() * sum(weight for _, weight in styles)
    for style, weight in styles:
        roll -= weight
        if roll < 0:
            return style
    return styles[-1][0]


def capitalised(text):
    return text[:1].upper() + text[1:] if text else text


def assemble(pieces):
    """Text from (words, end mark) pieces: a capital at the start and after a sentence end or a
    colon (countedSteps writes "Intro: One, …")."""
    out = []
    capital = True
    for words, end in pieces:
        out.append((capitalised(words) if capital else words) + end)
        capital = end in (".", "?", "!", ":")
    return " ".join(out)


def unpunctuated(text):
    """Lower case with no punctuation, as some recognizers write it. Apostrophes and hyphens stay."""
    text = re.sub(r"[.,:;?!]", "", text.lower())
    return re.sub(r"\s+", " ", text).strip()


def layout_row(scenario, rng):
    lead, colon_lead, items, closer = scenario
    count = rng.choices([2, 3, 4], weights=[0.3, 0.4, 0.3])[0]
    # Items keep their order, so a late item, last in the list, lands third or later.
    pool = [i for i, item in enumerate(items) if count >= 3 or item not in LATE_ITEMS]
    chosen = [items[i] for i in sorted(rng.sample(pool, count))]
    said_markers = markers(pick_style(count, rng), count, rng)
    lead_kind = rng.choices(["none", "sentence", "colon"], weights=[0.25, 0.55, 0.2])[0]
    with_closer = rng.random() < 0.4

    def lead_piece(end_for_sentence):
        if lead_kind == "sentence":
            return [(lead[:-1], end_for_sentence)]
        if lead_kind == "colon":
            return [(colon_lead, ":")]
        return []

    target = assemble(
        lead_piece(".")
        + [(f"{marker}, {item}", ".") for marker, item in zip(said_markers, chosen)]
        + ([(closer[:-1], closer[-1])] if with_closer else [])
    )
    form = rng.choices(["cased", "unpunctuated", "odd"], weights=[0.5, 0.3, 0.2])[0]
    if form == "cased":
        raw = target
    elif form == "unpunctuated":
        raw = unpunctuated(target)
    else:
        raw = odd_layout_raw(lead_piece, lead_kind, said_markers, chosen, closer if with_closer else None, rng)
        if raw == target:
            form, raw = "unpunctuated", unpunctuated(target)
    return form, raw, target


# Words a speaker does not pause after.
PAUSE_NEVER_AFTER = {
    "a", "an", "the", "to", "of", "for", "at", "in", "on", "by", "and", "or", "if", "your", "my", "our",
    "every", "each", "any", "some", "this", "that", "with", "from", "up", "into", "than", "more",
    "one", "two", "three", "four", "five", "ten", "half",
}


def odd_layout_raw(lead_piece, lead_kind, said_markers, items, closer, rng):
    """Stray full stops and commas where a speaker paused: "One. Go to the shops.", items joined
    with commas, a marker with no comma after it, a full stop inside an item."""
    changes = rng.sample(["marker-stop", "comma-join", "bare-marker", "lead-comma", "stop-in-item"], 2)
    pieces = lead_piece("," if "lead-comma" in changes and lead_kind == "sentence" else ".")
    split_item = rng.randrange(len(items))
    for index, (marker, item) in enumerate(zip(said_markers, items)):
        last = index == len(items) - 1
        end = "," if "comma-join" in changes and not last else "."
        if "marker-stop" in changes and index == 0:
            pieces.append((marker, "."))
            head = ""
        elif "bare-marker" in changes and index > 0:
            head = f"{marker} "
        else:
            head = f"{marker}, "
        words = item.split()
        # A pause after a content word, never after "the", "to" or a number.
        cuts = [cut for cut in range(3, len(words) - 1) if words[cut - 1].lower() not in PAUSE_NEVER_AFTER]
        if "stop-in-item" in changes and index == split_item and cuts:
            cut = rng.choice(cuts)
            pieces.append((head + " ".join(words[:cut]), "."))
            pieces.append((" ".join(words[cut:]), end))
        else:
            pieces.append((head + item, end))
    if closer:
        pieces.append((closer[:-1], closer[-1]))
    return assemble(pieces)


# MARK: - Placeholders

# A token alone, as the app sends a protected address or link: the text stays exactly as it is.
ALONE = ["⟦S1⟧.", "⟦S1⟧", "⟦S1⟧ ⟦S2⟧", "⟦S1⟧, ⟦S2⟧.", "⟦S1⟧ and ⟦S2⟧.", "⟦S1⟧ or ⟦S2⟧"]
ALONE_TEST = "⟦S1⟧ or ⟦S2⟧"

# A token at the very start: the sentence's subject (the next word stays lower case), or a token
# on its own followed by a sentence.
STARTS = [
    "⟦S1⟧ is my new address.",
    "⟦S1⟧ is my new email address, so please use that from now on.",
    "⟦S1⟧ is the link for tomorrow's meeting.",
    "⟦S1⟧ has the slides from the workshop.",
    "⟦S1⟧ should work now, but tell me if it doesn't.",
    "⟦S1⟧ was my old address, so don't send anything there.",
    "⟦S1⟧ and ⟦S2⟧ both need access to the folder.",
    "⟦S1⟧ or ⟦S2⟧, whichever is easier for you.",
    "⟦S1⟧ is where you can download the app.",
    "⟦S1⟧ goes straight to the booking page.",
    "⟦S1⟧. That's the address for the invoices.",
    "⟦S1⟧. Please send the photos there.",
    "⟦S1⟧ for the tickets and ⟦S2⟧ for the timetable.",
    "⟦S1⟧ is the support address if the login fails again.",
    "⟦S1⟧ takes you to the sign-up form.",
    "⟦S1⟧ has the map and the parking details.",
    "⟦S1⟧. Could you add this to the shared notes?",
    "⟦S1⟧ is the one to use for anything about payroll.",
    "⟦S1⟧ is our team inbox, not my personal one.",
    "⟦S1⟧ will be live from Monday.",
    "⟦S1⟧ is the recording of last week's call.",
    "⟦S1⟧ is the form for the school trip, and it's due on Friday.",
    "⟦S1⟧ works on a phone as well as a laptop.",
    "⟦S1⟧ is still the best way to reach me.",
    "⟦S1⟧ doesn't open for me. Can you check it?",
    "⟦S1⟧ has all the photos from the wedding.",
    "⟦S1⟧ is the address the courier needs.",
    "⟦S1⟧ was sent to the whole team this morning.",
    "⟦S1⟧. I think that's the right one.",
    "⟦S1⟧ is the new booking link, and the old one no longer works.",
    "⟦S1⟧ is for the parents and ⟦S2⟧ is for the staff.",
    "⟦S1⟧ replaces the address on the old letterhead.",
    "⟦S1⟧ needs a password, which I'll text you.",
]

TOKEN = re.compile(r"⟦S\d+⟧")


def odd_placeholder_raw(target, rng):
    """A pause written as a full stop: after a token that starts the sentence ("⟦S1⟧. Is my new
    address."), or else inside the sentence."""
    words = target.split(" ")
    if TOKEN.fullmatch(words[0]) and len(words) > 1 and words[1][:1].islower():
        return f"{words[0]}. {capitalised(' '.join(words[1:]))}"
    # A stop after a word in the middle, not next to a token or another mark.
    places = [i for i in range(2, len(words) - 2)
              if words[i][-1].isalpha() and not TOKEN.search(words[i]) and not TOKEN.search(words[i + 1])]
    if not places:
        return target.rstrip(".")
    cut = rng.choice(places)
    return " ".join(words[:cut] + [words[cut] + "."] + [capitalised(words[cut + 1])] + words[cut + 2:])


def placeholder_rows(template, rng):
    """The template as a good recognizer writes it, unpunctuated, and with a stray full stop."""
    rows = [("cased", template, template)]
    if rng.random() < 0.3 and template.endswith("."):
        rows.append(("cased", template[:-1], template))
    rows.append(("unpunctuated", unpunctuated_keeping_tokens(template), without_stop_after_token(template)))
    rows.append(("odd", odd_placeholder_raw(template, rng), template))
    return rows


def without_stop_after_token(text):
    """``text`` with no full stop after a token that stands before its own sentence: Deep's other
    placeholder examples add no mark next to a token ("⟦S1⟧ the bus was late" becomes "⟦S1⟧ The
    bus was late."), so a stop stays only where the recognizer wrote one."""
    return re.sub(r"^(⟦S\d+⟧)\. ", r"\1 ", text)


def unpunctuated_keeping_tokens(text):
    lowered = unpunctuated(text)
    # Tokens are written S1, S2 … in upper case.
    return re.sub(r"⟦s(\d+)⟧", r"⟦S\1⟧", lowered)


# MARK: - Writing


def row(category, raw, target, multiline):
    return {
        "category": category,
        "context": [],
        "letterBody": False,
        "multiline": multiline,
        "raw": raw,
        "source": f"e:{FAMILY}",
        "target": target,
    }


def split_of(count, test, valid, rng):
    """Each template's split: `test` and `valid` of them held out, the rest for training."""
    order = list(range(count))
    rng.shuffle(order)
    splits = {}
    for position, index in enumerate(order):
        splits[index] = "test" if position < test else ("valid" if position < test + valid else "train")
    return splits


def generate():
    rng = random.Random(SEED)
    rows = {"train": [], "valid": [], "test": []}
    seen = set()
    forms = {"cased": 0, "unpunctuated": 0, "odd": 0}

    layout_splits = split_of(len(SCENARIOS), LAYOUT_TEST_SCENARIOS, LAYOUT_VALID_SCENARIOS, rng)
    for index, scenario in enumerate(SCENARIOS):
        made = 0
        for _ in range(LAYOUT_ROWS_PER_SCENARIO * 6):
            if made == LAYOUT_ROWS_PER_SCENARIO:
                break
            form, raw, target = layout_row(scenario, rng)
            if raw in seen:
                continue
            seen.add(raw)
            forms[form] += 1
            rows[layout_splits[index]].append(row("series", raw, target, True))
            made += 1

    placeholder_splits = split_of(len(STARTS), PLACEHOLDER_TEST_TEMPLATES, PLACEHOLDER_VALID_TEMPLATES, rng)
    for text in ALONE:
        if text in seen:
            continue
        seen.add(text)
        forms["cased"] += 1
        # "⟦S1⟧." and "⟦S1⟧" read the same without punctuation, so only a text unlike the others is held out.
        split = "test" if text == ALONE_TEST else "train"
        rows[split].append(row("placeholder", text, text, rng.random() < 0.3))
    for index, template in enumerate(STARTS):
        for form, raw, target in placeholder_rows(template, rng):
            if raw in seen:
                continue
            seen.add(raw)
            forms[form] += 1
            rows[placeholder_splits[index]].append(row("placeholder", raw, target, rng.random() < 0.3))
    return rows, forms


def main():
    rows, forms = generate()
    OUT.mkdir(parents=True, exist_ok=True)
    for split, items in rows.items():
        path = OUT / f"{FAMILY}-{split}.jsonl"
        with path.open("w", encoding="utf-8") as handle:
            for item in items:
                handle.write(json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
        by_category = {}
        for item in items:
            by_category[item["category"]] = by_category.get(item["category"], 0) + 1
        print(f"{path.relative_to(ROOT)}: {len(items)} rows {by_category}")
    total = sum(forms.values())
    print("raw forms: " + ", ".join(f"{name} {count / total:.0%}" for name, count in forms.items()))


if __name__ == "__main__":
    main()
