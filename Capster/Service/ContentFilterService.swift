//
//  ContentFilterService.swift
//  Capster
//
//  Created by Joshua Sattler on 29.01.26.
//

import Foundation
import ScreenCaptureKit
import OSLog
import CoreGraphics
import AVFoundation

/// Service responsible for applying content filter settings (wallpaper, dock, menu bar)
@MainActor
final class ContentFilterService {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "ContentFilterService")

    /// Checks if screen recording permission has been granted
    /// - Returns: true if permission is granted
    func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Requests screen recording permission from the user
    /// - Returns: true if permission was granted (or was already granted)
    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Checks if microphone permission has been granted
    /// - Returns: true if permission is granted
    func hasMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Requests microphone permission from the user
    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Checks whether the display targeted by a filter is still connected
    ///
    /// A display picked from the content picker is captured by its `displayID`. Disconnecting
    /// the display leaves the filter intact but makes it produce no frames, so it has to be
    /// validated against the currently connected displays before capture starts. Window and
    /// application filters are not bound to a display and always pass.
    /// - Parameter filter: The filter to validate
    /// - Returns: true if the filter can still be captured
    func isSelectedDisplayConnected(_ filter: SCContentFilter) async -> Bool {
        guard filter.style == .display,
              let displayID = filter.includedDisplays.first?.displayID else {
            return true
        }

        guard let content = try? await SCShareableContent.current else {
            // Nothing to validate against - let the capture attempt surface the real failure
            logger.warning("Could not read shareable content, skipping display validation")
            return true
        }

        let isConnected = content.displays.contains { $0.displayID == displayID }

        if !isConnected {
            logger.warning("Selected display \(displayID) is no longer connected")
        }

        return isConnected
    }

    /// Applies user settings to a content filter for display capture
    /// - Parameters:
    ///   - filter: The original filter from the content picker
    ///   - settings: User settings for content visibility
    /// - Returns: A modified filter with settings applied
    func applySettings(to filter: SCContentFilter, settings: SettingsStore) async throws -> SCContentFilter {
        // Menu bar can be set directly on any filter
        filter.includeMenuBar = settings.showMenuBar

        // For wallpaper and dock exclusion, we need to rebuild the filter for display capture
        guard let display = filter.includedDisplays.first else {
            logger.info("Filter is not a display capture, returning with menu bar setting only")
            return filter
        }

        // If both wallpaper and dock are shown and Capster is shown, no need to rebuild the filter
        if settings.showWallpaper && settings.showDock && settings.showCapster {
            logger.info("No exclusions needed, returning original filter")
            return filter
        }

        // Check for screen recording permission before accessing SCShareableContent
        guard hasScreenRecordingPermission() else {
            logger.warning("Screen recording permission not granted, skipping window exclusions")
            return filter
        }

        let content = try await SCShareableContent.current
        let onScreenWindows = content.windows.filter { $0.isOnScreen }

        // Excluding by application (rather than by the specific SCWindow instances found
        // above) covers windows that don't exist yet - e.g. Capster's own menu bar
        // popover, which is normally closed and only appears mid-recording when the user
        // opens it to pause/stop. A window-ID-based exclusion snapshotted at filter-build
        // time can never catch that; excluding the whole app does, for the lifetime of
        // this filter.
        var excludedApplications: [SCRunningApplication] = []
        var exceptedWindows: [SCWindow] = []

        if !settings.showCapster, let capsterApp = content.applications.first(where: { $0.bundleIdentifier == Bundle.main.bundleIdentifier }) {
            excludedApplications.append(capsterApp)
            logger.debug("Excluding Capster application (all current and future windows)")
        }

        // Wallpaper and Dock are both owned by com.apple.dock as separate windows -
        // excluding the whole app and excepting whichever should stay visible gives
        // independent control over each, the same as the Capster case above.
        if (!settings.showWallpaper || !settings.showDock), let dockApp = content.applications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) {
            excludedApplications.append(dockApp)

            let dockWindows = onScreenWindows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.dock" }
            if settings.showWallpaper {
                let wallpaperWindows = dockWindows.filter { ($0.title ?? "").hasPrefix("Wallpaper-") }
                exceptedWindows.append(contentsOf: wallpaperWindows)
                logger.debug("Excepting \(wallpaperWindows.count) wallpaper window(s) from Dock exclusion")
            }
            if settings.showDock {
                let dockOnlyWindows = dockWindows.filter { !($0.title ?? "").hasPrefix("Wallpaper-") }
                exceptedWindows.append(contentsOf: dockOnlyWindows)
                logger.debug("Excepting \(dockOnlyWindows.count) dock window(s) from Dock exclusion")
            }
        }

        // Backstop is a macOS 26 layer behind wallpaper, not owned by com.apple.dock, so
        // it needs its own (dynamically resolved, not hardcoded) owning application.
        if !settings.showWallpaper,
           let backstopWindow = onScreenWindows.first(where: { ($0.title ?? "").contains("Backstop") }),
           let backstopApp = backstopWindow.owningApplication,
           !excludedApplications.contains(where: { $0.processID == backstopApp.processID }) {
            excludedApplications.append(backstopApp)
            logger.debug("Excluding Backstop application")
        }

        guard !excludedApplications.isEmpty else {
            logger.info("No applications to exclude, returning original filter")
            return filter
        }

        logger.info("Excluding \(excludedApplications.count) application(s), excepting \(exceptedWindows.count) window(s)")

        let newFilter = SCContentFilter(display: display, excludingApplications: excludedApplications, exceptingWindows: exceptedWindows)
        newFilter.includeMenuBar = settings.showMenuBar

        return newFilter
    }
}
