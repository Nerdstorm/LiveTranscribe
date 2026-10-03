import Styles
import Testing

/// The number rules, as they read cleaned and laid-out text. Each table pairs what the model
/// wrote with what dictation types; the last tables hold look-alikes that must stay words.
@Suite("NumberStyle")
struct NumberStyleTests {
    private let style = NumberStyle()

    @Test("Digit strings become digits, \"oh\" as zero", arguments: [
        ("My PIN is zero four four six.", "My PIN is 0446."),
        ("Zero Four Four Six", "0446"),
        ("the code is four seven two nine", "the code is 4729"),
        ("room three oh two", "room 302"),
        ("zero four four six and zero four four seven", "0446 and 0447"),
        ("call nine one one", "call 911"),
        ("zero-four-four-six", "0446"),
        ("oh four one two, three four five, six seven eight", "0412, 345, 678"),
        ("the oh oh seven films", "the 007 films"),
    ])
    func digitStrings(text: String, written: String) {
        #expect(style.written(text) == written)
    }

    @Test("Decimals and versions become digits", arguments: [
        ("two point five", "2.5"),
        ("it weighs zero point five kilos", "it weighs 0.5 kilos"),
        ("pi is three point one four", "pi is 3.14"),
        ("version two point four point one", "version 2.4.1"),
        ("Version Two Point Four Point One", "Version 2.4.1"),
        ("upgrade to one point one", "upgrade to 1.1"),
        ("version two point oh", "version 2.0"),
        ("version two", "version 2"),
        ("release one point twelve point three", "release 1.12.3"),
        ("two point five million people", "2.5 million people"),
    ])
    func decimalsAndVersions(text: String, written: String) {
        #expect(style.written(text) == written)
    }

    @Test("Percentages become digits", arguments: [
        ("twenty five percent", "25%"),
        ("Five percent of the budget.", "5% of the budget."),
        ("two point five per cent", "2.5%"),
        ("one hundred percent sure", "100% sure"),
        ("I agree a hundred percent.", "I agree 100%."),
        ("zero percent interest", "0% interest"),
        ("between five and ten percent", "between 5% and 10%"),
    ])
    func percentages(text: String, written: String) {
        #expect(style.written(text) == written)
    }

    @Test("Money becomes digits", arguments: [
        ("one hundred and twenty five dollars", "$125"),
        ("fifty cents", "50 cents"),
        ("five cents", "5 cents"),
        ("It costs five dollars.", "It costs $5."),
        ("five dollars and fifty cents", "$5.50"),
        ("fifty thousand dollars", "$50,000"),
        ("five million dollars", "$5 million"),
        ("a hundred dollars", "$100"),
        ("one dollar", "$1"),
        ("five or six dollars", "$5 or $6"),
        ("two point five dollars", "$2.50"),
        ("it costs two dollars fifty", "it costs $2.50"),
        ("one dollar ninety nine each", "$1.99 each"),
        ("five dollars fifty cents", "$5.50"),
        ("It was two dollars and fifty.", "It was $2.50."),
        ("five dollars and ten minutes", "$5 and 10 minutes"),
        ("ten to twenty million dollars", "$10 million to $20 million"),
        ("between nine and ten thousand dollars", "between $9000 and $10,000"),
    ])
    func money(text: String, written: String) {
        #expect(style.written(text) == written)
    }

    @Test("Times become digits after \"at\", \"by\", \"from\" and the like, or before am and pm", arguments: [
        ("at nine fifteen", "at 9:15"),
        ("seven thirty pm", "7:30 pm"),
        ("Seven Thirty PM", "7:30 PM"),
        ("meet me at twelve oh five", "meet me at 12:05"),
        ("by ten forty five a.m.", "by 10:45 a.m."),
        ("the call is at nine am", "the call is at 9 am"),
        ("from nine thirty to ten fifteen", "from 9:30 to 10:15"),
    ])
    func times(text: String, written: String) {
        #expect(style.written(text) == written)
    }

    @Test("Years become digits", arguments: [
        ("in twenty twenty six", "in 2026"),
        ("back in nineteen ninety nine", "back in 1999"),
        ("in twenty oh five", "in 2005"),
        ("the year two thousand", "the year 2000"),
        ("since two thousand and eight", "since 2008"),
        ("Twenty twenty-six was a good year.", "2026 was a good year."),
        ("from twenty twenty to twenty twenty six", "from 2020 to 2026"),
        ("back in the nineteen nineties", "back in the 1990s"),
        ("in the nineteen-nineties", "in the 1990s"),
        ("the twenty twenties", "the 2020s"),
        ("in the eighteen hundreds", "in the 1800s"),
    ])
    func years(text: String, written: String) {
        #expect(style.written(text) == written)
    }

