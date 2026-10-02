#!/usr/bin/env python3
"""Dictations written the way speech-to-text writes them, for transcript_seeds in the rules file.

They hold what a voice can't carry through TTS, because a synthetic voice says the word right and
the recognizer then writes it right:
- a common word the recognizer writes as a name ("We need to Harry", for hurry);
- letters it spells out ("the B B C");
- a word the speaker starts, stops and says in full ("We should con- consider the price"), which a
  synthetic voice can't stutter on cue.

Controls keep a name where it is one, keep letters that aren't an acronym, and keep a short word
followed by a word it starts when both are meant ("we were", "the car carpet"). The seeds are
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

# Word fragments: the speaker starts a word, stops and says it in full. The recognizer writes the
# piece as a word of its own, sometimes with a hyphen ("con consider", "con- consider"), and the
# answer drops it. Each sentence marks the word the speaker stumbled on as [word]; a template's
# rows differ only in how the recognizer wrote the stumble.
FRAGMENTS = [
    "Could you [confirm] the booking for next week?",
    "I'd [recommend] the fish if you like seafood.",
    "Please [schedule] a call with the supplier.",
    "The shop wants to see the [receipt] before they swap it.",
    "Can you [collect] the parcel from the post office?",
    "We need more [information] about the new parking rules.",
    "I'll [cancel] the order and buy it in the shop instead.",
    "Could you [explain] the bill to me again?",
    "Is the meeting room [available] on Thursday afternoon?",
    "I can't [remember] where I parked.",
    "It's really [important] that the back door stays locked.",
    "Who's going to [organise] the leaving drinks?",
    "The [insurance] renewal came through this morning.",
    "There's a [problem] with the washing machine again.",
    "I'm [definitely] coming to the barbecue.",
    "Have you made a [reservation] for dinner?",
    "The [temperature] dropped a lot overnight.",
    "Put the school play in the [calendar].",
    "The [electricity] went off for an hour last night.",
    "Our [neighbours] are having a party on Saturday.",
    "The [kitchen] tap is dripping again.",
    "I left my bike in the [garage].",
    "I need to pick up a [prescription] from the [pharmacy].",
    "The [library] closes early on Sundays.",
    "The [weather] looks better for the weekend.",
    "The [mechanic] said the brakes are fine.",
    "I've booked an [appointment] with the [dentist].",
    "Did the [invoice] go out yesterday?",
    "A [customer] left her scarf at the counter.",
    "The [delivery] should arrive before lunch.",
    "Let's [discuss] it after the holidays.",
    "We still have to [decide] on a colour for the hall.",
    "Can you [describe] what the noise sounds like?",
    "Could I [suggest] a different restaurant?",
    "I'll [prepare] the spare room for your parents.",
    "The band has [practice] on Tuesday evenings.",
    "The roads are [especially] busy near the school.",
    "It's [basically] the same phone with a better camera.",
    "You'll need your birth [certificate] for the passport.",
    "Make sure your driving [licence] hasn't expired.",
    "We should [measure] the window before we order blinds.",
    "Can you [replace] the bulb in the hallway?",
    "You have to [register] the car in your own name.",
    "Check the [ingredients] for nuts before you buy it.",
    "Put the letter in a stamped [envelope].",
    "The [vegetables] need a few more minutes.",
    "Let's order the [groceries] online this week.",
    "The new [furniture] arrives on Friday.",
    "All the [equipment] at the gym is brand new.",
    "Call me if there's an [emergency] while I'm away.",
    "My [headphones] stopped working on the train.",
    "The [battery] on my phone drains really fast.",
    "Have you seen my phone [charger]?",
    "The [printer] upstairs is out of paper.",
    "I forgot the [password] for the wifi again.",
    "The job [application] closes at the end of the month.",
    "The [deadline] for the essay has moved.",
    "Can you get an [estimate] for fixing the roof?",
    "My [interview] went better than I expected.",
    "Ask the [manager] if we can [return] it.",
    "Her [presentation] was the best of the day.",
    "I've shared the [spreadsheet] with the whole team.",
    "My bank [statement] still shows the old address.",
    "The bank will [transfer] the money on Friday.",
    "We're looking for a [volunteer] to run the cake stall.",
    "The [committee] meets at the start of every month.",
    "We tried to [negotiate] a lower rent.",
    "It's a great [opportunity] for the kids.",
    "The exam was more [difficult] than last year.",
    "They'll [eventually] fix the lift.",
    "We need to leave [immediately] after the ceremony.",
    "The [laundry] is still damp.",
    "The [thermostat] in the hall is broken.",
    "The [plumber] can't come until next week.",
    "The [electrician] fixed the lights in the garden.",
    "The [builder] sent us photos of the new wall.",
    "The [gutters] are full of leaves again.",
    "My [physio] wants me to walk every day.",
    "Bring a warm [sweater] for the boat trip.",
    "Take an [umbrella], it's going to pour.",
    "There's no room in the car for more [luggage].",
    "The travel agent emailed the [itinerary] this morning.",
    "The [traffic] on the bridge was [terrible].",
    "We missed the exit at the [roundabout].",
    "It's our wedding [anniversary] next month.",
    "We're planning a [surprise] party for her.",
    "Can you put up the [decorations] before the guests arrive?",
    "The boiler is due for its [maintenance] check.",
    "The fridge is still under [warranty].",
    "I'd like to make a [complaint] about the noise.",
    "I want to [apologise] for the [confusion].",
    "The hotel was really [expensive] for what it was.",
    "The food at the wedding was [excellent].",
    "That's [exactly] what I was going to say.",
    "I'm [exhausted] after the long drive.",
    "The [entrance] is round the back of the building.",
    "We had a lovely [evening] at the theatre.",
    "I'll make [breakfast] while you get dressed.",
    "I found a great [recipe] for lentil soup.",
    "Peel the [potatoes] and put them in the pan.",
    "The [cinema] near us is closing down.",
    "The [concert] was called off because of the storm.",
    "She has an [audition] for the school play.",
    "Our [landlord] finally fixed the boiler.",
    "Did you get the [deposit] back from the flat?",
    "The [broadband] keeps dropping in the evenings.",
    "Set a [reminder] to water the plants.",
    "Turn the [volume] down a bit, please.",
    "The [cupboard] under the stairs is full.",
    "The [recycling] goes out on Thursday.",
    "Your [symptoms] sound like a bad cold.",
    "Please sign the [contract] and send it back.",
    "[Consider] taking the earlier train.",
    "[Remember] to bring a jacket, it gets cold by the river.",
    "[Unplug] the heater before you go out.",
    "[Apparently] the shop is shut on Mondays.",
    "[Honestly], I didn't mind the wait.",
    "[Tomorrow] I'll sort out the [paperwork].",
]

# The pieces a speaker stops after, for each [word], spelled as the recognizer writes the sound
# ("kit", not "kitc"). Some are words too ("con", "head"), but none makes sense before its word
# ("the cup cupboard" would, so that piece is "cu"). None is a filler the rules remove before
# cleanup ("er", "um"), and none is a short word kept in WHOLE_WORDS.
PIECES = {
    "confirm": ["con", "conf"], "recommend": ["rec", "reco"], "schedule": ["sch", "sche"],
    "receipt": ["rece"], "collect": ["col", "coll"], "information": ["inf"], "cancel": ["canc"],
    "explain": ["ex", "exp"], "available": ["av", "avai"], "remember": ["rem", "reme"],
    "important": ["imp", "impo"], "organise": ["org", "orga"], "insurance": ["ins", "insu"],
    "problem": ["pro", "prob"], "definitely": ["def", "defi"], "reservation": ["res", "rese"],
    "temperature": ["tem"], "calendar": ["cal", "cale"], "electricity": ["elec"],
    "neighbours": ["nei"], "kitchen": ["ki", "kit"], "garage": ["ga", "gara"],
    "prescription": ["pre", "pres"], "pharmacy": ["phar"], "library": ["li"],
    "weather": ["wea"], "mechanic": ["mec"], "appointment": ["ap", "appo"], "dentist": ["de"],
    "invoice": ["inv", "invo"], "customer": ["cus", "cust"], "delivery": ["del", "de"],
    "discuss": ["di"], "decide": ["dec", "deci"], "describe": ["des"],
    "suggest": ["sug"], "prepare": ["pre"], "practice": ["prac"],
    "especially": ["esp", "espe"], "basically": ["bas", "basi"], "certificate": ["cer", "cert"],
    "licence": ["lic"], "measure": ["mea", "meas"], "replace": ["repl"], "register": ["reg", "regi"],
    "ingredients": ["ing"], "envelope": ["env", "enve"], "vegetables": ["vege"],
    "groceries": ["gro", "groc"], "furniture": ["furn"], "equipment": ["equ", "equi"],
    "emergency": ["em", "emer"], "headphones": ["head"], "battery": ["bat"], "charger": ["cha"],
    "printer": ["pri", "prin"], "password": ["pas"], "application": ["app"], "deadline": ["dea"],
    "estimate": ["est", "esti"], "interview": ["int"], "manager": ["mana"], "return": ["ret"],
    "presentation": ["pre", "pres"], "spreadsheet": ["spre"], "statement": ["sta"],
    "transfer": ["tra", "tran"], "volunteer": ["vol", "volu"], "committee": ["comm"],
    "negotiate": ["neg", "nego"], "opportunity": ["opp", "oppo"], "difficult": ["dif"],
    "eventually": ["ev"], "immediately": ["imm", "imme"], "laundry": ["lau", "laun"],
    "thermostat": ["ther"], "plumber": ["plu"], "electrician": ["elec"], "builder": ["bui", "buil"],
    "gutters": ["gut"], "physio": ["phy", "phys"], "sweater": ["swe", "swea"],
    "umbrella": ["umb"], "luggage": ["lug"], "itinerary": ["itin"], "traffic": ["tra", "traf"],
    "terrible": ["ter", "terr"], "roundabout": ["rou", "roun"], "anniversary": ["anni"],
    "surprise": ["sur", "surp"], "decorations": ["dec", "deco"], "maintenance": ["mai"],
    "warranty": ["war"], "complaint": ["com", "comp"], "apologise": ["apo", "apol"],
    "confusion": ["conf"], "expensive": ["ex", "exp"], "excellent": ["exc", "exce"],
    "exactly": ["exa", "exac"], "exhausted": ["exh", "exha"], "entrance": ["ent"],
    "evening": ["ev"], "breakfast": ["bre"], "recipe": ["reci"], "potatoes": ["pota"],
    "cinema": ["cin", "cine"], "concert": ["conc"], "audition": ["aud"], "landlord": ["lan"],
    "deposit": ["dep", "depo"], "broadband": ["bro"], "reminder": ["remi"], "volume": ["vol"],
    "cupboard": ["cu"], "recycling": ["recy"], "symptoms": ["sym", "symp"], "contract": ["con", "cont"],
    "consider": ["con", "cons"], "unplug": ["un"], "apparently": ["ap", "appa"], "honestly": ["hon"],
    "tomorrow": ["tomo"], "paperwork": ["pape"],
}

# A short word followed by a word it starts, where both are meant: kept as said.
WHOLE_WORDS = [
    "We were late because of the roadworks.", "I need an answer by the end of the week.",
    "The film ended so soon.", "The car carpet needs a good clean.", "Let's move the call to tomorrow.",
    "I can cancel the order if it's late.", "He helped me move the sofa.",
    "Bring her here when she's ready.", "It would be better to wait.",
    "We went to the theatre on Saturday.", "She's out of office until Monday.",
    "Let us use the meeting room.", "Would you like tea or orange juice?",
    "Measure it in inches, not centimetres.", "Sign the form in ink.", "Do dogs like carrots?",
    "The man managed to fix it himself.", "Park the car carefully, the space is tight.",
    "Let me meet them before we decide.", "We're all allergic to cats.",
    "It will be beautiful in the spring.", "His history teacher is really strict.",
    "Thanks for forwarding the email.", "Sorry for forgetting your birthday.",
    "There are no notes from the meeting.", "Can you add addresses to the guest list?",
    "We use user feedback to plan updates.", "We drove to town for the market.",
    "Try not to touch the wet paint.", "Let's go golfing on Sunday.", "The blanket is so soft.",
    "He headed home after the match.", "We stayed in a hot hotel room with no fan.",
    "The cat catches mice in the barn.", "I'm so sorry about the mix-up.",
    "We heard an announcement about the delay.", "We visited an ancient castle on a hill.",
    "You can call or order online.", "Turn the thermostat down at night.",
    "We were warned about the ice.", "She bought an antique clock.",
    "He heard the news on the radio.", "That might be because of the rain.",
    "A lot of offers end today.", "We wear coats even in May.", "It itches where the plaster was.",
    "I'll ask him to come in instead.", "Plant the seeds in individual pots.",
    "Add it to today's list.", "I want to toast the happy couple.", "She wants to tour the old mill.",
    "Remind me to top up the meter.", "The bar barely had room to stand.",
    "I feel so sore after the gym.", "She is isolated at home with flu.",
    "The newsletter is issued every month.", "We saw an animal in the road.",
    "He has an ankle injury from football.", "The boiler needs an annual check.",
    "He hears better with his left ear.", "Her herb garden is lovely.",
    "I'll be beside you the whole time.", "He held the door for us.",
    "I'll do double shifts next week.", "The theory sounds fine to me.",
    "Turn the theme music up a bit.", "Please add additional notes to the report.",
    "Did you read the new newsletter yet?", "Please re-read the contract before you sign.",
    "Bring a pen, pencil and paper to the exam.", "The main maintenance window is on Sunday night.",
    "We won wonderful prizes at the fair.", "The new news app is easier to read.",
    "She was the key keynote speaker at the conference.", "The sales rep reported a fault with the order.",
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


def neighbour(text, index, pool=NEUTRAL):
    """A neutral sentence from ``pool`` said before or after ``text``."""
    other = pool[int(digest("neutral", text, index)[:8], 16) % len(pool)]
    return (other, text) if int(digest("order", text)[:2], 16) % 2 else (text, other)


# Hesitations the rules remove before cleanup (FillerRemover.standardFillers): never a piece.
FILLERS = {"um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "hmmm"}

# Fragment rows hold no numbers, so they can't teach dropping a short word before a list number
# ("one, go to the shops") and don't depend on how the number rules write one; their neutral
# sentences hold none either.
NUMBER_WORDS = re.compile(r"\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|first|second|third|\d+)\b", re.I)
WORDS_ONLY = [text for text in NEUTRAL if not NUMBER_WORDS.search(text)]


def words_of(text):
    return re.findall(r"[a-z']+", text.lower())


def whole_word_pairs(text):
    """Short words (four letters at most) said before a word they start, as in "we were"."""
    words = words_of(text)
    return [(first, second) for first, second in zip(words, words[1:])
            if len(first) <= 4 and len(second) > len(first) and second.startswith(first)]


def stumbled(template, form, choice):
    """``template`` as the recognizer writes a speaker who stops after a piece of each [word]: the
    piece as a word of its own, "plain" ("con consider") or with a "hyphen" ("con- consider").
    At a sentence start the piece takes the capital, as the recognizer writes it."""
    def written(match):
        word = match.group(1)
        pieces = PIECES[word.lower()]
        piece = pieces[int(digest(template, word, choice)[:8], 16) % len(pieces)]
        if word[0].isupper():
            piece, word = piece.capitalize(), word[0].lower() + word[1:]
        return f"{piece}{'-' if form == 'hyphen' else ''} {word}"
    return re.sub(r"\[(\w+)\]", written, template)


def unpunctuated(text):
    """``text`` as a recognizer writes it with no capitals and no punctuation."""
    return re.sub(r"[.,?!;:]|(?<=\w)-(?= )", "", text).lower()


def fragment_seeds():
    """Each FRAGMENTS sentence as the recognizer writes the stumble, with its answer: cased with the
    piece plain or hyphenated, often again in another form (no capitals or punctuation, or the
    other way of writing the piece), and now and then beside a neutral sentence."""
    whole = {first for text in WHOLE_WORDS for first, _ in whole_word_pairs(text)}
    rows = []
    for template in FRAGMENTS:
        assert template.split()[0].strip("[],") not in NAME_FOR.values() and not NUMBER_WORDS.search(template), template
        group = f"word-fragment:{template}"
        target = re.sub(r"\[(\w+)\]", r"\1", template)
        for word in re.findall(r"\[(\w+)\]", template):
            for piece in PIECES[word.lower()]:
                assert 2 <= len(piece) <= 4 and len(word) - len(piece) >= 2 and word.lower().startswith(piece), (word, piece)
                assert piece not in FILLERS and piece not in whole, (word, piece)
        form = "hyphen" if int(digest("form", template)[:8], 16) % 10 < 3 else "plain"
        rows.append(row(stumbled(template, form, 0), target, "recognition", group))
        variant = int(digest("variant", template)[:8], 16) % 10
        if variant < 4:
            rows.append(row(unpunctuated(stumbled(template, "plain", 1)), target, "recognition", group))
        elif variant < 8:
            rows.append(row(stumbled(template, "plain" if form == "hyphen" else "hyphen", 1), target, "recognition", group))
        if int(digest("neighbour", template)[:8], 16) % 8 == 0:
            raw = stumbled(template, form, 2)
            before, after = neighbour(raw, 0, WORDS_ONLY)
            joined_target = " ".join(target if part == raw else part for part in (before, after))
            rows.append(row(f"{before} {after}", joined_target, "recognition", group))
    for text in WHOLE_WORDS:
        assert whole_word_pairs(text) and not NUMBER_WORDS.search(text), text
        group = f"whole-word:{text}"
        rows.append(row(text, text, "unchanged", group))
        if int(digest("unpunctuated", text)[:8], 16) % 10 < 4:
            rows.append(row(unpunctuated(text), text, "unchanged", group))
        if int(digest("neighbour", text)[:8], 16) % 6 == 0:
            before, after = neighbour(text, 0, WORDS_ONLY)
            rows.append(row(f"{before} {after}", f"{before} {after}", "unchanged", group))
    return rows


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
    return rows + fragment_seeds()


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
