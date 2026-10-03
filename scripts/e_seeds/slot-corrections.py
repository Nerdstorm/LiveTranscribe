#!/usr/bin/env python3
"""Corrections inside one slot of a sentence, for Deep candidate E ("the boats problem").

Candidate D resolves most corrections within a sentence, but loses the words before the slot when
the cue sits between a word and its replacement and the clause carries on after it:
"the cost of parking no wait petrol has doubled" became "Petrol has doubled." The right answer
keeps the words said before the slot and swaps only what was taken back: "The cost of petrol has
doubled."

Two kinds of examples, both in the `same-sentence` category:
- slot replacements: lead words that don't finish a clause ("the cost of", "flights to", "the"),
  the retracted word X, a cue, its replacement Y of the same kind, then the rest of the clause.
  The answer is the lead, Y and the rest. The speaker may say the last lead words again with Y
  ("flights to Rome, no, to Madrid"), which changes nothing.
- true restarts, as a contrast: the speaker says the clause again from its start, or replaces it
  with a clearly parallel one, so everything before the cue goes: "the price of apples has gone
  up sorry the price of pears has gone up" → "The price of pears has gone up."

Raw text comes in the forms the recognizer writes: cased and punctuated, lowercase without
punctuation, and cased with a full stop or comma where the speaker paused. A full stop after the
lead words doesn't finish the clause, so the answer still splices.

Every sentence is generic English written for this file. None comes from anyone's dictation.
No number words are used, so these rows say nothing about how numbers or spoken numbered lists
("one, go to the shops, two, ...") are written. Output is deterministic. All rows of a template go
to one split, so the test rows are sentences the adapter never saw.

Usage:
    scripts/e_seeds/slot-corrections.py --guard GUARD [--check]

GUARD runs Deep's check (the Rust port's OutputGuard at Deep) on {"raw", "cleaned", "multiline"}
lines, printing one verdict a line; the rows whose target it rejects are left out, since Deep would
only fall back to Standard on them. The written files were made with it. --check then compares the
raw texts with the held-out sets and checks the gate's keep and avoid words.
"""

import argparse
import json
from pathlib import Path
import random
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent.parent
TRAINING = ROOT / "Packages/LiveTranscribeKit/Training"
OUT = TRAINING / "generated-e"
FAMILY = "slot-corrections"
GATE = TRAINING / "eval" / f"{FAMILY}.jsonl"
SEED = 20261002
# The most words Deep's check lets a correction take back before its cue (guard-policy.json's
# maxRetractedWords). A clause replaced by another is no longer than this; one said again from
# its start may be.
MAX_RETRACTED = 6

# Held-out sets no raw text here may repeat (compared lowercase, without punctuation).
HELD_OUT = [
    TRAINING / "generated/test.jsonl",
    TRAINING / "prepared/deep-measured/test.jsonl",
    TRAINING / "prepared/deep-measured-d/test.jsonl",
]

# MARK: - Pools

