//! One Live Transcribe at a time: two would both hear the hotkey and type everything twice, and
//! only one can be the input method.

use std::fs::{File, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};

use anyhow::{Context, bail};

const LOCK_FILE: &str = "live-transcribe.lock";

/// Held until the app quits; the lock goes with the process however it ends.
pub(crate) struct InstanceLock {
    _held: File,
}

/// Takes the lock, one per user.
pub(crate) fn acquire() -> anyhow::Result<InstanceLock> {
    acquire_at(&lock_path()?)
}

/// In the session's runtime folder, where the desktop's other apps look too.
#[cfg(not(windows))]
fn lock_path() -> anyhow::Result<PathBuf> {
    let folder = dirs::runtime_dir()
        .or_else(dirs::cache_dir)
        .context("neither XDG_RUNTIME_DIR nor a cache folder is set")?;
    Ok(folder.join(LOCK_FILE))
}

/// In the app's folder in the user's local app data.
#[cfg(windows)]
fn lock_path() -> anyhow::Result<PathBuf> {
    let folder = dirs::data_local_dir()
        .context("the local app data folder is unknown")?
        .join("live-transcribe");
    std::fs::create_dir_all(&folder).with_context(|| format!("couldn't make {}", folder.display()))?;
    Ok(folder.join(LOCK_FILE))
}

fn acquire_at(path: &Path) -> anyhow::Result<InstanceLock> {
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path)
        .with_context(|| format!("couldn't open {}", path.display()))?;
    match file.try_lock() {
        Ok(()) => Ok(InstanceLock { _held: file }),
        Err(TryLockError::WouldBlock) => {
            bail!("Live Transcribe is already running; quit it from its tray menu first")
        }
        Err(TryLockError::Error(error)) => Err(error).with_context(|| format!("couldn't lock {}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_second_instance_is_turned_away_until_the_first_quits() {
        let folder = std::env::temp_dir().join(format!("live-transcribe-lock-test-{}", std::process::id()));
        std::fs::create_dir_all(&folder).expect("a folder");
        let path = folder.join(LOCK_FILE);
        let first = acquire_at(&path).expect("the first takes the lock");
        let second = acquire_at(&path).err().expect("the second is refused");
        assert!(second.to_string().contains("already running"));
        drop(first);
        assert!(acquire_at(&path).is_ok(), "free again once the first has gone");
        let _ = std::fs::remove_dir_all(folder);
    }
}
