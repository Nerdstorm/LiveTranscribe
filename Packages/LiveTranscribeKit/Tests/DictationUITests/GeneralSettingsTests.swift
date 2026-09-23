import Capture
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

    @Test func cleanupNotesSaySnippetsAndVocabularyAlwaysApply() {
        for level in CleanupLevel.allCases {
            let text = GeneralSettingsCleanupNotes.text(level: level, cleanupEnabled: true, adapterEnabled: true)
            #expect(text.contains("Snippets and vocabulary apply at every level"), "\(level)")
            #expect(!text.contains("Advanced"), "nothing is off, so nothing points to Advanced (\(level))")
        }
    }

    @Test func cleanupNotesExplainWhatAdvancedTurnedOff() {
        let modelOff = GeneralSettingsCleanupNotes.text(level: .light, cleanupEnabled: false, adapterEnabled: true)
        #expect(modelOff.contains("works like None"))

        // Self-corrections are resolved only by the adapter, and only at levels that ask for it.
        let adapterOff = GeneralSettingsCleanupNotes.text(level: .medium, cleanupEnabled: true, adapterEnabled: false)
        #expect(adapterOff.contains("Self-corrections are kept"))
        let lightWithoutAdapter = GeneralSettingsCleanupNotes.text(level: .light, cleanupEnabled: true, adapterEnabled: false)
        #expect(!lightWithoutAdapter.contains("Self-corrections"))
    }

    // MARK: - Microphone choices

    private let builtIn = AudioInputDevice(id: "built-in", name: "MacBook Pro Microphone")
    private let usb = AudioInputDevice(id: "usb", name: "USB Mic")
    private let loopback = AudioInputDevice(id: "loop", name: "Meeting Audio", isVirtual: true)

    @Test func systemDefaultComesFirstWithItsName() {
        let choices = GeneralSettingsMicrophoneChoice.choices(
            devices: [builtIn], selectedUID: nil, showVirtualDevices: false, systemDefaultName: "USB Mic"
        )
        #expect(choices.first == GeneralSettingsMicrophoneChoice(uid: nil, name: "System Default (USB Mic)"))
        let unnamed = GeneralSettingsMicrophoneChoice.choices(devices: [], selectedUID: nil, showVirtualDevices: false, systemDefaultName: nil)
        #expect(unnamed.map(\.name) == ["System Default"])
    }

    @Test func virtualDevicesAreHiddenUnlessAskedFor() {
        let hidden = GeneralSettingsMicrophoneChoice.choices(
            devices: [builtIn, loopback, usb], selectedUID: nil, showVirtualDevices: false, systemDefaultName: nil
        )
        #expect(hidden.map(\.uid) == [nil, "built-in", "usb"])
        let shown = GeneralSettingsMicrophoneChoice.choices(
            devices: [builtIn, loopback, usb], selectedUID: nil, showVirtualDevices: true, systemDefaultName: nil
        )
        #expect(shown.map(\.uid) == [nil, "built-in", "loop", "usb"])
    }

    @Test func aChosenVirtualDeviceStaysListed() {
        let choices = GeneralSettingsMicrophoneChoice.choices(
            devices: [builtIn, loopback], selectedUID: "loop", showVirtualDevices: false, systemDefaultName: nil
        )
        #expect(choices.map(\.uid) == [nil, "built-in", "loop"])
    }

    @Test func aDisconnectedChoiceIsListedSoTheSelectionStaysVisible() {
        let choices = GeneralSettingsMicrophoneChoice.choices(
            devices: [builtIn], selectedUID: "gone", showVirtualDevices: false, systemDefaultName: nil
        )
        #expect(choices.last == GeneralSettingsMicrophoneChoice(uid: "gone", name: "Disconnected microphone"))
        #expect(Set(choices.map(\.id)).count == choices.count)
    }

    // MARK: - fn key warning

    @MainActor
    @Test func warnsOnlyForFnWhenMacOSAlsoUsesIt() {
        let usage = Box(FnKeyUsage.showEmojiAndSymbols)
        let model = GeneralSettingsFnKeyModel(readUsage: { usage.value }, openURL: { _ in true })
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
            let model = GeneralSettingsFnKeyModel(readUsage: { usage }, openURL: { _ in true })
            #expect(model.warningMessage.contains(usage.fixHint))
        }
    }

    @MainActor
    @Test func opensKeyboardSettingsAndReportsAFailure() {
        let opened = Box<[URL]>([])
        let succeeds = Box(false)
        let model = GeneralSettingsFnKeyModel(readUsage: { .changeInputSource }, openURL: { url in
            opened.value.append(url)
            return succeeds.value
        })
        model.openKeyboardSettings()
        #expect(opened.value.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.Keyboard-Settings.extension"])
        #expect(model.errorMessage != nil)

        succeeds.value = true
        model.openKeyboardSettings()
        #expect(model.errorMessage == nil)
    }
}

/// A value the test changes after handing a closure that reads it to the model.
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
