//
//  DoNotDisturbService.swift
//  Capster
//

import Foundation
import OSLog

/// Turns Do Not Disturb on/off around a recording by running user-created Shortcuts.
///
/// macOS has had no public API for toggling Focus modes since they replaced the old
/// Notification Center "Do Not Disturb" switch - the `shortcuts` CLI running a Shortcut
/// built with the "Set Focus" action is the only currently-working way to do this from
/// outside the Shortcuts/Focus UI itself. The user has to create the two shortcuts once;
/// this just invokes them by name.
final class DoNotDisturbService {
    private let processRunner: ProcessRunning
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "DoNotDisturbService")

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func enable(shortcutName: String) async {
        await run(shortcutName: shortcutName, action: "enabling")
    }

    func disable(shortcutName: String) async {
        await run(shortcutName: shortcutName, action: "disabling")
    }

    private func run(shortcutName: String, action: String) async {
        do {
            let exitCode = try await processRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/shortcuts"),
                arguments: ["run", shortcutName],
                onOutputLine: { _ in }
            )
            if exitCode != 0 {
                logger.error("Shortcut \"\(shortcutName, privacy: .public)\" for \(action, privacy: .public) Do Not Disturb exited with code \(exitCode) - does a shortcut with that exact name exist in Shortcuts.app?")
            }
        } catch {
            logger.error("Failed to run shortcut \"\(shortcutName, privacy: .public)\" for \(action, privacy: .public) Do Not Disturb: \(error.localizedDescription)")
        }
    }
}