# Values of one kind, written as they are in the finished text. Every value of a kind has the same
# grammatical number, so the rest of a clause agrees with whichever one is said.
POOLS = {
    "city": ["Madrid", "Lisbon", "Oslo", "Dublin", "Vienna", "Prague", "Leeds", "York", "Bristol",
             "Glasgow", "Cardiff", "Porto", "Berlin", "Munich", "Lyon", "Seville", "Naples", "Bergen",
             "Galway", "Bath", "Brighton", "Hamburg", "Zurich", "Geneva", "Krakow", "Florence", "Milan",
             "Valencia", "Edinburgh", "Belfast"],
    "name": ["Tom", "Sara", "Ava", "Eli", "Ivy", "Otto", "Ines", "Anya", "Kofi", "Amara", "Nia", "Ravi",
             "Mei", "Yuki", "Lena", "Mateo", "Omar", "Leila", "Zara", "Ewan", "Rhys", "Divya", "Ezra",
             "Pia", "Teo", "Cleo", "Nuno", "Bea", "Kai", "Dara", "Asha", "Enzo", "Femi", "Hana", "Jonas",
             "Maya", "Felix", "Rosa", "Hugo"],
    "relative": ["my sister", "my brother", "my aunt", "my uncle", "my cousin", "my neighbour", "my dad",
                 "my mum", "my nephew", "my niece", "my grandmother", "my grandad"],
    "food": ["apples", "pears", "lemons", "tomatoes", "onions", "potatoes", "carrots", "grapes", "oranges",
             "cherries", "mushrooms", "peppers", "strawberries", "plums", "bananas", "peaches", "limes"],
    "staple": ["coffee", "tea", "milk", "flour", "sugar", "rice", "butter", "cheese", "bread", "pasta",
               "cereal", "juice"],
    "expense": ["parking", "petrol", "electricity", "heating", "childcare", "broadband", "diesel", "gas",
                "water", "rent"],
    "vehicle": ["bikes", "vans", "trucks", "buses", "trams", "taxis", "cars", "trains", "motorbikes",
                "coaches", "lorries", "caravans"],
    "room": ["the kitchen", "the hallway", "the garage", "the attic", "the basement", "the bathroom",
             "the spare room", "the lounge", "the shed", "the laundry", "the dining room", "the study",
             "the nursery", "the porch"],
    "landmark": ["station", "library", "school", "park", "hospital", "market", "church", "stadium",
                 "museum", "bakery", "pharmacy", "post office", "town hall", "cinema", "leisure centre",
                 "bus stop", "harbour", "river"],
    "device": ["printer", "router", "laptop", "projector", "scanner", "monitor", "tablet", "kettle",
               "heater", "dishwasher", "fridge", "microwave", "toaster", "camera", "speaker",
               "washing machine", "doorbell", "smoke alarm"],
    "furniture": ["sofa", "desk", "bookshelf", "wardrobe", "bed", "armchair", "dresser", "bench", "cabinet",
                  "dining table", "cupboard", "stool", "mirror"],
    "doc": ["contract", "invoice", "report", "lease", "quote", "agenda", "budget", "roster", "receipt",
            "proposal", "timetable", "menu", "newsletter", "schedule", "permit", "estimate"],
    "party": ["bank", "lawyer", "landlord", "builder", "accountant", "dentist", "vet", "plumber",
              "electrician", "council", "estate agent", "gardener", "cleaner", "caterer", "photographer",
              "decorator"],
    "color": ["red", "blue", "green", "yellow", "grey", "black", "white", "orange", "purple", "brown",
              "pink", "navy"],
    "size": ["small", "large", "big", "tall", "short", "long", "heavy", "wide", "narrow"],
    # Materials a garden table, a picnic bowl and a photo frame can all be made of.
    "material": ["wooden", "metal", "glass", "plastic", "steel", "bamboo", "aluminium"],
    "clothing": ["jacket", "scarf", "coat", "hat", "umbrella", "jumper", "backpack", "raincoat", "cardigan",
                 "hoodie", "belt"],
    "activity": ["tennis", "football", "swimming", "chess", "yoga", "piano", "dance", "drama", "karate",
                 "netball", "guitar", "hockey", "cricket", "rugby", "ballet", "judo"],
    "subject": ["maths", "history", "science", "French", "art", "music", "geography", "Spanish", "biology",
                "chemistry", "physics", "German", "Italian"],
    "pet": ["dog", "cat", "rabbit", "hamster", "puppy", "kitten", "parrot", "tortoise", "guinea pig",
            "goldfish"],
    "shop": ["bakery", "hardware store", "supermarket", "butcher", "garden centre", "newsagent", "florist",
             "dry cleaner", "chemist", "bookshop", "deli", "greengrocer"],
    "plant": ["roses", "tulips", "lavender", "daffodils", "sunflowers", "ferns", "lilies", "orchids", "bulbs",
              "geraniums", "poppies"],
    "event": ["party", "wedding", "picnic", "barbecue", "fundraiser", "concert", "fair", "festival",
              "quiz", "open day", "book club", "school play", "bake sale", "street party", "reunion"],
    "weekday": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
    "month": ["March", "April", "June", "July", "August", "September", "October", "November"],
    # Narrower kinds, for sentences only some values of a wider kind suit ("the charger for the
    # laptop", not "for the fridge"). No value says "night": Deep's check reads it as a time, which
    # only a time may take back.
    "charged": ["laptop", "tablet", "camera", "speaker", "phone", "headphones", "smartwatch", "drone"],
    "battery": ["laptop", "tablet", "camera", "speaker", "doorbell", "smoke alarm", "phone", "headphones",
                "smartwatch"],
    "gadget": ["printer", "router", "laptop", "projector", "scanner", "monitor", "heater", "speaker", "kettle",
               "fan", "lamp"],
    "transit": ["buses", "trams", "trains", "coaches"],
    "eatery": ["cafe", "pub", "deli", "canteen", "noodle bar", "pizzeria", "bistro", "tea room", "sandwich shop",
               "diner"],
    "building": ["station", "library", "school", "hospital", "market", "church", "stadium", "museum", "bakery",
                 "pharmacy", "post office", "town hall", "cinema", "leisure centre"],
    "attraction": ["museum", "castle", "harbour", "stadium", "farm", "gallery", "lighthouse", "cathedral",
                   "planetarium", "science centre"],
    "lockable": ["the shed", "the garage", "the attic", "the basement", "the study", "the spare room",
                 "the cellar", "the summer house"],
    "view_room": ["the attic", "the spare room", "the study", "the landing", "the kitchen", "the lounge",
                  "the nursery", "the top floor"],
    "eating_room": ["the kitchen", "the dining room", "the lounge", "the garden", "the conservatory"],
    "fruit": ["apples", "pears", "grapes", "oranges", "cherries", "strawberries", "plums", "bananas", "peaches"],
    "sown": ["sunflowers", "poppies", "lavender", "sweet peas", "marigolds", "cornflowers", "nasturtiums",
             "foxgloves"],
    "trade": ["builder", "plumber", "electrician", "decorator", "gardener", "caterer", "photographer", "cleaner",
              "roofer"],
    "fixer": ["landlord", "plumber", "builder", "council", "estate agent", "roofer", "handyman"],
    "ticketed": ["concert", "festival", "fair", "quiz", "school play", "fundraiser", "talent show",
                 "comedy show"],
    "occasion": ["party", "wedding", "reunion", "christening", "prize giving", "dinner dance", "fundraiser",
                 "engagement party", "gala"],
    "gathering": ["party", "barbecue", "picnic", "reunion", "book club", "bake sale", "quiz"],
}
POOLS["surface"] = [item for item in POOLS["furniture"] if item != "mirror"]
POOLS["name_pos"] = [name + "'s" for name in POOLS["name"]]
POOLS["relative_pos"] = [relative + "'s" for relative in POOLS["relative"]]

