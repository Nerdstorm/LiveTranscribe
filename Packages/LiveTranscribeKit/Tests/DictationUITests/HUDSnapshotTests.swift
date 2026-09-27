import AppKit
import Dictation
@testable import DictationUI
import Foundation
import SwiftUI
import Testing

/// The folder to write the HUD's pictures to; `nil` skips them.
private let snapshotFolder = ProcessInfo.processInfo.environment["LT_HUD_SNAPSHOTS"].map {
    URL(filePath: $0, directoryHint: .isDirectory)
}

/// Draws the HUD in each of its states, in light and dark, to PNGs for a person to look at. A
/// design aid, not a check: run with LT_HUD_SNAPSHOTS set to a folder
/// (TEST_RUNNER_LT_HUD_SNAPSHOTS with xcodebuild).
///
/// `ImageRenderer` has no window behind the HUD, so the material is drawn without the blur of
/// what is behind it, over a plain backdrop.
@MainActor
@Suite(
    "HUD snapshots",
    .enabled(if: snapshotFolder != nil, "set LT_HUD_SNAPSHOTS to a folder (TEST_RUNNER_LT_HUD_SNAPSHOTS with xcodebuild)")
)
struct HUDSnapshotTests {
    struct Snapshot: Sendable, CustomTestStringConvertible {
        let name: String
        let state: HUDState
        var level: Float = 0
        var bubbleSide = HUDBubbleSide.trailing

        var testDescription: String { name }
    }

    enum Appearance: String, CaseIterable, Sendable {
        case light, dark

        var colorScheme: ColorScheme { self == .light ? .light : .dark }
        /// Roughly a window behind the HUD.
        var backdrop: Color { self == .light ? Color(white: 0.93) : Color(white: 0.16) }
    }

    private nonisolated static let problem = DictationNotice.pasteNotAllowed(needsReopen: true)

    nonisolated static let snapshots = [
        Snapshot(name: "recording-quiet", state: HUDState(indicator: .level(handsFree: false), message: nil), level: 0.003),
        Snapshot(name: "recording-loud", state: HUDState(indicator: .level(handsFree: false), message: nil), level: 0.1),
        Snapshot(name: "recording-hands-free", state: HUDState(indicator: .level(handsFree: true), message: nil), level: 0.03),
        Snapshot(
            name: "recording-microphone-notice",
            state: HUDState(indicator: .level(handsFree: false), message: "Now using AirPods Pro."),
            level: 0.03
        ),
        Snapshot(name: "transcribing", state: HUDState(indicator: .spinner, message: nil)),
        Snapshot(
            name: "problem-bubble-trailing",
            state: HUDState(indicator: .notice(isProblem: true), message: problem.message)
        ),
        Snapshot(
            name: "problem-bubble-leading",
            state: HUDState(indicator: .notice(isProblem: true), message: problem.message),
            bubbleSide: .leading
        ),
        Snapshot(
            name: "notice",
            state: HUDState(indicator: .notice(isProblem: false), message: DictationNotice.nothingHeard.message)
        ),
    ]

    @Test(arguments: snapshots, Appearance.allCases)
    func render(_ snapshot: Snapshot, appearance: Appearance) throws {
        let folder = try #require(snapshotFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hud = DictationHUDView(state: snapshot.state, level: snapshot.level, bubbleSide: snapshot.bubbleSide)
            .padding(16)
            .background(appearance.backdrop)
            .environment(\.colorScheme, appearance.colorScheme)
        let renderer = ImageRenderer(content: hud)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "the HUD could not be drawn")
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: folder.appending(path: "\(snapshot.name)-\(appearance.rawValue).png"))
    }
}
