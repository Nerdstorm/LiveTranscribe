@testable import Cleanup
import Foundation
import Shared
import Testing

extension CleanupFixtures {
    /// executor.jsonl: cleanups run with a scripted model. Each case lists what the model does
    /// with each request, in order: reply, fail, take too long, or have the cleanup cancelled
    /// while it runs. The fixture records every request the executor made and what the cleanup
    /// returned.
    enum Executor {
        enum Step: Sendable {
            case reply(String)
            case fail(String)
            /// Keeps generating until the deadline stops it.
            case timeOut
            /// The cleanup is cancelled while the model generates.
            case cancel
        }

        struct Case: Sendable {
            let name: String
            var adapted = true
            var override: PromptTemplate?
            var contextLimit = 3
            var timeoutSeconds: Double = 10
            /// How Deep runs; `nil`, as shipped.
            var deep: DeepCleanup?
            let options: CleanupOptions
            let raw: String
            var context: [String] = []
            let script: [Step]
        }

        struct ScriptStep: Encodable {
            var reply: String?
            var fail: String?
            var timeOut: Bool?
            var cancel: Bool?

            init(_ step: Step) {
                switch step {
                case .reply(let text): reply = text
                case .fail(let message): fail = message
                case .timeOut: timeOut = true
                case .cancel: cancel = true
                }
            }
        }

        struct Cleaned: Encodable {
            let text: String
            let fellBack: Bool
            let fallbackReason: String?
            /// Only when the model never ran: the time a model run takes varies.
            let latencyMs: Int?
        }

        struct Line: Encodable {
            let name: String
            let adapted: Bool
            let override: Template?
            let contextLimit: Int
            let timeoutSeconds: String
            /// How Deep runs; absent, as shipped.
            let deep: Deep?
            let options: Options
            let raw: String
            let context: [String]
            let script: [ScriptStep]
            let requests: [Request]
            let result: Cleaned
        }

        /// A failure with the message the fallback reason carries.
        struct ScriptedFailure: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }

        static func lines() async throws -> [String] {
            var lines: [String] = []
            for testCase in cases {
                lines.append(try CleanupFixtures.line(await line(for: testCase)))
            }
            return lines
        }

