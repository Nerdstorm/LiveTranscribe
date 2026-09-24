import AppKit
import ApplicationServices
import Carbon
import Shared

/// Finds the focused field through the system-wide Accessibility element.
///
/// Needs Accessibility permission; without it there is no focused element and the router pastes.
public struct SystemFocusedTargetProvider: FocusedTargetProvider {
    private let messagingTimeoutSeconds: Float

    /// - Parameter messagingTimeoutMs: How long any Accessibility call may wait for the target app.
    ///   Every AX call is a synchronous message, so a hung app would otherwise stall dictation for
    ///   the system default of about 6 s. `0` restores that default.
    public init(messagingTimeoutMs: Int) {
        self.messagingTimeoutSeconds = Float(max(0, messagingTimeoutMs)) / 1_000
    }

    /// Makes up to five Accessibility calls to the focused app, each bounded by the messaging
    /// timeout; call it off the main actor so a slow app cannot stall the UI.
    public func currentTarget() -> InsertionTarget {
        let element = focusedElement()
        let target = InsertionTarget(
            app: owningApp(of: element),
            element: element,
            secureEventInputEnabled: IsSecureEventInputEnabled()
        )
        Log.insertion.debug("""
            Focused target: \(target.app?.bundleIdentifier ?? "unknown", privacy: .public), \
            element \(element.map { $0.role ?? "without a role" } ?? "none", privacy: .public), \
            secure \(target.isSecure, privacy: .public)
            """)
        return target
    }

    private func focusedElement() -> AXElement? {
        let systemWide = AXUIElementCreateSystemWide()
        // On the system-wide element the timeout is process-wide, and it also bounds this query,
        // which the focused app answers. Set on every call: it is cheap, and it then holds even if
        // permission was granted, or the timeout changed, after launch.
        let timeoutError = AXUIElementSetMessagingTimeout(systemWide, messagingTimeoutSeconds)
        if timeoutError != .success {
            Log.insertion.debug("AX messaging timeout not set: error \(timeoutError.rawValue, privacy: .public)")
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            // .noValue when nothing is focused; .apiDisabled without Accessibility permission.
            Log.insertion.info("No focused element: AX error \(error.rawValue, privacy: .public)")
            return nil
        }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        // Also per element, in case another part of the process changes the global timeout.
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
        return AXElement(element)
    }

    /// The app that owns the focused element, else the frontmost app.
    ///
    /// The owner is preferred because a non-activating panel (Spotlight, a launcher) takes the
    /// keyboard without becoming the frontmost app, and the text and ⌘V go to the owner.
    private func owningApp(of element: AXElement?) -> AppInfo? {
        let owner = element?.processIdentifier.flatMap { NSRunningApplication(processIdentifier: $0) }
        guard let app = owner ?? NSWorkspace.shared.frontmostApplication else { return nil }
        return AppInfo(
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "Unknown app",
            processIdentifier: app.processIdentifier
        )
    }
}
