//
//  WaveformView.swift
//  The waveform, the ruler, the selection, and all the mouse handling.
//
//  HOW THE INTERACTION IS LAID OUT
//  --------------------------------------------------------------------------
//  Two strips, two behaviours, no tool palette and no modifier keys to
//  memorise. This is the thing the Reddit round-up kept rewarding apps for.
//
//    The ruler (thin strip on top)
//      drag       move the playhead and scrub the audio, tape style
//
//    The waveform (everything below)
//      drag       select a range, and scrub as the edge moves so you hear
//                 where you are landing
//      click      move the playhead
//      double     select the whole clip
//      pinch      zoom
//
//  Stereo is drawn as two separate lanes, left above right. Fission draws a
//  stereo file as a single merged waveform and that was the one thing the
//  round-up called a "killer" flaw, so this app does not do that.
//

import AppKit
import SwiftUI

/// Maps between sample positions and screen positions.
///
/// `framesPerPoint` is the zoom level: how many samples are crushed into one
/// point of screen width. At 44,100 Hz a value of 44,100 shows one second per
/// point (very zoomed out) and a value of 1 shows one sample per point.
struct WaveTransform: Equatable {
    var framesPerPoint: Double = 512
    var startFrame: Int = 0

    func frame(forX x: CGFloat) -> Int {
        startFrame + Int((Double(x) * framesPerPoint).rounded())
    }

    func x(forFrame frame: Int) -> CGFloat {
        CGFloat(Double(frame - startFrame) / framesPerPoint)
    }

    /// Zoom so the whole clip fits `width` points.
    static func fitting(frameCount: Int, width: CGFloat) -> WaveTransform {
        let w = max(width, 1)
        return WaveTransform(
            framesPerPoint: max(Double(frameCount) / Double(w), 0.02),
            startFrame: 0
        )
    }

    /// Zoom by `factor` while keeping `frame` under the same screen position.
    ///
    /// Anchoring the zoom to a sample rather than to the middle of the view is
    /// what makes wheel-zoom feel right: the thing under the pointer stays
    /// under the pointer. `factor` above 1 zooms out, below 1 zooms in.
    func zoomed(by factor: Double, around frame: Int, limit frameCount: Int) -> WaveTransform {
        var next = self
        // 0.02 samples per point is roughly 50 points per sample, far past any
        // useful detail. The other end shows the entire file in one screen.
        next.framesPerPoint = max(0.02, min(
            framesPerPoint * factor,
            max(Double(frameCount), 1)
        ))
        let pointsFromLeft = Double(frame - startFrame) / framesPerPoint
        next.startFrame = frame - Int(pointsFromLeft * next.framesPerPoint)
        return next
    }

    /// Keep the visible span the same when the window changes width.
    ///
    /// Without this, widening the window would just reveal more audio at the
    /// same scale and narrowing it would clip audio off the right edge. With
    /// it, the waveform always fills the window: when the whole clip is on
    /// screen it stays exactly fitted, and when zoomed in the same stretch of
    /// time stays visible.
    func refitted(fromWidth oldWidth: CGFloat, toWidth newWidth: CGFloat) -> WaveTransform {
        guard oldWidth > 1, newWidth > 1 else { return self }
        var next = self
        let visibleFrames = Double(oldWidth) * framesPerPoint
        next.framesPerPoint = max(0.02, visibleFrames / Double(newWidth))
        return next
    }

    /// Keep the view inside the clip after zooming or panning.
    func clamped(frameCount: Int, width: CGFloat) -> WaveTransform {
        var copy = self
        let visible = Int(Double(width) * framesPerPoint)
        copy.framesPerPoint = max(0.02, min(framesPerPoint, max(Double(frameCount), 1)))
        let maxStart = max(0, frameCount - visible)
        copy.startFrame = max(0, min(startFrame, maxStart))
        return copy
    }
}

struct WaveformView: View {
    @ObservedObject var clip: AudioClip
    @ObservedObject var engine: PlaybackEngine

    @Binding var selection: Range<Int>?
    @Binding var transform: WaveTransform
    var marked: [Range<Int>]
    var snapToZero: Bool

