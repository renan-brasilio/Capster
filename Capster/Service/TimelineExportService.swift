//
//  TimelineExportService.swift
//  Capster
//

import AVFoundation
import Foundation
import OSLog

enum TimelineExportError: LocalizedError {
    case exportSessionUnavailable
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .exportSessionUnavailable:
            return "Couldn't create an export session for this timeline."
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .cancelled:
            return "Export was cancelled."
        }
    }
}

/// Renders an `EditorProject`'s composition to a new video file. Never overwrites the
/// original recording - `outputURL(for:)` always names the export `<name> (Edited).<ext>`,
/// resolving collisions the same way `PostProcessingCoordinator` resolves rename
/// collisions, so exporting the same project again doesn't clobber a prior export.
final class TimelineExportService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "TimelineExportService")

    /// Exports `project` to a new file alongside the original recording, reporting
    /// progress (0...1) as it renders. Throws on failure or cancellation rather than
    /// silently returning a partial file.
    func export(project: EditorProject, onProgress: @escaping (Double) -> Void) async throws -> URL {
        let result = try await VideoCompositionService.makeComposition(from: project)
        let outputURL = Self.outputURL(for: project.originalRecordingURL)

        guard let exportSession = AVAssetExportSession(
            asset: result.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw TimelineExportError.exportSessionUnavailable
        }
        exportSession.videoComposition = result.videoComposition
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov

        // AVAssetExportSession doesn't push progress updates, so poll it on a timer
        // instead - cancelled via `defer` whether export finishes, fails, or is cancelled.
        let pollTask = Task {
            while !Task.isCancelled {
                onProgress(Double(exportSession.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { pollTask.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                exportSession.exportAsynchronously {
                    continuation.resume()
                }
            }
        } onCancel: {
            exportSession.cancelExport()
        }

        switch exportSession.status {
        case .completed:
            onProgress(1)
            logger.info("Exported timeline to \(outputURL.lastPathComponent, privacy: .public)")
            return outputURL
        case .cancelled:
            throw TimelineExportError.cancelled
        default:
            throw TimelineExportError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown error")
        }
    }

    /// e.g. "Capster_2026-08-19-14.03.02.mp4" -> "Capster_2026-08-19-14.03.02 (Edited).mp4",
    /// appending a numeric suffix if that name is already taken.
    static func outputURL(for recordingURL: URL) -> URL {
        let ext = recordingURL.pathExtension
        let base = recordingURL.deletingPathExtension().lastPathComponent
        let directory = recordingURL.deletingLastPathComponent()

        func candidate(_ suffix: String) -> URL {
            directory.appending(path: "\(base) (Edited\(suffix)).\(ext)")
        }

        var url = candidate("")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = candidate(" \(counter)")
            counter += 1
        }
        return url
    }
}
