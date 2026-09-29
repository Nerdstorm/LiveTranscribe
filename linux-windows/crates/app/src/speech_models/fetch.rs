//! Fetching one published file over HTTPS into a path: carrying on from what's there, and checking
//! what arrives against the file's published size and SHA-256.

use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use lt_transcription::catalog::sha256_of;
use reqwest::StatusCode;
use reqwest::blocking::Client;
use reqwest::header::{CONTENT_RANGE, RANGE};

/// How long a connection may take, and how long a read may wait for data, before the download
/// fails and says why.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const READ_TIMEOUT: Duration = Duration::from_secs(60);

/// How often progress is reported, at most.
const PROGRESS_INTERVAL: Duration = Duration::from_millis(250);

/// What a download is doing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Stage {
    Downloading,
    /// Unpacking the model's files from the archive downloaded.
    Unpacking,
    /// Checking each file against its SHA-256.
    Checking,
}

/// How far a download, or its unpacking or checking, has got, in bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Progress {
    pub(crate) stage: Stage,
    pub(crate) done: u64,
    pub(crate) total: u64,
}

impl Progress {
    /// Whole percent, rounded down as the Mac's menu bar does, so 100 means finished.
    pub(crate) fn percent(self) -> u8 {
        let percent = self.done.min(self.total) * 100 / self.total.max(1);
        u8::try_from(percent).unwrap_or(100)
    }
}

/// Why a download failed.
#[derive(Debug)]
pub(crate) enum DownloadError {
    /// The server couldn't be reached, or the connection broke.
    Network {
        file: String,
        source: Box<dyn std::error::Error + Send + Sync>,
    },
    /// The server (`host`) answered with something other than the file.
    Status {
        file: String,
        host: &'static str,
        status: StatusCode,
    },
    /// The file arrived, twice, with other contents than were published.
    Checksum { file: String },
    /// The archive downloaded can't be unpacked, or lacks a file the model has.
    Unpack { archive: String, problem: String },
    /// A file or folder on this computer couldn't be written.
    Disk { path: PathBuf, source: io::Error },
    /// The download was stopped: cancelled, or the app stopped wanting it.
    Stopped,
}

impl fmt::Display for DownloadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Network { file, source } => {
                write!(
                    f,
                    "couldn't download the speech model's {file}: {}",
                    full_chain(source.as_ref())
                )
            }
            Self::Status { file, host, status } => {
                write!(f, "{host} answered {status} for the speech model's {file}")
            }
            Self::Checksum { file } => write!(
                f,
                "the speech model's {file} downloaded twice with other contents than were published"
            ),
            Self::Unpack { archive, problem } => write!(f, "couldn't unpack {archive}: {problem}"),
            Self::Disk { path, source } => write!(f, "couldn't write {}: {source}", path.display()),
            Self::Stopped => f.write_str("the download was stopped"),
        }
    }
}

/// The message already says what caused the error, so it has no source: printed with its causes,
/// as `{:#}` prints an `anyhow::Error` in the tray and on the command line, it would say them twice.
impl std::error::Error for DownloadError {}

/// An error and what caused it, on one line: reqwest's own message says only which request failed.
fn full_chain(error: &dyn std::error::Error) -> String {
    let mut text = error.to_string();
    let mut source = error.source();
    while let Some(cause) = source {
        text.push_str(": ");
        text.push_str(&cause.to_string());
        source = cause.source();
    }
    text
}

pub(crate) fn disk(path: &Path, source: io::Error) -> DownloadError {
    DownloadError::Disk {
        path: path.to_owned(),
        source,
    }
}

/// A file as published: where, and what it must be.
pub(crate) struct Published<'a> {
    pub(crate) url: String,
    /// Its name, as errors say it.
    pub(crate) name: &'a str,
    /// Who publishes it, as errors say it ("Hugging Face").
    pub(crate) host: &'static str,
    pub(crate) bytes: u64,
    pub(crate) sha256: &'a str,
}

/// Counts bytes across files and tells the listener, every [`PROGRESS_INTERVAL`] at most.
pub(crate) struct Reporter<'a> {
    stage: Stage,
    /// The files finished so far, together.
    pub(crate) completed: u64,
    /// What there is of the file under way.
    pub(crate) current: u64,
    total: u64,
    last: Option<Instant>,
    listener: &'a mut dyn FnMut(Progress) -> bool,
}

impl<'a> Reporter<'a> {
    pub(crate) fn new(stage: Stage, total: u64, listener: &'a mut dyn FnMut(Progress) -> bool) -> Self {
        Self {
            stage,
            completed: 0,
            current: 0,
            total,
            last: None,
            listener,
        }
    }

