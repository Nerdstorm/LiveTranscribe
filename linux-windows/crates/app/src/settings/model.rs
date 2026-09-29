//! The settings, as `settings.json` keeps them. A setting the Mac app has too goes under the Mac's
//! key (AppSettingsKey, docs/dictation.md "Settings"), with its default and its range.
//!
//! Reading is forgiving: a value that isn't valid is reported and its default used, the rest
//! still count, and keys this version doesn't know (from a later one) are kept and written back.
//! A change from the app is strict instead: it is refused whole, and the file keeps what it had.

use lt_hotkey::{KeyTracker, key_code, key_name};
use lt_shared::CleanupLevel;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// Where the speech model runs: [`lt_transcription::qwen3_asr::DeviceChoice`]'s names.
pub const DEVICES: [&str; 4] = ["auto", "NPU", "GPU", "CPU"];

/// Every setting.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    /// Whether the hotkey starts dictation. Off, the tray's *Start Dictation* still does.
    pub dictation_enabled: bool,
    /// The key to hold, as linux/input-event-codes.h names it (`KEY_RIGHTCTRL`).
    pub dictation_hotkey: String,
    pub hands_free_enabled: bool,
    #[serde(with = "cleanup_level")]
    pub cleanup_level: CleanupLevel,
    /// The microphone, as [`lt_capture::InputDevice::id`] names it; `None` for the system's
    /// default input.
    pub input_device_id: Option<String>,
    pub hotkey_tap_max_ms: u64,
    pub hotkey_double_tap_window_ms: u64,
    pub dictation_min_utterance_ms: u64,
    pub dictation_max_recording_seconds: u32,
    pub dictation_notice_seconds: f64,
    pub paste_restore_delay_ms: u64,
    /// The speech model: a catalog model's id, or a folder the setup kit converted a model into,
    /// in the app's models folder or a path; `None` for the default model.
    pub stt_model: Option<String>,
    /// Where a Qwen3-ASR model runs: one of [`DEVICES`]. The catalog's other models run on the CPU.
    pub stt_device: String,
    /// Keys this version doesn't know, kept for the version that wrote them.
    #[serde(flatten)]
    pub unknown: Map<String, Value>,
}

impl Default for Settings {
    /// The Mac's defaults (DictationSettings.defaults), with Right Ctrl for its fn key.
    fn default() -> Self {
        Self {
            dictation_enabled: true,
            dictation_hotkey: "KEY_RIGHTCTRL".to_owned(),
            hands_free_enabled: true,
            cleanup_level: CleanupLevel::Medium,
            input_device_id: None,
            hotkey_tap_max_ms: 300,
            hotkey_double_tap_window_ms: 300,
            dictation_min_utterance_ms: 300,
            dictation_max_recording_seconds: 300,
            dictation_notice_seconds: 2.5,
            paste_restore_delay_ms: 250,
            stt_model: None,
            stt_device: "auto".to_owned(),
            unknown: Map::new(),
        }
    }
}

/// The settings on the Advanced tab, which its Restore Defaults resets, as the Mac's does. The
/// model is chosen in the Models tab.
pub const ADVANCED_KEYS: [&str; 1] = ["sttDevice"];

impl Settings {
    /// Every key the settings have.
    pub fn keys() -> Vec<String> {
        match serde_json::to_value(Self::default()) {
            Ok(Value::Object(map)) => map.into_iter().map(|(key, _)| key).collect(),
            _ => Vec::new(),
        }
    }

    /// Reads `settings.json`: every valid value, the default for the rest, and what was wrong.
    pub fn read(text: &str) -> Result<(Self, Vec<String>), String> {
        let Value::Object(values) = serde_json::from_str(text).map_err(|error| error.to_string())? else {
            return Err("it isn't a JSON object".to_owned());
        };
        let mut settings = Self::default();
        let mut problems = Vec::new();
        for (key, value) in values {
            if let Err(problem) = settings.set(&key, value) {
                problems.push(problem);
            }
        }
        problems.extend(settings.repair());
        Ok((settings, problems))
    }

    /// The settings with `changes` (keys and values, as the file has them) made, or why not:
    /// each key must be a setting, and each value valid for it.
    pub fn changed(&self, changes: &Map<String, Value>) -> Result<Self, String> {
        let known = Self::keys();
        let mut settings = self.clone();
        for (key, value) in changes {
            if !known.contains(key) {
                return Err(format!("there is no setting {key}"));
            }
            settings.set(key, value.clone())?;
        }
        let problems = settings.repair();
        if problems.is_empty() {
            Ok(settings)
        } else {
            Err(problems.join("; "))
        }
    }

