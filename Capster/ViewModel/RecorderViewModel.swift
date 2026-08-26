//
//  RecorderViewModel.swift
//  Capster
//
//  Created by Joshua Sattler on 29.01.26.
//

import Foundation
import ScreenCaptureKit
import AppKit
import OSLog

/// The main view model managing recording state and coordination between services
@MainActor
@Observable
final class RecorderViewModel {

    // MARK: - Recording State

    enum RecordingState {
        case idle
        case recording
        case stopping
    }

    // MARK: - Published Properties

    private(set) var state: RecordingState = .idle
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var lastError: Error?
    private(set) var selectedContentFilter: SCContentFilter?

    /// Live microphone peak level (0...1) for the menu bar meter, polled from
    /// `AssetWriter` while capture is active - including during the countdown/Presenter
    /// Overlay wait, so the user can confirm the mic is picking anything up before the
    /// recording proper begins.
    private(set) var microphoneLevel: Float = 0

    /// The source rectangle for area selection (in display points, top-left origin)
    private(set) var selectedSourceRect: CGRect?

    /// The selected area in screen coordinates (bottom-left origin), used for the border frame overlay
    private var selectedScreenRect: CGRect?

    /// The screen on which the area selection was made
    private var selectedScreen: NSScreen?

    /// Whether the current selection is an area selection (as opposed to a picker selection)
    var isAreaSelection: Bool {
        selectedSourceRect != nil
    }

    var isRecording: Bool {
        state == .recording
    }

    /// Whether an active recording is currently paused. Only meaningful while `isRecording`.
    private(set) var isPaused = false

    /// True during the brief window right after capture has genuinely started but before
    /// real content is being written - while waiting for Presenter Overlay to be enabled
    /// manually and/or showing the countdown. Recording is internally paused throughout.
    /// Kept separate from `isPaused` so the pause/resume UI doesn't show (or accept taps)
    /// during this bootstrap window.
    private(set) var isPreparing = false

    var canStartRecording: Bool {
        selectedContentFilter != nil && state == .idle
    }

    var hasContentSelected: Bool {
        selectedContentFilter != nil
    }

    var formattedDuration: String {
        let hours = Int(recordingDuration) / 3600
        let minutes = (Int(recordingDuration) % 3600) / 60
        let seconds = Int(recordingDuration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    /// Whether Presenter Overlay is currently active (camera composited into stream)
    private(set) var isPresenterOverlayActive = false

    // MARK: - Dependencies

    let settings: SettingsStore
    let audioDeviceService: AudioDeviceService
    let cameraDeviceService: CameraDeviceService
    let previewService: PreviewService
    let notificationService: NotificationService
    let permissionService: PermissionService
    let chorusSession: ChorusSessionService
    let postProcessing: PostProcessingCoordinator
    private let captureEngine: CaptureEngine
    private let assetWriter: AssetWriter
    private let cameraSession = CameraSession()
    private let postProcessingPanel = PostProcessingPanelCoordinator()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "RecorderViewModel")

    // MARK: - Private Properties

    private var recordingTimer: Timer?
    private var levelMeterTimer: Timer?
    private var recordingStartTime: Date?
    private var pauseStartDate: Date?
    private var videoSize: CGSize = .zero
    private let areaSelectionOverlay = AreaSelectionOverlay()
    private let selectionBorderFrame = SelectionBorderFrame()
    private let recordingOverlay = RecordingOverlayCoordinator()
    private let countdownOverlay = CountdownOverlay()

    // MARK: - Initialization

    init() {
        self.settings = SettingsStore()
        self.audioDeviceService = AudioDeviceService()
        self.cameraDeviceService = CameraDeviceService()
        self.previewService = PreviewService()
        self.notificationService = NotificationService(settings: settings)
        self.permissionService = PermissionService()
        self.chorusSession = ChorusSessionService()
        self.postProcessing = PostProcessingCoordinator(settings: settings, notificationService: notificationService, chorusSession: chorusSession)
        self.captureEngine = CaptureEngine()
        self.assetWriter = AssetWriter()

        captureEngine.delegate = self
        captureEngine.sampleBufferDelegate = assetWriter
        previewService.delegate = self
    }

    // MARK: - Permission Methods

    /// Requests required permissions on app launch
    /// Only requests microphone permission if microphone capture is enabled
    func requestPermissionsOnLaunch() async {
        await permissionService.requestPermissions(includeMicrophone: settings.captureMicrophone)
    }

    /// Refreshes the current permission states
    func refreshPermissions() {
        permissionService.updatePermissionStates()
    }

    // MARK: - Public Methods

    /// Toggles the recording state. If no content is selected, triggers the appropriate
    /// selection flow based on the user's content selection mode preference.
    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else if hasContentSelected {
            await startRecording()
        } else {
            // No content selected — trigger selection based on the user's preferred mode
            switch ContentSelectionMode.current {
            case .pickContent:
                presentPicker()
            case .selectArea:
                await presentAreaSelection()
            }
        }
    }

