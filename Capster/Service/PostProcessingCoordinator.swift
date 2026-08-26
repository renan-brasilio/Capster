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

    private(set) var transcodeState: StepState = .notNeeded
    private(set) var gifExportState: StepState = .notNeeded
    private(set) var uploadState: StepState = .notNeeded
    private(set) var chorusLink: URL?

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
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "PostProcessingCoordinator")
    private var currentTask: Task<Void, Never>?

    init(
        settings: SettingsStore,
        notificationService: NotificationService,
        transcodeService: HandBrakeTranscodeService = HandBrakeTranscodeService(),
        gifExportService: GIFExportService = GIFExportService(),
        uploadService: ChorusUploadService = ChorusUploadService()
    ) {
        self.settings = settings
        self.notificationService = notificationService
        self.transcodeService = transcodeService
        self.gifExportService = gifExportService
        self.uploadService = uploadService
    }

    /// Starts the pipeline for a just-finished recording. No-ops if no automation is
    /// enabled. Returns immediately; the pipeline runs in an internal `Task`.
    func start(recordingURL: URL) {
        guard settings.handBrakeTranscodeEnabled || settings.gifExportEnabled || settings.chorusUploadEnabled else { return }

        currentTask?.cancel()
        transcodeState = settings.handBrakeTranscodeEnabled ? .queued : .notNeeded
        gifExportState = settings.gifExportEnabled ? .queued : .notNeeded
        uploadState = settings.chorusUploadEnabled ? .queued : .notNeeded
        chorusLink = nil

        currentTask = Task { [weak self] in
            await self?.run(recordingURL: recordingURL)
        }
    }

    /// Cancels any in-flight pipeline (e.g. the user closed the status panel mid-run).
    func cancel() {
        currentTask?.cancel()
    }

    /// Awaits completion of the current run, for deterministic test assertions.
    func waitUntilFinished() async {
        await currentTask?.value
    }

    private func run(recordingURL: URL) async {
        let accessedOutputDir = settings.startAccessingOutputDirectory()
        defer { if accessedOutputDir { settings.stopAccessingOutputDirectory() } }

        var workingURL = recordingURL

        if settings.handBrakeTranscodeEnabled {
            workingURL = await runTranscode(inputURL: workingURL)
        }

        if Task.isCancelled { return }

        if settings.gifExportEnabled {
            await runGIFExport(inputURL: workingURL)
        }

        if Task.isCancelled { return }

        if settings.chorusUploadEnabled {
            await runUpload(fileURL: workingURL)
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
                    self?.transcodeState = .running(progressText: progress.statusText, fraction: progress.fractionComplete)
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

    private func runUpload(fileURL: URL) async {
        uploadState = .running(progressText: "Uploading…", fraction: nil)
        notificationService.sendUploadStartedNotification(fileURL: fileURL)

        guard let token = settings.chorusAPIToken, !token.isEmpty else {
            let error = ChorusUploadError.tokenNotConfigured
            uploadState = .failed(error.localizedDescription)
            notificationService.sendUploadFailedNotification(error: error)
            logger.error("Upload failed: \(error.localizedDescription)")
            return
        }

        do {
            let result = try await uploadService.upload(fileURL: fileURL, token: token)
            chorusLink = result.link
            uploadState = .succeeded
            notificationService.sendUploadCompletedNotification(link: result.link)
        } catch {
            uploadState = .failed(error.localizedDescription)
            notificationService.sendUploadFailedNotification(error: error)
            logger.error("Upload failed: \(error.localizedDescription)")
        }
    }

    private func isCase(_ state: StepState, _ pattern: StepState) -> Bool {
        if case .failed = state, case .failed = pattern { return true }
        return false
    }
}
