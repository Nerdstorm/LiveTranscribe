#!/bin/zsh
# Generates the dictation eval clips with macOS text-to-speech.
#
# Each line of Packages/LiveTranscribeKit/Tests/IntegrationTests/Fixtures/Dictation/clips.tsv
# (id, category, spoken, intended) becomes <id>.wav in the same folder: 16 kHz mono 16-bit WAV of
# the spoken column. The clips are not committed. Run this before `Bench --dictation`.
# Re-running overwrites the clips.
set -euo pipefail

clip_dir="${0:A:h}/../Packages/LiveTranscribeKit/Tests/IntegrationTests/Fixtures/Dictation"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# Samantha (US English) ships with macOS; fall back to the system voice if it is missing.
voice_args=()
if say -v '?' | grep -q '^Samantha'; then
  voice_args=(-v Samantha)
fi

count=0
while IFS=$'\t' read -r id category spoken intended; do
  [[ -z "$id" || "$id" == \#* ]] && continue
  if [[ -z "$spoken" || -z "$intended" ]]; then
    print -u2 "Malformed line for $id in clips.tsv"
    exit 1
  fi
  say "${voice_args[@]}" -o "$work_dir/$id.aiff" "$spoken"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$work_dir/$id.aiff" "$clip_dir/$id.wav"
  count=$((count + 1))
done < "$clip_dir/clips.tsv"
print "Wrote $count clips to $clip_dir"
