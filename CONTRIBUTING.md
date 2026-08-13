# Contributing

This is a small app with a deliberately small scope: open one audio file, cut it,
export it. That sentence is the filter for every change.

## The most useful thing you can report

**How it sounds.** No automated test can hear a click, a stutter, or swapped
channels. The scrubbing engine in particular has been reasoned about carefully and
listened to very little. If something sounds wrong, that is the most valuable
issue this project can receive. Please include:

- what you did (drag, cut, export, which speed)
- the file's sample rate, channel count and format, which the status line shows
- what you heard

Sample rates other than 44.1 kHz, and mono files, are the least travelled paths.

## Before opening a pull request

Run the checks:

```bash
./Tests/HeadlessCheck/run.sh
```

They need no ffmpeg (the checks that do skip themselves) and take a few seconds.
Adding an assertion for whatever you fixed is welcome. So is deleting one that
turns out to prove nothing, which has already happened once: see the comment
above the undo-history check.

Then build and actually use it:

```bash
./build.sh
```

## House style, such as it is

- **Comments explain why, not what.** Every file opens with a plain-language
  explanation aimed at someone who is not an audio programmer. Keep that.
- **No dependencies.** The app uses only AVFoundation and SwiftUI. ffmpeg is
  optional and shelled out to, never linked. A pull request that adds a package
  needs a strong reason.
- **State the catch.** Where a feature has a real cost (lossless cutting landing
  on frame boundaries, undo history shrinking on long files), say so in the UI and
  in the docs rather than hoping nobody notices.
- **Measure, do not assert.** If a change is about performance or memory, include
  the number you measured.

## Things that will be declined, kindly

Multi-track mixing, effects racks, VST hosting, a plugin system, noise reduction,
cloud anything, telemetry. Not because they are bad, but because they are a
different application. Per-channel editing and auto-split on silence are the two
absent features most likely to be accepted.
