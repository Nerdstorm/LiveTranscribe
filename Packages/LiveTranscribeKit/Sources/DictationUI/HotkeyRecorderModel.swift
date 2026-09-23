import Hotkey

/// Records a new shortcut from key events: the logic behind ``HotkeyRecorderView``, as a pure
/// state machine so it can be tested with plain ``KeyEventInfo`` values.
///
/// While recording, it accepts either
/// - a **lone modifier**: one modifier key pressed and released with nothing else pressed in
///   between (fn, right ⌘, left ⌥, …; see ``ModifierKey``), when the configuration allows it, or
/// - a **key combination**: a key pressed with ⌘, ⌥ or ⌃ held, checked by
///   ``HotkeyBinding/validatedKeyCombo(keyCode:modifiers:)``, which also refuses standard macOS
///   shortcuts such as ⌘C.
///
/// Esc on its own cancels. Anything else that cannot be used sets ``problem`` and keeps
/// recording, so the user can try again straight away.
///
/// Modifier state is read from the device-dependent flag bits, which tell left and right keys
/// apart. A modifier already held when recording starts is never taken for a lone press.
struct HotkeyRecorderModel: Sendable, Equatable {
    /// What a recorder accepts.
    struct Configuration: Sendable, Equatable {
        /// Whether a modifier on its own can be recorded. Off for *Undo AI edit*, which the
        /// hotkey monitor supports only as a key combination.
        var allowsModifierOnly: Bool
        /// The app's other shortcut, which this one must differ from.
        var otherShortcut: HotkeyBinding?
        /// What the other shortcut does, for the message when it is chosen again ("dictation").
        var otherShortcutPurpose: String
    }

    /// Why the keys just pressed cannot be used.
    enum Problem: Sendable, Equatable {
        case invalidCombination(HotkeyBindingError)
        /// A modifier on its own was pressed, but this shortcut must be a combination.
        case needsKeyCombination
        /// Left ⌘ or left ⇧ on its own: both begin too many shortcuts to be a hotkey.
        case modifierNotAllowedAlone
        /// The same as the app's other shortcut.
        case alreadyUsed(purpose: String)

        var message: String {
            switch self {
            case .invalidCombination(let error):
                error.errorDescription ?? "That shortcut can't be used."
            case .needsKeyCombination:
                "Use a key combination with ⌘, ⌥ or ⌃, such as ⌃⌥Z."
            case .modifierNotAllowedAlone:
                "Left ⌘ and left ⇧ start too many shortcuts to use alone. Try fn or a key on the right."
            case .alreadyUsed(let purpose):
                "That shortcut is already used for \(purpose)."
            }
        }
    }

    /// What one event or intent did.
    enum Outcome: Sendable, Equatable {
        /// Not recording, or the event means nothing to the recorder.
        case ignored
        /// Still recording; the held keys or the problem may have changed.
        case updated
        /// Recording ended with this shortcut, which the caller stores.
        case recorded(HotkeyBinding)
        /// Recording ended without a change.
        case cancelled
    }

    let configuration: Configuration
    private(set) var isRecording = false
    private(set) var problem: Problem?
    /// The modifiers held now, as symbols ("fn⌃⌥"), for a live preview while recording.
    private(set) var heldModifiersDisplay = ""
    /// Modifier key codes held as of the last event.
    private var heldKeyCodes: Set<UInt16> = []
    /// The modifier pressed on its own; recorded if it is released before anything else happens.
    private var loneModifierCandidate: UInt16?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Intents

    /// Starts listening for a shortcut, forgetting any earlier problem.
    mutating func start() {
        isRecording = true
        resetKeyState()
        problem = nil
    }

    /// Stops listening without a change. Returns ``Outcome/ignored`` when not recording.
    @discardableResult
    mutating func cancel() -> Outcome {
        guard isRecording else { return .ignored }
        isRecording = false
        resetKeyState()
        problem = nil
        return .cancelled
    }

    /// Ends any recording and checks `binding` (normally the default, for *Reset*) against the
    /// other shortcut. Returns the binding to store, or `nil` with ``problem`` set when the other
    /// shortcut already uses it: the hotkey monitor would otherwise drop undo without a word.
    mutating func reset(to binding: HotkeyBinding) -> HotkeyBinding? {
        isRecording = false
        resetKeyState()
        if binding == configuration.otherShortcut {
            problem = .alreadyUsed(purpose: configuration.otherShortcutPurpose)
            return nil
        }
        problem = nil
        return binding
    }

    /// Whether the event should be kept from the window while recording, so a typed shortcut
    /// does not also press a button or beep. Modifier changes always pass through.
    func swallows(_ event: KeyEventInfo) -> Bool {
        isRecording && event.type == .keyDown
    }

