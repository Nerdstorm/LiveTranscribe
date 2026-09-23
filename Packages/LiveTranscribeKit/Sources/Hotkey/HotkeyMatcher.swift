import Foundation

/// What a keyboard event means for the hotkeys.
public enum KeyEventMeaning: Sendable, Equatable {
    case hotkeyDown
    case hotkeyUp
    case escape
    /// Another key went down while a modifier-only hotkey was held.
    case otherKey
    case undo
    /// Nothing to report.
    case none
}

/// A matcher's decision for one event: what it means, and whether the tap swallows it.
public struct HotkeyMatch: Sendable, Equatable {
    public var meaning: KeyEventMeaning
    /// Whether the event is removed from the event stream, so the frontmost app never sees it.
    public var consumes: Bool
    /// Whether the key also went down while a modifier-only hotkey was held, so it interrupts
    /// that hotkey as ``KeyEventMeaning/otherKey`` would. Set for the undo combination, which
    /// must both undo and cancel the recording its modifier started (left ⌃ as the dictation
    /// hotkey and ⌃⌥Z as undo, say).
    public var interruptsHotkey: Bool

    public init(meaning: KeyEventMeaning, consumes: Bool, interruptsHotkey: Bool = false) {
        self.meaning = meaning
        self.consumes = consumes
        self.interruptsHotkey = interruptsHotkey
    }

    /// Nothing to report; the event goes on to the app.
    public static let passThrough = HotkeyMatch(meaning: .none, consumes: false)

    /// The monitor events to deliver, in order: ``HotkeyEvent/otherKey`` first when the key
    /// interrupts the held hotkey, then the event for the meaning, if any.
    public var events: [HotkeyEvent] {
        let meaningEvent: HotkeyEvent? = switch meaning {
        case .hotkeyDown: .pressed
        case .hotkeyUp: .released
        case .escape: .escape
        case .otherKey: .otherKey
        case .undo: .undo
        case .none: nil
        }
        var events: [HotkeyEvent] = interruptsHotkey && meaning != .otherKey ? [.otherKey] : []
        if let meaningEvent { events.append(meaningEvent) }
        return events
    }
}

/// Decides what each keyboard event means for the dictation and undo hotkeys, and whether to
/// swallow it. Pure and synchronous, so the event tap's callback stays thin and testable.
///
/// - Modifier-only binding: presses and releases come from `flagsChanged` events for exactly
///   that key code, read from the key's own flag (the device-dependent bit for left/right keys,
///   `secondaryFn` for fn). `flagsChanged` is never swallowed: other apps must keep seeing
///   modifier state, or their shortcuts break.
/// - Key combination: a `keyDown` with that key code and exactly those modifiers is the press
///   (swallowed); that key's `keyUp` is the release (swallowed). Caps Lock, fn and the keypad
///   bit are ignored. Autorepeats while it is held are swallowed and ignored.
/// - The undo combination: its `keyDown` means undo (swallowed), with its repeats and `keyUp`.
///   Pressed while a modifier-only hotkey is held, it also interrupts that hotkey.
/// - Esc: its `keyDown` means escape, and is swallowed only while Esc is being captured, so an
///   Esc meant for the frontmost app still reaches it the rest of the time.
/// - Any other `keyDown` while a modifier-only hotkey is held means another key (not
///   swallowed): the user is typing a shortcut such as fn+arrow.
///
/// A combination that fails ``HotkeyBinding/validate()`` is never matched, as dictation or
/// undo, so a binding built in code cannot make the tap swallow ordinary typing.
/// A key-up is swallowed only when its key-down was, so no app ever sees half a key press.
public struct HotkeyMatcher: Sendable {
    /// The virtual key code of Esc.
    public static let escapeKeyCode: UInt16 = 53

    public let binding: HotkeyBinding
    /// The undo binding the matcher acts on; see ``effectiveUndoBinding(_:dictation:)``.
    public let undoBinding: HotkeyBinding?

    /// Whether the dictation hotkey is down, as far as the events seen so far tell.
    public private(set) var isHotkeyHeld = false
    /// Undo or Esc keys whose key-down was swallowed, so their repeats and key-up are too.
    private var swallowedKeysDown: Set<UInt16> = []
    /// Whether `binding` may be matched at all: `false` for an invalid combination.
    private let bindingIsUsable: Bool

    public init(binding: HotkeyBinding, undoBinding: HotkeyBinding?) {
        self.binding = binding
        self.bindingIsUsable = binding.isValid
        self.undoBinding = Self.effectiveUndoBinding(undoBinding, dictation: binding)
    }

    /// The undo binding that can actually be used alongside `dictation`, or `nil`.
    ///
    /// Only a valid key combination that differs from the dictation hotkey qualifies. A
    /// modifier-only undo binding is not supported: modifier events are never swallowed, so it
    /// would fire during every shortcut that uses that modifier.
    public static func effectiveUndoBinding(_ undo: HotkeyBinding?, dictation: HotkeyBinding) -> HotkeyBinding? {
        guard let undo, case .keyCombo = undo, undo.isValid, undo != dictation else { return nil }
        return undo
    }