# MARK: - Slot templates

# (lead, kind, rest, back, question). The lead is said once, before the slot; the rest follows the
# replacement. `back` is how many of the lead's last words the speaker may say again with the
# replacement ("near the station, no, near the library"). An empty lead puts the slot first.
SLOTS = [
    # A noun and a preposition before the slot, the shape candidate D loses.
    ("The cost of", "expense", "has doubled this year", 1, False),
    ("The price of", "food", "has gone up this month", 1, False),
    ("Flights to", "city", "are cheaper in the spring", 1, False),
    ("The train to", "city", "was cancelled this morning", 1, False),
    ("Parking near the", "landmark", "is free on Sundays", 2, False),
    ("The queue at the", "shop", "was really long today", 2, False),
    ("The meeting with the", "party", "has been moved to Thursday", 2, False),
    ("The key to", "lockable", "is under the mat", 1, False),
    ("The noise from", "room", "kept us awake", 1, False),
    ("The lights in", "room", "keep flickering", 1, False),
    ("The road to", "city", "is closed for repairs", 1, False),
    ("A parcel for", "name", "arrived this morning", 1, False),
    ("The charger for the", "charged", "is missing again", 2, False),
    ("The manual for the", "device", "is in the top drawer", 2, False),
    ("Fees for", "activity", "lessons are due on Friday", 1, False),
    ("Demand for", "vehicle", "has dropped this year", 1, False),
    ("Sales of", "vehicle", "rose sharply last quarter", 1, False),
    ("The forecast for", "city", "looks wet all week", 1, False),
    ("Hotels in", "city", "are fully booked that weekend", 1, False),
    ("The school near the", "landmark", "is closing early today", 2, False),
    ("The cafe opposite the", "landmark", "does really good coffee", 2, False),
    ("The path behind the", "landmark", "is too muddy to use", 2, False),
    ("The venue for the", "occasion", "is already booked", 2, False),
    ("The dress code for the", "occasion", "is smart casual", 2, False),
    ("Tickets for the", "ticketed", "sold out in an hour", 2, False),
    ("The smell in", "room", "is coming from the drain", 1, False),
    ("Repairs to", "room", "will take most of the week", 1, False),
    ("The paint for", "room", "is in the boot of the car", 1, False),
    ("The homework for", "subject", "is due tomorrow", 1, False),
    ("The teacher for", "subject", "is off sick this week", 1, False),
    ("The exam in", "subject", "has been moved to the main hall", 1, False),
    ("The food for the", "pet", "is on the top shelf", 2, False),
    ("The vet bill for the", "pet", "came to a lot more than we expected", 2, False),
    ("The bus to the", "building", "is running late", 2, False),
    ("The car park behind the", "landmark", "is closed at weekends", 2, False),
    ("Prices at the", "shop", "have gone up a lot", 2, False),
    ("The owner of the", "eatery", "wants to retire next year", 2, False),
    ("The battery in the", "battery", "needs replacing", 2, False),
    ("The warranty on the", "device", "runs out next month", 2, False),
    ("The guest list for the", "occasion", "is still growing", 2, False),
    ("The flowers for the", "occasion", "are being delivered on Saturday", 2, False),
    ("Seeds for", "sown", "should go in after the frost", 1, False),
    ("The weather in", "city", "has been lovely all week", 1, False),
    ("Rent on the flat in", "city", "is due on Monday", 1, False),
    ("The timetable for the", "transit", "has changed again", 2, False),
    ("The deposit for the", "occasion", "is due next week", 2, False),
    ("The new menu at the", "eatery", "starts on Monday", 2, False),
    ("Is the bus to", "city", "running on time", 1, True),
    ("Has the delivery for", "name", "been signed for", 1, True),
    # A possessive in the slot.
    ("The keys to", "name_pos", "car are on the hook", 1, False),
    ("The party at", "name_pos", "place has been called off", 1, False),
    ("The notes from", "name_pos", "talk are in the shared folder", 1, False),
    ("I'm borrowing", "relative_pos", "trailer for the weekend", 0, False),
    ("", "relative_pos", "car is blocking the drive", 0, False),
    ("", "name_pos", "laptop needs a new battery", 0, False),
    # The slot first, as the subject.
    ("", "relative", "is picking us up from the station", 0, False),
    ("", "name", "is bringing dessert on Saturday", 0, False),
    # An adjective after a determiner.
    ("The", "color", "folder is on the desk", 1, False),
    ("Can you grab the", "size", "box from the top shelf", 1, True),
    ("We bought the", "material", "table for the garden", 1, False),
    ("Pass me the", "color", "pen on the windowsill", 1, False),
    ("The", "size", "suitcase won't fit in the boot", 1, False),
    ("My", "color", "jumper shrank in the wash", 1, False),
    ("Put the", "color", "cushions on the sofa", 1, False),
    ("We need the", "material", "bowls for the picnic", 1, False),
    ("I'd like the", "material", "frame for this photo", 1, False),
    # The slot as an object.
    ("Can you move the", "gadget", "into the study", 1, True),
    ("Please take the", "furniture", "upstairs before the guests arrive", 1, False),
    ("I left my", "clothing", "at the gym", 1, False),
    ("Put the", "food", "in the fridge when you get home", 1, False),
    ("She painted", "room", "over the weekend", 0, False),
    ("We sold the", "furniture", "to a friend of ours", 1, False),
    ("They finally fixed the", "device", "this afternoon", 1, False),
    ("He forgot his", "clothing", "again", 1, False),
    ("Could you print the", "doc", "before the meeting", 1, True),
    ("Send the", "doc", "to the whole team", 1, False),
    ("We're still waiting for the", "doc", "from head office", 2, False),
    ("Can you water the", "plant", "while we're away", 1, True),
    ("Don't forget to feed the", "pet", "before you leave", 1, False),
    ("I need to call the", "fixer", "about the leak", 1, False),
    ("Bring some", "fruit", "for the picnic", 1, False),
    ("We'll need more", "staple", "for the weekend", 1, False),
    ("Could you pick up some", "staple", "on your way home", 1, True),
    ("Ask", "name", "to lock up tonight", 0, False),
    ("I'm lending", "name", "my old bike for the summer", 0, False),
    ("We're inviting", "name", "and their partner to dinner", 0, False),
    ("Let's ask the", "trade", "for another quote", 1, False),
    ("Could you check the", "device", "in the staff room", 1, True),
    ("Let's plant", "plant", "along the fence this year", 0, False),
    # After a preposition, with more of the clause to come.
    ("We're driving to", "city", "after lunch", 1, False),
    ("Can you give the keys to", "name", "tonight", 1, True),
    ("She's moving to", "city", "in the autumn", 1, False),
    ("Let's meet outside the", "building", "at lunchtime", 2, False),
    ("The cat sleeps on the", "surface", "every afternoon", 2, False),
    ("He left his bag in", "room", "this morning", 1, False),
    ("We had lunch at the", "eatery", "near work", 2, False),
    ("I'm taking the kids to", "activity", "practice after school", 1, False),
    ("She signed up for", "activity", "lessons this term", 1, False),
    ("He's really good at", "subject", "this year", 1, False),
    ("We're holding the", "gathering", "in the back garden", 1, False),
    ("The kids are going to", "name_pos", "house after school", 1, False),
    ("I bought these at the", "shop", "on the high street", 2, False),
    ("Our neighbour works at the", "building", "in town", 2, False),
    ("We stayed with", "relative", "over the holidays", 1, False),
    ("The kids want to visit the", "attraction", "this weekend", 2, False),
    ("Meet me at the", "landmark", "after work", 2, False),
    ("The trip to", "city", "has been postponed", 1, False),
    ("A new shop opened next to the", "landmark", "last week", 2, False),
    # A day or a month in the slot.
    ("The market on", "weekday", "has moved indoors", 1, False),
    ("The train on", "weekday", "is fully booked", 1, False),
    ("Our trip in", "month", "has been cancelled", 1, False),
    ("The school fair in", "month", "needs more helpers", 1, False),
    # More of the first shape.
    ("The view from", "view_room", "is lovely in the morning", 1, False),
    ("The receipt for the", "device", "is in my wallet", 2, False),
    ("The lesson after", "subject", "has been cancelled", 1, False),
    ("The photos from the", "event", "are on the shared drive", 2, False),
]

