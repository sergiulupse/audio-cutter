//
//  AppDelegate.swift
//  Opening files from outside the app: double-clicking an audio file in Finder,
//  dropping one on the Dock icon, or `open -a "Audio Cutter" song.mp3`.
//
//  SwiftUI's `Window` scene has no built-in hook for this, so we keep a small
//  AppKit delegate. macOS hands it the URLs, it broadcasts them, and the editor
//  picks them up. If a file arrives before the window exists (which is what
//  happens when the app is launched *by* the file) it is held in `pending`
//  until the editor asks for it.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let audioCutterOpenURL = Notification.Name("AudioCutterOpenURL")
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// A file that arrived before there was a window to show it in.
    static var pending: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        AppDelegate.pending = url
        NotificationCenter.default.post(
            name: .audioCutterOpenURL,
            object: nil,
            userInfo: ["url": url]
        )
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A single-window utility should come to the front when launched.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quit when the window is closed. This is a tool, not a document app;
    /// leaving a menu bar behind with no window is just clutter.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }
}
