//
//  SettingsStore.swift
//  Capster
//
//  Created by Joshua Sattler on 29.01.26.
//

import AppKit
import Foundation

/// Video codec options for recording
enum VideoCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "H.265"
    case proRes422 = "ProRes 422"
    case proRes4444 = "ProRes 4444"

    var id: String { rawValue }

    /// Whether this codec supports alpha channel capture
    var supportsAlphaChannel: Bool {
        switch self {
        case .hevc, .proRes4444:
            return true
        case .h264, .proRes422:
            return false
        }
    }

    /// Whether alpha channel is always enabled (cannot be disabled)
    var alwaysHasAlpha: Bool {
        switch self {
        case .proRes4444:
            return true
        case .hevc, .h264, .proRes422:
            return false
        }
    }

    /// Whether alpha channel can be toggled by the user
    var canToggleAlpha: Bool {
        switch self {
        case .hevc:
            return true
        case .h264, .proRes422, .proRes4444:
            return false
        }
    }

    /// Whether this codec supports HDR (10-bit) recording
    var supportsHDR: Bool {
        switch self {
        case .hevc, .proRes422, .proRes4444:
            return true
        case .h264:
            return false
        }
    }

    /// The pixel format ScreenCaptureKit and AVAssetWriter should use for HDR capture.
    ///
    /// Each codec requires a specific chroma subsampling and bit depth:
    /// - HEVC Main 10: 10-bit 4:2:0
    /// - ProRes 422: 10-bit 4:2:2
    /// - ProRes 4444: 16-bit half-float RGBA
    var hdrPixelFormat: OSType {
        switch self {
        case .hevc:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .proRes422:
            return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .proRes4444:
            return kCVPixelFormatType_64RGBAHalf
        case .h264:
            return kCVPixelFormatType_32BGRA
        }
    }

    /// Whether this codec supports user-adjustable quality/bitrate settings.
    ///
    /// ProRes codecs use fixed-quality encoding and ignore bitrate controls.
    var supportsQualitySetting: Bool {
        switch self {
        case .h264, .hevc:
            return true
        case .proRes422, .proRes4444:
            return false
        }
    }
}

/// Container format for output files
enum ContainerFormat: String, CaseIterable, Identifiable {
    case mov
    case mp4

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    /// Video codecs supported by this container format
    var supportedVideoCodecs: [VideoCodec] {
        switch self {
        case .mov:
            // MOV (QuickTime) supports all codecs including ProRes and HEVC with alpha
            return VideoCodec.allCases
        case .mp4:
            // MP4 (MPEG-4) only supports H.264 and HEVC (without alpha)
            return [.h264, .hevc]
        }
    }

    /// Whether this container supports alpha channel video
    var supportsAlphaChannel: Bool {
        switch self {
        case .mov:
            return true
        case .mp4:
            // MP4 does not support alpha channel (HEVC with alpha or ProRes 4444)
            return false
        }
    }

    /// Audio codecs supported by this container format
    var supportedAudioCodecs: [AudioCodec] {
        switch self {
        case .mov:
            // MOV supports all audio codecs
            return AudioCodec.allCases
        case .mp4:
            // MP4 only supports AAC (not raw PCM)
            return [.aac]
        }
    }
}

/// Audio codec options
enum AudioCodec: String, CaseIterable, Identifiable {
    case aac = "AAC"
    case pcm = "PCM"

    var id: String { rawValue }
}

/// Frame rate options for recording
enum FrameRate: Int, CaseIterable, Identifiable {
    case native = 0
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .native:
            return "Native"
        default:
            return "\(rawValue) fps"
        }
    }

    /// The frame rate in Hz the recording is captured and written at.
    ///
    /// For explicit rates this returns the selected value. `.native` resolves to
    /// 60: ScreenCaptureKit only delivers frames when content changes, so a
    /// higher ceiling produced a heavily variable frame rate that broke
    /// concatenation and upload tools without adding useful frames.
    ///
    /// `CaptureEngine` uses this for `minimumFrameInterval`, `AssetWriter` uses it
    /// as the constant frame rate grid, and both use it for the bitrate budget.
    var effectiveFrameRate: Double {
        switch self {
        case .native: 60.0
        default:      Double(rawValue)
        }
    }
}

