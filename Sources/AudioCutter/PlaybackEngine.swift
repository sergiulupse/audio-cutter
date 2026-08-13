//
//  PlaybackEngine.swift
//  Playback, backwards playback, and the drag-to-hear scrubbing.
//
//  HOW THIS WORKS, in plain language
//  --------------------------------------------------------------------------
//  AVAudioEngine is Apple's audio graph. We attach two "player" nodes to it:
//
//    * `player`      plays a stretch of the clip normally. To play a range we
//                    copy those samples into a buffer and hand it over. To play
//                    backwards we hand over the same samples in reverse order,
//                    which is exactly what running tape backwards does.
//
//    * `scrubPlayer` is used only while you drag the playhead. Every time the
//                    mouse moves we take a short "grain" of audio from under
//                    the cursor (about 40 ms), stretch or squash it according
//                    to how fast the mouse is moving, put a tiny fade on both
//                    ends so it does not click, and queue it. Dozens of these
//                    per second in a row is the tape-scrub sound.
//
//  The playhead position is not guessed from a timer. We ask the player node
//  how many samples it has actually rendered, which stays locked to the audio
//  even if the UI stutters. The timer only decides how often we look.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class PlaybackEngine: ObservableObject {

    // MARK: - Published state the UI watches

    @Published private(set) var isPlaying = false
    /// Where the playhead is, in samples.
    @Published var playhead: Int = 0

    /// Loop the played range instead of stopping at its end.
    var loop = false

    /// Playback speed. 1 is normal, 2 is double, 0.5 is half.
    ///
    /// This is tape speed, not a time stretch: at 2x everything is an octave up,
    /// at 0.5x an octave down. That is deliberate. Pitch-preserving stretching
    /// smears transients, and when you are hunting for the exact frame of a
    /// consonant, the chipmunk sound is the honest one. It is also what a
    /// shuttle wheel on a tape machine or an NLE does.
    @Published private(set) var rate: Float = 1.0

    /// True while shuttling backwards, so the UI can light the right button.
    @Published private(set) var playingBackwards = false

    /// The speeds J and L step through, and the menu offers.
    static let rateLadder: [Float] = [0.25, 0.5, 0.75, 1, 1.5, 2, 4]
    /// Where J and L jump to, in order, each time they are pressed again.
    static let shuttleLadder: [Float] = [1, 2, 4]

    // MARK: - Private

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let scrubPlayer = AVAudioPlayerNode()
    /// Changes playback speed. Sits between the player and the mixer, so its
    /// rate can be changed mid-playback without rescheduling anything.
    private let varispeed = AVAudioUnitVarispeed()

    private var format: AVAudioFormat?
    private var attached = false

    /// The sample this playback pass started from, and the direction.
    private var anchorFrame = 0
    private var activeRange: Range<Int> = 0..<0
    /// Identifies the current playback pass. Bumped by play(), pause() and
    /// stop(), so a completion handler from a cancelled pass can be recognised
    /// and ignored. See the long comment in play().
    private var generation = 0
    private weak var clip: AudioClip?

    private var ticker: AnyCancellable?

    // MARK: - Setup

    /// Point the engine at a clip. Called whenever a file is opened, because
    /// the graph has to be wired for that file's sample rate and channel count.
    func prepare(for clip: AudioClip) {
        stop()
        self.clip = clip
        guard clip.channelCount > 0 else { return }

        guard let fmt = AVAudioFormat(
            standardFormatWithSampleRate: clip.sampleRate,
            channels: AVAudioChannelCount(clip.channelCount)
        ) else { return }

        if !attached {
            engine.attach(player)
            engine.attach(scrubPlayer)
            engine.attach(varispeed)
            attached = true
        }

        // Rewiring requires a stopped engine.
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(varispeed)
        engine.disconnectNodeOutput(scrubPlayer)
        // player -> varispeed -> mixer, so the speed control affects normal
        // playback. The scrub player goes straight to the mixer because
        // scrubbing does its own resampling per grain.
        engine.connect(player, to: varispeed, format: fmt)
        engine.connect(varispeed, to: engine.mainMixerNode, format: fmt)
        engine.connect(scrubPlayer, to: engine.mainMixerNode, format: fmt)
        varispeed.rate = rate
        format = fmt

        do {
            try engine.start()
        } catch {
            NSLog("AudioCutter: engine failed to start: \(error)")
        }
    }

    /// Whether the audio graph actually started. False on a machine with no
    /// audio output device at all, such as a continuous-integration runner,
    /// which lets the transport checks skip themselves instead of failing.
    var isEngineRunning: Bool { engine.isRunning }

    // MARK: - Transport

    /// Play `range`, forwards or backwards, starting from `from` if that sample
    /// sits inside the range (so pressing play mid-selection resumes there).
    func play(range: Range<Int>, from: Int? = nil, backwards: Bool = false) {
        guard let clip, let format, range.count > 1 else { return }

        player.stop()
        playingBackwards = backwards
        activeRange = range

        var start = from ?? (backwards ? range.upperBound : range.lowerBound)
        if !range.contains(start) {
            start = backwards ? range.upperBound - 1 : range.lowerBound
        }

        // The stretch we actually need: from the start point to whichever end
        // we are heading towards.
        let sliceRange = backwards
            ? range.lowerBound..<max(range.lowerBound + 1, start)
            : start..<range.upperBound
        guard sliceRange.count > 1 else { return }

        var data = clip.slice(sliceRange)
        if backwards {
            data = data.map { Array($0.reversed()) }
        }

        guard let buffer = Self.makeBuffer(from: data, format: format) else { return }

        anchorFrame = start
        playhead = start

        // Stamp this playback pass. The completion handler below carries the
        // stamp and is ignored if it arrives after a newer pass has started.
        //
        // This matters more than it looks. `player.stop()` at the top of this
        // method flushes the previously scheduled buffer, and flushing fires
        // that buffer's completion handler. Without a stamp, the handler from
        // the playback we just cancelled would run against the playback we just
        // started and tear it down: isPlaying set to false, the playhead thrown
        // to the end of the range, and the position ticker stopped, while the
        // audio itself carried on. That is the "cursor vanishes and it keeps
        // playing forever" bug, and it showed up whenever one pass replaced
        // another: pressing J then Space, or J then L.
        generation &+= 1
        let thisGeneration = generation

        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            // Fires on an audio thread, so bounce back to the main actor.
            Task { @MainActor in self?.reachedEnd(generation: thisGeneration) }
        }
        player.play()
        isPlaying = true
        startTicking()
    }

    // MARK: - Speed and shuttle

    /// Set playback speed. Takes effect immediately, mid-playback, because
    /// varispeed is a live node parameter and not part of the scheduled buffer.
    func setRate(_ newRate: Float) {
        let clamped = max(0.25, min(4, newRate))
        rate = clamped
        varispeed.rate = clamped
    }

    /// L on the keyboard, and the fast-forward button.
    ///
    /// Not playing, or playing backwards: start forwards at normal speed.
    /// Already playing forwards: step up the shuttle ladder, 1 to 2 to 4.
    func shuttleForward(range: Range<Int>) {
        if isPlaying, !playingBackwards {
            setRate(Self.nextRung(after: rate))
        } else {
            setRate(1)
            play(range: range, from: playhead, backwards: false)
        }
    }

    /// J on the keyboard, and the rewind button. Mirror image of the above.
    func shuttleBackward(range: Range<Int>) {
        if isPlaying, playingBackwards {
            setRate(Self.nextRung(after: rate))
        } else {
            setRate(1)
            play(range: range, from: playhead, backwards: true)
        }
    }

    /// The next speed up the shuttle ladder, stopping at the top.
    private static func nextRung(after current: Float) -> Float {
        for rung in shuttleLadder where rung > current + 0.01 { return rung }
        return shuttleLadder.last ?? 1
    }

    func pause() {
        guard isPlaying else { return }
        let where_ = playhead
        generation &+= 1        // any handler still in flight is now stale
        player.stop()
        isPlaying = false
        stopTicking()
        playhead = where_
    }

    func stop() {
        generation &+= 1        // as above
        player.stop()
        scrubPlayer.stop()
        isPlaying = false
        stopTicking()
    }

    /// The scheduled audio ran out. Only acts if this is the pass that is
    /// actually current: see the comment in play().
    private func reachedEnd(generation stamp: Int) {
        guard stamp == generation, isPlaying else { return }
        if loop, activeRange.count > 1 {
            play(range: activeRange, from: nil, backwards: playingBackwards)
        } else {
            isPlaying = false
            stopTicking()
            playhead = playingBackwards ? activeRange.lowerBound : activeRange.upperBound
        }
    }

    // MARK: - Playhead tracking

    private func startTicking() {
        ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return }
        let rendered = Int(playerTime.sampleTime)
        playhead = playingBackwards
            ? max(activeRange.lowerBound, anchorFrame - rendered)
            : min(activeRange.upperBound, anchorFrame + rendered)
    }

    // MARK: - Scrubbing

    private var lastScrubFrame: Int?
    private var lastScrubTime: CFTimeInterval = 0

    /// Called repeatedly while the user drags. `frame` is where the cursor is.
    ///
    /// The grain length is fixed; the playback rate comes from how far the
    /// cursor travelled since the previous call. Drag slowly and you hear a
    /// slow smear, drag fast and it races, drag backwards and it plays
    /// backwards, which is what makes scrubbing feel physical.
    func scrub(to frame: Int) {
        guard let clip, let format, clip.frameCount > 0 else { return }
        let now = CACurrentMediaTime()
        defer {
            lastScrubFrame = frame
            lastScrubTime = now
        }

        if isPlaying { pause() }
        playhead = frame

        guard let previous = lastScrubFrame else { return }
        let elapsed = now - lastScrubTime
        guard elapsed > 0.012 else { return }   // cap at ~80 grains/second

        let travelled = frame - previous
        guard abs(travelled) > 8 else { return } // ignore jitter while holding still

        // Rate 1.0 means the cursor is moving at real-time speed.
        let rate = Double(travelled) / (clip.sampleRate * elapsed)
        let clamped = max(-4.0, min(4.0, rate))
        guard abs(clamped) > 0.02 else { return }

        let grainOut = 2_048                             // samples we emit
        let grainIn = Int(Double(grainOut) * abs(clamped))
        guard grainIn > 1 else { return }

        let backwards = clamped < 0
        let lo = backwards ? max(0, frame - grainIn) : min(clip.frameCount - 1, frame)
        let hi = backwards ? min(clip.frameCount, frame) : min(clip.frameCount, frame + grainIn)
        guard hi - lo > 1 else { return }

        let source = clip.slice(lo..<hi)
        var out = [[Float]](repeating: [Float](repeating: 0, count: grainOut),
                            count: source.count)

        // Cheap linear resample of the grain to the output length, reading
        // backwards when the drag is backwards.
        let inCount = hi - lo
        for ch in source.indices {
            source[ch].withUnsafeBufferPointer { src in
                for i in 0..<grainOut {
                    let t = Double(i) / Double(grainOut - 1)
                    let pos = (backwards ? (1 - t) : t) * Double(inCount - 1)
                    let i0 = Int(pos)
                    let i1 = min(i0 + 1, inCount - 1)
                    let frac = Float(pos - Double(i0))
                    out[ch][i] = src[i0] * (1 - frac) + src[i1] * frac
                }
            }
        }

        // A 128-sample fade on each end. Without it every grain boundary is a
        // step in the waveform, and a step is an audible tick.
        let ramp = 128
        for ch in out.indices {
            for i in 0..<ramp {
                let g = Float(i) / Float(ramp)
                out[ch][i] *= g
                out[ch][grainOut - 1 - i] *= g
            }
        }

        guard let buffer = Self.makeBuffer(from: out, format: format) else { return }
        if !scrubPlayer.isPlaying { scrubPlayer.play() }
        scrubPlayer.scheduleBuffer(buffer, at: nil, options: [])
    }

    /// Let the queued grains drain, then go quiet.
    func endScrub() {
        lastScrubFrame = nil
        scrubPlayer.stop()
    }

    // MARK: - Helpers

    /// Copy plain Swift arrays into the buffer type AVAudioEngine wants.
    nonisolated static func makeBuffer(
        from channels: [[Float]],
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let first = channels.first, !first.isEmpty else { return nil }
        let frames = AVAudioFrameCount(first.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let dst = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = frames
        let n = Int(format.channelCount)
        for ch in 0..<n {
            // If the file has fewer channels than the graph, repeat the last.
            let src = channels[min(ch, channels.count - 1)]
            src.withUnsafeBufferPointer { p in
                dst[ch].update(from: p.baseAddress!, count: Int(frames))
            }
        }
        return buffer
    }
}
