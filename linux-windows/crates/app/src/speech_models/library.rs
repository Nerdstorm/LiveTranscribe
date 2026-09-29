//! The catalog's models on this computer, as the Mac app's SpeechModelLibrary: which are
//! downloaded, and downloading or removing one, for Settings › Models and for dictation. The app
//! has one, so a download carries on when Settings closes, and dictation waits for the download
//! Settings shows rather than starting another.

use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

use lt_transcription::catalog::{SpeechModel, SpeechModelCatalog, VerifiedModel, VerifyError};

use super::downloads::SpeechModelDownloads;
use super::fetch::{DownloadError, Progress, Stage};

/// How long a wait for a download goes without saying how far it has got.
const WAIT_INTERVAL: Duration = Duration::from_millis(250);

/// A model's download, as Settings shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum DownloadState {
    NotDownloaded,
    Downloading(Progress),
    Downloaded,
    /// The last download failed, and why.
    Failed(String),
}

/// Hears each change to a model's download.
type Listener = Box<dyn Fn(&SpeechModel, &DownloadState) + Send>;

pub(crate) struct SpeechModelLibrary {
    catalog: &'static SpeechModelCatalog,
    downloads: SpeechModelDownloads,
    /// Each model's download under way, or how its last one ended.
    tasks: Mutex<HashMap<String, Task>>,
    /// Told whenever a task moves on.
    changed: Condvar,
    listeners: Mutex<Vec<Listener>>,
}

struct Task {
    /// Tells a download from the one before it.
    number: u64,
    progress: Progress,
    stop: Arc<AtomicBool>,
    /// How it ended; `None` while it runs.
    outcome: Option<Outcome>,
}

#[derive(Clone, Debug)]
enum Outcome {
    Downloaded,
    Stopped,
    Failed(String),
}

/// Why [`SpeechModelLibrary::ensure`] has no model to give.
#[derive(Debug)]
pub(crate) enum EnsureError {
    /// Whoever waited stopped wanting it; the download carries on.
    Abandoned,
    /// The download was cancelled, or failed.
    Download(String),
    /// The model's files aren't as published, even just downloaded.
    Verify(VerifyError),
}

impl fmt::Display for EnsureError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Abandoned => f.write_str("the speech model is no longer wanted"),
            Self::Download(problem) => f.write_str(problem),
            Self::Verify(error) => write!(f, "the speech model's files aren't as published: {error}"),
        }
    }
}

impl std::error::Error for EnsureError {}

impl SpeechModelLibrary {
    pub(crate) fn new(catalog: &'static SpeechModelCatalog, downloads: SpeechModelDownloads) -> Arc<Self> {
        Arc::new(Self {
            catalog,
            downloads,
            tasks: Mutex::new(HashMap::new()),
            changed: Condvar::new(),
            listeners: Mutex::new(Vec::new()),
        })
    }

