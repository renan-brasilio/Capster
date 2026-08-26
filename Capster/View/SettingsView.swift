//
//  SettingsView.swift
//  Capster
//
//  Created by Joshua Sattler on 29.01.26.
//

import AppKit
import KeyboardShortcuts
import SwiftUI

/// The settings window for Capster
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var updaterService: UpdaterService
    var permissionService: PermissionService

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(settings: settings, updaterService: updaterService)
            }

            Tab("Video", systemImage: "video") {
                VideoSettingsView(settings: settings)
            }

            Tab("Audio", systemImage: "waveform") {
                AudioSettingsView(settings: settings, permissionService: permissionService)
            }

            Tab("Shortcuts", systemImage: "keyboard") {
                ShortcutsSettingsView()
            }

            Tab("Automation", systemImage: "wand.and.stars") {
                AutomationSettingsView(settings: settings)
            }
        }
        .frame(width: 500, height: 420)
    }
}

// MARK: - Shortcuts Settings

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section("Recording") {
                KeyboardShortcuts.Recorder("Toggle Recording", name: .toggleRecording)
            }

            Section("Content Selection") {
                KeyboardShortcuts.Recorder("Select Content", name: .selectContent)
                KeyboardShortcuts.Recorder("Select Area", name: .selectArea)
            }

            Section {
                Text("Shortcuts work globally, even when Capster is not focused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Video Settings

struct VideoSettingsView: View {
    @Bindable var settings: SettingsStore

    private var alphaChannelHelpText: String {
        switch settings.videoCodec {
        case .proRes4444:
            return "ProRes 4444 always includes alpha channel support"
        case .hevc:
            return "Enable transparency support for HEVC"
        case .h264, .proRes422:
            return "Alpha channel not supported by this codec"
        }
    }

    private var hdrHelpText: String {
        if settings.videoCodec.supportsHDR {
            return "Enable 10-bit HDR capture for high dynamic range content"
        } else {
            return "HDR is only supported with ProRes 422 and ProRes 4444 codecs"
        }
    }

    private var qualityHelpText: String {
        if settings.videoCodec.supportsQualitySetting {
            return "Controls the video bitrate. Higher quality produces sharper output with larger files"
        } else {
            return "ProRes codecs use fixed-quality encoding"
        }
    }

    private let captureNativeResHelpText = """
        When enabled, captures at the display's native pixel resolution. \
        When disabled, captures at the logical (1x) resolution. Has no effect on non-Retina displays
        """

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Frame Rate", selection: $settings.frameRate) {
                    ForEach(FrameRate.allCases) { rate in
                        Text(rate.displayName).tag(rate)
                    }
                }

                Picker("Codec", selection: $settings.videoCodec) {
                    ForEach(VideoCodec.allCases) { codec in
                        let isSupported = settings.containerFormat.supportedVideoCodecs.contains(codec)
                        if isSupported {
                            Text(codec.rawValue).tag(codec)
                        } else {
                            Text("\(codec.rawValue) (not supported for \(settings.containerFormat.rawValue.uppercased()))")
                                .foregroundStyle(.secondary)
                                .tag(codec)
                        }
                    }
                }

                Picker("Container", selection: $settings.containerFormat) {
                    ForEach(ContainerFormat.allCases) { format in
                        Text(".\(format.rawValue)").tag(format)
                    }
                }

                Picker("Quality", selection: $settings.videoQuality) {
                    ForEach(VideoQuality.allCases) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
                .disabled(!settings.videoCodec.supportsQualitySetting)
                .help(qualityHelpText)
            }

            Section("Advanced") {
                Toggle("Capture Alpha Channel", isOn: $settings.captureAlphaChannel)
                    .disabled(!settings.videoCodec.canToggleAlpha || !settings.containerFormat.supportsAlphaChannel)
                    .help(alphaChannelHelpText)

                Toggle("HDR Recording", isOn: $settings.captureHDR)
                    .disabled(!settings.videoCodec.supportsHDR)
                    .help(hdrHelpText)

                Toggle("Native Resolution", isOn: $settings.captureNativeResolution)
                    .help(captureNativeResHelpText)
            }

            Section("Display Elements") {
                Toggle("Show Cursor", isOn: $settings.showCursor)
                Toggle("Show Wallpaper", isOn: $settings.showWallpaper)
                Toggle("Show Menu Bar", isOn: $settings.showMenuBar)
                Toggle("Show Dock", isOn: $settings.showDock)
                Toggle("Show Capster", isOn: $settings.showCapster)
            }

            Section("Window Capture") {
                Toggle("Show Window Shadows", isOn: $settings.showWindowShadows)
                    .help("Include window shadows when capturing individual windows")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Audio Settings

struct AudioSettingsView: View {
    @Bindable var settings: SettingsStore
    var permissionService: PermissionService

    @State private var isRequestingMicrophoneAccess = false

    var body: some View {
        Form {
            Section("Sources") {
                Toggle("Capture System Audio", isOn: $settings.captureSystemAudio)
                    .help("Record audio from applications and system sounds")

                Toggle("Capture Microphone", isOn: $settings.captureMicrophone)
                    .help("Record audio from the default microphone input")
            }

            Section("Permissions") {
                MicrophonePermissionRow(
                    permissionService: permissionService,
                    isRequesting: isRequestingMicrophoneAccess
                ) {
                    requestOrOpenMicrophoneSettings()
                }

                Text("Required to record from the microphone. If Capster was recently renamed or updated, this may need to be granted again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Format") {
                Picker("Codec", selection: $settings.audioCodec) {
                    ForEach(AudioCodec.allCases) { codec in
                        let isSupported = settings.containerFormat.supportedAudioCodecs.contains(codec)
                        if isSupported {
                            Text(codec.rawValue).tag(codec)
                        } else {
                            Text("\(codec.rawValue) (not supported for \(settings.containerFormat.rawValue.uppercased()))")
                                .foregroundStyle(.secondary)
                                .tag(codec)
                        }
                    }
                }
                .help("AAC is compressed, PCM is uncompressed lossless (MOV only)")
            }

            Section {
                Text("Audio tracks are recorded separately for post-processing flexibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            permissionService.updatePermissionStates()
        }
    }

    /// Requests microphone access if not yet determined, or opens System Settings
    /// if it was previously denied (macOS won't re-prompt once denied).
    private func requestOrOpenMicrophoneSettings() {
        if permissionService.microphoneState == .denied {
            permissionService.openMicrophoneSettings()
            return
        }

        isRequestingMicrophoneAccess = true
        Task {
            await permissionService.requestMicrophonePermission()
            isRequestingMicrophoneAccess = false
        }
    }
}

/// A row showing the current microphone permission state, with an action
/// to grant access (if undetermined) or open System Settings (if denied).
struct MicrophonePermissionRow: View {
    let permissionService: PermissionService
    let isRequesting: Bool
    let action: () -> Void

    private var statusIcon: String {
        switch permissionService.microphoneState {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch permissionService.microphoneState {
        case .granted: .green
        case .denied: .red
        case .unknown: .orange
        }
    }

    private var statusText: String {
        switch permissionService.microphoneState {
        case .granted: "Granted"
        case .denied: "Denied"
        case .unknown: "Not Requested"
        }
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .foregroundStyle(.secondary)

                if permissionService.microphoneState != .granted {
                    Button(isRequesting ? "Requesting…" : (permissionService.microphoneState == .denied ? "Open System Settings" : "Grant Access")) {
                        action()
                    }
                    .disabled(isRequesting)
                }
            }
        } label: {
            Text("Microphone Access")
        }
    }
}

// MARK: - Automation Settings

struct AutomationSettingsView: View {
    @Bindable var settings: SettingsStore

    @State private var tokenDraft: String = ""
    @State private var isInstallingHandBrake = false
    @State private var installStatusText: String?
    @State private var installErrorText: String?

    private var handBrakeCLIPath: String? {
        settings.handBrakeCLIURL?.path(percentEncoded: false)
    }

    var body: some View {
        Form {
            Section("HandBrake Transcode") {
                Toggle("Transcode After Recording", isOn: $settings.handBrakeTranscodeEnabled)

                Picker("Preset", selection: $settings.handBrakePreset) {
                    ForEach(HandBrakePreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .disabled(!settings.handBrakeTranscodeEnabled)

                Toggle("Delete Original After Transcode", isOn: $settings.deleteOriginalAfterTranscode)
                    .disabled(!settings.handBrakeTranscodeEnabled)
                    .help("Removes the original recording once HandBrake finishes successfully, leaving only the transcoded file.")

                LabeledContent("HandBrakeCLI") {
                    HStack {
                        Button("Locate HandBrakeCLI…") {
                            locateHandBrakeCLI()
                        }
                        if !settings.hasHandBrakeCLI {
                            Button(isInstallingHandBrake ? "Installing…" : "Install via Homebrew") {
                                installHandBrakeCLI()
                            }
                            .disabled(isInstallingHandBrake)
                        }
                        if settings.hasHandBrakeCLI {
                            Button("Reset", role: .destructive) {
                                settings.resetHandBrakeCLI()
                            }
                        }
                    }
                }

                if isInstallingHandBrake {
                    Text(installStatusText ?? "Starting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let installErrorText {
                    Text(installErrorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let handBrakeCLIPath {
                    Text(handBrakeCLIPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("HandBrakeCLI not located. Install it via Homebrew above, or install it yourself (e.g. \"brew install handbrake\") and select the binary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Chorus.ai Upload") {
                Toggle("Upload After Recording", isOn: $settings.chorusUploadEnabled)

                SecureField("API Token", text: $tokenDraft)
                    .disabled(!settings.chorusUploadEnabled)
                    .onChange(of: tokenDraft) { _, newValue in
                        settings.chorusAPIToken = newValue
                    }

                Text("Chorus.ai's upload API contract is unverified against a real account - if uploads fail immediately, this is the first place to check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            tokenDraft = settings.chorusAPIToken ?? ""
        }
    }

    /// Opens an NSOpenPanel to select the HandBrakeCLI executable
    private func locateHandBrakeCLI() {
        let panel = NSOpenPanel()
        panel.title = "Locate HandBrakeCLI"
        panel.message = "Select the HandBrakeCLI executable (commonly installed via Homebrew at /opt/homebrew/bin/HandBrakeCLI or /usr/local/bin/HandBrakeCLI)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: "/opt/homebrew/bin")
        panel.treatsFilePackagesAsDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            settings.setHandBrakeCLIURL(url)
        }
    }

    /// Runs `brew install handbrake` and locates HandBrakeCLI automatically afterward,
    /// so first-time setup doesn't require leaving Capster for Terminal.
    private func installHandBrakeCLI() {
        isInstallingHandBrake = true
        installErrorText = nil
        installStatusText = "Starting…"

        Task {
            let installer = HandBrakeInstallerService()
            do {
                let url = try await installer.install { line in
                    Task { @MainActor in installStatusText = line }
                }
                settings.setHandBrakeCLIURL(url)
                isInstallingHandBrake = false
                installStatusText = nil
            } catch {
                isInstallingHandBrake = false
                installStatusText = nil
                installErrorText = error.localizedDescription
            }
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    var updaterService: UpdaterService

    @State private var automaticallyChecksForUpdates: Bool

    init(settings: SettingsStore, updaterService: UpdaterService) {
        self.settings = settings
        self.updaterService = updaterService
        self._automaticallyChecksForUpdates = State(initialValue: updaterService.automaticallyChecksForUpdates)
    }

    /// Formats the output directory path for display
    private var displayPath: String {
        let path = settings.outputDirectory.path(percentEncoded: false)
        // Replace home directory with ~ for cleaner display
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var body: some View {
        Form {
            Section("Output Location") {
                LabeledContent {
                    HStack {
                        Button("Change...") {
                            selectOutputDirectory()
                        }

                        if settings.hasCustomOutputDirectory {
                            Button("Reset", role: .destructive) {
                                settings.resetOutputDirectory()
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(displayPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                TextField("Filename Format", text: $settings.filenameTemplate)

                LabeledContent("Preview") {
                    Text(settings.generateFilename())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text("Use {date} and {time} as placeholders - e.g. \(SettingsStore.defaultFilenameTemplate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                Toggle("3-Second Countdown Before Recording", isOn: $settings.countdownEnabled)
                Toggle("Open Folder When Recording Is Done", isOn: $settings.openFolderAfterRecording)
            }

            Section("Software Updates") {
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                    .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                        updaterService.automaticallyChecksForUpdates = newValue
                    }

                LabeledContent("Updates") {
                    Button("Check for Update") {
                        updaterService.checkForUpdates()
                    }
                    .disabled(!updaterService.canCheckForUpdates)
                }
            }

            AboutSection()
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Opens an NSOpenPanel to select a custom output directory
    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Select Output Directory"
        panel.message = "Choose where recordings will be saved"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputDirectory

        if panel.runModal() == .OK, let url = panel.url {
            settings.setCustomOutputDirectory(url)
        }
    }
}

// MARK: - About Section

struct AboutSection: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var gitSHA: String {
        Bundle.main.infoDictionary?["GitSHA"] as? String ?? "dev"
    }

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: "v\(appVersion) (\(gitSHA))")

            LabeledContent("Source Code") {
                Link(
                    "github.com/renan-brasilio/Capster",
                    destination: URL(string: "https://github.com/renan-brasilio/Capster")!
                )
            }

            LabeledContent("Fork of") {
                Link(
                    "BetterCapture by Joshua Sattler",
                    destination: URL(string: "https://github.com/jsattler/BetterCapture")!
                )
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView(settings: SettingsStore(), updaterService: UpdaterService(), permissionService: PermissionService())
}
