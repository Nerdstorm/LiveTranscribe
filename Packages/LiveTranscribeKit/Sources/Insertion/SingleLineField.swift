import ApplicationServices
import Foundation

/// Whether a focused field certainly takes a single line, so text dictated into it gets no line
/// breaks even in a multi-line app (see ``AppOverrides/allowsLineBreaks(in:)``).
///
/// Certain means a text field or combo box of the app's own interface: an address bar, a search
/// box (a search field reports the text field role too), a form field, a subject line. A field
/// in a web page never is: browsers and Electron apps report a rich text box as a text field
/// whenever the page doesn't mark it multi-line, and chat apps' message boxes are often such
/// boxes. Any other role, and a field whose surroundings can't be read, counts as taking several
/// lines.
enum SingleLineField {
    /// Roles of fields that take one line. A password field has the text field role too, but it
    /// never gets text.
    static let roles: Set<String> = [kAXTextFieldRole, kAXComboBoxRole]
    /// The role of a web page's root, in WebKit and in Chromium.
    static let webAreaRole = "AXWebArea"
    /// How many levels up the check looks for the window before giving up, and counting the field
    /// as not certain. A native field sits a few levels below its window.
    static let maxDepth = 64

    /// Whether `element` is certainly a single-line field. Only a field with a single-line role
    /// reads its ancestors: two Accessibility calls for each, at most ``maxDepth`` of them, and it
    /// stops at the first one that can't be read.
    static func isCertain(_ element: any AccessibilityElement) -> Bool {
        guard let role = element.role, roles.contains(role) else { return false }
        return isInAppInterface(element)
    }

    /// Whether the element's ancestors reach its window without passing a web page.
    private static func isInAppInterface(_ element: any AccessibilityElement) -> Bool {
        var current = element.parent
        for _ in 0..<maxDepth {
            guard let ancestor = current, let role = ancestor.role else { return false }
            switch role {
            case webAreaRole: return false
            case kAXWindowRole, kAXApplicationRole: return true
            default: current = ancestor.parent
            }
        }
        return false
    }
}
