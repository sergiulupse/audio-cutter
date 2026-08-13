#!/bin/bash
#
# run.sh  ::  check playback transport against a real audio engine.
#
# Separate from the headless checks because these need an actual audio output
# device: they start AVAudioEngine and watch the playhead move in real time.
# On a machine without one (a CI runner, a headless Mac) they skip themselves.
#
# What they cover: starting, changing direction, pausing, and above all that one
# playback pass replacing another does not leave the app playing audio it thinks
# it has stopped. See the comment at the top of main.swift.
#
#   ./Tests/TransportCheck/run.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/Sources/AudioCutter"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

cd "$WORK"

echo "> Generating test audio..."
python3 - <<'PYTHON'
import math, struct, wave

RATE = 44100
with wave.open("test.wav", "w") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(RATE)
    frames = bytearray()
    for i in range(2 * RATE):
        t = i / RATE
        left = 0.5 * math.sin(2 * math.pi * 440 * t)
        right = 0.5 * math.sin(2 * math.pi * 880 * t)
        frames += struct.pack("<hh", int(left * 32767), int(right * 32767))
    w.writeframes(bytes(frames))
PYTHON

echo "> Compiling checks..."
cp "$HERE/main.swift" .
swiftc -O -o transport main.swift \
  "$SRC/AudioClip.swift" \
  "$SRC/Snapping.swift" \
  "$SRC/Exporter.swift" \
  "$SRC/PlaybackEngine.swift"

echo "> Running (this plays audio for about two seconds)..."
./transport
