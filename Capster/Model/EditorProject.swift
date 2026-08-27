//
//  EditorProject.swift
//  Capster
//

import CoreMedia
import Foundation

/// A single source clip placed on the editor's timeline, trimmed to an in/out range.
struct EditorClip: Identifiable, Equatable {
    var id: UUID
    var sourceURL: URL
    /// Full duration of `sourceURL`, probed once when the clip is added.
    var sourceDuration: CMTime
    var trimStart: CMTime
    var trimEnd: CMTime

    init(id: UUID = UUID(), sourceURL: URL, sourceDuration: CMTime, trimStart: CMTime? = nil, trimEnd: CMTime? = nil) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourceDuration = sourceDuration
        self.trimStart = trimStart ?? .zero
        self.trimEnd = trimEnd ?? sourceDuration
    }

    /// The portion of the source actually included on the timeline.
    var trimmedDuration: CMTime {
        trimEnd - trimStart
    }
}

/// The in-memory timeline being edited - a plain value type so it's cheap to snapshot for
/// undo/redo (see `EditorViewModel`) and trivial for SwiftUI to diff, unlike
/// `AVMutableComposition` which is neither. `VideoCompositionService` builds the actual
/// composition from this on demand, rather than this type wrapping one directly.
struct EditorProject: Equatable {
    var clips: [EditorClip]
    let originalRecordingURL: URL

    /// Total duration across every clip's trimmed range.
    var totalDuration: CMTime {
        clips.reduce(.zero) { $0 + $1.trimmedDuration }
    }

    /// Splits the clip at `time` (measured along the whole timeline, not clip-local) into
    /// two adjacent clips sharing the same source and combined trim range. No-ops if `time`
    /// doesn't fall strictly inside a clip's trimmed range (e.g. it's exactly on a boundary,
    /// or past the end of the timeline).
    mutating func split(at time: CMTime) {
        var elapsed = CMTime.zero
        for index in clips.indices {
            let clip = clips[index]
            let clipEnd = elapsed + clip.trimmedDuration
            if time > elapsed && time < clipEnd {
                let splitPoint = clip.trimStart + (time - elapsed)
                var first = clip
                first.trimEnd = splitPoint
                var second = clip
                second.id = UUID()
                second.trimStart = splitPoint
                clips.replaceSubrange(index...index, with: [first, second])
                return
            }
            elapsed = clipEnd
        }
    }

    /// Moves the clip with `id` so it sits at `destinationIndex` in the timeline order.
    mutating func moveClip(id: EditorClip.ID, to destinationIndex: Int) {
        guard let sourceIndex = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips.remove(at: sourceIndex)
        clips.insert(clip, at: min(max(destinationIndex, 0), clips.count))
    }

    mutating func removeClip(id: EditorClip.ID) {
        clips.removeAll { $0.id == id }
    }
}
