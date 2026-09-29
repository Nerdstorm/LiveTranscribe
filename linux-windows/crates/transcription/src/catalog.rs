//! The speech models the app offers to download: the catalog the Mac app reads too,
//! Packages/LiveTranscribeKit/Sources/Transcription/Resources/speech-models.json
//! (SpeechModelCatalog.swift), built into the app and never fetched.
//!
//! A model has a section for each platform it runs on (`mac`, `linux`, `windows`); this build
//! reads its own platform's and leaves out a model without one, so each app has its own list, and
//! a model is named, described and credited alike everywhere. Every file is pinned: to a Hugging
//! Face commit and each file's SHA-256, or to an archive's SHA-256 and each file's in it.
//!
//! [`SpeechModel::verify`] checks a model's folder against those before the model is opened:
//! sherpa-onnx aborts the process on a file ONNX Runtime can't read ([`crate::sherpa`]), so only
//! a [`VerifiedModel`] opens ([`crate::speech_to_text::SpeechToText::open`]).

use std::collections::{BTreeMap, HashSet};
use std::fmt;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Instant, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::sherpa::Family;

/// The version of `speech-models.json` this build reads, as SpeechModelCatalog.swift's `format`.
/// A change older builds would misread needs a new number; a new field they would ignore doesn't.
pub const FORMAT: u64 = 1;

/// The catalog built into the app.
const BUNDLED: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../Packages/LiveTranscribeKit/Sources/Transcription/Resources/speech-models.json"
));

/// Where a folder remembers that its files were checked ([`SpeechModel::verify`]). A dot file,
/// which no model's file can be named.
pub const VERIFIED_FILE: &str = ".verified.json";

/// The models one platform can download.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SpeechModelCatalog {
    models: Vec<SpeechModel>,
}

/// A platform with its own section in the catalog.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    Linux,
    Windows,
}

impl Platform {
    /// The platform this build is for. Development builds on a Mac read Linux's section.
    pub fn current() -> Self {
        if cfg!(windows) { Self::Windows } else { Self::Linux }
    }
}

/// One model: what Settings shows about it, what runs it, and its files.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpeechModel {
    /// Stays the same across releases and platforms, such as `qwen3-asr-0.6b-sinhala`; also its
    /// folder's name.
    pub id: String,
    pub name: String,
    /// What to pick it for, in a sentence.
    pub summary: String,
    pub languages: String,
    /// An SPDX identifier, such as `Apache-2.0`.
    pub licence: String,
    /// Who made it, and converted it for this platform, credited as its licence asks.
    pub credit: String,
    pub engine: Engine,
    /// Its files, as they are in its folder.
    pub files: Vec<ModelFile>,
}

/// What runs a model on this platform, and where its files come from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Engine {
    /// Our Qwen3-ASR runtime on OpenVINO ([`crate::qwen3_asr`]), with a model the setup kit's
    /// export converted: the files of a Hugging Face repository at one commit.
    OpenVino { repository: String, revision: String },
    /// sherpa-onnx ([`crate::sherpa`]), on the CPU: some of the files of an archive sherpa-onnx
    /// publishes.
    SherpaOnnx { family: Family, archive: Archive },
}

/// An archive a model's files are unpacked from: a `.tar.bz2` with a folder at its top.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Archive {
    pub url: String,
    pub bytes: u64,
    pub sha256: String,
}

/// One of a model's files.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelFile {
    /// Its name in the model's folder, and in the repository or the archive's top folder.
    pub name: String,
    pub bytes: u64,
    pub sha256: String,
    /// What it is to sherpa-onnx; `None` for a file it finds by itself, such as an encoder's
    /// weights beside it, and for every file of an OpenVINO model.
    #[serde(default)]
    pub role: Option<Role>,
}

/// What a file is to sherpa-onnx.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Role {
    Encoder,
    Decoder,
    Joiner,
    Tokens,
}

impl SpeechModel {
    /// How much a download fetches.
    pub fn download_bytes(&self) -> u64 {
        match &self.engine {
            Engine::OpenVino { .. } => self.installed_bytes(),
            Engine::SherpaOnnx { archive, .. } => archive.bytes,
        }
    }

    /// How much its files take once in place.
    pub fn installed_bytes(&self) -> u64 {
        self.files.iter().map(|file| file.bytes).sum()
    }

