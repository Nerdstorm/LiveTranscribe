import Cleanup
import Foundation
import Shared
import Testing

@Suite("CleanupExecutor")
struct CleanupExecutorTests {
    private let segment = Segment(
        id: UUID(),
        sessionID: UUID(),
        startMs: 0,
        endMs: 1_500,
        rawText: "i think the build is broken on main"
    )

    private let medium = CleanupOptions(level: .medium)

    private func executor(timeout: Double = 1, adapted: Bool = false) -> CleanupExecutor {
        CleanupExecutor(contextLimit: 3, timeoutSeconds: timeout, prompts: PromptBuilder(adapted: adapted))
    }

    private func makeSegment(_ text: String) -> Segment {
        Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: text)
    }

    @Test func acceptedOutputReplacesRawText() async {
        let cleaned = await executor().run(segment, context: [], options: medium) { _ in "I think the build is broken on main." }
        #expect(!cleaned.fellBack)
        #expect(cleaned.cleanedText == "I think the build is broken on main.")
        #expect(cleaned.segment == segment)
    }

    @Test func generationErrorFallsBackToRaw() async {
        struct GPUFailure: LocalizedError { var errorDescription: String? { "GPU error" } }
        let cleaned = await executor().run(segment, context: [], options: medium) { _ in throw GPUFailure() }
        #expect(cleaned.fellBack)
        #expect(cleaned.cleanedText == segment.rawText)
        #expect(cleaned.fallbackReason == "generation failed: GPU error")
    }

    @Test func slowGenerationTimesOutAndFallsBack() async {
        let started = ContinuousClock.now
        let cleaned = await executor(timeout: 0.1).run(segment, context: [], options: medium) { _ in
            try await Task.sleep(for: .seconds(10))
            return "too late"
        }
        #expect(cleaned.fellBack)
        #expect(cleaned.fallbackReason == "timed out after 0.1s")
        #expect(started.duration(to: .now) < .seconds(2), "the generation is cancelled, not awaited")
    }

    @Test func guardRejectionFallsBack() async {
        let cleaned = await executor().run(segment, context: [], options: medium) { _ in "<think>hmm</think> I think the build is broken." }
        #expect(cleaned.fellBack)
        #expect(cleaned.fallbackReason == "thinking tags in output")
    }

    @Test func contextIsPassedThroughTheWindow() async {
        let captured = RequestRecorder()
        _ = await executor().run(segment, context: ["a.", "b.", "c.", "d."], options: medium) { request in
            await captured.record(request)
            return "I think the build is broken on main."
        }
        let request = await captured.last
        #expect(request?.messages.filter { $0.role == .assistant }.map(\.content) == ["b.", "c.", "d."])
        #expect(request?.messages.last == .init(role: .user, content: "TEXT:\n\(segment.rawText)"))
        #expect(request?.templateContext["enable_thinking"] == false)
    }

    @Test func emptyRawTextSkipsGeneration() async {
        let empty = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 10, rawText: "  ")
        let cleaned = await executor().run(empty, context: [], options: CleanupOptions(level: .light)) { _ in
            Issue.record("generation should not run")
            return ""
        }
        #expect(!cleaned.fellBack)
        #expect(cleaned.cleanedText == "  ")
    }

    // MARK: - Levels

    @Test func levelNoneReturnsTheRawTextWithoutTheModel() async {
        let raw = makeSegment("um so the the build is broken")
        let cleaned = await executor().run(raw, context: [], options: CleanupOptions(level: .none)) { _ in
            Issue.record("generation should not run")
            return ""
        }
        #expect(cleaned == CleanedSegment(segment: raw, cleanedText: raw.rawText, fellBack: false, fallbackReason: nil, latencyMs: 0))
    }

    @Test(arguments: ["ඒකෙ තියෙන magic වැඩ um", "um ඔන්න මගේ film එකතුවට"])
    func sinhalaSkipsTheModelButKeepsTheLevelsRules(_ text: String) async {
        let raw = makeSegment(text)
        for level in [CleanupLevel.light, .medium, .high] {
            let cleaned = await executor().run(raw, context: [], options: CleanupOptions(level: level)) { _ in
                Issue.record("the model drops Sinhala's vowel signs, so it must not see Sinhala")
                return ""
            }
            #expect(cleaned == CleanedSegment(
                segment: raw,
                cleanedText: CleanupExecutor.deterministicCleanup(of: text, level: level),
                fellBack: false,
                fallbackReason: nil,
                latencyMs: 0
            ))
        }
    }

    @Test func englishStillGoesToTheModel() async {
        let captured = RequestRecorder()
        _ = await executor().run(makeSegment("the build is broken"), context: [], options: medium) { request in
            await captured.record(request)
            return "The build is broken."
        }
        #expect(await captured.all.count == 1)
    }

    @Test func onlySinhalaIsKeptFromTheModel() {
        #expect(!CleanupScripts.modelCanRewrite("මේ film එක බලන්න"))
        #expect(!CleanupScripts.modelCanRewrite("ශ්‍රී"))
        #expect(CleanupScripts.modelCanRewrite("Let's meet on Tuesday."))
        #expect(CleanupScripts.modelCanRewrite("Café, naïve, 東京, नमस्ते"))
    }

    @Test func mediumRemovesFillersBeforeTheModelSeesTheText() async {
        let captured = RequestRecorder()
        let raw = makeSegment("so um the build is uh broken")
        let cleaned = await executor().run(raw, context: [], options: medium) { request in
            await captured.record(request)
            return "So the build is broken."
        }
        #expect(await captured.last?.messages.last == .init(role: .user, content: "TEXT:\nso the build is broken"))
        #expect(cleaned.cleanedText == "So the build is broken.")
        #expect(cleaned.segment == raw, "the record keeps what was actually said")
    }

    @Test func lightKeepsFillersForTheModel() async {
        let captured = RequestRecorder()
        let raw = makeSegment("so um the build is broken")
        _ = await executor().run(raw, context: [], options: CleanupOptions(level: .light)) { request in
            await captured.record(request)
            return "So, um, the build is broken."
        }
        #expect(await captured.last?.messages.last == .init(role: .user, content: "TEXT:\nso um the build is broken"))
    }

    @Test func aFallbackKeepsTheFillersRemoved() async {
        let raw = makeSegment("so um the build is uh broken")
        let cleaned = await executor().run(raw, context: [], options: medium) { _ in "Here is the text: So the build is broken." }
        #expect(cleaned.fellBack)
        #expect(cleaned.cleanedText == "so the build is broken")
    }

    @Test func onlyFillersLeavesNothingToClean() async {
        let cleaned = await executor().run(makeSegment("um uh"), context: [], options: medium) { _ in
            Issue.record("generation should not run")
            return ""
        }
        #expect(!cleaned.fellBack)
        #expect(cleaned.cleanedText.isEmpty)
    }

    /// The model sees each placeholder as a word, listed in the prompt; the tokens come back
    /// before the guard.
    @Test func optionsShapeThePrompt() async {
        let captured = RequestRecorder()
        let options = CleanupOptions(level: .high, vocabulary: ["Nerdstorm"], placeholders: ["⟦S1⟧"])
        let raw = makeSegment("email ⟦S1⟧ to the nerd storm team")
        let cleaned = await executor(adapted: true).run(raw, context: [], options: options) { request in
            await captured.record(request)
            return "Email S1 to the Nerdstorm team."
        }
        let request = await captured.last
        var shown = options
        shown.placeholders = ["S1"]
        #expect(request?.messages.first == .init(role: .system, content: PromptBuilder(adapted: true).template(for: shown).system))
        #expect(request?.messages.last == .init(role: .user, content: "TEXT:\nemail S1 to the nerd storm team"))
        #expect(cleaned.cleanedText == "Email ⟦S1⟧ to the Nerdstorm team.")
    }

    @Test func aDamagedPlaceholderFallsBackToTheTextWithPlaceholders() async {
        let options = CleanupOptions(level: .medium, placeholders: ["⟦S1⟧"])
        let raw = makeSegment("email ⟦S1⟧ to the team")
        let cleaned = await executor().run(raw, context: [], options: options) { _ in "Email S 1 to the team." }
        #expect(cleaned.fellBack)
        #expect(cleaned.fallbackReason == "changed a placeholder")
        #expect(cleaned.cleanedText == "email ⟦S1⟧ to the team")
    }

    // MARK: - High with a self-correction

    private static let corrected = "meet on tuesday no wait wednesday at the office"
    private static let resolved = "Meet on Wednesday at the office."

    @Test func highResolvesACorrectionAtMediumThenRewords() async {
        let captured = RequestRecorder()
        let high = CleanupOptions(level: .high, vocabulary: ["Acme"])
        let cleaned = await executor(adapted: true).run(makeSegment(Self.corrected), context: [], options: high) { request in
            await captured.record(request) == 1 ? Self.resolved : "Let's meet on Wednesday at the office."
        }
        let requests = await captured.all
        let prompts = PromptBuilder(adapted: true)
        #expect(requests.map { $0.messages.first?.content } == [
            prompts.template(for: CleanupOptions(level: .medium, vocabulary: ["Acme"])).system,
            prompts.template(for: high).system,
        ])
        #expect(requests.last?.messages.last == .init(role: .user, content: "TEXT:\n\(Self.resolved)"))
        #expect(cleaned.cleanedText == "Let's meet on Wednesday at the office.")
        #expect(!cleaned.fellBack)
    }

    @Test func aRejectedRewordingKeepsTheResolvedText() async {
        let captured = RequestRecorder()
        let cleaned = await executor(adapted: true).run(makeSegment(Self.corrected), context: [], options: CleanupOptions(level: .high)) { request in
            await captured.record(request) == 1 ? Self.resolved : "Here is the text: Let's meet on Wednesday."
        }
        #expect(cleaned.cleanedText == Self.resolved)
        #expect(!cleaned.fellBack, "the resolved text passed Medium's review")
        #expect(await captured.all.count == 2)
    }

    @Test func aRejectedResolutionFallsBackWithoutRewording() async {
        let captured = RequestRecorder()
        let cleaned = await executor(adapted: true).run(makeSegment(Self.corrected), context: [], options: CleanupOptions(level: .high)) { request in
            await captured.record(request)
            return "<think>hmm</think>"
        }
        #expect(cleaned.fellBack)
        #expect(cleaned.cleanedText == Self.corrected)
        #expect(await captured.all.count == 1)
    }

    @Test func theRewordingGetsOnlyTheTimeLeft() async {
        let started = ContinuousClock.now
        let captured = RequestRecorder()
        let cleaned = await executor(timeout: 1, adapted: true).run(makeSegment(Self.corrected), context: [], options: CleanupOptions(level: .high)) { request in
            guard await captured.record(request) == 1 else {
                try await Task.sleep(for: .seconds(10))
                return "too late"
            }
            return Self.resolved
        }
        #expect(cleaned.cleanedText == Self.resolved)
        #expect(!cleaned.fellBack)
        #expect(started.duration(to: .now) < .seconds(3), "both passes share one deadline")
    }

    @Test("One pass without a correction cue at High, and at Medium with one", arguments: [
        (CleanupLevel.high, "i think the build is broken on main"),
        (CleanupLevel.medium, corrected),
    ])
    func onePassOtherwise(level: CleanupLevel, text: String) async {
        let captured = RequestRecorder()
        _ = await executor(adapted: true).run(makeSegment(text), context: [], options: CleanupOptions(level: level)) { request in
            await captured.record(request)
            return text
        }
        #expect(await captured.all.count == 1)
    }

    /// Dictation with the cleanup model off inserts this, so it must match what a level does
    /// without the model: fillers go only at Medium and High.
    @Test func deterministicCleanupRemovesFillersOnlyAtMediumAndHigh() {
        let raw = "so um the build is uh broken"
        #expect(CleanupExecutor.deterministicCleanup(of: raw, level: .none) == raw)
        #expect(CleanupExecutor.deterministicCleanup(of: raw, level: .light) == raw)
        #expect(CleanupExecutor.deterministicCleanup(of: raw, level: .medium) == "so the build is broken")
        #expect(CleanupExecutor.deterministicCleanup(of: raw, level: .high) == "so the build is broken")
    }
}

private actor RequestRecorder {
    private(set) var all: [CleanupRequest] = []
    var last: CleanupRequest? { all.last }

    /// Records `request` and returns how many have been recorded, this one included.
    @discardableResult
    func record(_ request: CleanupRequest) -> Int {
        all.append(request)
        return all.count
    }
}