    /// Feeds one key event to the recorder.
    mutating func handle(_ event: KeyEventInfo) -> Outcome {
        guard isRecording else { return .ignored }
        switch event.type {
        case .flagsChanged: return handleModifierChange(event)
        case .keyDown: return handleKeyDown(event)
        case .keyUp: return .ignored
        }
    }

    // MARK: - Events

    private mutating func handleModifierChange(_ event: KeyEventInfo) -> Outcome {
        // Caps Lock and unknown codes toggle state rather than being held: not a shortcut key.
        guard Self.deviceFlags[event.keyCode] != nil else { return .ignored }
        let wasHeld = heldKeyCodes
        heldKeyCodes = Self.heldKeyCodes(in: event.flags)
        heldModifiersDisplay = Self.symbols(for: event.flags)

        let pressed = heldKeyCodes.contains(event.keyCode) && !wasHeld.contains(event.keyCode)
        if pressed {
            // Only a press with nothing else held can become a lone modifier; a second modifier
            // turns it into the start of a combination.
            loneModifierCandidate = wasHeld.isEmpty && heldKeyCodes == [event.keyCode] ? event.keyCode : nil
            return .updated
        }
        let released = !heldKeyCodes.contains(event.keyCode)
        guard released, loneModifierCandidate == event.keyCode, heldKeyCodes.isEmpty else {
            if heldKeyCodes.isEmpty { loneModifierCandidate = nil }
            return .updated
        }
        loneModifierCandidate = nil
        return finishLoneModifier(keyCode: event.keyCode)
    }

    private mutating func handleKeyDown(_ event: KeyEventInfo) -> Outcome {
        guard !event.isAutorepeat else { return .ignored }
        loneModifierCandidate = nil
        let modifiers = ModifierSet(eventFlags: event.flags)
        if event.keyCode == HotkeyMatcher.escapeKeyCode, modifiers.isEmpty {
            return cancel()
        }
        do {
            return finish(try HotkeyBinding.validatedKeyCombo(keyCode: event.keyCode, modifiers: modifiers))
        } catch {
            problem = .invalidCombination(error)
            return .updated
        }
    }

    private mutating func finishLoneModifier(keyCode: UInt16) -> Outcome {
        // Checked first: a recorder that takes only combinations must not suggest another
        // modifier, which it would refuse too.
        guard configuration.allowsModifierOnly else {
            problem = .needsKeyCombination
            return .updated
        }
        guard let key = ModifierKey.allCases.first(where: { $0.keyCode == keyCode }) else {
            problem = .modifierNotAllowedAlone
            return .updated
        }
        return finish(.modifierKey(key))
    }

    private mutating func finish(_ binding: HotkeyBinding) -> Outcome {
        if binding == configuration.otherShortcut {
            problem = .alreadyUsed(purpose: configuration.otherShortcutPurpose)
            return .updated
        }
        isRecording = false
        resetKeyState()
        problem = nil
        return .recorded(binding)
    }

    private mutating func resetKeyState() {
        heldKeyCodes = []
        loneModifierCandidate = nil
        heldModifiersDisplay = ""
    }

    // MARK: - Modifier flags

    /// The flag that is set while each modifier key is down, by virtual key code. The
    /// ``ModifierKey`` cases use their own ``ModifierKey/heldFlag``; left ⌘ (55) and left ⇧ (56)
    /// are added so pressing them is seen, even though they cannot be recorded on their own.
    static let deviceFlags: [UInt16: KeyEventFlags] = {
        var flags: [UInt16: KeyEventFlags] = [55: .leftCommand, 56: .leftShift]
        for key in ModifierKey.allCases {
            flags[key.keyCode] = key.heldFlag
        }
        return flags
    }()

    /// The modifier key codes whose flag is set in `flags`.
    static func heldKeyCodes(in flags: KeyEventFlags) -> Set<UInt16> {
        Set(deviceFlags.filter { flags.contains($0.value) }.keys)
    }

    /// The held modifiers as printed on the keys, fn first, then in macOS order: "fn⌃⌥".
    static func symbols(for flags: KeyEventFlags) -> String {
        (flags.contains(.secondaryFn) ? "fn" : "") + ModifierSet(eventFlags: flags).displayName
    }

    /// The binding a stored setting stands for: the parsed value, or `fallback` for a missing or
    /// damaged value, matching how the dictation controller reads it.
    static func binding(storage: String, fallback: HotkeyBinding) -> HotkeyBinding {
        HotkeyBinding(storageString: storage) ?? fallback
    }
}
