import Capture
import Dictation
@testable import DictationUI
import Foundation
import Hotkey
import os
import Permissions
import Session
import Testing

/// A microphone permission the test sets, and answers the prompt for.
private final class FakeMicrophone: MicrophonePermissionProviding {
    private struct State {
        var status: MicrophonePermissionStatus
        var grantsWhenAsked: Bool
        var requests = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ status: MicrophonePermissionStatus, grantsWhenAsked: Bool = true) {
        state = OSAllocatedUnfairLock(initialState: State(status: status, grantsWhenAsked: grantsWhenAsked))
    }

    var requests: Int { state.withLock { $0.requests } }
    func set(_ status: MicrophonePermissionStatus) { state.withLock { $0.status = status } }
    func status() -> MicrophonePermissionStatus { state.withLock { $0.status } }

    func request() async -> Bool {
        state.withLock { state in
            state.requests += 1
            if state.status == .undetermined { state.status = state.grantsWhenAsked ? .granted : .denied }
            return state.status == .granted
        }
    }
}

/// Accessibility access the test switches on and off, streamed to ``changes()``.
private final class FakeAccessibility: AccessibilityPermissionProviding {
    private struct State {
        var granted: Bool
        var canPost: Bool
        var prompts = 0
        var continuation: AsyncStream<Bool>.Continuation?
    }

    private let state: OSAllocatedUnfairLock<State>

    /// - Parameter canPost: What ``canPostKeystrokes()`` answers until ``set(canPost:)``.
    init(granted: Bool, canPost: Bool = true) {
        state = OSAllocatedUnfairLock(initialState: State(granted: granted, canPost: canPost))
    }

    var prompts: Int { state.withLock { $0.prompts } }
    func isGranted() -> Bool { state.withLock { $0.granted } }
    func canPostKeystrokes() -> Bool { state.withLock { $0.canPost } }
    /// Not streamed: the model reads it again with each Accessibility change and on refresh.
    func set(canPost: Bool) { state.withLock { $0.canPost = canPost } }
    func prompt() { state.withLock { $0.prompts += 1 } }

    func set(_ granted: Bool) {
        state.withLock { state in
            state.granted = granted
            state.continuation?.yield(granted)
        }
    }

    func changes() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        state.withLock { state in
            state.continuation = continuation
            continuation.yield(state.granted)
        }
        return stream
    }
}

/// Records what the model asked of the system.
@MainActor
private final class SystemSpy {
    var fnUsage: FnKeyUsage = .doNothing
    var opensKeyboardSettings = true
    var opensPrivacySettings = true
    var reopensApp = true
    private(set) var openedPermissions: [RequiredPermission] = []
    private(set) var reopens = 0
    private(set) var keyboardSettingsOpened = 0
    private(set) var announcements: [String] = []

    var system: OnboardingModel.System {
        OnboardingModel.System(
            fnKeyUsage: { self.fnUsage },
            openPrivacySettings: {
                self.openedPermissions.append($0)
                return self.opensPrivacySettings
            },
            openKeyboardSettings: {
                self.keyboardSettingsOpened += 1
                return self.opensKeyboardSettings
            },
            announce: { self.announcements.append($0) },
            reopenApp: {
                self.reopens += 1
                return self.reopensApp
            }
        )
    }
}

@MainActor
@Suite("Onboarding")
struct OnboardingModelTests {
    private let microphone: FakeMicrophone
    private let accessibility: FakeAccessibility
    private let spy = SystemSpy()
    /// This test's launch: a fresh memory, so tests don't share the app-wide one.
    private let promptMemory = PermissionsSettingsPromptMemory()

    init() {
        microphone = FakeMicrophone(.undetermined)
        accessibility = FakeAccessibility(granted: false)
    }

    private func makeModel(
        microphone status: MicrophonePermissionStatus? = nil,
        accessibility granted: Bool? = nil,
        fn: FnKeyUsage = .doNothing
    ) -> OnboardingModel {
        if let status { microphone.set(status) }
        if let granted { accessibility.set(granted) }
        spy.fnUsage = fn
        return OnboardingModel(
            microphonePermission: microphone,
            accessibility: accessibility,
            system: spy.system,
            promptMemory: promptMemory
        )
    }

