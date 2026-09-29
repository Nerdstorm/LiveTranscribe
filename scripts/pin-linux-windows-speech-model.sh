#!/bin/zsh
# Prints a speech model's "linux" (and "windows") section of speech-models.json: each file the
# Linux and Windows app downloads, with its size and SHA-256, which the app checks before it opens
# the model. Pin a model, or move its pin, with this; then try it with
# `livetranscribe transcribe --model <id>`, and bench it, before it goes in the catalog.
#
#   scripts/pin-linux-windows-speech-model.sh openvino Nerdstorm/Qwen3-ASR-0.6B-Sinhala-OpenVINO [revision]
#   scripts/pin-linux-windows-speech-model.sh sherpa-onnx nemo-transducer sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8
#
# An OpenVINO model is a Hugging Face repository the setup kit's export uploaded, at its latest
# commit or the one given. A sherpa-onnx model is an archive of sherpa-onnx's asr-models release: it
# is downloaded (up to a few GB) into a temporary folder, checked against the release's
# checksum.txt, and unpacked to hash each file. Its files' roles are guessed from their names, and
# its credit is left to write: check both.
set -euo pipefail

usage() {
  print -u2 -r -- "usage: scripts/pin-linux-windows-speech-model.sh openvino <owner/name> [revision]"
  print -u2 -r -- "       scripts/pin-linux-windows-speech-model.sh sherpa-onnx <family> <archive name>"
  exit 2
}

(( $# >= 2 )) || usage
engine=$1
shift

case $engine in
  openvino)
    (( $# <= 2 )) && [[ $1 == ?*/?* ]] || usage
    python3 - "$1" "${2:-main}" <<'EOF'
import hashlib, json, sys, urllib.request

repository, revision = sys.argv[1], sys.argv[2]
def get(url):
    with urllib.request.urlopen(url) as response:
        return response.read()

commit = json.loads(get(f"https://huggingface.co/api/models/{repository}/revision/{revision}"))["sha"]
tree = json.loads(get(f"https://huggingface.co/api/models/{repository}/tree/{commit}"))
# The model's files, as the export writes them; the manifest last, as a folder with one is a model.
skipped = {".gitattributes", "README.md"}
files = []
for entry in sorted(tree, key=lambda entry: (entry["path"] == "manifest.json", entry["path"])):
    name = entry["path"]
    if entry["type"] != "file" or name in skipped or name.startswith("LICENSE"):
        continue
    lfs = entry.get("lfs")
    sha256 = lfs["oid"] if lfs else hashlib.sha256(get(f"https://huggingface.co/{repository}/resolve/{commit}/{name}")).hexdigest()
    files.append({"name": name, "bytes": entry["size"], "sha256": sha256})
lines = ",\n".join(f"    {json.dumps(file)}" for file in files)
print(f'{{\n  "engine": "openvino",\n  "repository": "{repository}",\n  "revision": "{commit}",\n  "files": [\n{lines}\n  ]\n}}')
EOF
    ;;
  sherpa-onnx)
    (( $# == 2 )) || usage
    family=$1
    archive=${2%.tar.bz2}.tar.bz2
    url=https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$archive
    folder=$(mktemp -d)
    trap 'rm -rf "$folder"' EXIT
    expected=$(curl -fsSL https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/checksum.txt |
      awk -v name="$archive" '$1 == name { print $2 }')
    [[ -n $expected ]] || { print -u2 -r -- "$archive isn't in the asr-models release's checksum.txt"; exit 1 }
    print -u2 -r -- "Downloading $url"
    curl -fL --retry 3 --progress-bar --output "$folder/$archive" "$url"
    python3 - "$folder/$archive" "$url" "$expected" "$family" <<'EOF'
import hashlib, json, os, sys, tarfile

path, url, expected, family = sys.argv[1:]
def sha256_of(stream):
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(1 << 20), b""):
        digest.update(block)
    return digest.hexdigest()

with open(path, "rb") as stream:
    actual = sha256_of(stream)
if actual != expected:
    sys.exit(f"{os.path.basename(path)} is {actual}, where checksum.txt says {expected}")

def role(name):
    if name == "tokens.txt":
        return "tokens"
    if name.endswith(".onnx"):
        for part in ("encoder", "decoder", "joiner"):
            if part in name:
                return part
    return None

files = []
with tarfile.open(path, "r:bz2") as archive:
    for member in archive:
        parts = member.name.split("/")
        # The model's files are in the archive's top folder; its README and test clips aren't needed.
        if not member.isfile() or len(parts) != 2 or parts[1] == "README.md":
            continue
        file = {"name": parts[1], "bytes": member.size, "sha256": sha256_of(archive.extractfile(member))}
        if role(parts[1]):
            file["role"] = role(parts[1])
        files.append(file)
lines = ",\n".join(f"    {json.dumps(file)}" for file in files)
print(f'''{{
  "engine": "sherpa-onnx",
  "family": "{family}",
  "archive": {{
    "url": "{url}",
    "bytes": {os.path.getsize(path)},
    "sha256": "{actual}"
  }},
  "files": [
{lines}
  ],
  "credit": "(who made it, and that sherpa-onnx converted it)"
}}''')
EOF
    ;;
  *)
    usage
    ;;
esac
