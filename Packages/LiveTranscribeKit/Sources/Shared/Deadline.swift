import Foundation

/// Thrown by ``withDeadline(_:operation:)`` when the operation does not finish in time.
public struct DeadlineExceeded: Error, Equatable, Sendable {
    public let seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }
}

/// Runs `operation`, cancelling it cooperatively if it has not finished within `seconds`.
///
/// Returns only after the operation has actually stopped, so callers can safely start the
/// next unit of work on a shared resource (the GPU) as soon as this returns.
public func withDeadline<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw DeadlineExceeded(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw CancellationError()
        }
        return first
    }
}
