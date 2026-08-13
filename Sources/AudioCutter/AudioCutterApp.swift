//
//  AudioCutterApp.swift
//  The entry point. One window, no document model, no inspector, no sidebar.
//

import SwiftUI

@main
struct AudioCutterApp: App {
    /// Lets the AppKit delegate above receive Finder's open-file events.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Audio Cutter", id: "main") {
            EditorView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1160, height: 640)
        .commands {
            // Replace the default text-editing menus, which mean nothing here.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {}
        }
    }
}
