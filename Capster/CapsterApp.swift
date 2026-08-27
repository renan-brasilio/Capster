//
//  CapsterApp.swift
//  Capster
//
//  Created by Joshua Sattler on 29.01.26.
//

import AppKit
import KeyboardShortcuts
import OSLog
import SwiftUI

@main
struct CapsterApp: App {
    @State private var viewModel = RecorderViewModel()
    @State private var updaterService = UpdaterService()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "CapsterApp")

    init() {
        // Wired here, in `init()`, rather than a `.task` on the `MenuBarExtra`'s content -
        // that content (and the `.task` on it) is only actually built once the user opens
        // the menu bar popover at least once, which isn't guaranteed to have happened yet
        // when a `.capster` file or `capster://` URL needs handling right at launch (e.g.
        // double-clicking a `.capster` project file launches the app fresh and hands it the
        // open-URL event almost immediately). `init()` runs synchronously before any Scene
        // content, so this is reliable regardless of menu bar state.
        appDelegate.viewModel = viewModel
        appDelegate.onOpenURLs = { [self] urls in
            for url in urls { handleURL(url) }
        }
    }

    var body: some Scene {
        // Menu bar extra - the primary interface
        // Using .window style to support custom toggle switches
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
                .task {
                    await viewModel.requestPermissionsOnLaunch()
                    registerKeyboardShortcuts()
                }
                .onOpenURL { url in
                    handleURL(url)
                }
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView(
                settings: viewModel.settings,
                updaterService: updaterService,
                permissionService: viewModel.permissionService,
                chorusSession: viewModel.chorusSession,
                slackSession: viewModel.slackSession
            )
        }
    }

    // MARK: - File Opens

    /// A double-clicked `.capster` project file arrives here the same way a `capster://`
    /// URL does - both go through `application(_:open:)`. Opens the editor, resuming any
    /// saved edits the project file holds.
    private func handleFileOpen(_ url: URL) {
        guard let project = CapsterProjectFile.read(from: url) else {
            logger.error("Couldn't read Capster project file: \(url.lastPathComponent, privacy: .public)")
            return
        }
        logger.info("Opening editor for: \(project.originalRecordingURL.lastPathComponent, privacy: .public)")
        viewModel.openEditor(for: project.originalRecordingURL)
    }

    // MARK: - URL Scheme

    private func handleURL(_ url: URL) {
        if url.isFileURL {
            handleFileOpen(url)
            return
        }

        guard url.scheme == "capster" else { return }
        logger.info("Handling capster:// URL with host: \(url.host ?? "nil", privacy: .public)")

        switch url.host {
        case "toggle", "toggle-copy":
            let copyToClipboard = url.host == "toggle-copy"
            Task { @MainActor in
                if viewModel.isRecording {
                    await viewModel.stopRecording(copyToClipboard: copyToClipboard)
                } else {
                    switch ContentSelectionMode.current {
                    case .pickContent:
                        viewModel.presentPicker()
                    case .selectArea:
                        await viewModel.presentAreaSelection()
                    }
                }
            }
        case "open-recordings":
            Task { @MainActor in
                let settings = viewModel.settings
                let didStart = settings.startAccessingOutputDirectory()
                defer {
                    if didStart {
                        settings.stopAccessingOutputDirectory()
                    }
                }
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: settings.outputDirectory.path)
            }
        case "slack-oauth-callback":
            logger.info("Received Slack OAuth callback")
            Task { @MainActor in
                do {
                    try await viewModel.slackSession.completeSignIn(callbackURL: url, clientID: viewModel.settings.slackClientID)
                } catch {
                    logger.error("Slack sign-in failed: \(error.localizedDescription, privacy: .public)")
                    viewModel.notificationService.sendSlackSignInFailedNotification(error: error)
                }
            }
        default:
            break
        }
    }

    // MARK: - Keyboard Shortcuts

    private func registerKeyboardShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [viewModel] in
            Task { @MainActor in
                await viewModel.toggleRecording()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .selectContent) { [viewModel] in
            Task { @MainActor in
                viewModel.presentPicker()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .selectArea) { [viewModel] in
            Task { @MainActor in
                await viewModel.presentAreaSelection()
            }
        }
    }
}

/// The label shown in the menu bar (icon or duration timer)
struct MenuBarLabel: View {
    let viewModel: RecorderViewModel

    var body: some View {
        if viewModel.isRecording {
            // Render the duration into a fixed-size image so the
            // NSStatusItem never recalculates its width on each tick.
            if let image = timerImage {
                Image(nsImage: image)
            }
        } else {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        }
    }

    /// Renders the formatted duration into an ``NSImage`` with a stable
    /// width derived from the widest possible string for the current format.
    private var timerImage: NSImage? {
        let text = viewModel.formattedDuration

        // Use the widest possible string for the current format to
        // compute a stable size that won't change between ticks.
        let referenceText: String = if viewModel.recordingDuration >= 3600 {
            "0:00:00"
        } else {
            "00:00"
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]

        let referenceSize = (referenceText as NSString).size(withAttributes: attrs)
        let imageSize = NSSize(width: ceil(referenceSize.width), height: ceil(referenceSize.height))

        let textSize = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(
            x: (imageSize.width - textSize.width) / 2,
            y: (imageSize.height - textSize.height) / 2
        )

        let image = NSImage(size: imageSize, flipped: false) { _ in
            (text as NSString).draw(at: origin, withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }
}