# MARK: - Restart templates

# A clause said once, then again from its start with the slot changed: everything before the cue
# goes. (frame, kind, question)
REPEATS = [
    ("The price of {X} has gone up", "food", False),
    ("We're driving to {X} tomorrow", "city", False),
    ("I left it in {X}", "room", False),
    ("The bus stops near the {X}", "landmark", False),
    ("Can you call the {X} today", "party", True),
    ("I've ordered the {X} curtains", "color", False),
    ("{X} is cooking tonight", "name", False),
    ("Let's meet at the {X}", "landmark", False),
    ("We need more {X}", "staple", False),
    ("The kids want {X} lessons", "activity", False),
    ("Put it on the {X}", "surface", False),
    ("Ask {X} about the keys", "name", False),
    ("The {X} needs cleaning", "device", False),
    ("She's studying {X} at college", "subject", False),
    ("I'll bring the {X} tomorrow", "doc", False),
    ("We're staying in {X} for the week", "city", False),
    ("{X} is visiting next week", "relative", False),
    ("The {X} needs feeding", "pet", False),
    ("The {X} is closed today", "shop", False),
    ("The {X} rang this morning", "party", False),
    ("The {X} sofa is too big", "color", False),
    ("Let's grow {X} this year", "plant", False),
    ("I'm having lunch with {X}", "name", False),
    ("The fridge is full of {X}", "food", False),
    ("We had dinner in {X}", "eating_room", False),
    ("I've lost my {X}", "clothing", False),
    ("The {X} starts at noon", "event", False),
    ("Is the {X} open on Sunday", "shop", True),
    ("The {X} is in the car", "doc", False),
    ("Let's walk to the {X}", "landmark", False),
    ("{X} is driving us home", "relative", False),
    ("Water the {X} tonight", "plant", False),
    ("I'm learning {X} this year", "subject", False),
]

