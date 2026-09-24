import Foundation
import Insertion

/// One row of the Apps list: an app, and the insertion method its setting picks first.
struct AppOverrideRow: Identifiable, Equatable {
    /// Where the setting comes from.
    enum Source: String {
        /// The user's own setting, stored in `insertion-overrides.json`; editable.
        case user
        /// Shipped with the app (``AppOverrides/bundled``); read-only.
        case builtIn
    }

    /// The bundle identifier exactly as the setting stores it, which a hand-edited file may case
    /// differently from the app itself.
    let bundleIdentifier: String
    /// How to show the app; its ``AppOverrideApp/bundleIdentifier`` is ``bundleIdentifier``.
    let app: AppOverrideApp
    let method: InsertionMethod
    let source: Source
    /// For a built-in row: the user has a setting of their own for this app, which wins.
    let isReplacedByUser: Bool

    /// Unique across both sections, since an app can have a built-in and a user setting at once.
    var id: String { "\(source.rawValue):\(bundleIdentifier)" }
}

/// The per-app setting being added or edited in the sheet.
struct AppOverrideDraft: Identifiable, Equatable {
    /// Identifies the sheet while it is open.
    let id = UUID()
    /// The app, once one has been chosen.
    var app: AppOverrideApp?
    var method: InsertionMethod
    /// Whether saving adds a setting rather than changing the one for ``app``.
    let isNew: Bool
}

/// What each insertion method means, in the words of the Apps tab.
enum AppOverrideMethodText {
    /// A sentence about `method` for the picker in the editor sheet.
    static func summary(_ method: InsertionMethod) -> String {
        switch method {
        case .accessibility:
            "Types into the field directly and leaves the clipboard alone. If the app doesn\u{2019}t accept it, the text is pasted instead."
        case .paste:
            "Pastes with \u{2318}V. Works in almost every app, but briefly uses the clipboard."
        }
    }
}