        private static func line(for testCase: Case) async -> Line {
            let executor = CleanupExecutor(
                contextLimit: testCase.contextLimit,
                timeoutSeconds: testCase.timeoutSeconds,
                prompts: PromptBuilder(adapted: testCase.adapted, override: testCase.override),
                deep: testCase.deep ?? .shipped
            )
            let recorder = Recorder()
            let canceller = Canceller()
            let script = testCase.script
            let segment = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: testCase.raw)
            let task = Task {
                await executor.run(segment, context: testCase.context, options: testCase.options) { request in
                    let index = await recorder.record(request)
                    guard index < script.count else { throw ScriptedFailure(message: "the script has no step for this request") }
                    switch script[index] {
                    case .reply(let text):
                        return text
                    case .fail(let message):
                        throw ScriptedFailure(message: message)
                    case .timeOut:
                        try await Task.sleep(for: .seconds(60))
                        return "too late"
                    case .cancel:
                        await canceller.cancel()
                        try await Task.sleep(for: .seconds(60))
                        return "cancelled"
                    }
                }
            }
            await canceller.set(task)
            let cleaned = await task.value
            let requests = await recorder.requests
            #expect(requests.count == script.count, "\(testCase.name): one step per request")
            return Line(
                name: testCase.name,
                adapted: testCase.adapted,
                override: testCase.override.map(Template.init),
                contextLimit: testCase.contextLimit,
                timeoutSeconds: number(testCase.timeoutSeconds),
                deep: testCase.deep.map(Deep.init),
                options: Options(testCase.options),
                raw: testCase.raw,
                context: testCase.context,
                script: script.map(ScriptStep.init),
                requests: requests.map(Request.init),
                result: Cleaned(
                    text: cleaned.cleanedText,
                    fellBack: cleaned.fellBack,
                    fallbackReason: cleaned.fallbackReason,
                    latencyMs: requests.isEmpty ? cleaned.latencyMs : nil
                )
            )
        }

        private actor Recorder {
            private(set) var requests: [CleanupRequest] = []

            /// Records `request` and returns its index.
            func record(_ request: CleanupRequest) -> Int {
                requests.append(request)
                return requests.count - 1
            }
        }

        /// Cancels the cleanup's task, as soon as it is known.
        private actor Canceller {
            private var task: Task<CleanedSegment, Never>?
            private var cancelled = false

            func set(_ task: Task<CleanedSegment, Never>) {
                self.task = task
                if cancelled { task.cancel() }
            }

            func cancel() {
                cancelled = true
                task?.cancel()
            }
        }

        // MARK: - Cases

        private static let brokenBuild = "i think the build is broken on main"
        private static let corrected = "meet on tuesday no wait wednesday at the office"
        private static let resolved = "Meet on Wednesday at the office."
        private static let medium = CleanupOptions(level: .medium)
        private static let high = CleanupOptions(level: .high)
        static let override = PromptTemplate(
            system: "Fix the TEXT.",
            examples: [.init(text: "um hello", cleaned: "Hello.")]
        )

        static var cases: [Case] {
            unitTestCases + aliasCases + highCases + otherCases + deepCases
        }

        /// CleanupExecutorTests, as scripts.
        private static var unitTestCases: [Case] {
            let sinhala = ["ඒකෙ තියෙන magic වැඩ um", "um ඔන්න මගේ film එකතුවට"].flatMap { text in
                [CleanupLevel.light, .medium, .high].map { level in
                    Case(name: "Sinhala skips the model at \(level.rawValue)", options: CleanupOptions(level: level), raw: text, script: [])
                }
            }
            return [
                Case(name: "accepted output replaces the raw text", options: medium, raw: brokenBuild, script: [.reply("I think the build is broken on main.")]),
                Case(name: "a generation error falls back", options: medium, raw: brokenBuild, script: [.fail("GPU error")]),
                Case(name: "slow generation times out", timeoutSeconds: 0.3, options: medium, raw: brokenBuild, script: [.timeOut]),
                Case(name: "a guard rejection falls back", options: medium, raw: brokenBuild, script: [.reply("<think>hmm</think> I think the build is broken.")]),
                Case(
                    name: "context goes through the window",
                    options: medium,
                    raw: brokenBuild,
                    context: ["a.", "b.", "c.", "d."],
                    script: [.reply("I think the build is broken on main.")]
                ),
                Case(name: "empty raw text skips the model", options: CleanupOptions(level: .light), raw: "  ", script: []),
                Case(name: "None returns the raw text without the model", options: CleanupOptions(level: .none), raw: "um so the the build is broken", script: []),
                Case(name: "English goes to the model", options: medium, raw: "the build is broken", script: [.reply("The build is broken.")]),
                Case(name: "Medium removes fillers first", options: medium, raw: "so um the build is uh broken", script: [.reply("So the build is broken.")]),
                Case(name: "Light keeps fillers", options: CleanupOptions(level: .light), raw: "so um the build is broken", script: [.reply("So, um, the build is broken.")]),
                Case(name: "a fallback keeps the fillers removed", options: medium, raw: "so um the build is uh broken", script: [.reply("Here is the text: So the build is broken.")]),
                Case(name: "only fillers leaves nothing to clean", options: medium, raw: "um uh", script: []),
                Case(
                    name: "options shape the prompt",
                    options: CleanupOptions(level: .high, vocabulary: ["Nerdstorm"], placeholders: ["⟦S1⟧"]),
                    raw: "email ⟦S1⟧ to the nerd storm team",
                    script: [.reply("Email S1 to the Nerdstorm team.")]
                ),
                Case(
                    name: "a damaged placeholder falls back",
                    adapted: false,
                    options: CleanupOptions(level: .medium, placeholders: ["⟦S1⟧"]),
                    raw: "email ⟦S1⟧ to the team",
                    script: [.reply("Email S 1 to the team.")]
                ),
                Case(name: "High resolves, then rewords", options: CleanupOptions(level: .high, vocabulary: ["Acme"]), raw: corrected, script: [.reply(resolved), .reply("Let's meet on Wednesday at the office.")]),
                Case(name: "a rejected rewording keeps the resolved text", options: high, raw: corrected, script: [.reply(resolved), .reply("Here is the text: Let's meet on Wednesday.")]),
                Case(name: "a rejected resolution falls back without rewording", options: high, raw: corrected, script: [.reply("<think>hmm</think>")]),
                Case(name: "the rewording gets only the time left", timeoutSeconds: 0.3, options: high, raw: corrected, script: [.reply(resolved), .timeOut]),
                Case(name: "one pass at High without a cue", options: high, raw: brokenBuild, script: [.reply(brokenBuild)]),
                Case(name: "one pass at Medium with a cue", options: medium, raw: corrected, script: [.reply(corrected)]),
            ] + sinhala
        }

        /// What the model sees for placeholders, and what comes back.
        private static var aliasCases: [Case] {
            let one = CleanupOptions(level: .medium, placeholders: ["⟦S1⟧"])
            let two = CleanupOptions(level: .medium, placeholders: ["⟦S1⟧", "⟦S2⟧"])
            let twelve = (1...12).map { "⟦S\($0)⟧" }
            return [
                Case(name: "an alias is never a word in the text", options: one, raw: "fill in the s1 form and send ⟦S1⟧", script: [.reply("Fill in the S1 form and send T1.")]),
                Case(name: "with no free letter the model sees the tokens", options: one, raw: "S1 T2 P3 Q4 Z5 ⟦S1⟧", script: [.reply("S1 T2 P3 Q4 Z5 ⟦S1⟧.")]),
                Case(name: "an alias comes back in any case", options: two, raw: "send ⟦S1⟧ to ⟦S2⟧", script: [.reply("Send s1 to S2.")]),
                Case(name: "a dropped alias is left for the guard", options: two, raw: "send ⟦S1⟧ to ⟦S2⟧", script: [.reply("Send it to S2.")]),
                Case(name: "a repeated alias is left for the guard", options: two, raw: "send ⟦S1⟧ to ⟦S2⟧", script: [.reply("Send S1 to S1 and S2.")]),
                Case(name: "the model keeps a token", options: two, raw: "send ⟦S1⟧ to ⟦S2⟧", script: [.reply("Send ⟦S1⟧ to S2.")]),
                Case(name: "an alias inside a word stays", options: two, raw: "send ⟦S1⟧ to ⟦S2⟧", script: [.reply("Send S1 to S2S1.")]),
                Case(
                    name: "twelve placeholders",
                    options: CleanupOptions(level: .medium, placeholders: twelve),
                    raw: twelve.joined(separator: " and "),
                    script: [.reply((1...12).map { "S\($0)" }.joined(separator: " and ") + ".")]
                ),
                Case(
                    name: "placeholders in the context stay as they are",
                    options: one,
                    raw: "and ⟦S1⟧ too",
                    context: ["Sent ⟦S1⟧ earlier."],
                    script: [.reply("And S1 too.")]
                ),
                Case(
                    name: "a placeholder the options don't list",
                    options: medium,
                    raw: "send ⟦S1⟧ now",
                    script: [.reply("Send ⟦S1⟧ now.")]
                ),
                Case(
                    name: "a token repeated in the options",
                    options: CleanupOptions(level: .light, placeholders: ["⟦S1⟧", "⟦S1⟧"]),
                    raw: "send ⟦S1⟧ now",
                    script: [.reply("Send S1 now.")]
                ),
                Case(
                    name: "the alias letter skips words in the text",
                    options: one,
                    raw: "s1 t1 p1 on ⟦S1⟧",
                    script: [.reply("S1 T1 P1 on Q1.")]
                ),
            ]
        }

        /// High's two passes, whatever each of them does.
        private static var highCases: [Case] {
            [
                Case(name: "a failed rewording keeps the resolved text", options: high, raw: corrected, script: [.reply(resolved), .fail("GPU error")]),
                Case(name: "a cancelled rewording keeps the resolved text", options: high, raw: corrected, script: [.reply(resolved), .cancel]),
                Case(name: "a cancelled resolution falls back", options: high, raw: corrected, script: [.cancel]),
                Case(name: "a timed-out resolution falls back", timeoutSeconds: 0.3, options: high, raw: corrected, script: [.timeOut]),
                Case(name: "a failed resolution falls back", options: high, raw: corrected, script: [.fail("cleanup model not loaded")]),
                Case(name: "an empty rewording keeps the resolved text", options: high, raw: corrected, script: [.reply(resolved), .reply(" ")]),
                Case(
                    name: "both passes see the placeholders as words",
                    options: CleanupOptions(level: .high, vocabulary: ["Jane"], placeholders: ["⟦S1⟧"]),
                    raw: "send ⟦S1⟧ to john sorry jane",
                    context: ["Earlier.", "Before that."],
                    script: [.reply("Send S1 to Jane."), .reply("Please send S1 to Jane.")]
                ),
                Case(
                    name: "High without the adapter",
                    adapted: false,
                    options: high,
                    raw: corrected,
                    script: [.reply(resolved), .reply("Let's meet on Wednesday at the office.")]
                ),
                Case(
                    name: "a resolution that keeps the cue is reworded",
                    options: high,
                    raw: corrected,
                    script: [.reply("Meet on Tuesday, no wait, Wednesday at the office."), .reply("Meet on Tuesday, no, wait, Wednesday, at the office.")]
                ),
                Case(
                    name: "a resolution at Medium's standard stands when the rewording drops a word",
                    options: high,
                    raw: "send the report to john sorry jane by friday",
                    script: [.reply("Send the report to Jane by Friday."), .reply("Send the report to Jane.")]
                ),
                Case(name: "High removes fillers before resolving", options: high, raw: "um meet on tuesday uh no wait wednesday", script: [.reply("Meet on Wednesday."), .reply("Let's meet on Wednesday.")]),
                Case(name: "a cue in the context does not make two passes", options: high, raw: brokenBuild, context: ["Sorry, I mean it."], script: [.reply("I think the build is broken on main.")]),
                Case(name: "a cue at High with the prompt overridden", override: override, options: high, raw: corrected, script: [.reply(resolved), .reply(resolved)]),
            ]
        }

        private static var otherCases: [Case] {
            [
                Case(name: "the model not loaded falls back", options: medium, raw: brokenBuild, script: [.fail("cleanup model not loaded")]),
                Case(name: "cancelled at Medium", options: medium, raw: brokenBuild, script: [.cancel]),
                Case(name: "cancelled at Light", options: CleanupOptions(level: .light), raw: brokenBuild, script: [.cancel]),
                Case(name: "timed out at Light", timeoutSeconds: 0.3, options: CleanupOptions(level: .light), raw: brokenBuild, script: [.timeOut]),
                Case(name: "an empty reply falls back", options: medium, raw: brokenBuild, script: [.reply("  \n")]),
                Case(name: "a reply is trimmed", options: medium, raw: brokenBuild, script: [.reply("\n I think the build is broken on main.  ")]),
                Case(name: "Light rejects a resolved correction", options: CleanupOptions(level: .light), raw: "we should meet on tuesday sorry wednesday", script: [.reply("We should meet on Wednesday.")]),
                Case(name: "Medium accepts a resolved correction", options: medium, raw: "we should meet on tuesday sorry wednesday", script: [.reply("We should meet on Wednesday.")]),
                Case(
                    name: "blank context is skipped",
                    contextLimit: 2,
                    options: medium,
                    raw: brokenBuild,
                    context: ["First.", "  ", "\n", "Second. ", ""],
                    script: [.reply("I think the build is broken on main.")]
                ),
                Case(name: "no context with a limit of 0", contextLimit: 0, options: medium, raw: brokenBuild, context: ["a.", "b."], script: [.reply(brokenBuild)]),
                Case(
                    name: "a prompt override with examples",
                    adapted: false,
                    override: override,
                    options: CleanupOptions(level: .light, vocabulary: ["Ignored"]),
                    raw: brokenBuild,
                    context: ["Earlier."],
                    script: [.reply("I think the build is broken on main.")]
                ),
                Case(name: "Light with the adapter loaded", options: CleanupOptions(level: .light, vocabulary: ["Main"]), raw: brokenBuild, script: [.reply("I think the build is broken on Main.")]),
                Case(name: "a Sinhala word in English skips the model", options: medium, raw: "send the ශ්‍රී file", script: []),
                Case(name: "the first Sinhala scalar skips the model", options: medium, raw: "boundary \u{0D80}", script: []),
                Case(name: "the last Sinhala scalar skips the model", options: medium, raw: "boundary \u{0DFF}", script: []),
                Case(name: "the scalar before Sinhala goes to the model", options: medium, raw: "boundary \u{0D7F}", script: [.reply("Boundary \u{0D7F}")]),
                Case(name: "the scalar after Sinhala goes to the model", options: medium, raw: "boundary \u{0E00}", script: [.reply("Boundary \u{0E00}")]),
                Case(name: "Sinhala at None is left alone", options: CleanupOptions(level: .none), raw: "um ශ්‍රී", script: []),
                Case(name: "punctuation only goes to the model", options: medium, raw: "…", script: [.reply("…")]),
                Case(name: "whitespace of every kind skips the model", options: CleanupOptions(level: .light), raw: "\u{00A0}\u{2028}\u{3000}\t", script: []),
                Case(name: "fillers and their punctuation leave nothing to clean", options: medium, raw: "um, uh.", script: []),
                Case(
                    name: "a long text's token budget",
                    options: medium,
                    raw: Array(repeating: "and then we talked about the plan", count: 12).joined(separator: " "),
                    script: [.reply("And then we talked about the plan.")]
                ),
            ]
        }
    }
}
