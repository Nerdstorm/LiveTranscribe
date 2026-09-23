@testable import Dictation
import Foundation
import Persistence
import Shared
import Testing

/// A menu bar app runs for weeks without a relaunch or a settings change, so the controller
/// keeps to the history retention on its own: periodically, and after a saved dictation.
@MainActor
@Suite("Dictation history retention")
struct DictationHistoryRetentionTests {
    /// A dictation made `days` days ago.
    private func record(daysAgo days: Double) -> DictationRecord {
        DictationRecord(
            id: UUID(),
            createdAt: Date().addingTimeInterval(-days * 86_400),
            appName: "Notes",
            bundleIdentifier: "com.example.Notes",
            rawText: "\(days) days ago",
            cleanedText: "\(days) days ago.",
            cleanupLevel: "medium",
            fellBack: false,
            fallbackReason: nil,
            delivery: "accessibility",
            audioDurationMs: 1_000,
            latencyMs: 200
        )
    }

    /// Keeps a week, pruned every `minutes`.
    private func harness(retentionDays: Int = 7, minutes: Int = 60) -> Harness {
        Harness {
            $0.dictation.historyRetentionDays = retentionDays
            $0.dictation.historyPruneIntervalMinutes = minutes
        }
    }

    private func contains(_ record: DictationRecord, in history: MemoryDictationHistory) async -> Bool {
        await history.records.contains { $0.id == record.id }
    }

    // MARK: - Periodic prune

    @Test func aRunningControllerPrunesEveryInterval() async throws {
        let h = harness(minutes: 30)
        h.controller.start()
        defer { h.controller.stop() }
        #expect(await eventually { h.pruneTimer.waiters == 1 })
        #expect(h.pruneTimer.requested == [.seconds(1_800)], "the interval from Settings")

        // Past the retention since the launch prune, with no settings change since.
        let expired = record(daysAgo: 8)
        let recent = record(daysAgo: 1)
        try await h.history.append(expired)
        try await h.history.append(recent)

        h.pruneTimer.fire()
        #expect(await eventuallyAsync { await !contains(expired, in: h.history) })
        #expect(await contains(recent, in: h.history))
        #expect(await eventually { h.pruneTimer.waiters == 1 }, "and waits for the next one")
    }

    @Test func aNewIntervalAppliesFromTheNextWait() async {
        let settings = SettingsBox()
        let h = Harness(settings: settings)
        h.controller.start()
        defer { h.controller.stop() }
        #expect(await eventually { h.pruneTimer.waiters == 1 })
        settings.update { $0.dictation.historyPruneIntervalMinutes = 5 }

        h.pruneTimer.fire()
        #expect(await eventually { h.pruneTimer.waiters == 1 })
        #expect(h.pruneTimer.requested == [.seconds(3_600), .seconds(300)])
    }

    @Test func stoppingEndsThePeriodicPrune() async {
        let h = harness()
        h.controller.start()
        #expect(await eventually { h.pruneTimer.waiters == 1 })
        h.controller.stop()
        #expect(await eventually { h.pruneTimer.waiters == 0 }, "the wait is cancelled")

        h.controller.start()
        #expect(await eventually { h.pruneTimer.waiters == 1 }, "and starts again with the controller")
        h.controller.stop()
    }

    // MARK: - After a saved dictation

    @Test func aSavedDictationPrunesOnceTheIntervalHasPassed() async throws {
        let h = harness()
        let atLaunch = record(daysAgo: 9)
        try await h.history.append(atLaunch)
        h.controller.start()
        defer { h.controller.stop() }
        #expect(await eventuallyAsync { await !contains(atLaunch, in: h.history) }, "the launch prune")
        let expired = record(daysAgo: 8)
        try await h.history.append(expired)

        // The launch prune ran moments ago, so this save leaves the history alone.
        await h.hold(milliseconds: 400)
        await h.release()
        #expect(await h.history.records.count == 2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await contains(expired, in: h.history), "pruned at most once per interval")

        // An hour later, with the periodic prune not having run, the next save prunes.
        h.clock.advance(by: .seconds(3_600))
        await h.hold(milliseconds: 400)
        await h.release()
        #expect(await eventuallyAsync { await !contains(expired, in: h.history) })
        #expect(await h.history.records.count == 2, "both new dictations stay")
    }

    @Test func withoutARetentionNothingIsPruned() async throws {
        let h = harness(retentionDays: 0)
        h.controller.start()
        defer { h.controller.stop() }
        let old = record(daysAgo: 400)
        try await h.history.append(old)
        #expect(await eventually { h.pruneTimer.waiters == 1 })

        h.clock.advance(by: .seconds(3_600))
        await h.hold(milliseconds: 400)
        await h.release()
        h.pruneTimer.fire()
        #expect(await eventually { h.pruneTimer.waiters == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await contains(old, in: h.history), "0 days keeps everything (decision H2)")
    }
}