    /// Presents the system content sharing picker
    func presentPicker() {
        startCameraSessionForPresenterOverlayIfNeeded()
        captureEngine.presentPicker()
    }

    /// Presents the area selection overlay on the display under the cursor
    func presentAreaSelection() async {
        startCameraSessionForPresenterOverlayIfNeeded()

        // Dismiss any existing border frame so it doesn't overlap the selection overlay
        selectionBorderFrame.dismiss()

        guard let result = await areaSelectionOverlay.present() else {
            logger.info("Area selection cancelled")
            return
        }

        // Show the border frame immediately so the user sees the selection outline
        selectionBorderFrame.show(screenRect: result.screenRect)

        // Find the corresponding SCDisplay for the selected screen
        do {
            let content = try await SCShareableContent.current
            let screenNumber = result.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

            guard let display = content.displays.first(where: { $0.displayID == screenNumber }) else {
                logger.error("Could not find SCDisplay for selected screen")
                return
            }

            // Create a content filter for the full display
            let filter = SCContentFilter(display: display, excludingWindows: [])

            // Convert screen rect (NSScreen coordinates, bottom-left origin) to
            // sourceRect (display coordinates, top-left origin)
            let displayHeight = CGFloat(display.height)
            let screenOrigin = result.screen.frame.origin

            let localX = result.screenRect.origin.x - screenOrigin.x
            let localY = result.screenRect.origin.y - screenOrigin.y

            // Flip Y: NSScreen has origin at bottom-left, sourceRect uses top-left
            let flippedY = displayHeight - localY - result.screenRect.height

            // Snap dimensions to even pixel counts for codec compatibility
            let scale = result.screen.backingScaleFactor
            let pixelWidth = result.screenRect.width * scale
            let pixelHeight = result.screenRect.height * scale
            let evenPixelWidth = ceil(pixelWidth / 2) * 2
            let evenPixelHeight = ceil(pixelHeight / 2) * 2

            let sourceRect = CGRect(
                x: localX,
                y: flippedY,
                width: evenPixelWidth / scale,
                height: evenPixelHeight / scale
            )

            // Clear any existing picker selection (mutually exclusive)
            captureEngine.clearSelection()

            // Store the area selection and set the filter on the capture engine
            selectedSourceRect = sourceRect
            selectedScreenRect = result.screenRect
            selectedScreen = result.screen
            selectedContentFilter = filter
            try await captureEngine.updateFilter(filter)

            logger.info("Area selected: sourceRect=\(sourceRect.debugDescription), display=\(display.displayID)")

            // Update preview with the display filter and source rect
            await previewService.setContentFilter(filter, sourceRect: sourceRect)

            // Show the recording overlay on the screen where the area was selected
            recordingOverlay.show(viewModel: self, screen: selectedScreen)

        } catch {
            selectionBorderFrame.dismiss()
            logger.error("Failed to get shareable content for area selection: \(error.localizedDescription)")
        }
    }

    /// Starts the camera session as soon as content selection begins, rather than
    /// waiting until recording starts.
    ///
    /// The system's Presenter Overlay toggle only becomes available in Control Center
    /// once an `AVCaptureSession` is active alongside the `SCStream`. Starting it only
    /// at `startRecording()` meant the toggle wasn't available until after the SCStream
    /// was already running, forcing the user to enable it mid-recording. Starting it here
    /// instead lets them turn it on before they ever hit record.
    private func startCameraSessionForPresenterOverlayIfNeeded() {
        guard settings.presenterOverlayEnabled else { return }
        Task { await cameraSession.start(deviceID: settings.selectedCameraID) }
    }

