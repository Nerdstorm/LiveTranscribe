#!/bin/zsh
# Generates the integration-test and bench audio clips with macOS text-to-speech.
#
# The clips are not committed: they are synthesised locally from the reference transcripts in
# Packages/LiveTranscribeKit/Tests/IntegrationTests/Fixtures/Audio/*.txt, as 16 kHz mono 16-bit WAV.
# Run this before the integration tests or the bench. Re-running overwrites the clips.
set -euo pipefail

audio_dir="${0:A:h}/../Packages/LiveTranscribeKit/Tests/IntegrationTests/Fixtures/Audio"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# A pause between sentences gives the voice activity detector a segment boundary.
pause='[[slnc 1200]]'

# Name and spoken text of each clip. The spoken text is the reference transcript plus pauses.
typeset -A spoken
spoken[clip01_meeting]="I think we should probably meet on Tuesday. $pause Maybe around three o'clock, if that works for you."
spoken[clip02_report]="The quarterly report is due next Friday. $pause Please send me your numbers by Wednesday, so I can review them before the call."
spoken[clip03_build]="So the main issue is that the build keeps failing on the release branch. $pause I'm not totally sure why, but I suspect the cache."
spoken[clip04_longform]="When we moved the service to the new cluster last month, the latency went up a little at first, but after we tuned the connection pool and turned on caching for the most common queries, it came back down, and now it is actually faster than it was before the move."

# Samantha (US English) ships with macOS; fall back to the system voice if it is missing.
voice_args=()
if say -v '?' | grep -q '^Samantha'; then
  voice_args=(-v Samantha)
fi

for name in ${(ok)spoken}; do
  reference_file="$audio_dir/$name.txt"
  if [[ ! -f "$reference_file" ]]; then
    print -u2 "Missing reference transcript: $reference_file"
    exit 1
  fi
  # The clip must say exactly the reference transcript, or the WER checks measure the wrong thing.
  expected="$(<"$reference_file")"
  actual="${spoken[$name]//$pause /}"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 "Spoken text for $name does not match $reference_file"
    exit 1
  fi
  say "${voice_args[@]}" -o "$work_dir/$name.aiff" "${spoken[$name]}"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$work_dir/$name.aiff" "$audio_dir/$name.wav"
  print "Wrote $name.wav ($(afinfo "$audio_dir/$name.wav" | awk '/estimated duration/ { printf "%.1f s", $3 }'))"
done
