import ApplicationServices
import Foundation

/// How many UTF-16 units before the caret ``AccessibilityElement/characterBeforeSelection()``
/// reads.
///
/// Not a tunable: it only has to hold one user-perceived character. The longest standard emoji
/// sequences (a flag with tag characters, a couple with skin tones) are 14–15 units. A longer
/// cluster, such as a letter under dozens of combining marks, is cut to its tail, which is never
/// whitespace or an opening bracket or quote either, so the spacing decision made from it is the
/// same.
private let caretLookbackUTF16Units = 16

extension AccessibilityElement {
    /// The character just before the caret, or before the selection that inserted text will
    /// replace; `nil` at the start of the field or when the app cannot say.
    ///
    /// Reads the selection, then only the few UTF-16 units before it
    /// (``string(forRange:)``), never the whole value: a field can hold a multi-megabyte
    /// document, and every Accessibility call is a message to the other app. So an app without
    /// `kAXStringForRangeParameterizedAttribute` gets `nil`. The two calls are each bounded by
    /// the element's messaging timeout; make them off the main actor.
    public func characterBeforeSelection() -> Character? {
        guard let selection = range(kAXSelectedTextRangeAttribute),
              selection.location != NSNotFound,
              selection.location > 0
        else { return nil }
        let start = max(0, selection.location - caretLookbackUTF16Units)
        let before = NSRange(location: start, length: selection.location - start)
        // `last` is a whole grapheme cluster: a surrogate pair or a composed sequence stays intact.
        return string(forRange: before)?.last
    }
}