    /// Where it is downloaded from, as Settings names it.
    pub fn source(&self) -> &'static str {
        match self.engine {
            Engine::OpenVino { .. } => "Hugging Face",
            Engine::SherpaOnnx { .. } => "GitHub",
        }
    }

    /// Whether `folder` looks like it holds the model: each file there, at its size. Quick, for
    /// Settings; [`Self::verify`] is the check.
    pub fn is_in(&self, folder: &Path) -> bool {
        self.files.iter().all(|file| {
            fs::metadata(folder.join(&file.name))
                .is_ok_and(|metadata| metadata.is_file() && metadata.len() == file.bytes)
        })
    }

    /// Checks that `folder` holds each of the model's files as published: its size, and its
    /// SHA-256. `progress` hears how many bytes have been hashed, of how many.
    ///
    /// A check that passes is remembered in the folder ([`VERIFIED_FILE`]) with each file's size
    /// and modification time, so the next one hashes only the files that changed since: loading a
    /// model checks it every time.
    pub fn verify(&self, folder: &Path, progress: &mut dyn FnMut(u64, u64)) -> Result<VerifiedModel<'_>, VerifyError> {
        let started = Instant::now();
        let stamp_path = folder.join(VERIFIED_FILE);
        let stamp = Stamp::read(&stamp_path);
        let mut checked = Stamp::default();
        let mut unchecked = Vec::new();
        for file in &self.files {
            let path = folder.join(&file.name);
            let metadata = fs::metadata(&path).map_err(|source| match source.kind() {
                io::ErrorKind::NotFound => VerifyError::Missing {
                    file: file.name.clone(),
                },
                _ => VerifyError::Read {
                    path: path.clone(),
                    source,
                },
            })?;
            if metadata.len() != file.bytes {
                return Err(VerifyError::Size {
                    file: file.name.clone(),
                    expected: file.bytes,
                    found: metadata.len(),
                });
            }
            let seen = StampedFile {
                bytes: file.bytes,
                sha256: file.sha256.clone(),
                modified_ns: modified_ns(&metadata),
            };
            if stamp.files.get(&file.name) == Some(&seen) {
                checked.files.insert(file.name.clone(), seen);
            } else {
                unchecked.push((file, path, seen));
            }
        }
        if !unchecked.is_empty() {
            let total = unchecked.iter().map(|(file, ..)| file.bytes).sum();
            let mut done = 0;
            progress(done, total);
            for (file, path, seen) in unchecked {
                let sha256 = sha256_of(&path, &mut |read| {
                    done += read;
                    progress(done, total);
                })
                .map_err(|source| VerifyError::Read {
                    path: path.clone(),
                    source,
                })?;
                if sha256 != file.sha256 {
                    return Err(VerifyError::Checksum {
                        file: file.name.clone(),
                    });
                }
                checked.files.insert(file.name.clone(), seen);
            }
            tracing::info!(
                "Checked {} of {}'s files in {:.1} s",
                checked.files.len(),
                self.id,
                started.elapsed().as_secs_f32()
            );
            // Unremembered, the check is only made again next time.
            if let Err(error) = checked.write(&stamp_path) {
                tracing::warn!("Couldn't remember that {} was checked: {error}", folder.display());
            }
        }
        Ok(VerifiedModel {
            model: self,
            folder: folder.to_owned(),
        })
    }
}

/// A model whose files [`SpeechModel::verify`] found as published, in its folder.
#[derive(Debug)]
pub struct VerifiedModel<'a> {
    model: &'a SpeechModel,
    folder: PathBuf,
}

impl VerifiedModel<'_> {
    pub fn model(&self) -> &SpeechModel {
        self.model
    }

    pub fn folder(&self) -> &Path {
        &self.folder
    }
}

/// Why a model's folder didn't pass [`SpeechModel::verify`].
#[derive(Debug)]
pub enum VerifyError {
    Missing {
        file: String,
    },
    Size {
        file: String,
        expected: u64,
        found: u64,
    },
    /// The file's contents aren't what was published.
    Checksum {
        file: String,
    },
    Read {
        path: PathBuf,
        source: io::Error,
    },
}

impl fmt::Display for VerifyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Missing { file } => write!(f, "{file} is missing"),
            Self::Size { file, expected, found } => {
                write!(f, "{file} has {found} bytes where {expected} were published")
            }
            Self::Checksum { file } => write!(f, "{file} isn't what was published"),
            Self::Read { path, source } => write!(f, "couldn't read {}: {source}", path.display()),
        }
    }
}

