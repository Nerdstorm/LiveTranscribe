//! Unpacking a model's files from the `.tar.bz2` archive sherpa-onnx publishes it in: only the
//! files the catalog lists, from the archive's top folder, each written under its catalog name.
//! Nothing else in the archive (its test clips, its README) is written, and no path in it is
//! followed, so an archive can't write outside the model's folder.

use std::cell::Cell;
use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufReader, Read, Write};
use std::path::{Component, Path};
use std::rc::Rc;

use lt_transcription::catalog::ModelFile;
use tar::EntryType;

use super::fetch::{DownloadError, Progress, Reporter, Stage, disk};

/// Unpacks `files` from `archive` into `folder`, reporting how much of the archive has been read.
/// Each file must be in the archive's top folder at its catalog size; its contents are checked
/// later, with the rest of the model's.
pub(crate) fn unpack(
    archive: &Path,
    files: &[ModelFile],
    folder: &Path,
    progress: &mut dyn FnMut(Progress) -> bool,
) -> Result<(), DownloadError> {
    let name = archive
        .file_name()
        .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
    let unreadable = |problem: String| DownloadError::Unpack {
        archive: name.clone(),
        problem,
    };
    let input = File::open(archive).map_err(|source| disk(archive, source))?;
    let total = input.metadata().map_err(|source| disk(archive, source))?.len();
    let read = Rc::new(Cell::new(0));
    let counted = Counted {
        inner: BufReader::with_capacity(1 << 20, input),
        read: Rc::clone(&read),
    };
    let mut entries = tar::Archive::new(bzip2::read::MultiBzDecoder::new(counted));
    let mut wanted: HashMap<&str, &ModelFile> = files.iter().map(|file| (file.name.as_str(), file)).collect();
    let mut reporter = Reporter::new(Stage::Unpacking, total, progress);
    for entry in entries.entries().map_err(|error| unreadable(error.to_string()))? {
        let mut entry = entry.map_err(|error| unreadable(error.to_string()))?;
        let path = entry
            .path()
            .map_err(|error| unreadable(error.to_string()))?
            .into_owned();
        let Some(file) = top_folder_file(&path).and_then(|name| wanted.remove(name)) else {
            continue;
        };
        if entry.header().entry_type() != EntryType::Regular {
            return Err(unreadable(format!("its {} isn't a file", file.name)));
        }
        let size = entry.header().size().map_err(|error| unreadable(error.to_string()))?;
        if size != file.bytes {
            return Err(unreadable(format!(
                "its {} has {size} bytes where {} were published",
                file.name, file.bytes
            )));
        }
        let destination = folder.join(&file.name);
        let mut output = File::create(&destination).map_err(|source| disk(&destination, source))?;
        let mut buffer = vec![0; 1 << 20];
        loop {
            let count = match entry.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => count,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(unreadable(error.to_string())),
            };
            output
                .write_all(&buffer[..count])
                .map_err(|source| disk(&destination, source))?;
            reporter.current = read.get();
            if !reporter.report(false) {
                return Err(DownloadError::Stopped);
            }
        }
        output.flush().map_err(|source| disk(&destination, source))?;
        if wanted.is_empty() {
            // The rest of the archive is test clips and the like.
            break;
        }
    }
    if let Some(name) = wanted.keys().min() {
        return Err(unreadable(format!("it has no {name}")));
    }
    reporter.current = total;
    reporter.report(true);
    Ok(())
}

/// The name of a file in the archive's top folder (`folder/name`), if `path` is one.
fn top_folder_file(path: &Path) -> Option<&str> {
    let mut components = path.components();
    let (Some(Component::Normal(_)), Some(Component::Normal(name)), None) =
        (components.next(), components.next(), components.next())
    else {
        return None;
    };
    name.to_str()
}

/// Counts the bytes read through it, which is how far into the archive the unpacking has got.
struct Counted<R> {
    inner: R,
    read: Rc<Cell<u64>>,
}