# A clause replaced by a clearly parallel one about the same thing: everything before the cue
# goes. {X} is the same value in both. (first, second, kind)
REPLACES = [
    ("Put the {X} in the garage", "leave it by the front door", "furniture"),
    ("Take the {X} to the tip", "sell it online instead", "furniture"),
    ("Get a taxi to the {X}", "we'll cycle to the {X}", "landmark"),
    ("Call {X} tonight", "send {X} a message tonight", "name"),
    ("Email the {X} today", "phone the {X} today", "party"),
    ("Buy the {X} now", "buy it in the sales", "furniture"),
    ("We'll paint {X} this weekend", "we'll paint it next month", "room"),
    ("I'll pick up the {X}", "can you pick up the {X}", "doc"),
    ("Move the {X} upstairs", "leave the {X} where it is", "furniture"),
    ("Tell {X} to come by car", "tell {X} to come by train", "name"),
    ("Put the {X} in the wash", "wash it by hand", "clothing"),
    ("Turn the {X} off", "unplug the {X}", "gadget"),
    ("We'll drive to {X}", "we'll take the train to {X}", "city"),
    ("Keep the {X} in the hall", "hang it on the back door", "clothing"),
]

# MARK: - Cues

# Cues between a word and its replacement, as a cased transcript writes them inside a sentence and
# after a full stop, with weights.
SLOT_CUES = [
    ("no wait", ["no wait", "no, wait"], "No wait", 3),
    ("wait no", ["wait, no"], "Wait, no", 2),
    ("sorry", ["sorry"], "Sorry", 4),
    ("no sorry", ["no, sorry"], "No, sorry", 3),
    ("i mean", ["I mean"], "I mean", 3),
    ("actually", ["actually"], "Actually", 2),
    ("or rather", ["or rather"], "Or rather", 2),
    ("make that", ["make that"], "Make that", 1),
    ("no", ["no"], "No", 2),
]

