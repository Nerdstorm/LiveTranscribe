@testable import DictationUI
import Foundation
import Hotkey
import Shared
import Testing

@Suite("General settings")
struct GeneralSettingsTests {
    // MARK: - Timing

    @Test func everyTimingRangeMatchesTheControllersClamps() {
        for field in GeneralSettingsTimingField.all {
            var below = AppSettings.defaults.dictation
            var above = AppSettings.defaults.dictation
            switch field.value {
            case .int(let keyPath, let range, _):
                below[keyPath: keyPath] = range.lowerBound - 1
                above[keyPath: keyPath] = range.upperBound + 1
                #expect(below.sanitized()[keyPath: keyPath] == range.lowerBound, "\(field.key)")
                #expect(above.sanitized()[keyPath: keyPath] == range.upperBound, "\(field.key)")
                #expect(range.contains(AppSettings.defaults.dictation[keyPath: keyPath]), "\(field.key)")
            case .double(let keyPath, let range, _, _):
                below[keyPath: keyPath] = range.lowerBound - 0.01
                above[keyPath: keyPath] = range.upperBound + 0.01
                #expect(below.sanitized()[keyPath: keyPath] == range.lowerBound, "\(field.key)")
                #expect(above.sanitized()[keyPath: keyPath] == range.upperBound, "\(field.key)")
                #expect(range.contains(AppSettings.defaults.dictation[keyPath: keyPath]), "\(field.key)")
            }
        }
    }

    @Test func everyTimingFieldHasItsOwnKeyAndText() {
        let fields = GeneralSettingsTimingField.all
        #expect(Set(fields.map(\.key)).count == fields.count)
        #expect(fields.count == 13)
        for field in fields {
            #expect(!field.label.isEmpty)
            #expect(!field.help.isEmpty)
        }
    }