/// Video quality presets controlling compression bitrate for H.264 and HEVC.
///
/// Each preset defines a bits-per-pixel multiplier used to calculate the
/// target average bitrate: `width * height * bpp * frameRate`.
/// ProRes codecs ignore this setting since they use fixed-quality encoding.
enum VideoQuality: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }

    /// Bits-per-pixel multiplier for H.264
    var h264BitsPerPixel: Double {
        switch self {
        case .low:    0.04
        case .medium: 0.2
        case .high:   0.6
        }
    }

    /// Bits-per-pixel multiplier for HEVC (more efficient codec)
    var hevcBitsPerPixel: Double {
        switch self {
        case .low:    0.02
        case .medium: 0.15
        case .high:   0.4
        }
    }

    /// Returns the bits-per-pixel multiplier for the given codec
    func bitsPerPixel(for codec: VideoCodec) -> Double? {
        switch codec {
        case .h264: h264BitsPerPixel
        case .hevc: hevcBitsPerPixel
        case .proRes422, .proRes4444: nil
        }
    }
}

/// Curated HandBrakeCLI presets exposed in Settings, matching the built-in preset names
/// HandBrakeCLI ships with (verified against `HandBrakeCLI --preset-list`, version 1.11.2).
enum HandBrakePreset: String, CaseIterable, Identifiable {
    case veryFast1080p30 = "Very Fast 1080p30"
    case fast1080p30 = "Fast 1080p30"
    case hq1080p30Surround = "HQ 1080p30 Surround"
    case superHQ1080p30Surround = "Super HQ 1080p30 Surround"
    case h265MKV1080p30 = "H.265 MKV 1080p30"

    var id: String { rawValue }

    /// The exact string passed to `HandBrakeCLI --preset "<value>"`.
    var cliPresetName: String { rawValue }
}

/// Describes which ScreenCaptureKit HDR configuration is active, so the
/// ``AssetWriter`` can tag the output container with matching colorimetry.
enum HDRPreset {
    /// SDR capture — no HDR color properties needed.
    case sdr

    /// Manual BT.2020 / PQ configuration applied to a plain
    /// `SCStreamConfiguration`. Used on macOS 15–25 to produce
    /// HDR10-compatible output (BT.2020 primaries, PQ transfer
    /// function, BT.2020 YCbCr matrix).
    case hdr10Manual

    /// ``SCStreamConfiguration.Preset.captureHDRRecordingPreservedSDRHDR10``
    /// (macOS 26+). Same BT.2020 / PQ colorimetry as `.hdr10Manual`, but
    /// also injects static HDR10 mastering metadata and preserves SDR UI
    /// appearance on HDR screens.
    case hdr10PreservedSDR
}

/// Persists user preferences using UserDefaults
@MainActor
@Observable
final class SettingsStore {

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let keychain: KeychainServing

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard, keychain: KeychainServing = KeychainService()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    // MARK: - Recording Behavior Settings

    /// Whether a 3-second countdown overlay is shown before a recording actually starts.
    var countdownEnabled: Bool {
        get {
            access(keyPath: \.countdownEnabled)
            guard defaults.object(forKey: "countdownEnabled") != nil else { return true }
            return defaults.bool(forKey: "countdownEnabled")
        }
        set {
            withMutation(keyPath: \.countdownEnabled) {
                defaults.set(newValue, forKey: "countdownEnabled")
            }
        }
    }

    /// Whether the output folder is revealed in Finder once a recording finishes saving.
    var openFolderAfterRecording: Bool {
        get {
            access(keyPath: \.openFolderAfterRecording)
            return defaults.bool(forKey: "openFolderAfterRecording")
        }
        set {
            withMutation(keyPath: \.openFolderAfterRecording) {
                defaults.set(newValue, forKey: "openFolderAfterRecording")
            }
        }
    }