RESTART_CUES = [
    ("sorry", ["sorry"], "Sorry", 4),
    ("no sorry", ["no, sorry"], "No, sorry", 3),
    ("no wait", ["no wait", "no, wait"], "No wait", 3),
    ("wait no", ["wait, no"], "Wait, no", 2),
    ("i mean", ["I mean"], "I mean", 2),
    ("actually no", ["actually, no"], "Actually, no", 2),
    ("sorry i mean", ["sorry, I mean"], "Sorry, I mean", 1),
    ("scratch that", ["scratch that"], "Scratch that", 1),
]

# MARK: - Text


def cap(text):
    return text[:1].upper() + text[1:] if text else text


# Values written with a capital wherever they stand.
PROPER = {value for kind in ("name", "city", "subject", "weekday", "month") for value in POOLS[kind]}


def mid_sentence(text):
    """A clause as it reads after a cue inside a sentence: no capital, unless it starts with a name or "I"."""
    first = text.split()[0] if text else ""
    if first == "I" or first.startswith("I'") or first.removesuffix("'s") in PROPER:
        return text
    return text[:1].lower() + text[1:]


def lowercase_speech(text):
    """The text as a recognizer writes it with no casing or punctuation."""
    text = re.sub(r"[.,?!;:]", "", text.lower())
    return re.sub(r"\s+", " ", text).strip()


def normalize(text):
    """Lowercase words without punctuation, for comparing raw texts."""
    text = text.lower().replace("’", "'").replace("-", " ")
    text = re.sub(r"[^\w\s']", " ", text)
    return " ".join(text.split())


# Words that say nothing about what a value is, so a value may share them with its sentence.
FUNCTION_WORDS = {"the", "a", "an", "my", "our", "his", "her", "their", "to", "of", "in", "on", "at", "for",
                  "and", "with", "is", "are", "it"}


def words(text):
    return normalize(text).split()


def content_words(text):
    return {word for word in words(text) if word not in FUNCTION_WORDS}


def join(*parts):
    return " ".join(part for part in parts if part)


def pick_weighted(rng, items):
    total = sum(item[-1] for item in items)
    roll = rng.uniform(0, total)
    for item in items:
        roll -= item[-1]
        if roll <= 0:
            return item
    return items[-1]


def pick_form(rng):
    roll = rng.random()
    return "cased" if roll < 0.5 else "lower" if roll < 0.8 else "odd"


def pick_pair(rng, kind, avoid_words, used):
    """Two different values of a kind, not used together yet, sharing no word with each other or
    with the rest of the sentence."""
    pool = [value for value in POOLS[kind] if not content_words(value) & avoid_words]
    for _ in range(50):
        said, meant = rng.sample(pool, 2)
        if content_words(said) & content_words(meant):
            continue
        if (said, meant) not in used:
            used.add((said, meant))
            return said, meant
    raise RuntimeError(f"no fresh pair for {kind}")


# MARK: - Rows


def slot_row(rng, template, used):
    """A slot replacement as the recognizer writes it, and the answer: lead, Y and rest."""
    lead, kind, rest, back, question = template
    said, meant = pick_pair(rng, kind, content_words(lead) | content_words(rest), used)
    lead_words = lead.split()
    again = rng.choice(range(1, back + 1)) if back and rng.random() < 0.35 else 0
    # Said again after the cue, a lead's first word is mid-sentence: "The red, no, the blue folder".
    restated = join(mid_sentence(" ".join(lead_words[len(lead_words) - again:])) if again else "", meant)
    end = "?" if question else "."
    target = cap(join(lead, meant, rest)) + end
    cue, spoken_forms, opening, _ = pick_weighted(rng, SLOT_CUES)
    form = pick_form(rng)
    spoken_cue = rng.choice(spoken_forms)
    if form == "lower":
        raw = lowercase_speech(join(lead, said, spoken_cue, restated, rest))
    elif form == "cased":
        style = rng.random()
        before = join(lead, said)
        if style < 0.35:
            raw = f"{before}, {spoken_cue}, {join(restated, rest)}{end}"
        elif style < 0.65:
            raw = f"{before}, {spoken_cue} {restated}, {rest}{end}"
        elif style < 0.85:
            raw = f"{before}, {spoken_cue}, {restated}, {rest}{end}"
        else:
            raw = f"{join(before, spoken_cue, restated, rest)}{end}"
        raw = cap(raw) if rng.random() < 0.95 else raw
    else:
        style = rng.random()
        if style < 0.45 and cue != "no":
            raw = f"{cap(join(lead, said))}. {opening}, {join(restated, rest)}{end}"
        elif style < 0.7 and lead:
            raw = f"{cap(lead)}, {said}, {spoken_cue} {join(restated, rest)}{end}"
        else:
            raw = f"{cap(join(lead, said))}, {spoken_cue}. {cap(join(restated, rest))}{end}"
    return raw, target


