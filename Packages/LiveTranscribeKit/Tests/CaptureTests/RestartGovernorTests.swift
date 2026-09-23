@testable import Capture
import Testing

@Suite("RestartGovernor")
struct RestartGovernorTests {
    private let start = ContinuousClock.now

    /// Asks the governor at each offset (seconds after `start`) and returns its answers.
    private func decisions(_ governor: inout RestartGovernor, at offsets: [Int]) -> [Bool] {
        offsets.map { governor.allowRestart(at: start + .seconds($0)) }
    }

    @Test func allowsUpToTheLimitWithinTheWindow() {
        var governor = RestartGovernor(maxRestarts: 3, window: .seconds(60))
        #expect(decisions(&governor, at: [0, 1, 2, 3]) == [true, true, true, false], "a route that keeps flipping is stopped")
    }

    @Test func restartsOutsideTheWindowNoLongerCount() {
        var governor = RestartGovernor(maxRestarts: 2, window: .seconds(60))
        #expect(decisions(&governor, at: [0, 30, 59, 61]) == [true, true, false, true], "the first restart ages out at 60 s")
    }

    @Test func refusedRestartsAreNotRecorded() {
        var governor = RestartGovernor(maxRestarts: 1, window: .seconds(10))
        #expect(decisions(&governor, at: [0, 5, 10]) == [true, false, true])
    }

    @Test func limitIsAtLeastOne() {
        var governor = RestartGovernor(maxRestarts: 0)
        #expect(decisions(&governor, at: [0]) == [true])
    }
}

@Suite("RestartGovernor: when the next restart is allowed")
struct RestartGovernorNextAllowedTests {
    private let start = ContinuousClock.now

    @Test("Below the limit, now", arguments: [0, 1])
    func belowTheLimitItIsNow(recorded: Int) {
        var governor = RestartGovernor(maxRestarts: 2, window: .seconds(60))
        for offset in 0..<recorded {
            _ = governor.allowRestart(at: start + .seconds(offset))
        }
        #expect(governor.nextAllowedRestart(after: start + .seconds(5)) == start + .seconds(5))
    }

    @Test func atTheLimitItIsWhenTheOldestAgesOut() {
        var governor = RestartGovernor(maxRestarts: 2, window: .seconds(60))
        _ = governor.allowRestart(at: start)
        _ = governor.allowRestart(at: start + .seconds(10))
        let next = governor.nextAllowedRestart(after: start + .seconds(20))
        #expect(next == start + .seconds(60))
        let allowed = governor.allowRestart(at: next)
        #expect(allowed, "the instant it names is allowed")
    }

    @Test func restartsAlreadyOutsideTheWindowDoNotDelay() {
        var governor = RestartGovernor(maxRestarts: 1, window: .seconds(10))
        _ = governor.allowRestart(at: start)
        #expect(governor.nextAllowedRestart(after: start + .seconds(11)) == start + .seconds(11))
    }
}
