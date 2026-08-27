//
//  EditorWindowCoordinator.swift
//  Capster
//

import AppKit
import SwiftUI

/// Manages the editor's window directly via AppKit, the same way `PostProcessingPanelCoordinator`
/// and `RecordingOverlayPanel` manage theirs - rather than SwiftUI's `WindowGroup`/`openWindow`.
///
/// `openWindow` depends on the owning Scene's content having been built at least once, and
/// `MenuBarExtra` content (where the `@Environment(\.openWindow)` needed to call it lives)
/// is only actually built once the user opens the menu bar popover - not necessarily at
/// launch. That made the editor silently fail to open when triggered before then, e.g. a
/// freshly-launched app immediately handling a double-clicked `.capster` file. A plain
/// `NSWindow` has no such dependency: it can be shown at any point in the app's lifetime.
@MainActor
final class EditorWindowCoordinator {
    private var windows: [URL: NSWindow] = [:]
    private var closeObservers: [URL: NSObjectProtocol] = [:]

    /// Shows the editor for `recordingURL`, reusing and bringing forward an already-open
    /// window for the same recording rather than opening a duplicate.
    func show(recordingURL: URL, postProcessing: PostProcessingCoordinator) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let existing = windows[recordingURL] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = recordingURL.lastPathComponent
        window.minSize = CGSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(
            rootView: EditorWindowView(recordingURL: recordingURL, postProcessing: postProcessing)
        )

        closeObservers[recordingURL] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.forget(recordingURL) }
        }

        window.makeKeyAndOrderFront(nil)
        windows[recordingURL] = window
    }

    private func forget(_ recordingURL: URL) {
        windows[recordingURL] = nil
        if let observer = closeObservers[recordingURL] {
            NotificationCenter.default.removeObserver(observer)
        }
        closeObservers[recordingURL] = nil
    }
}
