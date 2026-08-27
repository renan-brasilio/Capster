//
//  ThumbnailCache.swift
//  Capster
//

import AppKit
import AVFoundation
import CoreMedia
import Foundation

/// Generates and caches timeline thumbnail images so scrubbing/trimming doesn't re-decode
/// frames that have already been drawn. One `AVAssetImageGenerator` is kept per source URL
/// rather than per clip - trimming only changes a clip's in/out points on an
/// already-generated source, so reusing the generator (and its cached frames) is what
/// keeps trimming near-free.
@MainActor
final class ThumbnailCache {
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private let cache = NSCache<NSString, NSImage>()

    /// Returns a cached thumbnail for `sourceURL` at `time`, generating and caching it
    /// (on a coarse tolerance, since exact-frame accuracy isn't needed for a filmstrip) if
    /// it isn't already there. Returns `nil` if generation fails - e.g. `time` falls past
    /// the asset's actual duration - and the caller shows a placeholder instead.
    func thumbnail(for sourceURL: URL, at time: CMTime) async -> NSImage? {
        let key = cacheKey(sourceURL: sourceURL, time: time)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let generator = generator(for: sourceURL)
        guard let generated = try? await generator.image(at: time) else { return nil }
        let cgImage = generated.image
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        return image
    }

    /// Drops the generator (and its implicit decode state) for `sourceURL` - used when a
    /// clip is removed from the timeline so its resources aren't held onto indefinitely.
    func evict(sourceURL: URL) {
        generators[sourceURL] = nil
    }

    private func generator(for sourceURL: URL) -> AVAssetImageGenerator {
        if let existing = generators[sourceURL] {
            return existing
        }
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generators[sourceURL] = generator
        return generator
    }

    /// Rounds the timestamp to a tenth of a second so nearby scrub positions share one
    /// cache entry instead of each triggering a fresh generation.
    private func cacheKey(sourceURL: URL, time: CMTime) -> NSString {
        let roundedSeconds = (time.seconds * 10).rounded() / 10
        return "\(sourceURL.path)#\(roundedSeconds)" as NSString
    }
}
