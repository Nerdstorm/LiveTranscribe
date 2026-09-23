import Foundation

/// One utterance as shown in the transcript.
public struct TranscriptLine: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Still being spoken; text will change.
        case partial
        /// Final raw text; `awaitingCleanup` while the LLM has not returned yet.
        case raw(awaitingCleanup: Bool)
        case cleaned
        /// Cleanup output was rejected; the raw text is shown.
        case fellBack(reason: String)
    }

    public let id: UUID
    public var text: String
    /// The raw transcript, once final. Differs from `text` when cleanup changed something.
    public var rawText: String?
    public var state: State

    public init(id: UUID, text: String, rawText: String?, state: State) {
        self.id = id
        self.text = text
        self.rawText = rawText
        self.state = state
    }

    public var isFinal: Bool {
        switch state {
        case .partial: false
        case .raw(let awaitingCleanup): !awaitingCleanup
        case .cleaned, .fellBack: true
        }
    }
}
