//
//  VideoCompositionService.swift
//  Capster
//

import AVFoundation
import CoreMedia
import Foundation

enum VideoCompositionError: LocalizedError {
    case emptyProject
    case noVideoTrack(URL)
    case insertionFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .emptyProject:
            return "The timeline has no clips to export."
        case .noVideoTrack(let url):
            return "\(url.lastPathComponent) doesn't contain a video track."
        case .insertionFailed(let url, let error):
            return "Couldn't add \(url.lastPathComponent) to the timeline: \(error.localizedDescription)"
        }
    }
}

/// Builds the `AVMutableComposition`/`AVMutableVideoComposition` pair the player and
/// exporter both render from an `EditorProject`. Kept as a stateless service - rather than
/// `EditorProject` wrapping a composition directly - so the expensive, async asset-loading
/// work only runs when the player or exporter actually needs a fresh composition, not on
/// every timeline mutation.
enum VideoCompositionService {

    struct Result {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
    }

    /// Probes `url` for its duration, producing a full-length, untrimmed `EditorClip`
    /// ready to append to the timeline.
    static func makeClip(for url: URL) async throws -> EditorClip {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return EditorClip(sourceURL: url, sourceDuration: duration)
    }

    /// Builds a composition spanning every clip's trimmed range back-to-back, and a
    /// matching video composition that normalizes each source's orientation into one
    /// consistent render size - screen recordings and imported clips can differ in both
    /// dimensions and `preferredTransform`, so each clip gets its own layer instruction
    /// over its own slice of the shared composition track rather than one transform for
    /// the whole timeline.
    static func makeComposition(from project: EditorProject) async throws -> Result {
        guard !project.clips.isEmpty else { throw VideoCompositionError.emptyProject }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoCompositionError.emptyProject
        }

        var renderSize: CGSize?
        var maxFrameRate: Float = 30
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero

        for clip in project.clips {
            let asset = AVURLAsset(url: clip.sourceURL)
            guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoCompositionError.noVideoTrack(clip.sourceURL)
            }

            let timeRange = CMTimeRange(start: clip.trimStart, end: clip.trimEnd)

            do {
                try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: cursor)
            } catch {
                throw VideoCompositionError.insertionFailed(clip.sourceURL, error)
            }

            // Best-effort - an imported clip without an audio track shouldn't block the
            // rest of the timeline from composing.
            if let sourceAudioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
                try? compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: cursor)
            }

            let transform = try await sourceVideoTrack.load(.preferredTransform)
            let naturalSize = try await sourceVideoTrack.load(.naturalSize)
            let frameRate = try await sourceVideoTrack.load(.nominalFrameRate)
            maxFrameRate = max(maxFrameRate, frameRate)

            if renderSize == nil {
                let transformedSize = naturalSize.applying(transform)
                renderSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
            }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: clip.trimmedDuration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
            layerInstruction.setTransform(transform, at: cursor)
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)

            cursor = cursor + clip.trimmedDuration
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize ?? CGSize(width: 1920, height: 1080)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(maxFrameRate.rounded()))
        videoComposition.instructions = instructions

        return Result(composition: composition, videoComposition: videoComposition)
    }
}
