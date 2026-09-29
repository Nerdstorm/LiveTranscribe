//! The catalog's models on disk, as the Mac app's SpeechModelDownloads: each in a folder of the
//! models folder named by its id, downloaded into a folder beside it and moved into place once
//! every file is in. A download that stops (no network, Cancel, the app quit) carries on from
//! where it stopped the next time.
//!
//! A Hugging Face model's files are fetched one by one at its pinned commit. A sherpa-onnx model's
//! archive is fetched and checked, the model's files are unpacked from it, and the archive is
//! deleted. Either way the folder is then checked against the catalog ([`SpeechModel::verify`]),
//! and a model is only opened checked.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use lt_transcription::catalog::{Engine, SpeechModel, VERIFIED_FILE, VerifiedModel, VerifyError};

use super::archive::unpack;
use super::fetch::{DownloadError, Progress, Published, Reporter, Stage, disk, fetch_file};

const HUGGING_FACE: &str = "https://huggingface.co";

/// The models folder, and downloading into it.
#[derive(Clone, Debug)]
pub(crate) struct SpeechModelDownloads {
    folder: PathBuf,
    /// Where Hugging Face is: a test's server stands in for it.
    hugging_face: String,
}

impl SpeechModelDownloads {
    /// Downloads into `folder`, the models folder.
    pub(crate) fn new(folder: PathBuf) -> Self {
        Self {
            folder,
            hugging_face: HUGGING_FACE.to_owned(),
        }
    }

    /// Downloads into `folder`, with a test's server for Hugging Face.
    #[cfg(test)]
    pub(crate) fn with_hugging_face(folder: PathBuf, hugging_face: &str) -> Self {
        Self {
            folder,
            hugging_face: hugging_face.to_owned(),
        }
    }

    /// The models folder, which also holds models the setup kit converted.
    pub(crate) fn folder(&self) -> &Path {
        &self.folder
    }

    /// Where `model` is kept.
    pub(crate) fn folder_of(&self, model: &SpeechModel) -> PathBuf {
        self.folder.join(&model.id)
    }

    /// Where `model` is downloaded before it moves into place: beside it, so the move is a rename.
    fn staging_of(&self, model: &SpeechModel) -> PathBuf {
        self.folder.join(format!(".{}.download", model.id))
    }

    /// Whether `model` looks downloaded: each file in place, at its size. Loading it checks more.
    pub(crate) fn is_downloaded(&self, model: &SpeechModel) -> bool {
        model.is_in(&self.folder_of(model))
    }

    /// Whether any of `model`'s files are here, downloaded or partly, to remove.
    pub(crate) fn has_files(&self, model: &SpeechModel) -> bool {
        self.folder_of(model).exists() || self.staging_of(model).exists()
    }

