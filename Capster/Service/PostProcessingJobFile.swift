//
//  PostProcessingJobFile.swift
//  Capster
//

import Foundation

/// The `.capster` file written alongside every recording, letting the user later reopen
/// (and re-run from scratch, under whatever Settings are current at that point) the
/// post-processing pipeline for it - whether because the panel got closed before a step
/// finished, post-processing wasn't enabled at record time, or they just want to redo it.
struct PostProcessingJobFile: Codable {
    static let fileExtension = "capster"

    /// Absolute path to the recording this job file refers to. A path rather than a
    /// security-scoped bookmark since Capster doesn't run under App Sandbox.
    let recordingPath: String

    /// The `.capster` sidecar path for a given recording - same directory and base name,
    /// swapped extension.
    static func url(for recordingURL: URL) -> URL {
        recordingURL.deletingPathExtension().appendingPathExtension(fileExtension)
    }

    /// Writes the sidecar file for `recordingURL`. Best-effort - a failure here shouldn't
    /// interrupt the recording flow, just means this recording won't be reopenable later.
    static func write(for recordingURL: URL) {
        let job = PostProcessingJobFile(recordingPath: recordingURL.path(percentEncoded: false))
        guard let data = try? JSONEncoder().encode(job) else { return }
        try? data.write(to: url(for: recordingURL))
    }

    /// Reads a `.capster` file and resolves the recording URL it points to. Returns nil if
    /// the file isn't valid JSON in the expected shape - the caller decides how to surface
    /// that (a missing/moved recording is a separate, expected failure mode from this).
    static func read(from fileURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: fileURL),
              let job = try? JSONDecoder().decode(PostProcessingJobFile.self, from: data) else {
            return nil
        }
        return URL(fileURLWithPath: job.recordingPath)
    }
}
