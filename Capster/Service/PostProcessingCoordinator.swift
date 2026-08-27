//
//  PostProcessingCoordinator.swift
//  Capster
//

import Foundation
import OSLog

/// Runs the optional post-recording pipeline (HandBrake transcode, then Chorus upload)
/// and publishes its progress for the status panel and notifications.
///
/// Kept separate from `RecorderViewModel` because it's a distinct multi-step lifecycle
/// that can outlive a single `stopRecording()` call and manages its own security-scoped
/// access spans independently of the recording's own.
@MainActor
@Observable
final class PostProcessingCoordinator {

    enum StepState: Equatable {
        case notNeeded
        case queued
        case running(progressText: String, fraction: Double?)
        case succeeded
        case failed(String)
    }

    /// A pending rename prompt, shown by the status panel right after the recording
    /// finishes and before any processing starts. Non-nil only while the pipeline is
    /// paused waiting for `submitRename(_:)`. `formattedDuration` and `destinationDirectory`
    /// are read-only context shown alongside the name field.
    struct RenamePrompt: Equatable {
        let suggestedName: String
        let formattedDuration: String
        let destinationDirectory: URL
    }

    private(set) var transcodeState: StepState = .notNeeded
    private(set) var gifExportState: StepState = .notNeeded
    private(set) var uploadState: StepState = .notNeeded
    private(set) var chorusCallID: String?
    private(set) var renamePrompt: RenamePrompt?

    /// The recording this run started with - exposed so the status panel can offer an
    /// "Edit Recording" action without needing its own copy of the URL threaded in
    /// separately from `start(recordingURL:formattedDuration:)`.
    private(set) var recordingURL: URL?

    var isRunning: Bool {
        switch (transcodeState, gifExportState, uploadState) {
        case (.queued, _, _), (.running, _, _),
            (_, .queued, _), (_, .running, _),
            (_, _, .queued), (_, _, .running):
            return true
        default:
            return false
        }
    }

    var isFinished: Bool {
        !isRunning && (transcodeState != .notNeeded || gifExportState != .notNeeded || uploadState != .notNeeded)
    }

    /// Whether `start(recordingURL:formattedDuration:)` actually queued any step - `false`
    /// right after a no-op `start()` call (nothing enabled in Settings), which callers
    /// embedding the step list inline (rather than only showing it when non-empty, the way
    /// the auto-popped status panel does by never calling `start()` at all in that case)
    /// need to distinguish from "steps are still queued".
    var hasAnySteps: Bool {
        transcodeState != .notNeeded || gifExportState != .notNeeded || uploadState != .notNeeded
    }

    var didSucceed: Bool {
        isFinished
            && !isCase(transcodeState, .failed(""))
            && !isCase(gifExportState, .failed(""))
            && !isCase(uploadState, .failed(""))
    }