impl<R: Read> Read for Counted<R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let count = self.inner.read(buffer)?;
        self.read.set(self.read.get() + count as u64);
        Ok(count)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::fs;
    use std::path::PathBuf;

    use lt_transcription::catalog::hex;
    use sha2::{Digest, Sha256};

    use super::*;

    /// A `.tar.bz2` of `entries` (paths and contents), as sherpa-onnx packs its models.
    pub(crate) fn tar_bz2(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let encoder = bzip2::write::BzEncoder::new(Vec::new(), bzip2::Compression::fast());
        let mut builder = tar::Builder::new(encoder);
        for (path, contents) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_size(contents.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            builder.append_data(&mut header, path, *contents).unwrap();
        }
        builder.into_inner().unwrap().finish().unwrap()
    }

    pub(crate) fn model_file(name: &str, contents: &[u8]) -> ModelFile {
        ModelFile {
            name: name.to_owned(),
            bytes: contents.len() as u64,
            sha256: hex(&Sha256::digest(contents)),
            role: None,
        }
    }

    fn scratch(name: &str) -> PathBuf {
        let folder = std::env::temp_dir().join(format!("lt-archive-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&folder);
        fs::create_dir_all(&folder).unwrap();
        folder
    }

    #[test]
    fn only_the_models_files_are_unpacked() {
        let folder = scratch("unpack");
        let archive = folder.join("model.tar.bz2");
        fs::write(
            &archive,
            tar_bz2(&[
                ("model/README.md", b"read me"),
                ("model/encoder.onnx", b"encoder"),
                ("model/test_wavs/0.wav", b"clip"),
                ("model/tokens.txt", b"tokens"),
            ]),
        )
        .unwrap();
        let into = folder.join("unpacked");
        fs::create_dir_all(&into).unwrap();
        let files = [
            model_file("encoder.onnx", b"encoder"),
            model_file("tokens.txt", b"tokens"),
        ];
        let mut heard = Vec::new();
        unpack(&archive, &files, &into, &mut |progress| {
            heard.push(progress);
            true
        })
        .unwrap();
        let mut names: Vec<_> = fs::read_dir(&into)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        assert_eq!(names, ["encoder.onnx", "tokens.txt"]);
        assert_eq!(fs::read(into.join("tokens.txt")).unwrap(), b"tokens");
        let last = heard.last().unwrap();
        assert_eq!((last.stage, last.percent()), (Stage::Unpacking, 100));
        let _ = fs::remove_dir_all(folder);
    }

    #[test]
    fn a_file_missing_from_the_archive_or_of_another_size_is_refused() {
        let folder = scratch("refused");
        let archive = folder.join("model.tar.bz2");
        fs::write(&archive, tar_bz2(&[("model/encoder.onnx", b"encoder")])).unwrap();
        let missing = unpack(
            &archive,
            &[
                model_file("encoder.onnx", b"encoder"),
                model_file("tokens.txt", b"tokens"),
            ],
            &folder,
            &mut |_| true,
        )
        .unwrap_err();
        assert_eq!(
            missing.to_string(),
            "couldn't unpack model.tar.bz2: it has no tokens.txt"
        );

        let resized = unpack(
            &archive,
            &[model_file("encoder.onnx", b"encoder!")],
            &folder,
            &mut |_| true,
        )
        .unwrap_err();
        assert!(
            resized.to_string().contains("has 7 bytes where 8 were published"),
            "{resized}"
        );
        let _ = fs::remove_dir_all(folder);
    }

    #[test]
    fn nothing_outside_the_top_folder_is_taken() {
        assert_eq!(top_folder_file(Path::new("model/tokens.txt")), Some("tokens.txt"));
        assert_eq!(top_folder_file(Path::new("tokens.txt")), None);
        assert_eq!(top_folder_file(Path::new("model/sub/tokens.txt")), None);
        assert_eq!(top_folder_file(Path::new("../tokens.txt")), None);
        assert_eq!(top_folder_file(Path::new("/model/tokens.txt")), None);
    }

    #[test]
    fn a_damaged_archive_says_so() {
        let folder = scratch("damaged");
        let archive = folder.join("model.tar.bz2");
        fs::write(&archive, b"BZh9 not really").unwrap();
        let error = unpack(&archive, &[model_file("tokens.txt", b"tokens")], &folder, &mut |_| true).unwrap_err();
        assert!(matches!(error, DownloadError::Unpack { .. }), "{error}");
        let _ = fs::remove_dir_all(folder);
    }
}