    /// Starts a new recording session
    func startRecording() async {
        guard canStartRecording else {
            logger.warning("Cannot start recording: no content selected or already recording")
            return
        }

        // Dismiss the recording overlay if it's still visible
        recordingOverlay.dismiss()

        do {
            state = .recording
            lastError = nil

            logger.info("Starting recording sequence...")

            // Sent as early as possible so the pause has time to actually take effect
            // before capture (and its audio track) starts below.
            if settings.pauseMusicOnRecordStartEnabled {
                MediaKeyService.togglePlayPause()
            }

            // Stop any active live preview before starting recording
            logger.info("Stopping any active live preview...")
            await previewService.stopPreview()
            logger.info("Live preview stopped")

            // Determine video size from filter
            if let filter = selectedContentFilter {
                videoSize = await getContentSize(from: filter)
            }
            logger.info("Video size: \(self.videoSize.width)x\(self.videoSize.height)")

            // Access security-scoped output directory before writing
            _ = settings.startAccessingOutputDirectory()

            // Setup asset writer
            let outputURL = settings.generateOutputURL()
            try assetWriter.setup(url: outputURL, settings: settings, videoSize: videoSize)
            try assetWriter.startWriting()
            logger.info("AssetWriter ready")

            // Start camera for Presenter Overlay before capture so the system detects it
            if settings.presenterOverlayEnabled {
                await cameraSession.start(deviceID: settings.selectedCameraID)
            }

            let hasPrepareWindow = settings.presenterOverlayEnabled || settings.countdownEnabled

            // With no countdown/Presenter Overlay wait, recording writes in real time the
            // instant capture starts, so this is the only point where playing the cue can't
            // end up in the system audio or microphone track - once ScreenCaptureKit is
            // capturing, anything played through the speakers gets picked up like any other
            // sound. When a prepare window exists, the cue instead plays after it below,
            // while writing is still paused.
            if !hasPrepareWindow {
                NSSound(named: "Tink")?.play()
            }

            // Start capture with the calculated video size
            logger.info("Starting capture engine...")
            try await captureEngine.startCapture(with: settings, videoSize: videoSize, sourceRect: selectedSourceRect)

            // Re-show the area selection border now that capture has started
            if isAreaSelection, let screenRect = selectedScreenRect {
                selectionBorderFrame.show(screenRect: screenRect)
            }

            // Start timers
            startTimer()
            startLevelMeterTimer()

            // The screen-sharing menu bar icon only offers Presenter Overlay once a share
            // is genuinely live, so this has to wait until capture has actually started -
            // pause immediately (nothing meaningful is written during this window, same
            // mechanism as the manual Pause button) while the user enables it, then resume
            // for real once they're ready.
            if hasPrepareWindow {
                isPreparing = true
                pauseInternal()

                let screen = selectedScreen ?? NSScreen.main ?? NSScreen.screens.first

                if settings.presenterOverlayEnabled, let screen {
                    await countdownOverlay.waitForPresenterOverlayEnable(on: screen)
                }

                if settings.countdownEnabled, let screen {
                    await countdownOverlay.runCountdown(seconds: 3, on: screen)
                }

                // Still paused here, so the cue is picked up by ScreenCaptureKit like any
                // other system sound but dropped rather than written - waiting out its
                // duration before resuming keeps it from bleeding into the resumed track.
                if let sound = NSSound(named: "Tink") {
                    sound.play()
                    try? await Task.sleep(for: .seconds(sound.duration))
                }

                resumeInternal()
                isPreparing = false
            }

            logger.info("Recording started")

        } catch {
            state = .idle
            lastError = error
            cameraSession.stop()
            selectionBorderFrame.dismiss()
            stopLevelMeterTimer()

            // The writer may already be set up and holding an empty output file. Cancel it
            // before releasing the output directory, since that is where the file lives.
            assetWriter.cancel()
            settings.stopAccessingOutputDirectory()

            // lastError has no UI representation, so every start failure has to be surfaced
            // as a notification - otherwise the record button silently does nothing.
            notificationService.sendRecordingStartFailedNotification(error: error)

            // The selection points at a display that is gone, so drop it. The next recording
            // attempt then opens the picker instead of failing the same way again.
            if error as? CaptureError == .selectedDisplayDisconnected {
                await resetSelection()
            }

            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Stops the current recording session
    func stopRecording(copyToClipboard: Bool = false) async {
        guard isRecording else { return }

        state = .stopping
        isPaused = false
        // If still waiting on Presenter Overlay / the countdown, release that wait so
        // `startRecording()` doesn't stay suspended after the recording it belongs to
        // has been torn down.
        countdownOverlay.cancel()
        isPreparing = false
        stopTimer()
        stopLevelMeterTimer()
        selectionBorderFrame.dismiss()

        do {
            // Stop capture and camera session
            try await captureEngine.stopCapture()
            cameraSession.stop()
            isPresenterOverlayActive = false

            // Finalize file
            let (outputURL, videoFrameCount) = try await assetWriter.finishWriting()

            state = .idle
            recordingDuration = 0

            logger.info("Recording stopped and saved to: \(outputURL.lastPathComponent)")
            NSSound(named: "Pop")?.play()

            if settings.openFolderAfterRecording {
                NSWorkspace.shared.selectFile(outputURL.path(percentEncoded: false), inFileViewerRootedAtPath: outputURL.deletingLastPathComponent().path(percentEncoded: false))
            }

            // Brief delay to ensure screen sharing mode has fully stopped before sending notification
            try? await Task.sleep(for: .milliseconds(100))

            // Send notification. The file is kept either way - an audio-only recording is
            // still worth more than a deleted one - but the user has to be told about it.
            if videoFrameCount == 0 {
                logger.error("Recording contains no video frames: \(outputURL.lastPathComponent)")
                notificationService.sendRecordingMissingVideoNotification(fileURL: outputURL)
            } else {
                notificationService.sendRecordingSavedNotification(fileURL: outputURL)
            }

            if copyToClipboard {
                copyFileToClipboard(outputURL)
            }

            if settings.handBrakeTranscodeEnabled || settings.gifExportEnabled || settings.chorusUploadEnabled {
                postProcessing.start(recordingURL: outputURL)
                postProcessingPanel.show(coordinator: postProcessing)
            }

            settings.stopAccessingOutputDirectory()

        } catch {
            state = .idle
            lastError = error
            assetWriter.cancel()
            settings.stopAccessingOutputDirectory()
            notificationService.sendRecordingFailedNotification(error: error)
            logger.error("Failed to stop recording: \(error.localizedDescription)")
        }
    }

    /// Cancels the current recording, discarding whatever has been captured so far.
    /// Unlike `stopRecording()`, the output file is deleted rather than finalized.
    func cancelRecording() async {
        guard isRecording else { return }

        state = .stopping
        isPaused = false
        // Release any pending Presenter Overlay / countdown wait so `startRecording()`
        // doesn't stay suspended after the recording it belongs to has been torn down.
        countdownOverlay.cancel()
        isPreparing = false
        stopTimer()
        stopLevelMeterTimer()
        selectionBorderFrame.dismiss()

        do {
            try await captureEngine.stopCapture()
        } catch {
            logger.error("Failed to stop capture while cancelling: \(error.localizedDescription)")
        }

        cameraSession.stop()
        isPresenterOverlayActive = false
        assetWriter.cancel()
        settings.stopAccessingOutputDirectory()

        state = .idle
        recordingDuration = 0

        logger.info("Recording cancelled and discarded")
    }

    /// Pauses or resumes the current recording.
    ///
    /// The capture stream, camera session, and Presenter Overlay all keep running the
    /// whole time - only appending to the output file stops - so resuming is instant and
    /// doesn't re-trigger the picker or any permission prompts.
    func togglePause() {
        guard isRecording, !isPreparing else { return }

        if isPaused {
            isPaused = false
            resumeInternal()
            logger.info("Recording resumed")
        } else {
            isPaused = true
            pauseInternal()
            logger.info("Recording paused")
        }
    }

    /// Pauses appending without touching `isPaused` - shared by `togglePause()` and the
    /// Presenter Overlay / countdown bootstrap window in `startRecording()`.
    private func pauseInternal() {
        assetWriter.pause()
        pauseStartDate = Date()
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    /// Resumes appending, shifting `recordingStartTime` forward by however long was
    /// paused so the displayed duration continues smoothly.
    private func resumeInternal() {
        assetWriter.resume()

        if let pauseStartDate, let recordingStartTime {
            self.recordingStartTime = recordingStartTime.addingTimeInterval(
                Date().timeIntervalSince(pauseStartDate))
        }
        pauseStartDate = nil
        scheduleDurationTimer()
    }

    /// Resets the capture selection, removing the border frame and clearing state
    ///
    /// Covers both area and picker selections, so the capture engine's filter is cleared
    /// alongside the view model's - otherwise the engine keeps a filter the UI no longer shows.
    func resetSelection() async {
        selectedSourceRect = nil
        selectedScreenRect = nil
        selectedScreen = nil
        selectedContentFilter = nil
        captureEngine.clearSelection()
        selectionBorderFrame.dismiss()
        recordingOverlay.dismiss()
        cameraSession.stop()
        await previewService.stopPreview()
        previewService.clearPreview()
    }

    /// Starts the live preview stream (call when menu bar window opens)
    func startPreview() async {
        guard !isRecording else { return }
        await previewService.startPreview()
    }

    /// Stops the live preview stream (call when menu bar window closes)
    func stopPreview() async {
        await previewService.stopPreview()
    }

    // MARK: - Timer Management

    private func startTimer() {
        recordingStartTime = Date()
        recordingDuration = 0
        scheduleDurationTimer()
    }

    private func scheduleDurationTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
        pauseStartDate = nil
    }

    /// Polls `AssetWriter`'s microphone level a few times a second for the menu bar meter.
    /// A dedicated timer rather than piggybacking on the once-a-second duration timer,
    /// since a meter needs to look live.
    private func startLevelMeterTimer() {
        levelMeterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.microphoneLevel = self.assetWriter.microphoneLevel
            }
        }
    }

