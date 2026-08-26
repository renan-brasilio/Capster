//
//  AudioLevelMeter.swift
//  Capster
//

import CoreMedia
import AudioToolbox

/// Computes a normalized peak amplitude from a raw audio `CMSampleBuffer`, for driving
/// a live level meter in the UI.
enum AudioLevelMeter {

    /// Peak absolute amplitude across every channel, normalized to `0...1`, or `nil` if
    /// the buffer isn't decodable PCM.
    ///
    /// A level meter only cares about loudness, not which channel it came from, so this
    /// scans every buffer in the list the same way regardless of whether the format is
    /// interleaved or planar - unlike writing the samples, there's no need to allocate a
    /// buffer count that matches the layout exactly.
    static func peakLevel(from sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        let isFloat = asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channelCount = max(Int(asbd.pointee.mChannelsPerFrame), 1)
        let bufferCount = isNonInterleaved ? channelCount : 1

        let bufferListPointer = AudioBufferList.allocate(maximumBuffers: bufferCount)
        defer { bufferListPointer.unsafeMutablePointer.deallocate() }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPointer.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: bufferCount),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        var peak: Float = 0
        for buffer in bufferListPointer {
            guard let data = buffer.mData else { continue }

            if isFloat, asbd.pointee.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count { peak = max(peak, abs(samples[index])) }
            } else if !isFloat, asbd.pointee.mBitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count { peak = max(peak, abs(Float(samples[index])) / Float(Int16.max)) }
            }
        }

        return min(peak, 1.0)
    }
}
