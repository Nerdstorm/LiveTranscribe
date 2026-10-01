import Foundation

extension DeepLayoutFrames {
    // MARK: - Bullet packs of the test split

    static let bulletPacksTest: [ListPack] = [
        // Noun phrases: podcast equipment
        ListPack(
            intros: [
                "what I need to start the podcast",
                "what I am still short of",
                "the starter kit",
                "the gear list for the studio",
                "{count} items to sort out first",
            ],
            items: [
                "a decent microphone",
                "a pop filter for the mic",
                "a quiet room with soft furnishings",
                "a pair of closed-back headphones",
                "a stable internet connection",
                "editing software for the recordings",
                "a desk stand for the microphone",
                "a simple logo for the cover art",
                "a hosting account for the episodes",
                "a list of guests for the first season",
                "an intro jingle",
                "a short script for each episode",
                "a spare set of batteries for the recorder",
                "a release schedule",
            ]
        ),
        // Noun phrases: hospital appointment
        ListPack(
            intros: [
                "what to take to the hospital",
                "{few} things to bring on the day",
                "what I need to have with me",
                "what to bring for Tuesday's appointment",
                "{count} things for my bag",
            ],
            items: [
                "my referral letter",
                "a list of my current medicines",
                "my insurance card",
                "my health card",
                "a flask of tea",
                "a book for the waiting room",
                "comfortable shoes",
                "a spare phone charger",
                "a notebook for questions",
                "the scan results from last year",
                "a loose jumper",
                "some coins for the car park",
                "my reading glasses",
                "the name of my regular doctor",
            ]
        ),
        // Gerund phrases: food bank duties
        ListPack(
            intros: [
                "what I do at the food bank",
                "my jobs on Saturdays",
                "{few} things I help with",
                "what my shifts involve",
                "what I've signed up for",
            ],
            items: [
                "sorting the donated tins",
                "checking the dates on everything",
                "packing boxes for the families",
                "greeting people at the door",
                "restocking the fresh produce shelf",
                "writing names on the collection slips",
                "loading the van on Fridays",
                "cleaning the prep tables",
                "counting the weekly donations",
                "answering the phone",
                "translating for new arrivals",
                "folding the empty cartons",
                "updating the stock sheet",
                "making tea for the early shift",
            ]
        ),
        // Imperative phrases: cafe closing duties
        ListPack(
            intros: [
                "the closing routine",
                "{few} things to do before you lock up",
                "what to do at the end of your shift",
                "notes for whoever closes",
                "the last jobs of the day",
            ],
            items: [
                "wipe down all the counters",
                "empty the coffee grounds",
                "cover the pastries with film",
                "sweep behind the counter",
                "count the till float",
                "switch off the grill",
                "lift the chairs onto the tables",
                "mop the floor by the door",
                "check the fridge temperature",
                "take the rubbish to the skip",
                "wash the milk jugs",
                "lock the cash drawer",
                "write tomorrow's specials on the board",
                "arm the security system on the way out",
            ]
        ),
        // Short clauses: allotment update
        ListPack(
            intros: [
                "how the allotment is doing",
                "{few} notes from the plot",
                "what I saw at the allotment today",
                "an update on the plot",
                "how things look down at the allotment",
            ],
            items: [
                "the beans are nearly ready",
                "the shed roof leaks in heavy rain",
                "the compost heap is too dry",
                "the slugs have found the lettuces",
                "the water butt is full",
                "the path needs new gravel",
                "the raspberries are coming back well",
                "the neighbouring plot has been abandoned",
                "the gate hinge is rusty",
                "the onions are drying in the sun",
                "the tap runs slowly",
                "the fence needs some new posts",
                "the pumpkins are taking over the corner",
                "the committee wants the weeds under control",
            ]
        ),
    ]

    // MARK: - Openers and closers

    static let openersTrain: [String] = [
        "Hope you are doing well.",
        "Thanks for your message yesterday.",
        "Good to see everyone at the workshop.",
        "I talked to the landlord this morning.",
        "Sorry I missed your call earlier.",
        "The meeting ran long today.",
        "I finally had time to look at this.",
        "Thanks for your patience on this.",
        "We made good progress this week.",
        "I'm writing up my notes from the visit.",
        "Just catching up on my inbox.",
        "I read through everything you sent.",
        "It was a busy day at the office.",
        "Thanks for sending the files over.",
        "The weather has been awful here.",
        "I checked with the others over lunch.",
        "Hello again from the road.",
        "I was on site most of the day.",
        "Thanks, {name}, that helps a lot.",
        "Good news from the school today.",
        "I've had a chance to think it over.",
        "We spoke briefly after the session.",
        "Sorry for the late notice.",
        "The client called me back this morning.",
        "I've finished my review of the contract.",
        "Thank you for the warm welcome yesterday.",
        "Things are moving along nicely on my side.",
        "I had a quick word with the coach.",
        "Thanks for covering for me last week.",
        "I've been chasing the suppliers all morning.",
        "Thanks for the chat on {weekday}.",
    ]

    static let closersTrain: [String] = [
        "Thanks again for your help.",
        "Talk to you on {weekday}.",
        "I'll check back with you next week.",
        "Have a great weekend.",
        "Hope that makes sense.",
        "Happy to go through it in person.",
        "I'm around all afternoon if you want to chat.",
        "Reply here if I have missed something.",
        "We can revisit this after the holidays.",
        "Speak soon.",
        "Hope that helps.",
        "Cheers for now.",
        "I'll send a reminder on {weekday}.",
        "Thanks for bearing with me.",
        "Drop me a line when you have a minute.",
        "I'll be in the office from nine.",
        "Looking forward to hearing your thoughts.",
        "Ring me any time before six.",
        "I'll update the thread once I hear back.",
        "See you at the next meeting.",
        "Hope the rest of your week goes well.",
        "Much appreciated.",
        "Take care.",
        "Catch you later.",
        "No rush on this.",
        "Ping me when you are back.",
        "Best of luck with it all.",
        "We'll sort the rest out next time.",
        "Feel free to forward this to the team.",
        "I'll take it from here.",
        "Thanks for being so flexible.",
    ]

    static let openersTest: [String] = [
        "Hello from the conference centre.",
        "Thanks for the lift this morning.",
        "I had a long chat with the accountant.",
        "It has been a strange week so far.",
        "Thanks for the invitation to the open evening.",
        "I visited the new site yesterday.",
        "We finally got the keys this morning.",
        "Just a short message between classes.",
        "Thanks for sorting out the parking.",
        "I've spent the morning going through the feedback.",
    ]

    static let closersTest: [String] = [
        "Enjoy the rest of your evening.",
        "Let's catch up properly soon.",
        "Thanks for your time.",
        "I'll be checking messages tonight.",
        "Hope the weather improves for you.",
        "Give my love to the family.",
        "Good luck with the presentation.",
        "Let's talk it over on the phone.",
        "Safe travels.",
        "I'll pop by the office on Friday.",
        "Thanks for all the hard work.",
    ]
}
