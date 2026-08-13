//
//  AudioClip.swift
//  The document model: the audio samples in memory, every edit operation,
//  and the undo history.
//
//  HOW THIS WORKS, in plain language
//  --------------------------------------------------------------------------
//  An audio file is just a very long list of numbers. One number = one
//  "sample" = the position of the speaker cone at one instant. At 44,100 Hz
//  there are 44,100 of those numbers per second, per channel (2 channels for
//  stereo). We decode the whole file into plain Swift arrays of Float, one
//  array per channel, where each Float sits between -1.0 and +1.0.
//
//  Once the audio is a plain array, editing becomes trivial array surgery:
//    - "keep this selection"   = throw away everything outside a range
//    - "delete this selection" = remove that range, splice the two ends
//    - "fade"                  = multiply a stretch of numbers by a ramp
//    - "normalize"             = multiply everything by one number
//
//  Drawing 40 million numbers on screen would be far too slow, so we also
//  precompute a "mip" (a summary): for every block of 256 samples we store the
//  smallest and largest value in that block. The waveform view draws from the
//  summary when zoomed out and from the real samples when zoomed in. This is
//  the same trick every DAW uses.
//

import AVFoundation
import Foundation

/// One min/max pair summarising a block of samples. Two Floats, so the whole
/// summary is tiny compared to the audio itself.
struct Peak {
    var min: Float
    var max: Float

    static let zero = Peak(min: 0, max: 0)
}

/// The raw result of decoding a file. Deliberately a plain value type with no
/// main-actor requirement, so decoding can happen on a background thread and
/// then be handed to the UI in one piece.
struct DecodedAudio {
    var channels: [[Float]]
    var sampleRate: Double
    var sourceURL: URL
    /// The format we decoded from, used only for the info line in the UI.
    var sourceDescription: String
}

@MainActor
final class AudioClip: ObservableObject {

    /// How many samples each entry of the summary covers.
    nonisolated static let mipBucket = 256

    // MARK: - State

    /// The audio itself. One inner array per channel.
    @Published private(set) var channels: [[Float]] = []
    /// Number of samples per channel. Kept separately so the UI can read a
    /// length without touching the big arrays.
    @Published private(set) var frameCount: Int = 0
    @Published private(set) var sampleRate: Double = 44_100
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceDescription: String = ""
    /// The zoomed-out drawing summary, one array per channel.
    @Published private(set) var mip: [[Peak]] = []
    /// Bumped every time the samples change, so views know to redraw.
    @Published private(set) var revision: Int = 0

    /// True while the audio in memory still matches the file on disk exactly.
    ///
    /// This is what makes lossless exporting possible. If nothing has been
    /// altered, a selection can be copied straight out of the original file
    /// without decoding and re-encoding it. One fade or one gain change and that
    /// shortcut is off the table, so any edit clears this.
    @Published private(set) var isPristine = false

    /// Every edit pushes a full snapshot here first, which is the simplest
    /// undo that can possibly work.
    ///
    /// The catch is size. Audio in memory costs sampleRate x channels x 4
    /// bytes per second: about 21 MB per minute of stereo at 44.1 kHz. So 30
    /// minutes of stereo is 635 MB, and *each* undo step is another 635 MB.
    /// Capping the history by count alone is a trap, because 24 steps on a
    /// half-hour recording is 15 GB and on a two-hour one it is 61 GB.
    ///
    /// So the history is capped by *bytes* as well as by count. Oldest
    /// snapshots are dropped until the history fits the budget, and one step
    /// is always kept so undo never silently becomes a no-op.
    private var undoStack: [(channels: [[Float]], frames: Int)] = []
    private let undoLimit = 24
    private let undoByteBudget = 1_500_000_000      // 1.5 GB of history
    @Published private(set) var canUndo = false

    /// Roughly what the undo history is costing right now, in bytes.
    private var undoBytes: Int {
        undoStack.reduce(0) { total, entry in
            total + entry.channels.reduce(0) { $0 + $1.count * 4 }
        }
    }

    /// How many undo steps are actually available, for the UI to report.
    var undoDepth: Int { undoStack.count }

    var isEmpty: Bool { frameCount == 0 }
    var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
    var channelCount: Int { channels.count }

    // MARK: - Loading

