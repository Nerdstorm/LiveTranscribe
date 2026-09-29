#!/bin/zsh
# Prints what a speech model's "mac" entry in speech-models.json pins: the Hugging Face
# repository's latest commit, the size of the files the app downloads from it (the patterns in
# SpeechModelDownloads.swift), and the model_type its config.json names. Bump a model to a new
# commit with these, after trying it with make bench ARGS="--stt-model <repository>".
#
#   scripts/pin-speech-model.sh mlx-community/parakeet-tdt-0.6b-v3
set -euo pipefail

(( $# == 1 )) && [[ $1 == ?*/?* ]] || { print -u2 -r -- "usage: scripts/pin-speech-model.sh <owner/name>"; exit 2 }

curl -fsSL "https://huggingface.co/api/models/$1?blobs=true" | python3 -c '
import fnmatch, json, sys, urllib.request

info = json.load(sys.stdin)
patterns = ["*.safetensors", "*.json", "*.txt", "*.wav", "*.model", "*.mvn", "tokenizer*", "tokenizer.*"]
size = sum(f.get("size") or 0 for f in info.get("siblings", [])
           if any(fnmatch.fnmatch(f["rfilename"], p) for p in patterns))
repository, commit = info["id"], info["sha"]
with urllib.request.urlopen(f"https://huggingface.co/{repository}/resolve/{commit}/config.json") as response:
    config = json.load(response)
kind = config.get("model_type") or config.get("architecture") or config.get("model_version")
print(json.dumps({
    "repository": repository,
    "revision": commit,
    "bytes": size,
    "kind": kind or "(none: the repository name must name it)",
}, indent=2))
'
