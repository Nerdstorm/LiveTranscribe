import ApplicationServices
import Capture
@testable import Dictation
import Foundation
import Hotkey
import Insertion
import os
import Permissions
import Shared

/// A clock the test moves by hand.
final class ManualClock: Sendable {
    private let base = ContinuousClock.now
    private let offset = OSAllocatedUnfairLock(initialState: Duration.zero)

    func now() -> ContinuousClock.Instant { base + offset.withLock { $0 } }
    func advance(by duration: Duration) { offset.withLock { $0 += duration } }
}

/// Hotkey events pushed by the test.
final class FakeHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    // Test-only: touched from the main actor and from the controller, never concurrently.
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var continuation: AsyncStream<HotkeyEvent>.Continuation?
        var denyPermission = false
        var capturingEscape = false
        var starts: [(HotkeyBinding, HotkeyBinding?)] = []
    }

    func denyPermission(_ deny: Bool) { state.withLock { $0.denyPermission = deny } }
    var capturingEscape: Bool { state.withLock { $0.capturingEscape } }
    var startedBindings: [HotkeyBinding] { state.withLock { $0.starts.map(\.0) } }
    /// Started and not stopped since.
    var isRunning: Bool { state.withLock { $0.continuation != nil } }

    /// Delivers an event, as a key press would; `false` if the monitor is not running.
    @discardableResult
    func send(_ event: HotkeyEvent) -> Bool {
        state.withLock { $0.continuation?.yield(event) } != nil
    }

    func start(binding: HotkeyBinding, undoBinding: HotkeyBinding?) throws -> AsyncStream<HotkeyEvent> {
        try state.withLock { state in
            if state.denyPermission { throw HotkeyError.permissionDenied }
            let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
            state.continuation = continuation
            state.starts.append((binding, undoBinding))
            return stream
        }
    }

    func stop() {
        state.withLock { $0.continuation?.finish(); $0.continuation = nil }
    }

    func setCapturingEscape(_ capturing: Bool) { state.withLock { $0.capturingEscape = capturing } }
}

/// A focused field holding a value and a caret.
struct FakeElement: AccessibilityElement {
    var value: String
    var caret: Int
    var subrole: String?
    var role: String? = kAXTextAreaRole

    func string(_ attribute: String) -> String? { attribute == kAXValueAttribute ? value : nil }
    func range(_ attribute: String) -> NSRange? {
        attribute == kAXSelectedTextRangeAttribute ? NSRange(location: caret, length: 0) : nil
    }
    func setString(_ value: String, for attribute: String) -> Bool { false }
    func setRange(_ range: NSRange, for attribute: String) -> Bool { false }
    func bounds(for range: NSRange) -> CGRect? { CGRect(x: 100, y: 200, width: 2, height: 16) }
    var processIdentifier: pid_t? { 42 }
    func isSameElement(as other: any AccessibilityElement) -> Bool { true }
}

final class FakeFocus: FocusedTargetProvider, @unchecked Sendable {
    private let target = OSAllocatedUnfairLock(initialState: FakeFocus.field(value: "", secure: false))
    /// While set, lookups wait for ``releaseLookups()``, so a test can see the state in between.
    private let gate = OSAllocatedUnfairLock<DispatchSemaphore?>(initialState: nil)

    static let app = AppInfo(bundleIdentifier: "com.example.Notes", name: "Notes", processIdentifier: 42)

    static func field(value: String, secure: Bool) -> InsertionTarget {
        let element = FakeElement(value: value, caret: (value as NSString).length, subrole: secure ? kAXSecureTextFieldSubrole : nil)
        return InsertionTarget(app: app, element: element, secureEventInputEnabled: false)
    }

    /// A focused field whose caret is drawn at `caret`.
    static func field(caret: CGRect) -> InsertionTarget {
        InsertionTarget(app: app, element: nil, isSecure: false, isMultiline: false, caretRect: caret)
    }

    func set(_ target: InsertionTarget) { self.target.withLock { $0 = target } }

    func currentTarget() -> InsertionTarget {
        // Runs on a detached task, never the main actor, so waiting here blocks nothing the test needs.
        gate.withLock { $0 }?.wait()
        return target.withLock { $0 }
    }

    func holdLookups() { gate.withLock { $0 = DispatchSemaphore(value: 0) } }

    func releaseLookups() {
        let semaphore = gate.withLock { gate in
            defer { gate = nil }
            return gate
        }
        semaphore?.signal()
    }
}

actor FakeDelivery: TextDelivery {
    private(set) var inserted: [String] = []
    private(set) var undone: [String] = []
    var result: InsertionResult = .inserted(.accessibility, range: NSRange(location: 0, length: 0))
    var undoResult: UndoResult = .replacedInPlace(range: NSRange(location: 0, length: 0))

    func set(result: InsertionResult) { self.result = result }

    func insert(_ text: String, into target: InsertionTarget) async -> InsertionResult {
        inserted.append(text)
        return result
    }

    func undo(_ record: InsertionRecord, replacingWith text: String, in target: InsertionTarget) async -> UndoResult {
        undone.append(text)
        return undoResult
    }
}

struct FakeMicrophone: MicrophonePermissionProviding {
    let current: MicrophonePermissionStatus
    func status() -> MicrophonePermissionStatus { current }
    func request() async -> Bool { current == .granted }
}

final class FakeAccessibility: AccessibilityPermissionProviding, @unchecked Sendable {
    private let continuation: AsyncStream<Bool>.Continuation
    private let stream: AsyncStream<Bool>
    private let granted: OSAllocatedUnfairLock<Bool>

    init(granted: Bool) {
        self.granted = OSAllocatedUnfairLock(initialState: granted)
        (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        continuation.yield(granted)
    }

    func set(_ value: Bool) {
        granted.withLock { $0 = value }
        continuation.yield(value)
    }

    func isGranted() -> Bool { granted.withLock { $0 } }
    func prompt() {}
    func changes() -> AsyncStream<Bool> { stream }
}

/// Settings the test can change while the controller runs.
final class SettingsBox: Sendable {
    private let settings = OSAllocatedUnfairLock(initialState: AppSettings.defaults)

    var current: AppSettings { settings.withLock { $0 } }
    func update(_ change: (inout AppSettings) -> Void) {
        var copy = current
        change(&copy)
        let updated = copy
        settings.withLock { $0 = updated }
    }
}

/// Model readiness the test can change.
final class ReadinessSwitch: Sendable {
    private let readiness: OSAllocatedUnfairLock<DictationReadiness>

    init(_ readiness: DictationReadiness) { self.readiness = OSAllocatedUnfairLock(initialState: readiness) }

    var current: DictationReadiness { readiness.withLock { $0 } }
    func set(_ value: DictationReadiness) { readiness.withLock { $0 = value } }
}