    /// Set while a selection drag is in flight, so we can extend from the
    /// original anchor rather than from the last mouse position.
    @State private var dragAnchor: Int?

    /// When and where the last click landed, for spotting a double-click.
    @State private var lastClickTime: Date?
    @State private var lastClickX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ruler(width: geo.size.width)
                lanes(size: CGSize(
                    width: geo.size.width,
                    height: max(geo.size.height - Theme.rulerHeight, 40)
                ))
            }
            .onChange(of: geo.size.width) { _, newWidth in
                transform = transform.clamped(
                    frameCount: clip.frameCount,
                    width: newWidth
                )
            }
        }
    }

    // MARK: - Ruler

    private func ruler(width: CGFloat) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Theme.chrome))

            guard clip.frameCount > 0 else { return }

            // Choose a tick spacing that gives roughly one label every 90
            // points, rounded to something a human would pick.
            let secondsVisible = Double(size.width) * transform.framesPerPoint / clip.sampleRate
            let targetTicks = max(Double(size.width) / 90, 1)
            let rawStep = secondsVisible / targetTicks
            let step = niceStep(rawStep)

            let firstSecond = floor(
                Double(transform.startFrame) / clip.sampleRate / step
            ) * step
            var t = firstSecond
            while t <= (Double(transform.startFrame) / clip.sampleRate) + secondsVisible {
                let frame = Int(t * clip.sampleRate)
                let x = transform.x(forFrame: frame)
                if x >= -40, x <= size.width + 40, t >= 0 {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: size.height - 7))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(Theme.textDim), lineWidth: 1)

                    context.draw(
                        Text(formatRulerTime(t))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Theme.textDim),
                        at: CGPoint(x: x + 3, y: 9),
                        anchor: .leading
                    )
                }
                t += step
            }

            // Playhead flag
            let px = transform.x(forFrame: engine.playhead)
            if px >= 0, px <= size.width {
                var head = Path()
                head.move(to: CGPoint(x: px, y: 0))
                head.addLine(to: CGPoint(x: px, y: size.height))
                context.stroke(head, with: .color(Theme.playhead), lineWidth: 1)
            }
        }
        .frame(height: Theme.rulerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard clip.frameCount > 0 else { return }
                    let frame = clampFrame(transform.frame(forX: value.location.x))
                    engine.scrub(to: frame)
                }
                .onEnded { _ in engine.endScrub() }
        )
    }

    /// 0.001, 0.002, 0.005, 0.01 ... the spacings that look deliberate.
    private func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        let normalised = raw / magnitude
        let snapped: Double
        switch normalised {
        case ..<1.5: snapped = 1
        case ..<3.5: snapped = 2
        case ..<7.5: snapped = 5
        default: snapped = 10
        }
        return snapped * magnitude
    }

    // MARK: - Lanes

    private func lanes(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            context.fill(Path(CGRect(origin: .zero, size: canvasSize)),
                         with: .color(Theme.background))

            guard clip.frameCount > 0, clip.channelCount > 0 else {
                context.draw(
                    Text("Drop an audio file here, or press ⌘O")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textDim),
                    at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                )
                return
            }

            let laneCount = clip.channelCount
            let laneHeight = canvasSize.height / CGFloat(laneCount)

            func laneRect(_ channel: Int) -> CGRect {
                CGRect(
                    x: 0,
                    y: CGFloat(channel) * laneHeight + Theme.lanePadding,
                    width: canvasSize.width,
                    height: laneHeight - Theme.lanePadding * 2
                )
            }

            // Order matters. Lane backgrounds are opaque, so they go down
            // first; then the region tints, which would otherwise be painted
            // over; then the waveform, which must stay the brightest thing on
            // screen.
            for channel in 0..<laneCount {
                drawLaneBackground(in: &context, rect: laneRect(channel))
            }

            for region in marked {
                paintRegion(region, in: &context, size: canvasSize,
                            fill: Theme.markFill, edge: Theme.markEdge)
            }
            if let selection {
                paintRegion(selection, in: &context, size: canvasSize,
                            fill: Theme.selectionFill, edge: Theme.selectionEdge)
            }

            for channel in 0..<laneCount {
                let top = CGFloat(channel) * laneHeight
                drawLaneWave(channel: channel, in: &context, rect: laneRect(channel))

                if channel > 0 {
                    var divider = Path()
                    divider.move(to: CGPoint(x: 0, y: top))
                    divider.addLine(to: CGPoint(x: canvasSize.width, y: top))
                    context.stroke(divider, with: .color(Theme.laneDivider),
                                   lineWidth: 1)
                }

                // L / R badge, only when there is more than one lane.
                if laneCount > 1 {
                    let label = channel == 0 ? "L" : (channel == 1 ? "R" : "\(channel + 1)")
                    context.draw(
                        Text(label)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.textDim),
                        at: CGPoint(x: 8, y: top + 10),
                        anchor: .leading
                    )
                }
            }

            // Playhead last, on top of everything.
            let px = transform.x(forFrame: engine.playhead)
            if px >= 0, px <= canvasSize.width {
                var head = Path()
                head.move(to: CGPoint(x: px, y: 0))
                head.addLine(to: CGPoint(x: px, y: canvasSize.height))
                context.stroke(head, with: .color(Theme.playhead), lineWidth: 1)
            }
        }
        .frame(height: size.height)
        .contentShape(Rectangle())
        // ONE gesture handles clicking, double-clicking and dragging.
        //
        // Every attempt to split these across separate SwiftUI gestures has
        // failed the same way: a zero-distance DragGesture and a TapGesture
        // both claim the same mouse-up, and whichever runs last wins. That is
        // what made small selections impossible (drag lost to tap) and then
        // what stopped double-click from selecting all (the tap set the
        // selection, then the drag's click branch cleared it a moment later).
        // Counting the clicks by hand is less elegant and completely
        // predictable.
        .gesture(selectionDrag)
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    transform = transform.zoomed(
                        by: 1 / max(value.magnification, 0.05),
                        around: engine.playhead,
                        limit: clip.frameCount
                    )
                }
        )
    }

    private func drawLaneBackground(
        in context: inout GraphicsContext,
        rect: CGRect
    ) {
        context.fill(
            Path(roundedRect: rect, cornerRadius: Theme.corner),
            with: .color(Theme.laneBackground)
        )
    }

    /// Draw one channel: for every point of width, one vertical line from the
    /// quietest to the loudest sample in the slice of audio behind that point.
    /// That is all a waveform display ever is.
    private func drawLaneWave(
        channel: Int,
        in context: inout GraphicsContext,
        rect: CGRect
    ) {
        let midY = rect.midY
        let halfHeight = rect.height / 2 - 1

        var centre = Path()
        centre.move(to: CGPoint(x: rect.minX, y: midY))
        centre.addLine(to: CGPoint(x: rect.maxX, y: midY))
        context.stroke(centre, with: .color(Theme.centreLine), lineWidth: 1)

        var outside = Path()
        var inside = Path()

        let step = max(transform.framesPerPoint, 1.0 / 8.0)
        var x = rect.minX
        while x <= rect.maxX {
            let from = transform.frame(forX: x)
            let to = from + Int(step.rounded(.up))
            if to <= 0 { x += 1; continue }
            if from >= clip.frameCount { break }

            let peak = clip.peak(channel: channel, from: from, to: to)
            let yTop = midY - CGFloat(max(peak.max, 0.0004)) * halfHeight
            let yBottom = midY - CGFloat(min(peak.min, -0.0004)) * halfHeight

            let inSelection = selection.map { $0.contains(from) } ?? false
            if inSelection {
                inside.move(to: CGPoint(x: x, y: yTop))
                inside.addLine(to: CGPoint(x: x, y: yBottom))
            } else {
                outside.move(to: CGPoint(x: x, y: yTop))
                outside.addLine(to: CGPoint(x: x, y: yBottom))
            }
            x += 1
        }

        context.stroke(outside, with: .color(Theme.wave), lineWidth: 1)
        context.stroke(inside, with: .color(Theme.waveInSelection), lineWidth: 1)
    }

    private func paintRegion(
        _ region: Range<Int>,
        in context: inout GraphicsContext,
        size: CGSize,
        fill: Color,
        edge: Color
    ) {
        let x0 = transform.x(forFrame: region.lowerBound)
        let x1 = transform.x(forFrame: region.upperBound)
        guard x1 >= 0, x0 <= size.width else { return }
        let clippedX0 = max(x0, 0)
        let clippedX1 = min(x1, size.width)
        let rect = CGRect(
            x: clippedX0,
            y: 0,
            width: max(clippedX1 - clippedX0, 1),
            height: size.height
        )
        context.fill(Path(rect), with: .color(fill))

        for x in [x0, x1] where x >= 0 && x <= size.width {
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(edge), lineWidth: 1)
        }
    }

    // MARK: - Selecting

    /// A drag shorter than this many points counts as a click, not a selection.
    ///
    /// Four points, measured on screen rather than in samples, which is the
    /// whole trick: it is small enough that a deliberate flick of the mouse
    /// still selects, and large enough that the pixel or two of jitter in a
    /// normal click does not. Because the threshold is in screen space, zooming
    /// in costs nothing: at high magnification four points is a handful of
    /// samples, so you can still select a single syllable.
    private static let clickSlop: CGFloat = 4

    private var selectionDrag: some Gesture {
        // minimumDistance 0 means the gesture starts on mouse-down, so even a
        // three-pixel drag produces a selection. The click case is sorted out
        // in onEnded by looking at how far the mouse actually travelled.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard clip.frameCount > 0 else { return }
                let travelled = abs(value.location.x - value.startLocation.x)
                let current = clampFrame(transform.frame(forX: value.location.x))

                if dragAnchor == nil {
                    dragAnchor = clampFrame(
                        transform.frame(forX: value.startLocation.x)
                    )
                }
                guard let anchor = dragAnchor else { return }

                // Below the slop it is still a click in progress: move the
                // playhead and do not invent a selection yet.
                guard travelled > Self.clickSlop else {
                    engine.playhead = current
                    return
                }

                let lo = min(anchor, current)
                let hi = max(anchor, current)
                // A real drag always yields at least one sample, however far
                // zoomed in. Without this floor, dragging while a single sample
                // spans many points produces lo == hi and nothing selects.
                selection = lo..<max(hi, lo + 1)

                // Scrubbing while selecting is what makes the drag feel like
                // it is touching the sound rather than drawing a rectangle.
                engine.scrub(to: current)
            }
            .onEnded { value in
                defer { dragAnchor = nil }
                engine.endScrub()
                guard clip.frameCount > 0 else { return }

                let travelled = abs(value.location.x - value.startLocation.x)
                if travelled <= Self.clickSlop {
                    let now = Date()
                    // Two clicks close together in both time and place select
                    // the whole clip. The time limit is the one the user set in
                    // System Settings, not a number invented here.
                    if let previousTime = lastClickTime,
                       let previousX = lastClickX,
                       now.timeIntervalSince(previousTime) <= NSEvent.doubleClickInterval,
                       abs(value.location.x - previousX) <= 6 {
                        selection = 0..<clip.frameCount
                        engine.playhead = 0
                        lastClickTime = nil
                        lastClickX = nil
                        return
                    }

                    // A single click: place the playhead, clear any selection,
                    // and remember it in case a second one follows.
                    lastClickTime = now
                    lastClickX = value.location.x
                    engine.playhead = clampFrame(
                        transform.frame(forX: value.location.x)
                    )
                    selection = nil
                    return
                }

                // A real drag is not part of any double-click.
                lastClickTime = nil
                lastClickX = nil

                // Snap only once the drag is finished, so the edges do not
                // jitter under the cursor while you are still moving.
                if let current = selection {
                    let snapped = clip.snapped(current, enabled: snapToZero)
                    selection = snapped
                    engine.playhead = snapped.lowerBound
                }
            }
    }

    // MARK: - Helpers

    private func clampFrame(_ frame: Int) -> Int {
        max(0, min(frame, max(clip.frameCount - 1, 0)))
    }
}
