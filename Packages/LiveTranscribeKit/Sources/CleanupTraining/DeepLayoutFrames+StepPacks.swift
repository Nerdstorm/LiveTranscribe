import Foundation

extension DeepLayoutFrames {
    // MARK: - Step packs (ordered steps)

    static let stepPacksTrain: [ListPack] = [
        // Restart the home wifi
        ListPack(
            intros: [
                "to restart the wifi",
                "here's how to get the wifi back up",
                "the process is",
                "{count} steps to fix the connection",
                "what you do",
            ],
            items: [
                "switch off the router at the socket",
                "leave it alone for a minute",
                "switch it back on",
                "wait for the status light to turn steady",
                "reconnect your laptop to the network",
                "open a web page to test the connection",
                "restart any device that still fails",
            ]
        ),
        // Renew a fishing permit
        ListPack(
            intros: [
                "to renew the fishing permit",
                "here's how to get the permit renewed",
                "the renewal process is",
                "{count} steps to renew it",
                "it goes like this",
            ],
            items: [
                "find your permit number",
                "open the agency website",
                "sign in to your account",
                "check your personal details",
                "choose the renewal period",
                "pay the renewal charge by card",
                "download the new permit",
                "keep a copy in your tackle box",
            ]
        ),
        // Bleed a radiator
        ListPack(
            intros: [
                "to release trapped air from a radiator",
                "here's how to get a cold radiator working again",
                "the method is",
                "{count} steps to get the air out",
                "run through it in this order",
            ],
            items: [
                "turn the thermostat right down",
                "let the radiator go cold",
                "put a towel under the valve",
                "fit the bleed key onto the small square valve",
                "turn it a quarter turn until you hear a hiss",
                "tighten the valve as soon as water appears",
                "read the gauge on the front of the boiler",
                "top up the pressure if it is low",
            ]
        ),
        // Set up a new email account
        ListPack(
            intros: [
                "to set up the new email account",
                "{count} steps to get your account working",
                "the sign-up process is",
                "how to sign up",
                "here's the order",
            ],
            items: [
                "go to the sign-up page",
                "enter your email address",
                "choose a strong password",
                "verify your email with the code",
                "add a recovery phone number",
                "turn on two-step verification",
                "add a profile picture",
            ]
        ),
        // Make a yeast loaf
        ListPack(
            intros: [
                "to make a simple loaf",
                "here's how to make bread",
                "the recipe is",
                "{count} steps to a fresh loaf",
                "here's what to do",
            ],
            items: [
                "weigh out the flour",
                "dissolve the yeast in warm water",
                "mix the dough until it comes together",
                "knead it for ten minutes",
                "leave it to rise for an hour",
                "knock back the dough",
                "form the dough into a round",
                "let it prove again",
                "bake it at two hundred degrees",
            ]
        ),
        // File an expense claim
        ListPack(
            intros: [
                "to file an expense claim",
                "here's how to claim your expenses",
                "the procedure is",
                "{count} steps to get paid back",
                "what you need to do",
            ],
            items: [
                "collect all your receipts",
                "open the expense form",
                "add each expense with its date",
                "attach a photo of every receipt",
                "pick the project code",
                "submit the claim to your manager",
                "wait for the approval email",
                "check the payment in your next payslip",
            ]
        ),
        // Change a flat tyre
        ListPack(
            intros: [
                "to change a flat tyre",
                "here's how to swap the wheel",
                "the process is",
                "{count} steps to get back on the road",
                "do it in this order",
            ],
            items: [
                "park on level ground",
                "switch on the hazard lights",
                "loosen the wheel nuts slightly",
                "jack up the car",
                "remove the wheel",
                "fit the spare wheel",
                "tighten the nuts by hand",
                "lower the car",
                "tighten the nuts fully with the wrench",
                "check the spare's pressure soon",
            ]
        ),
        // Start a new code repository
        ListPack(
            intros: [
                "to start a new project",
                "here's how to set up the repository",
                "the routine is",
                "{count} steps to get going",
                "set it up like this",
            ],
            items: [
                "create an empty repository",
                "clone it to your laptop",
                "add a readme file",
                "set up the linter",
                "write the first test",
                "configure the build pipeline",
                "protect the main branch",
            ]
        ),
        // Repot a houseplant
        ListPack(
            intros: [
                "to repot a houseplant",
                "here's how to give it a new pot",
                "how it's done",
                "{count} steps to repot it",
                "work through these",
            ],
            items: [
                "water the plant the day before",
                "choose a slightly larger pot",
                "cover the drainage holes with stones",
                "add a layer of fresh soil",
                "ease the plant out of the old pot",
                "loosen the roots gently",
                "place it in the new pot",
                "fill the gaps with soil",
                "water it thoroughly",
            ]
        ),
        // Onboard a supplier
        ListPack(
            intros: [
                "to bring on a new supplier",
                "here's how we add a vendor",
                "our onboarding process is",
                "{count} steps to bring them on board",
                "what you do",
            ],
            items: [
                "request the company registration details",
                "check their insurance certificate",
                "run a credit check",
                "add them to the vendor system",
                "send the purchase order template",
                "agree the payment terms",
                "place a small test order",
            ]
        ),
        // Treat a minor burn
        ListPack(
            intros: [
                "to treat a minor burn",
                "here's what to do for a small burn",
                "the first aid steps are",
                "{count} steps to look after it",
                "act quickly",
            ],
            items: [
                "cool the burn under running water",
                "keep it there for twenty minutes",
                "remove rings near the burn",
                "cover it with a clean film",
                "take a painkiller if you need one",
                "see a doctor if blisters appear",
            ]
        ),
        // Organise a street party
        ListPack(
            intros: [
                "to organise a street party",
                "here's how to plan the street party",
                "the approval process is",
                "{count} steps to get it approved",
                "start with this",
            ],
            items: [
                "talk to your neighbours first",
                "pick a date in the summer",
                "apply to the council for a road closure",
                "ask every household to bring a dish",
                "borrow tables from the community hall",
                "put up notices along the street",
                "set up the tables on the morning of the party",
                "clear everything away by evening",
            ]
        ),
    ]

