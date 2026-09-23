import AppKit
import SwiftUI

/// A multi-line plain-text field that keeps exactly what is typed.
///
/// SwiftUI's `TextEditor` follows the system's text substitutions, which are on by default: it
/// turns `"` into `“`, `--` into `—`, and applies the user's text replacements and spelling
/// corrections as they type. That would silently change a snippet's URL or code, or a spoken
/// variant, so this wraps an `NSTextView` with every automatic substitution off.
///
/// Tab moves to the next field, as in the rest of the sheet; Option-Tab types a tab.
struct EditableListPlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// What VoiceOver calls the field.
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        // Offered completions that one keystroke accepts: predicted words (macOS 14), and the
        // result of an expression ending in "=" (macOS 15), which would turn "2+2=" into "2+2=4".
        textView.inlinePredictionType = .no
        if #available(macOS 15.0, *) {
            textView.mathExpressionCompletionType = .no
        }
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(accessibilityLabel)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.setAccessibilityLabel(accessibilityLabel)
        // Replacing the string mid-composition would cancel an input method's marked text.
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
        }
    }

    /// Copies the text view's edits into the binding, and turns Tab into moving focus.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }
    }
}
