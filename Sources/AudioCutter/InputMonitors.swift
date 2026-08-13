//
//  InputMonitors.swift
//  Raw keyboard and scroll-wheel handling.
//
//  WHY THIS FILE EXISTS
//  --------------------------------------------------------------------------
//  SwiftUI on macOS has two holes that matter for an app like this:
//
//  1. There is no scroll-wheel event. `MagnifyGesture` covers a trackpad pinch
//     and nothing covers a mouse wheel, so zooming with the wheel is simply not
//     expressible in pure SwiftUI.
//
//  2. Bare keys are unreliable. `.keyboardShortcut(.space, modifiers: [])` on a
//     hidden button works sometimes and silently loses to whatever control
//     happens to hold focus the rest of the time. Space and J/K/L are the keys
//     an editor lives by, so "sometimes" is not good enough.
//
//  Both are solved the AppKit way: a local event monitor, which sees events
//  before they reach the focused control. The class hands each event to a
//  closure that returns true when it has dealt with it; returning true
//  swallows the event so it does not also beep or scroll something.
//
//  Two safety rules are enforced here rather than at every call site:
//
//  * Events are ignored unless they belong to the app's key window. Without
//    this, keys typed into a save dialog would drive the editor behind it.
//  * Events are ignored while a text field has focus, so typing a filename
//    never triggers a cut.
//

import AppKit
import Foundation

@MainActor
final class InputMonitors: ObservableObject {

    /// Return true when the key has been handled and should not travel further.
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Return true when the scroll has been handled.
    var onScroll: ((NSEvent) -> Bool)?

    private var keyMonitor: Any?
    private var scrollMonitor: Any?

    func start() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
            [weak self] event in
            guard let self, self.shouldHandle(event) else { return event }
            return (self.onKeyDown?(event) ?? false) ? nil : event
        }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) {
            [weak self] event in
            guard let self, self.shouldHandle(event) else { return event }
            return (self.onScroll?(event) ?? false) ? nil : event
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = nil
        scrollMonitor = nil
    }

    deinit {
        // deinit is not main-actor isolated, so copy the tokens out first.
        let tokens = [keyMonitor, scrollMonitor].compactMap { $0 }
        for token in tokens { NSEvent.removeMonitor(token) }
    }

    /// Decide whether an event is ours to act on.
    ///
    /// A local monitor only ever sees events already destined for this app, so
    /// the job here is narrower than it looks: stay out of the way of panels
    /// and text fields.
    ///
    /// `event.window` is deliberately allowed to be nil. Events posted
    /// programmatically (accessibility tools, automation, my own testing) carry
    /// no window, and refusing those would mean the app cannot be driven at all.
    /// In that case the key window stands in for it.
    private func shouldHandle(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? NSApp.keyWindow else { return false }

        // Save and open dialogs are NSPanels. While one is up, Space and Delete
        // belong to it, not to the editor behind it.
        if window is NSPanel { return false }
        // Some other window of ours has focus.
        if let key = NSApp.keyWindow, key !== window { return false }
        if let responder = window.firstResponder {
            if responder is NSTextView { return false }
            if responder is NSTextField { return false }
            // An NSTextView acting as a field editor reports its delegate as
            // the field, so check that shape too.
            if let view = responder as? NSView,
               view.className.contains("TextField") {
                return false
            }
        }
        return true
    }
}

// MARK: - Reading events

extension NSEvent {

    /// True when no command, option or control key is down. Bare keys only:
    /// this is what keeps the monitor from stealing ⌘K, ⌘Z and friends, which
    /// SwiftUI handles perfectly well on its own.
    var hasNoCommandModifiers: Bool {
        modifierFlags.intersection([.command, .option, .control]).isEmpty
    }

    /// The letter typed, lowercased, ignoring shift and friends.
    var plainCharacter: String {
        charactersIgnoringModifiers?.lowercased() ?? ""
    }
}

/// The hardware key codes this app cares about. Using codes rather than
/// characters for these means they work on any keyboard layout.
enum KeyCode {
    static let space: UInt16 = 49
    static let delete: UInt16 = 51        // the big key above Return
    static let forwardDelete: UInt16 = 117
    static let returnKey: UInt16 = 36
    static let escape: UInt16 = 53
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
}
