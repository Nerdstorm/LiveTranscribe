import CoreGraphics
@testable import Hotkey
import Testing

@Suite("HotkeyEventRouter")
struct HotkeyEventRouterTests {
    private static func router(
        binding: HotkeyBinding = .defaultDictation,
        undoBinding: HotkeyBinding? = .defaultUndo,
        capturingEscape: Bool = false
    ) -> (HotkeyEventRouter, AsyncStream<HotkeyEvent>) {
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream(bufferingPolicy: .unbounded)
        let router = HotkeyEventRouter(
            binding: binding,
            undoBinding: undoBinding,
            capturingEscape: capturingEscape,
            continuation: continuation
        )
        return (router, stream)
    }

    private static func events(of stream: AsyncStream<HotkeyEvent>) async -> [HotkeyEvent] {
        var events: [HotkeyEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    @Test func deliversEventsInKeyOrderAndReportsWhatToSwallow() async {
        let (router, stream) = Self.router()
        let swallowed = [
            Keys.flagsChanged(63, [.secondaryFn]),
            Keys.down(Keys.keyA, [.secondaryFn]),
            Keys.flagsChanged(63, []),
            Keys.down(Keys.keyZ, [.control, .option]),
            Keys.up(Keys.keyZ),
            Keys.down(Keys.escape),
            Keys.down(Keys.keyA),
        ].map(router.route)
        router.finish()

        #expect(swallowed == [false, false, false, true, true, false, false])
        #expect(await Self.events(of: stream) == [.pressed, .otherKey, .released, .undo, .escape])
    }

    @Test func escapeCaptureCanBeToggledWhileRunning() async {
        let (router, stream) = Self.router(capturingEscape: true)
        #expect(router.route(Keys.down(Keys.escape)))
        #expect(router.route(Keys.up(Keys.escape)))
        router.setCapturingEscape(false)
        #expect(!router.route(Keys.down(Keys.escape)))
        #expect(!router.route(Keys.up(Keys.escape)))
        router.finish()
        #expect(await Self.events(of: stream) == [.escape, .escape])
    }

    @Test func resynchronizingDeliversALostRelease() async {
        let (router, stream) = Self.router()
        _ = router.route(Keys.flagsChanged(63, [.secondaryFn]))
        router.resynchronize(isKeyDown: { _ in true }, modifierFlags: [])
        router.resynchronize(isKeyDown: { _ in false }, modifierFlags: [.secondaryFn])
        router.resynchronize(isKeyDown: { _ in false }, modifierFlags: [])
        router.finish()
        #expect(await Self.events(of: stream) == [.pressed, .released])
    }

    @Test func undoWhileAModifierHotkeyIsHeldDeliversOtherKeyFirst() async {
        let (router, stream) = Self.router(binding: .modifierKey(.leftOption))
        _ = router.route(Keys.flagsChanged(58, [.option, .leftOption]))
        #expect(router.route(Keys.down(Keys.keyZ, [.option, .leftOption, .control, .leftControl])))
        router.finish()
        #expect(await Self.events(of: stream) == [.pressed, .otherKey, .undo])
    }

    @Test func eventsAfterFinishAreDropped() async {
        let (router, stream) = Self.router()
        router.finish()
        _ = router.route(Keys.flagsChanged(63, [.secondaryFn]))
        #expect(await Self.events(of: stream).isEmpty)
    }
}

@Suite("KeyEventInfo from CGEvent")
struct KeyEventInfoConversionTests {
    @Test("Reads the key code, flags and repeat flag", arguments: [
        (CGEventType.keyDown, KeyEventType.keyDown), (.keyUp, .keyUp), (.flagsChanged, .flagsChanged),
    ])
    func convertsKeyboardEvents(cgType: CGEventType, expected: KeyEventType) throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: cgType != .keyUp))
        event.type = cgType
        event.flags = [.maskControl, .maskAlternate, .maskSecondaryFn, CGEventFlags(rawValue: 0x40)]
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        let info = try #require(KeyEventInfo(event: event, type: cgType))
        #expect(info.type == expected)
        #expect(info.keyCode == 49)
        #expect(info.flags.isSuperset(of: [.control, .option, .secondaryFn, .rightOption]))
        #expect(info.isAutorepeat)
    }

    @Test func aFirstPressIsNotARepeat() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true))
        let info = try #require(KeyEventInfo(event: event, type: .keyDown))
        #expect(!info.isAutorepeat)
        #expect(info.keyCode == 6)
    }

    @Test("Other event types are ignored", arguments: [CGEventType.leftMouseDown, .scrollWheel, .tapDisabledByTimeout])
    func ignoresOtherTypes(type: CGEventType) throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        #expect(KeyEventInfo(event: event, type: type) == nil)
    }
}
