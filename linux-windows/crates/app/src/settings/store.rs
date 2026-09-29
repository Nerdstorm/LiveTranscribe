//! `settings.json`, in the platform's config folder (on Linux, `~/.config/live-transcribe`), and
//! the command line's options, which set a setting for one run without saving it.
//!
//! The file is only the user's: the folder is made owner-only, and the file is written whole
//! to a temporary file beside it, then renamed over it, so it is never left half written.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use super::model::Settings;

pub struct SettingsStore {
    path: PathBuf,
    /// What the file holds.
    saved: Settings,
    /// Settings from the command line, for this run only: they win over the file's until the
    /// setting is changed in the app.
    overrides: Map<String, Value>,
}

impl SettingsStore {
    /// Reads the settings at `path`: the defaults when there is no file yet. A file that isn't
    /// settings at all is moved aside (`settings.json.unreadable`), so it is neither used nor
    /// lost, and the defaults are used. Returns what was wrong, to be told.
    pub fn open(path: PathBuf, overrides: Map<String, Value>) -> (Self, Vec<String>) {
        let mut problems = Vec::new();
        let saved = match fs::read_to_string(&path) {
            Ok(text) => match Settings::read(&text) {
                Ok((settings, found)) => {
                    problems.extend(
                        found
                            .into_iter()
                            .map(|problem| format!("{}: {problem}; its default is used", path.display())),
                    );
                    settings
                }
                Err(error) => {
                    let aside = path.with_extension("json.unreadable");
                    let moved = fs::rename(&path, &aside)
                        .map(|()| format!("it was moved to {}", aside.display()))
                        .unwrap_or_else(|error| format!("moving it aside failed too ({error})"));
                    problems.push(format!(
                        "{} isn't settings ({error}), so the defaults are used; {moved}",
                        path.display()
                    ));
                    Settings::default()
                }
            },
            Err(error) if error.kind() == io::ErrorKind::NotFound => Settings::default(),
            Err(error) => {
                problems.push(format!(
                    "{} can't be read ({error}), so the defaults are used",
                    path.display()
                ));
                Settings::default()
            }
        };
        let overrides = match saved.changed(&overrides) {
            Ok(_) => overrides,
            Err(problem) => {
                problems.push(format!("the command line's settings weren't used: {problem}"));
                Map::new()
            }
        };
        (Self { path, saved, overrides }, problems)
    }

    /// The settings in effect: the file's, with the command line's on top.
    pub fn settings(&self) -> Settings {
        // Checked when the store opened, and the file's settings are always valid.
        self.saved
            .changed(&self.overrides)
            .unwrap_or_else(|_| self.saved.clone())
    }

    /// The keys the command line sets for this run.
    pub fn overridden(&self) -> Vec<String> {
        self.overrides.keys().cloned().collect()
    }

    /// Makes `changes` and saves them. A setting the command line set follows the change from
    /// now on. Nothing changes if any change is invalid or the file can't be written. Returns the
    /// settings now in effect.
    pub fn change(&mut self, changes: &Map<String, Value>) -> Result<Settings, String> {
        let settings = self.saved.changed(changes)?;
        save(&self.path, &settings).map_err(|error| format!("couldn't save {}: {error}", self.path.display()))?;
        self.saved = settings;
        self.overrides.retain(|key, _| !changes.contains_key(key));
        Ok(self.settings())
    }
}

fn save(path: &Path, settings: &Settings) -> io::Result<()> {
    let folder = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "the settings file has no folder"))?;
    create_private_folder(folder)?;
    let mut text = serde_json::to_string_pretty(settings).map_err(io::Error::other)?;
    text.push('\n');
    let temporary = path.with_extension("json.new");
    let mut file = private_file(&temporary)?;
    file.write_all(text.as_bytes())?;
    file.sync_all()?;
    drop(file);
    fs::rename(&temporary, path)
}

#[cfg(unix)]
fn create_private_folder(folder: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new().recursive(true).mode(0o700).create(folder)
}

#[cfg(not(unix))]
fn create_private_folder(folder: &Path) -> io::Result<()> {
    fs::create_dir_all(folder)
}

#[cfg(unix)]
fn private_file(path: &Path) -> io::Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
}

#[cfg(not(unix))]
fn private_file(path: &Path) -> io::Result<fs::File> {
    OpenOptions::new().write(true).create(true).truncate(true).open(path)
}

#[cfg(test)]
mod tests {
    use lt_shared::CleanupLevel;
    use serde_json::json;

    use super::*;

    struct Folder(PathBuf);

    impl Folder {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!("lt-settings-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&path);
            Self(path)
        }

        fn settings(&self) -> PathBuf {
            self.0.join("live-transcribe").join("settings.json")
        }
    }

    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn map(value: Value) -> Map<String, Value> {
        match value {
            Value::Object(map) => map,
            _ => panic!("an object"),
        }
    }

    #[test]
    fn no_file_is_the_defaults_and_a_change_makes_one() {
        let folder = Folder::new("first");
        let (mut store, problems) = SettingsStore::open(folder.settings(), Map::new());
        assert!(problems.is_empty());
        assert_eq!(store.settings(), Settings::default());
        assert!(!folder.settings().exists(), "reading writes nothing");

        let settings = store.change(&map(json!({"cleanupLevel": "high"}))).unwrap();
        assert_eq!(settings.cleanup_level, CleanupLevel::High);
        let (reopened, _) = SettingsStore::open(folder.settings(), Map::new());
        assert_eq!(reopened.settings().cleanup_level, CleanupLevel::High);
    }

