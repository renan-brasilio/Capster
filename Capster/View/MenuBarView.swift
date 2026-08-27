//
//  MenuBarView.swift
//  Capster
//
//  Created by Joshua Sattler on 29.01.26.
//

import SwiftUI
import ScreenCaptureKit

/// The main menu bar interface for Capster
struct MenuBarView: View {
    @Bindable var viewModel: RecorderViewModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var currentPreview: NSImage?

    private var isRecording: Bool { viewModel.isRecording }
    /// Recording (including the pre-recording bootstrap window) - used to disable selection/settings.
    private var isBusy: Bool { viewModel.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            // Permission status banner (only when idle)
            if !isBusy,
               viewModel.permissionService.screenRecordingState != .granted ||
                (viewModel.settings.captureMicrophone && viewModel.permissionService.microphoneState != .granted) {
                PermissionStatusBanner(
                    permissionService: viewModel.permissionService,
                    showMicrophonePermission: viewModel.settings.captureMicrophone
                )
                MenuBarDivider()
            }

            // Recording button (stop + timer), starting status, or Start button
            if isRecording && viewModel.isPreparing {
                MenuBarActionButton(
                    title: "Starting Recording...",
                    systemImage: "timer",
                    accentColor: .green,
                    isDisabled: true
                ) {}
                .padding(.top, 8)

                MenuBarActionButton(
                    title: "Cancel Recording",
                    systemImage: "xmark.circle",
                    accentColor: .red
                ) {
                    Task {
                        await viewModel.cancelRecording()
                    }
                }
            } else if isRecording {
                RecordingButton(
                    duration: viewModel.formattedDuration,
                    isPaused: viewModel.isPaused
                ) {
                    dismiss()
                    Task {
                        await viewModel.stopRecording()
                    }
                }
                .padding(.top, 8)

                MenuBarActionButton(
                    title: viewModel.isPaused ? "Resume Recording" : "Pause Recording",
                    systemImage: viewModel.isPaused ? "play.circle" : "pause.circle",
                    accentColor: .orange
                ) {
                    viewModel.togglePause()
                }

                MenuBarActionButton(
                    title: "Restart Recording",
                    systemImage: "arrow.counterclockwise.circle",
                    accentColor: .blue
                ) {
                    Task {
                        await viewModel.restartRecording()
                    }
                }

                MenuBarActionButton(
                    title: "Cancel Recording",
                    systemImage: "xmark.circle",
                    accentColor: .red
                ) {
                    Task {
                        await viewModel.cancelRecording()
                    }
                }
            } else {
                MenuBarActionButton(
                    title: "Start Recording",
                    systemImage: "record.circle",
                    accentColor: .green,
                    isDisabled: !viewModel.canStartRecording
                ) {
                    dismiss()
                    Task {
                        await viewModel.startRecording()
                    }
                }
                .padding(.top, 8)
            }

            if isRecording && viewModel.settings.captureMicrophone {
                MicrophoneLevelRow(level: viewModel.microphoneLevel)
            }

            MenuBarDivider()

            // Content Selection
            ContentSelectionButton(viewModel: viewModel) { dismiss() }
                .disabled(isBusy)

            // Preview thumbnail
            if viewModel.hasContentSelected {
                PreviewThumbnailView(
                    previewImage: currentPreview,
                    isLivePreviewActive: viewModel.previewService.isCapturing,
                    onStartLivePreview: {
                        Task {
                            await viewModel.startPreview()
                        }
                    },
                    onStopLivePreview: {
                        Task {
                            await viewModel.stopPreview()
                        }
                    }
                )
                .onChange(of: viewModel.previewService.previewImage) { _, newImage in
                    currentPreview = newImage
                }
                .onAppear {
                    currentPreview = viewModel.previewService.previewImage
                }

                Button {
                    Task {
                        await viewModel.resetSelection()
                    }
                } label: {
                    Text("Reset Selection")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.gray.opacity(0.15), in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .disabled(isBusy)
            }

            MenuBarDivider()

            // Settings Sections
            Group {
                VideoSettingsSection(settings: viewModel.settings)

                PresenterOverlaySettingsSection(
                    settings: viewModel.settings,
                    cameraDeviceService: viewModel.cameraDeviceService
                )

                AudioSettingsSection(
                    settings: viewModel.settings,
                    audioDeviceService: viewModel.audioDeviceService
                )

                CountdownSettingsSection(settings: viewModel.settings)
            }
            .disabled(isBusy)

            MenuBarDivider()

            // Bottom Actions
            if let lastRecordingURL = viewModel.lastRecordingURL {
                MenuBarActionButton(title: "Edit Last Recording", systemImage: "scissors") {
                    dismiss()
                    viewModel.editorWindowCoordinator.show(recordingURL: lastRecordingURL, postProcessing: viewModel.postProcessing)
                }
            }

            MenuBarActionButton(title: "Open Output Folder", systemImage: "folder") {
                let settings = viewModel.settings
                let didStart = settings.startAccessingOutputDirectory()
                defer {
                    if didStart {
                        settings.stopAccessingOutputDirectory()
                    }
                }
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: settings.outputDirectory.path)
            }

            MenuBarActionButton(title: "Settings...", systemImage: "gear") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            }

