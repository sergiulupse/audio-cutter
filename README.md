<div align="center">

# Audio Cutter

**Open an audio file, drag over the part you want, export it. That is the whole app.**

A small, fast, free audio editor for macOS. No subscription, no account, no
upload, no 400 MB download. It opens instantly, it cuts, it exports, it gets out
of the way.

[Install](#install) · [What it does](#what-it-does) · [Build it yourself](#build-it-yourself) · [Design notes](DESIGN-NOTES.md)

</div>

---

## Why this exists

Cutting thirty seconds out of an MP3 should take ten seconds and cost nothing.
Instead the best tool for it is paid, the free ones are either browser toys or
full studio suites where the trim is buried six menus deep, and the online ones
want you to upload your audio to a stranger's server.

So: a single-window app that does the one job. Written from scratch in Swift with
no external libraries at all, on Apple's own audio frameworks. The whole thing is
a few thousand lines you can read in an afternoon.

Vibe-coded with [Claude Code](https://claude.com/claude-code). Free under the MIT
licence. Use it, fork it, ship it. No credit required, though it is always
welcome.

---

## Install

**macOS 14 (Sonoma) or later. Apple Silicon or Intel.**

Grab the `.dmg` from the [Releases](../../releases) page, open it, and drag
**Audio Cutter** to your Applications folder.

### The first launch will be blocked. Here is how to get past it

macOS will refuse to open it and say:

> **"Audio Cutter.app" Not Opened.** Apple could not verify "Audio Cutter.app" is
> free of malware that may harm your Mac or compromise your privacy.

with only **Done** and **Move to Trash** as options. That is expected, and it is
not really about this app. macOS blocks *any* app that has not been through
Apple's notarization service, which costs $99 a year. This is free software and
has not paid for it. Nothing about the warning means malware was found: it means
nobody paid Apple to check.

Click **Done** (not Move to Trash), then:

1. Open **System Settings** and go to **Privacy & Security**
2. Scroll to the **Security** section near the bottom. You will see
   *"Audio Cutter.app" was blocked to protect your Mac.* Click **Open Anyway**
3. A second dialog asks *Open "Audio Cutter.app"?* Click **Open Anyway** again
4. macOS asks for an administrator username and password. Enter it and click
   **OK**

The app opens, and you are never asked again. Yes, it is four steps and two
identical-looking warnings. That is Apple's design, not enthusiasm on our part.

Two things worth knowing:

- The **Open Anyway** button only shows for about an hour after the warning. If
  it is not there, double-click the app again to trigger the warning and go
  straight back to Privacy & Security.
- On **macOS 15 Sequoia and later**, the old trick of right-clicking the app and
  choosing Open no longer works. Apple removed it. Any guide still telling you to
  do that is out of date.

### Two ways to skip the warning entirely

**Build it yourself.** Apps you compile on your own machine are never flagged as
downloaded, so there is no warning at all. It takes one command and about thirty
seconds:

```bash
git clone https://github.com/sergiulupse/audio-cutter.git
cd audio-cutter && ./build.sh
```

**Or clear the flag from the terminal**, after dragging the app to Applications:

```bash
xattr -dr com.apple.quarantine "/Applications/Audio Cutter.app"
```

That removes the "downloaded from the internet" mark macOS attaches to the file.
It is the standard fix for unnotarized open-source Mac apps, and it is also
exactly what someone distributing malware would tell you to run. Only do it for
software you can inspect, which is the entire reason the source is here.

**Optional:** install [ffmpeg](https://ffmpeg.org) for MP3 support.

```bash
brew install ffmpeg
```

Everything else works without it. Apple removed the MP3 encoder from macOS years
ago, so MP3 writing (and lossless MP3 cutting) is the one thing that needs an
outside tool. The app says so plainly rather than quietly handing you a different
format.

---

## What it does

**Opens** MP3, WAV, FLAC, AIFF, M4A/AAC and CAF. Drop a file on the window, press
⌘O, or double-click it in Finder.

**Selects** by dragging across the waveform. The audio scrubs under your cursor as
you drag, tape style, so you hear exactly where the edges are landing. Click to
place the playhead, double-click to select everything, drag the thin ruler on top
to scrub without selecting. Any real drag selects, however short.

**Cuts** with the two buttons that carry the whole app:

- **Keep** (⌘K) throws away everything outside the selection.
- **Delete** (Delete) removes the selection and splices the gap shut.

**Exports** (⌘E) to WAV or AIFF at 24-bit, FLAC, M4A/AAC, or MP3.

**Regions.** ⌘M marks a selection and remembers it. The Regions menu then deletes
every marked region at once, or exports each one as its own numbered file, which
is how you chop a long recording into pieces.

**Cleans up.** Normalize, fade in, fade out, silence a range, reverse a range, and
trim the silence off both ends of the clip.

**Plays** at 0.25x to 4x, with a `2x` toggle for the common case and J / K / L
shuttle keys on a 1 to 2 to 4 ladder, the same as every editor from Avid to
Resolve. Speed is tape speed, so pitch moves with it. That is deliberate:
pitch-preserving stretching smears the transients you are trying to cut on.

**Moves around** with the scroll wheel (zooms around the pointer), sideways scroll
or the slider (pans), or a pinch. Resizing the window keeps the waveform filling
it.

### Three details that matter more than they sound

**Lossless cutting.** Trimming an MP3 and exporting MP3 normally means
re-compressing already-compressed audio, which audibly wears it out. When nothing
has been edited, this app copies the encoded frames straight out of the original
file instead, so what comes out is bit-for-bit what went in. The status line reads
`lossless ready` when that is available. The one catch, stated plainly: compressed
audio lives in frames of about 26 ms which cannot be split, so the cut lands on
the nearest frame rather than the exact sample. If you need sample accuracy,
export WAV or FLAC, or switch the option off in the Clean up menu.

**Zero-crossing snap.** A cut in the middle of a waveform leaves a vertical step,
and a step is an audible click. Cuts snap to the nearest point where the sound
passes through silence, searching at most 8 ms, and give up rather than wander if
there is nothing there. Behind that, a 4 ms fade at every cut boundary covers the
case snapping cannot win.

**Stereo is two lanes, L above R.** Several editors merge stereo into a single
waveform. This one does not.

---

## Keyboard

| | |
|---|---|
| Space | play / pause |
| K | pause |
| L | play forwards. Press again for 2x, again for 4x |
| J | play backwards. Press again for 2x, again for 4x |
| Delete | remove the selection |
| ← → | nudge the playhead by 0.1 s, or 1 s with Shift |
| Return | back to start |
| Escape | clear selection |
| ⌘O | open |
| ⌘K | keep selection |
| ⌘E | export |
| ⌘M | mark region |
| ⌘A | select all |
| ⌘Z | undo |
| ⌘0 | fit the whole clip |

J / K / L are the shuttle keys shared by every professional editor, so your hands
may already know them.

---

## Build it yourself

Needs macOS 14 or later, and Xcode or just the Command Line Tools.

```bash
git clone <this-repo>
cd Audio-Cutter
./build.sh
```

That compiles, draws the icon, wraps the binary in a real `.app`, ad-hoc signs it,
and launches it. The result is in `build/`.

```bash
./build.sh debug      # faster compile, no optimisation
./build.sh --no-run   # build without launching
./build.sh --icon     # redraw the app icon first
./build.sh --dmg      # also produce a distributable .dmg
```

Check the audio engine without opening a window:

```bash
./Tests/HeadlessCheck/run.sh
```

That is 28 assertions over decoding, snapping, cutting, undo, normalising, silence
trimming, lossless cutting and every export format. Checks that need ffmpeg skip
themselves when it is absent.

There is a second suite for playback, which needs a real audio device and plays
about two seconds of tone:

```bash
./Tests/TransportCheck/run.sh
```

It drives the transport the way fingers do (play, change direction mid-playback,
pause) and exists because of a real bug: cancelling one playback pass used to
tear down the pass that replaced it, leaving audio running that the app thought
was stopped. It skips itself on a machine with no audio output.

### How the code is laid out

| File | What lives there |
|---|---|
| `AudioClip.swift` | The document: samples in memory, every edit, undo, the drawing summary |
| `Snapping.swift` | Zero-crossing search |
| `PlaybackEngine.swift` | Playback, backwards playback, speed, drag-to-hear scrubbing |
| `Exporter.swift` | Writing WAV / AIFF / FLAC / M4A natively, MP3 and lossless cuts via ffmpeg |
| `WaveformView.swift` | Waveform drawing, ruler, selection, all mouse handling |
| `EditorView.swift` | The window, toolbar, and every action wired together |
| `InputMonitors.swift` | Scroll wheel and bare keys, which SwiftUI cannot provide |
| `AppDelegate.swift` | Files opened from Finder or the Dock |
| `Theme.swift` | Every colour in one place |
| `Resources/make-icon.swift` | Draws the app icon at all ten sizes, then packs the .icns |

Both test suites live in `Tests/`, are plain Swift compiled on the spot by a
shell script, and need no test framework.

Every file opens with a plain-language explanation of what it does and why,
written for someone who is not an audio programmer. An audio file is just a very
long list of numbers between -1 and +1; once it is a plain array, "keep this bit"
is array surgery and nothing more.

---

## Known limits

[DESIGN-NOTES.md](DESIGN-NOTES.md) has the honest version, including which claims
were measured and which were only reasoned about. The short list:

- **Undo is capped by memory.** Audio costs about 21 MB per minute of stereo in
  RAM and each undo step is a full copy, so the history is limited to 1.5 GB. On
  a 30-minute file that is roughly two undo steps rather than twenty-four. The
  status line shows how many you have.
- **Edits apply to both channels.** You can see L and R separately but not edit
  them independently.
- **No auto-split on silence**, only manual region marking, plus trim-silence for
  the two ends.
- **No noise reduction.** That is a different app.
- **One file at a time.** One window, one clip.
- **macOS only.** It sits directly on SwiftUI and AVFoundation, so Windows or
  Linux would be a rewrite, not a port.

---

## Contributing

Bug reports are genuinely welcome, especially about how it *sounds*: no automated
test can hear a click. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

MIT. See [LICENSE](LICENSE).
