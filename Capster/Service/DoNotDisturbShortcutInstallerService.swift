//
//  DoNotDisturbShortcutInstallerService.swift
//  Capster
//

import AppKit
import Foundation
import OSLog

/// Builds and signs the two "Set Focus" Shortcuts that `DoNotDisturbService` runs by
/// name, then hands them to Shortcuts.app for the user to approve importing.
///
/// The plist shape below is copied verbatim from a real shortcut exported from
/// Shortcuts.app itself (Set Focus, Do Not Disturb, Turn On, Until Turned Off, all left
/// at their defaults) - `FocusModes`/`Operation`/`AssertionType` are all omitted because
/// that's exactly how Shortcuts.app serializes the default focus with default settings;
/// only `Enabled` (1 or 0) actually varies between the two shortcuts.
///
/// Signing still requires the `shortcuts sign` CLI (there's no Swift API for it), and
/// Apple requires an explicit one-time "Add Shortcut" click to import any shortcut
/// regardless of how the file arrives - this can't be made fully silent.
final class DoNotDisturbShortcutInstallerService {
    enum InstallError: LocalizedError {
        case signingFailed(name: String, exitCode: Int32)

        var errorDescription: String? {
            switch self {
            case .signingFailed(let name, let exitCode):
                return "Failed to sign the \"\(name)\" shortcut (shortcuts sign exited with code \(exitCode))."
            }
        }
    }

    private let processRunner: ProcessRunning
    private let openURL: (URL) -> Void
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "DoNotDisturbShortcutInstallerService")

    init(processRunner: ProcessRunning = SystemProcessRunner(), openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.processRunner = processRunner
        self.openURL = openURL
    }

    /// Builds, signs, and opens both shortcuts for the user to approve importing.
    func installShortcuts(onName: String, offName: String) async throws {
        let onURL = try await buildSignedShortcut(name: onName, enabled: true)
        let offURL = try await buildSignedShortcut(name: offName, enabled: false)
        openURL(onURL)
        openURL(offURL)
    }

    private func buildSignedShortcut(name: String, enabled: Bool) async throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: Self.plistDictionary(name: name, enabled: enabled), format: .binary, options: 0)

        let sanitizedName = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let tempDir = FileManager.default.temporaryDirectory
        // `shortcuts sign` has been observed to reject an otherwise-valid plist when the
        // input filename doesn't relate to the shortcut's own name, so the sanitized name
        // is kept in both temp filenames rather than using a bare UUID.
        let inputURL = tempDir.appending(path: "\(sanitizedName)-sign-input-\(UUID().uuidString).shortcut")
        let outputURL = tempDir.appending(path: "\(sanitizedName)-\(UUID().uuidString).shortcut")
        try data.write(to: inputURL)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let exitCode = try await processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/shortcuts"),
            arguments: [
                "sign", "--mode", "people-who-know-me",
                "--input", inputURL.path(percentEncoded: false),
                "--output", outputURL.path(percentEncoded: false)
            ],
            onOutputLine: { _ in }
        )

        guard exitCode == 0, FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
            logger.error("Failed to sign shortcut \"\(name, privacy: .public)\": shortcuts sign exited with code \(exitCode)")
            throw InstallError.signingFailed(name: name, exitCode: exitCode)
        }

        return outputURL
    }

    private static func plistDictionary(name: String, enabled: Bool) -> [String: Any] {
        [
            "WFWorkflowActions": [
                [
                    "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
                    "WFWorkflowActionParameters": ["Enabled": enabled ? 1 : 0]
                ]
            ],
            "WFWorkflowClientVersion": "4711",
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowIcon": [
                "WFWorkflowIconGlyphNumber": 61440,
                "WFWorkflowIconStartColor": -23508481
            ],
            "WFWorkflowImportQuestions": [],
            "WFWorkflowInputContentItemClasses": [],
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowName": name,
            "WFWorkflowOutputContentItemClasses": [],
            "WFWorkflowTypes": []
        ]
    }
}