    pub(crate) fn catalog(&self) -> &'static SpeechModelCatalog {
        self.catalog
    }

    pub(crate) fn downloads(&self) -> &SpeechModelDownloads {
        &self.downloads
    }

    /// Tells `listener` of every change to a download from now on: its progress, a quarter second
    /// apart at most, and how it ends.
    pub(crate) fn subscribe(&self, listener: impl Fn(&SpeechModel, &DownloadState) + Send + 'static) {
        lock(&self.listeners).push(Box::new(listener));
    }

    pub(crate) fn state(&self, model: &SpeechModel) -> DownloadState {
        let tasks = lock(&self.tasks);
        match tasks.get(&model.id) {
            Some(task) if task.outcome.is_none() => DownloadState::Downloading(task.progress),
            Some(Task {
                outcome: Some(Outcome::Failed(problem)),
                ..
            }) if !self.downloads.is_downloaded(model) => DownloadState::Failed(problem.clone()),
            _ if self.downloads.is_downloaded(model) => DownloadState::Downloaded,
            _ => DownloadState::NotDownloaded,
        }
    }

    /// Whether any of the model's files are here, whole or partly downloaded, and not downloading.
    pub(crate) fn can_remove(&self, model: &SpeechModel) -> bool {
        !self.is_downloading(model) && self.downloads.has_files(model)
    }

    fn is_downloading(&self, model: &SpeechModel) -> bool {
        lock(&self.tasks)
            .get(&model.id)
            .is_some_and(|task| task.outcome.is_none())
    }

    /// Downloads `model` and checks it, on a thread of its own, unless it's downloading already.
    pub(crate) fn download(self: &Arc<Self>, model: &'static SpeechModel) {
        let (number, stop) = {
            let mut tasks = lock(&self.tasks);
            let previous = tasks.get(&model.id);
            if previous.is_some_and(|task| task.outcome.is_none()) {
                return;
            }
            let number = previous.map_or(1, |task| task.number + 1);
            let stop = Arc::new(AtomicBool::new(false));
            tasks.insert(
                model.id.clone(),
                Task {
                    number,
                    progress: Progress {
                        stage: Stage::Downloading,
                        done: 0,
                        total: model.download_bytes(),
                    },
                    stop: Arc::clone(&stop),
                    outcome: None,
                },
            );
            (number, stop)
        };
        self.tell(model);
        let library = Arc::clone(self);
        let spawned = thread::Builder::new()
            .name(format!("download {}", model.id))
            .spawn(move || library.run(model, number, &stop));
        if let Err(error) = spawned {
            self.finish(
                model,
                number,
                Outcome::Failed(format!("couldn't start the download: {error}")),
            );
        }
    }

    fn run(&self, model: &'static SpeechModel, number: u64, stop: &AtomicBool) {
        eprintln!(
            "Downloading the speech model {} ({:.1} GB) from {} into {}",
            model.name,
            model.download_bytes() as f64 / 1e9,
            model.source(),
            self.downloads.folder_of(model).display()
        );
        let started = Instant::now();
        let downloaded = self.downloads.download(model, &mut |progress| {
            self.progressed(model, number, progress);
            !stop.load(Ordering::Relaxed)
        });
        let outcome = match downloaded {
            Ok(()) => match self
                .downloads
                .verify(model, &mut |progress| self.progressed(model, number, progress))
            {
                Ok(_) => {
                    eprintln!("Downloaded {} in {:.0} s", model.name, started.elapsed().as_secs_f32());
                    Outcome::Downloaded
                }
                Err(error) => Outcome::Failed(format!("the downloaded files aren't as published: {error}")),
            },
            Err(DownloadError::Stopped) => {
                eprintln!(
                    "Stopped downloading {}; what was downloaded stays for the next try",
                    model.name
                );
                Outcome::Stopped
            }
            Err(error) => Outcome::Failed(error.to_string()),
        };
        if let Outcome::Failed(problem) = &outcome {
            eprintln!("livetranscribe: couldn't download {}: {problem}", model.name);
        }
        self.finish(model, number, outcome);
    }

    fn progressed(&self, model: &SpeechModel, number: u64, progress: Progress) {
        if let Some(task) = lock(&self.tasks).get_mut(&model.id)
            && task.number == number
        {
            task.progress = progress;
        }
        self.changed.notify_all();
        self.tell(model);
    }

    fn finish(&self, model: &SpeechModel, number: u64, outcome: Outcome) {
        if let Some(task) = lock(&self.tasks).get_mut(&model.id)
            && task.number == number
        {
            task.outcome = Some(outcome);
        }
        self.changed.notify_all();
        self.tell(model);
    }

    /// Stops `model`'s download, if it's downloading; what was downloaded stays for the next try.
    pub(crate) fn cancel(&self, model: &SpeechModel) {
        if let Some(task) = lock(&self.tasks).get(&model.id)
            && task.outcome.is_none()
        {
            task.stop.store(true, Ordering::Relaxed);
        }
    }

    /// Removes the model's files. Settings keeps the model in use from being removed.
    pub(crate) fn remove(&self, model: &SpeechModel) -> Result<(), String> {
        let result = {
            let mut tasks = lock(&self.tasks);
            if tasks.get(&model.id).is_some_and(|task| task.outcome.is_none()) {
                return Err(format!("{} is downloading: cancel the download first", model.name));
            }
            tasks.remove(&model.id);
            self.downloads
                .remove(model)
                .map_err(|error| format!("{} couldn't be removed: {error}", model.name))
        };
        self.tell(model);
        result
    }

    /// The model, checked, once it's downloaded: now, or after the download under way or one this
    /// starts, which Settings shows too. `progress` hears how far the download, or the check, has
    /// got, and returns false to stop waiting; the download carries on.
    pub(crate) fn ensure(
        self: &Arc<Self>,
        model: &'static SpeechModel,
        progress: &mut dyn FnMut(Progress) -> bool,
    ) -> Result<VerifiedModel<'static>, EnsureError> {
        if !self.is_downloading(model) && self.downloads.is_downloaded(model) {
            match self.downloads.verify(model, &mut |checked| {
                progress(checked);
            }) {
                Ok(verified) => return Ok(verified),
                Err(error) => eprintln!(
                    "⚠ {} isn't as published ({error}), so it is downloaded again",
                    model.name
                ),
            }
        }
        self.download(model);
        let mut tasks = lock(&self.tasks);
        loop {
            let Some(task) = tasks.get(&model.id) else {
                return Err(EnsureError::Download("the speech model was removed".to_owned()));
            };
            match task.outcome.clone() {
                Some(Outcome::Downloaded) => break,
                Some(Outcome::Stopped) => return Err(EnsureError::Download("the download was cancelled".to_owned())),
                Some(Outcome::Failed(problem)) => return Err(EnsureError::Download(problem)),
                None => {
                    let current = task.progress;
                    drop(tasks);
                    if !progress(current) {
                        return Err(EnsureError::Abandoned);
                    }
                    tasks = lock(&self.tasks);
                    tasks = self
                        .changed
                        .wait_timeout(tasks, WAIT_INTERVAL)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0;
                }
            }
        }
        drop(tasks);
        // Checked as it downloaded; this reads what that check remembered.
        self.downloads
            .verify(model, &mut |checked| {
                progress(checked);
            })
            .map_err(EnsureError::Verify)
    }

    /// Tells the listeners how `model`'s download stands.
    fn tell(&self, model: &SpeechModel) {
        let state = self.state(model);
        for listener in lock(&self.listeners).iter() {
            listener(model, &state);
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::super::downloads::tests::{Server, hugging_face_model, scratch};
    use super::*;

    const WEIGHTS: &[u8] = &[7; 300_000];
    const MANIFEST: &[u8] = br#"{"format": 2}"#;

    /// A library downloading into `root` from `server`. Its catalog is empty: the tests hand it
    /// the models.
    fn library(root: &std::path::Path, server: &Server) -> Arc<SpeechModelLibrary> {
        static EMPTY: std::sync::OnceLock<SpeechModelCatalog> = std::sync::OnceLock::new();
        SpeechModelLibrary::new(
            EMPTY.get_or_init(SpeechModelCatalog::default),
            SpeechModelDownloads::with_hugging_face(root.to_owned(), &server.base),
        )
    }

    /// Waits for `model`'s download to end, and returns how it stands then.
    fn settled(library: &SpeechModelLibrary, model: &SpeechModel) -> DownloadState {
        let deadline = Instant::now() + Duration::from_secs(20);
        while library.is_downloading(model) {
            assert!(Instant::now() < deadline, "the download never ended");
            thread::sleep(Duration::from_millis(10));
        }
        library.state(model)
    }

    #[test]
    fn a_download_is_told_to_listeners_and_ends_downloaded() {
        let (model, published) = hugging_face_model(WEIGHTS, MANIFEST);
        let server = Server::start(published, true);
        let root = scratch("library-download");
        let library = library(&root, &server);
        let heard = Arc::new(Mutex::new(Vec::new()));
        let hearing = Arc::clone(&heard);
        library.subscribe(move |_, state| lock(&hearing).push(state.clone()));
        assert_eq!(library.state(model), DownloadState::NotDownloaded);

        library.download(model);
        assert_eq!(settled(&library, model), DownloadState::Downloaded);
        let heard = lock(&heard);
        assert!(
            matches!(heard.first(), Some(DownloadState::Downloading(_))),
            "{heard:?}"
        );
        assert_eq!(heard.last(), Some(&DownloadState::Downloaded));
        assert!(
            root.join("the-model")
                .join(lt_transcription::catalog::VERIFIED_FILE)
                .is_file(),
            "checked once in"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn ensure_downloads_a_model_and_gives_it_checked() {
        let (model, published) = hugging_face_model(WEIGHTS, MANIFEST);
        let server = Server::start(published, true);
        let root = scratch("library-ensure");
        let library = library(&root, &server);
        let mut stages = Vec::new();
        let verified = library
            .ensure(model, &mut |progress| {
                stages.push(progress.stage);
                true
            })
            .unwrap();
        assert_eq!(verified.folder(), root.join("the-model"));
        assert!(stages.contains(&Stage::Downloading), "{stages:?}");

        // Downloaded, it's only checked: no request goes out.
        let asked = server.requests().len();
        library.ensure(model, &mut |_| true).unwrap();
        assert_eq!(server.requests().len(), asked);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn ensure_waits_for_the_download_under_way_and_can_stop_waiting() {
        let (model, published) = hugging_face_model(WEIGHTS, MANIFEST);
        let server = Server::slow(published, Duration::from_millis(20));
        let root = scratch("library-join");
        let library = library(&root, &server);
        library.download(model);
        let error = library.ensure(model, &mut |_| false).unwrap_err();
        assert!(matches!(error, EnsureError::Abandoned), "{error}");
        assert!(library.is_downloading(model), "the download carries on");

        library.ensure(model, &mut |_| true).unwrap();
        assert_eq!(library.state(model), DownloadState::Downloaded);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_cancelled_download_ends_not_downloaded_and_can_be_removed() {
        let (model, published) = hugging_face_model(WEIGHTS, MANIFEST);
        let server = Server::slow(published, Duration::from_millis(20));
        let root = scratch("library-cancel");
        let library = library(&root, &server);
        library.download(model);
        assert!(library.remove(model).is_err(), "not while it downloads");
        assert!(!library.can_remove(model));
        library.cancel(model);
        assert_eq!(settled(&library, model), DownloadState::NotDownloaded);
        assert!(library.can_remove(model), "what was downloaded stays");
        library.remove(model).unwrap();
        assert!(!library.can_remove(model));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_failed_download_says_why_until_it_is_tried_again() {
        let (model, mut published) = hugging_face_model(WEIGHTS, MANIFEST);
        published.remove("manifest.json");
        let server = Server::start(published, true);
        let root = scratch("library-fail");
        let library = library(&root, &server);
        let error = library.ensure(model, &mut |_| true).unwrap_err();
        assert_eq!(
            error.to_string(),
            "Hugging Face answered 404 Not Found for the speech model's manifest.json"
        );
        let DownloadState::Failed(problem) = library.state(model) else {
            panic!("failed");
        };
        assert!(problem.contains("404"), "{problem}");
        let _ = fs::remove_dir_all(root);
    }
}
