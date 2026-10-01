import Foundation

/// A list of things a speaker enumerates: phrases of one grammatical shape, which read right after
/// any of the pack's intros, so a list made from a pack is coherent.
struct ListPack: Sendable {
    /// How the list is introduced, lowercase first letter (names aside), no colon and no full stop.
    /// `{count}` becomes "two", "three", … "six"; `{few}` becomes "a couple of" (two items), "a
    /// few" (three or four) or "several" (five or six). An intro with neither fits any count.
    let intros: [String]
    /// The items as said and as written: lowercase first letter (names aside), no final
    /// punctuation, no commas, no colon and never the word "and" or "or" inside an item.
    let items: [String]
}

/// Frames and vocabulary for Deep's layout examples (lists, email bodies, placeholders,
/// corrections inside a mention), which ``DeepExampleGenerator`` fills and lays out. Split into
/// extensions by kind; each has a training and a test version, and no test frame or item pack is in
/// training or validation. Plain values (a name, a city, a homophone pair) may repeat across the two:
/// the test split measures the layout, not the vocabulary.
enum DeepLayoutFrames {}