    /// Decides what `event` means. `capturingEscape` is whether Esc is swallowed right now.
    public mutating func match(_ event: KeyEventInfo, capturingEscape: Bool) -> HotkeyMatch {
        switch event.type {
        case .flagsChanged: matchFlagsChanged(event)
        case .keyDown: matchKeyDown(event, capturingEscape: capturingEscape)
        case .keyUp: matchKeyUp(event)
        }
    }

    /// Reconciles with the keyboard's actual state after events may have been missed (macOS
    /// disables a tap that is too slow, and events during that gap are lost).
    ///
    /// `isKeyDown` reports whether a key code is down now; `modifierFlags` are the modifier
    /// flags held now. A modifier-only hotkey counts as still down if either says so, because
    /// neither is documented to be reliable for every modifier (fn in particular).
    ///
    /// Returns ``KeyEventMeaning/hotkeyUp`` when the hotkey was believed held but is no longer
    /// down, so a lost release cannot leave a recording running; otherwise ``KeyEventMeaning/none``.
    public mutating func resynchronize(isKeyDown: (UInt16) -> Bool, modifierFlags: KeyEventFlags) -> KeyEventMeaning {
        swallowedKeysDown = swallowedKeysDown.filter(isKeyDown)
        guard isHotkeyHeld else { return .none }
        let stillDown = switch binding {
        case .modifierKey(let key): isKeyDown(key.keyCode) || modifierFlags.contains(key.heldFlag)
        case .keyCombo(let keyCode, _): isKeyDown(keyCode)
        }
        guard !stillDown else { return .none }
        isHotkeyHeld = false
        return .hotkeyUp
    }

    // MARK: - Event kinds

    private mutating func matchFlagsChanged(_ event: KeyEventInfo) -> HotkeyMatch {
        guard case .modifierKey(let key) = binding, event.keyCode == key.keyCode else { return .passThrough }
        let isDown = event.flags.contains(key.heldFlag)
        switch (isDown, isHotkeyHeld) {
        case (true, false):
            isHotkeyHeld = true
            return HotkeyMatch(meaning: .hotkeyDown, consumes: false)
        case (false, true):
            isHotkeyHeld = false
            return HotkeyMatch(meaning: .hotkeyUp, consumes: false)
        default:
            return .passThrough
        }
    }

    private mutating func matchKeyDown(_ event: KeyEventInfo, capturingEscape: Bool) -> HotkeyMatch {
        if bindingIsUsable, case .keyCombo(let keyCode, let modifiers) = binding, event.keyCode == keyCode {
            if isHotkeyHeld {
                return HotkeyMatch(meaning: .none, consumes: true)
            }
            // An autorepeat without a matching press means the key was already down before the
            // modifiers were: that is not the shortcut, and the app has been seeing the key.
            if !event.isAutorepeat, ModifierSet(eventFlags: event.flags) == modifiers {
                isHotkeyHeld = true
                return HotkeyMatch(meaning: .hotkeyDown, consumes: true)
            }
        }

        let modifierHotkeyHeld = if case .modifierKey = binding { isHotkeyHeld } else { false }

        if case .keyCombo(let keyCode, let modifiers) = undoBinding, event.keyCode == keyCode {
            if swallowedKeysDown.contains(keyCode) {
                return HotkeyMatch(meaning: .none, consumes: true)
            }
            if !event.isAutorepeat, ModifierSet(eventFlags: event.flags) == modifiers {
                swallowedKeysDown.insert(keyCode)
                return HotkeyMatch(meaning: .undo, consumes: true, interruptsHotkey: modifierHotkeyHeld)
            }
        }

        if event.keyCode == Self.escapeKeyCode {
            if swallowedKeysDown.contains(Self.escapeKeyCode) {
                return HotkeyMatch(meaning: .none, consumes: true)
            }
            // Repeats of an Esc the app already saw go on to it, key-up included.
            guard !event.isAutorepeat else { return .passThrough }
            if capturingEscape {
                swallowedKeysDown.insert(Self.escapeKeyCode)
            }
            return HotkeyMatch(meaning: .escape, consumes: capturingEscape)
        }

        if modifierHotkeyHeld {
            return HotkeyMatch(meaning: .otherKey, consumes: false)
        }
        return .passThrough
    }

    private mutating func matchKeyUp(_ event: KeyEventInfo) -> HotkeyMatch {
        if case .keyCombo(let keyCode, _) = binding, event.keyCode == keyCode, isHotkeyHeld {
            isHotkeyHeld = false
            return HotkeyMatch(meaning: .hotkeyUp, consumes: true)
        }
        if swallowedKeysDown.remove(event.keyCode) != nil {
            return HotkeyMatch(meaning: .none, consumes: true)
        }
        return .passThrough
    }
}