    static let stepPacksTest: [ListPack] = [
        // Descale a kettle
        ListPack(
            intros: [
                "to descale the kettle",
                "here's how to clean the limescale out",
                "the approach is",
                "{count} steps to a clean kettle",
                "follow these in order",
            ],
            items: [
                "fill the kettle halfway with water",
                "add a cup of white vinegar",
                "bring it to the boil",
                "leave it to sit for an hour",
                "pour the mixture away",
                "rinse the inside well",
                "boil a fresh batch of plain water",
                "pour that away as well",
            ]
        ),
        // Jump-start a flat battery
        ListPack(
            intros: [
                "to jump-start a flat battery",
                "here's how to get the engine going",
                "it works like this",
                "{count} steps to restart the car",
                "do it in this sequence",
            ],
            items: [
                "park the working car close by",
                "switch off both engines",
                "connect the red clamp to the flat battery",
                "attach the other red clamp to the good battery",
                "clip the black clamp to the donor battery",
                "fix the last clamp to bare metal on the stalled car",
                "start the working car",
                "try the stalled engine",
                "remove the clamps in reverse order",
            ]
        ),
        // Apply for a library card
        ListPack(
            intros: [
                "to get a library card",
                "here's how to join the library",
                "the joining process is",
                "{count} steps to start borrowing",
                "what you do is",
            ],
            items: [
                "check the opening hours",
                "bring a recent bill with your address on it",
                "bring a photo ID too",
                "go to the front desk",
                "fill in the membership form",
                "collect your temporary card",
                "activate the account online",
                "choose your first book",
                "borrow it at the self-service kiosk",
            ]
        ),
        // Set up regular backups
        ListPack(
            intros: [
                "to set up the weekly backup",
                "here's how to protect your files",
                "the way to do it is",
                "{count} steps to back up the laptop",
                "go through it in this order",
            ],
            items: [
                "plug in the external drive",
                "open the backup settings",
                "select the drive as the destination",
                "choose the folders to include",
                "set the schedule to weekly",
                "run the first backup manually",
                "check that the files are on the drive",
                "eject the drive safely",
            ]
        ),
        // Sharpen a kitchen knife
        ListPack(
            intros: [
                "to sharpen a kitchen knife",
                "here's how to put an edge back on a blade",
                "the steps run in this order",
                "{count} steps to a sharper knife",
                "the technique is",
            ],
            items: [
                "soak the whetstone in water",
                "rest the stone on a damp cloth",
                "hold the knife at a shallow angle",
                "draw the blade across the stone",
                "repeat on the other side",
                "flip the stone to the fine grit",
                "polish the edge with light strokes",
                "rinse the knife under the tap",
            ]
        ),
    ]
}
