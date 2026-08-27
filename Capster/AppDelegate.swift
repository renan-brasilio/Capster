//
//  AppDelegate.swift
//  Capster
//

import AppKit

/// Ensures the capture stream, camera session, and any in-progress recording are torn
/// down before the app quits.
///
/// Without this, quitting (Quit button, Cmd+Q, Dock, system logout) killed the process
/// immediately, leaving ScreenCaptureKit's `replayd` daemon holding the stream open -
/// screen sharing stayed active system-wide even after the app was gone.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: RecorderViewModel?

    /// Set by `CapsterApp` to the same handler used by its `.onOpenURL` modifier.
    ///
    /// `.onOpenURL` alone isn't reliable here: it's attached to the `MenuBarExtra`
    /// popover's content, which SwiftUI only keeps alive while that popover is actually
    /// open on screen. A `capster://` redirect arriving while the user is elsewhere (e.g.
    /// mid OAuth flow in the browser) can be silently dropped with no error and nothing
    /// logged. This delegate callback is live for the whole app lifetime regardless.
    var onOpenURLs: (([URL]) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        onOpenURLs?(urls)
    }

    /// Overriding `LSUIElement`'s default (menu bar only, no Dock icon) has to happen here
    /// rather than from a SwiftUI `.task` - a `.task` on the `MenuBarExtra` content can run
    /// before AppKit finishes its own Info.plist-driven activation policy setup, so an
    /// early `setActivationPolicy` call gets silently overwritten a moment later. This
    /// delegate callback fires at the correct point in the launch sequence.
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockIconPolicy()
        NotificationCenter.default.addObserver(
            self, selector: #selector(userDefaultsDidChange), name: UserDefaults.didChangeNotification, object: nil
        )
    }

    @objc private func userDefaultsDidChange() {
        applyDockIconPolicy()
    }

    private func applyDockIconPolicy() {
        let showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        if NSApp.activationPolicy() != (showDockIcon ? .regular : .accessory) {
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.isRecording || viewModel.hasContentSelected else {
            return .terminateNow
        }

        Task { @MainActor in
            if viewModel.isRecording {
                await viewModel.stopRecording()
            } else {
                await viewModel.resetSelection()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