    @Test func timingKeysAreTheOnesTheStoreReads() {
        // Each field writes its value to the key AppSettingsStore loads it from.
        let suite = "GeneralSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for field in GeneralSettingsTimingField.all {
            switch field.value {
            case .int(_, let range, _): defaults.set(range.upperBound, forKey: field.key.rawValue)
            case .double(_, let range, _, _): defaults.set(range.upperBound, forKey: field.key.rawValue)
            }
        }
        let loaded = AppSettingsStore(suiteName: suite).load().dictation
        for field in GeneralSettingsTimingField.all {
            switch field.value {
            case .int(let keyPath, let range, _): #expect(loaded[keyPath: keyPath] == range.upperBound, "\(field.key)")
            case .double(let keyPath, let range, _, _): #expect(loaded[keyPath: keyPath] == range.upperBound, "\(field.key)")
            }
        }
    }

    @Test func aStoredValueOutsideTheRangeIsShownAsItTakesEffect() {
        #expect(GeneralSettingsTimingField.effective(5_000, in: 100...1_000) == 1_000)
        #expect(GeneralSettingsTimingField.effective(-3, in: 0...2_000) == 0)
        #expect(GeneralSettingsTimingField.effective(0.3, in: 0.5...1.0) == Double(0.5))
        #expect(GeneralSettingsTimingField.effective(300, in: 100...1_000) == 300)
    }

    @Test func fractionalStepsStoreTheValueShown() {
        #expect(Double(0.8) + 0.05 != 0.85, "the drift this guards against")
        #expect(GeneralSettingsTimingField.rounded(0.8 + 0.05, fractionDigits: 2) == 0.85)
        #expect(GeneralSettingsTimingField.rounded(2.5 + 0.5, fractionDigits: 1) == 3.0)
    }

    // MARK: - Cleanup notes

    private typealias Switches = GeneralSettingsCleanupNotes.ModelSwitches
    private static let allOn = Switches(cleanupEnabled: true, adapterEnabled: true)

    private func notes(_ level: CleanupLevel, inEffect: Switches, stored: Switches? = nil) -> String {
        GeneralSettingsCleanupNotes.text(level: level, inEffect: inEffect, stored: stored ?? inEffect)
    }

    /// The level applies to both modes, but snippets, vocabulary and spoken commands only to
    /// dictation (the live transcript applies none of them), so the note names dictation.
    @Test func cleanupNotesSaySnippetsVocabularyAndCommandsAlwaysApply() {
        for level in CleanupLevel.allCases {
            let text = notes(level, inEffect: Self.allOn)
            #expect(text.contains("Dictation applies your snippets, vocabulary and spoken commands at every level"), "\(level)")
            #expect(!text.contains("Advanced"), "nothing is off, so nothing points to Advanced (\(level))")
            #expect(!text.contains("starts"), "nothing waits for a restart (\(level))")
        }
    }

    /// Without the model, Medium and High still remove fillers and format lists, so the levels
    /// do not work like None; the note says what does happen.
    @Test func cleanupNotesSayWhatTheLevelsStillDoWithTheModelOff() {
        let off = Switches(cleanupEnabled: false, adapterEnabled: true)
        for level in CleanupLevel.allCases {
            let text = notes(level, inEffect: off)
            #expect(text.contains("The cleanup model is off in Advanced, so nothing is reworded"), "\(level)")
            #expect(text.contains("still removes filler words and lays out spoken lists and letters at Medium and High"), "\(level)")
            #expect(!text.contains("works like None"), "\(level)")
            #expect(!text.contains("Self-corrections"), "the model being off says it all (\(level))")
        }
    }

    /// Self-corrections are resolved only by the adapter, and only at levels that ask for it.
    @Test func cleanupNotesExplainTheAdapterBeingOff() {
        let adapterOff = Switches(cleanupEnabled: true, adapterEnabled: false)
        #expect(notes(.medium, inEffect: adapterOff).contains("Self-corrections are kept as spoken, because Resolve spoken self-corrections is off in Advanced."))
        #expect(!notes(.light, inEffect: adapterOff).contains("Self-corrections"))
    }

    /// Advanced's switches apply at the next launch, so General describes the ones in effect and
    /// says what changes once Live Transcribe restarts.
    @Test func cleanupNotesSayWhenAChangeWaitsForARestart() {
        let modelOff = Switches(cleanupEnabled: false, adapterEnabled: true)
        let adapterOff = Switches(cleanupEnabled: true, adapterEnabled: false)

        let turningOff = notes(.medium, inEffect: Self.allOn, stored: modelOff)
        #expect(turningOff.contains("The cleanup model turns off the next time Live Transcribe starts."))
        #expect(!turningOff.contains("nothing is reworded"), "the model still cleans up until then")

        let turningOn = notes(.medium, inEffect: modelOff, stored: Self.allOn)
        #expect(turningOn.contains("The cleanup model is off until Live Transcribe restarts, so nothing is reworded"))
        #expect(!turningOn.contains("off in Advanced"), "Advanced already shows it on")

        #expect(notes(.high, inEffect: Self.allOn, stored: adapterOff)
            .contains("Resolve spoken self-corrections turns off the next time Live Transcribe starts."))
        let adapterTurningOn = notes(.medium, inEffect: adapterOff, stored: Self.allOn)
        #expect(adapterTurningOn.contains("Self-corrections are kept as spoken until Live Transcribe restarts"))
        #expect(!adapterTurningOn.contains("off in Advanced"))
    }

    /// The switches in effect are the ones Live Transcribe started with.
    @Test func switchesInEffectComeFromTheLaunchSettings() {
        var settings = AppSettings.defaults
        settings.cleanupEnabled = false
        settings.cleanupAdapterEnabled = true
        #expect(Switches(settings: settings) == Switches(cleanupEnabled: false, adapterEnabled: true))
    }

    // MARK: - fn key warning

    @MainActor
    @Test func warnsOnlyForFnWhenMacOSAlsoUsesIt() {
        let usage = Box(FnKeyUsage.showEmojiAndSymbols)
        let model = GeneralSettingsFnKeyModel(readUsage: { usage.value }, openKeyboardSettings: { true })
        #expect(model.showsWarning(forStoredHotkey: HotkeyBinding.defaultDictation.storageString))
        #expect(model.showsWarning(forStoredHotkey: "damaged"), "a damaged value falls back to fn")
        #expect(!model.showsWarning(forStoredHotkey: HotkeyBinding.modifierKey(.rightOption).storageString))
        #expect(model.warningMessage.contains("Do Nothing"))

        usage.value = .doNothing
        #expect(model.showsWarning(forStoredHotkey: "modifier:fn"), "not re-read until refresh")
        model.refresh()
        #expect(!model.showsWarning(forStoredHotkey: "modifier:fn"))
    }

    @MainActor
    @Test func everyConflictingUsageExplainsItself() {
        for usage in FnKeyUsage.allCases where usage.conflictsWithFnHotkey {
            let model = GeneralSettingsFnKeyModel(readUsage: { usage }, openKeyboardSettings: { true })
            #expect(model.warningMessage.contains(usage.fixHint))
        }
    }

    @MainActor
    @Test func opensKeyboardSettingsAndReportsAFailure() {
        let opened = Box(0)
        let succeeds = Box(false)
        let model = GeneralSettingsFnKeyModel(readUsage: { .changeInputSource }, openKeyboardSettings: {
            opened.value += 1
            return succeeds.value
        })
        model.openKeyboardSettings()
        #expect(opened.value == 1)
        #expect(model.errorMessage == "Couldn't open System Settings. Open it from the Apple menu, then choose Keyboard.")

        succeeds.value = true
        model.openKeyboardSettings()
        #expect(opened.value == 2)
        #expect(model.errorMessage == nil)
    }
}

/// A value the test changes after handing a closure that reads it to the model.
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
