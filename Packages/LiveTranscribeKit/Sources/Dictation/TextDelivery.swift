import Foundation
import Insertion
import os
import Shared

/// Puts text at the cursor and undoes it: the Insertion slice, as the dictation flow uses it.
public protocol TextDelivery: Sendable {
    /// Whether text for `target` may contain line breaks, from its app's setting and its field
    /// (see ``AppOverrides/allowsLineBreaks(in:)``).
    func allowsLineBreaks(in target: InsertionTarget) async -> Bool
    func insert(_ text: String, into target: InsertionTarget) async -> InsertionResult
    func undo(_ record: InsertionRecord, replacingWith text: String, in target: InsertionTarget) async -> UndoResult
}

/// The system's text delivery: Accessibility, then paste, then the clipboard.
///
/// The router is built for each call from the current settings and per-app overrides, and line
/// breaks are decided from the current overrides, so a change in Settings applies to the next
/// dictation. The paste inserter is kept between calls:
/// pastes through one inserter never overlap, which keeps the user's clipboard safe when an undo
/// pastes while a dictation is still restoring it.
public final class SystemTextDelivery: TextDelivery {
    private let settings: @Sendable () -> AppSettings
    private let overrides: AppOverridesStore
    private let focus: any FocusedTargetProvider
    private let pasteboard = SystemPasteboard()
    private let keystrokes = CGEventKeystrokeSender()
    /// The shared paste inserter and the restore delay it was built with; rebuilt when the
    /// delay changes in Settings.
    private let pasteInserter = OSAllocatedUnfairLock<(delayMs: Int, inserter: PasteboardTextInserter)?>(initialState: nil)

    /// - Parameter focus: Read again just before each paste, so ⌘V never goes to a password
    ///   field or another app that took focus while the dictation was processed. The same
    ///   provider the dictation flow reads the target with.
    public init(
        settings: @escaping @Sendable () -> AppSettings,
        overrides: AppOverridesStore,
        focus: any FocusedTargetProvider
    ) {
        self.settings = settings
        self.overrides = overrides
        self.focus = focus
    }

    public func allowsLineBreaks(in target: InsertionTarget) async -> Bool {
        await currentOverrides().allowsLineBreaks(in: target)
    }

    public func insert(_ text: String, into target: InsertionTarget) async -> InsertionResult {
        await router(settings().dictation).insert(text, into: target)
    }

    public func undo(_ record: InsertionRecord, replacingWith text: String, in target: InsertionTarget) async -> UndoResult {
        let current = settings().dictation
        let undoer = InsertionUndoer(
            router: await router(current),
            keystrokes: keystrokes,
            settleDelayMs: current.undoSettleDelayMs
        )
        return await undoer.undo(record, replacingWith: text, in: target)
    }

    private func router(_ settings: DictationSettings) async -> InsertionRouter {
        InsertionRouter(
            accessibility: AXTextInserter(verificationDelayMs: settings.accessibilityVerificationDelayMs),
            paste: paste(restoreDelayMs: settings.pasteRestoreDelayMs),
            pasteboard: pasteboard,
            overrides: await currentOverrides()
        )
    }

    /// The built-in overrides with the user's on top; the built-in ones alone when the user's
    /// can't be read.
    private func currentOverrides() async -> AppOverrides {
        do {
            return .bundled.merged(with: try await overrides.load())
        } catch {
            Log.insertion.error("Per-app settings unreadable: \(error.localizedDescription, privacy: .public)")
            return .bundled
        }
    }

    private func paste(restoreDelayMs: Int) -> PasteboardTextInserter {
        let pasteboard = pasteboard
        let keystrokes = keystrokes
        let focus = focus
        return pasteInserter.withLock { cached in
            if let cached, cached.delayMs == restoreDelayMs { return cached.inserter }
            let inserter = PasteboardTextInserter(
                pasteboard: pasteboard, keystrokes: keystrokes, focus: focus, restoreDelayMs: restoreDelayMs
            )
            cached = (restoreDelayMs, inserter)
            return inserter
        }
    }
}
