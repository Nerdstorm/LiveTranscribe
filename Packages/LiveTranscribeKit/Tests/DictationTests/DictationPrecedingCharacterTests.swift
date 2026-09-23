import ApplicationServices
@testable import Dictation
import Foundation
import Testing

/// The character before the caret, read for spacing on every dictation, is an Accessibility call
/// to another app: it must not run on the main actor or copy the whole field.
@MainActor
@Suite("DictationController preceding character")
struct DictationPrecedingCharacterTests {
    @Test func isReadOffTheMainThreadWithoutCopyingTheField() async {
        let h = Harness()
        let probe = ElementProbe()
        h.focus.set(FakeFocus.field(value: "Hello", secure: false, probe: probe))
        h.controller.start()

        await h.hold(milliseconds: 500)
        await h.release()

        #expect(await h.delivery.inserted == [" Ship it on friday."])
        #expect(probe.attributes == [kAXStringForRangeParameterizedAttribute])
        #expect(!probe.readOnMainThread)
    }

    /// Esc cancels until the text is inserted, including while the field is being read.
    @Test func escapeWhileTheFieldIsReadCancels() async throws {
        let h = Harness()
        let probe = ElementProbe()
        probe.hold()
        defer { probe.release() }
        h.focus.set(FakeFocus.field(value: "Hello", secure: false, probe: probe))
        h.controller.start()
        await h.hold(milliseconds: 500)

        h.controller.handle(.released)
        #expect(await eventually { probe.attributes.contains(kAXStringForRangeParameterizedAttribute) })
        #expect(h.controller.phase == .processing)
        h.controller.handle(.escape)
        probe.release()
        await h.controller.settle()

        #expect(h.controller.notice == .cancelled)
        #expect(await h.delivery.inserted.isEmpty)
        #expect(try await h.history.all().isEmpty)
    }
}
