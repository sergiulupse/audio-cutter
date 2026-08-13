//
//  EditorView.swift
//  The window: toolbar, waveform, status line, and every action wired up.
//

import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct EditorView: View {

    @StateObject private var clip = AudioClip()
    @StateObject private var engine = PlaybackEngine()
    /// Raw keyboard and scroll-wheel events. See InputMonitors.swift for why
    /// these cannot be done with SwiftUI alone.
    @StateObject private var input = InputMonitors()

    /// The live selection, in samples. `nil` means nothing is selected, which
    /// is what makes every action fall back to "the whole clip".
    @State private var selection: Range<Int>?
    /// Extra regions the user has marked with ⌘M.
    @State private var marked: [Range<Int>] = []

    @State private var transform = WaveTransform()
    @State private var viewWidth: CGFloat = 800
    /// Where the waveform sits inside the window, in window coordinates.
    /// Needed because scroll events arrive from AppKit with window coordinates
    /// and have to be turned back into a sample position.
    @State private var waveFrame: CGRect = .zero

    @State private var snapToZero = true
    /// Prefer copying compressed audio out untouched over re-encoding it.
    @State private var preferLossless = true
    @State private var loop = false
    @State private var exportFormat: ExportFormat = .wav

    @State private var busy: String?
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.laneDivider)

            WaveformView(
                clip: clip,
                engine: engine,
                selection: $selection,
                transform: $transform,
                marked: marked,
                snapToZero: snapToZero
            )
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            viewWidth = geo.size.width
                            waveFrame = geo.frame(in: .global)
                        }
                        // Resizing the window keeps the waveform filling it:
                        // fully zoomed out stays fully fitted, zoomed in keeps
                        // the same stretch of time on screen.
                        .onChange(of: geo.size.width) { oldWidth, newWidth in
                            transform = transform
                                .refitted(fromWidth: oldWidth, toWidth: newWidth)
                                .clamped(frameCount: clip.frameCount, width: newWidth)
                            viewWidth = newWidth
                            waveFrame = geo.frame(in: .global)
                        }
                        .onChange(of: geo.frame(in: .global)) { _, frame in
                            waveFrame = frame
                        }
                }
            )
            .dropDestination(for: URL.self) { urls, _ in
                if let first = urls.first { load(url: first) }
                return true
            }

            if clip.frameCount > 0 {
                panStrip
            }

            Divider().overlay(Theme.laneDivider)
            statusBar
        }
        .background(Theme.background)
        // Wide enough that the toolbar never has to truncate a label. Measured
        // against the real control widths rather than guessed.
        .frame(minWidth: 1040, minHeight: 420)
        .overlay(alignment: .top) { toastView }
        .overlay { busyView }
        .alert(
            "Audio Cutter",
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )
        ) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        // Invisible buttons purely to own keyboard shortcuts.
        .background(shortcuts)
        .onChange(of: loop) { _, value in engine.loop = value }
        // Keep the playhead on screen while it moves. Without this, playing a
        // zoomed-in clip walks the cursor off the right edge and it never comes
        // back, which reads as "the cursor disappeared".
        .onChange(of: engine.playhead) { _, _ in followPlayhead() }
        // Files opened from Finder, the Dock, or the `open` command.
        .onReceive(NotificationCenter.default.publisher(for: .audioCutterOpenURL)) { note in
            if let url = note.userInfo?["url"] as? URL { load(url: url) }
        }
        .onAppear {
            // Bare keys and the scroll wheel, which SwiftUI cannot give us.
            input.onKeyDown = handleKey
            input.onScroll = handleScroll
            input.start()

            // A file that arrived while the window was still being created.
            if let pending = AppDelegate.pending {
                AppDelegate.pending = nil
                load(url: pending)
            }
        }
        .onDisappear { input.stop() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                openFile()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open an audio file (⌘O)")

            divider

            // Transport. The layout matches the J / K / L keys underneath it:
            // rewind, play-pause, fast forward.
            HStack(spacing: 4) {
                iconButton("backward.end.fill", help: "Back to start (Return)") {
                    engine.stop()
                    engine.playhead = selection?.lowerBound ?? 0
                }
                iconButton(
                    "backward.fill",
                    help: "Play backwards, press again for 2x then 4x (J)"
                ) {
                    engine.shuttleBackward(range: selection ?? 0..<clip.frameCount)
                }
                iconButton(
                    engine.isPlaying ? "pause.fill" : "play.fill",
                    help: engine.isPlaying ? "Pause (Space or K)" : "Play (Space or K)",
                    prominent: true
                ) {
                    togglePlay()
                }
                iconButton(
                    "forward.fill",
                    help: "Play forwards, press again for 2x then 4x (L)"
                ) {
                    engine.shuttleForward(range: selection ?? 0..<clip.frameCount)
                }

                // The quick double-speed toggle, and a menu for everything else.
                // fixedSize on both: without it a crowded toolbar shrinks the
                // labels to nothing and you get a blank button.
                Button("2x") {
                    engine.setRate(engine.rate == 2 ? 1 : 2)
                }
                .help("Jump between normal speed and double speed")
                .tint(engine.rate == 2 ? Theme.accent : nil)
                .fixedSize()

                Menu {
                    ForEach(PlaybackEngine.rateLadder, id: \.self) { rate in
                        Button(rateLabel(rate)) { engine.setRate(rate) }
                    }
                } label: {
                    Text(rateLabel(engine.rate))
                        .monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Playback speed. This is tape speed, so pitch moves with it.")

                Toggle(isOn: $loop) {
                    Image(systemName: "repeat")
                }
                .toggleStyle(.button)
                .help("Loop the played range")
            }
            .disabled(clip.isEmpty)

            divider

            // The two operations the app exists for.
            Button {
                keepSelection()
            } label: {
                Label("Keep", systemImage: "scissors")
            }
            .help("Throw away everything outside the selection (⌘K)")
            .disabled(selection == nil)
            .fixedSize()

            Button {
                deleteSelection()
            } label: {
                Label("Delete", systemImage: "delete.left")
            }
            .help("Remove the selection and close the gap (Delete)")
            .disabled(selection == nil)
            .fixedSize()

            divider

            // Marking lives inside the Regions menu rather than as its own
            // button. It belongs with the other region actions, and the toolbar
            // has no width to spare.
            Menu {
                Button("Mark this selection") { markSelection() }
                    .disabled(selection == nil)
                Divider()
                Button("Delete all \(marked.count) marked regions") {
                    deleteMarked()
                }
                .disabled(marked.isEmpty)
                Button("Export each marked region as a file…") {
                    exportEachMarked()
                }
                .disabled(marked.isEmpty)
                Divider()
                Button("Clear marks") { marked = [] }
                    .disabled(marked.isEmpty)
            } label: {
                Text(marked.isEmpty ? "Regions" : "Regions (\(marked.count))")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            divider

            Menu {
                Button("Normalize") { clip.normalize(); afterEdit(keepSelection: true) }
                Button("Fade in over selection") { applyFade(fadingIn: true) }
                    .disabled(selection == nil)
                Button("Fade out over selection") { applyFade(fadingIn: false) }
                    .disabled(selection == nil)
                Button("Silence selection") {
                    guard let s = snappedSelection() else { return }
                    clip.silence(s)
                    afterEdit(keepSelection: true)
                }
                .disabled(selection == nil)
                Button("Reverse selection") {
                    clip.reverse(snappedSelection())
                    afterEdit(keepSelection: true)
                }
                Divider()
                Button("Trim silence from both ends") { trimSilence() }
                Divider()
                Toggle("Snap edits to zero crossings", isOn: $snapToZero)
                Toggle("Lossless cut when possible", isOn: $preferLossless)
            } label: {
                Label("Clean up", systemImage: "wand.and.stars")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(clip.isEmpty)

            Spacer()

            zoomControls

            divider

            Picker("", selection: $exportFormat) {
                ForEach(ExportFormat.allCases) { fmt in
                    Text(fmt.rawValue).tag(fmt)
                }
            }
            .frame(width: 78)
            .help(exportFormat.subtitle)

            Button {
                exportSelectionOrAll()
            } label: {
                Label(
                    selection == nil ? "Export" : "Export Selection",
                    systemImage: "square.and.arrow.up"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .help("Write to disk (⌘E)")
            .disabled(clip.isEmpty)
            .fixedSize()   // never truncate the one label that must be read
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.chrome)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .tint(Theme.accent)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.laneDivider)
            .frame(width: 1, height: 18)
    }

    private func iconButton(
        _ systemName: String,
        help: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 16)
        }
        .help(help)
        .buttonStyle(.bordered)
        .tint(prominent ? Theme.accent : nil)
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            iconButton("minus.magnifyingglass", help: "Zoom out") {
                transform.framesPerPoint = min(
                    transform.framesPerPoint * 2,
                    max(Double(clip.frameCount), 1)
                )
                clampTransform()
            }
            iconButton("plus.magnifyingglass", help: "Zoom in") {
                transform.framesPerPoint = max(transform.framesPerPoint / 2, 0.02)
                clampTransform()
            }
            // fixedSize so these never shrink into an ellipsis.
            Button("Fit") { fitAll() }
                .help("Show the whole clip (⌘0)")
                .fixedSize()
            Button("Sel") { fitSelection() }
                .help("Zoom to the selection")
                .disabled(selection == nil)
                .fixedSize()
        }
        .disabled(clip.isEmpty)
    }

    /// A slider to move along the clip once you are zoomed in past the window.
    private var panStrip: some View {
        let visible = Double(viewWidth) * transform.framesPerPoint
        let maxStart = max(Double(clip.frameCount) - visible, 0)
        return Group {
            if maxStart > 1 {
                Slider(
                    value: Binding(
                        get: { min(Double(transform.startFrame), maxStart) },
                        set: { transform.startFrame = Int($0) }
                    ),
                    in: 0...maxStart
                )
                .controlSize(.mini)
                .tint(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Theme.chrome)
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            if clip.isEmpty {
                Text("No file open")
                    .foregroundColor(Theme.textDim)
            } else {
                Text(clip.sourceURL?.lastPathComponent ?? "Untitled")
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(clip.sourceDescription)
                    .foregroundColor(Theme.textDim)
                Text("length \(formatTime(clip.duration))")
                    .foregroundColor(Theme.textDim)
                if let selection {
                    Text(
                        "selection \(formatTime(Double(selection.count) / clip.sampleRate))"
                            + "  ·  \(formatTime(Double(selection.lowerBound) / clip.sampleRate))"
                            + " → \(formatTime(Double(selection.upperBound) / clip.sampleRate))"
                    )
                    .foregroundColor(Theme.accent)
                }
            }
            Spacer()
            // Undo history is capped by memory, not just by count, so on a long
            // recording you genuinely get fewer steps. Say so rather than
            // letting ⌘Z quietly run out.
            if clip.undoDepth > 0 {
                Text("undo \(clip.undoDepth)")
                    .foregroundColor(Theme.textDim)
                    .help("Undo steps available. Long files hold fewer, because each step is a full copy of the audio.")
            }
            if !clip.isEmpty {
                Text("playhead \(formatTime(Double(engine.playhead) / clip.sampleRate))")
                    .foregroundColor(Theme.textDim)
            }
            if losslessPossible {
                Text("lossless ready")
                    .foregroundColor(Theme.accent)
                    .help("This selection can be exported without re-encoding, so no quality is lost. The cut lands on the nearest compressed frame, within about 26 ms.")
            }
            if !Exporter.mp3Available {
                Text("MP3 unavailable")
                    .foregroundColor(Theme.textDim)
                    .help("Install ffmpeg or lame to export MP3.")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.chrome)
    }

    private var toastView: some View {
        Group {
            if let toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.accent.opacity(0.95))
                    )
                    .foregroundColor(.black)
                    .padding(.top, 46)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: toast)
    }

    private var busyView: some View {
        Group {
            if let busy {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(busy).font(.system(size: 12))
                }
                .padding(22)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(Theme.chrome)
                )
                .shadow(radius: 20)
            }
        }
    }

    // MARK: - Keyboard

    /// The command-key shortcuts. These are safe to leave to SwiftUI, because
    /// nothing else in the window competes for them.
    private var shortcuts: some View {
        Group {
            Button("") { openFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button("") { keepSelection() }
                .keyboardShortcut("k", modifiers: .command)
            Button("") { deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("") { markSelection() }
                .keyboardShortcut("m", modifiers: .command)
            Button("") { exportSelectionOrAll() }
                .keyboardShortcut("e", modifiers: .command)
            Button("") { clip.undo(); afterEdit(keepSelection: false) }
                .keyboardShortcut("z", modifiers: .command)
            Button("") { selection = 0..<clip.frameCount }
                .keyboardShortcut("a", modifiers: .command)
            Button("") { fitAll() }
                .keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    /// The bare keys: Space, Delete, J / K / L, Return, Escape, arrows.
    ///
    /// These go through an AppKit event monitor rather than SwiftUI shortcuts,
    /// because a hidden button holding a modifier-free key loses to whatever
    /// control has focus. Returning true swallows the key.
    private func handleKey(_ event: NSEvent) -> Bool {
        // Anything with command, option or control belongs to the menus above.
        guard event.hasNoCommandModifiers else { return false }

        let whole = selection ?? 0..<clip.frameCount

        switch event.keyCode {
        case KeyCode.space:
            guard !clip.isEmpty else { return false }
            togglePlay()
            return true

        case KeyCode.delete, KeyCode.forwardDelete:
            // Plain Delete removes the selection. With nothing selected, let
            // the key through rather than wiping the whole file by accident.
            guard selection != nil else { return false }
            deleteSelection()
            return true

        case KeyCode.returnKey:
            guard !clip.isEmpty else { return false }
            engine.stop()
            engine.playhead = selection?.lowerBound ?? 0
            return true

        case KeyCode.escape:
            selection = nil
            return true

        case KeyCode.leftArrow, KeyCode.rightArrow:
            guard !clip.isEmpty else { return false }
            // Nudge the playhead: a tenth of a second, or a whole second with
            // shift held.
            let step = event.modifierFlags.contains(.shift) ? 1.0 : 0.1
            let frames = Int(step * clip.sampleRate)
            let direction = event.keyCode == KeyCode.leftArrow ? -1 : 1
            engine.playhead = max(0, min(
                engine.playhead + frames * direction,
                max(clip.frameCount - 1, 0)
            ))
            return true

        default:
            break
        }

        // J / K / L: the shuttle keys every editor shares.
        switch event.plainCharacter {
        case "j":
            guard !clip.isEmpty else { return false }
            engine.shuttleBackward(range: whole)
            return true
        case "k":
            guard !clip.isEmpty else { return false }
            engine.pause()
            return true
        case "l":
            guard !clip.isEmpty else { return false }
            engine.shuttleForward(range: whole)
            return true
        default:
            return false
        }
    }

    // MARK: - Scroll wheel

    /// Wheel or two-finger scroll over the waveform: zoom around the pointer.
    /// Horizontal scrolling pans instead.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard !clip.isEmpty else { return false }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard dx != 0 || dy != 0 else { return false }

        // AppKit gives the pointer in window coordinates, whose x axis matches
        // SwiftUI's global space, so x needs no conversion. Only x matters here.
        let pointerX = event.locationInWindow.x - waveFrame.minX
        let clampedX = max(0, min(pointerX, waveFrame.width))
        let anchor = max(0, min(
            transform.frame(forX: clampedX),
            max(clip.frameCount - 1, 0)
        ))

        if abs(dx) > abs(dy) {
            // Pan. framesPerPoint converts screen travel into samples.
            transform.startFrame -= Int(Double(dx) * transform.framesPerPoint)
        } else {
            // Zoom. A trackpad sends many small precise deltas, a wheel sends
            // one chunky notch, so they need different sensitivities or the
            // trackpad flies off the scale.
            let factor: Double
            if event.hasPreciseScrollingDeltas {
                factor = pow(1.004, -Double(dy))
            } else {
                factor = dy > 0 ? 1 / 1.3 : 1.3
            }
            transform = transform.zoomed(
                by: factor,
                around: anchor,
                limit: clip.frameCount
            )
        }

        clampTransform()
        return true
    }

    /// "1x", "0.5x", "2x". Trailing zeros dropped, because "1.0x" reads worse.
    private func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded()
            ? String(format: "%.0fx", rate)
            : String(format: "%.2gx", rate)
    }

    // MARK: - Opening

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    private func load(url: URL) {
        busy = "Reading \(url.lastPathComponent)…"
        Task {
            do {
                let decoded = try await Task.detached(priority: .userInitiated) {
                    try AudioClip.decode(url: url)
                }.value
                clip.adopt(decoded)
                engine.prepare(for: clip)
                engine.playhead = 0
                selection = nil
                marked = []
                fitAll()
                busy = nil
            } catch {
                busy = nil
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Transport

    private func togglePlay() {
        guard !clip.isEmpty else { return }
        if engine.isPlaying {
            engine.pause()
            return
        }
        let range = selection ?? 0..<clip.frameCount
        let from = range.contains(engine.playhead) ? engine.playhead : range.lowerBound
        engine.play(range: range, from: from, backwards: false)
    }

    // Backwards playback now goes through engine.shuttleBackward, so that
    // pressing J or the rewind button a second time steps up the speed instead
    // of restarting. The old playBackwards() helper was removed.

    // MARK: - Edits

    /// The selection with zero-crossing snapping applied, which is what every
    /// destructive action should actually use.
    private func snappedSelection() -> Range<Int>? {
        guard let selection else { return nil }
        return clip.snapped(selection, enabled: snapToZero)
    }

    private func keepSelection() {
        guard let range = snappedSelection() else { return }
        engine.stop()
        clip.keep(range)
        selection = nil
        marked = []
        engine.playhead = 0
        engine.prepare(for: clip)
        fitAll()
        show("Kept \(formatTime(clip.duration))")
    }

    private func deleteSelection() {
        guard let range = snappedSelection() else { return }
        engine.stop()
        let removed = Double(range.count) / clip.sampleRate
        clip.delete(range)
        selection = nil
        marked = []
        engine.playhead = min(range.lowerBound, max(clip.frameCount - 1, 0))
        engine.prepare(for: clip)
        fitAll()
        show("Removed \(formatTime(removed))")
    }

    private func markSelection() {
        guard let range = snappedSelection() else { return }
        marked.append(range)
        marked.sort { $0.lowerBound < $1.lowerBound }
        selection = nil
        show("\(marked.count) region\(marked.count == 1 ? "" : "s") marked")
    }

    private func deleteMarked() {
        guard !marked.isEmpty else { return }
        engine.stop()
        let count = marked.count
        clip.delete(ranges: marked)
        marked = []
        selection = nil
        engine.playhead = 0
        engine.prepare(for: clip)
        fitAll()
        show("Removed \(count) regions")
    }

    private func applyFade(fadingIn: Bool) {
        guard let range = snappedSelection() else { return }
        clip.fade(range, fadingIn: fadingIn)
        afterEdit(keepSelection: true)
        show(fadingIn ? "Faded in" : "Faded out")
    }

    /// True when the current selection could be copied out without re-encoding.
    private var losslessPossible: Bool {
        preferLossless && Exporter.canCutLosslessly(
            source: clip.sourceURL,
            isPristine: clip.isPristine,
            format: exportFormat
        )
    }

    private func trimSilence() {
        engine.stop()
        let removed = clip.trimSilence()
        selection = nil
        marked = []
        engine.playhead = 0
        engine.prepare(for: clip)
        fitAll()
        show(removed > 0
             ? "Trimmed \(formatTime(removed)) of silence"
             : "No silence to trim")
    }

    /// Housekeeping after an edit that did not change the clip's length.
    private func afterEdit(keepSelection: Bool) {
        if !keepSelection { selection = nil }
        if clip.frameCount == 0 { marked = [] }
        engine.playhead = min(engine.playhead, max(clip.frameCount - 1, 0))
    }

    // MARK: - Export

    private func exportSelectionOrAll() {
        guard !clip.isEmpty else { return }
        if exportFormat == .mp3, !Exporter.mp3Available {
            error = "MP3 export needs ffmpeg or lame installed.\nTry: brew install ffmpeg"
            return
        }

        let range = snappedSelection() ?? 0..<clip.frameCount
        let suffix = selection == nil ? "" : "Cut"

        let panel = NSSavePanel()
        panel.nameFieldStringValue = Exporter.suggestedName(
            from: clip.sourceURL,
            suffix: suffix,
            format: exportFormat
        )
        if let dir = clip.sourceURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data = clip.slice(range)
        let rate = clip.sampleRate
        let format = exportFormat
        let lossless = losslessPossible
        let source = clip.sourceURL
        let startSeconds = Double(range.lowerBound) / rate
        let durationSeconds = Double(range.count) / rate
        busy = "Writing \(url.lastPathComponent)…"

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if lossless, let source {
                        // Copy the encoded frames straight across: no decode,
                        // no re-encode, no quality lost.
                        try Exporter.losslessCut(
                            source: source,
                            startSeconds: startSeconds,
                            durationSeconds: durationSeconds,
                            to: url
                        )
                    } else {
                        try Exporter.write(
                            channels: data,
                            sampleRate: rate,
                            to: url,
                            format: format
                        )
                    }
                }.value
                busy = nil
                show(lossless
                     ? "Exported losslessly, no re-encode"
                     : "Exported \(url.lastPathComponent)")
            } catch {
                busy = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func exportEachMarked() {
        guard !marked.isEmpty else { return }
        if exportFormat == .mp3, !Exporter.mp3Available {
            error = "MP3 export needs ffmpeg or lame installed.\nTry: brew install ffmpeg"
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        if let dir = clip.sourceURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let base = clip.sourceURL?.deletingPathExtension().lastPathComponent ?? "Audio"
        let pieces = marked.map { clip.slice($0) }
        let rate = clip.sampleRate
        let format = exportFormat
        busy = "Writing \(pieces.count) files…"

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    for (index, data) in pieces.enumerated() {
                        let name = String(format: "%@ %02d.%@",
                                          base, index + 1, format.fileExtension)
                        try Exporter.write(
                            channels: data,
                            sampleRate: rate,
                            to: folder.appendingPathComponent(name),
                            format: format
                        )
                    }
                }.value
                busy = nil
                show("Exported \(pieces.count) files")
            } catch {
                busy = nil
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - View helpers

    private func fitAll() {
        guard clip.frameCount > 0 else { return }
        transform = .fitting(frameCount: clip.frameCount, width: viewWidth)
    }

    private func fitSelection() {
        guard let selection, selection.count > 1 else { return }
        // A little air on each side so the edges are visible.
        let pad = selection.count / 12
        let lo = max(0, selection.lowerBound - pad)
        let hi = min(clip.frameCount, selection.upperBound + pad)
        transform = WaveTransform(
            framesPerPoint: max(Double(hi - lo) / Double(max(viewWidth, 1)), 0.02),
            startFrame: lo
        )
    }

    /// Scroll the view when the playhead reaches its edge, the way a tape
    /// machine's window follows the tape.
    ///
    /// Only while playing, so it never fights you when you are panning by hand,
    /// and only when zoomed in far enough that some of the clip is off screen.
    private func followPlayhead() {
        guard engine.isPlaying, clip.frameCount > 0, viewWidth > 1 else { return }

        let visible = Int(Double(viewWidth) * transform.framesPerPoint)
        // The whole clip already fits: there is nothing to follow.
        guard visible > 0, visible < clip.frameCount else { return }

        let head = engine.playhead
        let left = transform.startFrame
        let right = left + visible
        // A margin of a tenth of the window, so the playhead does not sit
        // exactly on the edge before the view moves.
        let margin = max(visible / 10, 1)

        guard head < left + margin || head > right - margin else { return }

        // Land the playhead a tenth of the way in from the edge it is heading
        // away from, which leaves the most of what is coming next visible.
        let lead = engine.playingBackwards
            ? Int(Double(visible) * 0.9)
            : Int(Double(visible) * 0.1)
        transform.startFrame = max(0, min(head - lead, clip.frameCount - visible))
    }

    private func clampTransform() {
        transform = transform.clamped(frameCount: clip.frameCount, width: viewWidth)
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == message { toast = nil }
        }
    }
}