    /// Checks `model`'s files in its folder ([`SpeechModel::verify`]).
    pub(crate) fn verify<'a>(
        &self,
        model: &'a SpeechModel,
        progress: &mut dyn FnMut(Progress),
    ) -> Result<VerifiedModel<'a>, VerifyError> {
        model.verify(&self.folder_of(model), &mut |done, total| {
            progress(Progress {
                stage: Stage::Checking,
                done,
                total,
            });
        })
    }

    /// Downloads `model` into its folder. `progress` hears how far it has got, every quarter
    /// second at most, and returns false to stop it; what was downloaded stays for the next try.
    ///
    /// A folder already there that isn't the model (a download of an earlier pin, or a damaged
    /// one) is where the download carries on from: a file that is as published isn't fetched again.
    pub(crate) fn download(
        &self,
        model: &SpeechModel,
        progress: &mut dyn FnMut(Progress) -> bool,
    ) -> Result<(), DownloadError> {
        let folder = self.folder_of(model);
        let staging = self.staging_of(model);
        if folder.exists() {
            if staging.exists() {
                fs::remove_dir_all(&folder).map_err(|source| disk(&folder, source))?;
            } else {
                fs::rename(&folder, &staging).map_err(|source| disk(&folder, source))?;
            }
        }
        fs::create_dir_all(&staging).map_err(|source| disk(&staging, source))?;
        match &model.engine {
            Engine::OpenVino { repository, revision } => {
                let mut reporter = Reporter::new(Stage::Downloading, model.download_bytes(), progress);
                for file in &model.files {
                    let published = Published {
                        url: format!("{}/{repository}/resolve/{revision}/{}", self.hugging_face, file.name),
                        name: &file.name,
                        host: model.source(),
                        bytes: file.bytes,
                        sha256: &file.sha256,
                    };
                    fetch_file(&published, &staging.join(&file.name), &mut reporter)?;
                }
                reporter.report(true);
            }
            Engine::SherpaOnnx { archive, .. } => {
                let name = archive.url.rsplit('/').next().unwrap_or("model.tar.bz2");
                let path = staging.join(name);
                let published = Published {
                    url: archive.url.clone(),
                    name,
                    host: model.source(),
                    bytes: archive.bytes,
                    sha256: &archive.sha256,
                };
                let mut reporter = Reporter::new(Stage::Downloading, archive.bytes, progress);
                fetch_file(&published, &path, &mut reporter)?;
                reporter.report(true);
                unpack(&path, &model.files, &staging, progress)?;
                fs::remove_file(&path).map_err(|source| disk(&path, source))?;
            }
        }
        // What an earlier download remembered checking says nothing about these files.
        match fs::remove_file(staging.join(VERIFIED_FILE)) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(disk(&staging, error)),
            _ => {}
        }
        fs::rename(&staging, &folder).map_err(|source| disk(&folder, source))?;
        Ok(())
    }

    /// Removes `model`'s files: its folder, and any download under way into the folder beside it.
    pub(crate) fn remove(&self, model: &SpeechModel) -> io::Result<()> {
        for folder in [self.folder_of(model), self.staging_of(model)] {
            match fs::remove_dir_all(&folder) {
                Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
                _ => {}
            }
        }
        tracing::info!("Removed the speech model {}", model.id);
        Ok(())
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::collections::HashMap;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};
    use std::thread;

    use lt_transcription::catalog::{Archive, ModelFile, Platform, Role, SpeechModelCatalog, hex};
    use lt_transcription::sherpa::Family;
    use serde_json::json;
    use sha2::{Digest, Sha256};

    use super::super::archive::tests::{model_file, tar_bz2};
    use super::*;

    /// Each request's path, and where its range starts.
    type Requests = Arc<Mutex<Vec<(String, Option<String>)>>>;

    /// A tiny HTTP server with the files a test publishes; it records each request's path and
    /// range, and can ignore ranges. It answers one request a connection, and says so.
    pub(crate) struct Server {
        pub(crate) base: String,
        requests: Requests,
        files: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    }

    impl Server {
        pub(crate) fn start(files: HashMap<String, Vec<u8>>, honour_ranges: bool) -> Self {
            Self::serve(files, honour_ranges, None)
        }

        /// A server that sends each body a little at a time, pausing `pause` between pieces.
        pub(crate) fn slow(files: HashMap<String, Vec<u8>>, pause: std::time::Duration) -> Self {
            Self::serve(files, true, Some(pause))
        }

        fn serve(files: HashMap<String, Vec<u8>>, honour_ranges: bool, pause: Option<std::time::Duration>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let requests = Requests::default();
            let seen = Arc::clone(&requests);
            let files = Arc::new(Mutex::new(files));
            let published = Arc::clone(&files);
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
                    let body = published.lock().unwrap().get(name).cloned();
                    let response = match body.as_deref() {
                        None => b"HTTP/1.1 404 Not Found\r\nconnection: close\r\ncontent-length: 0\r\n\r\n".to_vec(),
                        Some(body) => match range.and_then(|from| from.parse::<usize>().ok()) {
                            Some(from) if honour_ranges && from < body.len() => {
                                let mut response = format!(
                                    "HTTP/1.1 206 Partial Content\r\nconnection: close\r\ncontent-length: {}\r\ncontent-range: bytes {from}-{}/{}\r\n\r\n",
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
                    match pause {
                        None => {
                            let _ = stream.write_all(&response);
                        }
                        Some(pause) => {
                            for piece in response.chunks(8 * 1024) {
                                if stream.write_all(piece).is_err() {
                                    break;
                                }
                                thread::sleep(pause);
                            }
                        }
                    }
                }
            });
            Self { base, requests, files }
        }

        /// Publishes more files, such as an archive whose URL has the server's address in it.
        pub(crate) fn publish(&self, files: HashMap<String, Vec<u8>>) {
            self.files.lock().unwrap().extend(files);
        }

        pub(crate) fn requests(&self) -> Vec<(String, Option<String>)> {
            self.requests.lock().unwrap().clone()
        }
    }

    fn sha256_hex(bytes: &[u8]) -> String {
        hex(&Sha256::digest(bytes))
    }

    /// A catalog of one model, `section` its Linux section, kept for the test's life.
    pub(crate) fn catalog_with(section: serde_json::Value) -> &'static SpeechModelCatalog {
        let text = json!({
            "format": 1,
            "models": [{
                "id": "the-model", "name": "The Model", "summary": "For tests.", "languages": "English",
                "licence": "MIT", "credit": "Us", "linux": section, "windows": section,
            }],
        });
        Box::leak(Box::new(
            SpeechModelCatalog::parse(&text.to_string(), Platform::current()).unwrap(),
        ))
    }

    /// A Hugging Face model of two files, and what a server publishes for it.
    pub(crate) fn hugging_face_model(
        weights: &[u8],
        manifest: &[u8],
    ) -> (&'static SpeechModel, HashMap<String, Vec<u8>>) {
        let catalog = catalog_with(json!({
            "engine": "openvino",
            "repository": "Nerdstorm/test",
            "revision": "8298d9b2d532965800b2c0c64b81965ededb03a3",
            "files": [
                {"name": "weights.bin", "bytes": weights.len(), "sha256": sha256_hex(weights)},
                {"name": "manifest.json", "bytes": manifest.len(), "sha256": sha256_hex(manifest)},
            ],
        }));
        let published = HashMap::from([
            ("weights.bin".to_owned(), weights.to_vec()),
            ("manifest.json".to_owned(), manifest.to_vec()),
        ]);
        (&catalog.models()[0], published)
    }

    /// A sherpa-onnx model whose files are in an archive at `base`, and what a server publishes.
    /// Made without the catalog, which takes archives over HTTPS only.
    pub(crate) fn archived_model(base: &str) -> (&'static SpeechModel, HashMap<String, Vec<u8>>) {
        let archive = tar_bz2(&[
            ("the-model/encoder.onnx", ENCODER),
            ("the-model/test_wavs/0.wav", b"clip"),
            ("the-model/decoder.onnx", b"decoder"),
            ("the-model/tokens.txt", b"tokens"),
        ]);
        let file = |name: &str, contents: &[u8], role| ModelFile {
            role: Some(role),
            ..model_file(name, contents)
        };
        let model = SpeechModel {
            id: "the-model".to_owned(),
            name: "The Model".to_owned(),
            summary: "For tests.".to_owned(),
            languages: "English".to_owned(),
            licence: "MIT".to_owned(),
            credit: "Us".to_owned(),
            engine: Engine::SherpaOnnx {
                family: Family::CohereTranscribe,
                archive: Archive {
                    url: format!("{base}/releases/download/asr-models/the-model.tar.bz2"),
                    bytes: archive.len() as u64,
                    sha256: sha256_hex(&archive),
                },
            },
            files: vec![
                file("encoder.onnx", ENCODER, Role::Encoder),
                file("decoder.onnx", b"decoder", Role::Decoder),
                file("tokens.txt", b"tokens", Role::Tokens),
            ],
        };
        (
            Box::leak(Box::new(model)),
            HashMap::from([("the-model.tar.bz2".to_owned(), archive)]),
        )
    }

    pub(crate) fn scratch(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("lt-download-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn downloads(root: &Path, server: &Server) -> SpeechModelDownloads {
        SpeechModelDownloads {
            folder: root.to_owned(),
            hugging_face: server.base.clone(),
        }
    }

    const WEIGHTS: &[u8] = &[7; 300_000];
    const MANIFEST: &[u8] = br#"{"format": 2}"#;
    const ENCODER: &[u8] = &[3; 200_000];

    #[test]
    fn downloads_every_file_then_moves_the_folder_into_place() {
        let (model, published) = hugging_face_model(WEIGHTS, MANIFEST);
        let server = Server::start(published, true);
        let root = scratch("whole");
        let downloads = downloads(&root, &server);
        let mut heard = Vec::new();
        downloads
            .download(model, &mut |progress| {
                heard.push(progress);
                true
            })
            .unwrap();
        assert!(downloads.is_downloaded(model));
        assert_eq!(fs::read(root.join("the-model/weights.bin")).unwrap(), WEIGHTS);
        assert!(
            !root.join(".the-model.download").exists(),
            "the staging folder became the model"
        );
        assert_eq!(heard.last().map(|progress| progress.percent()), Some(100));
        assert!(
            heard.windows(2).all(|pair| pair[0].done <= pair[1].done),
            "progress only grows"
        );
        assert_eq!(
            server.requests()[0],
            (
                "/Nerdstorm/test/resolve/8298d9b2d532965800b2c0c64b81965ededb03a3/weights.bin".to_owned(),
                None
            )
        );
        downloads.verify(model, &mut |_| {}).unwrap();
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn an_archived_model_is_unpacked_and_its_archive_deleted() {
        let root = scratch("archive");
        // The server's address is in the catalog, so the model is made once the server is up.
        let server = Server::start(HashMap::new(), true);
        let (model, published) = archived_model(&server.base);
        server.publish(published);
        let downloads = downloads(&root, &server);
        let mut stages = Vec::new();
        downloads
            .download(model, &mut |progress| {
                if stages.last() != Some(&progress.stage) {
                    stages.push(progress.stage);
                }
                true
            })
            .unwrap();
        assert_eq!(stages, [Stage::Downloading, Stage::Unpacking]);
        let mut names: Vec<_> = fs::read_dir(root.join("the-model"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        assert_eq!(
            names,
            ["decoder.onnx", "encoder.onnx", "tokens.txt"],
            "no archive, no clips"
        );
        downloads.verify(model, &mut |_| {}).unwrap();
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_partial_file_is_carried_on_with_a_range() {
        let (model, published) = hugging_face_model(WEIGHTS, MANIFEST);
        let server = Server::start(published, true);
        let root = scratch("resume");
        let staging = root.join(".the-model.download");
        fs::create_dir_all(&staging).unwrap();
        fs::write(staging.join("weights.bin"), &WEIGHTS[..100_000]).unwrap();
        downloads(&root, &server).download(model, &mut |_| true).unwrap();
        assert_eq!(fs::read(root.join("the-model/weights.bin")).unwrap(), WEIGHTS);
        assert_eq!(server.requests()[0].1.as_deref(), Some("100000"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_server_that_ignores_the_range_sends_the_file_again() {
        let (model, published) = hugging_face_model(WEIGHTS, MANIFEST);
        let server = Server::start(published, false);
        let root = scratch("no-range");
        let staging = root.join(".the-model.download");
        fs::create_dir_all(&staging).unwrap();
        fs::write(staging.join("weights.bin"), &WEIGHTS[..100_000]).unwrap();
        downloads(&root, &server).download(model, &mut |_| true).unwrap();
        assert_eq!(fs::read(root.join("the-model/weights.bin")).unwrap(), WEIGHTS);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_file_with_other_contents_is_downloaded_again() {
        let (model, published) = hugging_face_model(WEIGHTS, MANIFEST);
        let server = Server::start(published, true);
        let root = scratch("corrupt");
        let staging = root.join(".the-model.download");
        fs::create_dir_all(&staging).unwrap();
        fs::write(staging.join("weights.bin"), vec![8; WEIGHTS.len()]).unwrap();
        downloads(&root, &server).download(model, &mut |_| true).unwrap();
        assert_eq!(fs::read(root.join("the-model/weights.bin")).unwrap(), WEIGHTS);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_damaged_model_in_place_is_repaired_fetching_only_what_is_damaged() {
        let (model, published) = hugging_face_model(WEIGHTS, MANIFEST);
        let server = Server::start(published, true);
        let root = scratch("repair");
        let downloads = downloads(&root, &server);
        downloads.download(model, &mut |_| true).unwrap();
        fs::write(root.join("the-model/weights.bin"), vec![8; WEIGHTS.len()]).unwrap();
        assert!(downloads.verify(model, &mut |_| {}).is_err());

        let before = server.requests().len();
        downloads.download(model, &mut |_| true).unwrap();
        let fetched: Vec<_> = server.requests()[before..]
            .iter()
            .map(|(path, _)| path.clone())
            .collect();
        assert!(fetched.iter().all(|path| path.ends_with("/weights.bin")), "{fetched:?}");
        downloads.verify(model, &mut |_| {}).unwrap();
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn contents_that_never_match_fail_and_leave_no_model() {
        let (model, mut published) = hugging_face_model(WEIGHTS, MANIFEST);
        published.insert("weights.bin".to_owned(), vec![9; WEIGHTS.len()]);
        let server = Server::start(published, true);
        let root = scratch("mismatch");
        let downloads = downloads(&root, &server);
        let error = downloads.download(model, &mut |_| true).unwrap_err();
        assert!(
            matches!(&error, DownloadError::Checksum { file } if file == "weights.bin"),
            "{error}"
        );
        assert!(!downloads.is_downloaded(model));
        assert!(!root.join("the-model").exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_missing_file_says_what_the_server_answered() {
        let (model, mut published) = hugging_face_model(WEIGHTS, MANIFEST);
        published.remove("manifest.json");
        let server = Server::start(published, true);
        let root = scratch("missing");
        let error = downloads(&root, &server).download(model, &mut |_| true).unwrap_err();
        assert_eq!(
            error.to_string(),
            "Hugging Face answered 404 Not Found for the speech model's manifest.json"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_failure_says_its_cause_once_when_printed_with_its_causes() {
        let (model, _) = hugging_face_model(WEIGHTS, MANIFEST);
        let root = scratch("refused");
        // Nothing listens on port 1, and the other tests' servers take ports the system picks.
        let downloads = SpeechModelDownloads {
            folder: root.clone(),
            hugging_face: "http://127.0.0.1:1".to_owned(),
        };
        let error = downloads.download(model, &mut |_| true).unwrap_err();
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
        let (model, published) = hugging_face_model(WEIGHTS, MANIFEST);
        let server = Server::start(published, true);
        let root = scratch("stop");
        let downloads = downloads(&root, &server);
        let error = downloads.download(model, &mut |_| false).unwrap_err();
        assert!(matches!(error, DownloadError::Stopped));
        assert!(!downloads.is_downloaded(model));
        assert!(root.join(".the-model.download/weights.bin").exists());
        assert!(downloads.has_files(model));
        downloads.remove(model).unwrap();
        assert!(!downloads.has_files(model), "removing takes the partial download too");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn percent_rounds_down() {
        let progress = |done| Progress {
            stage: Stage::Downloading,
            done,
            total: 1_000,
        };
        assert_eq!(progress(0).percent(), 0);
        assert_eq!(progress(999).percent(), 99);
        assert_eq!(progress(1_000).percent(), 100);
        assert_eq!(
            Progress {
                stage: Stage::Checking,
                done: 0,
                total: 0
            }
            .percent(),
            0
        );
    }
}
