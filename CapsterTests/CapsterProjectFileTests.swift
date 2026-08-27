//
//  CapsterProjectFileTests.swift
//  CapsterTests
//

import Testing
import CoreMedia
import Foundation
@testable import Capster

struct CapsterProjectFileTests {

    private func recordingURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
    }

    @Test func urlForRecordingSwapsExtensionKeepingBaseName() {
        let recording = URL(fileURLWithPath: "/Users/x/Movies/Capster/Capster_2026-08-27-11.20.00.mp4")
        let projectURL = CapsterProjectFile.url(for: recording)

        #expect(projectURL.lastPathComponent == "Capster_2026-08-27-11.20.00.capster")
        #expect(projectURL.deletingLastPathComponent() == recording.deletingLastPathComponent())
    }

    @Test func writeForRecordingRoundTripsAsAnEmptyPointer() throws {
        let recording = recordingURL()
        let projectURL = CapsterProjectFile.url(for: recording)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        CapsterProjectFile.write(for: recording)

        let resolved = CapsterProjectFile.read(from: projectURL)
        #expect(resolved?.originalRecordingURL.path(percentEncoded: false) == recording.path(percentEncoded: false))
        #expect(resolved?.clips.isEmpty == true)
    }

    @Test func writeProjectRoundTripsClipsWithTrimPoints() throws {
        let recording = recordingURL()
        let projectURL = CapsterProjectFile.url(for: recording)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let clip = EditorClip(
            sourceURL: recording,
            sourceDuration: CMTime(seconds: 10, preferredTimescale: 600),
            trimStart: CMTime(seconds: 2, preferredTimescale: 600),
            trimEnd: CMTime(seconds: 8, preferredTimescale: 600)
        )
        let project = EditorProject(clips: [clip], originalRecordingURL: recording)
        CapsterProjectFile.write(project, for: recording)

        let resolved = try #require(CapsterProjectFile.read(from: projectURL))
        #expect(resolved.clips.count == 1)
        let reconstructed = resolved.makeEditorProject()
        #expect(reconstructed.clips[0].trimStart.seconds == 2)
        #expect(reconstructed.clips[0].trimEnd.seconds == 8)
        #expect(reconstructed.clips[0].sourceDuration.seconds == 10)
    }

    @Test func readReturnsNilForGarbageContent() throws {
        let projectURL = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).capster")
        try Data("not json".utf8).write(to: projectURL)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        #expect(CapsterProjectFile.read(from: projectURL) == nil)
    }

    @Test func readReturnsNilForMissingFile() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).capster")
        #expect(CapsterProjectFile.read(from: missing) == nil)
    }
}
