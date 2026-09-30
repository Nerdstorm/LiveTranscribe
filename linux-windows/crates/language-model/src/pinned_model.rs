//! The cleanup model the Linux and Windows app downloads, pinned: a Hugging Face repository at one
//! commit, and each file the runtime reads with its size and SHA-256.
//!
//! [`prepare`] is the one call the app makes: it checks the model's folder in the models folder and
//! downloads what's missing or damaged, as the speech models are downloaded
//! (`crates/app/src/speech_models/`): into a hidden folder beside the others, carrying on where a
//! stopped download stopped, each file checked against its SHA-256 as it arrives, and moved into
//! place only when every file matches. A check that passed is remembered in the folder
//! (`.verified.json`, with each file's size and modification time), so the next start hashes only
//! the files that changed since, and doesn't go online.

use std::collections::BTreeMap;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, Instant, UNIX_EPOCH};

use reqwest::StatusCode;
use reqwest::blocking::Client;
use reqwest::header::{CONTENT_RANGE, RANGE};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// A model's files, as published at one commit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PinnedModel {
    /// Its folder's name in the models folder.
    pub id: &'static str,
    /// The Hugging Face repository.
    pub repository: &'static str,
    /// The commit its files are taken from.
    pub revision: &'static str,
    pub files: &'static [PinnedFile],
}

/// One file of a model.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PinnedFile {
    pub name: &'static str,
    pub bytes: u64,
    pub sha256: &'static str,
}

/// The cleanup model: the Mac app's own Qwen3-1.7B weights (mlx-community/Qwen3-1.7B-4bit at
/// 3b1b176) in OpenVINO's graph for it, with each adapter's matrices as inputs of the model, as
/// `tools/export-qwen3-cleanup.py` converts them, and the files the runtime reads (not its
/// `config.json`, `export.json` or model card). The tokenizer's files are OpenVINO's own
/// conversion's, byte for byte. Apache-2.0, as Qwen3 is.
pub const CLEANUP_MODEL: PinnedModel = PinnedModel {
    id: "qwen3-1.7b-mlx-4bit-ov",
    repository: "Nerdstorm/Qwen3-1.7B-MLX-4bit-OpenVINO",
    revision: "1d7c4b40b288b628596f82242557f9f4958c5594",
    files: &[
        PinnedFile {
            name: "generation_config.json",
            bytes: 214,
            sha256: "81051cd3f6e77013827148d0b8a6ead93f8ac390d5ab805f849199f0af6a08db",
        },
        PinnedFile {
            name: "merges.txt",
            bytes: 1_671_853,
            sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
        },
        PinnedFile {
            name: "tokenizer_config.json",
            bytes: 9_706,
            sha256: "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0",
        },
        PinnedFile {
            name: "vocab.json",
            bytes: 2_776_833,
            sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
        },
        PinnedFile {
            name: "openvino_model.xml",
            bytes: 3_202_689,
            sha256: "012c5db186aa5a8a7d9e64c2e2a82dbea2cda6b90e37fd622f918c1017575c0e",
        },
        PinnedFile {
            name: "openvino_model.bin",
            bytes: 927_926_884,
            sha256: "5efcd749922add16446b857106ff32e59ce7753f5a8985bc1699375a402ae767",
        },
    ],
};

/// Where Hugging Face serves a repository's files.
const HUGGING_FACE: &str = "https://huggingface.co";

/// Where a folder remembers that its files were checked. A dot file, which no model's file can
/// be named; the speech models' folders use the same name and format.
pub const VERIFIED_FILE: &str = ".verified.json";

/// How long a connection may take, and how long a read may wait for data.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const READ_TIMEOUT: Duration = Duration::from_secs(60);

/// How often progress is reported, at most.
const PROGRESS_INTERVAL: Duration = Duration::from_millis(250);

/// What [`prepare`] is doing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    /// Checking the files in place against their SHA-256s.
    Checking,
    Downloading,
}

/// How far a stage has got, in bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Progress {
    pub stage: Stage,
    pub done: u64,
    pub total: u64,
}

