import Foundation
import Shared

/// Lays out dictated text by intent: lists become numbered or bulleted lines, a letter gets its
/// salutation and sign-off on lines of their own. Runs at Medium and High, in fields that take
/// several lines.
///
/// Two kinds of rule, so a new structure is one more rule in ``standardRules`` or
/// ``standardFrames``:
/// - a ``FrameRule`` finds a structure in the words before cleanup and lays out the parts the
///   model must not rearrange (it moved a letter's names between greeting and sign-off when it
///   saw the whole letter), leaving the rest for the model to clean;
/// - a ``LayoutRule`` rearranges a paragraph of the cleaned text, whose spoken line breaks and
///   list markers are already newlines.
///
/// Rules only move and punctuate words; they never reword. Snippets, emoji and addresses are
/// still placeholders while the rules run, so a rule cannot change them either.
public struct Layout: Sendable {
    /// Marked lists first, so the ordinal rule sees only prose.
    public static let standardRules: [any LayoutRule] = [MarkedListLayout(), OrdinalListLayout()]
    public static let standardFrames: [any FrameRule] = [LetterFrame()]

    private let rules: [any LayoutRule]
    private let frames: [any FrameRule]

    public init(rules: [any LayoutRule] = standardRules, frames: [any FrameRule] = standardFrames) {
        self.rules = rules
        self.frames = frames
    }

    /// The first frame that fits `text`, the transcript before cleanup; `nil` when none does.
    public func frame(in text: String) -> TextFrame? {
        for rule in frames {
            if let frame = rule.frame(in: text) { return frame }
        }
        return nil
    }

    /// `text` with every rule applied to each paragraph in turn. Paragraphs are separated by a
    /// blank line and keep their order.
    public func arrange(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map { paragraph in
            var lines = paragraph.components(separatedBy: "\n")
            for rule in rules {
                if let arranged = rule.arrange(lines) { lines = arranged }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

/// Rearranges one paragraph of cleaned text.
public protocol LayoutRule: Sendable {
    /// `lines`, one paragraph without blank lines, laid out; `nil` to leave them as they are. A
    /// blank line in the result starts a new paragraph, as after a list.
    func arrange(_ lines: [String]) -> [String]?
}

/// Finds a structure in the words before cleanup.
public protocol FrameRule: Sendable {
    /// The frame around `text`, or `nil` when the structure is not there.
    func frame(in text: String) -> TextFrame?
}

/// Text split into a body the language model cleans and the laid-out text around it.
public struct TextFrame: Sendable, Equatable {
    /// Laid out before the body, ending in the break that separates them.
    public let opening: String
    /// The words the model cleans, placeholders and all.
    public let body: String
    /// Laid out after the body, starting with the break that separates them.
    public let closing: String

    public init(opening: String, body: String, closing: String) {
        self.opening = opening
        self.body = body
        self.closing = closing
    }

    /// The frame around `cleanedBody`, which starts a paragraph and so a sentence.
    public func assembled(body cleanedBody: String) -> String {
        opening + SentenceCase.capitalizingFirstWord(cleanedBody.trimmingCharacters(in: .whitespacesAndNewlines)) + closing
    }
}