impl std::error::Error for VerifyError {}

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

/// When a file was last written, in nanoseconds since 1970; 0 where the system doesn't say.
fn modified_ns(metadata: &fs::Metadata) -> u64 {
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |since| u64::try_from(since.as_nanos()).unwrap_or(u64::MAX))
}

/// A file's SHA-256, in lowercase hex. `read` hears each run of bytes hashed.
pub fn sha256_of(path: &Path, read: &mut dyn FnMut(u64)) -> io::Result<String> {
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
        read(count as u64);
    }
    Ok(hex(&hasher.finalize()))
}

/// Bytes in lowercase hex, as SHA-256s are published.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Why a catalog couldn't be read.
#[derive(Debug, PartialEq, Eq)]
pub enum CatalogError {
    Unreadable(String),
    UnsupportedFormat(u64),
    Invalid { model: String, problem: String },
}

impl fmt::Display for CatalogError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unreadable(detail) => write!(f, "the speech model catalog can't be read: {detail}"),
            Self::UnsupportedFormat(format) => write!(
                f,
                "the speech model catalog is in format {format}, which this version can't read"
            ),
            Self::Invalid { model, problem } => write!(f, "the speech model catalog's {model}: {problem}"),
        }
    }
}

impl std::error::Error for CatalogError {}

impl SpeechModelCatalog {
    /// The catalog built into the app, for this platform. If it can't be read, which the tests
    /// rule out, it's empty, and the app still runs a model converted with the setup kit.
    pub fn bundled() -> &'static Self {
        static BUNDLED_CATALOG: OnceLock<SpeechModelCatalog> = OnceLock::new();
        BUNDLED_CATALOG.get_or_init(|| {
            Self::parse(BUNDLED, Platform::current()).unwrap_or_else(|error| {
                tracing::error!("No speech model catalog: {error}");
                Self::default()
            })
        })
    }

    /// Reads a catalog, keeping the models `platform` can download, and checks each is complete.
    pub fn parse(json: &str, platform: Platform) -> Result<Self, CatalogError> {
        let file: CatalogFile =
            serde_json::from_str(json).map_err(|error| CatalogError::Unreadable(error.to_string()))?;
        if file.format != FORMAT {
            return Err(CatalogError::UnsupportedFormat(file.format));
        }
        let mut ids = HashSet::new();
        let mut models = Vec::new();
        for entry in file.models {
            if !ids.insert(entry.id.clone()) {
                return Err(invalid(&entry.id, "is listed twice".to_owned()));
            }
            let section = match platform {
                Platform::Linux => entry.linux,
                Platform::Windows => entry.windows,
            };
            let Some(section) = section else { continue };
            let (engine, files, credit) = match section {
                Section::OpenVino {
                    repository,
                    revision,
                    files,
                    credit,
                } => (Engine::OpenVino { repository, revision }, files, credit),
                Section::SherpaOnnx {
                    family,
                    archive,
                    files,
                    credit,
                } => (Engine::SherpaOnnx { family, archive }, files, credit),
            };
            let model = SpeechModel {
                credit: credit.unwrap_or(entry.credit),
                id: entry.id,
                name: entry.name,
                summary: entry.summary,
                languages: entry.languages,
                licence: entry.licence,
                engine,
                files,
            };
            check(&model).map_err(|problem| invalid(&model.id, problem))?;
            models.push(model);
        }
        Ok(Self { models })
    }

    pub fn models(&self) -> &[SpeechModel] {
        &self.models
    }

    /// The model with `id`, if this platform has it.
    pub fn model(&self, id: &str) -> Option<&SpeechModel> {
        self.models.iter().find(|model| model.id == id)
    }
}

fn invalid(model: &str, problem: String) -> CatalogError {
    CatalogError::Invalid {
        model: model.to_owned(),
        problem,
    }
}