            MenuBarActionButton(title: "Quit...", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.bottom, 8)
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Menu Bar Action Button

/// A styled action button for menu bar window with hover effect
struct MenuBarActionButton: View {
    let title: String
    var systemImage: String?
    var accentColor: Color = .primary
    var isDisabled: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage {
                    ZStack {
                        Circle()
                            .fill(.gray.opacity(0.2))
                            .frame(width: 24, height: 24)

                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isDisabled ? Color.gray.opacity(0.3) : accentColor.opacity(0.8))
                    }
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isDisabled ? Color.gray.opacity(0.5) : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered && !isDisabled ? accentColor.opacity(0.1) : .clear)
                .padding(.horizontal, 4)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Recording Button

/// A combined button that shows recording status and allows stopping
struct RecordingButton: View {
    let duration: String
    let isPaused: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Pulsing red dot with stop icon
                ZStack {
                    Circle()
                        .fill(.gray.opacity(0.2))
                        .frame(width: 24, height: 24)

                    Image(systemName: "stop.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.red.opacity(0.8))
                }

                Text(isPaused ? "Paused" : "Stop Recording")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Text(duration)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(isPaused ? .orange : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? .red.opacity(0.1) : .clear)
                .padding(.horizontal, 4)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Microphone Level Meter

/// A small live level meter shown while recording with the microphone enabled, so the
/// user can confirm audio is actually coming through instead of just hoping.
struct MicrophoneLevelRow: View {
    /// Peak amplitude, 0...1.
    let level: Float

    private var color: Color {
        if level > 0.85 { return .red }
        if level > 0.6 { return .yellow }
        return .green
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.gray.opacity(0.2))
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .animation(.linear(duration: 0.1), value: level)
    }
}

// MARK: - Content Selection Button

/// A split button that triggers the active content selection mode, with a dropdown chevron to switch modes.
/// The left portion triggers the action; the right chevron opens a dropdown to change the mode.
/// Styled consistently with other menu bar rows.
struct ContentSelectionButton: View {
    let viewModel: RecorderViewModel
    var onDismissPanel: (() -> Void)?
    @AppStorage(ContentSelectionMode.storageKey) private var mode: ContentSelectionMode = .pickContent
    @State private var isDropdownExpanded = false
    @State private var isMainHovered = false
    @State private var isChevronHovered = false

    /// Whether content has been selected via the currently active mode
    private var hasActiveSelection: Bool {
        switch mode {
        case .pickContent:
            viewModel.hasContentSelected && !viewModel.isAreaSelection
        case .selectArea:
            viewModel.isAreaSelection
        }
    }

    private var buttonLabel: String {
        hasActiveSelection ? "Change \(mode.label.split(separator: " ").last, default: "Content")..." : "\(mode.label)..."
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main button row
            HStack(spacing: 0) {
                // Left: action button
                Button {
                    triggerAction()
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(hasActiveSelection ? .blue.opacity(0.8) : .gray.opacity(0.2))
                                .frame(width: 24, height: 24)

                            Image(systemName: mode.icon)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(hasActiveSelection ? .white : .primary)
                        }

                        Text(buttonLabel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)

                        Spacer()
                    }
                    .padding(.leading, 12)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isMainHovered = hovering
                }

                // Right: chevron dropdown toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isDropdownExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isDropdownExpanded ? 90 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
                .onHover { hovering in
                    isChevronHovered = hovering
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill((isMainHovered || isChevronHovered) ? .gray.opacity(0.1) : .clear)
                    .padding(.horizontal, 4)
            )

            // Dropdown options
            if isDropdownExpanded {
                VStack(spacing: 0) {
                    DeviceRow(
                        name: ContentSelectionMode.pickContent.label,
                        icon: ContentSelectionMode.pickContent.icon,
                        isSelected: mode == .pickContent
                    ) {
                        mode = .pickContent
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isDropdownExpanded = false
                        }
                    }

                    DeviceRow(
                        name: ContentSelectionMode.selectArea.label,
                        icon: ContentSelectionMode.selectArea.icon,
                        isSelected: mode == .selectArea
                    ) {
                        mode = .selectArea
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isDropdownExpanded = false
                        }
                    }
                }
                .padding(.leading, 12)
                .background(.quaternary.opacity(0.3))
            }
        }
    }

    private func triggerAction() {
        switch mode {
        case .pickContent:
            viewModel.presentPicker()
        case .selectArea:
            onDismissPanel?()
            Task {
                await viewModel.presentAreaSelection()
            }
        }
    }
}

// MARK: - Permission Status Banner

/// A banner showing missing permissions with buttons to open System Settings
struct PermissionStatusBanner: View {
    let permissionService: PermissionService
    let showMicrophonePermission: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Permissions Required")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if permissionService.screenRecordingState != .granted {
                PermissionRow(
                    title: "Screen Recording",
                    isGranted: false
                ) {
                    permissionService.openScreenRecordingSettings()
                }
            }

            if showMicrophonePermission && permissionService.microphoneState != .granted {
                PermissionRow(
                    title: "Microphone",
                    isGranted: false
                ) {
                    permissionService.openMicrophoneSettings()
                }
            }
        }
        .padding(.bottom, 8)
    }
}

/// A single permission row with status and action button
struct PermissionRow: View {
    let title: String
    let isGranted: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isGranted ? .green : .red)
                    .font(.system(size: 12))

                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)

                Spacer()

                if !isGranted {
                    Text("Open Settings")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? .gray.opacity(0.1) : .clear)
                .padding(.horizontal, 4)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Preview

#Preview {
    MenuBarView(viewModel: RecorderViewModel())
}
