/// Whether the item in an editor sheet can be saved, and what to say under its fields if not.
enum EditableListValidation: Equatable, Sendable {
    case valid
    /// A required field is still empty. Save stays off and the message says what is missing,
    /// shown as a hint rather than an error: the user simply hasn't got there yet.
    case incomplete(String)
    /// What was typed can't be saved as it is (a duplicate, a trigger with no words).
    case invalid(String)

    /// Whether Save is on.
    var canSave: Bool { self == .valid }

    /// The sentence to show under the fields, if any.
    var message: String? {
        switch self {
        case .valid: nil
        case .incomplete(let message), .invalid(let message): message
        }
    }
}
