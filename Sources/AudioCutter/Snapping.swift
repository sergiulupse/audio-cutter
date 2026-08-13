//
//  Snapping.swift
//  Zero-crossing snap.
//
//  WHY THIS EXISTS
//  --------------------------------------------------------------------------
//  A "zero crossing" is a sample where the waveform passes through silence on
//  its way from positive to negative (or back). If you cut exactly on a zero
//  crossing, the two pieces meet at zero and there is no step in the waveform,
//  so there is no click. Cut anywhere else and you get a tiny vertical jump,
//  which the speaker reproduces as a tick.
//
//  Every serious editor has this, and the Reddit round-up praised it in the
//  apps that had it and complained about it in the apps that got it wrong. The
//  classic mistake is snapping too far: on a sharp drum hit, a snap that
//  wanders 30 ms away lands in the previous note. So this implementation has a
//  hard search limit and, if it cannot find a crossing inside that window, it
//  gives up and returns the original position instead of guessing.
//

import Foundation

extension AudioClip {

    /// Nudge `frame` to the nearest zero crossing, searching at most
    /// `windowMilliseconds` in each direction.
    ///
    /// On stereo we look at the sum of channels: a point that is zero in the
    /// sum is the point where the cut is silent overall, which is what the ear
    /// actually cares about.
    func snapToZeroCrossing(_ frame: Int, windowMilliseconds: Double = 8) -> Int {
        guard frameCount > 2 else { return frame }
        let target = max(0, min(frame, frameCount - 1))
        let window = max(1, Int(windowMilliseconds / 1000 * sampleRate))

        func summed(_ i: Int) -> Float {
            var total: Float = 0
            for ch in 0..<channelCount { total += sample(channel: ch, at: i) }
            return total
        }

        // Walk outwards from the target so the first hit is the closest one.
        for offset in 0...window {
            for direction in (offset == 0 ? [1] : [-1, 1]) {
                let i = target + offset * direction
                guard i > 0, i < frameCount - 1 else { continue }
                let a = summed(i)
                let b = summed(i + 1)
                // Sign change, or landing exactly on zero.
                if a == 0 { return i }
                if (a < 0) != (b < 0) {
                    // Pick whichever of the two straddling samples is nearer
                    // to actual zero.
                    return abs(a) <= abs(b) ? i : i + 1
                }
            }
        }

        // Nothing found in the window. Better to cut where the user asked than
        // to move the edit somewhere surprising.
        return target
    }

    /// Snap both ends of a selection.
    ///
    /// Deliberately skipped for selections shorter than about 20 ms: the search
    /// window is 8 ms wide at each end, so snapping a very short selection could
    /// move its edges by a large fraction of its own length, or collapse it
    /// entirely. When you have zoomed in far enough to select a few
    /// milliseconds, you meant those milliseconds.
    func snapped(_ range: Range<Int>, enabled: Bool) -> Range<Int> {
        let shortestWorthSnapping = Int(0.020 * sampleRate)
        guard enabled, range.count > shortestWorthSnapping else { return range }
        let lo = snapToZeroCrossing(range.lowerBound)
        let hi = snapToZeroCrossing(range.upperBound)
        return lo < hi ? lo..<hi : range
    }
}
