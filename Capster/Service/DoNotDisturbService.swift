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

    /// Returns whether the shortcut actually ran successfully, so the caller can surface
    /// a visible failure - a missing/misnamed shortcut otherwise fails completely silently.
    @discardableResult
    func enable(shortcutName: String) async -> Bool {
        await run(shortcutName: shortcutName, action: "enabling")
    }

    @discardableResult
    func disable(shortcutName: String) async -> Bool {
        await run(shortcutName: shortcutName, action: "disabling")
    }

    private func run(shortcutName: String, action: String) async -> Bool {
        do {
            let exitCode = try await processRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/shortcuts"),
                arguments: ["run", shortcutName],
                onOutputLine: { _ in }
            )
            if exitCode != 0 {
                logger.error("Shortcut \"\(shortcutName, privacy: .public)\" for \(action, privacy: .public) Do Not Disturb exited with code \(exitCode) - does a shortcut with that exact name exist in Shortcuts.app?")
                return false
            }
            return true
        } catch {
            logger.error("Failed to run shortcut \"\(shortcutName, privacy: .public)\" for \(action, privacy: .public) Do Not Disturb: \(error.localizedDescription)")
            return false
        }
    }
}
