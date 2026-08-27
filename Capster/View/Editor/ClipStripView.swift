//
//  ClipStripView.swift
//  Capster
//

import AppKit
import CoreMedia
import SwiftUI

/// A single clip's cell in the timeline filmstrip: tiled thumbnails across its trimmed
/// width, with draggable in/out trim handles at each edge.
struct ClipStripView: View {
    let clip: EditorClip
    let pointsPerSecond: CGFloat
    let thumbnailCache: ThumbnailCache
    let onTrimStartChanged: (CMTime) -> Void
    let onTrimEndChanged: (CMTime) -> Void
    let onRemove: () -> Void

    @State private var thumbnails: [NSImage] = []
    @State private var draftTrimStart: CMTime?
    @State private var draftTrimEnd: CMTime?

    private static let thumbnailWidth: CGFloat = 80
    private static let minimumTrimGap = CMTime(seconds: 0.1, preferredTimescale: 600)

    private var trimStart: CMTime { draftTrimStart ?? clip.trimStart }
    private var trimEnd: CMTime { draftTrimEnd ?? clip.trimEnd }
    private var width: CGFloat {
        max(CGFloat((trimEnd - trimStart).seconds) * pointsPerSecond, 24)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(thumbnails.indices, id: \.self) { index in
                Image(nsImage: thumbnails[index])
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.thumbnailWidth)
                    .clipped()
            }
        }
        .frame(width: width, height: 80)
        .background(.gray.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .leading) { trimHandle(isLeading: true) }
        .overlay(alignment: .trailing) { trimHandle(isLeading: false) }
        .contextMenu {
            Button("Remove Clip", role: .destructive, action: onRemove)
        }
        .task(id: clip.id) {
            await loadThumbnails()
        }
    }

    private func trimHandle(isLeading: Bool) -> some View {
        Rectangle()
            .fill(.white.opacity(0.001))
            .frame(width: 10)
            .overlay(Rectangle().fill(.white).frame(width: 3))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let deltaSeconds = Double(value.translation.width) / Double(pointsPerSecond)
                        let delta = CMTime(seconds: deltaSeconds, preferredTimescale: 600)
                        if isLeading {
                            let proposed = clip.trimStart + delta
                            draftTrimStart = max(.zero, min(proposed, clip.trimEnd - Self.minimumTrimGap))
                        } else {
                            let proposed = clip.trimEnd + delta
                            draftTrimEnd = max(clip.trimStart + Self.minimumTrimGap, min(proposed, clip.sourceDuration))
                        }
                    }
                    .onEnded { _ in
                        if let draftTrimStart {
                            onTrimStartChanged(draftTrimStart)
                        }
                        if let draftTrimEnd {
                            onTrimEndChanged(draftTrimEnd)
                        }
                        draftTrimStart = nil
                        draftTrimEnd = nil
                    }
            )
    }

    private func loadThumbnails() async {
        let count = max(Int(width / Self.thumbnailWidth), 1)
        let duration = trimEnd - trimStart
        var images: [NSImage] = []
        for index in 0..<count {
            let fraction = count == 1 ? 0 : Double(index) / Double(count - 1)
            let time = trimStart + CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
            if let image = await thumbnailCache.thumbnail(for: clip.sourceURL, at: time) {
                images.append(image)
            }
        }
        thumbnails = images
    }
}
