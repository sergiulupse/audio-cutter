//
//  Exporter.swift
//  Writing audio back out to disk.
//
//  WHAT MACOS CAN AND CANNOT DO ON ITS OWN
//  --------------------------------------------------------------------------
//  AVFoundation will happily *decode* almost anything, but it only *encodes* a
//  shorter list. Natively we can write:
//
//      WAV, AIFF, CAF   uncompressed, lossless, instant
//      M4A (AAC)        compressed, what Apple uses everywhere
//      FLAC             compressed, lossless (macOS 10.13 and later)
//
//  MP3 is the exception: Apple removed the MP3 encoder years ago (patents,
//  now expired, but it never came back). So for MP3 we write a temporary WAV
//  and hand it to ffmpeg or lame if either is installed. Both are on this
//  machine via Homebrew. If neither is found, the app says so plainly rather
//  than silently producing something else.
//

import AVFoundation
import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case wav = "WAV"
    case aiff = "AIFF"
    case flac = "FLAC"
    case m4a = "M4A"
    case mp3 = "MP3"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .flac: return "flac"
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        }
    }

    var isLossless: Bool {
        switch self {
        case .wav, .aiff, .flac: return true
        case .m4a, .mp3: return false
        }
    }

    /// MP3 needs an outside encoder, so the UI can grey it out if missing.
    var needsExternalEncoder: Bool { self == .mp3 }

    var subtitle: String {
        switch self {
        case .wav: return "Uncompressed, 24-bit. The safe default."
        case .aiff: return "Uncompressed, 24-bit, Apple's old container."
        case .flac: return "Compressed with no quality loss. Half the size of WAV."
        case .m4a: return "AAC, small, very good quality."
        case .mp3: return "Universal. Needs ffmpeg or lame installed."
        }
    }
}

struct Exporter {

    // MARK: - Public entry point

    /// Write `channels` to `url` in `format`.
    /// Runs on a background thread; never call this on the main actor.
    static func write(
        channels: [[Float]],
        sampleRate: Double,
        to url: URL,
        format: ExportFormat,
        bitrate: Int = 320_000
    ) throws {
        guard let first = channels.first, !first.isEmpty else {
            throw CutterError.message("There is nothing to export.")
        }

        if format == .mp3 {
            try writeMP3(
                channels: channels,
                sampleRate: sampleRate,
                to: url,
                bitrate: bitrate
            )
            return
        }

        try writeNative(
            channels: channels,
            sampleRate: sampleRate,
            to: url,
            format: format,
            bitrate: bitrate
        )
    }

    // MARK: - Native encoders

    private static func writeNative(
        channels: [[Float]],
        sampleRate: Double,
        to url: URL,
        format: ExportFormat,
        bitrate: Int
    ) throws {
        let channelCount = channels.count
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount
        ]

        switch format {
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        case .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = true
            settings[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = min(bitrate, 256_000)
        case .mp3:
            throw CutterError.message("MP3 is handled separately.")
        }

        // Remove any existing file: AVAudioFile will not overwrite in place.
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            if format == .flac {
                throw CutterError.message(
                    "This Mac's FLAC encoder refused the file. Export as WAV, or install ffmpeg for FLAC."
                )
            }
            throw error
        }

