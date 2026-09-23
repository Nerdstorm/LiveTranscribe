import Capture
import Dictation
@testable import DictationUI
import Observation
import os
import Permissions
import Testing

/// A microphone permission whose status the test sets; `request()` answers with `grantOnRequest`.
private final class FakeMicrophone: MicrophonePermissionProviding {
    private let state = OSAllocatedUnfairLock(initialState: (status: MicrophonePermissionStatus.undetermined, grant: true, requests: 0))

    var currentStatus: MicrophonePermissionStatus {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }

    var grantOnRequest: Bool {
        get { state.withLock { $0.grant } }
        set { state.withLock { $0.grant = newValue } }
    }

    var requests: Int { state.withLock { $0.requests } }

    func status() -> MicrophonePermissionStatus { currentStatus }

    func request() async -> Bool {
        state.withLock { state in
            state.requests += 1
            if state.status == .undetermined { state.status = state.grant ? .granted : .denied }
            return state.status == .granted
        }
    }
}

/// An Accessibility permission the test grants or revokes; changes are pushed to `changes()`.
private final class FakeAccessibility: AccessibilityPermissionProviding {
    private let state = OSAllocatedUnfairLock(
        initialState: (granted: false, canPost: true, prompts: 0, continuation: AsyncStream<Bool>.Continuation?.none)
    )

    /// What ``canPostKeystrokes()`` answers. Not streamed: it changes only with Accessibility.
    var postsKeystrokes: Bool {
        get { state.withLock { $0.canPost } }
        set { state.withLock { $0.canPost = newValue } }
    }

    var prompts: Int { state.withLock { $0.prompts } }

    /// Whether someone is following ``changes()``.
    var hasSubscriber: Bool { state.withLock { $0.continuation != nil } }

    func set(granted: Bool) {
        let continuation = state.withLock { state in
            state.granted = granted
            return state.continuation
        }
        continuation?.yield(granted)
    }

    func finish() {
        state.withLock { $0.continuation }?.finish()
    }

    func isGranted() -> Bool { state.withLock { $0.granted } }

    func canPostKeystrokes() -> Bool { postsKeystrokes }

    func prompt() { state.withLock { $0.prompts += 1 } }

    func changes() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let granted = state.withLock { state in
            state.continuation = continuation
            return state.granted
        }
        continuation.yield(granted)
        return stream
    }
}

@Suite("Permissions settings")
@MainActor
struct PermissionsSettingsModelTests {
    private let microphone = FakeMicrophone()
    private let accessibility = FakeAccessibility()

    /// This test's launch: a fresh memory, so tests don't share the app-wide one.
    private let promptMemory = PermissionsSettingsPromptMemory()

    private func model(
        opened: @escaping @MainActor (RequiredPermission) -> Bool = { _ in true },
        reopen: @escaping @MainActor () -> Bool = { true }
    ) -> PermissionsSettingsModel {
        PermissionsSettingsModel(
            microphonePermission: microphone,
            accessibility: accessibility,
            promptMemory: promptMemory,
            openSettings: opened,
            reopenApp: reopen
        )
    }

    @Test func anUndeterminedMicrophoneIsRequested() async {
        let model = model()
        #expect(model.statusText(.microphone) == "Not asked yet")
        #expect(model.action(for: .microphone) == .request)

        await model.perform(.request, for: .microphone)
        #expect(microphone.requests == 1)
        #expect(model.isGranted(.microphone))
        #expect(model.statusText(.microphone) == "Allowed")
        #expect(model.action(for: .microphone) == nil)
    }

    @Test func aDeniedMicrophoneOpensSystemSettings() async {
        microphone.currentStatus = .denied
        var opened: [RequiredPermission] = []
        let model = model { opened.append($0); return true }
        #expect(model.statusText(.microphone) == "Not allowed")
        #expect(model.action(for: .microphone) == .openSettings)
        await model.perform(.openSettings, for: .microphone)
        #expect(opened == [.microphone])
        #expect(microphone.requests == 0)
    }

    @Test func aPaneThatWillNotOpenSaysWhereToGo() async {
        microphone.currentStatus = .denied
        let model = model { _ in false }
        await model.perform(.openSettings, for: .microphone)
        #expect(model.errorMessage == "Couldn't open System Settings. Open it from the Apple menu, then choose Privacy & Security › Microphone.")
        #expect(model.errorMessage == RequiredPermission.microphone.settingsFailureMessage)

        await model.perform(.request, for: .accessibility)
        #expect(model.errorMessage == nil, "the next action clears it")
    }

    @Test func theMicrophoneIsReadAgainOnRefresh() {
        let model = model()
        microphone.currentStatus = .granted
        #expect(!model.isGranted(.microphone), "not re-read until refresh")
        model.refresh()
        #expect(model.isGranted(.microphone))
    }

