# Design notes

The honest account of how this app could fail, written as a pre-mortem on the day
it was built: assume it is three months from now and nobody uses it, work
backwards, name the reasons, fix what is worth fixing and write down what is being
accepted knowingly.

Kept in the repo because it is more useful than a changelog. If you are deciding
whether to trust this app with your audio, this is the page to read.

Numbers below were measured, not estimated. Where something was only reasoned
about, it says so.

---

## 1. It ate the machine on a long recording

**MEASURED, AND FIXED.** Audio in memory costs `sampleRate x channels x 4`
bytes per second: about 21 MB per minute of 44.1 kHz stereo. A 30-minute file
is 605 MB, and every undo step was a full second copy of it.

The original undo history was capped at 24 steps by count only. On that
30-minute file that is 15 GB; on a two-hour recording it is 61 GB, which would
have taken down a 64 GB Mac Studio. This was the single most likely way the app
killed itself, and long recordings are exactly what people have: interviews,
meetings, sampling sessions, podcast takes.

The history is now capped at 1.5 GB as well as 24 steps, oldest dropped first,
and one step is always kept so undo never silently becomes a no-op. Measured
after the fix, on 30 minutes of stereo with ten consecutive edits: undo depth
settles at 2, peak memory 1.85 GB instead of about 6.6 GB. The app now shows
`undo N` in the status line so the shorter history on big files is visible
rather than a surprise.

**Accepted consequence:** on very long files you get two undo steps, not
twenty-four. The honest fix is to store undo as edit descriptions rather than
copies of audio, which is a v0.2 job.

**Still not tested:** a file long enough that decoding itself is a problem. 30
minutes decodes in 0.15 s, so the ceiling is memory, not speed. Two hours would
be about 2.4 GB resident. It should work on this machine. It has not been tried.

## 2. MP3 in, MP3 out, quality quietly erodes

**WAS REAL, NOW FIXED.** The app decodes to float, edits, and re-encodes.
Trimming an MP3 and exporting MP3 therefore re-compressed audio that was already
compressed, and doing that repeatedly audibly degrades it. This is the single
feature that the well-known paid Mac editor is built around, and its absence was
the best reason to go back to paying.

Fixed by copying the encoded frames instead of decoding them, whenever the audio
in memory still matches the file on disk (`AudioClip.isPristine`), the source is
compressed, and the export format matches the source. Verified two ways: the
output decodes to the requested length, and a 4 KB probe from the middle of the
output is found byte for byte inside the source file, which a re-encode could not
produce.

**Accepted consequence:** compressed audio lives in frames of about 26 ms, and a
frame cannot be split, so the cut lands on the nearest frame rather than the exact
sample. That is surfaced in the UI and in the README rather than hidden. Sample
accuracy means exporting WAV or FLAC, or switching the option off.

## 3. He never opens it, because friction

**MITIGATED.** If cutting a clip means finding a folder in a terminal first, then
QuickTime wins by default and the app is dead in a week. It opens audio files
straight from Finder (double-click, Open With, drag onto the Dock icon), ships as
a `.dmg` that drags into Applications, and registers itself for every audio type
macOS knows. A global hotkey is a reasonable future addition if it turns out
people want it constantly.

## 4. Gatekeeper or a macOS update blocks it

**ACCEPTED, AND THE REASON FOR THE INSTALL DANCE.** The app is ad-hoc signed, not
notarized, because notarization requires a $99/year Apple Developer account and
this is free software.

The cost is real and it got worse in macOS 15. Sequoia removed the Control-click
to Open bypass, so a new user now meets a dialog offering only "Done" and "Move
to Trash", and has to go to System Settings > Privacy & Security and click Open
Anyway, within about an hour of the warning. That is a genuinely bad first
impression, and it is the single biggest reason someone will delete this app
before using it.

The honest answer is that you can read every line of the source and build it
yourself in one command, and a locally built app is never quarantined at all. That
is a better guarantee than a certificate. But it only helps people who are willing
to open a terminal.

The real fix, if this ever gets an audience worth the money: join the Apple
Developer Program, sign with a Developer ID certificate and the hardened runtime,
then `notarytool submit --wait` and `stapler staple` in the release workflow. It
is perhaps twenty lines of CI and four secrets.

## 5. Something in the audio path is broken in a way tests cannot see

**PARTLY MITIGATED, HONEST GAP.** The headless suite proves decode, snap, cut,
normalize and export across MP3/WAV/FLAC. It cannot prove what the audio
*sounds* like: no automated test can hear a click, a stutter in the scrub
grains, or a channel swap.

The scrubbing engine is the least verified code in the project. It was reasoned
about carefully (ramps on both ends of every grain, throttled to about 80 per
second) and never listened to by me, because I cannot hear. It also has not been
tried at 48 kHz, 96 kHz, or mono, only 44.1 kHz stereo.

**What would close it:** somebody opening a 48 kHz recording and a mono voice memo
and dragging around for ten seconds. Two minutes of listening beats any test that
can be written for it. If you hear a click, a stutter or swapped channels, please
open an issue: that is the most valuable bug report this project can get.

## 6. It grew into Audacity

**ACCEPTED, WITH A LINE DRAWN.** The pressure on a tool like this is always to
add one more thing: noise reduction, auto-split, batch processing, per-channel
edits, multi-track. Each is reasonable. Together they are a different app, and a
slower, worse one for the thing it is actually for.

The line: this app opens one file, cuts it, exports it. Anything that does not
serve that sentence goes in the "known limits" list and stays there until enough
people miss it repeatedly. Pull requests that add a mixer will be admired and
declined.

---

## What this exercise changed, concretely

1. Undo history capped by bytes as well as by count. Measured 3.5x reduction in
   peak memory on a 30-minute file, with undo still working. This was a genuine
   crash waiting to happen.
2. `undo N` added to the status line, so the shorter history on long files is
   visible rather than a surprise.
3. Lossless cutting built, because it was the one feature gap that sent people
   back to the paid app. Proven by byte comparison, not by assertion.
4. The scrub engine is explicitly flagged as the least verified part, with the
   two-minute manual check that would cover it.

## Where the bodies are buried

If you are reading the source, these are the four places where something
non-obvious is going on, each explained in a comment at the top of its file:

- **`InputMonitors.swift`** exists only because SwiftUI on macOS has no
  scroll-wheel event and cannot reliably own modifier-free keys like Space.
- **`AudioClip.swift`** keeps the whole file in memory as plain `[[Float]]`. That
  is what makes every edit three lines long, and it is also the reason for the
  undo memory cap.
- **`PlaybackEngine.swift`** scrubbing works by scheduling short grains resampled
  by drag velocity, with ramps on both ends. Remove the ramps and every grain
  boundary becomes a tick.
- **`PlaybackEngine.swift`** also stamps every playback pass with a generation
  number. `player.stop()` flushes the scheduled buffer, and flushing fires that
  buffer's completion handler, so without the stamp the handler belonging to a
  pass you just cancelled tears down the pass that replaced it: audio keeps
  playing while the app believes it stopped, and the playhead is thrown to the
  end of the clip. Reported from real use, reproduced in
  `Tests/TransportCheck`, and that test was confirmed to fail against the
  pre-fix engine before being kept.
- **`Snapping.swift`** searches for zero crossings in the *sum* of the channels,
  and deliberately refuses to move a cut more than 8 ms or to touch selections
  shorter than 20 ms.
