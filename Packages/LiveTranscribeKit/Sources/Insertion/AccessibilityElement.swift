import ApplicationServices
import Foundation
import Shared

/// The few Accessibility operations insertion needs, on one UI element of another app.
///
/// A protocol so the inserter, router and undo logic can be tested with an in-memory element;
/// ``AXElement`` is the thin adapter over the real API. Attribute names are the `kAX…` constants.
/// Ranges are UTF-16 based, as the Accessibility API and `NSString` count them.
public protocol AccessibilityElement: Sendable {
    /// `kAXRoleAttribute`, e.g. `AXTextArea`.
    var role: String? { get }
    /// `kAXSubroleAttribute`, e.g. `AXSecureTextField`.
    var subrole: String? { get }
    /// The process that owns the element.
    var processIdentifier: pid_t? { get }

    /// A string attribute, or `nil` if the app does not provide it as a string.
    func string(_ attribute: String) -> String?
    /// A range attribute, or `nil` if the app does not provide it as a range.
    func range(_ attribute: String) -> NSRange?
    /// Sets a string attribute. `true` only means the app accepted the call, not that it acted on it.
    func setString(_ value: String, for attribute: String) -> Bool
    /// Sets a range attribute. `true` only means the app accepted the call, not that it acted on it.
    func setRange(_ range: NSRange, for attribute: String) -> Bool
    /// Screen rectangle of the text in `range` (`kAXBoundsForRangeParameterizedAttribute`).
    func bounds(for range: NSRange) -> CGRect?
    /// Whether `other` refers to the same UI element, so undo can tell that focus has not moved.
    func isSameElement(as other: any AccessibilityElement) -> Bool
}

/// An ``AccessibilityElement`` backed by a real `AXUIElement`.
///
/// Every call is a synchronous message to the owning app and can block for as long as the
/// element's messaging timeout, so callers set a short one (see ``SystemFocusedTargetProvider``).
///
/// `@unchecked Sendable`: an `AXUIElement` is an immutable CF reference to an element in another
/// process (its pid and an opaque token); it has no mutable state of its own to race on. The AX
/// client functions are not tied to the main thread, and each call is an independent IPC message,
/// so using the same reference from several tasks is safe. The SDK does not mark it `Sendable`.
public struct AXElement: AccessibilityElement, @unchecked Sendable {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }

    public var role: String? { string(kAXRoleAttribute) }

    public var subrole: String? { string(kAXSubroleAttribute) }

    public var processIdentifier: pid_t? {
        var pid: pid_t = 0
        let error = AXUIElementGetPid(element, &pid)
        guard error == .success else {
            Log.insertion.debug("AX pid unavailable: error \(error.rawValue, privacy: .public)")
            return nil
        }
        return pid
    }

    public func string(_ attribute: String) -> String? {
        copyValue(attribute) as? String
    }

    public func range(_ attribute: String) -> NSRange? {
        guard let value = copyValue(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        // Checked above: the value is an AXValue.
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    public func setString(_ value: String, for attribute: String) -> Bool {
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, value as CFString)
        return report(error, setting: attribute)
    }

    public func setRange(_ range: NSRange, for attribute: String) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        return report(error, setting: attribute)
    }

    public func bounds(for range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result
        )
        guard error == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(result, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    public func isSameElement(as other: any AccessibilityElement) -> Bool {
        guard let other = other as? AXElement else { return false }
        return CFEqual(element, other.element)
    }

    private func copyValue(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            // Expected for attributes an element does not support; kept at debug level.
            Log.insertion.debug("AX read \(attribute, privacy: .public) failed: error \(error.rawValue, privacy: .public)")
            return nil
        }
        return value
    }

    private func report(_ error: AXError, setting attribute: String) -> Bool {
        guard error == .success else {
            Log.insertion.info("AX write \(attribute, privacy: .public) failed: error \(error.rawValue, privacy: .public)")
            return false
        }
        return true
    }
}
