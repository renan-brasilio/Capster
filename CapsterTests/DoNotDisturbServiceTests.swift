//
//  DoNotDisturbServiceTests.swift
//  CapsterTests
//

import Testing
import Foundation
@testable import Capster

struct DoNotDisturbServiceTests {

    @Test func enableRunsShortcutsWithTheGivenNameAndReportsSuccess() async throws {
        let runner = RecordingProcessRunner(exitCode: 0)
        let service = DoNotDisturbService(processRunner: runner)

        let succeeded = await service.enable(shortcutName: "Capster DND On")

        #expect(succeeded == true)
        #expect(runner.executableURL?.path(percentEncoded: false) == "/usr/bin/shortcuts")
        #expect(runner.arguments == ["run", "Capster DND On"])
    }

    @Test func disableRunsShortcutsWithTheGivenNameAndReportsSuccess() async throws {
        let runner = RecordingProcessRunner(exitCode: 0)
        let service = DoNotDisturbService(processRunner: runner)

        let succeeded = await service.disable(shortcutName: "Capster DND Off")

        #expect(succeeded == true)
        #expect(runner.arguments == ["run", "Capster DND Off"])
    }

    /// A missing shortcut (or any other failure) shouldn't throw or crash the caller -
    /// there's no recording-blocking behavior to protect - but does report failure so
    /// the caller can surface it, rather than failing completely silently.
    @Test func nonZeroExitDoesNotThrowAndReportsFailure() async throws {
        let service = DoNotDisturbService(processRunner: RecordingProcessRunner(exitCode: 1))
        let succeeded = await service.enable(shortcutName: "Missing Shortcut")
        #expect(succeeded == false)
    }

    @Test func thrownErrorDoesNotPropagateAndReportsFailure() async throws {
        let service = DoNotDisturbService(processRunner: ThrowingProcessRunner())
        let succeeded = await service.enable(shortcutName: "Capster DND On")
        #expect(succeeded == false)
    }
}

private final class RecordingProcessRunner: ProcessRunning {
    private let exitCode: Int32
    private(set) var executableURL: URL?
    private(set) var arguments: [String]?

    init(exitCode: Int32) {
        self.exitCode = exitCode
    }

    func run(executableURL: URL, arguments: [String], onOutputLine: @escaping (String) -> Void) async throws -> Int32 {
        self.executableURL = executableURL
        self.arguments = arguments
        return exitCode
    }
}

private final class ThrowingProcessRunner: ProcessRunning {
    func run(executableURL: URL, arguments: [String], onOutputLine: @escaping (String) -> Void) async throws -> Int32 {
        throw NSError(domain: "ThrowingProcessRunner", code: -1)
    }
}