    /// Sets one key to `value`, if the value is valid for it; an unknown key is kept as it is.
    fn set(&mut self, key: &str, value: Value) -> Result<(), String> {
        let Ok(Value::Object(mut map)) = serde_json::to_value(&*self) else {
            return Err("the settings can't be written".to_owned());
        };
        map.insert(key.to_owned(), value);
        *self = serde_json::from_value(Value::Object(map)).map_err(|error| format!("{key}: {error}"))?;
        Ok(())
    }

    /// Puts every value in its range and names in their canonical form, and returns what had to
    /// go back to its default because it could never be used.
    fn repair(&mut self) -> Vec<String> {
        let defaults = Self::default();
        let mut problems = Vec::new();
        match canonical_hotkey(&self.dictation_hotkey) {
            Ok(name) => self.dictation_hotkey = name,
            Err(problem) => {
                problems.push(format!("dictationHotkey: {problem}"));
                self.dictation_hotkey = defaults.dictation_hotkey;
            }
        }
        match DEVICES
            .iter()
            .find(|device| device.eq_ignore_ascii_case(self.stt_device.trim()))
        {
            Some(device) => self.stt_device = (*device).to_owned(),
            None => {
                problems.push(format!(
                    "sttDevice: {} isn't one of {}",
                    self.stt_device,
                    DEVICES.join(", ")
                ));
                self.stt_device = defaults.stt_device;
            }
        }
        for text in [&mut self.input_device_id, &mut self.stt_model] {
            if text.as_deref().is_some_and(|text| text.trim().is_empty()) {
                *text = None;
            }
        }
        self.hotkey_tap_max_ms = self.hotkey_tap_max_ms.clamp(100, 1_000);
        self.hotkey_double_tap_window_ms = self.hotkey_double_tap_window_ms.clamp(100, 1_000);
        self.dictation_min_utterance_ms = self.dictation_min_utterance_ms.clamp(0, 2_000);
        self.dictation_max_recording_seconds = self.dictation_max_recording_seconds.clamp(10, 1_800);
        self.paste_restore_delay_ms = self.paste_restore_delay_ms.clamp(50, 5_000);
        self.dictation_notice_seconds = if self.dictation_notice_seconds.is_finite() {
            self.dictation_notice_seconds.clamp(0.5, 10.0)
        } else {
            defaults.dictation_notice_seconds
        };
        problems
    }
}

/// The hotkey's name as `livetranscribe keys` prints it, if the key can be the hotkey.
fn canonical_hotkey(name: &str) -> Result<String, String> {
    let code = key_code(name).ok_or_else(|| format!("{name} isn't a key name"))?;
    KeyTracker::new(code).map_err(|reason| reason.to_string())?;
    Ok(key_name(code))
}

