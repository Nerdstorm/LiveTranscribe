//! Downloads the default speech model the first time the app needs it, as the Mac app downloads
//! its models on first launch: Nerdstorm/Qwen3-ASR-0.6B-Sinhala-OpenVINO from Hugging Face, at a
//! pinned revision, into a folder beside its final place. Each file is checked against its
//! SHA-256, and the folder moves into place only when every file has. A download that stops (no
//! network, the app quit) carries on from where it stopped the next time.
//!
//! A model in place is used as it is, without asking Hugging Face anything.

use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use reqwest::StatusCode;
use reqwest::blocking::Client;
use reqwest::header::{CONTENT_RANGE, RANGE};
use sha2::{Digest, Sha256};

const HUGGING_FACE: &str = "https://huggingface.co";

/// How long a connection may take, and how long a read may wait for data, before the download
/// fails and says why.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const READ_TIMEOUT: Duration = Duration::from_secs(60);

/// How often progress is reported, at most.
const PROGRESS_INTERVAL: Duration = Duration::from_millis(250);

/// A model the app can download: a Hugging Face repository at a revision, and its files.
pub(crate) struct DownloadableModel {
    pub(crate) repository: &'static str,
    pub(crate) revision: &'static str,
    pub(crate) files: &'static [ModelFile],
}

/// A file of a model, as published.
pub(crate) struct ModelFile {
    pub(crate) name: &'static str,
    pub(crate) size: u64,
    pub(crate) sha256: &'static str,
}

/// The default speech model ([`crate::paths::DEFAULT_MODEL`]): the Mac app's, converted for
/// OpenVINO. The setup kit's 07-export-model.sh pins the same revision and files.
pub(crate) const DEFAULT_MODEL: DownloadableModel = DownloadableModel {
    repository: "Nerdstorm/Qwen3-ASR-0.6B-Sinhala-OpenVINO",
    revision: "8298d9b2d532965800b2c0c64b81965ededb03a3",
    files: &[
        ModelFile {
            name: "audio-conv.bin",
            size: 24_756_552,
            sha256: "c2d7685599c5aac77254a235a40e9d700c791ed60f2f4aa3b6065d024edd8571",
        },
        ModelFile {
            name: "audio-conv.xml",
            size: 20_822,
            sha256: "e7bb6cabc32771250112a6b10cc15859284425f71334e190c7c1f6b8af1b2710",
        },
        ModelFile {
            name: "audio-encoder.bin",
            size: 350_684_002,
            sha256: "b46d7aaf22574ec88eca688fbfc042359440841ea7dc87e27f4cb91faf0abcf0",
        },
        ModelFile {
            name: "audio-encoder.xml",
            size: 686_210,
            sha256: "e388b2506792ff28a4519227a0f6a2165f406eef15c3c4a6cf6ec6e5e63b1bcc",
        },
        ModelFile {
            name: "config.json",
            size: 7_206,
            sha256: "4d1d1418760461ac810d0abff04e7181c98dc1639b446dc501b33f8473e748b7",
        },
        ModelFile {
            name: "merges.txt",
            size: 1_671_853,
            sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
        },
        ModelFile {
            name: "text-embeddings.bin",
            size: 155_886_340,
            sha256: "452fa0052ce24db7c73c198ed96c05a6c24aaea46aa6f91cb5a28123f4fe460b",
        },
        ModelFile {
            name: "text-embeddings.xml",
            size: 5_695,
            sha256: "259ea5813bd03e4b0828049c5f259a4f80d4f9111335974b5cf0287ad3460ec1",
        },
        ModelFile {
            name: "text.bin",
            size: 597_239_024,
            sha256: "dad4bfca2c4a9410aeb4b8c7687277df2babcc684ccc7f8b2b75f4221505ee49",
        },
        ModelFile {
            name: "text.xml",
            size: 2_568_513,
            sha256: "f318dac79d95c755704d8951f126b704b8079e1d1f156ed79fba2b4fe41b7ba5",
        },
        ModelFile {
            name: "tokenizer_config.json",
            size: 12_487,
            sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c",
        },
        ModelFile {
            name: "vocab.json",
            size: 2_776_833,
            sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
        },
        // Last: a folder with a manifest is a complete model (`is_in_place`).
        ModelFile {
            name: "manifest.json",
            size: 526,
            sha256: "23a02176b5fec5b60aeab88778431a5b1bede5f1d19d856486f939543b26639d",
        },
    ],
};

impl DownloadableModel {
    /// All its files together, in bytes.
    pub(crate) fn size(&self) -> u64 {
        self.files.iter().map(|file| file.size).sum()
    }
}