    /// Whether Do Not Disturb is turned on for the duration of a recording, via the two
    /// user-created Shortcuts named by `doNotDisturbOnShortcutName`/`doNotDisturbOffShortcutName`.
    /// macOS has no direct API for toggling Focus modes, so this is the only way to do it.
    var doNotDisturbEnabled: Bool {
        get {
            access(keyPath: \.doNotDisturbEnabled)
            return defaults.bool(forKey: "doNotDisturbEnabled")
        }
        set {
            withMutation(keyPath: \.doNotDisturbEnabled) {
                defaults.set(newValue, forKey: "doNotDisturbEnabled")
            }
        }
    }

    static let defaultDoNotDisturbOnShortcutName = "Capster DND On"
    static let defaultDoNotDisturbOffShortcutName = "Capster DND Off"

    /// Name of the Shortcuts.app shortcut run (via `shortcuts run`) to turn Do Not Disturb
    /// on when a recording starts. Must contain a single "Set Focus" action.
    var doNotDisturbOnShortcutName: String {
        get {
            access(keyPath: \.doNotDisturbOnShortcutName)
            guard let stored = defaults.string(forKey: "doNotDisturbOnShortcutName"), !stored.isEmpty else {
                return Self.defaultDoNotDisturbOnShortcutName
            }
            return stored
        }
        set {
            withMutation(keyPath: \.doNotDisturbOnShortcutName) {
                defaults.set(newValue, forKey: "doNotDisturbOnShortcutName")
            }
        }
    }

    /// Name of the Shortcuts.app shortcut run to turn Do Not Disturb back off when a
    /// recording stops. Must contain a single "Set Focus" action.
    var doNotDisturbOffShortcutName: String {
        get {
            access(keyPath: \.doNotDisturbOffShortcutName)
            guard let stored = defaults.string(forKey: "doNotDisturbOffShortcutName"), !stored.isEmpty else {
                return Self.defaultDoNotDisturbOffShortcutName
            }
            return stored
        }
        set {
            withMutation(keyPath: \.doNotDisturbOffShortcutName) {
                defaults.set(newValue, forKey: "doNotDisturbOffShortcutName")
            }
        }
    }

    // MARK: - Video Settings

    var frameRate: FrameRate {
        get {
            FrameRate(rawValue: frameRateRaw) ?? .fps60
        }
        set {
            frameRateRaw = newValue.rawValue
        }
    }

    var videoQuality: VideoQuality {
        get {
            VideoQuality(rawValue: videoQualityRaw) ?? .medium
        }
        set {
            videoQualityRaw = newValue.rawValue
        }
    }

    var videoCodec: VideoCodec {
        get {
            VideoCodec(rawValue: videoCodecRaw) ?? .hevc
        }
        set {
            // Ensure the codec is compatible with the current container format
            guard containerFormat.supportedVideoCodecs.contains(newValue) else {
                // If codec is not compatible, switch to MOV container first
                containerFormatRaw = ContainerFormat.mov.rawValue
                videoCodecRaw = newValue.rawValue
                return
            }

            videoCodecRaw = newValue.rawValue

            // Set alpha channel based on codec and container capabilities
            if newValue.alwaysHasAlpha {
                // ProRes 4444 always has alpha, requires MOV container
                captureAlphaChannel = true
            } else if !newValue.supportsAlphaChannel || !containerFormat.supportsAlphaChannel {
                // H.264, ProRes 422 never have alpha, or container doesn't support it
                captureAlphaChannel = false
            }
            // HEVC can toggle alpha (if container supports it), so leave it as-is

            // Disable HDR for codecs that don't support it
            if !newValue.supportsHDR {
                captureHDR = false
            }

            // HEVC with alpha uses a separate codec type that doesn't support
            // Main 10 HDR, so alpha and HDR are mutually exclusive for HEVC.
            if newValue == .hevc && captureHDR {
                captureAlphaChannel = false
            }
        }
    }

    var containerFormat: ContainerFormat {
        get {
            ContainerFormat(rawValue: containerFormatRaw) ?? .mov
        }
        set {
            containerFormatRaw = newValue.rawValue

            // Ensure current video codec is compatible with new container
            if !newValue.supportedVideoCodecs.contains(videoCodec) {
                // Switch to a compatible codec (prefer HEVC for quality)
                videoCodec = .hevc
            }

            // Disable alpha channel if container doesn't support it
            if !newValue.supportsAlphaChannel {
                captureAlphaChannel = false
            }

            // Ensure current audio codec is compatible with new container
            if !newValue.supportedAudioCodecs.contains(audioCodec) {
                audioCodec = .aac
            }
        }
    }