/// Why [`prepare`] failed.
#[derive(Debug)]
pub enum PrepareError {
    /// The server couldn't be reached, or the connection broke.
    Network {
        file: String,
        source: Box<dyn std::error::Error + Send + Sync>,
    },
    /// Hugging Face answered with something other than the file.
    Status { file: String, status: StatusCode },
    /// The file arrived, twice, with other contents than were published.
    Checksum { file: String },
    /// A file or folder on this computer couldn't be read or written.
    Disk { path: PathBuf, source: io::Error },
    /// The listener asked for it to stop; what was downloaded stays for the next try.
    Stopped,
}

impl fmt::Display for PrepareError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Network { file, source } => {
                write!(f, "couldn't download the cleanup model's {file}: {source}")?;
                let mut cause = source.source();
                while let Some(error) = cause {
                    write!(f, ": {error}")?;
                    cause = error.source();
                }
                Ok(())
            }
            Self::Status { file, status } => {
                write!(f, "Hugging Face answered {status} for the cleanup model's {file}")
            }
            Self::Checksum { file } => write!(
                f,
                "the cleanup model's {file} downloaded twice with other contents than were published"
            ),
            Self::Disk { path, source } => write!(f, "couldn't write {}: {source}", path.display()),
            Self::Stopped => f.write_str("the download was stopped"),
        }
    }
}

/// The message says what caused the error, so it has no source.
impl std::error::Error for PrepareError {}

impl PinnedModel {
    /// Where the model is kept in `models_folder`.
    pub fn folder_in(&self, models_folder: &Path) -> PathBuf {
        models_folder.join(self.id)
    }

    /// How much its files take.
    pub fn bytes(&self) -> u64 {
        self.files.iter().map(|file| file.bytes).sum()
    }

    /// Whether its folder in `models_folder` looks complete: each file there, at its size. Quick,
    /// for a settings screen; [`prepare`] checks the contents.
    pub fn is_in(&self, models_folder: &Path) -> bool {
        let folder = self.folder_in(models_folder);
        self.files.iter().all(|file| {
            fs::metadata(folder.join(file.name))
                .is_ok_and(|metadata| metadata.is_file() && metadata.len() == file.bytes)
        })
    }
}

/// Makes `model`'s folder in `models_folder` hold its files as published, and returns the folder:
/// checks the files there (hashing only those changed since the last check), and downloads any
/// that are missing or damaged. `progress` hears how far it has got, every quarter second at most,
/// and returns false to stop.
pub fn prepare(
    model: &PinnedModel,
    models_folder: &Path,
    progress: &mut dyn FnMut(Progress) -> bool,
) -> Result<PathBuf, PrepareError> {
    prepare_from(HUGGING_FACE, model, models_folder, progress)
}

/// [`prepare`], from `host` rather than Hugging Face: a test's server.
fn prepare_from(
    host: &str,
    model: &PinnedModel,
    models_folder: &Path,
    progress: &mut dyn FnMut(Progress) -> bool,
) -> Result<PathBuf, PrepareError> {
    let folder = model.folder_in(models_folder);
    match verify(model, &folder, progress) {
        Ok(()) => return Ok(folder),
        Err(Unverified::Stopped) => return Err(PrepareError::Stopped),
        Err(Unverified::Mismatch(reason)) if folder.exists() => {
            tracing::warn!(
                model = model.id,
                "The cleanup model's folder isn't as published ({reason}); downloading"
            );
        }
        Err(Unverified::Mismatch(_)) => tracing::info!(model = model.id, "Downloading the cleanup model"),
    }
    download(host, model, models_folder, progress)?;
    Ok(folder)
}

/// Why a folder didn't pass [`verify`].
enum Unverified {
    /// A file is missing, or isn't as published: what's wrong.
    Mismatch(String),
    Stopped,
}