/// What a model must be for the app to download, check and open it.
fn check(model: &SpeechModel) -> Result<(), String> {
    let id_is_a_name = !model.id.is_empty()
        && !model.id.starts_with('.')
        && model
            .id
            .chars()
            .all(|character| character.is_ascii_lowercase() || character.is_ascii_digit() || ".-".contains(character));
    if !id_is_a_name {
        return Err("its id isn't a folder name of lowercase letters, digits, dots and dashes".to_owned());
    }
    if model.files.is_empty() {
        return Err("it has no files".to_owned());
    }
    let mut names = HashSet::new();
    for file in &model.files {
        let plain = !file.name.is_empty()
            && !file.name.starts_with('.')
            && !file.name.contains(['/', '\\', ':'])
            && !file.name.contains('\0');
        if !plain {
            return Err(format!("{:?} isn't a plain file name", file.name));
        }
        if !names.insert(file.name.as_str()) {
            return Err(format!("{} is listed twice", file.name));
        }
        if !is_sha256(&file.sha256) {
            return Err(format!("{}'s SHA-256 isn't 64 lowercase hex digits", file.name));
        }
    }
    match &model.engine {
        Engine::OpenVino { repository, revision } => {
            if repository.split('/').count() != 2 || repository.split('/').any(str::is_empty) {
                return Err(format!("{repository} isn't a Hugging Face repository"));
            }
            if revision.len() != 40 || !revision.chars().all(|digit| digit.is_ascii_hexdigit()) {
                return Err(format!("{revision} isn't a commit"));
            }
            if model.files.iter().any(|file| file.role.is_some()) {
                return Err("an OpenVINO model's files have no roles".to_owned());
            }
        }
        Engine::SherpaOnnx { family, archive } => {
            if !archive.url.starts_with("https://") || !archive.url.ends_with(".tar.bz2") {
                return Err(format!("{} isn't a .tar.bz2 to download over HTTPS", archive.url));
            }
            if !is_sha256(&archive.sha256) {
                return Err("its archive's SHA-256 isn't 64 lowercase hex digits".to_owned());
            }
            for role in model.files.iter().filter_map(|file| file.role) {
                if !family.roles().contains(&role) {
                    return Err(format!("a {family:?} model has no {role:?} file"));
                }
            }
            for role in family.roles() {
                let count = model.files.iter().filter(|file| file.role == Some(*role)).count();
                if count != 1 {
                    return Err(format!(
                        "it has {count} {role:?} files where a {family:?} model has one"
                    ));
                }
            }
        }
    }
    Ok(())
}

fn is_sha256(text: &str) -> bool {
    text.len() == 64
        && text
            .chars()
            .all(|digit| digit.is_ascii_digit() || ('a'..='f').contains(&digit))
}

/// The file's layout: every platform's models, of which this build keeps its own platform's.
#[derive(Deserialize)]
struct CatalogFile {
    format: u64,
    models: Vec<Entry>,
}

#[derive(Deserialize)]
struct Entry {
    id: String,
    name: String,
    summary: String,
    languages: String,
    licence: String,
    credit: String,
    linux: Option<Section>,
    windows: Option<Section>,
}

/// A model's section for a platform.
#[derive(Deserialize)]
#[serde(tag = "engine", deny_unknown_fields)]
enum Section {
    #[serde(rename = "openvino")]
    OpenVino {
        repository: String,
        revision: String,
        files: Vec<ModelFile>,
        /// The credit on this platform, where its conversion is someone else's.
        credit: Option<String>,
    },
    #[serde(rename = "sherpa-onnx")]
    SherpaOnnx {
        family: Family,
        archive: Archive,
        files: Vec<ModelFile>,
        credit: Option<String>,
    },
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("lt-catalog-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&folder);
        fs::create_dir_all(&folder).unwrap();
        folder
    }

    fn sha256(bytes: &[u8]) -> String {
        hex(&Sha256::digest(bytes))
    }

    /// A catalog of one sherpa-onnx model with `files` (name, contents, role).
    fn catalog_of(files: &[(&str, &[u8], Option<&str>)]) -> SpeechModelCatalog {
        let files: Vec<_> = files
            .iter()
            .map(|(name, contents, role)| {
                let mut file = json!({"name": name, "bytes": contents.len(), "sha256": sha256(contents)});
                if let Some(role) = role {
                    file["role"] = json!(role);
                }
                file
            })
            .collect();
        let section = json!({
            "engine": "sherpa-onnx",
            "family": "cohere-transcribe",
            "archive": {"url": "https://example.com/model.tar.bz2", "bytes": 10, "sha256": sha256(b"archive")},
            "files": files,
        });
        let text = json!({
            "format": 1,
            "models": [{
                "id": "test-model", "name": "Test", "summary": "For tests.", "languages": "English",
                "licence": "MIT", "credit": "Us", "linux": section, "windows": section,
            }],
        });
        SpeechModelCatalog::parse(&text.to_string(), Platform::Linux).unwrap()
    }