    private func stopLevelMeterTimer() {
        levelMeterTimer?.invalidate()
        levelMeterTimer = nil
        microphoneLevel = 0
    }

    // MARK: - Helper Methods

    private func copyFileToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private func getContentSize(from filter: SCContentFilter) async -> CGSize {
        // Apply scale if Capture Native Resolution setting is enabled
        let applyScale: Bool = settings.captureNativeResolution

        // If area selection is active, use the source rect dimensions.
        // The sourceRect is already snapped to even pixel counts in presentAreaSelection().
        if let sourceRect = selectedSourceRect {
            let scale = CGFloat(filter.pointPixelScale)
            return CGSize(
                width: applyScale ? sourceRect.width * scale : sourceRect.width,
                height: applyScale ? sourceRect.height * scale : sourceRect.height
            )
        }

        // Get the content rect from the filter
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)

        if rect.width > 0 && rect.height > 0 {
            return CGSize(
                width: applyScale ? rect.width * scale : rect.width,
                height: applyScale ? rect.height * scale : rect.height
            )
        }

        // Fallback to main screen size
        if let screen = NSScreen.main {
            return CGSize(
                width: applyScale ? screen.frame.width * screen.backingScaleFactor : screen.frame.width,
                height: applyScale ? screen.frame.height * screen.backingScaleFactor : screen.frame.height
            )
        }