def restart_row(rng, first, second, first_question, question):
    """A clause said and then started again, as the recognizer writes it, and the answer: the
    second clause alone."""
    end = "?" if question else "."
    target = cap(second) + end
    _, spoken_forms, opening, _ = pick_weighted(rng, RESTART_CUES)
    form = pick_form(rng)
    spoken_cue = rng.choice(spoken_forms)
    if form == "lower":
        raw = lowercase_speech(join(first, spoken_cue, second))
    elif form == "cased":
        if rng.random() < 0.8:
            raw = f"{cap(first)}, {spoken_cue}, {mid_sentence(second)}{end}"
        else:
            raw = f"{cap(join(first, spoken_cue, mid_sentence(second)))}{end}"
    else:
        style = rng.random()
        first_end = "?" if first_question else "."
        if style < 0.7:
            raw = f"{cap(first)}{first_end} {opening}, {mid_sentence(second)}{end}"
        else:
            raw = f"{cap(first)}, {spoken_cue}. {cap(second)}{end}"
    return raw, target


def fill(frame, value):
    return frame.replace("{X}", value)


def row(raw, target, rng):
    return {
        "category": "same-sentence",
        "context": [],
        "letterBody": False,
        "multiline": rng.random() < 0.3,
        "raw": raw,
        "source": f"e:{FAMILY}",
        "target": target,
    }


def generate():
    rng = random.Random(SEED)
    seen = set()
    groups = {"slot": [], "restart": []}

    def add(group, raw, target, kind):
        key = normalize(raw)
        if key in seen:
            return False
        seen.add(key)
        group.append(row(raw, target, rng) | {"kind": kind})
        return True

    for index, template in enumerate(SLOTS):
        rows, used = [], set()
        # Four or five rows a template, about 430 in training.
        while len(rows) < 4 + index % 2:
            raw, target = slot_row(rng, template, used)
            add(rows, raw, target, "slot")
        groups["slot"].append(rows)

    for frame, kind, question in REPEATS:
        rows, used = [], set()
        while len(rows) < 5:
            said, meant = pick_pair(rng, kind, content_words(frame.replace("{X}", "")), used)
            raw, target = restart_row(rng, fill(frame, said), fill(frame, meant), question, question)
            add(rows, raw, target, "restart")
        groups["restart"].append(rows)

    for first, second, kind in REPLACES:
        rows, values = [], [v for v in POOLS[kind]
                            if not content_words(v) & content_words(first + " " + second)
                            and len(words(fill(first, v))) <= MAX_RETRACTED]
        rng.shuffle(values)
        for value in values:
            if len(rows) == 5:
                break
            raw, target = restart_row(rng, fill(first, value), fill(second, value), False, second.startswith("can you"))
            add(rows, raw, target, "restart")
        # A first clause too long for every value would leave its template, and maybe a split, empty.
        if len(rows) < 5:
            sys.exit(f"{first!r} wrote {len(rows)} rows: shorten it to {MAX_RETRACTED} words with its value")
        groups["restart"].append(rows)

    splits = {"train": [], "valid": [], "test": []}
    for name, templates in groups.items():
        order = list(range(len(templates)))
        random.Random(f"{SEED}-{name}").shuffle(order)
        # Test gets about 12% and validation about 10% of training's count.
        n_test = round(len(order) * 0.12 / 1.22)
        n_valid = round(len(order) * 0.10 / 1.22)
        for position, index in enumerate(order):
            split = "test" if position < n_test else "valid" if position < n_test + n_valid else "train"
            splits[split].extend(templates[index])
    for split in splits.values():
        random.Random(f"{SEED}-order-{len(split)}").shuffle(split)
    return splits


