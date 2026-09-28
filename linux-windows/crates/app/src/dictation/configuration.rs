//! What each part of dictation takes from the settings.

use std::path::{Path, PathBuf};
use std::time::Duration;

use lt_capture::RecorderConfiguration;
use lt_dictation::{Configuration, ControllerConfiguration};
use lt_hotkey::HotkeyGestureConfiguration;
use lt_insertion::InsertionConfiguration;
use lt_transcription::qwen3_asr::DeviceChoice;

use crate::paths;
use crate::settings::Settings;

/// How long an app gets to read pasted text before it is left on the clipboard instead.
const PASTE_READ_TIMEOUT: Duration = Duration::from_secs(2);

pub(crate) fn controller(settings: &Settings) -> ControllerConfiguration {
    ControllerConfiguration {
        gesture: HotkeyGestureConfiguration {
            tap_max_ms: settings.hotkey_tap_max_ms,
            double_tap_window_ms: settings.hotkey_double_tap_window_ms,
            hands_free_enabled: settings.hands_free_enabled,
        },
        min_utterance_ms: usize::try_from(settings.dictation_min_utterance_ms).unwrap_or(usize::MAX),
        max_recording_seconds: settings.dictation_max_recording_seconds,
        text: Configuration {
            level: settings.cleanup_level,
            snippets: Vec::new(),
            vocabulary: Vec::new(),
            // Each field says whether it takes line breaks.
            multiline: false,
        },
    }
}

pub(crate) fn recorder(settings: &Settings) -> RecorderConfiguration {
    RecorderConfiguration {
        max_duration_seconds: settings.dictation_max_recording_seconds,
        device: settings.input_device_id.clone(),
    }
}

pub(crate) fn insertion(settings: &Settings) -> InsertionConfiguration {
    InsertionConfiguration {
        restore_delay: Duration::from_millis(settings.paste_restore_delay_ms),
        read_timeout: PASTE_READ_TIMEOUT,
    }
}

/// How long each of the panel's messages shows.
pub(crate) fn notice_ms(settings: &Settings) -> u64 {
    // In range by the settings' repair: 0.5 to 10 s.
    (settings.dictation_notice_seconds * 1_000.0).round() as u64
}

/// The speech model to load, and where it runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ModelChoice {
    pub(crate) folder: PathBuf,
    pub(crate) device: DeviceChoice,
    /// It's the default model, which is downloaded when it isn't in its folder yet.
    pub(crate) downloadable: bool,
}

impl ModelChoice {
    pub(crate) fn from_settings(settings: &Settings) -> anyhow::Result<Self> {
        let default = paths::default_model()?;
        let folder = match settings.stt_model.as_deref() {
            None => default.clone(),
            Some(model) => model_folder(model, &paths::models_folder()?),
        };
        Ok(Self {
            downloadable: folder == default,
            folder,
            device: settings.stt_device.parse().unwrap_or(DeviceChoice::Auto),
        })
    }
}

/// `model` is a folder in `models`, or a path to one elsewhere.
fn model_folder(model: &str, models: &Path) -> PathBuf {
    let path = Path::new(model);
    if path.is_absolute() {
        path.to_owned()
    } else {
        models.join(path)
    }
}

#[cfg(test)]
mod tests {
    use lt_shared::CleanupLevel;

    use super::*;

    #[test]
    fn each_part_gets_its_settings() {
        let settings = Settings {
            hands_free_enabled: false,
            cleanup_level: CleanupLevel::High,
            hotkey_tap_max_ms: 250,
            dictation_min_utterance_ms: 400,
            dictation_max_recording_seconds: 60,
            dictation_notice_seconds: 1.5,
            paste_restore_delay_ms: 500,
            input_device_id: Some("pulseaudio:alsa_input.usb".to_owned()),
            ..Settings::default()
        };
        let controller = controller(&settings);
        assert!(!controller.gesture.hands_free_enabled);
        assert_eq!(controller.gesture.tap_max_ms, 250);
        assert_eq!(controller.min_utterance_ms, 400);
        assert_eq!(controller.max_recording_seconds, 60);
        assert_eq!(controller.text.level, CleanupLevel::High);
        let recorder = recorder(&settings);
        assert_eq!(
            recorder.max_duration_seconds, 60,
            "the recorder stops where the notice says it did"
        );
        assert_eq!(recorder.device.as_deref(), Some("pulseaudio:alsa_input.usb"));
        assert_eq!(insertion(&settings).restore_delay, Duration::from_millis(500));
        assert_eq!(notice_ms(&settings), 1_500);
    }

    #[test]
    fn a_model_is_a_folder_in_the_models_folder_or_a_path() {
        let models = Path::new("/home/me/.local/share/live-transcribe/models");
        assert_eq!(
            model_folder("qwen3-asr-0.6b-v2", models),
            models.join("qwen3-asr-0.6b-v2")
        );
        assert_eq!(model_folder("/srv/models/mine", models), Path::new("/srv/models/mine"));
    }
}