/// Checks each file in `folder`: its size, and its SHA-256 unless the folder remembers checking
/// it at this size and modification time.
fn verify(model: &PinnedModel, folder: &Path, progress: &mut dyn FnMut(Progress) -> bool) -> Result<(), Unverified> {
    let stamp_path = folder.join(VERIFIED_FILE);
    let stamp = Stamp::read(&stamp_path);
    let mut checked = Stamp::default();
    let mut unchecked = Vec::new();
    for file in model.files {
        let path = folder.join(file.name);
        let metadata = fs::metadata(&path).map_err(|error| Unverified::Mismatch(format!("{}: {error}", file.name)))?;
        if metadata.len() != file.bytes {
            return Err(Unverified::Mismatch(format!(
                "{} has {} bytes where {} were published",
                file.name,
                metadata.len(),
                file.bytes
            )));
        }
        let seen = StampedFile::of(file, &metadata);
        if stamp.files.get(file.name) == Some(&seen) {
            checked.files.insert(file.name.to_owned(), seen);
        } else {
            unchecked.push((file, path, seen));
        }
    }
    if unchecked.is_empty() {
        return Ok(());
    }
    let started = Instant::now();
    let total = unchecked.iter().map(|(file, ..)| file.bytes).sum();
    let mut reporter = Reporter::new(Stage::Checking, total, progress);
    for (file, path, seen) in unchecked {
        let sha256 = sha256_of(&path, &mut |read| {
            reporter.current += read;
            reporter.report(false)
        })
        .map_err(|error| match error.kind() {
            io::ErrorKind::Interrupted => Unverified::Stopped,
            _ => Unverified::Mismatch(format!("{}: {error}", file.name)),
        })?;
        if sha256 != file.sha256 {
            return Err(Unverified::Mismatch(format!("{} isn't what was published", file.name)));
        }
        checked.files.insert(file.name.to_owned(), seen);
    }
    reporter.report(true);
    tracing::info!(
        model = model.id,
        "Checked the cleanup model's files in {:.1} s",
        started.elapsed().as_secs_f32()
    );
    // Unremembered, the check is only made again next time.
    if let Err(error) = checked.write(&stamp_path) {
        tracing::warn!("Couldn't remember that {} was checked: {error}", folder.display());
    }
    Ok(())
}

/// Downloads `model` into its folder, through the hidden folder beside it. A folder already there
/// (a damaged one, or an earlier pin's) is where the download carries on from: a file in it that's
/// as published isn't fetched again.
fn download(
    host: &str,
    model: &PinnedModel,
    models_folder: &Path,
    progress: &mut dyn FnMut(Progress) -> bool,
) -> Result<(), PrepareError> {
    let folder = model.folder_in(models_folder);
    let staging = models_folder.join(format!(".{}.download", model.id));
    if folder.exists() {
        if staging.exists() {
            fs::remove_dir_all(&folder).map_err(|source| disk(&folder, source))?;
        } else {
            fs::rename(&folder, &staging).map_err(|source| disk(&folder, source))?;
        }
    }
    fs::create_dir_all(&staging).map_err(|source| disk(&staging, source))?;
    let mut reporter = Reporter::new(Stage::Downloading, model.bytes(), progress);
    let mut stamp = Stamp::default();
    for file in model.files {
        let url = format!("{host}/{}/resolve/{}/{}", model.repository, model.revision, file.name);
        let path = staging.join(file.name);
        // A file may sit in a subfolder of the repository (adapters/medium/…).
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|source| disk(parent, source))?;
        }
        fetch_file(&url, file, &path, &mut reporter)?;
        let metadata = fs::metadata(&path).map_err(|source| disk(&path, source))?;
        stamp
            .files
            .insert(file.name.to_owned(), StampedFile::of(file, &metadata));
    }
    reporter.report(true);
    // Every file was checked as it arrived; the stamp spares the next start hashing them again.
    let stamp_path = staging.join(VERIFIED_FILE);
    stamp.write(&stamp_path).map_err(|source| disk(&stamp_path, source))?;
    fs::rename(&staging, &folder).map_err(|source| disk(&folder, source))?;
    tracing::info!(model = model.id, "Downloaded the cleanup model");
    Ok(())
}