    fn cohere_files() -> Vec<(&'static str, &'static [u8], Option<&'static str>)> {
        vec![
            ("encoder.onnx", b"encoder", Some("encoder")),
            ("encoder.onnx.data", b"weights", None),
            ("decoder.onnx", b"decoder", Some("decoder")),
            ("tokens.txt", b"tokens", Some("tokens")),
        ]
    }

    fn write_files(folder: &Path, files: &[(&str, &[u8], Option<&str>)]) {
        for (name, contents, _) in files {
            fs::write(folder.join(name), contents).unwrap();
        }
    }

    #[test]
    fn the_bundled_catalog_is_readable_on_each_platform() {
        for platform in [Platform::Linux, Platform::Windows] {
            let catalog = SpeechModelCatalog::parse(BUNDLED, platform).unwrap();
            let ids: Vec<_> = catalog.models().iter().map(|model| model.id.as_str()).collect();
            assert_eq!(
                ids,
                [
                    "qwen3-asr-0.6b-sinhala",
                    "parakeet-tdt-0.6b-v2",
                    "parakeet-tdt-0.6b-v3",
                    "cohere-transcribe"
                ],
                "{platform:?}"
            );
        }
    }

    #[test]
    fn the_default_model_is_the_one_the_setup_kit_pins() {
        let catalog = SpeechModelCatalog::parse(BUNDLED, Platform::Linux).unwrap();
        let model = catalog.model("qwen3-asr-0.6b-sinhala").unwrap();
        assert_eq!(
            model.engine,
            Engine::OpenVino {
                repository: "Nerdstorm/Qwen3-ASR-0.6B-Sinhala-OpenVINO".to_owned(),
                revision: "8298d9b2d532965800b2c0c64b81965ededb03a3".to_owned(),
            }
        );
        assert_eq!(model.files.len(), 13);
        assert_eq!(model.download_bytes(), 1_136_316_063);
        assert_eq!(model.source(), "Hugging Face");
    }

    #[test]
    fn a_sherpa_model_has_its_archive_and_its_credit_for_the_platform() {
        let catalog = SpeechModelCatalog::parse(BUNDLED, Platform::Linux).unwrap();
        let model = catalog.model("cohere-transcribe").unwrap();
        let Engine::SherpaOnnx { family, archive } = &model.engine else {
            panic!("sherpa-onnx runs it");
        };
        assert_eq!(*family, Family::CohereTranscribe);
        assert_eq!(model.download_bytes(), archive.bytes);
        assert!(model.installed_bytes() > archive.bytes, "unpacked, it's bigger");
        assert!(model.credit.contains("sherpa-onnx"), "{}", model.credit);
        assert!(!model.credit.contains("MLX"), "the Mac's credit is the Mac's");
    }

    #[test]
    fn a_model_without_the_platforms_section_is_left_out() {
        let text = json!({
            "format": 1,
            "models": [{
                "id": "mac-only", "name": "Mac", "summary": "", "languages": "", "licence": "MIT",
                "credit": "", "mac": {"repository": "a/b", "revision": "c", "bytes": 1, "kind": "whisper"},
            }],
        });
        let catalog = SpeechModelCatalog::parse(&text.to_string(), Platform::Linux).unwrap();
        assert!(catalog.models().is_empty());
    }

