//
//  TimelineExportServiceTests.swift
//  CapsterTests
//

import Testing
import Foundation
@testable import Capster

struct TimelineExportServiceTests {

    @Test func outputURLAppendsEditedSuffixKeepingExtension() {
        let recording = URL(fileURLWithPath: "/Users/x/Movies/Capster/Capster_2026-08-27-11.20.00.mp4")
        let output = TimelineExportService.outputURL(for: recording)

        #expect(output.lastPathComponent == "Capster_2026-08-27-11.20.00 (Edited).mp4")
        #expect(output.deletingLastPathComponent() == recording.deletingLastPathComponent())
    }

    @Test func outputURLAvoidsCollidingWithAnExistingExport() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recording = directory.appending(path: "Recording.mov")
        let firstExport = TimelineExportService.outputURL(for: recording)
        try Data().write(to: firstExport)

        let secondExport = TimelineExportService.outputURL(for: recording)

        #expect(secondExport.lastPathComponent == "Recording (Edited 2).mov")
    }
}