    /// Lets the model's observation run until `condition` holds, for up to two seconds.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for the model to update")
    }

    // MARK: - Steps

    @Test func startsAtTheFirstStepThatNeedsSomething() {
        #expect(makeModel().step == .microphone)
        #expect(makeModel(microphone: .granted).step == .accessibility)
        #expect(makeModel(microphone: .granted, accessibility: true, fn: .showEmojiAndSymbols).step == .fnKey)
        #expect(makeModel(microphone: .granted, accessibility: true).step == .tryIt)
    }

    @Test func theFnStepIsOnlyForTheFnHotkey() {
        let model = makeModel()
        #expect(model.steps == [.microphone, .accessibility, .fnKey, .tryIt])
        model.setHotkey(storageString: "modifier:rightOption")
        #expect(model.steps == [.microphone, .accessibility, .tryIt])
        #expect(model.hotkey.displayName == "Right ⌥ Option")
        // An unreadable setting means the default, fn, as it does for the controller.
        model.setHotkey(storageString: "not a hotkey")
        #expect(model.steps.contains(.fnKey))
    }

    @Test func leavingFnWhileOnItsStepMovesToTheNextStep() {
        let model = makeModel(microphone: .granted, accessibility: true, fn: .changeInputSource)
        #expect(model.step == .fnKey)
        model.setHotkey(storageString: "combo:49:control,option")
        #expect(model.step == .tryIt)
    }

    @Test func switchingToFnReadsTheSystemSettingAgain() {
        let model = makeModel()
        model.setHotkey(storageString: "modifier:rightOption")
        spy.fnUsage = .startDictation
        model.setHotkey(storageString: "modifier:fn")
        #expect(model.fnUsage == .startDictation)
        #expect(!model.isComplete(.fnKey))
    }

    @Test func movesForwardAndBackWithinTheSteps() {
        let model = makeModel()
        #expect(model.isFirstStep)
        model.goBack()
        #expect(model.step == .microphone)
        model.goForward()
        model.goForward()
        model.goForward()
        #expect(model.step == .tryIt)
        #expect(model.isLastStep)
        model.goForward()
        #expect(model.step == .tryIt)
        model.goBack()
        #expect(model.step == .fnKey)
    }

    @Test func jumpsOnlyToStepsThatAreListed() {
        let model = makeModel()
        model.setHotkey(storageString: "modifier:rightOption")
        model.show(.fnKey)
        #expect(model.step == .microphone)
        model.show(.tryIt)
        #expect(model.step == .tryIt)
    }

    @Test func tryItIsNeverShownAsDone() {
        #expect(!makeModel(microphone: .granted, accessibility: true).isComplete(.tryIt))
    }

    // MARK: - Permissions

    @Test func allowingTheMicrophoneUpdatesTheStepAndSaysSo() async {
        let model = makeModel()
        await model.requestMicrophone()
        #expect(model.microphone == .granted)
        #expect(model.isComplete(.microphone))
        #expect(!model.isRequestingMicrophone)
        #expect(spy.announcements == ["Microphone access is on"])
    }

    @Test func refusingTheMicrophoneIsShownAsOff() async {
        let refusing = FakeMicrophone(.undetermined, grantsWhenAsked: false)
        let model = OnboardingModel(
            microphonePermission: refusing,
            accessibility: accessibility,
            system: spy.system,
            promptMemory: promptMemory
        )
        await model.requestMicrophone()
        #expect(model.microphone == .denied)
        #expect(spy.announcements == ["Microphone access is off"])
        model.openMicrophoneSettings()
        #expect(spy.openedPermissions == [.microphone])
    }

    @Test func grantingAccessibilityPromptsAndOpensTheList() {
        let model = makeModel()
        #expect(!model.hasAskedForAccessibility)
        model.grantAccessibility()
        #expect(accessibility.prompts == 1)
        #expect(spy.openedPermissions == [.accessibility])
        #expect(model.hasAskedForAccessibility)
    }

    /// macOS shows the Accessibility prompt once per launch. Once setup has shown it, Settings'
    /// button must open System Settings, or its first click does nothing.
    @Test func theAccessibilityPromptShownInSetupIsRememberedForSettings() {
        let model = makeModel()
        #expect(!promptMemory.accessibilityPrompted)
        model.grantAccessibility()
        #expect(promptMemory.accessibilityPrompted)

        let settings = PermissionsSettingsModel(
            microphonePermission: microphone,
            accessibility: accessibility,
            promptMemory: promptMemory,
            openSettings: { _ in true }
        )
        #expect(settings.action(for: .accessibility) == .openSettings)
    }

    @Test func aPrivacyPaneThatWillNotOpenSaysWhereToGo() {
        let model = makeModel()
        spy.opensPrivacySettings = false
        model.openMicrophoneSettings()
        #expect(model.errorMessage == "Couldn't open System Settings. Open it from the Apple menu, then choose Privacy & Security › Microphone.")
        model.grantAccessibility()
        #expect(model.errorMessage == "Couldn't open System Settings. Open it from the Apple menu, then choose Privacy & Security › Accessibility.")

        spy.opensPrivacySettings = true
        model.grantAccessibility()
        #expect(model.errorMessage == nil, "cleared once it opens")
    }

    @Test func accessibilityUpdatesLiveWhileObserved() async {
        let model = makeModel()
        let observation = Task { await model.observeAccessibility() }
        defer { observation.cancel() }
        accessibility.set(true)
        await waitUntil { model.accessibilityGranted }
        #expect(model.isComplete(.accessibility))
        accessibility.set(false)
        await waitUntil { !model.accessibilityGranted }
        #expect(spy.announcements == ["Accessibility access is on", "Accessibility access is off"])
    }

    // MARK: - Reopen

    /// Accessibility is on, but macOS still refuses ⌘V until the app reopens.
    @Test func accessibilityThatCannotPasteYetIsNotDone() {
        accessibility.set(canPost: false)
        let model = makeModel(microphone: .granted, accessibility: true)
        #expect(model.needsReopen)
        #expect(!model.isComplete(.accessibility))
        #expect(model.step == .accessibility, "setup opens where something is needed")
    }

    @Test func reopensOrSaysHowToByHand() {
        accessibility.set(canPost: false)
        let model = makeModel(microphone: .granted, accessibility: true)
        model.reopen()
        #expect(spy.reopens == 1)
        #expect(model.errorMessage == nil)

        spy.reopensApp = false
        model.reopen()
        #expect(model.errorMessage == "Couldn't reopen Live Transcribe. Quit it from the menu bar, then open it again.")
    }

    /// Granted while setup is open: the paste part may not follow until the app reopens.
    @Test func aGrantThatCannotPasteYetAsksForAReopen() async {
        accessibility.set(canPost: false)
        let model = makeModel()
        let observation = Task { await model.observeAccessibility() }
        defer { observation.cancel() }
        accessibility.set(true)
        await waitUntil { model.accessibilityGranted }
        #expect(model.needsReopen)
        #expect(spy.announcements == [OnboardingModel.reopenStatus])

        accessibility.set(canPost: true)
        model.refresh()
        #expect(model.isComplete(.accessibility))
        #expect(spy.announcements == [OnboardingModel.reopenStatus, "Accessibility access is on"])
    }

    @Test func refreshPicksUpChangesMadeInSystemSettings() {
        let model = makeModel(fn: .showEmojiAndSymbols)
        microphone.set(.granted)
        accessibility.set(true)
        spy.fnUsage = .doNothing
        model.refresh()
        #expect(model.isComplete(.microphone))
        #expect(model.isComplete(.accessibility))
        #expect(model.isComplete(.fnKey))
        // Nothing changed, so nothing more is announced.
        let announced = spy.announcements
        model.refresh()
        #expect(spy.announcements == announced)
    }

    // MARK: - fn key

    @Test func checkingTheFnKeyAgainSaysWhatItFound() {
        let model = makeModel(fn: .showEmojiAndSymbols)
        model.checkFnKey()
        // The stored value may be FnKeyUsage's assumption, so it is never named.
        #expect(spy.announcements.last == "Not set to Do Nothing yet")
        #expect(!model.isComplete(.fnKey))
        spy.fnUsage = .doNothing
        model.checkFnKey()
        #expect(model.isComplete(.fnKey))
        #expect(spy.announcements.last == "The fn key is ready")
    }

    @Test func opensKeyboardSettingsOrSaysItCouldNot() {
        let model = makeModel(fn: .changeInputSource)
        model.openKeyboardSettings()
        #expect(spy.keyboardSettingsOpened == 1)
        #expect(model.errorMessage == nil)

        spy.opensKeyboardSettings = false
        model.openKeyboardSettings()
        #expect(spy.keyboardSettingsOpened == 2)
        #expect(model.errorMessage == "Couldn't open System Settings. Open it from the Apple menu, then choose Keyboard.")
        // Moving on clears it.
        model.goForward()
        #expect(model.errorMessage == nil)
    }

    // MARK: - Try it

    @Test func tryItSaysWhyDictationMightNotWorkYet() {
        func note(granted: Bool = true, hotkey: HotkeyState = .running(hotkey: "fn"), session: SessionPhase = .ready) -> String? {
            OnboardingModel.tryItNote(permissionsGranted: granted, hotkey: hotkey, session: session)
        }
        #expect(note(granted: false)?.contains("Accessibility") == true)
        #expect(note(granted: false, hotkey: .needsAccessibility)?.contains("Accessibility") == true)
        #expect(note(session: .loading)?.contains("loading") == true)
        #expect(note(session: .notLoaded)?.contains("loading") == true)
        #expect(note(session: .failed(.modelLoadFailed(model: "m", message: "x")))?.contains("couldn't load") == true)
        #expect(note(session: .listening) == "Stop the live transcript to dictate.")
        #expect(note() == nil)
        #expect(note(session: .failed(.audioCaptureFailed(message: "x"))) == nil)
    }

    @Test func tryItSaysWhenTheShortcutIsOffOrBroken() {
        func note(_ hotkey: HotkeyState, session: SessionPhase = .ready) -> String? {
            OnboardingModel.tryItNote(permissionsGranted: true, hotkey: hotkey, session: session)
        }
        #expect(note(.disabled) == "The dictation shortcut is off. Turn it on in Settings to try it.")
        #expect(note(.failed("The event tap failed")) == "The dictation shortcut couldn't start: The event tap failed")
        // A shortcut that can't work outranks the models, which would not help.
        #expect(note(.disabled, session: .loading) == note(.disabled))
        // Still starting, or about to restart now that Accessibility is on: nothing to say.
        #expect(note(.stopped) == nil)
        #expect(note(.needsAccessibility) == nil)
    }
}