    @Test("Counts from ten up become digits, with commas from 10,000", arguments: [
        ("twenty one chairs", "21 chairs"),
        ("twenty-one chairs", "21 chairs"),
        ("Twenty one people came.", "21 people came."),
        ("Ten Downing Street", "10 Downing Street"),
        ("ten people", "10 people"),
        ("about ten minutes late", "about 10 minutes late"),
        ("We counted ninety-nine.", "We counted 99."),
        ("(twenty)", "(20)"),
        ("one hundred", "100"),
        ("fifteen hundred", "1500"),
        ("five thousand", "5000"),
        ("fifty thousand", "50,000"),
        ("two hundred and fifty thousand", "250,000"),
        ("one million two hundred thousand", "1,200,000"),
        ("three billion", "3 billion"),
        ("two thousand, five hundred", "2500"),
        ("fifty thousand, I mean sixty thousand", "50,000, I mean 60,000"),
        ("a twenty-five-year-old", "a 25-year-old"),
        ("nine fifteen-year-olds", "nine 15-year-olds"),
        ("ten to fifteen people", "10 to 15 people"),
        ("between two hundred and three hundred", "between 200 and 300"),
        ("In two thousand, five people came.", "In 2000, five people came."),
        ("the point is twenty", "the point is 20"),
        ("a hundred and fifty people", "150 people"),
        ("a hundred twenty people", "120 people"),
        ("twenty twelve-year-olds", "20 12-year-olds"),
        ("we expect twenty to thirty thousand visitors", "we expect 20,000 to 30,000 visitors"),
        ("five or six hundred people", "500 or 600 people"),
        ("two to three million people", "2 million to 3 million people"),
        ("fifty to two thousand people", "50 to 2000 people"),
    ])
    func counts(text: String, written: String) {
        #expect(style.written(text) == written)
    }

    @Test("Counts below ten, \"one\" as a word, and idioms stay words", arguments: [
        "two things",
        "nine people",
        "zero chance",
        "the one I want",
        "one of them",
        "one day",
        "a couple of things",
        "on cloud nine",
        "we're number one",
        "first, second and third",
        "one-on-one",
        "a five-year plan",
        "one and a half",
        "twelve and a half",
        "forty winks",
        "hindsight is twenty twenty",
        "at nine",
    ])
    func wordsThatStay(text: String) {
        #expect(style.written(text) == text)
    }

    @Test("Number words that make no one number stay words", arguments: [
        "one point I would make",
        "nine eleven",
        "twenty four seven",
        "nine fifteen year olds",
        "one two",
        "eighteen sixty five",
        "a hundred people",
        "a thousand times",
        "hundreds of emails",
        "the nineties",
        "covid-nineteen",
        "Oh, I see.",
        "oh no",
        "Oh oh oh",
        "call me at five fifty dollars",
        "a thousand and one nights",
    ])
    func wordsThatMakeNoNumber(text: String) {
        #expect(style.written(text) == text)
    }

    @Test("Ordinals, o'clock, clock phrases and ranges with a small number stay words", arguments: [
        "the twenty first century",
        "twenty-first",
        "at ten o'clock",
        "half past ten",
        "quarter to eleven",
        "twenty past twelve",
        "five to ten",
        "nine or ten",
        "eight, nine, ten",
    ])
    func phrasesThatStay(text: String) {
        #expect(style.written(text) == text)
    }

    @Test("Digits already written stay as they are", arguments: [
        "sam42@example.com",
        "Room 42 is on level 3.",
        "version 2.4.1",
        "25% of $125",
    ])
    func digitsStay(text: String) {
        #expect(style.written(text) == text)
    }

    /// The rules run after the list layout, so list numbers are digits already and the markers
    /// that were not laid out are words below ten.
    @Test("List numbers and markers stay as laid out", arguments: [
        ("1. Go to shops\n2. Talk to mechanic", "1. Go to shops\n2. Talk to mechanic"),
        ("One, go to shops, two, talk to mechanic.", "One, go to shops, two, talk to mechanic."),
        ("One is the launch. Two, the marketing.", "One is the launch. Two, the marketing."),
        ("One, twenty eggs; two, milk.", "One, 20 eggs; two, milk."),
        ("Number one, the form. Number two, the sign-in.", "Number one, the form. Number two, the sign-in."),
        ("10. Ship the release\n11. Write the docs", "10. Ship the release\n11. Write the docs"),
        ("We need three things:\n1. Twenty eggs\n2. Milk", "We need three things:\n1. 20 eggs\n2. Milk"),
        ("- Ten apples\n- Two pears", "- 10 apples\n- Two pears"),
        ("Shopping list:\n- Milk\n- Eggs\n\nBack by twenty past twelve.", "Shopping list:\n- Milk\n- Eggs\n\nBack by twenty past twelve."),
    ])
    func listNumbersStay(text: String, written: String) {
        #expect(style.written(text) == written)
    }

    @Test func aLineBreakEndsANumber() {
        #expect(style.written("fifty\nthousand people") == "50\nthousand people")
    }

    @Test func keptPhrasesStayAsWritten() {
        let style = NumberStyle(keeping: ["Studio Fifty-Four", "Nerdstorm"])
        #expect(style.written("meet at Studio Fifty-Four at nine thirty") == "meet at Studio Fifty-Four at 9:30")
        #expect(style.written("meet at studio fifty four") == "meet at studio fifty four", "in any case")
        #expect(style.written("fifty four people") == "54 people", "elsewhere the words are numbers")
    }

    @Test func textWithoutNumberWordsIsReturnedAsItIs() {
        let text = "Hi Sam,\n\nThanks for the update.\n\nCheers,\nPriya"
        #expect(style.written(text) == text)
        #expect(style.written("") == "")
    }
}
