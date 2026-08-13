#!/bin/bash
#
# run.sh  ::  check the parts of Audio Cutter that do not need a window.
#
# This compiles the model, snapping and export code together with a small
# throwaway program that puts them through their paces, then runs it against
# real audio files generated on the spot. It covers the chain that actually
# matters: decode a file, cut it, write it back out, read it again.
#
# ffmpeg is optional. Without it the WAV fixtures are still generated (with
# python3, which every Mac has) and the MP3, FLAC and lossless-cut checks are
# skipped rather than failed. With it, everything runs.
#
# The UI is not covered here. Windows and mouse gestures have to be checked by
# hand, by using the app.
#
#   ./Tests/HeadlessCheck/run.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/Sources/AudioCutter"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Use the full Xcode toolchain when it is installed.
if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

cd "$WORK"

echo "> Generating test audio..."

# WAV fixtures, written by hand so no external tool is needed:
#   test.wav    2 s stereo, 440 Hz left and 880 Hz right
#   padded.wav  1 s of tone with 1 s of silence on each side
#   silent.wav  2 s of nothing at all
python3 - <<'PYTHON'
import math, struct, wave

RATE = 44100

def write(path, blocks):
    """blocks: list of (seconds, left_hz or None, right_hz or None)"""
    with wave.open(path, "w") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for seconds, left_hz, right_hz in blocks:
            for i in range(int(seconds * RATE)):
                t = i / RATE
                l = 0.0 if left_hz is None else 0.5 * math.sin(2 * math.pi * left_hz * t)
                r = 0.0 if right_hz is None else 0.5 * math.sin(2 * math.pi * right_hz * t)
                frames += struct.pack("<hh", int(l * 32767), int(r * 32767))
        w.writeframes(bytes(frames))

write("test.wav",   [(2.0, 440, 880)])
write("padded.wav", [(1.0, None, None), (1.0, 440, 440), (1.0, None, None)])
write("silent.wav", [(2.0, None, None)])
PYTHON

if command -v ffmpeg >/dev/null; then
  echo "  ffmpeg found: adding MP3 and FLAC fixtures"
  ffmpeg -hide_banner -loglevel error -y -i test.wav -c:a libmp3lame -b:a 192k test.mp3
  ffmpeg -hide_banner -loglevel error -y -i test.wav -c:a flac test.flac
else
  echo "  ffmpeg not installed: MP3, FLAC and lossless-cut checks will be skipped"
fi

echo "> Compiling checks..."
cp "$HERE/main.swift" .
swiftc -O -o checker main.swift \
  "$SRC/AudioClip.swift" \
  "$SRC/Snapping.swift" \
  "$SRC/Exporter.swift" \
  "$SRC/PlaybackEngine.swift"

echo "> Running..."
./checker