    /// Tells the listener how far it has got, if it's time to (or `now`), and returns whether to
    /// carry on.
    pub(crate) fn report(&mut self, now: bool) -> bool {
        if !now && self.last.is_some_and(|last| last.elapsed() < PROGRESS_INTERVAL) {
            return true;
        }
        self.last = Some(Instant::now());
        (self.listener)(Progress {
            stage: self.stage,
            done: self.completed + self.current,
            total: self.total,
        })
    }
}

/// Downloads `file` into `path`, carrying on from what's there, and checks it. A file that comes
/// out with other contents than were published is downloaded once more from the start.
pub(crate) fn fetch_file(file: &Published<'_>, path: &Path, reporter: &mut Reporter<'_>) -> Result<(), DownloadError> {
    for attempt in 0..2 {
        let had = existing_length(path, file.bytes).map_err(|source| disk(path, source))?;
        reporter.current = had;
        if had < file.bytes {
            fetch_rest(file, path, had, reporter)?;
        }
        if sha256_of(path, &mut |_| {}).map_err(|source| disk(path, source))? == file.sha256 {
            reporter.completed += file.bytes;
            reporter.current = 0;
            return Ok(());
        }
        tracing::warn!(
            file = file.name,
            attempt,
            "A downloaded file isn't what was published; downloading it again"
        );
        fs::remove_file(path).map_err(|source| disk(path, source))?;
    }
    reporter.current = 0;
    Err(DownloadError::Checksum {
        file: file.name.to_owned(),
    })
}

/// How much of the file is there already, emptying one that's longer than it should be.
fn existing_length(path: &Path, size: u64) -> io::Result<u64> {
    match fs::metadata(path) {
        Ok(metadata) if metadata.len() <= size => Ok(metadata.len()),
        Ok(_) => {
            fs::remove_file(path)?;
            Ok(0)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(0),
        Err(error) => Err(error),
    }
}

/// Downloads the file from byte `from` to its end into `path`. A server that ignores the range
/// sends the whole file, which then replaces what was there. What arrived before the connection
/// broke stays, for the next try to carry on from.
fn fetch_rest(file: &Published<'_>, path: &Path, from: u64, reporter: &mut Reporter<'_>) -> Result<(), DownloadError> {
    let network = |source: Box<dyn std::error::Error + Send + Sync>| DownloadError::Network {
        file: file.name.to_owned(),
        source,
    };
    let mut request = client().map_err(|error| network(Box::new(error)))?.get(&file.url);
    if from > 0 {
        request = request.header(RANGE, format!("bytes={from}-"));
    }
    let mut response = request.send().map_err(|error| network(Box::new(error)))?;
    let resumed = response.status() == StatusCode::PARTIAL_CONTENT
        && response
            .headers()
            .get(CONTENT_RANGE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|range| range.starts_with(&format!("bytes {from}-")));
    if !resumed && response.status() != StatusCode::OK {
        return Err(DownloadError::Status {
            file: file.name.to_owned(),
            host: file.host,
            status: response.status(),
        });
    }
    let (output, mut written) = if resumed {
        (OpenOptions::new().append(true).open(path), from)
    } else {
        (File::create(path), 0)
    };
    let mut output = output.map_err(|source| disk(path, source))?;
    reporter.current = written;
    let mut buffer = vec![0; 64 * 1024];
    while written <= file.bytes {
        let read = match response.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => {
                output.flush().map_err(|source| disk(path, source))?;
                return Err(network(match error.into_inner() {
                    Some(inner) => inner,
                    None => "the connection broke".into(),
                }));
            }
        };
        output.write_all(&buffer[..read]).map_err(|source| disk(path, source))?;
        written += read as u64;
        reporter.current = written;
        if !reporter.report(false) {
            output.flush().map_err(|source| disk(path, source))?;
            return Err(DownloadError::Stopped);
        }
    }
    output.flush().map_err(|source| disk(path, source))?;
    if written < file.bytes {
        return Err(network("the download ended before the file did".into()));
    }
    Ok(())
}

/// One HTTP client for the process, which keeps its connections. It checks them with the system's
/// CA certificates, and can't be made without any, as in a container without the ca-certificates
/// package: then each download fails with why, and the next try makes it anew.
fn client() -> Result<&'static Client, reqwest::Error> {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    if let Some(client) = CLIENT.get() {
        return Ok(client);
    }
    // reqwest takes rustls's process-wide cryptography, which is ring here.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = Client::builder()
        .user_agent(concat!("livetranscribe/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(CONNECT_TIMEOUT)
        // For a blocking client, this bounds each read of the body, not the whole download.
        .timeout(READ_TIMEOUT)
        .build()?;
    Ok(CLIENT.get_or_init(|| client))
}
