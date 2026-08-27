//
//  HandBrakeTranscodeServiceTests.swift
//  CapsterTests
//

import Testing
import Foundation
@testable import Capster

struct HandBrakeTranscodeServiceTests {

    private func tempFileURL(name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory.appending(path: name)
    }

    @Test func successfulTranscodeReturnsOutputURL() async throws {
        let input = tempFileURL(name: "input.mp4")
        FileManager.default.createFile(atPath: input.path(percentEncoded: false), contents: Data())
        defer { try? FileManager.default.removeItem(at: input) }

        let expectedOutput = HandBrakeTranscodeService.outputURL(for: input)
        let stub = StubProcessRunner(
            lines: ["Encoding: task 1 of 1, 50.00 %", "Encoding: task 1 of 1, 100.00 %"],
            exitCode: 0,
            onRun: { FileManager.default.createFile(atPath: expectedOutput.path(percentEncoded: false), contents: Data()) }
        )
        defer { try? FileManager.default.removeItem(at: expectedOutput) }

        let service = HandBrakeTranscodeService(processRunner: stub)
        var reportedFractions: [Double] = []

        let output = try await service.transcode(
            inputURL: input,
            preset: .fast1080p30,
            binaryURL: tempFileURL(name: "HandBrakeCLI")
        ) { progress in
            reportedFractions.append(progress.fractionComplete)
        }

        #expect(output == expectedOutput)
        #expect(reportedFractions == [0.5, 1.0])
    }

    @Test func nonZeroExitThrows() async throws {
        let input = tempFileURL(name: "input.mp4")
        let stub = StubProcessRunner(lines: ["some error"], exitCode: 1)
        let service = HandBrakeTranscodeService(processRunner: stub)

        await #expect(throws: HandBrakeTranscodeError.self) {
            _ = try await service.transcode(inputURL: input, preset: .fast1080p30, binaryURL: tempFileURL()) { _ in }
        }
    }

    @Test func missingOutputFileThrows() async throws {
        let input = tempFileURL(name: "input.mp4")
        let stub = StubProcessRunner(lines: [], exitCode: 0)
        let service = HandBrakeTranscodeService(processRunner: stub)

        await #expect(throws: HandBrakeTranscodeError.self) {
            _ = try await service.transcode(inputURL: input, preset: .fast1080p30, binaryURL: tempFileURL()) { _ in }
        }
    }

    // MARK: - parseProgress

    @Test func parsesValidProgressLine() {
        let progress = HandBrakeTranscodeService.parseProgress(from: "Encoding: task 1 of 1, 42.17 %")
        #expect(progress?.fractionComplete == 0.4217)
        #expect(progress?.etaSeconds == nil)
    }

    @Test func ignoresNonProgressLines() {
        #expect(HandBrakeTranscodeService.parseProgress(from: "Muxing: this may take awhile...") == nil)
        #expect(HandBrakeTranscodeService.parseProgress(from: "HandBrake has exited.") == nil)
    }

    /// Real line captured from an actual HandBrakeCLI run - it only starts appending the
    /// fps/ETA suffix once its rolling average has settled, so earlier lines are bare
    /// percentages (covered by `parsesValidProgressLine` above).
    @Test func parsesETAOnceHandBrakeStartsReportingOne() {
        let progress = HandBrakeTranscodeService.parseProgress(
            from: "Encoding: task 1 of 1, 51.17 % (174.12 fps, avg 174.12 fps, ETA 00h00m07s)"
        )
        #expect(progress?.fractionComplete == 0.5117)
        #expect(progress?.etaSeconds == 7)
    }

    @Test func parsesETAWithHoursAndMinutes() {
        let progress = HandBrakeTranscodeService.parseProgress(
            from: "Encoding: task 1 of 1, 12.00 % (10.00 fps, avg 10.00 fps, ETA 01h02m03s)"
        )
        let expectedSeconds: TimeInterval = 1 * 3600 + 2 * 60 + 3
        #expect(progress?.etaSeconds == expectedSeconds)
    }
}

private final class StubProcessRunner: ProcessRunning {
    private let lines: [String]
    private let exitCode: Int32
    private let onRun: (() -> Void)?

    init(lines: [String], exitCode: Int32, onRun: (() -> Void)? = nil) {
        self.lines = lines
        self.exitCode = exitCode
        self.onRun = onRun
    }

    func run(executableURL: URL, arguments: [String], onOutputLine: @escaping (String) -> Void) async throws -> Int32 {
        lines.forEach(onOutputLine)
        onRun?()
        return exitCode
    }
}
