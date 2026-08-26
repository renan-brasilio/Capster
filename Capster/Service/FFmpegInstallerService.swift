//
//  FFmpegInstallerService.swift
//  Capster
//

import Foundation
import OSLog

enum FFmpegInstallError: LocalizedError {
    case brewNotFound
    case installFailed(Int32)
    case cliNotFoundAfterInstall

    var errorDescription: String? {
        switch self {
        case .brewNotFound:
            return "Homebrew isn't installed. Install it from https://brew.sh, then try again."
        case .installFailed(let code):
            return "\"brew install ffmpeg\" exited with code \(code)."
        case .cliNotFoundAfterInstall:
            return "Homebrew finished, but ffmpeg wasn't found afterward."
        }
    }
}

/// Runs `brew install ffmpeg` to get ffmpeg onto the machine, so the user doesn't have
/// to leave Capster and use Terminal for first-time setup.
final class FFmpegInstallerService {
    private let processRunner: ProcessRunning
    private let fileExists: (String) -> Bool
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "FFmpegInstallerService")

    init(
        processRunner: ProcessRunning = SystemProcessRunner(),
        fileExists: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.processRunner = processRunner
        self.fileExists = fileExists
    }

    func locateBrew() -> URL? {
        HandBrakeInstallerService.candidateBrewPaths.first(where: fileExists).map(URL.init(fileURLWithPath:))
    }

    /// Runs the install, streaming brew's output lines via `onOutputLine`, and returns
    /// the resulting ffmpeg binary's URL on success.
    func install(onOutputLine: @escaping (String) -> Void) async throws -> URL {
        guard let brewURL = locateBrew() else { throw FFmpegInstallError.brewNotFound }

        let exitCode = try await processRunner.run(
            executableURL: brewURL,
            arguments: ["install", "ffmpeg"],
            onOutputLine: onOutputLine
        )
        logger.info("brew install ffmpeg exited with code \(exitCode)")
        guard exitCode == 0 else { throw FFmpegInstallError.installFailed(exitCode) }

        let cliURL = brewURL.deletingLastPathComponent().appending(path: "ffmpeg")
        guard fileExists(cliURL.path(percentEncoded: false)) else {
            throw FFmpegInstallError.cliNotFoundAfterInstall
        }
        return cliURL
    }
}