/// Downloads `file` from `url` into `path`, carrying on from what's there, and checks it. A file
/// that comes out with other contents than were published is downloaded once more from the start.
fn fetch_file(url: &str, file: &PinnedFile, path: &Path, reporter: &mut Reporter<'_>) -> Result<(), PrepareError> {
    for attempt in 0..2 {
        let had = existing_length(path, file.bytes).map_err(|source| disk(path, source))?;
        reporter.current = had;
        if had < file.bytes {
            fetch_rest(url, file, path, had, reporter)?;
        }
        if sha256_of(path, &mut |_| true).map_err(|source| disk(path, source))? == file.sha256 {
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
    Err(PrepareError::Checksum {
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
fn fetch_rest(
    url: &str,
    file: &PinnedFile,
    path: &Path,
    from: u64,
    reporter: &mut Reporter<'_>,
) -> Result<(), PrepareError> {
    let network = |source: Box<dyn std::error::Error + Send + Sync>| PrepareError::Network {
        file: file.name.to_owned(),
        source,
    };
    let mut request = client().map_err(|error| network(Box::new(error)))?.get(url);
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
        return Err(PrepareError::Status {
            file: file.name.to_owned(),
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
                return Err(network(Box::new(error)));
            }
        };
        output.write_all(&buffer[..read]).map_err(|source| disk(path, source))?;
        written += read as u64;
        reporter.current = written;
        if !reporter.report(false) {
            output.flush().map_err(|source| disk(path, source))?;
            return Err(PrepareError::Stopped);
        }
    }
    output.flush().map_err(|source| disk(path, source))?;
    if written < file.bytes {
        return Err(network("the download ended before the file did".into()));
    }
    Ok(())
}

/// One HTTP client for the process, which keeps its connections, checking them with the system's
/// CA certificates.
fn client() -> Result<&'static Client, reqwest::Error> {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    if let Some(client) = CLIENT.get() {
        return Ok(client);
    }
    // reqwest takes rustls's process-wide cryptography, which is ring here, as the app's is.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = Client::builder()
        .user_agent(concat!("livetranscribe/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(CONNECT_TIMEOUT)
        // For a blocking client, this bounds each read of the body, not the whole download.
        .timeout(READ_TIMEOUT)
        .build()?;
    Ok(CLIENT.get_or_init(|| client))
}

/// Counts bytes across files and tells the listener, every [`PROGRESS_INTERVAL`] at most.
struct Reporter<'a> {
    stage: Stage,
    /// The files finished so far, together.
    completed: u64,
    /// What there is of the file under way.
    current: u64,
    total: u64,
    last: Option<Instant>,
    listener: &'a mut dyn FnMut(Progress) -> bool,
}

impl<'a> Reporter<'a> {
    fn new(stage: Stage, total: u64, listener: &'a mut dyn FnMut(Progress) -> bool) -> Self {
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
    fn report(&mut self, now: bool) -> bool {
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

/// What [`VERIFIED_FILE`] remembers of each file checked.
#[derive(Debug, Default, Deserialize, Serialize)]
struct Stamp {
    files: BTreeMap<String, StampedFile>,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
struct StampedFile {
    bytes: u64,
    /// What it was checked against, so that a new pin checks it again.
    sha256: String,
    /// When it was last written, in nanoseconds since 1970.
    modified_ns: u64,
}

impl StampedFile {
    fn of(file: &PinnedFile, metadata: &fs::Metadata) -> Self {
        Self {
            bytes: file.bytes,
            sha256: file.sha256.to_owned(),
            modified_ns: metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |since| u64::try_from(since.as_nanos()).unwrap_or(u64::MAX)),
        }
    }
}

impl Stamp {
    /// What `path` remembers; nothing if it can't be read.
    fn read(path: &Path) -> Self {
        fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    /// Writes the stamp whole or not at all.
    fn write(&self, path: &Path) -> io::Result<()> {
        let text = serde_json::to_vec_pretty(self).map_err(io::Error::other)?;
        let partial = path.with_extension("json.partial");
        fs::write(&partial, text)?;
        fs::rename(&partial, path)
    }
}

/// A file's SHA-256, in lowercase hex. `read` hears each run of bytes hashed, and returns false to
/// stop, which fails with [`io::ErrorKind::Interrupted`].
fn sha256_of(path: &Path, read: &mut dyn FnMut(u64) -> bool) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0; 1 << 20];
    loop {
        let count = match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        hasher.update(&buffer[..count]);
        if !read(count as u64) {
            return Err(io::Error::new(io::ErrorKind::Interrupted, "stopped"));
        }
    }
    Ok(hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect())
}

fn disk(path: &Path, source: io::Error) -> PrepareError {
    PrepareError::Disk {
        path: path.to_owned(),
        source,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::io::{BufRead, BufReader};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};
    use std::thread;

    use super::*;

    /// Each request's path, and where its range starts.
    type Requests = Arc<Mutex<Vec<(String, Option<u64>)>>>;

    /// A tiny HTTP server with the files a test publishes. It records each request's path and
    /// where its range starts, and answers one request a connection.
    struct Server {
        base: String,
        requests: Requests,
    }

    impl Server {
        fn start(files: HashMap<&'static str, Vec<u8>>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let requests = Requests::default();
            let seen = Arc::clone(&requests);
            thread::spawn(move || {
                for stream in listener.incoming() {
                    let Ok(mut stream) = stream else { continue };
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut request_line = String::new();
                    if reader.read_line(&mut request_line).is_err() {
                        continue;
                    }
                    let path = request_line.split_whitespace().nth(1).unwrap_or_default().to_owned();
                    let mut range = None;
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                            break;
                        }
                        if let Some(value) = line.to_ascii_lowercase().strip_prefix("range: bytes=") {
                            range = value.trim().trim_end_matches('-').parse::<u64>().ok();
                        }
                    }
                    seen.lock().unwrap().push((path.clone(), range));
                    let name = path.rsplit('/').next().unwrap_or_default();
                    let response = match files.get(name) {
                        None => b"HTTP/1.1 404 Not Found\r\nconnection: close\r\ncontent-length: 0\r\n\r\n".to_vec(),
                        Some(body) => match range.map(|from| from as usize) {
                            Some(from) if from < body.len() => {
                                let mut response = format!(
                                    "HTTP/1.1 206 Partial Content\r\nconnection: close\r\ncontent-length: {}\r\n\
                                     content-range: bytes {from}-{}/{}\r\n\r\n",
                                    body.len() - from,
                                    body.len() - 1,
                                    body.len()
                                )
                                .into_bytes();
                                response.extend_from_slice(&body[from..]);
                                response
                            }
                            _ => {
                                let mut response = format!(
                                    "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: {}\r\n\r\n",
                                    body.len()
                                )
                                .into_bytes();
                                response.extend_from_slice(body);
                                response
                            }
                        },
                    };
                    let _ = stream.write_all(&response);
                }
            });
            Self { base, requests }
        }

        fn requests(&self) -> Vec<(String, Option<u64>)> {
            self.requests.lock().unwrap().clone()
        }
    }

    const WEIGHTS: &[u8] = &[7; 300_000];
    const CONFIG: &[u8] = b"{\"eos_token_id\": [1, 2]}";

    fn sha256_hex(bytes: &[u8]) -> String {
        Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
    }

    /// A model of two files, and a server that publishes them.
    fn model_and_server() -> (&'static PinnedModel, Server) {
        let files: &'static [PinnedFile] = Box::leak(Box::new([
            PinnedFile {
                name: "config.json",
                bytes: CONFIG.len() as u64,
                sha256: Box::leak(sha256_hex(CONFIG).into_boxed_str()),
            },
            PinnedFile {
                name: "weights.bin",
                bytes: WEIGHTS.len() as u64,
                sha256: Box::leak(sha256_hex(WEIGHTS).into_boxed_str()),
            },
        ]));
        let model = Box::leak(Box::new(PinnedModel {
            id: "the-model",
            repository: "Owner/the-model",
            revision: "8298d9b2d532965800b2c0c64b81965ededb03a3",
            files,
        }));
        let server = Server::start(HashMap::from([
            ("config.json", CONFIG.to_vec()),
            ("weights.bin", WEIGHTS.to_vec()),
        ]));
        (model, server)
    }

    fn scratch(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("lt-language-model-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&folder);
        fs::create_dir_all(&folder).unwrap();
        folder
    }

    #[test]
    fn puts_a_file_in_the_subfolder_its_name_gives() {
        const ADAPTER: &[u8] = &[3; 1_000];
        let files: &'static [PinnedFile] = Box::leak(Box::new([PinnedFile {
            name: "adapters/medium/adapters.safetensors",
            bytes: ADAPTER.len() as u64,
            sha256: Box::leak(sha256_hex(ADAPTER).into_boxed_str()),
        }]));
        let model = Box::leak(Box::new(PinnedModel {
            id: "nested",
            repository: "Owner/nested",
            revision: "8298d9b2d532965800b2c0c64b81965ededb03a3",
            files,
        }));
        let server = Server::start(HashMap::from([("adapters.safetensors", ADAPTER.to_vec())]));
        let root = scratch("nested");
        let folder = prepare_from(&server.base, model, &root, &mut |_| true).unwrap();
        assert_eq!(
            fs::read(folder.join("adapters/medium/adapters.safetensors")).unwrap(),
            ADAPTER
        );
        // The second time, the stamp is trusted: nothing is requested again.
        prepare_from(&server.base, model, &root, &mut |_| true).unwrap();
        assert_eq!(server.requests().len(), 1);
    }

    #[test]
    fn downloads_the_model_at_its_revision_then_trusts_its_stamp() {
        let (model, server) = model_and_server();
        let root = scratch("download");
        let folder = prepare_from(&server.base, model, &root, &mut |_| true).unwrap();
        assert_eq!(folder, root.join("the-model"));
        assert_eq!(fs::read(folder.join("weights.bin")).unwrap(), WEIGHTS);
        assert!(folder.join(VERIFIED_FILE).is_file());
        assert!(!root.join(".the-model.download").exists());
        let paths: Vec<String> = server.requests().into_iter().map(|(path, _)| path).collect();
        assert_eq!(
            paths,
            [
                "/Owner/the-model/resolve/8298d9b2d532965800b2c0c64b81965ededb03a3/config.json",
                "/Owner/the-model/resolve/8298d9b2d532965800b2c0c64b81965ededb03a3/weights.bin",
            ]
        );

        // The second start hashes nothing and asks the server nothing.
        let mut stages = Vec::new();
        prepare_from(&server.base, model, &root, &mut |progress| {
            stages.push(progress.stage);
            true
        })
        .unwrap();
        assert!(stages.is_empty(), "{stages:?}");
        assert_eq!(server.requests().len(), 2);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn carries_on_a_partial_download_with_a_range() {
        let (model, server) = model_and_server();
        let root = scratch("resume");
        let staging = root.join(".the-model.download");
        fs::create_dir_all(&staging).unwrap();
        fs::write(staging.join("weights.bin"), &WEIGHTS[..100_000]).unwrap();
        prepare_from(&server.base, model, &root, &mut |_| true).unwrap();
        assert_eq!(fs::read(root.join("the-model/weights.bin")).unwrap(), WEIGHTS);
        let weights = server
            .requests()
            .into_iter()
            .find(|(path, _)| path.ends_with("weights.bin"))
            .unwrap();
        assert_eq!(weights.1, Some(100_000));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_damaged_file_is_downloaded_again() {
        let (model, server) = model_and_server();
        let root = scratch("damaged");
        let folder = prepare_from(&server.base, model, &root, &mut |_| true).unwrap();
        let mut damaged = WEIGHTS.to_vec();
        damaged[1_000] = 0;
        fs::write(folder.join("weights.bin"), &damaged).unwrap();
        prepare_from(&server.base, model, &root, &mut |_| true).unwrap();
        assert_eq!(fs::read(folder.join("weights.bin")).unwrap(), WEIGHTS);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn stops_when_the_listener_says_so() {
        let (model, server) = model_and_server();
        let root = scratch("stop");
        let result = prepare_from(&server.base, model, &root, &mut |progress| {
            progress.stage != Stage::Downloading
        });
        assert!(matches!(result, Err(PrepareError::Stopped)), "{result:?}");
        assert!(!model.is_in(&root));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn the_cleanup_model_is_pinned_to_a_commit() {
        assert_eq!(CLEANUP_MODEL.revision.len(), 40);
        assert!(CLEANUP_MODEL.files.iter().all(|file| file.sha256.len() == 64));
        assert!(CLEANUP_MODEL.files.iter().any(|file| file.name == "openvino_model.bin"));
    }
}
