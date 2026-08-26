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

            if let link = coordinator.chorusLink {
                LabeledContent("Chorus Link") {
                    HStack {
                        Link(link.absoluteString, destination: link)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Close", action: onDismiss)
            }
        }
        .padding(16)
        .frame(width: 360)
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
