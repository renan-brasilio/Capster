//
//  PostProcessingJobFileTests.swift
//  CapsterTests
//

import Testing
import Foundation
@testable import Capster

struct PostProcessingJobFileTests {

    private func recordingURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
    }

    @Test func urlForRecordingSwapsExtensionKeepingBaseName() {
        let recording = URL(fileURLWithPath: "/Users/x/Movies/Capster/Capster_2026-08-27-11.20.00.mp4")
        let jobURL = PostProcessingJobFile.url(for: recording)

        #expect(jobURL.lastPathComponent == "Capster_2026-08-27-11.20.00.capster")
        #expect(jobURL.deletingLastPathComponent() == recording.deletingLastPathComponent())
    }

    @Test func writeThenReadRoundTripsTheRecordingURL() throws {
        let recording = recordingURL()
        let jobURL = PostProcessingJobFile.url(for: recording)
        defer { try? FileManager.default.removeItem(at: jobURL) }

        PostProcessingJobFile.write(for: recording)

        let resolved = PostProcessingJobFile.read(from: jobURL)
        #expect(resolved?.path(percentEncoded: false) == recording.path(percentEncoded: false))
    }

    @Test func readReturnsNilForGarbageContent() throws {
        let jobURL = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).capster")
        try Data("not json".utf8).write(to: jobURL)
        defer { try? FileManager.default.removeItem(at: jobURL) }

        #expect(PostProcessingJobFile.read(from: jobURL) == nil)
    }

    @Test func readReturnsNilForMissingFile() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).capster")
        #expect(PostProcessingJobFile.read(from: missing) == nil)
    }
}