/// A cleanup level as its name: `none`, `light`, `medium` or `high`.
mod cleanup_level {
    use lt_shared::CleanupLevel;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(level: &CleanupLevel, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(level.as_str())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<CleanupLevel, D::Error> {
        let name = String::deserialize(deserializer)?;
        CleanupLevel::ALL
            .into_iter()
            .find(|level| level.as_str() == name)
            .ok_or_else(|| serde::de::Error::custom(format!("{name} isn't one of none, light, medium or high")))
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn changes(value: Value) -> Map<String, Value> {
        match value {
            Value::Object(map) => map,
            _ => panic!("an object"),
        }
    }

    #[test]
    fn the_defaults_are_the_macs() {
        let settings = Settings::default();
        let text = serde_json::to_string(&settings).unwrap();
        let (read, problems) = Settings::read(&text).unwrap();
        assert_eq!(read, settings);
        assert!(problems.is_empty(), "{problems:?}");
        assert_eq!(
            serde_json::to_value(&settings).unwrap(),
            json!({
                "dictationEnabled": true,
                "dictationHotkey": "KEY_RIGHTCTRL",
                "handsFreeEnabled": true,
                "cleanupLevel": "medium",
                "inputDeviceId": null,
                "hotkeyTapMaxMs": 300,
                "hotkeyDoubleTapWindowMs": 300,
                "dictationMinUtteranceMs": 300,
                "dictationMaxRecordingSeconds": 300,
                "dictationNoticeSeconds": 2.5,
                "pasteRestoreDelayMs": 250,
                "sttModel": null,
                "sttDevice": "auto",
            })
        );
    }

    #[test]
    fn a_missing_setting_is_its_default() {
        let (settings, problems) = Settings::read(r#"{"cleanupLevel": "high"}"#).unwrap();
        assert_eq!(settings.cleanup_level, CleanupLevel::High);
        assert_eq!(settings.dictation_hotkey, "KEY_RIGHTCTRL");
        assert!(problems.is_empty());
    }

    #[test]
    fn a_bad_value_is_reported_and_the_rest_still_count() {
        let (settings, problems) = Settings::read(
            r#"{"cleanupLevel": "extreme", "handsFreeEnabled": false, "dictationHotkey": "KEY_ESC",
                "sttDevice": "TPU", "hotkeyTapMaxMs": "fast"}"#,
        )
        .unwrap();
        assert!(!settings.hands_free_enabled);
        assert_eq!(settings.cleanup_level, CleanupLevel::Medium);
        assert_eq!(settings.dictation_hotkey, "KEY_RIGHTCTRL");
        assert_eq!(settings.stt_device, "auto");
        assert_eq!(settings.hotkey_tap_max_ms, 300);
        assert_eq!(problems.len(), 4, "{problems:?}");
        assert!(problems.iter().any(|problem| problem.contains("extreme")));
        assert!(problems.iter().any(|problem| problem.contains("Esc cancels dictation")));
    }

    #[test]
    fn keys_from_a_later_version_are_kept() {
        let (settings, _) = Settings::read(r#"{"historyEnabled": false, "cleanupLevel": "light"}"#).unwrap();
        assert_eq!(settings.unknown.get("historyEnabled"), Some(&json!(false)));
        let written = serde_json::to_value(&settings).unwrap();
        assert_eq!(written["historyEnabled"], json!(false));
        assert_eq!(written["cleanupLevel"], json!("light"));
    }

    #[test]
    fn values_are_put_in_their_range_and_names_in_their_canonical_form() {
        let (settings, problems) = Settings::read(
            r#"{"hotkeyTapMaxMs": 5, "dictationMaxRecordingSeconds": 100000, "dictationNoticeSeconds": 0.1,
                "pasteRestoreDelayMs": 0, "dictationHotkey": "rightalt", "sttDevice": "npu",
                "inputDeviceId": " ", "sttModel": ""}"#,
        )
        .unwrap();
        assert!(problems.is_empty(), "{problems:?}");
        assert_eq!(settings.hotkey_tap_max_ms, 100);
        assert_eq!(settings.dictation_max_recording_seconds, 1_800);
        assert!((settings.dictation_notice_seconds - 0.5).abs() < f64::EPSILON);
        assert_eq!(settings.paste_restore_delay_ms, 50);
        assert_eq!(settings.dictation_hotkey, "KEY_RIGHTALT");
        assert_eq!(settings.stt_device, "NPU");
        assert_eq!((settings.input_device_id, settings.stt_model), (None, None));
    }

    #[test]
    fn what_isnt_settings_is_refused() {
        assert!(Settings::read("[1, 2]").is_err());
        assert!(Settings::read("{").is_err());
    }

    #[test]
    fn a_change_is_made_whole_or_not_at_all() {
        let settings = Settings::default();
        let changed = settings
            .changed(&changes(json!({"cleanupLevel": "none", "dictationHotkey": "KEY_F23"})))
            .unwrap();
        assert_eq!(changed.cleanup_level, CleanupLevel::None);
        assert_eq!(changed.dictation_hotkey, "KEY_F23");

        let refused = settings.changed(&changes(json!({"cleanupLevel": "none", "dictationHotkey": "KEY_ESC"})));
        assert!(refused.unwrap_err().contains("Esc cancels dictation"));
        assert!(settings.changed(&changes(json!({"cleanupLevel": 3}))).is_err());
        assert!(
            settings.changed(&changes(json!({"historyEnabled": true}))).is_err(),
            "not a setting of this version"
        );
        assert_eq!(settings, Settings::default(), "the original is untouched");
    }

    #[test]
    fn the_advanced_keys_are_settings() {
        let keys = Settings::keys();
        assert!(ADVANCED_KEYS.iter().all(|key| keys.contains(&(*key).to_owned())));
    }
}