    #[cfg(unix)]
    #[test]
    fn only_the_user_can_read_the_file() {
        use std::os::unix::fs::PermissionsExt;
        let folder = Folder::new("private");
        let (mut store, _) = SettingsStore::open(folder.settings(), Map::new());
        store.change(&map(json!({"handsFreeEnabled": false}))).unwrap();
        let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&folder.settings()), 0o600);
        assert_eq!(mode(folder.settings().parent().unwrap()), 0o700);
        assert!(!folder.settings().with_extension("json.new").exists());
    }

    #[test]
    fn an_invalid_change_saves_nothing() {
        let folder = Folder::new("invalid");
        let (mut store, _) = SettingsStore::open(folder.settings(), Map::new());
        store.change(&map(json!({"cleanupLevel": "light"}))).unwrap();
        let error = store
            .change(&map(json!({"cleanupLevel": "high", "dictationHotkey": "KEY_ESC"})))
            .unwrap_err();
        assert!(error.contains("Esc cancels dictation"), "{error}");
        assert_eq!(store.settings().cleanup_level, CleanupLevel::Light);
        let (reopened, _) = SettingsStore::open(folder.settings(), Map::new());
        assert_eq!(reopened.settings().cleanup_level, CleanupLevel::Light);
    }

    #[test]
    fn the_command_line_wins_for_the_run_until_the_setting_changes() {
        let folder = Folder::new("overrides");
        let (mut store, _) = SettingsStore::open(folder.settings(), Map::new());
        store.change(&map(json!({"dictationHotkey": "KEY_RIGHTALT"}))).unwrap();

        let overrides = map(json!({"dictationHotkey": "KEY_F23", "cleanupLevel": "none"}));
        let (mut store, problems) = SettingsStore::open(folder.settings(), overrides);
        assert!(problems.is_empty());
        assert_eq!(store.settings().dictation_hotkey, "KEY_F23");
        assert_eq!(store.overridden().len(), 2);

        // Another setting's change leaves the command line's alone and doesn't save them.
        store.change(&map(json!({"handsFreeEnabled": false}))).unwrap();
        assert_eq!(store.settings().dictation_hotkey, "KEY_F23");
        let (saved, _) = SettingsStore::open(folder.settings(), Map::new());
        assert_eq!(saved.settings().dictation_hotkey, "KEY_RIGHTALT");
        assert_eq!(saved.settings().cleanup_level, CleanupLevel::Medium);

        // Changing it in the app ends the command line's say.
        let settings = store.change(&map(json!({"cleanupLevel": "high"}))).unwrap();
        assert_eq!(settings.cleanup_level, CleanupLevel::High);
        assert_eq!(store.overridden(), ["dictationHotkey"]);
    }

    #[test]
    fn a_language_from_the_command_line_is_kept_by_its_code() {
        let folder = Folder::new("language");
        let (store, problems) = SettingsStore::open(folder.settings(), map(json!({"sttLanguage": "German"})));
        assert!(problems.is_empty(), "{problems:?}");
        assert_eq!(store.settings().stt_language.as_deref(), Some("de"));
    }

    #[test]
    fn invalid_command_line_settings_are_reported_and_left_out() {
        let folder = Folder::new("bad-overrides");
        let (store, problems) = SettingsStore::open(folder.settings(), map(json!({"dictationHotkey": "KEY_NOPE"})));
        assert_eq!(problems.len(), 1);
        assert!(problems[0].contains("KEY_NOPE"), "{problems:?}");
        assert_eq!(store.settings(), Settings::default());
        assert!(store.overridden().is_empty());
    }

    #[test]
    fn a_file_that_isnt_settings_is_moved_aside_not_lost() {
        let folder = Folder::new("unreadable");
        fs::create_dir_all(folder.settings().parent().unwrap()).unwrap();
        fs::write(folder.settings(), "{ not json").unwrap();
        let (store, problems) = SettingsStore::open(folder.settings(), Map::new());
        assert_eq!(store.settings(), Settings::default());
        assert_eq!(problems.len(), 1);
        assert!(!folder.settings().exists());
        assert_eq!(
            fs::read_to_string(folder.settings().with_extension("json.unreadable")).unwrap(),
            "{ not json"
        );
    }

    #[test]
    fn a_bad_value_in_the_file_is_reported_and_replaced_at_the_next_save() {
        let folder = Folder::new("bad-value");
        fs::create_dir_all(folder.settings().parent().unwrap()).unwrap();
        fs::write(
            folder.settings(),
            r#"{"cleanupLevel": "extreme", "handsFreeEnabled": false}"#,
        )
        .unwrap();
        let (mut store, problems) = SettingsStore::open(folder.settings(), Map::new());
        assert_eq!(problems.len(), 1, "{problems:?}");
        assert!(!store.settings().hands_free_enabled);
        store.change(&map(json!({"dictationEnabled": true}))).unwrap();
        let text = fs::read_to_string(folder.settings()).unwrap();
        assert!(text.contains(r#""cleanupLevel": "medium""#), "{text}");
    }
}
