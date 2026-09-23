import Capture
import Foundation
@testable import Permissions
import os
import Testing

@Suite("Permissions")
struct PermissionsTests {
    @Test func missingPermissionsAreListedMicrophoneFirst() {
        #expect(PermissionSnapshot(microphone: .granted, accessibility: true).missing.isEmpty)
        #expect(PermissionSnapshot(microphone: .granted, accessibility: true).allGranted)
        #expect(PermissionSnapshot(microphone: .undetermined, accessibility: false).missing == [.microphone, .accessibility])
        #expect(PermissionSnapshot(microphone: .denied, accessibility: true).missing == [.microphone])
        #expect(PermissionSnapshot(microphone: .granted, accessibility: false).missing == [.accessibility])
    }

    @Test func everyPermissionLinksToItsSettingsPane() {
        #expect(RequiredPermission.microphone.settingsURL?.absoluteString.hasSuffix("Privacy_Microphone") == true)
        #expect(RequiredPermission.accessibility.settingsURL?.absoluteString.hasSuffix("Privacy_Accessibility") == true)
        for permission in RequiredPermission.allCases {
            #expect(!permission.reason.isEmpty)
            #expect(!permission.title.isEmpty)
        }
    }

    @Test func theKeyboardLinkOpensSystemSettingsAtKeyboard() {
        #expect(PrivacySettings.keyboardSettingsURL?.absoluteString
            == "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        #expect(PrivacySettings.keyboardSettingsFailureMessage.contains("Keyboard"))
    }

    /// Nothing here opens System Settings: a fake stands in for the workspace.
    @MainActor
    @Test func openingReportsWhetherSystemSettingsOpened() throws {
        let link = try #require(PrivacySettings.keyboardSettingsURL)
        var opened: [URL] = []

        #expect(PrivacySettings.open(link, pane: "keyboard") { opened.append($0); return true })
        #expect(opened == [link])

        #expect(!PrivacySettings.open(link, pane: "keyboard") { opened.append($0); return false })
        #expect(opened == [link, link])

        #expect(!PrivacySettings.open(nil, pane: "keyboard") { opened.append($0); return true })
        #expect(opened == [link, link], "no link, nothing to open")
    }

    @Test func thePollerYieldsTheCurrentStateThenOnlyChanges() async {
        let answers = OSAllocatedUnfairLock(initialState: [false, false, true, true, true, false])
        let poller = PermissionPoller(interval: .milliseconds(1)) {
            answers.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        }
        var seen: [Bool] = []
        for await state in poller.states() {
            seen.append(state)
            if seen.count == 3 { break }
        }
        #expect(seen == [false, true, false])
    }
}
