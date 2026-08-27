//
//  NotificationService.swift
//  Capster
//
//  Created by Joshua Sattler on 06.02.26.
//

import Foundation
import UserNotifications
import AppKit
import OSLog

/// Service responsible for managing user notifications
@MainActor
@Observable
final class NotificationService: NSObject {

    // MARK: - Constants

    private enum NotificationIdentifier {
        static let categoryRecordingSaved = "RECORDING_SAVED"
        static let categoryRecordingFailed = "RECORDING_FAILED"
        static let actionShowInFinder = "SHOW_IN_FINDER"
        static let actionEditRecording = "EDIT_RECORDING"
        static let categoryPostProcessing = "POST_PROCESSING"
        static let categoryPostProcessingFailed = "POST_PROCESSING_FAILED"
        static let categoryChorusUploadCompleted = "CHORUS_UPLOAD_COMPLETED"
        static let actionOpenChorusLink = "OPEN_CHORUS_LINK"
    }

    private enum UserInfoKey {
        static let folderURL = "folderURL"
        static let recordingURL = "recordingURL"
        static let chorusLink = "chorusLink"
    }

    // MARK: - Properties

    private let settings: SettingsStore
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Capster",
        category: "NotificationService"
    )

    /// Called with the recording's URL when the user taps "Edit Recording" on the
    /// "Recording Saved" notification - this is the primary entry point for the editor's
    /// optional branch, since it's the first moment after a recording finishes where the
    /// user can choose "edit" instead of "quick post-process". Set by `RecorderViewModel`,
    /// which owns the closure that actually opens the editor window.
    var onEditRecordingRequested: ((URL) -> Void)?

    // MARK: - Initialization

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        setupNotificationDelegate()
        registerNotificationCategories()
        requestNotificationPermission()
    }

    // MARK: - Setup

    private func setupNotificationDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    private func registerNotificationCategories() {
        // Action to show recording in Finder
        let showInFinderAction = UNNotificationAction(
            identifier: NotificationIdentifier.actionShowInFinder,
            title: "Show in Finder",
            options: [.foreground]
        )

        // Action to open the just-finished recording in the post-recording editor
        let editRecordingAction = UNNotificationAction(
            identifier: NotificationIdentifier.actionEditRecording,
            title: "Edit Recording",
            options: [.foreground]
        )

        // Category for successful recording with actions
        let recordingSavedCategory = UNNotificationCategory(
            identifier: NotificationIdentifier.categoryRecordingSaved,
            actions: [showInFinderAction, editRecordingAction],
            intentIdentifiers: []
        )

        // Category for failed recording (no actions needed)
        let recordingFailedCategory = UNNotificationCategory(
            identifier: NotificationIdentifier.categoryRecordingFailed,
            actions: [],
            intentIdentifiers: []
        )

        // Categories for the post-processing pipeline (transcode/upload started/completed)
        let postProcessingCategory = UNNotificationCategory(
            identifier: NotificationIdentifier.categoryPostProcessing,
            actions: [],
            intentIdentifiers: []
        )

        let postProcessingFailedCategory = UNNotificationCategory(
            identifier: NotificationIdentifier.categoryPostProcessingFailed,
            actions: [],
            intentIdentifiers: []
        )

        // Action to open the Chorus link for a completed upload
        let openChorusLinkAction = UNNotificationAction(
            identifier: NotificationIdentifier.actionOpenChorusLink,
            title: "Open Link",
            options: [.foreground]
        )

        let chorusUploadCompletedCategory = UNNotificationCategory(
            identifier: NotificationIdentifier.categoryChorusUploadCompleted,
            actions: [openChorusLinkAction],
            intentIdentifiers: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            recordingSavedCategory,
            recordingFailedCategory,
            postProcessingCategory,
            postProcessingFailedCategory,
            chorusUploadCompletedCategory
        ])
    }

    private func requestNotificationPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                if granted {
                    logger.info("Notification permission granted")
                } else {
                    logger.warning("Notification permission denied")
                }
            } catch {
                logger.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Public Methods

    /// Sends a notification for a successfully saved recording
    /// - Parameter fileURL: The URL of the saved recording file
    func sendRecordingSavedNotification(fileURL: URL) {
        send(
            title: "Recording Saved",
            body: "Your recording has been saved to \(fileURL.lastPathComponent)",
            category: NotificationIdentifier.categoryRecordingSaved,
            folderURL: fileURL.deletingLastPathComponent(),
            recordingURL: fileURL
        )
    }

    /// Sends a notification for a recording that was saved without any video frames
    /// - Parameter fileURL: The URL of the saved recording file
    func sendRecordingMissingVideoNotification(fileURL: URL) {
        send(
            title: "Recording Saved Without Video",
            body: "No video was captured. Only audio was saved to \(fileURL.lastPathComponent)",
            category: NotificationIdentifier.categoryRecordingSaved,
            folderURL: fileURL.deletingLastPathComponent()
        )
    }

    /// Sends a notification for a recording that could not be started
    ///
    /// Start failures leave nothing on disk, so they are reported separately from
    /// failures that lose an in-progress recording.
    /// - Parameter error: The error that prevented the recording from starting
    func sendRecordingStartFailedNotification(error: Error) {
        send(
            title: "Can't Start Recording",
            body: error.localizedDescription,
            category: NotificationIdentifier.categoryRecordingFailed
        )
    }

    /// Sends a notification for a failed recording
    /// - Parameter error: The error that caused the recording to fail
    func sendRecordingFailedNotification(error: Error) {
        send(
            title: "Recording Failed",
            body: "Your recording could not be saved: \(error.localizedDescription)",
            category: NotificationIdentifier.categoryRecordingFailed
        )
    }

    /// Sends a notification when a `.capster` job file's recording can't be found -
    /// most likely moved, renamed, or deleted since the job file was created.
    /// Sends a notification when a `.capster` project file's recording can't be found -
    /// most likely moved, renamed, or deleted since the project file was written.
    func sendProjectSourceMissingNotification(fileURL: URL) {
        send(
            title: "Recording Not Found",
            body: "Can't open the editor - \"\(fileURL.lastPathComponent)\" is missing. It may have been moved, renamed, or deleted.",
            category: NotificationIdentifier.categoryRecordingFailed
        )
    }

    /// Sends a notification when recording stopped unexpectedly
    /// - Parameter error: Optional error that caused the stop
    func sendRecordingStoppedNotification(error: Error?) {
        let reason = error.map { ": \($0.localizedDescription)" } ?? ""

        send(
            title: "Recording Stopped",
            body: "Recording stopped unexpectedly\(reason)",
            category: NotificationIdentifier.categoryRecordingFailed
        )
    }

    // MARK: - Post-Processing Notifications

    func sendTranscodeStartedNotification(fileURL: URL) {
        send(
            title: "Transcoding Recording",
            body: "Transcoding \(fileURL.lastPathComponent) with HandBrake…",
            category: NotificationIdentifier.categoryPostProcessing
        )
    }

    func sendTranscodeCompletedNotification(fileURL: URL) {
        send(
            title: "Transcode Complete",
            body: "\(fileURL.lastPathComponent) has been transcoded",
            category: NotificationIdentifier.categoryPostProcessing,
            folderURL: fileURL.deletingLastPathComponent()
        )
    }

    func sendTranscodeFailedNotification(error: Error) {
        send(
            title: "Transcode Failed",
            body: error.localizedDescription,
            category: NotificationIdentifier.categoryPostProcessingFailed
        )
    }

    func sendGIFExportStartedNotification(fileURL: URL) {
        send(
            title: "Exporting GIF",
            body: "Exporting \(fileURL.lastPathComponent) as a GIF…",
            category: NotificationIdentifier.categoryPostProcessing
        )
    }

    func sendGIFExportCompletedNotification(fileURL: URL) {
        send(
            title: "GIF Export Complete",
            body: "\(fileURL.lastPathComponent) is ready",
            category: NotificationIdentifier.categoryPostProcessing,
            folderURL: fileURL.deletingLastPathComponent()
        )
    }

    func sendGIFExportFailedNotification(error: Error) {
        send(
            title: "GIF Export Failed",
            body: error.localizedDescription,
            category: NotificationIdentifier.categoryPostProcessingFailed
        )
    }

    func sendDoNotDisturbShortcutFailedNotification(shortcutName: String) {
        send(
            title: "Do Not Disturb Shortcut Not Found",
            body: "Couldn't run the \"\(shortcutName)\" shortcut. Create it in Shortcuts.app with a \"Set Focus\" action, or fix the name in Settings > Recording.",
            category: NotificationIdentifier.categoryPostProcessingFailed
        )
    }

    func sendSlackSignInFailedNotification(error: Error) {
        send(
            title: "Slack Sign-In Failed",
            body: error.localizedDescription,
            category: NotificationIdentifier.categoryPostProcessingFailed
        )
    }

    func sendUploadStartedNotification(fileURL: URL) {
        send(
            title: "Uploading to Chorus",
            body: "Uploading \(fileURL.lastPathComponent)…",
            category: NotificationIdentifier.categoryPostProcessing
        )
    }

    /// Sends a notification for a completed Chorus upload. If the (unverified) API
    /// response didn't include a link, falls back to a plain completion notification.
    func sendUploadCompletedNotification(link: URL?) {
        guard let link else {
            send(
                title: "Upload Complete",
                body: "Your recording was uploaded to Chorus.",
                category: NotificationIdentifier.categoryPostProcessing
            )
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Upload Complete"
        content.body = "Your recording was uploaded to Chorus."
        content.sound = .default
        content.categoryIdentifier = NotificationIdentifier.categoryChorusUploadCompleted
        content.userInfo = [UserInfoKey.chorusLink: link.absoluteString]

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
                logger.info("Notification sent: Upload Complete")
            } catch {
                logger.error("Failed to send notification 'Upload Complete': \(error.localizedDescription)")
            }
        }
    }

    func sendUploadFailedNotification(error: Error) {
        send(
            title: "Upload Failed",
            body: error.localizedDescription,
            category: NotificationIdentifier.categoryPostProcessingFailed
        )
    }

    // MARK: - Private Methods

    /// Builds and delivers a notification request
    /// - Parameters:
    ///   - title: The notification title
    ///   - body: The notification body
    ///   - category: The category identifier determining the available actions
    ///   - folderURL: Folder to reveal when the notification is clicked, if any
    ///   - recordingURL: Recording to open in the editor for the "Edit Recording" action, if any
    private func send(title: String, body: String, category: String, folderURL: URL? = nil, recordingURL: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category

        var userInfo: [String: Any] = [:]
        if let folderURL {
            userInfo[UserInfoKey.folderURL] = folderURL.path()
        }
        if let recordingURL {
            userInfo[UserInfoKey.recordingURL] = recordingURL.path(percentEncoded: false)
        }
        if !userInfo.isEmpty {
            content.userInfo = userInfo
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
                logger.info("Notification sent: \(title)")
            } catch {
                logger.error("Failed to send notification '\(title)': \(error.localizedDescription)")
            }
        }
    }

    private func openFolderInFinder(path: String) {
        _ = settings.startAccessingOutputDirectory()
        defer { settings.stopAccessingOutputDirectory() }
        let url = URL(filePath: path)
        NSWorkspace.shared.open(url)
    }

    private func openChorusLink(_ link: String) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show notifications even when app is in foreground
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let categoryIdentifier = response.notification.request.content.categoryIdentifier

        switch response.actionIdentifier {
        case NotificationIdentifier.actionShowInFinder,
            UNNotificationDefaultActionIdentifier where await categoryIdentifier == NotificationIdentifier.categoryRecordingSaved:
            // User tapped the notification or the "Show in Finder" action
            if let folderPath = await userInfo[UserInfoKey.folderURL] as? String {
                await MainActor.run {
                    openFolderInFinder(path: folderPath)
                }
            }

        case NotificationIdentifier.actionEditRecording:
            // User tapped "Edit Recording" - open it in the post-recording editor instead
            // of running the quick post-processing pipeline.
            if let recordingPath = await userInfo[UserInfoKey.recordingURL] as? String {
                let recordingURL = URL(fileURLWithPath: recordingPath)
                await MainActor.run {
                    onEditRecordingRequested?(recordingURL)
                }
            }

        case NotificationIdentifier.actionOpenChorusLink,
            UNNotificationDefaultActionIdentifier where await categoryIdentifier == NotificationIdentifier.categoryChorusUploadCompleted:
            // User tapped the notification or the "Open Link" action
            if let link = await userInfo[UserInfoKey.chorusLink] as? String {
                await MainActor.run {
                    openChorusLink(link)
                }
            }

        default:
            break
        }
    }
}
