//! The settings while the app runs. The tray and the Settings window change them here; each
//! change is saved, then told to whoever listens (dictation, the window), in the order the
//! changes were made.

use std::sync::{Mutex, MutexGuard, PoisonError};

use serde_json::{Map, Value};

use super::model::Settings;
use super::store::SettingsStore;

/// Hears each change: the settings now in effect, and the keys the command line still sets.
type Listener = Box<dyn Fn(&Settings, &[String]) + Send>;

pub(crate) struct SettingsService {
    store: Mutex<SettingsStore>,
    listeners: Mutex<Vec<Listener>>,
}

impl SettingsService {
    pub(crate) fn new(store: SettingsStore) -> Self {
        Self {
            store: Mutex::new(store),
            listeners: Mutex::new(Vec::new()),
        }
    }

    /// Tells `listener` every change from now on. It runs while the change is being made, so it
    /// must not change settings itself.
    pub(crate) fn subscribe(&self, listener: impl Fn(&Settings, &[String]) + Send + 'static) {
        lock(&self.listeners).push(Box::new(listener));
    }

    /// The settings in effect, and the keys the command line sets for this run.
    pub(crate) fn current(&self) -> (Settings, Vec<String>) {
        let store = lock(&self.store);
        (store.settings(), store.overridden())
    }

    /// Makes `changes`, saves them and tells the listeners; nothing changes if one is invalid.
    pub(crate) fn change(&self, changes: &Map<String, Value>) -> Result<Settings, String> {
        // The store stays locked while the listeners hear, so they hear changes in order.
        let mut store = lock(&self.store);
        let settings = store.change(changes)?;
        let overridden = store.overridden();
        for listener in lock(&self.listeners).iter() {
            listener(&settings, &overridden);
        }
        Ok(settings)
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use serde_json::json;

    use super::*;

    #[test]
    fn listeners_hear_each_saved_change_and_nothing_refused() {
        let folder = std::env::temp_dir().join(format!("lt-settings-service-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        let (store, _) = SettingsStore::open(folder.join("settings.json"), Map::new());
        let service = SettingsService::new(store);
        let heard = Arc::new(Mutex::new(Vec::new()));
        let hearing = Arc::clone(&heard);
        service.subscribe(move |settings, _| lock(&hearing).push(settings.cleanup_level.as_str()));

        let change = |value: Value| match value {
            Value::Object(map) => map,
            _ => unreachable!(),
        };
        service.change(&change(json!({"cleanupLevel": "high"}))).unwrap();
        assert!(service.change(&change(json!({"cleanupLevel": "loud"}))).is_err());
        service.change(&change(json!({"cleanupLevel": "none"}))).unwrap();
        assert_eq!(*lock(&heard), ["high", "none"]);
        assert_eq!(service.current().0.cleanup_level.as_str(), "none");
        let _ = std::fs::remove_dir_all(folder);
    }
}