    private let settings: SettingsStore
    private let notificationService: NotificationService
    private let transcodeService: HandBrakeTranscodeService
    private let gifExportService: GIFExportService
    private let uploadService: ChorusUploadService
    private let chorusSession: ChorusSessionService
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "PostProcessingCoordinator")
    private var currentTask: Task<Void, Never>?
    private var renameContinuation: CheckedContinuation<String?, Never>?

    init(
        settings: SettingsStore,
        notificationService: NotificationService,
        chorusSession: ChorusSessionService,
        transcodeService: HandBrakeTranscodeService = HandBrakeTranscodeService(),
        gifExportService: GIFExportService = GIFExportService(),
        uploadService: ChorusUploadService = ChorusUploadService()
    ) {
        self.settings = settings
        self.notificationService = notificationService
        self.chorusSession = chorusSession
        self.transcodeService = transcodeService
        self.gifExportService = gifExportService
        self.uploadService = uploadService
    }

    /// Starts the pipeline for a just-finished recording. No-ops if no automation is
    /// enabled. Returns immediately; the pipeline runs in an internal `Task`.
    /// `formattedDuration` is only used to display in the rename prompt, if shown.
    func start(recordingURL: URL, formattedDuration: String = "") {
        guard settings.handBrakeTranscodeEnabled || settings.gifExportEnabled || settings.chorusUploadEnabled else { return }

        currentTask?.cancel()
        self.recordingURL = recordingURL
        transcodeState = settings.handBrakeTranscodeEnabled ? .queued : .notNeeded
        gifExportState = settings.gifExportEnabled ? .queued : .notNeeded
        uploadState = settings.chorusUploadEnabled ? .queued : .notNeeded
        chorusCallID = nil

        currentTask = Task { [weak self] in
            await self?.run(recordingURL: recordingURL, formattedDuration: formattedDuration)
        }
    }

    /// Cancels any in-flight pipeline (e.g. the user closed the status panel mid-run).
    func cancel() {
        currentTask?.cancel()
        resumeRename(with: nil)
    }

    /// Resolves a pending rename prompt from the status panel. `newName` is the desired
    /// base filename (without extension); pass `nil` to keep the current name and proceed.
    func submitRename(_ newName: String?) {
        resumeRename(with: newName)
    }

    private func resumeRename(with newName: String?) {
        guard let renameContinuation else { return }
        self.renameContinuation = nil
        renamePrompt = nil
        renameContinuation.resume(returning: newName)
    }

    /// Awaits completion of the current run, for deterministic test assertions.
    func waitUntilFinished() async {
        await currentTask?.value
    }

    private func run(recordingURL: URL, formattedDuration: String) async {
        let accessedOutputDir = settings.startAccessingOutputDirectory()
        defer { if accessedOutputDir { settings.stopAccessingOutputDirectory() } }

        var workingURL = recordingURL

        // Renaming happens first, before any processing, so the same name carries through
        // to the transcoded file, the GIF, and the name Chorus shows - not just the file
        // that happens to be current when the upload step runs.
        if settings.chorusUploadEnabled && settings.chorusRenameBeforeUploadEnabled {
            let suggestedName = workingURL.deletingPathExtension().lastPathComponent
            if let newName = await requestRename(
                suggestedName: suggestedName,
                formattedDuration: formattedDuration,
                destinationDirectory: workingURL.deletingLastPathComponent()
            ) {
                workingURL = renamedFile(at: workingURL, toBaseName: newName) ?? workingURL
            }
        }

        // Captured before transcoding, which appends " (Transcoded)" to the filename -
        // the transcoded file is what actually gets uploaded, but Chorus's title should
        // stay the clean recording name, not the on-disk transcoded filename.
        let chorusTitle = workingURL.deletingPathExtension().lastPathComponent

        if Task.isCancelled { return }

        if settings.handBrakeTranscodeEnabled {
            workingURL = await runTranscode(inputURL: workingURL)
        }

        if Task.isCancelled { return }

        if settings.gifExportEnabled {
            await runGIFExport(inputURL: workingURL)
        }

        if Task.isCancelled { return }

        if settings.chorusUploadEnabled {
            await runUpload(fileURL: workingURL, title: chorusTitle)
        }
    }

    /// Runs the transcode step. Returns the transcoded file's URL on success, or the
    /// original `inputURL` if transcoding is skipped/fails - a failed transcode should
    /// not silently cancel an upload the user separately asked for.
    private func runTranscode(inputURL: URL) async -> URL {
        transcodeState = .running(progressText: "Starting…", fraction: 0)
        notificationService.sendTranscodeStartedNotification(fileURL: inputURL)

        guard let binaryURL = settings.handBrakeCLIURL else {
            let error = HandBrakeTranscodeError.binaryNotConfigured
            transcodeState = .failed(error.localizedDescription)
            notificationService.sendTranscodeFailedNotification(error: error)
            logger.error("Transcode failed: \(error.localizedDescription)")
            return inputURL
        }

        do {
            let transcodedURL = try await transcodeService.transcode(
                inputURL: inputURL,
                preset: settings.handBrakePreset,
                binaryURL: binaryURL
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.transcodeState = .running(progressText: Self.transcodeProgressText(for: progress), fraction: progress.fractionComplete)
                }
            }
            transcodeState = .succeeded
            notificationService.sendTranscodeCompletedNotification(fileURL: transcodedURL)

            if settings.deleteOriginalAfterTranscode {
                do {
                    try FileManager.default.removeItem(at: inputURL)
                } catch {
                    logger.error("Failed to delete original recording after transcode: \(error.localizedDescription)")
                }
            }

            return transcodedURL
        } catch {
            transcodeState = .failed(error.localizedDescription)
            notificationService.sendTranscodeFailedNotification(error: error)
            logger.error("Transcode failed: \(error.localizedDescription)")
            return inputURL
        }
    }

    /// Runs the GIF export step. Failure doesn't affect `workingURL` - a GIF is an extra
    /// artifact alongside the recording, not a replacement for it.
    private func runGIFExport(inputURL: URL) async {
        gifExportState = .running(progressText: "Starting…", fraction: 0)
        notificationService.sendGIFExportStartedNotification(fileURL: inputURL)

        guard let binaryURL = settings.ffmpegURL else {
            let error = GIFExportError.binaryNotConfigured
            gifExportState = .failed(error.localizedDescription)
            notificationService.sendGIFExportFailedNotification(error: error)
            logger.error("GIF export failed: \(error.localizedDescription)")
            return
        }

        do {
            let gifURL = try await gifExportService.export(
                inputURL: inputURL,
                binaryURL: binaryURL
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.gifExportState = .running(progressText: progress.statusText, fraction: progress.fractionComplete)
                }
            }
            gifExportState = .succeeded
            notificationService.sendGIFExportCompletedNotification(fileURL: gifURL)
        } catch {
            gifExportState = .failed(error.localizedDescription)
            notificationService.sendGIFExportFailedNotification(error: error)
            logger.error("GIF export failed: \(error.localizedDescription)")
        }
    }

    private func runUpload(fileURL: URL, title: String) async {
        uploadState = .running(progressText: "Uploading…", fraction: nil)
        notificationService.sendUploadStartedNotification(fileURL: fileURL)

        guard let cookieHeader = chorusSession.cookieHeader, let xsrfToken = chorusSession.xsrfToken else {
            let error = ChorusUploadError.notSignedIn
            uploadState = .failed(error.localizedDescription)
            notificationService.sendUploadFailedNotification(error: error)
            logger.error("Upload failed: \(error.localizedDescription)")
            return
        }

        do {
            let result = try await uploadService.upload(
                fileURL: fileURL,
                title: title,
                cookieHeader: cookieHeader,
                xsrfToken: xsrfToken,
                isPrivate: settings.chorusUploadPrivate
            )
            chorusCallID = result.callID
            uploadState = .succeeded
            notificationService.sendUploadCompletedNotification(link: nil)
        } catch {
            uploadState = .failed(error.localizedDescription)
            notificationService.sendUploadFailedNotification(error: error)
            logger.error("Upload failed: \(error.localizedDescription)")
        }
    }

    /// Suspends until the status panel calls `submitRename(_:)`, surfacing `renamePrompt`
    /// for it to display in the meantime.
    private func requestRename(suggestedName: String, formattedDuration: String, destinationDirectory: URL) async -> String? {
        await withCheckedContinuation { continuation in
            renameContinuation = continuation
            renamePrompt = RenamePrompt(
                suggestedName: suggestedName,
                formattedDuration: formattedDuration,
                destinationDirectory: destinationDirectory
            )
        }
    }

    /// Renames `fileURL` on disk to `baseName` (its extension is preserved), resolving a
    /// name collision by appending a numeric suffix. Returns `nil` - leaving the original
    /// file in place - if `baseName` sanitizes to empty, matches the current name, or the
    /// move fails.
    private func renamedFile(at fileURL: URL, toBaseName baseName: String) -> URL? {
        let sanitized = baseName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, sanitized != fileURL.deletingPathExtension().lastPathComponent else { return nil }

        let directory = fileURL.deletingLastPathComponent()
        let ext = fileURL.pathExtension
        func candidateURL(_ name: String) -> URL {
            directory.appending(path: ext.isEmpty ? name : "\(name).\(ext)")
        }

        var candidate = candidateURL(sanitized)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = candidateURL("\(sanitized) \(suffix)")
            suffix += 1
        }

        do {
            try FileManager.default.moveItem(at: fileURL, to: candidate)
            return candidate
        } catch {
            logger.error("Failed to rename recording before Chorus upload: \(error.localizedDescription)")
            return nil
        }
    }

    /// A compact "42% - 0:32 remaining" label - HandBrakeCLI's own progress line (used
    /// directly as the status text before this) is a long fps/ETA string that the panel's
    /// single-line, middle-truncated display cut off, hiding the ETA it contained.
    private static func transcodeProgressText(for progress: HandBrakeProgress) -> String {
        let percent = Int((progress.fractionComplete * 100).rounded())
        guard let etaSeconds = progress.etaSeconds else {
            return "\(percent)%"
        }
        return "\(percent)% - \(RecorderViewModel.formatDuration(etaSeconds)) remaining"
    }

    private func isCase(_ state: StepState, _ pattern: StepState) -> Bool {
        if case .failed = state, case .failed = pattern { return true }
        return false
    }
}
