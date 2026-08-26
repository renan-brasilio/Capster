//
//  HandBrakeTranscodeService.swift
//  Capster
//

import Foundation
import OSLog

enum HandBrakeTranscodeError: LocalizedError {
    case binaryNotConfigured
    case nonZeroExit(Int32, stderrTail: String)
    case outputFileMissing

    var errorDescription: String? {
        switch self {
        case .binaryNotConfigured:
            return "HandBrakeCLI has not been located. Set it in Settings > Automation."
        case .nonZeroExit(let code, let stderrTail):
            return "HandBrakeCLI exited with code \(code): \(stderrTail)"
        case .outputFileMissing:
            return "HandBrakeCLI finished but no output file was produced."
        }
    }
}

/// Thrown by `ProcessRunning` implementations when the child process itself couldn't be
/// launched (e.g. the binary was deleted or lost its executable bit between being
/// located and being run). Generic rather than tool-specific since `SystemProcessRunner`
/// is shared across every CLI Capster shells out to.
enum ProcessLaunchError: LocalizedError {
    case launchFailed(Error)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let error):
            return "Failed to launch process: \(error.localizedDescription)"
        }
    }
}

/// Progress parsed from HandBrakeCLI's stdout while an encode is running.
struct HandBrakeProgress: Equatable {
    /// 0...1, parsed from a `Encoding: task 1 of 1, NN.NN %` line.
    let fractionComplete: Double
    /// Raw text of the most recent progress line, for a status label.
    let statusText: String
}

/// Abstracts subprocess launching so tests can stub HandBrakeCLI invocation without
/// shelling out to a real binary.
protocol ProcessRunning {
    /// Launches `executableURL` with `arguments`, streaming combined stdout+stderr lines
    /// via `onOutputLine`, and returns the process's exit code once it terminates.
    /// Must terminate the child process on Swift Task cancellation rather than just
    /// stopping the await.
    func run(
        executableURL: URL,
        arguments: [String],
        onOutputLine: @escaping (String) -> Void
    ) async throws -> Int32
}

/// Real implementation backed by `Foundation.Process`.
final class SystemProcessRunner: ProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        onOutputLine: @escaping (String) -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lineBuffer = LineBuffer(onLine: onOutputLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lineBuffer.append(data)
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessLaunchError.launchFailed(error)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { finished in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    lineBuffer.flush()
                    continuation.resume(returning: finished.terminationStatus)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

/// Accumulates raw stdout bytes into complete lines before handing them to the callback.
private final class LineBuffer {
    private var pending = Data()
    private let onLine: (String) -> Void
    private let lock = NSLock()

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        lock.lock()
        pending.append(data)
        var lines: [String] = []
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineData = pending[..<newlineIndex]
            pending = pending[(newlineIndex + 1)...]
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let remaining = pending
        pending = Data()
        lock.unlock()
        if !remaining.isEmpty, let line = String(data: remaining, encoding: .utf8), !line.isEmpty {
            onLine(line)
        }
    }
}

final class HandBrakeTranscodeService {
    private let processRunner: ProcessRunning
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "HandBrakeTranscodeService")

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    /// Transcodes `inputURL` to a new file alongside it using `binaryURL` (already
    /// security-scope-resolved by the caller) and `preset`. Reports progress via
    /// `onProgress` as HandBrakeCLI's stdout is parsed. Throws on failure rather than
    /// falling back to the original file - the caller decides what that means for the
    /// pipeline.
    func transcode(
        inputURL: URL,
        preset: HandBrakePreset,
        binaryURL: URL,
        onProgress: @escaping (HandBrakeProgress) -> Void
    ) async throws -> URL {
        let outputURL = Self.outputURL(for: inputURL)
        let arguments = [
            "-i", inputURL.path(percentEncoded: false),
            "-o", outputURL.path(percentEncoded: false),
            "--preset", preset.cliPresetName
        ]

        var stderrTail: [String] = []
        let exitCode = try await processRunner.run(executableURL: binaryURL, arguments: arguments) { line in
            if let progress = Self.parseProgress(from: line) {
                onProgress(progress)
            }
            stderrTail.append(line)
            if stderrTail.count > 20 { stderrTail.removeFirst() }
        }

        logger.info("HandBrakeCLI exited with code \(exitCode)")

        guard exitCode == 0 else {
            throw HandBrakeTranscodeError.nonZeroExit(exitCode, stderrTail: stderrTail.joined(separator: "\n"))
        }
        guard FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
            throw HandBrakeTranscodeError.outputFileMissing
        }
        return outputURL
    }

    /// e.g. "Capster_2026-08-19-14.03.02.mp4" -> "Capster_2026-08-19-14.03.02 (Transcoded).mp4"
    static func outputURL(for inputURL: URL) -> URL {
        let ext = inputURL.pathExtension
        let base = inputURL.deletingPathExtension().lastPathComponent
        return inputURL
            .deletingLastPathComponent()
            .appending(path: "\(base) (Transcoded).\(ext)")
    }

    /// Parses lines like "Encoding: task 1 of 1, 42.17 %" into `HandBrakeProgress`.
    /// Returns nil for non-progress lines (muxing, scanning, etc.).
    static func parseProgress(from line: String) -> HandBrakeProgress? {
        guard line.contains("Encoding:"), let percentRange = line.range(of: "%") else { return nil }
        let beforePercent = line[..<percentRange.lowerBound]
        guard let lastComma = beforePercent.lastIndex(of: ",") else { return nil }
        let numberText = beforePercent[beforePercent.index(after: lastComma)...]
            .trimmingCharacters(in: .whitespaces)
        guard let percent = Double(numberText) else { return nil }
        return HandBrakeProgress(fractionComplete: percent / 100, statusText: line.trimmingCharacters(in: .whitespaces))
    }
}
