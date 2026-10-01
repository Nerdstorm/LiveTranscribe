import Foundation

extension DeepLayoutFrames {
    // MARK: - Bullet packs (unordered things)

    static let bulletPacksTrain: [ListPack] = [
        // Noun phrases: software project needs
        ListPack(
            intros: [
                "{few} things we need to focus on",
                "what we need before the beta goes out",
                "our requirements for the new dashboard",
                "the things still missing",
                "the key requirements",
                "for the beta release we need",
            ],
            items: [
                "a working staging environment",
                "the final API documentation",
                "a rollback plan for the release",
                "sign-off from the security team",
                "a fixed list of supported browsers",
                "the updated privacy notice",
                "a dedicated on-call rotation",
                "test data for the billing flow",
                "a clear owner for each feature",
                "the translated help pages",
                "an agreed performance budget",
                "monitoring on the payment service",
                "a backup of the production database",
                "written release notes",
            ]
        ),
        // Noun phrases: home improvement supplies
        ListPack(
            intros: [
                "what we need for the bathroom job",
                "{count} things I still need from the hardware store",
                "the shopping list for the weekend project",
                "things to pick up before Saturday",
                "the supplies we are short of",
                "for the bathroom job I still need",
            ],
            items: [
                "a new shower screen",
                "grout in light grey",
                "a tube of silicone sealant",
                "two rolls of masking tape",
                "a spirit level",
                "replacement hinges for the cabinet",
                "a box of wall plugs",
                "a packet of tile spacers",
                "a drill bit for masonry",
                "a heavy dust sheet",
                "a pair of safety glasses",
                "some paint for the ceiling",
                "a new extractor fan",
                "a stud finder",
            ]
        ),
        // Noun phrases: community meeting topics
        ListPack(
            intros: [
                "topics for the committee meeting",
                "{few} points on the agenda",
                "what I want to raise at the meeting",
                "the discussion points",
                "{count} topics for this evening",
            ],
            items: [
                "the volunteer rota for the summer",
                "the proposed changes to the membership fees",
                "an update on the roof repairs",
                "feedback from the open day",
                "next year's schedule of events",
                "the new safeguarding policy",
                "the state of the changing rooms",
                "the treasurer's report",
                "the trophy presentation evening",
                "the complaint about parking",
                "the sponsorship offer from a local firm",
                "the plan for the spring tournament",
                "a proposal for a junior team",
                "the date of the annual general meeting",
            ]
        ),
        // Noun phrases: project risks
        ListPack(
            intros: [
                "the main risks",
                "{few} risks I see with the plan",
                "my concerns about the project",
                "what worries me",
                "{count} things that could go wrong",
                "the risks as I see them",
            ],
            items: [
                "a delay in signing the supplier contract",
                "rising cloud costs",
                "the loss of our lead engineer",
                "a slow approval from legal",
                "an unclear scope for phase two",
                "a shortage of testers",
                "late changes from the client",
                "a currency swing against the dollar",
                "low attendance at the launch event",
                "data migration errors",
                "a change in the tax rules",
                "a clash with the holiday period",
                "too many open decisions",
                "weak test coverage on the checkout",
            ]
        ),
        // Noun phrases: questions for a vendor
        ListPack(
            intros: [
                "my questions for the vendor",
                "the open questions",
                "{count} questions I want answered",
                "what I would like to know",
                "things I need to find out",
            ],
            items: [
                "the price of the extended warranty",
                "the delivery date for the first batch",
                "the length of the contract",
                "the notice period for cancelling",
                "the cost of extra storage",
                "the support hours at weekends",
                "the process for changing plans",
                "the limit on the number of users",
                "the location of the data centre",
                "the fee for early termination",
                "the training that comes with setup",
                "the refund policy for unused months",
                "the uptime guarantee",
                "the contact for urgent problems",
            ]
        ),
        // Gerund phrases: engineering work in progress
        ListPack(
            intros: [
                "what I'm working on this week",
                "{few} things keeping me busy",
                "my focus for the sprint",
                "what the team is busy with",
                "the jobs in progress",
            ],
            items: [
                "getting the nightly build stable",
                "migrating the user table to the new schema",
                "writing tests for the export module",
                "fixing the timeout on the upload page",
                "tuning the search index",
                "cleaning up the old feature flags",
                "reviewing the pull requests from last week",
                "setting up alerts for failed payments",
                "updating the onboarding emails",
                "documenting the release process",
                "moving the logs to cheaper storage",
                "rotating the expired certificates",
                "speeding up the report generation",
                "training the new starter on the deploy tools",
            ]
        ),
        // Gerund phrases: weekend plans at home
        ListPack(
            intros: [
                "what we're doing this weekend",
                "{few} things planned for Saturday",
                "plans for the long weekend",
                "what is on the cards for us",
                "the weekend plans",
            ],
            items: [
                "taking the kids to swimming",
                "clearing out the garage",
                "visiting Grandma in the afternoon",
                "washing the car",
                "planting the tomato seedlings",
                "sorting the winter clothes",
                "cooking a big lunch for the neighbours",
                "mowing the front lawn",
                "fixing the squeaky door",
                "painting the spare bedroom",
                "walking the dog along the river",
                "returning the library books",
                "cleaning the gutters",
                "watching the football with friends",
            ]
        ),
        // Gerund phrases: health and fitness goals
        ListPack(
            intros: [
                "my goals for the season",
                "{count} things I'm working on with the coach",
                "what I'm trying to improve",
                "my training plan for the month",
                "what I want to change this year",
            ],
            items: [
                "running three times a week",
                "stretching after every session",
                "sleeping at least eight hours",
                "drinking more water during the day",
                "lifting lighter weights with better form",
                "skipping late snacks",
                "swimming on Sunday mornings",
                "cycling to work twice a week",
                "keeping a training diary",
                "warming up for ten minutes",
                "foam rolling the calves",
                "joining a club for Saturday runs",
                "tracking my resting heart rate",
                "taking a full rest day",
            ]
        ),
        // Gerund phrases: conference organising
        ListPack(
            intros: [
                "what I'm handling for the conference",
                "my part of the organising",
                "the jobs I've taken on",
                "{few} tasks on my side",
                "what I'm responsible for",
            ],
            items: [
                "booking the speakers' travel",
                "printing the name badges",
                "confirming the catering numbers",
                "testing the projector in the main hall",
                "sending the joining instructions",
                "arranging the airport transfers",
                "updating the schedule on the website",
                "ordering the lanyards",
                "checking the wheelchair access",
                "preparing the welcome packs",
                "hiring the sound engineer",
                "marking the route with signs",
                "chasing the last few payments",
                "collecting the signed consent forms",
            ]
        ),
        // Imperative phrases: leaving the house
        ListPack(
            intros: [
                "{few} things to do before we leave",
                "my reminders for the house-sitter",
                "the checklist before we go",
                "what needs doing before the taxi arrives",
                "{count} jobs for the morning of the flight",
            ],
            items: [
                "bolt the side gate",
                "unplug the toaster",
                "take out the compost",
                "water the pot plants",
                "set the alarm",
                "close the garage",
                "pull the curtains in the lounge",
                "leave a key with the neighbours",
                "empty the fridge of anything perishable",
                "put the bins out",
                "set the thermostat to eighteen",
                "turn off the main water valve",
                "check the windows are latched",
                "shut the loft hatch",
            ]
        ),
        // Imperative phrases: customer support
        ListPack(
            intros: [
                "reminders for the support team",
                "{few} habits for every ticket",
                "what to do when a customer calls",
                "the support checklist",
                "{count} rules for the help desk",
            ],
            items: [
                "greet the customer by name",
                "confirm the account email first",
                "log the call in the ticket system",
                "ask for the exact error message",
                "offer a follow-up time",
                "check the status page for outages",
                "tag the ticket with the product area",
                "escalate anything about billing",
                "summarise the fix in plain words",
                "thank them for waiting",
                "never promise a date you cannot keep",
                "send a survey link at the end",
                "record the customer's device model",
                "close the ticket once they confirm",
            ]
        ),
        // Imperative phrases: volunteers on event day
        ListPack(
            intros: [
                "instructions for volunteers",
                "{few} things to remember on the day",
                "before the gates open",
                "what every marshal should do",
                "{few} reminders for Sunday",
            ],
            items: [
                "wear your bright vest",
                "arrive by seven thirty",
                "sign in at the tent",
                "check your radio is charged",
                "keep the exits clear",
                "point families towards the water station",
                "report any injury straight away",
                "stay at your post until relieved",
                "carry a whistle",
                "hand out programmes at the gate",
                "direct cars to the field car park",
                "take a break every two hours",
                "drink plenty of water",
                "smile at everyone",
            ]
        ),
        // Imperative phrases: month-end finance
        ListPack(
            intros: [
                "the month-end checklist",
                "{few} jobs before we close the books",
                "what finance needs to do by Friday",
                "my instructions for the new accountant",
                "{count} jobs for month end",
            ],
            items: [
                "reconcile the bank accounts",
                "chase the unpaid invoices",
                "file the expense receipts",
                "update the cash flow forecast",
                "approve the pending purchase orders",
                "review the payroll report",
                "archive the signed contracts",
                "back up the ledger",
                "send the summary to the director",
                "check the tax codes on new suppliers",
                "close the open journals",
                "lock the accounting period",
                "check the petty cash float",
                "review the travel bookings",
            ]
        ),
        // Imperative phrases: school morning routine
        ListPack(
            intros: [
                "{few} things to get done before school",
                "the school morning checklist",
                "reminders for the kids",
                "what to do before the bus comes",
                "{count} things for each morning",
            ],
            items: [
                "brush your teeth",
                "pack your lunchbox",
                "put your homework in your bag",
                "find your PE kit",
                "tie your shoelaces",
                "feed the cat",
                "make your bed",
                "fill your drink bottle",
                "check the timetable for today",
                "sign the trip form",
                "hang up your coat",
                "say goodbye to the dog",
                "put your phone on silent",
                "zip up your school bag",
            ]
        ),
        // Short clauses: project status
        ListPack(
            intros: [
                "updates since Monday",
                "{few} status notes",
                "where things stand",
                "progress so far",
                "the current status",
                "here is where the project stands",
            ],
            items: [
                "the payment service is running on the new cluster",
                "the import script is finished",
                "the mobile build is waiting for review",
                "the search fix has been merged",
                "the staging database is refreshed",
                "the design team has sent the final mockups",
                "the security scan found nothing serious",
                "the docs site is live",
                "the load test is scheduled for Thursday",
                "the translations are half done",
                "the support inbox is back under control",
                "the release candidate is tagged",
                "the test suite takes twelve minutes now",
                "the backlog is down to forty tickets",
            ]
        ),
        // Short clauses: quirks of a rental flat
        ListPack(
            intros: [
                "the quirks of the flat",
                "{few} things to know before you move in",
                "the notes for the new tenants",
                "what to know about the flat",
                "{count} things about the place",
                "here's what you should know about the flat",
            ],
            items: [
                "the heating comes on at six",
                "the bins go out on Tuesday nights",
                "the front door sticks in wet weather",
                "the washing machine is quite noisy",
                "the neighbours are friendly",
                "the boiler sometimes needs a reset",
                "the garden gate has no lock",
                "the shower takes a minute to warm up",
                "the parking spot is behind the shed",
                "the broadband is included in the rent",
                "the stairs creak at night",
                "the smoke alarm beeps when the battery is low",
                "the kitchen window faces the street",
                "the landlord lives next door",
            ]
        ),
        // Short clauses: meeting decisions
        ListPack(
            intros: [
                "what we decided at the meeting",
                "{few} decisions from the call",
                "the outcome of the review",
                "what came out of the workshop",
                "the decisions so far",
                "here is what we agreed",
            ],
            items: [
                "we keep the current pricing for another quarter",
                "we drop support for the old tablet",
                "the office stays closed on the bank holiday",
                "Mateo leads the vendor search",
                "the budget is capped at twelve thousand",
                "the next review is in six weeks",
                "the trial runs for one month",
                "every release needs two approvals",
                "the weekly call moves to Tuesdays",
                "new hires get a mentor",
                "travel needs approval from finance",
                "we pause the hiring until spring",
                "all invoices go through the shared inbox",
                "the newsletter goes monthly instead of weekly",
            ]
        ),
        // Short clauses: holiday trip notes
        ListPack(
            intros: [
                "how the trip went",
                "{few} things about the holiday",
                "what I remember from the trip",
                "my notes on the holiday",
                "the trip in brief",
                "here's how the holiday went",
            ],
            items: [
                "the train was forty minutes late",
                "the hotel upgraded our room",
                "it rained on the second day",
                "the kids loved the beach",
                "the museum was closed on Monday",
                "the food was better than expected",
                "we lost one suitcase for a day",
                "the ferry was cancelled once",
                "the guide spoke excellent English",
                "the old town was full of tourists",
                "the hike took longer than planned",
                "our neighbours at the campsite were kind",
                "the airport queue moved quickly",
                "the souvenir shop overcharged us",
            ]
        ),
    ]
}
