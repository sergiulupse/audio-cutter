//
//  Theme.swift
//  Every colour and metric in one place, so the look can be changed without
//  hunting through the views.
//
//  The palette is deliberately tiny: a near-black stage, two greys for the
//  waveform, one accent. Restraint is the whole point of the app.
//

import SwiftUI

enum Theme {

    // Stage
    static let background = Color(red: 0.055, green: 0.059, blue: 0.067)
    static let laneBackground = Color(red: 0.086, green: 0.090, blue: 0.102)
    static let laneDivider = Color.white.opacity(0.06)
    static let chrome = Color(red: 0.098, green: 0.102, blue: 0.114)

    // Waveform
    static let wave = Color(red: 0.62, green: 0.66, blue: 0.72)
    static let waveInSelection = Color(red: 0.95, green: 0.96, blue: 0.98)
    static let centreLine = Color.white.opacity(0.10)

    // Accent: a single warm signal colour, used for selection and playhead.
    static let accent = Color(red: 1.00, green: 0.58, blue: 0.20)
    static let selectionFill = accent.opacity(0.16)
    static let selectionEdge = accent.opacity(0.85)

    // Marked regions sit behind the live selection, quieter.
    static let markFill = Color(red: 0.36, green: 0.62, blue: 0.98).opacity(0.16)
    static let markEdge = Color(red: 0.36, green: 0.62, blue: 0.98).opacity(0.55)

    static let playhead = Color.white
    static let text = Color.white.opacity(0.92)
    static let textDim = Color.white.opacity(0.45)

    // Metrics
    static let rulerHeight: CGFloat = 26
    static let lanePadding: CGFloat = 6
    static let corner: CGFloat = 6
}

/// Seconds shown as m:ss.mmm, which is the only format that is useful when
/// you are cutting on a syllable.
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00.000" }
    let minutes = Int(seconds) / 60
    let secs = Int(seconds) % 60
    let millis = Int((seconds - floor(seconds)) * 1000)
    return String(format: "%d:%02d.%03d", minutes, secs, millis)
}

/// Shorter form for the ruler, where space is tight.
func formatRulerTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let minutes = Int(seconds) / 60
    let secs = Int(seconds) % 60
    if seconds < 10 {
        return String(format: "%.2fs", seconds)
    }
    return String(format: "%d:%02d", minutes, secs)
}
