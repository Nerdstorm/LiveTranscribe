@testable import Cleanup
import Foundation
import Shared

/// Deep's cleanups as scripts: DeepCleanupTests, then Medium's fallback and Medium's pass first
/// whatever each pass does, thinking, layout and placeholders.
extension CleanupFixtures.Executor {
    private static let kirk = "I tried to speak with Kirk, but he didn't. I don't think he actually check whether the release is tomorrow. No, sorry, the after tomorrow."
    private static let repaired = "I tried to speak with Kirk, but he didn't. I don't think he actually checked whether the release is the day after tomorrow."
    private static let lease = "the lease ends in april no wait may"
    private static let meeting = "The meeting is on Tuesday. Sorry, Wednesday. We will review the the budget."
    private static let meetingResolved = "The meeting is on Wednesday. We will review the budget."
    private static let deep = CleanupOptions(level: .deep)

    /// Deep as tools vary it, with a deadline short enough to wait for.
    private static func deepCleanup(
        passes: DeepCleanup.Passes = .one,
        adapter: CleanupRequest.Adapter = .deep,
        thinking: Bool = false,
        fallsBackToMedium: Bool = true,
        minimumTimeoutSeconds: Double = 0.3
    ) -> DeepCleanup {
        DeepCleanup(
            passes: passes, adapter: adapter, thinking: thinking, thinkingTokens: 64,
            fallsBackToMedium: fallsBackToMedium, minimumTimeoutSeconds: minimumTimeoutSeconds
        )
    }

