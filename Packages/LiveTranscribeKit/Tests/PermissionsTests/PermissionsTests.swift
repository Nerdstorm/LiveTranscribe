import Capture
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
