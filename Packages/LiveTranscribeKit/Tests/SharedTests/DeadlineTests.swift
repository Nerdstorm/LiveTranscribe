import Shared
import Testing

@Suite("withDeadline")
struct DeadlineTests {
    @Test func returnsTheResultWhenFastEnough() async throws {
        let value = try await withDeadline(seconds: 1) { 42 }
        #expect(value == 42)
    }

    @Test func throwsDeadlineExceededWhenTooSlow() async {
        await #expect(throws: DeadlineExceeded(seconds: 0.05)) {
            try await withDeadline(seconds: 0.05) {
                try await Task.sleep(for: .seconds(5))
                return 0
            }
        }
    }

    @Test func cancelsTheOperationOnTimeout() async throws {
        let probe = CancellationProbe()
        _ = try? await withDeadline(seconds: 0.05) {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                await probe.markCancelled()
            }
            return 0
        }
        // withDeadline returns only after the operation stopped, so the flag is already set.
        #expect(await probe.wasCancelled)
    }

    @Test func propagatesOperationErrors() async {
        struct Boom: Error, Equatable {}
        await #expect(throws: Boom()) {
            try await withDeadline(seconds: 1) { () async throws -> Int in throw Boom() }
        }
    }
}

private actor CancellationProbe {
    private(set) var wasCancelled = false
    func markCancelled() { wasCancelled = true }
}

@Suite("Duration")
struct DurationTests {
    @Test func wholeMilliseconds() {
        #expect(Duration.milliseconds(1_234).wholeMilliseconds == 1_234)
        #expect(Duration.seconds(2).wholeMilliseconds == 2_000)
        #expect(Duration.microseconds(1_999).wholeMilliseconds == 1)
    }
}
