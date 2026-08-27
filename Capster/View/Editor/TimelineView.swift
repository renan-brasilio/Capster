//
//  TimelineView.swift
//  Capster
//

import CoreMedia
import SwiftUI

/// The horizontal filmstrip of the timeline: one `ClipStripView` per clip, laid out
/// left-to-right in timeline order with no gaps, so the playhead's pixel offset always
/// matches `elapsed seconds * pointsPerSecond` - the same coordinate space the composition
/// itself uses.
struct TimelineView: View {
    @Bindable var viewModel: EditorViewModel

    /// Points per second of timeline - trim handles and the playhead both convert
    /// screen-space drag deltas through this, so it's the single source of truth for the
    /// timeline's zoom level.
    private let pointsPerSecond: CGFloat = 60

    var body: some View {
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(viewModel.project.clips.enumerated()), id: \.element.id) { index, clip in
                        ClipStripView(
                            clip: clip,
                            pointsPerSecond: pointsPerSecond,
                            thumbnailCache: viewModel.thumbnailCache,
                            onTrimStartChanged: { viewModel.trim(clipID: clip.id, trimStart: $0) },
                            onTrimEndChanged: { viewModel.trim(clipID: clip.id, trimEnd: $0) },
                            onRemove: { viewModel.removeClip(id: clip.id) }
                        )
                        .draggable(clip.id.uuidString) {
                            Text(clip.sourceURL.lastPathComponent)
                                .padding(6)
                                .background(.thinMaterial, in: .rect(cornerRadius: 6))
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let idString = items.first, let id = UUID(uuidString: idString) else { return false }
                            viewModel.moveClip(id: id, to: index)
                            return true
                        }
                    }
                }

                playhead
            }
            .padding(.vertical, 8)
        }
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture().onEnded { value in
                viewModel.seek(to: CMTime(seconds: value.location.x / pointsPerSecond, preferredTimescale: 600))
            }
        )
        .frame(height: 96)
        .background(.black.opacity(0.05))
    }

    private var playhead: some View {
        Rectangle()
            .fill(.red)
            .frame(width: 2)
            .offset(x: CGFloat(viewModel.playheadTime.seconds) * pointsPerSecond)
            .allowsHitTesting(false)
    }
}
