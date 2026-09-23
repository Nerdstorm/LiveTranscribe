import Foundation
import Persistence

/// Records for the history tests.
enum HistoryListFixtures {
    static func record(
        text: String,
        raw: String? = nil,
        app: String? = "Notes",
        at seconds: TimeInterval = 0,
        fellBack: Bool = false
    ) -> DictationRecord {
        DictationRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds),
            appName: app,
            bundleIdentifier: app.map { "com.example.\($0)" },
            rawText: raw ?? text,
            cleanedText: text,
            cleanupLevel: "medium",
            fellBack: fellBack,
            fallbackReason: fellBack ? "output too short" : nil,
            delivery: "accessibility",
            audioDurationMs: 4_200,
            latencyMs: 820
        )
    }
}

/// A history whose first ``all()`` returns what it held at that moment, but only after the test
/// opens the gate; later calls answer at once. Lets a test overlap two loads.
actor GatedHistory: DictationHistory {
    private var records: [DictationRecord]
    private var gate: CheckedContinuation<Void, Never>?
    private var holding: CheckedContinuation<Void, Never>?
    private var gated = true

    init(records: [DictationRecord]) {
        self.records = records
    }

    /// Returns once the first ``all()`` is waiting at the gate.
    func waitUntilHeld() async {
        guard gate == nil else { return }
        await withCheckedContinuation { holding = $0 }
    }

    func open() {
        gate?.resume()
        gate = nil
    }

    func all() async throws -> [DictationRecord] {
        let snapshot = Array(records.reversed())
        if gated {
            gated = false
            await withCheckedContinuation { continuation in
                gate = continuation
                holding?.resume()
                holding = nil
            }
        }
        return snapshot
    }

    func append(_ record: DictationRecord) async throws { records.append(record) }
    func recent(limit: Int) async throws -> [DictationRecord] { Array(try await all().prefix(max(limit, 0))) }
    func delete(id: UUID) async throws { records.removeAll { $0.id == id } }
    func prune(olderThan cutoff: Date) async throws -> Int { 0 }
    func clear() async throws { records = [] }
}
