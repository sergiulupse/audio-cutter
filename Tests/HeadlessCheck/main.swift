//
//  main.swift
//  The headless check suite. Compiled and run by run.sh, never shipped in the
//  app.
//
//  It exercises everything that does not need a window: decoding each format,
//  zero-crossing snapping, the cut operations, undo and its memory cap,
//  normalising, trimming silence, lossless cutting, and writing every export
//  format back out and reading it in again.
//
//  Checks that depend on ffmpeg are skipped, not failed, when it is missing.
//

import AVFoundation
import Foundation

var failures = 0
var skipped = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
    if !ok { failures += 1 }
}

func skip(_ label: String, _ why: String) {
    print("SKIP  \(label)  [\(why)]")
    skipped += 1
}

MainActor.assumeIsolated { try! run() }

@MainActor func run() throws {

    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = dir.appendingPathComponent("out")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    func fixture(_ name: String) -> URL? {
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Decoding

    for name in ["test.wav", "test.mp3", "test.flac"] {
        guard let url = fixture(name) else {
            skip("decode \(name)", "fixture not generated, ffmpeg missing")
            continue
        }
        do {
            let decoded = try AudioClip.decode(url: url)
            let seconds = Double(decoded.channels[0].count) / decoded.sampleRate
            check("decode \(name)",
                  decoded.channels.count == 2 && abs(seconds - 2.0) < 0.06,
                  "\(decoded.channels.count)ch \(Int(decoded.sampleRate))Hz "
                    + String(format: "%.3f", seconds) + "s")
        } catch {
            check("decode \(name)", false, "\(error)")
        }
    }

    // MARK: The document model

    let clip = AudioClip()
    clip.adopt(try AudioClip.decode(url: dir.appendingPathComponent("test.wav")))
    let original = clip.frameCount
    let rate = clip.sampleRate

    check("adopt sets length", original > 80_000, "\(original) frames")
    check("mip built", clip.mip.count == 2 && clip.mip[0].count > 100,
          "\(clip.mip[0].count) buckets")

    // MARK: Zero-crossing snapping
    //
    // Snapping targets the sum of the channels, because that is the signal the
    // speaker actually produces, so the check measures the sum too.

    func summed(_ i: Int) -> Float {
        (0..<clip.channelCount).reduce(Float(0)) { $0 + clip.sample(channel: $1, at: i) }
    }
    var worstIndex = 10_000
    var worstValue: Float = 0
    for i in 10_000..<(10_000 + Int(rate / 220)) {
        let v = abs(summed(i))
        if v > worstValue { worstValue = v; worstIndex = i }
    }
    let snappedIndex = clip.snapToZeroCrossing(worstIndex)
    let beforeSnap = abs(summed(worstIndex))
    let afterSnap = abs(summed(snappedIndex))
    check("zero-crossing snap: from the loudest point to near-silence",
          afterSnap < beforeSnap * 0.05,
          String(format: "sum |before| %.4f -> |after| %.5f, moved %d samples",
                 beforeSnap, afterSnap, snappedIndex - worstIndex))

    let farLimit = clip.snapToZeroCrossing(30_000, windowMilliseconds: 0.001)
    check("snap gives up rather than moving far", abs(farLimit - 30_000) <= 2,
          "moved \(farLimit - 30_000)")

    let tiny = 10_000..<10_100                      // about 2 ms
    check("snap leaves very short selections alone",
          clip.snapped(tiny, enabled: true) == tiny)

    // MARK: Cutting

    let keepRange = 20_000..<(20_000 + Int(rate / 2))
    clip.keep(keepRange)
    check("keep trims to the selection", clip.frameCount == keepRange.count,
          "\(clip.frameCount) == \(keepRange.count)")
    check("keep is undoable", clip.canUndo)
    check("edge fade applied at the cut boundary",
          abs(clip.sample(channel: 0, at: 0)) < 0.01,
          "first sample \(clip.sample(channel: 0, at: 0))")

    clip.undo()
    check("undo restores the length", clip.frameCount == original, "\(clip.frameCount)")

    // Overlapping ranges must be merged, not deleted twice.
    let a = 1_000..<2_000
    let b = 1_500..<3_000
    let c = 50_000..<51_000
    clip.delete(ranges: [c, a, b])
    check("multi-region delete merges overlaps",
          clip.frameCount == original - 3_000,
          "\(original) -> \(clip.frameCount)")
    clip.undo()

    // MARK: Undo history bounds
    //
    // Each undo step is a full copy of the audio, so the history is capped by
    // bytes as well as by count.
    //
    // Be clear about what this proves: these fixtures are two seconds long, so
    // ten steps is a few megabytes and the byte cap never engages. What is
    // checked here is the count cap and that undo still works afterwards. The
    // byte cap can only be exercised by a file large enough to hit 1.5 GB of
    // history, which is a 30-minute stereo recording; that was measured by hand
    // (peak memory 1.85 GB rather than 6.6 GB, history settling at 2 steps)
    // rather than in this suite, because generating half an hour of audio on
    // every run is not worth the minute it costs.

    for i in 1...10 { clip.silence((i * 1_000)..<(i * 1_000 + 100)) }
    check("undo history respects the count cap and still works",
          clip.undoDepth == 10 && clip.canUndo,
          "\(clip.undoDepth) steps, "
            + "\(clip.frameCount * clip.channelCount * 4 / 1024) KB each")
    while clip.canUndo { clip.undo() }

    // MARK: Normalising

    clip.normalize()
    var peak: Float = 0
    for i in 0..<clip.frameCount { peak = max(peak, abs(clip.sample(channel: 0, at: i))) }
    check("normalize reaches -0.3 dBFS", abs(peak - 0.966) < 0.02,
          String(format: "peak %.4f", peak))

    // MARK: Trimming silence

    let padded = AudioClip()
    padded.adopt(try AudioClip.decode(url: dir.appendingPathComponent("padded.wav")))
    let paddedBefore = padded.duration
    let removed = padded.trimSilence()
    check("trim silence removes the padding",
          removed > 1.2 && abs(padded.duration - 1.0) < 0.15,
          String(format: "%.2fs -> %.2fs, removed %.2fs",
                 paddedBefore, padded.duration, removed))

    let unpadded = AudioClip()
    unpadded.adopt(try AudioClip.decode(url: dir.appendingPathComponent("test.wav")))
    let unpaddedLength = unpadded.frameCount
    check("trim silence leaves a file with no silence alone",
          unpadded.trimSilence() == 0 && unpadded.frameCount == unpaddedLength)

    let silent = AudioClip()
    silent.adopt(try AudioClip.decode(url: dir.appendingPathComponent("silent.wav")))
    let silentLength = silent.frameCount
    check("a fully silent file is not wiped out",
          silent.trimSilence() == 0 && silent.frameCount == silentLength)

    // MARK: Lossless cutting

    if let mp3 = fixture("test.mp3") {
        let pristine = AudioClip()
        pristine.adopt(try AudioClip.decode(url: mp3))
        check("a freshly opened clip is pristine", pristine.isPristine)
        check("lossless offered for MP3 in, MP3 out",
              Exporter.canCutLosslessly(source: mp3,
                                        isPristine: pristine.isPristine,
                                        format: .mp3))
        check("lossless refused for MP3 in, WAV out (WAV is already lossless)",
              !Exporter.canCutLosslessly(source: mp3,
                                         isPristine: pristine.isPristine,
                                         format: .wav))

        let cutURL = out.appendingPathComponent("lossless.mp3")
        try Exporter.losslessCut(source: mp3, startSeconds: 0.5,
                                 durationSeconds: 1.0, to: cutURL)
        let back = try AudioClip.decode(url: cutURL)
        let seconds = Double(back.channels[0].count) / back.sampleRate
        check("lossless cut lands within one MP3 frame of the request",
              abs(seconds - 1.0) < 0.06, String(format: "%.4fs", seconds))

        // The proof that nothing was re-encoded: the compressed frames in the
        // output appear byte for byte inside the source. Comparing decoded
        // samples instead would only measure the frame-boundary time shift that
        // seeking introduces, which is expected and harmless.
        let sourceBytes = try Data(contentsOf: mp3)
        let cutBytes = try Data(contentsOf: cutURL)
        let probeStart = cutBytes.count / 2
        let probe = cutBytes.subdata(
            in: probeStart..<min(probeStart + 4_000, cutBytes.count)
        )
        check("compressed frames are copied byte for byte from the source",
              probe.count > 1_000 && sourceBytes.range(of: probe) != nil,
              "\(probe.count) byte probe from the middle of the output")

        pristine.normalize()
        check("an edit withdraws the lossless option",
              !pristine.isPristine
                && !Exporter.canCutLosslessly(source: mp3,
                                              isPristine: pristine.isPristine,
                                              format: .mp3))
    } else {
        skip("lossless cutting", "needs ffmpeg")
    }

    // MARK: Exporting

    let payload = clip.slice(0..<min(clip.frameCount, Int(rate)))
    for format in ExportFormat.allCases {
        let url = out.appendingPathComponent("export.\(format.fileExtension)")
        if format == .mp3, !Exporter.mp3Available {
            skip("export \(format.rawValue)", "no MP3 encoder installed")
            continue
        }
        do {
            try Exporter.write(channels: payload, sampleRate: rate,
                               to: url, format: format)
            let size = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let back = try AudioClip.decode(url: url)
            let seconds = Double(back.channels[0].count) / back.sampleRate
            check("export and reread \(format.rawValue)",
                  (size ?? 0) > 1_000 && abs(seconds - 1.0) < 0.1,
                  "\((size ?? 0) / 1024) KB, "
                    + String(format: "%.3f", seconds) + "s, \(back.channels.count)ch")
        } catch {
            check("export \(format.rawValue)", false, error.localizedDescription)
        }
    }

    print("")
    if failures == 0 {
        print("ALL CHECKS PASSED\(skipped > 0 ? " (\(skipped) skipped)" : "")")
    } else {
        print("\(failures) CHECK(S) FAILED")
    }
    exit(failures == 0 ? 0 : 1)
}
