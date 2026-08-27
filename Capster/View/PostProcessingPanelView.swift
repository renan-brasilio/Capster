//
//  PostProcessingPanelView.swift
//  Capster
//

import SwiftUI

/// The SwiftUI content view hosted inside the post-processing status panel.
/// Shows a row per enabled stage (transcode, upload) with live progress, and the
/// Chorus link once the upload succeeds.
struct PostProcessingPanelView: View {
    let coordinator: PostProcessingCoordinator
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let prompt = coordinator.renamePrompt {
                RenameRow(prompt: prompt) { newName in
                    coordinator.submitRename(newName)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if coordinator.transcodeState != .notNeeded {
                    StepRow(title: "Transcode", state: coordinator.transcodeState)
                }
                if coordinator.gifExportState != .notNeeded {
                    StepRow(title: "Export GIF", state: coordinator.gifExportState)
                }
                if coordinator.uploadState != .notNeeded {
                    StepRow(title: "Upload to Chorus", state: coordinator.uploadState)
                }
            }

            if let callID = coordinator.chorusCallID {
                LabeledContent("Chorus Recording ID") {
                    HStack {
                        Text(callID)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(callID, forType: .string)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Close", action: onDismiss)
            }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: 560)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: coordinator.isFinished) {
            guard coordinator.isFinished, coordinator.didSucceed else { return }
            try? await Task.sleep(for: .seconds(4))
            if coordinator.isFinished, coordinator.didSucceed {
                onDismiss()
            }
        }
    }
}

/// Pauses the pipeline right after recording, before any processing, to let the user
/// rename the recording. The name entered here is applied to the file on disk, so the
/// (possibly transcoded) file and Chorus's displayed title all end up matching it.
private struct RenameRow: View {
    let prompt: PostProcessingCoordinator.RenamePrompt
    let onSubmit: (String?) -> Void

    @State private var name: String

    init(prompt: PostProcessingCoordinator.RenamePrompt, onSubmit: @escaping (String?) -> Void) {
        self.prompt = prompt
        self.onSubmit = onSubmit
        _name = State(initialValue: prompt.suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name This Recording")
                .font(.headline)

            TextField("Recording Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(name) }

            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Duration", value: prompt.formattedDuration)
                LabeledContent("Save Location") {
                    Text(prompt.destinationDirectory.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Skip") { onSubmit(nil) }
                Button("Continue") { onSubmit(name) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct StepRow: View {
    let title: String
    let state: PostProcessingCoordinator.StepState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                switch state {
                case .notNeeded, .queued:
                    Text("Queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .running(let progressText, let fraction):
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                case .succeeded:
                    Text("Done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .notNeeded, .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
