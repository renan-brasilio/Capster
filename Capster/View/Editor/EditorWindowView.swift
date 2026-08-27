//
//  EditorWindowView.swift
//  Capster
//

import AppKit
import CoreMedia
import SwiftUI
import UniformTypeIdentifiers

/// Content of the editor's `WindowGroup` scene. Takes the just-recorded (or reopened)
/// video's URL, asynchronously loads it into an `EditorViewModel`, and hosts the
/// preview/transport/timeline/toolbar around it. After a successful export, the window
/// switches to a second "screen" showing post-processing progress inline - reusing
/// `PostProcessingPanelView` directly - rather than opening the separate floating panel
/// used for the quick post-process (non-edited) flow.
struct EditorWindowView: View {
    let recordingURL: URL
    let postProcessing: PostProcessingCoordinator

    private enum Screen: Equatable {
        case editing
        case processing(exportedURL: URL)
    }

    @State private var viewModel: EditorViewModel?
    @State private var screen: Screen = .editing
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportError: String?
    private let exportService = TimelineExportService()

    var body: some View {
        Group {
            switch screen {
            case .editing:
                if let viewModel {
                    editor(viewModel)
                } else {
                    ProgressView("Loading recording…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .processing(let exportedURL):
                processingScreen(exportedURL: exportedURL)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .navigationTitle(recordingURL.lastPathComponent)
        .task {
            viewModel = await EditorViewModel.make(originalRecordingURL: recordingURL)
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        ), presenting: exportError) { _ in
            Button("OK") { exportError = nil }
        } message: { error in
            Text(error)
        }
    }

    // MARK: - Editing screen

    @ViewBuilder
    private func editor(_ viewModel: EditorViewModel) -> some View {
        VStack(spacing: 0) {
            toolbar(viewModel)
            Divider()

            PlayerContainerView(player: viewModel.player)
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            transportControls(viewModel)

            Divider()
            TimelineView(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(isExporting)
        .overlay {
            if isExporting {
                exportOverlay
            }
        }
    }

    private func toolbar(_ viewModel: EditorViewModel) -> some View {
        HStack(spacing: 12) {
            Button {
                viewModel.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo)
            .keyboardShortcut("z", modifiers: [.command])

            Button {
                viewModel.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!viewModel.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Divider()

            Button("Split at Playhead") {
                viewModel.split()
            }

            AddClipButton(viewModel: viewModel)

            Divider()

            Button {
                viewModel.save()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!viewModel.hasUnsavedChanges)
            .keyboardShortcut("s", modifiers: [.command])

            Spacer()

            Button("Export…") {
                export(viewModel)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func transportControls(_ viewModel: EditorViewModel) -> some View {
        HStack(spacing: 12) {
            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])

            Text(RecorderViewModel.formatDuration(viewModel.playheadTime.seconds))
                .font(.system(.body, design: .monospaced))

            Text("/")
                .foregroundStyle(.secondary)

            Text(RecorderViewModel.formatDuration(viewModel.project.totalDuration.seconds))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            if viewModel.isRebuildingPreview {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var exportOverlay: some View {
        VStack(spacing: 12) {
            ProgressView(value: exportProgress)
                .frame(width: 240)
            Text("Exporting… \(Int(exportProgress * 100))%")
                .font(.caption)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func export(_ viewModel: EditorViewModel) {
        isExporting = true
        exportProgress = 0
        let project = viewModel.project

        Task {
            do {
                let url = try await exportService.export(project: project) { progress in
                    Task { @MainActor in exportProgress = progress }
                }
                isExporting = false
                postProcessing.start(
                    recordingURL: url,
                    formattedDuration: RecorderViewModel.formatDuration(project.totalDuration.seconds)
                )
                screen = .processing(exportedURL: url)
            } catch {
                isExporting = false
                exportError = error.localizedDescription
            }
        }
    }

    // MARK: - Processing screen

    private func processingScreen(exportedURL: URL) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    screen = .editing
                } label: {
                    Label("Back to Editing", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(8)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            ScrollView {
                VStack(spacing: 32) {
                    Spacer(minLength: 48)

                    VStack(spacing: 12) {
                        Image(systemName: postProcessing.hasAnySteps ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(postProcessing.hasAnySteps ? .blue : .green)
                        Text(postProcessing.hasAnySteps ? "Processing Your Export" : "Export Complete")
                            .font(.title.bold())
                        Text(exportedURL.lastPathComponent)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Group {
                        if postProcessing.hasAnySteps {
                            PostProcessingPanelView(coordinator: postProcessing) {
                                screen = .editing
                            }
                        } else {
                            revealInFinderCard(exportedURL: exportedURL)
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                    Spacer(minLength: 48)
                }
                .frame(maxWidth: .infinity, minHeight: 480)
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown instead of `PostProcessingPanelView` when the export finished but nothing in
    /// Settings enables transcode/GIF/upload - `PostProcessingPanelView` would otherwise
    /// render an empty step list, since `postProcessing.start(...)` was a no-op. The page
    /// header above already covers the checkmark/title/filename, so this is just the action.
    private func revealInFinderCard(exportedURL: URL) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(
                exportedURL.path(percentEncoded: false),
                inFileViewerRootedAtPath: exportedURL.deletingLastPathComponent().path(percentEncoded: false)
            )
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 560)
    }
}

/// The "Add Clip" toolbar button - split out so its `.fileImporter` presentation state
/// doesn't need to be threaded through the parent toolbar.
private struct AddClipButton: View {
    let viewModel: EditorViewModel
    @State private var isImporterPresented = false

    var body: some View {
        Button("Add Clip…") {
            isImporterPresented = true
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            guard case .success(let url) = result else { return }
            Task {
                await viewModel.addClip(from: url)
            }
        }
    }
}