/// Whether `folder` holds a model. An export writes the manifest last, and a download moves the
/// whole folder into place at once, so a folder with a manifest is complete.
pub(crate) fn is_in_place(folder: &Path) -> bool {
    folder.join("manifest.json").is_file()
}

/// How far a download has got, in bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Progress {
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
    /// Hugging Face couldn't be reached, or the connection broke.
    Network {
        file: &'static str,
        source: Box<dyn std::error::Error + Send + Sync>,
    },
    /// Hugging Face answered with something other than the file.
    Status { file: &'static str, status: StatusCode },
    /// The file arrived, twice, with other contents than were published.
    Checksum { file: &'static str },
    /// A file or folder on this computer couldn't be written.
    Disk { path: PathBuf, source: io::Error },
    /// The app stopped wanting the download.
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
            Self::Status { file, status } => {
                write!(f, "Hugging Face answered {status} for the speech model's {file}")
            }
            Self::Checksum { file } => write!(
                f,
                "the speech model's {file} downloaded twice with other contents than were published"
            ),
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

/// Downloads `model` from Hugging Face into `folder`, which must not hold a model yet. `progress`
/// hears how far it has got, every quarter second at most, and returns false to stop it; what was
/// downloaded stays for the next try.
pub(crate) fn download(
    model: &DownloadableModel,
    folder: &Path,
    progress: &mut dyn FnMut(Progress) -> bool,
) -> Result<(), DownloadError> {
    download_from(HUGGING_FACE, model, folder, progress)
}

fn download_from(
    base: &str,
    model: &DownloadableModel,
    folder: &Path,
    progress: &mut dyn FnMut(Progress) -> bool,
) -> Result<(), DownloadError> {
    let staging = staging_folder(folder);
    fs::create_dir_all(&staging).map_err(|source| disk(&staging, source))?;
    let mut reporter = Reporter {
        completed: 0,
        current: 0,
        total: model.size(),
        last: None,
        listener: progress,
    };
    for file in model.files {
        let url = format!("{base}/{}/resolve/{}/{}", model.repository, model.revision, file.name);
        fetch_file(&url, file, &staging.join(file.name), &mut reporter)?;
    }
    // Whatever is where the model goes has no manifest, so it's an unfinished copy.
    if folder.exists() {
        fs::remove_dir_all(folder).map_err(|source| disk(folder, source))?;
    }
    fs::rename(&staging, folder).map_err(|source| disk(folder, source))?;
    reporter.report(true);
    Ok(())
}

/// Where a model is downloaded before it moves into `folder`: beside it, so the move is a rename.
fn staging_folder(folder: &Path) -> PathBuf {
    let name = folder
        .file_name()
        .map(|name| name.to_string_lossy())
        .unwrap_or_default();
    folder.with_file_name(format!(".{name}.download"))
}

/// Downloads one file into `path`, carrying on from what's there, and checks it. A file that
/// comes out with other contents than were published is downloaded once more from the start.
fn fetch_file(url: &str, file: &'static ModelFile, path: &Path, reporter: &mut Reporter) -> Result<(), DownloadError> {
    for attempt in 0..2 {
        let had = existing_length(path, file.size).map_err(|source| disk(path, source))?;
        reporter.current = had;
        if had < file.size {
            fetch_rest(url, file, path, had, reporter)?;
        }
        if sha256_of(path).map_err(|source| disk(path, source))? == file.sha256 {
            reporter.completed += file.size;
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
    Err(DownloadError::Checksum { file: file.name })
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
    file: &'static ModelFile,
    path: &Path,
    from: u64,
    reporter: &mut Reporter,
) -> Result<(), DownloadError> {
    let network = |source: Box<dyn std::error::Error + Send + Sync>| DownloadError::Network {
        file: file.name,
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
        return Err(DownloadError::Status {
            file: file.name,
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
    while written <= file.size {
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
    if written < file.size {
        return Err(network("the download ended before the file did".into()));
    }
    Ok(())
}

fn sha256_of(path: &Path) -> io::Result<String> {
    let mut hasher = Sha256::new();
    io::copy(&mut File::open(path)?, &mut hasher)?;
    Ok(hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect())
}

fn disk(path: &Path, source: io::Error) -> DownloadError {
    DownloadError::Disk {
        path: path.to_owned(),
        source,
    }
}

/// One HTTP client for the process, which keeps its connections to Hugging Face. It checks them
/// with the system's CA certificates, and can't be made without any, as in a container without
/// the ca-certificates package: then each download fails with why, and the next try makes it anew.
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

/// Counts bytes across the files and tells the listener, every [`PROGRESS_INTERVAL`] at most.
struct Reporter<'a> {
    /// The files checked so far, together.
    completed: u64,
    /// What there is of the file being downloaded.
    current: u64,
    total: u64,
    last: Option<Instant>,
    listener: &'a mut dyn FnMut(Progress) -> bool,
}

impl Reporter<'_> {
    /// Tells the listener how far the download has got, if it's time to (or `now`), and returns
    /// whether to carry on.
    fn report(&mut self, now: bool) -> bool {
        if !now && self.last.is_some_and(|last| last.elapsed() < PROGRESS_INTERVAL) {
            return true;
        }
        self.last = Some(Instant::now());
        (self.listener)(Progress {
            done: self.completed + self.current,
            total: self.total,
        })
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
    type Requests = Arc<Mutex<Vec<(String, Option<String>)>>>;

    /// A tiny HTTP server with the files a test publishes; it records each request's path and
    /// range, and can ignore ranges.
    struct Server {
        base: String,
        requests: Requests,
    }

    impl Server {
        fn start(files: HashMap<String, Vec<u8>>, honour_ranges: bool) -> Self {
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
                            range = Some(value.trim().trim_end_matches('-').to_owned());
                        }
                    }
                    seen.lock().unwrap().push((path.clone(), range.clone()));
                    let name = path.rsplit('/').next().unwrap_or_default();
                    let response = match files.get(name) {
                        None => b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n".to_vec(),
                        Some(body) => match range.and_then(|from| from.parse::<usize>().ok()) {
                            Some(from) if honour_ranges && from < body.len() => {
                                let mut response = format!(
                                    "HTTP/1.1 206 Partial Content\r\ncontent-length: {}\r\ncontent-range: bytes {from}-{}/{}\r\n\r\n",
                                    body.len() - from,
                                    body.len() - 1,
                                    body.len()
                                )
                                .into_bytes();
                                response.extend_from_slice(&body[from..]);
                                response
                            }
                            _ => {
                                let mut response =
                                    format!("HTTP/1.1 200 OK\r\ncontent-length: {}\r\n\r\n", body.len()).into_bytes();
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

        fn requests(&self) -> Vec<(String, Option<String>)> {
            self.requests.lock().unwrap().clone()
        }
    }

    fn sha256_hex(bytes: &[u8]) -> String {
        Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
    }

    /// A model of two files, and what a server publishes for it.
    fn model(first: &[u8], manifest: &[u8]) -> (DownloadableModel, HashMap<String, Vec<u8>>) {
        let files: &'static [ModelFile] = Box::leak(Box::new([
            ModelFile {
                name: "weights.bin",
                size: first.len() as u64,
                sha256: Box::leak(sha256_hex(first).into_boxed_str()),
            },
            ModelFile {
                name: "manifest.json",
                size: manifest.len() as u64,
                sha256: Box::leak(sha256_hex(manifest).into_boxed_str()),
            },
        ]));
        let published = HashMap::from([
            ("weights.bin".to_owned(), first.to_vec()),
            ("manifest.json".to_owned(), manifest.to_vec()),
        ]);
        (
            DownloadableModel {
                repository: "Nerdstorm/test",
                revision: "abc123",
                files,
            },
            published,
        )
    }

    fn scratch(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("lt-download-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        root
    }

    const WEIGHTS: &[u8] = &[7; 300_000];
    const MANIFEST: &[u8] = br#"{"format": 2}"#;

    #[test]
    fn downloads_every_file_then_moves_the_folder_into_place() {
        let (model, published) = model(WEIGHTS, MANIFEST);
        let server = Server::start(published, true);
        let root = scratch("whole");
        let folder = root.join("the-model");
        let mut heard = Vec::new();
        download_from(&server.base, &model, &folder, &mut |progress| {
            heard.push(progress);
            true
        })
        .unwrap();
        assert!(is_in_place(&folder));
        assert_eq!(fs::read(folder.join("weights.bin")).unwrap(), WEIGHTS);
        assert!(!staging_folder(&folder).exists(), "the staging folder became the model");
        assert_eq!(heard.last().map(|progress| progress.percent()), Some(100));
        assert!(
            heard.windows(2).all(|pair| pair[0].done <= pair[1].done),
            "progress only grows"
        );
        assert_eq!(
            server.requests()[0],
            ("/Nerdstorm/test/resolve/abc123/weights.bin".to_owned(), None)
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_partial_file_is_carried_on_with_a_range() {
        let (model, published) = model(WEIGHTS, MANIFEST);
        let server = Server::start(published, true);
        let root = scratch("resume");
        let folder = root.join("the-model");
        let staging = staging_folder(&folder);
        fs::create_dir_all(&staging).unwrap();
        fs::write(staging.join("weights.bin"), &WEIGHTS[..100_000]).unwrap();
        download_from(&server.base, &model, &folder, &mut |_| true).unwrap();
        assert_eq!(fs::read(folder.join("weights.bin")).unwrap(), WEIGHTS);
        assert_eq!(server.requests()[0].1.as_deref(), Some("100000"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_server_that_ignores_the_range_sends_the_file_again() {
        let (model, published) = model(WEIGHTS, MANIFEST);
        let server = Server::start(published, false);
        let root = scratch("no-range");
        let folder = root.join("the-model");
        let staging = staging_folder(&folder);
        fs::create_dir_all(&staging).unwrap();
        fs::write(staging.join("weights.bin"), &WEIGHTS[..100_000]).unwrap();
        download_from(&server.base, &model, &folder, &mut |_| true).unwrap();
        assert_eq!(fs::read(folder.join("weights.bin")).unwrap(), WEIGHTS);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_file_with_other_contents_is_downloaded_again() {
        let (model, published) = model(WEIGHTS, MANIFEST);
        let server = Server::start(published, true);
        let root = scratch("corrupt");
        let folder = root.join("the-model");
        let staging = staging_folder(&folder);
        fs::create_dir_all(&staging).unwrap();
        fs::write(staging.join("weights.bin"), vec![8; WEIGHTS.len()]).unwrap();
        download_from(&server.base, &model, &folder, &mut |_| true).unwrap();
        assert_eq!(fs::read(folder.join("weights.bin")).unwrap(), WEIGHTS);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn contents_that_never_match_fail_and_leave_no_model() {
        let (model, mut published) = model(WEIGHTS, MANIFEST);
        published.insert("weights.bin".to_owned(), vec![9; WEIGHTS.len()]);
        let server = Server::start(published, true);
        let root = scratch("mismatch");
        let folder = root.join("the-model");
        let error = download_from(&server.base, &model, &folder, &mut |_| true).unwrap_err();
        assert!(
            matches!(error, DownloadError::Checksum { file: "weights.bin" }),
            "{error}"
        );
        assert!(!folder.exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_missing_file_says_what_the_server_answered() {
        let (model, mut published) = model(WEIGHTS, MANIFEST);
        published.remove("manifest.json");
        let server = Server::start(published, true);
        let root = scratch("missing");
        let error = download_from(&server.base, &model, &root.join("the-model"), &mut |_| true).unwrap_err();
        assert_eq!(
            error.to_string(),
            "Hugging Face answered 404 Not Found for the speech model's manifest.json"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_failure_says_its_cause_once_when_printed_with_its_causes() {
        let (model, _) = model(WEIGHTS, MANIFEST);
        let root = scratch("refused");
        // Nothing listens on port 1, and the other tests' servers take ports the system picks.
        let error = download_from("http://127.0.0.1:1", &model, &root.join("the-model"), &mut |_| true).unwrap_err();
        assert!(matches!(error, DownloadError::Network { .. }), "{error}");
        let printed = format!(
            "{:#}",
            anyhow::Error::new(error).context("couldn't download the speech model")
        );
        assert_eq!(printed.matches("error sending request").count(), 1, "{printed}");

        let error = disk(&root, io::Error::new(io::ErrorKind::PermissionDenied, "not allowed"));
        let printed = format!("{:#}", anyhow::Error::new(error));
        assert_eq!(printed, format!("couldn't write {}: not allowed", root.display()));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn stopping_keeps_what_was_downloaded() {
        let (model, published) = model(WEIGHTS, MANIFEST);
        let server = Server::start(published, true);
        let root = scratch("stop");
        let folder = root.join("the-model");
        let error = download_from(&server.base, &model, &folder, &mut |_| false).unwrap_err();
        assert!(matches!(error, DownloadError::Stopped));
        assert!(!is_in_place(&folder));
        assert!(staging_folder(&folder).join("weights.bin").exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn the_default_model_is_the_published_one() {
        assert_eq!(DEFAULT_MODEL.files.len(), 13);
        assert_eq!(DEFAULT_MODEL.files.last().map(|file| file.name), Some("manifest.json"));
        assert_eq!(DEFAULT_MODEL.size(), 1_136_316_063);
        assert!(DEFAULT_MODEL.files.iter().all(|file| file.sha256.len() == 64));
    }

    #[test]
    fn percent_rounds_down() {
        let progress = |done| Progress { done, total: 1_000 };
        assert_eq!(progress(0).percent(), 0);
        assert_eq!(progress(999).percent(), 99);
        assert_eq!(progress(1_000).percent(), 100);
        assert_eq!(Progress { done: 0, total: 0 }.percent(), 0);
    }
}