        return CGSize(width: 1920, height: 1080)
    }
}

// MARK: - CaptureEngineDelegate

extension RecorderViewModel: CaptureEngineDelegate {

    func captureEngine(_ engine: CaptureEngine, didUpdateFilter filter: SCContentFilter) {
        // Clear any area selection (picker and area selections are mutually exclusive)
        selectedSourceRect = nil
        selectedScreenRect = nil
        selectedScreen = nil
        selectionBorderFrame.dismiss()

        selectedContentFilter = filter
        logger.info("Content filter updated")

        // Capture a static thumbnail for the preview
        Task {
            await previewService.setContentFilter(filter)
        }

        // Show the recording overlay. For picker selections there is no stored screen
        // (selectedScreen is nil), so the overlay positions itself below the status item.
        recordingOverlay.show(viewModel: self, screen: selectedScreen)
    }

    func captureEngine(_ engine: CaptureEngine, didStopWithError error: Error?) {
        // Check if user clicked "Stop Sharing" in the menu bar
        let isUserStopped = (error as? SCStreamError)?.code == .userStopped

        if let error, !isUserStopped {
            lastError = error
            logger.error("Capture stopped with error: \(error.localizedDescription)")
        }

        // Clean up if we were recording
        if isRecording {
            if isUserStopped {
                // User clicked "Stop Sharing" - gracefully save the recording
                logger.info("User stopped sharing via system UI, saving recording...")
                Task {
                    await stopRecording()
                }
            } else {
                // Stream error during recording - try to save what we have
                logger.warning("Stream stopped unexpectedly, attempting to save recording...")
                Task {
                    await stopRecording()
                }
            }
        }
    }

    func captureEngine(_ engine: CaptureEngine, presenterOverlayDidChange isActive: Bool) {
        isPresenterOverlayActive = isActive
        logger.info("Presenter Overlay \(isActive ? "activated" : "deactivated")")
    }

    func captureEngineDidCancelPicker(_ engine: CaptureEngine) {
        logger.info("Picker was cancelled, clearing selection and preview")

        // Clear the selected content filter
        selectedContentFilter = nil

        // Dismiss the overlay if it was shown after a previous selection
        recordingOverlay.dismiss()
        cameraSession.stop()

        // Stop and clear the preview
        Task {
            await previewService.cancelCapture()
            previewService.clearPreview()
        }
    }
}

// MARK: - PreviewServiceDelegate

extension RecorderViewModel: PreviewServiceDelegate {

    func previewServiceDidStopByUser(_ service: PreviewService) {
        logger.info("User stopped sharing via system UI, clearing selection")

        // Clear the selection
        selectedContentFilter = nil

        // Clear the content filter in capture engine and deactivate picker
        captureEngine.clearSelection()
        captureEngine.deactivatePicker()
        cameraSession.stop()
    }
}
