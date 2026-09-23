import ApplicationServices
import Foundation
import Insertion
import os

/// An in-memory text field that behaves like a well-behaved app, or like one of the
/// misbehaving ones insertion has to survive.
final class FakeElement: AccessibilityElement {
    enum Behaviour: Sendable {
        /// Applies writes and reports success.
        case normal
        /// Reports success but changes nothing (the classic Electron behaviour).
        case ignoresWrites
        /// Reports failure and changes nothing.
        case rejectsWrites
        /// Applies writes but reports failure.
        case appliesButReportsFailure
        /// Applies only the first half of the text, like a field with a length limit.
        case truncatesWrites
        /// Applies writes, then its value can no longer be read.
        case valueUnreadableAfterWrite
        /// Reports success but applies the write only after the next read of its value, which
        /// still shows the old text (a write travelling to another process, as in Chromium).
        case appliesLate
    }

    private struct State {
        var value: String?
        var selection: NSRange?
        var behaviour: Behaviour
        var ignoresSelectionWrites: Bool
        var valueWrites = 0
        /// A write accepted under ``Behaviour/appliesLate`` that has not landed yet.
        var pendingWrite: String?
        var history: [(value: String?, selection: NSRange?)] = []
    }

    let role: String?
    let subrole: String?
    let processIdentifier: pid_t?
    private let caretBounds: CGRect?
    private let state: OSAllocatedUnfairLock<State>

    /// - Parameters:
    ///   - value: The field's text; `nil` makes it unreadable.
    ///   - selection: Defaults to a caret at the end of `value`.
    init(
        value: String?,
        selection: NSRange? = nil,
        role: String? = kAXTextFieldRole,
        subrole: String? = nil,
        processIdentifier: pid_t? = 42,
        caretBounds: CGRect? = nil,
        behaviour: Behaviour = .normal,
        ignoresSelectionWrites: Bool = false
    ) {
        self.role = role
        self.subrole = subrole
        self.processIdentifier = processIdentifier
        self.caretBounds = caretBounds
        let initialSelection = selection ?? value.map { NSRange(location: $0.utf16.count, length: 0) }
        self.state = OSAllocatedUnfairLock(initialState: State(
            value: value,
            selection: initialSelection,
            behaviour: behaviour,
            ignoresSelectionWrites: ignoresSelectionWrites
        ))
    }

    var value: String? { state.withLock { $0.value } }
    var selection: NSRange? { state.withLock { $0.selection } }
    /// Calls that tried to set `kAXSelectedTextAttribute`.
    var valueWrites: Int { state.withLock { $0.valueWrites } }

    func setBehaviour(_ behaviour: Behaviour) {
        state.withLock { $0.behaviour = behaviour }
    }

    /// The user (or a paste) types `text` at the selection, whatever the Accessibility behaviour.
    func typeText(_ text: String) {
        state.withLock { Self.apply(text, to: &$0) }
    }

    /// Moves the caret, as a click in the field would.
    func moveCaret(to location: Int) {
        state.withLock { $0.selection = NSRange(location: location, length: 0) }
    }

    /// Makes the selection unreadable, as some apps' custom text views do.
    func clearSelection() {
        state.withLock { $0.selection = nil }
    }

    /// The app's ⌘Z: reverts the last change.
    func undoLastChange() {
        state.withLock { state in
            guard let previous = state.history.popLast() else { return }
            state.value = previous.value
            state.selection = previous.selection
        }
    }

    func string(_ attribute: String) -> String? {
        state.withLock { state in
            switch attribute {
            case kAXValueAttribute:
                let current = state.value
                if let pending = state.pendingWrite {
                    state.pendingWrite = nil
                    Self.apply(pending, to: &state)
                }
                return current
            case kAXSelectedTextAttribute:
                guard let value = state.value, let selection = state.selection else { return nil }
                return (value as NSString).substring(with: selection)
            default:
                return nil
            }
        }
    }

    func range(_ attribute: String) -> NSRange? {
        attribute == kAXSelectedTextRangeAttribute ? selection : nil
    }

    func setString(_ text: String, for attribute: String) -> Bool {
        guard attribute == kAXSelectedTextAttribute else { return false }
        return state.withLock { state in
            state.valueWrites += 1
            switch state.behaviour {
            case .normal:
                Self.apply(text, to: &state)
                return true
            case .ignoresWrites:
                return true
            case .rejectsWrites:
                return false
            case .appliesButReportsFailure:
                Self.apply(text, to: &state)
                return false
            case .truncatesWrites:
                Self.apply(String(text.prefix(text.count / 2)), to: &state)
                return true
            case .valueUnreadableAfterWrite:
                Self.apply(text, to: &state)
                state.value = nil
                return true
            case .appliesLate:
                state.pendingWrite = text
                return true
            }
        }
    }

    func setRange(_ range: NSRange, for attribute: String) -> Bool {
        guard attribute == kAXSelectedTextRangeAttribute else { return false }
        state.withLock { state in
            if !state.ignoresSelectionWrites { state.selection = range }
        }
        return true
    }

    func bounds(for range: NSRange) -> CGRect? {
        caretBounds
    }

    func isSameElement(as other: any AccessibilityElement) -> Bool {
        (other as? FakeElement) === self
    }

    private static func apply(_ text: String, to state: inout State) {
        guard let value = state.value, let selection = state.selection else { return }
        state.history.append((value, selection))
        state.value = (value as NSString).replacingCharacters(in: selection, with: text)
        state.selection = NSRange(location: selection.location + text.utf16.count, length: 0)
    }
}