def keep_accepted(splits, guard):
    """Leaves out rows whose target Deep's check rejects, which would only ever fall back to
    Standard. `guard` reads {"raw", "cleaned", "multiline"} lines and prints a verdict for each."""
    for split, rows in splits.items():
        lines = "".join(json.dumps({"raw": item["raw"], "cleaned": item["target"], "multiline": item["multiline"]}) + "\n"
                        for item in rows)
        verdicts = subprocess.run([guard], input=lines, capture_output=True, text=True, check=True).stdout.splitlines()
        if len(verdicts) != len(rows):
            sys.exit(f"{guard} gave {len(verdicts)} verdicts for {len(rows)} rows")
        kept = [item for item, verdict in zip(rows, verdicts) if verdict.startswith("Accepted")]
        for item, verdict in zip(rows, verdicts):
            if not verdict.startswith("Accepted"):
                print(f"  left out ({split}, {verdict.split(chr(9))[0]}): {item['raw']}")
        print(f"{split}: Deep's check accepts {len(kept)} of {len(rows)}")
        splits[split] = kept


def write(splits):
    OUT.mkdir(parents=True, exist_ok=True)
    for split, rows in splits.items():
        path = OUT / f"{FAMILY}-{split}.jsonl"
        with path.open("w", encoding="utf-8") as file:
            for item in rows:
                item = {key: value for key, value in item.items() if key != "kind"}
                file.write(json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")


# MARK: - Check


def raws_in(path):
    with path.open(encoding="utf-8") as file:
        return [json.loads(line)["raw"] for line in file if line.strip()]


def contains(text, phrase):
    return f" {normalize(phrase)} " in f" {normalize(text)} "


def check(splits):
    """Leaks into held-out sets, and the gate's own consistency. Returns the number of problems."""
    problems = 0
    ours = {normalize(item["raw"]): split for split, rows in splits.items() for item in rows}
    held = {}
    for path in sorted((TRAINING / "eval").glob("*.jsonl")) + HELD_OUT:
        if path == GATE or not path.exists():
            continue
        for raw in raws_in(path):
            held.setdefault(normalize(raw), path.relative_to(TRAINING))
    leaks = [(raw, ours[raw], held[raw]) for raw in ours if raw in held]
    for raw, split, source in leaks:
        print(f"LEAK {split}: {raw!r} is in {source}")
    problems += len(leaks)
    print(f"rows: {sum(len(rows) for rows in splits.values())}, held-out raws compared: {len(held)}, leaks: {len(leaks)}")

    if not GATE.exists():
        print(f"no gate file at {GATE}")
        return problems + 1
    gate = [json.loads(line) for line in GATE.open(encoding="utf-8") if line.strip()]
    trained = " ".join(f" {normalize(item['raw'])} " for rows in splits.values() for item in rows)
    gate_leaks = shared = 0
    for case in gate:
        if normalize(case["raw"]) in ours:
            print(f"GATE LEAK {case['id']}: raw is a generated row")
            gate_leaks += 1
        for phrase in case["keep"]:
            if not contains(case["target"], phrase):
                print(f"GATE {case['id']}: target lacks keep {phrase!r}")
                problems += 1
        for phrase in case["avoid"]:
            if contains(case["target"], phrase):
                print(f"GATE {case['id']}: target has avoid {phrase!r}")
                problems += 1
            if f" {normalize(phrase)} " in trained:
                print(f"GATE {case['id']}: avoided {phrase!r} is in a generated row")
                shared += 1
        if normalize(case["raw"]) in held:
            print(f"GATE {case['id']}: raw is in {held[normalize(case['raw'])]}")
            gate_leaks += 1
    print(f"gate cases: {len(gate)}, gate leaks: {gate_leaks}, retracted gate words seen in generated rows: {shared}")
    return problems + gate_leaks + shared


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="check for leaks into held-out sets after writing")
    parser.add_argument("--guard", help="a program that runs Deep's check; rows it rejects are left out")
    args = parser.parse_args()
    splits = generate()
    if args.guard:
        keep_accepted(splits, args.guard)
    write(splits)
    for split, rows in splits.items():
        slots = sum(1 for item in rows if item["kind"] == "slot")
        lowercase = sum(1 for item in rows if item["raw"] == lowercase_speech(item["raw"]))
        multiline = sum(1 for item in rows if item["multiline"])
        print(f"{split}: {len(rows)} ({slots} slot replacements, {len(rows) - slots} restarts; "
              f"{lowercase} lowercase without punctuation, {multiline} multiline)")
    if args.check and check(splits):
        sys.exit(1)


if __name__ == "__main__":
    main()
