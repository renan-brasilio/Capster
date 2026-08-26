//
//  GIFExportService.swift
//  Capster
//

import AVFoundation
import Foundation
import OSLog

enum GIFExportError: LocalizedError {
    case binaryNotConfigured
    case nonZeroExit(Int32, stderrTail: String)
    case outputFileMissing

    var errorDescription: String? {
        switch self {
        case .binaryNotConfigured:
            return "ffmpeg has not been located. Set it in Settings > Automation."
        case .nonZeroExit(let code, let stderrTail):
            return "ffmpeg exited with code \(code): \(stderrTail)"
        case .outputFileMissing:
            return "ffmpeg finished but no GIF file was produced."
        }
    }
}

/// Progress parsed from ffmpeg's stderr while a GIF export is running.
struct GIFExportProgress: Equatable {
    /// 0...1, computed from the "time=" field against the input's known duration.
    let fractionComplete: Double
    /// Raw text of the most recent progress line, for a status label.
    let statusText: String
}

/// Exports a recording as an animated GIF via ffmpeg, using a two-pass palette in a
/// single command (`palettegen`/`paletteuse`) for reasonable quality at a small size.
final class GIFExportService {
    /// Fixed rather than user-configurable - a general-purpose balance between
    /// smoothness/quality and file size for a quick share.
    private static let frameRate = 12
    private static let maxWidth = 720

    private let processRunner: ProcessRunning
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "GIFExportService")

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    /// Exports `inputURL` to a GIF alongside it using `binaryURL` (a located ffmpeg
    /// executable). Reports progress via `onProgress` as ffmpeg's stderr is parsed.
    func export(
        inputURL: URL,
        binaryURL: URL,
        onProgress: @escaping (GIFExportProgress) -> Void
    ) async throws -> URL {
        let outputURL = Self.outputURL(for: inputURL)
        let duration = try? await AVURLAsset(url: inputURL).load(.duration).seconds

        let filter = "fps=\(Self.frameRate),scale=\(Self.maxWidth):-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
        let arguments = [
            "-y",
            "-i", inputURL.path(percentEncoded: false),
            "-filter_complex", filter,
            outputURL.path(percentEncoded: false)
        ]

        var stderrTail: [String] = []
        let exitCode = try await processRunner.run(executableURL: binaryURL, arguments: arguments) { line in
            if let duration, duration > 0, let elapsed = Self.parseElapsedSeconds(from: line) {
                onProgress(GIFExportProgress(
                    fractionComplete: min(elapsed / duration, 1),
                    statusText: line.trimmingCharacters(in: .whitespaces)
                ))
            }
            stderrTail.append(line)
            if stderrTail.count > 20 { stderrTail.removeFirst() }
        }

        logger.info("ffmpeg (GIF export) exited with code \(exitCode)")

        guard exitCode == 0 else {
            throw GIFExportError.nonZeroExit(exitCode, stderrTail: stderrTail.joined(separator: "\n"))
        }
        guard FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
            throw GIFExportError.outputFileMissing
        }
        return outputURL
    }

    /// e.g. "Capster_2026-08-19-14.03.02.mp4" -> "Capster_2026-08-19-14.03.02.gif"
    static func outputURL(for inputURL: URL) -> URL {
        inputURL.deletingPathExtension().appendingPathExtension("gif")
    }

    /// Parses ffmpeg progress lines like
    /// "frame=  120 fps=25 q=-1.0 size=  1024kB time=00:00:04.80 bitrate=..." into seconds.
    static func parseElapsedSeconds(from line: String) -> Double? {
        guard let timeRange = line.range(of: "time=") else { return nil }
        let afterTime = line[timeRange.upperBound...]
        let timeText = afterTime.prefix { $0 == ":" || $0 == "." || $0.isNumber }

        let components = timeText.split(separator: ":").map(String.init)
        guard components.count == 3,
            let hours = Double(components[0]),
            let minutes = Double(components[1]),
            let seconds = Double(components[2])
        else { return nil }

        return hours * 3600 + minutes * 60 + seconds
    }
}