    var captureAlphaChannel: Bool {
        get {
            access(keyPath: \.captureAlphaChannel)
            // ProRes 4444 always has alpha regardless of stored value
            if videoCodec.alwaysHasAlpha {
                return true
            }
            // If codec or container doesn't support alpha, always return false
            if !videoCodec.supportsAlphaChannel || !containerFormat.supportsAlphaChannel {
                return false
            }
            // HEVC with alpha uses a different codec type incompatible with Main 10 HDR
            if videoCodec == .hevc && captureHDR {
                return false
            }
            return defaults.bool(forKey: "captureAlphaChannel")
        }
        set {
            // Only allow alpha channel if both codec and container support it
            let canEnable = videoCodec.supportsAlphaChannel && containerFormat.supportsAlphaChannel
            var finalValue = newValue && canEnable

            // HEVC alpha and HDR are mutually exclusive
            if videoCodec == .hevc && finalValue && captureHDR {
                finalValue = false
            }

            withMutation(keyPath: \.captureAlphaChannel) {
                defaults.set(finalValue, forKey: "captureAlphaChannel")
            }
        }
    }

    var captureHDR: Bool {
        get {
            access(keyPath: \.captureHDR)
            return defaults.bool(forKey: "captureHDR")
        }
        set {
            withMutation(keyPath: \.captureHDR) {
                defaults.set(newValue, forKey: "captureHDR")
            }

            // HEVC alpha and HDR are mutually exclusive
            if newValue && videoCodec == .hevc {
                captureAlphaChannel = false
            }
        }
    }