    /// DeepCleanupTests, as scripts, then Medium's fallback and Medium's pass first whatever
    /// each pass does, thinking, layout and placeholders.
    static var deepCases: [Case] {
        let afterMedium = deepCleanup(passes: .afterMedium, adapter: .off, minimumTimeoutSeconds: 8)
        let thinking = deepCleanup(thinking: true, fallsBackToMedium: false, minimumTimeoutSeconds: 8)
        let alone = deepCleanup(fallsBackToMedium: false, minimumTimeoutSeconds: 8)
        return [
            // DeepCleanupTests
            Case(name: "Deep accepts a repair in one pass", options: deep, raw: kirk, script: [.reply(repaired)]),
            Case(name: "Deep without the adapter", deep: deepCleanup(adapter: .off, minimumTimeoutSeconds: 8), options: deep, raw: kirk, script: [.reply(repaired)]),
            Case(name: "Deep with the self-correction adapter", deep: deepCleanup(adapter: .medium, minimumTimeoutSeconds: 8), options: deep, raw: kirk, script: [.reply(repaired)]),
            Case(name: "a rejected repair gets Medium's cleanup", options: deep, raw: lease, script: [.reply("The lease ends in April."), .reply("The lease ends in May.")]),
            Case(name: "when Medium's cleanup is rejected too, what was said is shown", options: deep, raw: lease, script: [.reply("The lease ends in April."), .reply("The lease ends in April.")]),
            Case(name: "no answer in time is not retried", timeoutSeconds: 0.3, deep: deepCleanup(), options: deep, raw: kirk, script: [.timeOut]),
            Case(name: "without the fallback a rejected repair shows what was said", deep: alone, options: deep, raw: lease, script: [.reply("The lease ends in April.")]),
            Case(name: "after Medium, Medium resolves first, then Deep repairs", deep: afterMedium, options: deep, raw: meeting, script: [.reply(meetingResolved), .reply(meetingResolved)]),
            Case(
                name: "after Medium, Medium's result stands when the repair is rejected",
                deep: afterMedium,
                options: deep,
                raw: "The meeting is on Tuesday. Sorry, Wednesday.",
                script: [.reply("The meeting is on Wednesday."), .reply("The meeting is on Wednesday, as agreed.")]
            ),
            Case(name: "after Medium, one pass without a cue", deep: afterMedium, options: deep, raw: "she don't know", script: [.reply("She doesn't know.")]),
            Case(
                name: "thinking is sampled and its reasoning removed",
                deep: thinking,
                options: deep,
                raw: kirk,
                script: [.reply("<think>\nThe speaker corrects tomorrow to the day after tomorrow.\n</think>\n\n\(repaired)")]
            ),
            Case(name: "unfinished thinking falls back", deep: thinking, options: deep, raw: kirk, script: [.reply("<think>\nThe speaker says tomorrow, then")]),
            Case(name: "thinking tags without thinking are rejected", deep: alone, options: deep, raw: kirk, script: [.reply("<think></think>\(repaired)")]),
            Case(name: "Deep waits for its own minimum", timeoutSeconds: 0.05, deep: deepCleanup(), options: deep, raw: kirk, script: [.timeOut]),
            Case(name: "the Advanced timeout applies when it is longer", timeoutSeconds: 0.4, deep: deepCleanup(), options: deep, raw: kirk, script: [.timeOut]),

            // Medium's fallback, whatever it does.
            Case(name: "a failed repair is not retried", options: deep, raw: kirk, script: [.fail("GPU error")]),
            Case(name: "a cancelled repair is not retried", options: deep, raw: kirk, script: [.cancel]),
            Case(name: "an empty repair gets Medium's cleanup", options: deep, raw: lease, script: [.reply(" \n"), .reply("The lease ends in May.")]),
            Case(name: "a failed fallback keeps Deep's reason", options: deep, raw: lease, script: [.reply("The lease ends in April."), .fail("GPU error")]),
            Case(name: "a cancelled fallback keeps Deep's reason", options: deep, raw: lease, script: [.reply("The lease ends in April."), .cancel]),
            Case(
                name: "the fallback gets only the time left",
                timeoutSeconds: 0.3,
                deep: deepCleanup(),
                options: deep,
                raw: lease,
                script: [.reply("The lease ends in April."), .timeOut]
            ),
            Case(name: "unfinished thinking gets Medium's cleanup", deep: deepCleanup(thinking: true, minimumTimeoutSeconds: 8), options: deep, raw: lease, script: [.reply("<think>\nApril, then"), .reply("The lease ends in May.")]),
            Case(name: "leaked thinking tags get Medium's cleanup", options: deep, raw: lease, script: [.reply("<think>April</think> The lease ends in May."), .reply("The lease ends in May.")]),
            Case(name: "a preamble gets Medium's cleanup", options: deep, raw: lease, script: [.reply("Here is the text: The lease ends in May."), .reply("The lease ends in May.")]),

            // Medium's pass first, whatever each pass does.
            Case(
                name: "after Medium, a rejected resolution leaves the repair to Deep",
                deep: afterMedium,
                options: deep,
                raw: lease,
                script: [.reply("The lease ends in June."), .reply("The lease ends in May.")]
            ),
            Case(
                name: "after Medium, a rejected resolution and repair fall back without a third pass",
                deep: afterMedium,
                options: deep,
                raw: lease,
                script: [.reply("The lease ends in June."), .reply("The lease ends in April.")]
            ),
            Case(
                name: "after Medium, a timed-out resolution leaves no time",
                timeoutSeconds: 0.3,
                deep: deepCleanup(passes: .afterMedium),
                options: deep,
                raw: lease,
                script: [.timeOut]
            ),
            Case(
                name: "after Medium, a timed-out repair keeps Medium's result",
                timeoutSeconds: 0.3,
                deep: deepCleanup(passes: .afterMedium),
                options: deep,
                raw: lease,
                script: [.reply("The lease ends in May."), .timeOut]
            ),
            Case(name: "after Medium, a cancelled resolution falls back", deep: afterMedium, options: deep, raw: lease, script: [.cancel]),
            Case(
                name: "after Medium, a failed repair keeps Medium's result",
                deep: afterMedium,
                options: deep,
                raw: lease,
                script: [.reply("The lease ends in May."), .fail("GPU error")]
            ),
            Case(
                name: "after Medium, without a cue a rejected repair gets Medium's cleanup",
                deep: afterMedium,
                options: deep,
                raw: "she don't know",
                script: [.reply("She doesn't know anything."), .reply("She doesn't know.")]
            ),
            Case(
                name: "after Medium, then thinking",
                deep: deepCleanup(passes: .afterMedium, thinking: true, minimumTimeoutSeconds: 8),
                options: deep,
                raw: meeting,
                script: [.reply(meetingResolved), .reply("<think>\nFine.\n</think>\(meetingResolved)")]
            ),

            // Layout, placeholders, context and what reaches the model.
            Case(
                name: "Deep lays out a list in a field that takes several lines",
                options: CleanupOptions(level: .deep, multiline: true),
                raw: "I need to buy milk, eggs and bread.",
                script: [.reply("I need to buy:\n- Milk\n- Eggs\n- Bread")]
            ),
            Case(
                name: "lines in a one-line field get Medium's cleanup",
                options: deep,
                raw: "I need to buy milk, eggs and bread.",
                script: [.reply("I need to buy:\n- Milk\n- Eggs\n- Bread"), .reply("I need to buy milk, eggs and bread.")]
            ),
            Case(
                name: "Deep sees the placeholders as words",
                options: CleanupOptions(level: .deep, vocabulary: ["Jane"], placeholders: ["⟦S1⟧"]),
                raw: "send ⟦S1⟧ to john. sorry, jane.",
                context: ["Earlier.", "Before that."],
                script: [.reply("Send S1 to Jane.")]
            ),
            Case(
                name: "a thinking seed comes from the text the model sees",
                deep: thinking,
                options: CleanupOptions(level: .deep, placeholders: ["⟦S1⟧", "⟦S2⟧"]),
                raw: "send ⟦S1⟧ to ⟦S2⟧ tomorrow",
                script: [.reply("<think>ok</think>Send S1 to S2 tomorrow.")]
            ),
            Case(
                name: "Medium's fallback sees the placeholders as words too",
                options: CleanupOptions(level: .deep, placeholders: ["⟦S1⟧"], multiline: true),
                raw: "send ⟦S1⟧ to john sorry jane",
                script: [.reply("Send S1 to John and Jane."), .reply("Send S1 to Jane.")]
            ),
            Case(name: "Deep removes fillers first", options: deep, raw: "um the lease ends in april uh no wait may", script: [.reply("The lease ends in May.")]),
            Case(name: "Deep without the self-correction adapter loaded", adapted: false, options: deep, raw: lease, script: [.reply("The lease ends in April."), .reply("The lease ends in May.")]),
            Case(name: "Deep with the prompt overridden", override: override, options: deep, raw: kirk, script: [.reply(repaired)]),
            Case(name: "Sinhala skips the model at deep", options: deep, raw: "ඒකෙ තියෙන magic වැඩ um", script: []),
            Case(name: "only fillers leave Deep nothing to clean", options: deep, raw: "um uh", script: []),
        ]
    }
}
