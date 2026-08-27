//
//  CapsterProjectFile.swift
//  Capster
//

import CoreMedia
import Foundation

/// The `.capster` project file written next to every recording. Originally just a pointer
/// back to the recording (for reopening post-processing), it's now the editor's save file:
/// it can hold the full timeline - clip order, trim points, any added clips - so opening a
/// `.capster` file reopens the editor exactly where the user left off, not a fresh
/// single-clip project.
struct CapsterProjectFile: Codable {
    static let fileExtension = "capster"

    struct ClipEntry: Codable {
        let sourcePath: String
        let sourceDurationSeconds: Double
        let trimStartSeconds: Double
        let trimEndSeconds: Double
    }

    /// Absolute path to the recording this project started from - kept even as clips are
    /// trimmed, split, reordered, or added to, since it's also this file's own sidecar
    /// location (`url(for:)`) and identifies the editor's `WindowGroup` window.
    let originalRecordingPath: String

    /// Saved timeline state. Empty for a project file that's just the auto-written pointer
    /// from a just-finished recording - nothing has been edited (or saved) yet, so the
    /// editor probes `originalRecordingPath` fresh instead of reconstructing from this.
    let clips: [ClipEntry]

    var originalRecordingURL: URL {
        URL(fileURLWithPath: originalRecordingPath)
    }

    /// The sidecar path for a given recording - same directory and base name, swapped
    /// extension.
    static func url(for recordingURL: URL) -> URL {
        recordingURL.deletingPathExtension().appendingPathExtension(fileExtension)
    }

    /// Writes the pointer-only sidecar for a just-finished recording, before any editing
    /// has happened. Best-effort - a failure here shouldn't interrupt the recording flow,
    /// just means this recording won't be reopenable later.
    static func write(for recordingURL: URL) {
        write(CapsterProjectFile(originalRecordingPath: recordingURL.path(percentEncoded: false), clips: []), for: recordingURL)
    }

    /// Saves `project`'s current timeline, overwriting whatever was there before -
    /// called when the user explicitly saves their edits.
    static func write(_ project: EditorProject, for recordingURL: URL) {
        let clips = project.clips.map {
            ClipEntry(
                sourcePath: $0.sourceURL.path(percentEncoded: false),
                sourceDurationSeconds: $0.sourceDuration.seconds,
                trimStartSeconds: $0.trimStart.seconds,
                trimEndSeconds: $0.trimEnd.seconds
            )
        }
        write(CapsterProjectFile(originalRecordingPath: recordingURL.path(percentEncoded: false), clips: clips), for: recordingURL)
    }

    private static func write(_ file: CapsterProjectFile, for recordingURL: URL) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url(for: recordingURL))
    }

    /// Reads a `.capster` file. Returns nil if it isn't valid JSON in the expected shape -
    /// the caller decides how to surface that (a missing/moved recording is a separate,
    /// expected failure mode from this).
    static func read(from fileURL: URL) -> CapsterProjectFile? {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(CapsterProjectFile.self, from: data) else {
            return nil
        }
        return file
    }

    /// Reconstructs an `EditorProject` from the saved clip entries. Only meaningful when
    /// `clips` isn't empty - callers check that first and fall back to probing
    /// `originalRecordingURL` fresh otherwise.
    func makeEditorProject() -> EditorProject {
        EditorProject(
            clips: clips.map { entry in
                EditorClip(
                    sourceURL: URL(fileURLWithPath: entry.sourcePath),
                    sourceDuration: CMTime(seconds: entry.sourceDurationSeconds, preferredTimescale: 600),
                    trimStart: CMTime(seconds: entry.trimStartSeconds, preferredTimescale: 600),
                    trimEnd: CMTime(seconds: entry.trimEndSeconds, preferredTimescale: 600)
                )
            },
            originalRecordingURL: originalRecordingURL
        )
    }
}