    var captureNativeResolution: Bool {
        get {
            access(keyPath: \.captureNativeResolution)
            return defaults.object(forKey: "captureNativeResolution") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.captureNativeResolution) {
                defaults.set(newValue, forKey: "captureNativeResolution")
            }
        }
    }

    /// The active HDR preset for the current codec and OS version.
    ///
    /// Both ``CaptureEngine`` and ``AssetWriter`` use this to ensure the
    /// stream configuration and output color tags stay in sync.
    var hdrPreset: HDRPreset {
        guard captureHDR && videoCodec.supportsHDR else { return .sdr }
        if #available(macOS 26, *) {
            return .hdr10PreservedSDR
        }
        return .hdr10Manual
    }

    // MARK: - Audio Settings

    var captureMicrophone: Bool {
        get {
            access(keyPath: \.captureMicrophone)
            return defaults.bool(forKey: "captureMicrophone")
        }
        set {
            withMutation(keyPath: \.captureMicrophone) {
                defaults.set(newValue, forKey: "captureMicrophone")
            }
        }
    }

    var captureSystemAudio: Bool {
        get {
            access(keyPath: \.captureSystemAudio)
            return defaults.bool(forKey: "captureSystemAudio")
        }
        set {
            withMutation(keyPath: \.captureSystemAudio) {
                defaults.set(newValue, forKey: "captureSystemAudio")
            }
        }
    }

    var audioCodec: AudioCodec {
        get {
            AudioCodec(rawValue: audioCodecRaw) ?? .aac
        }
        set {
            // Ensure the audio codec is compatible with the current container format
            guard containerFormat.supportedAudioCodecs.contains(newValue) else {
                // If codec is not compatible, switch to MOV container first
                containerFormatRaw = ContainerFormat.mov.rawValue
                audioCodecRaw = newValue.rawValue
                return
            }

            audioCodecRaw = newValue.rawValue
        }
    }

    var selectedMicrophoneID: String? {
        get {
            access(keyPath: \.selectedMicrophoneID)
            return defaults.string(forKey: "selectedMicrophoneID")
        }
        set {
            withMutation(keyPath: \.selectedMicrophoneID) {
                defaults.set(newValue, forKey: "selectedMicrophoneID")
            }
        }
    }

    // MARK: - Presenter Overlay Settings

    var presenterOverlayEnabled: Bool {
        get {
            access(keyPath: \.presenterOverlayEnabled)
            return defaults.bool(forKey: "presenterOverlayEnabled")
        }
        set {
            withMutation(keyPath: \.presenterOverlayEnabled) {
                defaults.set(newValue, forKey: "presenterOverlayEnabled")
            }
        }
    }

    /// The selected camera device ID for Presenter Overlay, or `nil` for the system default.
    var selectedCameraID: String? {
        get {
            access(keyPath: \.selectedCameraID)
            return defaults.string(forKey: "selectedCameraID")
        }
        set {
            withMutation(keyPath: \.selectedCameraID) {
                defaults.set(newValue, forKey: "selectedCameraID")
            }
        }
    }

    // MARK: - Content Filter Settings

    var showCursor: Bool {
        get {
            access(keyPath: \.showCursor)
            return defaults.object(forKey: "showCursor") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.showCursor) {
                defaults.set(newValue, forKey: "showCursor")
            }
        }
    }

    var showWallpaper: Bool {
        get {
            access(keyPath: \.showWallpaper)
            return defaults.object(forKey: "showWallpaper") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.showWallpaper) {
                defaults.set(newValue, forKey: "showWallpaper")
            }
        }
    }

    var showMenuBar: Bool {
        get {
            access(keyPath: \.showMenuBar)
            return defaults.object(forKey: "showMenuBar") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.showMenuBar) {
                defaults.set(newValue, forKey: "showMenuBar")
            }
        }
    }

    var showDock: Bool {
        get {
            access(keyPath: \.showDock)
            return defaults.object(forKey: "showDock") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.showDock) {
                defaults.set(newValue, forKey: "showDock")
            }
        }
    }

    var showWindowShadows: Bool {
        get {
            access(keyPath: \.showWindowShadows)
            return defaults.object(forKey: "showWindowShadows") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.showWindowShadows) {
                defaults.set(newValue, forKey: "showWindowShadows")
            }
        }
    }

    var showCapster: Bool {
        get {
            access(keyPath: \.showCapster)
            return defaults.object(forKey: "showCapster") as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.showCapster) {
                defaults.set(newValue, forKey: "showCapster")
            }
        }
    }

    // MARK: - Output Settings

    /// The default output directory (Movies/Capster)
    var defaultOutputDirectory: URL {
        URL.homeDirectory.appending(path: "Movies/Capster")
    }

    /// Default filename template - matches the format recordings used before this setting existed.
    static let defaultFilenameTemplate = "Capster_{date}-{time}"

    /// Template used to name new recordings. Supports `{date}` (yyyy-MM-dd) and `{time}`
    /// (HH.mm.ss) placeholders; the container's file extension is appended automatically.
    var filenameTemplate: String {
        get {
            access(keyPath: \.filenameTemplate)
            guard let stored = defaults.string(forKey: "filenameTemplate"), !stored.isEmpty else {
                return Self.defaultFilenameTemplate
            }
            return stored
        }
        set {
            withMutation(keyPath: \.filenameTemplate) {
                defaults.set(newValue, forKey: "filenameTemplate")
            }
        }
    }

    /// Security-scoped bookmark data for the custom output directory
    private var customOutputDirectoryBookmark: Data? {
        get {
            access(keyPath: \.customOutputDirectoryBookmark)
            return defaults.data(forKey: "customOutputDirectoryBookmark")
        }
        set {
            withMutation(keyPath: \.customOutputDirectoryBookmark) {
                defaults.set(newValue, forKey: "customOutputDirectoryBookmark")
            }
        }
    }

    /// Whether a custom output directory has been set
    var hasCustomOutputDirectory: Bool {
        customOutputDirectoryBookmark != nil
    }

    /// The current output directory, using custom path if set
    var outputDirectory: URL {
        guard let bookmarkData = customOutputDirectoryBookmark else {
            return defaultOutputDirectory
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale, let newBookmark = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                customOutputDirectoryBookmark = newBookmark
            }

            return url
        } catch {
            // If bookmark resolution fails, fall back to default
            return defaultOutputDirectory
        }
    }

    /// Sets a custom output directory from a user-selected URL
    /// - Parameter url: The URL selected by the user via NSOpenPanel
    func setCustomOutputDirectory(_ url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            customOutputDirectoryBookmark = bookmarkData
        } catch {
            // Failed to create bookmark, ignore
        }
    }

    /// Resets to the default output directory
    func resetOutputDirectory() {
        customOutputDirectoryBookmark = nil
    }

    /// No-ops now that Capster doesn't run under App Sandbox - kept so call sites don't
    /// need to change if sandboxing is ever reintroduced.
    func startAccessingOutputDirectory() -> Bool { true }

    func stopAccessingOutputDirectory() {}

    // MARK: - Automation Settings

    /// Whether a finished recording is transcoded with HandBrakeCLI before anything else runs.
    var handBrakeTranscodeEnabled: Bool {
        get {
            access(keyPath: \.handBrakeTranscodeEnabled)
            return defaults.bool(forKey: "handBrakeTranscodeEnabled")
        }
        set {
            withMutation(keyPath: \.handBrakeTranscodeEnabled) {
                defaults.set(newValue, forKey: "handBrakeTranscodeEnabled")
            }
        }
    }

    var handBrakePreset: HandBrakePreset {
        get { HandBrakePreset(rawValue: handBrakePresetRaw) ?? .fast1080p30 }
        set { handBrakePresetRaw = newValue.rawValue }
    }

    /// Whether the original recording is deleted once HandBrake finishes successfully,
    /// leaving only the transcoded file behind.
    var deleteOriginalAfterTranscode: Bool {
        get {
            access(keyPath: \.deleteOriginalAfterTranscode)
            return defaults.bool(forKey: "deleteOriginalAfterTranscode")
        }
        set {
            withMutation(keyPath: \.deleteOriginalAfterTranscode) {
                defaults.set(newValue, forKey: "deleteOriginalAfterTranscode")
            }
        }
    }

    /// Whether a (possibly transcoded) recording is uploaded to Chorus.ai afterwards.
    var chorusUploadEnabled: Bool {
        get {
            access(keyPath: \.chorusUploadEnabled)
            return defaults.bool(forKey: "chorusUploadEnabled")
        }
        set {
            withMutation(keyPath: \.chorusUploadEnabled) {
                defaults.set(newValue, forKey: "chorusUploadEnabled")
            }
        }
    }

    /// Whether uploads are marked private in Chorus (visible only to the uploader).
    /// Defaults to on, since a screen recording uploaded automatically shouldn't become
    /// company-visible without the user having chosen that.
    var chorusUploadPrivate: Bool {
        get {
            access(keyPath: \.chorusUploadPrivate)
            guard defaults.object(forKey: "chorusUploadPrivate") != nil else { return true }
            return defaults.bool(forKey: "chorusUploadPrivate")
        }
        set {
            withMutation(keyPath: \.chorusUploadPrivate) {
                defaults.set(newValue, forKey: "chorusUploadPrivate")
            }
        }
    }

    /// Whether the pipeline pauses before uploading to let the user rename the recording.
    /// The rename is applied to the file on disk, so the name Chorus shows matches exactly.
    var chorusRenameBeforeUploadEnabled: Bool {
        get {
            access(keyPath: \.chorusRenameBeforeUploadEnabled)
            return defaults.bool(forKey: "chorusRenameBeforeUploadEnabled")
        }
        set {
            withMutation(keyPath: \.chorusRenameBeforeUploadEnabled) {
                defaults.set(newValue, forKey: "chorusRenameBeforeUploadEnabled")
            }
        }
    }

    /// Whether a GIF is exported from the (possibly transcoded) recording via ffmpeg.
    var gifExportEnabled: Bool {
        get {
            access(keyPath: \.gifExportEnabled)
            return defaults.bool(forKey: "gifExportEnabled")
        }
        set {
            withMutation(keyPath: \.gifExportEnabled) {
                defaults.set(newValue, forKey: "gifExportEnabled")
            }
        }
    }

    /// Security-scoped bookmark data for the user-located HandBrakeCLI executable.
    private var handBrakeCLIBookmark: Data? {
        get {
            access(keyPath: \.handBrakeCLIBookmark)
            return defaults.data(forKey: "handBrakeCLIBookmark")
        }
        set {
            withMutation(keyPath: \.handBrakeCLIBookmark) {
                defaults.set(newValue, forKey: "handBrakeCLIBookmark")
            }
        }
    }

    /// Whether the user has located a HandBrakeCLI binary.
    var hasHandBrakeCLI: Bool { handBrakeCLIBookmark != nil }

    /// Resolves the HandBrakeCLI bookmark to a URL, refreshing it if stale.
    /// Returns nil if never set, or if resolution fails (e.g. the binary was moved
    /// or deleted without re-selecting it in Settings).
    var handBrakeCLIURL: URL? {
        guard let bookmarkData = handBrakeCLIBookmark else { return nil }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale, let refreshed = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                handBrakeCLIBookmark = refreshed
            }

            return url
        } catch {
            return nil
        }
    }

    /// Sets the HandBrakeCLI binary location from a user-selected URL (NSOpenPanel result).
    func setHandBrakeCLIURL(_ url: URL) {
        guard let bookmarkData = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        handBrakeCLIBookmark = bookmarkData
    }

    /// Clears the located HandBrakeCLI binary.
    func resetHandBrakeCLI() {
        handBrakeCLIBookmark = nil
    }

    /// Security-scoped bookmark data for the user-located ffmpeg executable.
    private var ffmpegBookmark: Data? {
        get {
            access(keyPath: \.ffmpegBookmark)
            return defaults.data(forKey: "ffmpegBookmark")
        }
        set {
            withMutation(keyPath: \.ffmpegBookmark) {
                defaults.set(newValue, forKey: "ffmpegBookmark")
            }
        }
    }

    /// Whether the user has located an ffmpeg binary.
    var hasFFmpegCLI: Bool { ffmpegBookmark != nil }

    /// Resolves the ffmpeg bookmark to a URL, refreshing it if stale. Returns nil if never
    /// set, or if resolution fails (e.g. the binary was moved or deleted without
    /// re-selecting it in Settings).
    var ffmpegURL: URL? {
        guard let bookmarkData = ffmpegBookmark else { return nil }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale, let refreshed = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                ffmpegBookmark = refreshed
            }

            return url
        } catch {
            return nil
        }
    }

    /// Sets the ffmpeg binary location from a user-selected URL (NSOpenPanel result).
    func setFFmpegURL(_ url: URL) {
        guard let bookmarkData = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        ffmpegBookmark = bookmarkData
    }

    /// Clears the located ffmpeg binary.
    func resetFFmpeg() {
        ffmpegBookmark = nil
    }

    // MARK: - Slack Settings

    /// Client ID of the Slack App used for the OAuth sign-in flow. Not secret - the
    /// matching Client Secret is stored in the Keychain via `SlackSessionService`.
    var slackClientID: String {
        get {
            access(keyPath: \.slackClientID)
            return defaults.string(forKey: "slackClientID") ?? ""
        }
        set {
            withMutation(keyPath: \.slackClientID) {
                defaults.set(newValue, forKey: "slackClientID")
            }
        }
    }

    /// Whether a custom Slack status is set while recording, restored to whatever it was
    /// beforehand once the recording stops.
    var slackStatusEnabled: Bool {
        get {
            access(keyPath: \.slackStatusEnabled)
            return defaults.bool(forKey: "slackStatusEnabled")
        }
        set {
            withMutation(keyPath: \.slackStatusEnabled) {
                defaults.set(newValue, forKey: "slackStatusEnabled")
            }
        }
    }

    /// Whether Slack's own Do Not Disturb (separate from macOS's) is snoozed while
    /// recording, and un-snoozed once it stops.
    var slackDoNotDisturbEnabled: Bool {
        get {
            access(keyPath: \.slackDoNotDisturbEnabled)
            return defaults.bool(forKey: "slackDoNotDisturbEnabled")
        }
        set {
            withMutation(keyPath: \.slackDoNotDisturbEnabled) {
                defaults.set(newValue, forKey: "slackDoNotDisturbEnabled")
            }
        }
    }

    static let defaultSlackStatusText = "Recording a video for documentation; Answers will be delayed"
    static let defaultSlackStatusEmoji = ":black_circle_for_record:"

    /// Slack status text shown while recording.
    var slackStatusText: String {
        get {
            access(keyPath: \.slackStatusText)
            guard let stored = defaults.string(forKey: "slackStatusText"), !stored.isEmpty else {
                return Self.defaultSlackStatusText
            }
            return stored
        }
        set {
            withMutation(keyPath: \.slackStatusText) {
                defaults.set(newValue, forKey: "slackStatusText")
            }
        }
    }

    /// Slack status emoji (as a `:colon_name:` code) shown while recording.
    var slackStatusEmoji: String {
        get {
            access(keyPath: \.slackStatusEmoji)
            guard let stored = defaults.string(forKey: "slackStatusEmoji"), !stored.isEmpty else {
                return Self.defaultSlackStatusEmoji
            }
            return stored
        }
        set {
            withMutation(keyPath: \.slackStatusEmoji) {
                defaults.set(newValue, forKey: "slackStatusEmoji")
            }
        }
    }

    // MARK: - Private Storage

    private var handBrakePresetRaw: String {
        get {
            access(keyPath: \.handBrakePresetRaw)
            return defaults.string(forKey: "handBrakePreset") ?? HandBrakePreset.fast1080p30.rawValue
        }
        set {
            withMutation(keyPath: \.handBrakePresetRaw) {
                defaults.set(newValue, forKey: "handBrakePreset")
            }
        }
    }

    private var frameRateRaw: Int {
        get {
            access(keyPath: \.frameRateRaw)
            guard defaults.object(forKey: "frameRate") != nil else {
                return FrameRate.fps60.rawValue
            }
            return defaults.integer(forKey: "frameRate")
        }
        set {
            withMutation(keyPath: \.frameRateRaw) {
                defaults.set(newValue, forKey: "frameRate")
            }
        }
    }

    private var videoQualityRaw: String {
        get {
            access(keyPath: \.videoQualityRaw)
            return defaults.string(forKey: "videoQuality") ?? VideoQuality.medium.rawValue
        }
        set {
            withMutation(keyPath: \.videoQualityRaw) {
                defaults.set(newValue, forKey: "videoQuality")
            }
        }
    }

    private var videoCodecRaw: String {
        get {
            access(keyPath: \.videoCodecRaw)
            return defaults.string(forKey: "videoCodec") ?? VideoCodec.hevc.rawValue
        }
        set {
            withMutation(keyPath: \.videoCodecRaw) {
                defaults.set(newValue, forKey: "videoCodec")
            }
        }
    }

    private var containerFormatRaw: String {
        get {
            access(keyPath: \.containerFormatRaw)
            return defaults.string(forKey: "containerFormat") ?? ContainerFormat.mov.rawValue
        }
        set {
            withMutation(keyPath: \.containerFormatRaw) {
                defaults.set(newValue, forKey: "containerFormat")
            }
        }
    }

    private var audioCodecRaw: String {
        get {
            access(keyPath: \.audioCodecRaw)
            return defaults.string(forKey: "audioCodec") ?? AudioCodec.aac.rawValue
        }
        set {
            withMutation(keyPath: \.audioCodecRaw) {
                defaults.set(newValue, forKey: "audioCodec")
            }
        }
    }

    // MARK: - Helper Methods

    /// Expands `filenameTemplate`'s `{date}`/`{time}` placeholders against a given moment
    /// and appends the container's file extension.
    func generateFilename(for date: Date = Date()) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH.mm.ss"

        let expanded = filenameTemplate
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: date))

        return "\(Self.sanitizedFilenameComponent(expanded)).\(containerFormat.fileExtension)"
    }

    /// Returns the full output URL for a new recording
    func generateOutputURL() -> URL {
        outputDirectory.appending(path: generateFilename())
    }

    /// Strips path separators from a user-editable filename template's expansion, so it
    /// can never create subdirectories or escape the output directory, and falls back to
    /// the default base name if editing leaves nothing usable.
    private static func sanitizedFilenameComponent(_ raw: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:")
        let sanitized = raw.components(separatedBy: invalidCharacters).joined(separator: "-")
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Capster" : trimmed
    }
}