    #[test]
    fn another_format_is_refused() {
        let error = SpeechModelCatalog::parse(r#"{"format": 2, "models": []}"#, Platform::Linux).unwrap_err();
        assert_eq!(error, CatalogError::UnsupportedFormat(2));
    }

    #[test]
    fn a_model_missing_a_file_its_family_needs_is_refused() {
        let text = json!({
            "format": 1,
            "models": [{
                "id": "parakeet", "name": "P", "summary": "", "languages": "", "licence": "MIT", "credit": "",
                "linux": {
                    "engine": "sherpa-onnx",
                    "family": "nemo-transducer",
                    "archive": {"url": "https://example.com/p.tar.bz2", "bytes": 1, "sha256": sha256(b"p")},
                    "files": [
                        {"name": "encoder.onnx", "bytes": 1, "sha256": sha256(b"e"), "role": "encoder"},
                        {"name": "decoder.onnx", "bytes": 1, "sha256": sha256(b"d"), "role": "decoder"},
                        {"name": "tokens.txt", "bytes": 1, "sha256": sha256(b"t"), "role": "tokens"},
                    ],
                },
            }],
        });
        let error = SpeechModelCatalog::parse(&text.to_string(), Platform::Linux).unwrap_err();
        assert!(error.to_string().contains("0 Joiner files"), "{error}");
    }

    #[test]
    fn a_file_name_that_isnt_plain_is_refused() {
        for name in ["../escape", "sub/file", ".hidden", ""] {
            let text = json!({
                "format": 1,
                "models": [{
                    "id": "bad", "name": "B", "summary": "", "languages": "", "licence": "MIT", "credit": "",
                    "linux": {
                        "engine": "openvino",
                        "repository": "a/b",
                        "revision": "8298d9b2d532965800b2c0c64b81965ededb03a3",
                        "files": [{"name": name, "bytes": 1, "sha256": sha256(b"x")}],
                    },
                }],
            });
            assert!(
                SpeechModelCatalog::parse(&text.to_string(), Platform::Linux).is_err(),
                "{name:?}"
            );
        }
    }

    #[test]
    fn a_folder_with_every_file_as_published_verifies_and_is_remembered() {
        let files = cohere_files();
        let catalog = catalog_of(&files);
        let model = &catalog.models()[0];
        let folder = scratch("verify");
        write_files(&folder, &files);
        assert!(model.is_in(&folder));

        let mut hashed = Vec::new();
        let verified = model
            .verify(&folder, &mut |done, total| hashed.push((done, total)))
            .unwrap();
        assert_eq!(verified.folder(), folder);
        assert_eq!(hashed.last(), Some(&(27, 27)), "every byte hashed");
        assert!(folder.join(VERIFIED_FILE).is_file());

        hashed.clear();
        model
            .verify(&folder, &mut |done, total| hashed.push((done, total)))
            .unwrap();
        assert!(hashed.is_empty(), "nothing hashed again: {hashed:?}");
        let _ = fs::remove_dir_all(folder);
    }

    #[test]
    fn a_changed_file_is_hashed_again_and_refused() {
        let files = cohere_files();
        let catalog = catalog_of(&files);
        let model = &catalog.models()[0];
        let folder = scratch("changed");
        write_files(&folder, &files);
        model.verify(&folder, &mut |_, _| {}).unwrap();

        // Same size, other contents, as another program would leave it. The time is set, since
        // a write this soon after the first can have the same time on a coarse clock.
        fs::write(folder.join("decoder.onnx"), b"DECODER").unwrap();
        File::options()
            .write(true)
            .open(folder.join("decoder.onnx"))
            .unwrap()
            .set_modified(std::time::SystemTime::now() + std::time::Duration::from_secs(5))
            .unwrap();
        let error = model.verify(&folder, &mut |_, _| {}).unwrap_err();
        assert!(
            matches!(&error, VerifyError::Checksum { file } if file == "decoder.onnx"),
            "{error}"
        );
        let _ = fs::remove_dir_all(folder);
    }

    #[test]
    fn a_missing_or_short_file_is_refused_without_hashing() {
        let files = cohere_files();
        let catalog = catalog_of(&files);
        let model = &catalog.models()[0];
        let folder = scratch("missing");
        write_files(&folder, &files[..3]);
        assert!(!model.is_in(&folder));
        let error = model
            .verify(&folder, &mut |_, _| panic!("nothing is hashed"))
            .unwrap_err();
        assert!(
            matches!(&error, VerifyError::Missing { file } if file == "tokens.txt"),
            "{error}"
        );

        fs::write(folder.join("tokens.txt"), b"tok").unwrap();
        let error = model
            .verify(&folder, &mut |_, _| panic!("nothing is hashed"))
            .unwrap_err();
        assert_eq!(error.to_string(), "tokens.txt has 3 bytes where 6 were published");
        let _ = fs::remove_dir_all(folder);
    }

    #[test]
    fn a_new_pin_checks_the_files_again() {
        let files = cohere_files();
        let folder = scratch("new-pin");
        write_files(&folder, &files);
        catalog_of(&files).models()[0].verify(&folder, &mut |_, _| {}).unwrap();

        // The same names and sizes, published with other contents.
        let mut republished = files.clone();
        republished[2].1 = b"DECODER";
        let catalog = catalog_of(&republished);
        let error = catalog.models()[0].verify(&folder, &mut |_, _| {}).unwrap_err();
        assert!(matches!(error, VerifyError::Checksum { .. }), "{error}");
        let _ = fs::remove_dir_all(folder);
    }
}