        guard let writeFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount)
        ) else {
            throw CutterError.message("Could not build an output format.")
        }

        // Hand the samples over one second at a time. AVAudioFile converts
        // from our float buffers to whatever the settings above asked for.
        let total = channels[0].count
        let chunk = Int(sampleRate)
        var offset = 0
        while offset < total {
            let n = min(chunk, total - offset)
            let piece = channels.map { Array($0[offset..<(offset + n)]) }
            guard let buffer = PlaybackEngine.makeBuffer(
                from: piece,
                format: writeFormat
            ) else { break }
            try file.write(from: buffer)
            offset += n
        }
    }

    // MARK: - MP3 by way of ffmpeg or lame

    /// Where Homebrew and friends install command line tools. Checked in order.
    private static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin"
    ]

    static func locate(_ tool: String) -> URL? {
        for dir in searchPaths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// True when MP3 export is possible on this machine.
    static var mp3Available: Bool {
        locate("ffmpeg") != nil || locate("lame") != nil
    }

    static var mp3EncoderName: String {
        if locate("ffmpeg") != nil { return "ffmpeg" }
        if locate("lame") != nil { return "lame" }
        return "none"
    }

    private static func writeMP3(
        channels: [[Float]],
        sampleRate: Double,
        to url: URL,
        bitrate: Int
    ) throws {
        guard let encoder = locate("ffmpeg") ?? locate("lame") else {
            throw CutterError.message(
                "MP3 export needs ffmpeg or lame installed. Try: brew install ffmpeg"
            )
        }

        // Stage a lossless WAV in the temp folder, encode from that, delete it.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiocutter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temp) }

        try writeNative(
            channels: channels,
            sampleRate: sampleRate,
            to: temp,
            format: .wav,
            bitrate: bitrate
        )

        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let kbps = max(64, min(320, bitrate / 1000))
        let args: [String]
        if encoder.lastPathComponent == "ffmpeg" {
            args = [
                "-hide_banner", "-loglevel", "error", "-y",
                "-i", temp.path,
                "-codec:a", "libmp3lame",
                "-b:a", "\(kbps)k",
                url.path
            ]
        } else {
            args = ["-b", "\(kbps)", "--quiet", temp.path, url.path]
        }

        let process = Process()
        process.executableURL = encoder
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CutterError.message(
                "\(encoder.lastPathComponent) failed"
                    + (message.isEmpty ? "." : ":\n\(message)")
            )
        }
    }

    // MARK: - Lossless cutting

    /// Copy a stretch of a compressed file out to a new file without decoding
    /// it, so the audio that comes out is bit-for-bit the audio that went in.
    ///
    /// WHY THIS MATTERS
    /// ----------------------------------------------------------------------
    /// Normally this app decodes to float, edits, and re-encodes. If the source
    /// was already MP3 or AAC, that means compressing audio a second time, and
    /// doing that repeatedly audibly wears it out. This path avoids it entirely:
    /// ffmpeg copies the encoded frames across untouched. It is the same trick
    /// the well-known paid Mac editor is built around.
    ///
    /// THE CATCH, stated plainly
    /// ----------------------------------------------------------------------
    /// Compressed audio is stored in frames, roughly 26 ms each for MP3, and a
    /// frame cannot be split. So the cut lands on the nearest frame boundary
    /// rather than the exact sample you selected. If you need the cut to be
    /// sample accurate, re-encode instead, or export to WAV or FLAC.
    ///
    /// Only valid when the audio in memory has not been edited, which the caller
    /// checks with `AudioClip.isPristine`.
    static func losslessCut(
        source: URL,
        startSeconds: Double,
        durationSeconds: Double,
        to url: URL
    ) throws {
        guard let ffmpeg = locate("ffmpeg") else {
            throw CutterError.message(
                "Lossless cutting needs ffmpeg installed. Try: brew install ffmpeg"
            )
        }
        guard durationSeconds > 0.001 else {
            throw CutterError.message("That selection is too short to export.")
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            // -ss before -i seeks by keyframe, which is what makes the copy
            // cheap and lossless.
            "-ss", String(format: "%.6f", startSeconds),
            "-t", String(format: "%.6f", durationSeconds),
            "-i", source.path,
            "-c", "copy",
            // Drop any video stream (cover art) so the result is pure audio.
            "-vn",
            "-map", "0:a",
            url.path
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CutterError.message(
                "Lossless cut failed" + (message.isEmpty ? "." : ":\n\(message)")
            )
        }
    }

    /// Whether a lossless cut is possible right now.
    ///
    /// Four things have to line up: nothing has been edited, the source is a
    /// compressed format where re-encoding would actually cost quality, the
    /// export format matches the source, and ffmpeg is installed.
    static func canCutLosslessly(
        source: URL?,
        isPristine: Bool,
        format: ExportFormat
    ) -> Bool {
        guard isPristine, let source, locate("ffmpeg") != nil else { return false }
        let sourceExt = source.pathExtension.lowercased()
        guard !format.isLossless else { return false }
        switch format {
        case .mp3: return sourceExt == "mp3"
        case .m4a: return ["m4a", "aac", "mp4"].contains(sourceExt)
        default: return false
        }
    }

    // MARK: - Filenames

    /// "song.mp3" plus " Cut" becomes "song Cut.wav", avoiding a clash with
    /// whatever is already sitting in the folder.
    static func suggestedName(
        from source: URL?,
        suffix: String,
        format: ExportFormat
    ) -> String {
        let base = source?.deletingPathExtension().lastPathComponent ?? "Audio"
        let name = suffix.isEmpty ? base : "\(base) \(suffix)"
        return "\(name).\(format.fileExtension)"
    }
}