    @Test func accessibilityPromptsOnceThenOpensSystemSettings() async {
        var opened: [RequiredPermission] = []
        let model = model { opened.append($0); return true }
        #expect(model.statusText(.accessibility) == "Not allowed")
        #expect(model.action(for: .accessibility) == .request)

        await model.perform(.request, for: .accessibility)
        #expect(accessibility.prompts == 1)
        #expect(model.action(for: .accessibility) == .openSettings)

        await model.perform(.openSettings, for: .accessibility)
        #expect(opened == [.accessibility])
    }

    @Test func aSettingsWindowOpenedAgainDoesNotOfferThePromptTwice() async {
        // macOS shows the prompt once per launch, so a new window's button must not be a no-op.
        await model().perform(.request, for: .accessibility)
        let reopened = model()
        #expect(reopened.action(for: .accessibility) == .openSettings)
        #expect(accessibility.prompts == 1)
    }

    /// Setup can show the prompt while this window is open; the button follows at once. The
    /// window redraws only because reading the button observes the shared memory.
    @Test func aPromptShownElsewhereSwitchesAnOpenWindowToSystemSettings() {
        let model = model()
        let redrawn = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            #expect(model.action(for: .accessibility) == .request)
        } onChange: {
            redrawn.withLock { $0 = true }
        }
        promptMemory.prompt(accessibility)  // as setup does
        #expect(redrawn.withLock { $0 }, "an open window redraws its button")
        #expect(model.action(for: .accessibility) == .openSettings)
        #expect(accessibility.prompts == 1)
    }

    @Test func accessibilityChangesAreFollowed() async {
        let model = model()
        let following = Task { await model.followAccessibility() }
        for _ in 0..<1_000 where !accessibility.hasSubscriber {
            await Task.yield()
        }
        #expect(accessibility.hasSubscriber)
        #expect(!model.isGranted(.accessibility))
        accessibility.set(granted: true)
        accessibility.finish()
        await following.value
        #expect(model.isGranted(.accessibility))
        #expect(model.action(for: .accessibility) == nil)
        #expect(model.statusText(.accessibility) == "Allowed")
    }

    // MARK: - Reopen

    /// Accessibility is on, but macOS still refuses ⌘V until the app reopens.
    @Test func accessibilityThatCannotPasteYetOffersToReopen() async {
        accessibility.set(granted: true)
        accessibility.postsKeystrokes = false
        var reopens = 0
        let model = model(reopen: { reopens += 1; return true })

        #expect(model.needsReopen)
        #expect(model.statusText(.accessibility) == "Allowed, but can't paste yet")
        #expect(model.action(for: .accessibility) == .reopen)

        await model.perform(.reopen, for: .accessibility)
        #expect(reopens == 1)
        #expect(model.errorMessage == nil)
    }

    @Test func aReopenThatFailsSaysWhatToDoByHand() async {
        accessibility.set(granted: true)
        accessibility.postsKeystrokes = false
        let model = model(reopen: { false })

        await model.perform(.reopen, for: .accessibility)
        #expect(model.errorMessage == "Couldn't reopen Live Transcribe. Quit it from the menu bar, then open it again.")
    }

    /// Without Accessibility, keystrokes are refused too: granting it is what's needed, not a reopen.
    @Test func noReopenIsOfferedWhileAccessibilityIsOff() {
        accessibility.postsKeystrokes = false
        let model = model()
        #expect(!model.needsReopen)
        #expect(model.statusText(.accessibility) == "Not allowed")
        #expect(model.action(for: .accessibility) == .request)
    }

    @Test func whetherTheAppCanPasteIsReadAgainWithAccessibility() async {
        accessibility.postsKeystrokes = false
        let model = model()
        let following = Task { await model.followAccessibility() }
        for _ in 0..<1_000 where !accessibility.hasSubscriber {
            await Task.yield()
        }
        accessibility.set(granted: true)
        accessibility.finish()
        await following.value
        #expect(model.needsReopen, "granted while running, as when the entry is removed and added again")

        accessibility.postsKeystrokes = true
        model.refresh()
        #expect(!model.needsReopen)
        #expect(model.action(for: .accessibility) == nil)
    }

    // MARK: - Shortcut status

    @Test func theShortcutStatusExplainsEachState() {
        let running = PermissionsSettingsShortcutStatus(.running(hotkey: "fn"))
        #expect(running.message.contains("fn"))
        #expect(!running.isProblem)

        let waiting = PermissionsSettingsShortcutStatus(.needsAccessibility)
        #expect(waiting.isProblem)
        #expect(waiting.needsAccessibility)

        let failed = PermissionsSettingsShortcutStatus(.failed("The event tap could not start"))
        #expect(failed.isProblem)
        #expect(!failed.needsAccessibility)
        #expect(failed.message == "The event tap could not start", "the detail is already a sentence")

        #expect(!PermissionsSettingsShortcutStatus(.disabled).isProblem)
        #expect(!PermissionsSettingsShortcutStatus(.stopped).isProblem)
    }
}