    /// Decode a file into memory. Runs off the main thread; call from a Task.
    ///
    /// AVAudioFile gives us a uniform PCM view of whatever we hand it, so MP3,
    /// M4A/AAC, WAV, AIFF, CAF and FLAC all arrive here as plain Floats. That
    /// is why the app does not need a separate decoder per format.
    nonisolated static func decode(url: URL) throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat            // always float PCM
        let total = AVAudioFrameCount(file.length)

        guard total > 0 else {
            throw CutterError.message("That file contains no audio.")
        }

        var channels = [[Float]](
            repeating: [],
            count: Int(format.channelCount)
        )
        for i in channels.indices {
            channels[i].reserveCapacity(Int(total))
        }

        // Read in chunks so a long file never needs one giant allocation from
        // AVFoundation. 1 second at a time is a comfortable size.
        let chunkFrames = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: chunkFrames
        ) else {
            throw CutterError.message("Could not allocate a decode buffer.")
        }

        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: chunkFrames)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for ch in 0..<channels.count {
                let p = data[ch]
                channels[ch].append(
                    contentsOf: UnsafeBufferPointer(start: p, count: n)
                )
            }
        }

        guard channels.first?.isEmpty == false else {
            throw CutterError.message("Nothing could be decoded from that file.")
        }

        let ext = url.pathExtension.uppercased()
        let chDesc: String
        switch format.channelCount {
        case 1: chDesc = "mono"
        case 2: chDesc = "stereo"
        default: chDesc = "\(format.channelCount) ch"
        }
        let desc = "\(ext.isEmpty ? "audio" : ext) · "
            + "\(Int(format.sampleRate / 1000)).\(Int(format.sampleRate.truncatingRemainder(dividingBy: 1000)) / 100) kHz · "
            + chDesc

        return DecodedAudio(
            channels: channels,
            sampleRate: format.sampleRate,
            sourceURL: url,
            sourceDescription: desc
        )
    }

    /// Install decoded audio as the current document, replacing anything open.
    func adopt(_ decoded: DecodedAudio) {
        channels = decoded.channels
        frameCount = decoded.channels[0].count
        sampleRate = decoded.sampleRate
        sourceURL = decoded.sourceURL
        sourceDescription = decoded.sourceDescription
        undoStack.removeAll()
        canUndo = false
        isPristine = true
        rebuildMip()
        revision += 1
    }

    func close() {
        channels = []
        frameCount = 0
        sourceURL = nil
        sourceDescription = ""
        mip = []
        undoStack.removeAll()
        canUndo = false
        isPristine = false
        revision += 1
    }

    // MARK: - Drawing summary

    private func rebuildMip() {
        mip = AudioClip.buildMip(channels: channels)
    }

    nonisolated static func buildMip(channels: [[Float]]) -> [[Peak]] {
        let bucket = mipBucket
        return channels.map { samples -> [Peak] in
            let count = (samples.count + bucket - 1) / bucket
            var out = [Peak](repeating: .zero, count: max(count, 0))
            samples.withUnsafeBufferPointer { buf in
                for b in 0..<count {
                    let lo = b * bucket
                    let hi = Swift.min(lo + bucket, buf.count)
                    var mn: Float = .greatestFiniteMagnitude
                    var mx: Float = -.greatestFiniteMagnitude
                    for i in lo..<hi {
                        let v = buf[i]
                        if v < mn { mn = v }
                        if v > mx { mx = v }
                    }
                    out[b] = Peak(min: mn, max: mx)
                }
            }
            return out
        }
    }

    /// Min/max across a range of samples, for one channel. Uses the summary
    /// when the range is wide enough that reading every sample would be waste.
    func peak(channel: Int, from: Int, to: Int) -> Peak {
        guard channel < channels.count else { return .zero }
        let lo = max(0, min(from, frameCount))
        let hi = max(lo, min(to, frameCount))
        if hi <= lo { return .zero }

        let span = hi - lo
        var mn: Float = .greatestFiniteMagnitude
        var mx: Float = -.greatestFiniteMagnitude

        if span >= AudioClip.mipBucket * 2, channel < mip.count {
            // Wide range: read the summary, and the ragged sample-level edges.
            let table = mip[channel]
            let firstBucket = (lo + AudioClip.mipBucket - 1) / AudioClip.mipBucket
            let lastBucket = hi / AudioClip.mipBucket
            if firstBucket < lastBucket {
                for b in firstBucket..<min(lastBucket, table.count) {
                    let p = table[b]
                    if p.min < mn { mn = p.min }
                    if p.max > mx { mx = p.max }
                }
            }
            channels[channel].withUnsafeBufferPointer { buf in
                for i in lo..<min(firstBucket * AudioClip.mipBucket, hi) {
                    let v = buf[i]
                    if v < mn { mn = v }
                    if v > mx { mx = v }
                }
                for i in max(lastBucket * AudioClip.mipBucket, lo)..<hi {
                    let v = buf[i]
                    if v < mn { mn = v }
                    if v > mx { mx = v }
                }
            }
        } else {
            channels[channel].withUnsafeBufferPointer { buf in
                for i in lo..<hi {
                    let v = buf[i]
                    if v < mn { mn = v }
                    if v > mx { mx = v }
                }
            }
        }

        if mn > mx { return .zero }
        return Peak(min: mn, max: mx)
    }

    /// A single sample, for the scrub engine and for zoomed-in drawing.
    func sample(channel: Int, at index: Int) -> Float {
        guard channel < channels.count,
              index >= 0, index < channels[channel].count else { return 0 }
        return channels[channel][index]
    }

    /// A copy of a range of samples, used for playback and export.
    func slice(_ range: Range<Int>) -> [[Float]] {
        let lo = max(0, min(range.lowerBound, frameCount))
        let hi = max(lo, min(range.upperBound, frameCount))
        return channels.map { Array($0[lo..<hi]) }
    }

    // MARK: - Undo

    private func snapshot() {
        // Every destructive operation calls this before touching the samples,
        // which makes it the one reliable place to record that the audio in
        // memory no longer matches the file on disk.
        isPristine = false
        undoStack.append((channels, frameCount))

        // Trim by count first, then by weight. `count > 1` guards both loops so
        // the most recent snapshot survives even if it alone exceeds the
        // budget: one working undo matters more than a tidy number.
        while undoStack.count > undoLimit {
            undoStack.removeFirst()
        }
        while undoStack.count > 1, undoBytes > undoByteBudget {
            undoStack.removeFirst()
        }

        canUndo = !undoStack.isEmpty
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        channels = last.channels
        frameCount = last.frames
        canUndo = !undoStack.isEmpty
        rebuildMip()
        revision += 1
    }

    // MARK: - Edits

    /// Throw away everything outside `range`. This is the "keep only what I
    /// selected" operation, which is the whole point of the app.
    func keep(_ range: Range<Int>) {
        let r = clamp(range)
        guard r.count > 0, r.count < frameCount else { return }
        snapshot()
        channels = channels.map { Array($0[r]) }
        frameCount = channels[0].count
        applyEdgeFades()
        finishEdit()
    }

    /// Remove `range` and splice what is left together.
    func delete(_ range: Range<Int>) {
        delete(ranges: [range])
    }

    /// Remove several ranges at once. Used by "delete all marked regions".
    /// Deleting back-to-front means earlier indices stay valid as we go.
    func delete(ranges: [Range<Int>]) {
        let cleaned = normalise(ranges)
        guard !cleaned.isEmpty else { return }
        let totalRemoved = cleaned.reduce(0) { $0 + $1.count }
        guard totalRemoved > 0, totalRemoved < frameCount else { return }

        snapshot()
        for r in cleaned.reversed() {
            for ch in channels.indices {
                channels[ch].removeSubrange(r)
            }
        }
        frameCount = channels[0].count
        applyEdgeFades()
        finishEdit()
    }

    /// Multiply a range by a ramp from 0 to 1 (or 1 to 0 when fading out).
    /// The ramp is equal-power (a quarter sine) rather than a straight line,
    /// because a straight line sounds like it dips in the middle.
    func fade(_ range: Range<Int>, fadingIn: Bool, takeSnapshot: Bool = true) {
        let r = clamp(range)
        guard r.count > 1 else { return }
        if takeSnapshot { snapshot() }
        let n = Float(r.count - 1)
        for ch in channels.indices {
            channels[ch].withUnsafeMutableBufferPointer { buf in
                for (k, i) in r.enumerated() {
                    let t = Float(k) / n
                    let g = fadingIn ? t : 1 - t
                    buf[i] *= sin(g * .pi / 2)      // equal-power curve
                }
            }
        }
        if takeSnapshot { finishEdit() }
    }

    /// Scale the whole clip so its loudest point sits just under full scale.
    /// -0.3 dBFS of headroom keeps lossy encoders from clipping on export.
    func normalize() {
        guard frameCount > 0 else { return }
        var peakAbs: Float = 0
        for ch in channels {
            ch.withUnsafeBufferPointer { buf in
                for v in buf { let a = abs(v); if a > peakAbs { peakAbs = a } }
            }
        }
        guard peakAbs > 0.0001 else { return }
        let target: Float = 0.9660  // -0.3 dBFS
        let gain = target / peakAbs
        guard abs(gain - 1) > 0.001 else { return }

        snapshot()
        for ch in channels.indices {
            channels[ch].withUnsafeMutableBufferPointer { buf in
                for i in 0..<buf.count { buf[i] *= gain }
            }
        }
        finishEdit()
    }

    /// Play-it-backwards, permanently. Distinct from the reverse transport
    /// button, which only previews backwards without changing the audio.
    func reverse(_ range: Range<Int>?) {
        let r = range.map(clamp) ?? 0..<frameCount
        guard r.count > 1 else { return }
        snapshot()
        for ch in channels.indices {
            let piece = Array(channels[ch][r]).reversed()
            channels[ch].replaceSubrange(r, with: piece)
        }
        finishEdit()
    }

    /// Cut the dead air off the front and back of the clip.
    ///
    /// "Silence" here means quieter than `thresholdDB` for a continuous stretch.
    /// The default of -50 dBFS is below room tone but well above the noise floor
    /// of a real recording, so it finds the gap before someone starts talking
    /// without eating the first breath. A small margin is left on each side for
    /// the same reason: a hard cut at the exact moment sound appears clips the
    /// attack off it.
    ///
    /// Returns the number of seconds removed, or 0 if there was nothing to trim.
    @discardableResult
    func trimSilence(thresholdDB: Float = -50, marginMilliseconds: Double = 30) -> Double {
        guard frameCount > 0 else { return 0 }
        let threshold = pow(10, thresholdDB / 20)      // dBFS to a 0...1 amplitude

        /// Loudest sample across all channels at one position.
        func level(_ i: Int) -> Float {
            var peak: Float = 0
            for ch in 0..<channelCount {
                peak = max(peak, abs(sample(channel: ch, at: i)))
            }
            return peak
        }

        var first = 0
        while first < frameCount, level(first) < threshold { first += 1 }
        // Nothing above the threshold anywhere: the file is silent, leave it be
        // rather than deleting all of it.
        guard first < frameCount else { return 0 }

        var last = frameCount - 1
        while last > first, level(last) < threshold { last -= 1 }

        let margin = Int(marginMilliseconds / 1000 * sampleRate)
        let start = max(0, first - margin)
        let end = min(frameCount, last + margin + 1)
        guard end - start < frameCount else { return 0 }

        let removed = Double(frameCount - (end - start)) / sampleRate
        keep(start..<end)
        return removed
    }

    /// Silence a range without removing it, keeping the clip's total length.
    func silence(_ range: Range<Int>) {
        let r = clamp(range)
        guard r.count > 0 else { return }
        snapshot()
        for ch in channels.indices {
            channels[ch].withUnsafeMutableBufferPointer { buf in
                for i in r { buf[i] = 0 }
            }
        }
        finishEdit()
    }

    // MARK: - Edit plumbing

    /// Every cut leaves a step in the waveform where two unrelated samples now
    /// sit next to each other, and a step is a click. A 4 ms fade at the very
    /// start and end of the clip removes it, and is far too short to hear as
    /// a fade.
    var autoFadeMilliseconds: Double = 4

    private func applyEdgeFades() {
        let n = Int(autoFadeMilliseconds / 1000 * sampleRate)
        guard n > 1, frameCount > n * 2 else { return }
        fade(0..<n, fadingIn: true, takeSnapshot: false)
        fade((frameCount - n)..<frameCount, fadingIn: false, takeSnapshot: false)
    }

    private func finishEdit() {
        rebuildMip()
        revision += 1
    }

    private func clamp(_ range: Range<Int>) -> Range<Int> {
        let lo = max(0, min(range.lowerBound, frameCount))
        let hi = max(lo, min(range.upperBound, frameCount))
        return lo..<hi
    }

    /// Sort ranges, drop empties, and merge any that touch or overlap, so a
    /// multi-region delete cannot corrupt itself.
    private func normalise(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.map(clamp).filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        var out: [Range<Int>] = []
        for r in sorted {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}

/// One error type for everything the app can tell the user about.
enum CutterError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}
