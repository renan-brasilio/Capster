//
//  DoNotDisturbShortcutInstallerServiceTests.swift
//  CapsterTests
//

import Testing
import Foundation
@testable import Capster

struct DoNotDisturbShortcutInstallerServiceTests {

    @Test func installShortcutsBuildsCorrectPlistsAndSignsBoth() async throws {
        let runner = RecordingSignRunner()
        var openedURLs: [URL] = []
        let service = DoNotDisturbShortcutInstallerService(processRunner: runner, openURL: { openedURLs.append($0) })

        try await service.installShortcuts(onName: "Test On", offName: "Test Off")

        #expect(runner.invocations.count == 2)
        #expect(openedURLs.count == 2)

        let onInvocation = try #require(runner.invocations.first)
        #expect(onInvocation.arguments.first == "sign")
        #expect(onInvocation.arguments.contains("people-who-know-me"))
        let onPlist = try #require(onInvocation.inputPlist)
        #expect(onPlist["WFWorkflowName"] as? String == "Test On")
        let onParams = try #require((onPlist["WFWorkflowActions"] as? [[String: Any]])?.first?["WFWorkflowActionParameters"] as? [String: Any])
        #expect(onParams["Enabled"] as? Int == 1)

        let offInvocation = try #require(runner.invocations.last)
        let offPlist = try #require(offInvocation.inputPlist)
        #expect(offPlist["WFWorkflowName"] as? String == "Test Off")
        let offParams = try #require((offPlist["WFWorkflowActions"] as? [[String: Any]])?.first?["WFWorkflowActionParameters"] as? [String: Any])
        #expect(offParams["Enabled"] as? Int == 0)
    }

    @Test func installShortcutsUsesTheDndSetActionIdentifier() async throws {
        let runner = RecordingSignRunner()
        let service = DoNotDisturbShortcutInstallerService(processRunner: runner, openURL: { _ in })

        try await service.installShortcuts(onName: "On", offName: "Off")

        let identifier = try #require(
            (runner.invocations.first?.inputPlist?["WFWorkflowActions"] as? [[String: Any]])?.first?["WFWorkflowActionIdentifier"] as? String
        )
        #expect(identifier == "is.workflow.actions.dnd.set")
    }

    @Test func installShortcutsCleansUpTempInputFiles() async throws {
        let runner = RecordingSignRunner()
        let service = DoNotDisturbShortcutInstallerService(processRunner: runner, openURL: { _ in })

        try await service.installShortcuts(onName: "Cleanup Test On", offName: "Cleanup Test Off")

        for invocation in runner.invocations {
            guard let inputIndex = invocation.arguments.firstIndex(of: "--input") else {
                Issue.record("Expected --input argument")
                continue
            }
            let inputPath = invocation.arguments[inputIndex + 1]
            #expect(FileManager.default.fileExists(atPath: inputPath) == false)
        }
    }

    @Test func installShortcutsThrowsWhenSigningFails() async throws {
        let service = DoNotDisturbShortcutInstallerService(processRunner: FailingSignRunner(), openURL: { _ in })

        await #expect(throws: DoNotDisturbShortcutInstallerService.InstallError.self) {
            try await service.installShortcuts(onName: "On", offName: "Off")
        }
    }
}

/// Mimics `shortcuts sign`: reads the plist at `--input`, records it, and writes a dummy
/// file at `--output` so the caller's existence check succeeds.
private final class RecordingSignRunner: ProcessRunning {
    private(set) var invocations: [(arguments: [String], inputPlist: [String: Any]?)] = []

    func run(executableURL: URL, arguments: [String], onOutputLine: @escaping (String) -> Void) async throws -> Int32 {
        var inputPlist: [String: Any]?
        if let inputIndex = arguments.firstIndex(of: "--input"), arguments.count > inputIndex + 1 {
            let inputPath = arguments[inputIndex + 1]
            if let data = FileManager.default.contents(atPath: inputPath) {
                inputPlist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            }
        }
        invocations.append((arguments, inputPlist))

        if let outputIndex = arguments.firstIndex(of: "--output"), arguments.count > outputIndex + 1 {
            FileManager.default.createFile(atPath: arguments[outputIndex + 1], contents: Data("signed".utf8))
        }
        return 0
    }
}

private final class FailingSignRunner: ProcessRunning {
    func run(executableURL: URL, arguments: [String], onOutputLine: @escaping (String) -> Void) async throws -> Int32 {
        1
    }
}
