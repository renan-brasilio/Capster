//
//  AudioMixer.swift
//  Capster
//

import AVFoundation
import CoreMedia
import OSLog

/// Mixes system audio and microphone sample buffers into a single audio stream.
///
/// ScreenCaptureKit delivers system audio and microphone audio as two independent
/// `CMSampleBuffer` streams, each with its own native format - the microphone's format
/// depends on the connected device and can differ from the system audio's fixed 48kHz
/// stereo format. Writing them as two separate `AVAssetWriterInput` tracks meant most
/// players (QuickTime, Finder Quick Look) only played the first track back by default,
/// making the microphone sound "missing" whenever system audio was quiet.
///
/// Both sources are converted to a shared canonical format and scheduled onto their own
/// `AVAudioPlayerNode`; both feed an intermediate `captureMixer`, which in turn feeds
/// `mainMixerNode` (muted, so nothing is audible through hardware output). The tap sits on
/// `captureMixer`, upstream of that mute - a mixer node's `outputVolume` scales what its own
/// tap receives too, so tapping the muted node directly would capture silence.
final class AudioMixer: @unchecked Sendable {

    /// Called with each mixed sample buffer, ready to append to a single audio track.
    /// Invoked on whichever queue the mixer's tap fires on - not necessarily the main actor.
    var onMixedSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private let systemAudioPlayer = AVAudioPlayerNode()
    private let microphonePlayer = AVAudioPlayerNode()
    private let captureMixer = AVAudioMixerNode()

    private let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false
    )!

    /// Converters are lazily created per source since each source's native format
    /// (particularly the microphone's) isn't known until its first sample buffer arrives.
    /// Each is only ever touched from the one queue CaptureEngine delivers that source on.
    private var systemAudioConverter: AVAudioConverter?
    private var microphoneConverter: AVAudioConverter?

    private(set) var isRunning = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "AudioMixer")

    init() {
        engine.attach(systemAudioPlayer)
        engine.attach(microphonePlayer)
        engine.attach(captureMixer)
        engine.connect(systemAudioPlayer, to: captureMixer, format: canonicalFormat)
        engine.connect(microphonePlayer, to: captureMixer, format: canonicalFormat)
        engine.connect(captureMixer, to: engine.mainMixerNode, format: nil)

        // Muted so the mix is never audible through hardware output. The tap is installed
        // on `captureMixer`, upstream of this, so it still sees the full signal.
        engine.mainMixerNode.outputVolume = 0
    }

    /// Starts the mixing engine. Must be called before any `mix...` method.
    func start() throws {
        guard !isRunning else { return }

        systemAudioScheduleCount = 0
        microphoneScheduleCount = 0
        tapCallCount = 0

        captureMixer.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handleMixedBuffer(buffer)
        }

        try engine.start()
        systemAudioPlayer.play()
        microphonePlayer.play()
        isRunning = true
    }

    /// Stops the engine and releases per-recording state.
    func stop() {
        guard isRunning else { return }

        captureMixer.removeTap(onBus: 0)
        systemAudioPlayer.stop()
        microphonePlayer.stop()
        engine.stop()

        systemAudioConverter = nil
        microphoneConverter = nil
        isRunning = false
    }

    /// Schedules a system audio sample buffer for mixing.
    func mixSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        schedule(sampleBuffer, onto: systemAudioPlayer, converter: &systemAudioConverter, label: "system audio")
    }

    /// Schedules a microphone sample buffer for mixing.
    func mixMicrophone(_ sampleBuffer: CMSampleBuffer) {
        schedule(sampleBuffer, onto: microphonePlayer, converter: &microphoneConverter, label: "microphone")
    }

    // MARK: - Scheduling

    private var systemAudioScheduleCount = 0
    private var microphoneScheduleCount = 0
    private var tapCallCount = 0

    private func schedule(
        _ sampleBuffer: CMSampleBuffer,
        onto player: AVAudioPlayerNode,
        converter: inout AVAudioConverter?,
        label: String
    ) {
        guard isRunning else {
            logger.error("schedule(\(label, privacy: .public)) dropped - mixer not running")
            return
        }
        guard let sourceBuffer = Self.pcmBuffer(from: sampleBuffer, label: label, logger: logger) else {
            return
        }

        if converter == nil {
            converter = AVAudioConverter(from: sourceBuffer.format, to: canonicalFormat)
        }
        guard let converter else {
            logger.error("Could not create audio converter for \(label)")
            return
        }

        let ratio = canonicalFormat.sampleRate / sourceBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 16
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: outputCapacity) else {
            logger.error("schedule(\(label)) dropped - failed to allocate converted buffer, capacity=\(outputCapacity)")
            return
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let conversionError {
            logger.error("Failed to convert \(label) for mixing: \(conversionError.localizedDescription)")
            return
        }

        guard convertedBuffer.frameLength > 0 else {
            logger.error("schedule(\(label)) dropped - converter produced 0 frames, status=\(status.rawValue)")
            return
        }

        if label == "system audio" {
            systemAudioScheduleCount += 1
            if systemAudioScheduleCount % 20 == 1 {
                logger.info("system audio scheduled x\(self.systemAudioScheduleCount), frames=\(convertedBuffer.frameLength), playerPlaying=\(player.isPlaying)")
            }
        } else {
            microphoneScheduleCount += 1
            if microphoneScheduleCount % 20 == 1 {
                logger.info("microphone scheduled x\(self.microphoneScheduleCount), frames=\(convertedBuffer.frameLength), playerPlaying=\(player.isPlaying)")
            }
        }

        player.scheduleBuffer(convertedBuffer, completionCallbackType: .dataPlayedBack) { _ in }
    }

    private func handleMixedBuffer(_ buffer: AVAudioPCMBuffer) {
        // Must be in the same time domain ScreenCaptureKit stamps video/system-audio
        // sample buffers with (the host time clock), not an independent counter -
        // AssetWriter anchors all tracks to whichever sample arrives first, so a mixed
        // track on its own timeline corrupted the whole file's timing.
        let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())

        tapCallCount += 1
        if tapCallCount % 20 == 1 {
            logger.info("tap fired x\(self.tapCallCount), frameLength=\(buffer.frameLength)")
        }

        guard let sampleBuffer = Self.sampleBuffer(from: buffer, presentationTime: presentationTime) else {
            logger.error("tap callback dropped - sampleBuffer(from:) returned nil at call #\(self.tapCallCount)")
            return
        }
        onMixedSampleBuffer?(sampleBuffer)
    }

    // MARK: - CMSampleBuffer <-> AVAudioPCMBuffer conversion

    /// Wraps a `CMSampleBuffer`'s audio data in an `AVAudioPCMBuffer` without copying,
    /// keeping the sample buffer's underlying block buffer alive for as long as needed.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer, label: String, logger: Logger) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            logger.error("pcmBuffer(\(label, privacy: .public)) dropped - no format description")
            return nil
        }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            logger.error("pcmBuffer(\(label, privacy: .public)) dropped - no ASBD")
            return nil
        }
        guard let format = AVAudioFormat(streamDescription: asbd) else {
            logger.error("pcmBuffer(\(label, privacy: .public)) dropped - AVAudioFormat init failed for formatID=\(asbd.pointee.mFormatID), flags=\(asbd.pointee.mFormatFlags), channels=\(asbd.pointee.mChannelsPerFrame), bitsPerChannel=\(asbd.pointee.mBitsPerChannel), sampleRate=\(asbd.pointee.mSampleRate)")
            return nil
        }

        // Interleaved audio packs every channel into one buffer, so the list needs
        // exactly 1 entry regardless of channel count. Only non-interleaved (planar)
        // audio needs one buffer per channel. Allocating for `channelCount` unconditionally
        // made this fail for interleaved sources (e.g. many microphones report interleaved
        // stereo) with kCMSampleBufferError_ArrayTooSmall, since the function determines
        // the buffer count from the list size passed in, not just the byte size.
        let channelCount = Int(format.channelCount)
        let bufferCount = format.isInterleaved ? 1 : channelCount
        let bufferListPointer = AudioBufferList.allocate(maximumBuffers: bufferCount)

        var blockBuffer: CMBlockBuffer?
        var sizeNeeded = 0
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: bufferListPointer.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: bufferCount),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            logger.error("pcmBuffer(\(label, privacy: .public)) dropped - CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer status=\(status), sizeNeeded=\(sizeNeeded), allocatedSize=\(AudioBufferList.sizeInBytes(maximumBuffers: bufferCount)), channelCount=\(channelCount), interleaved=\(format.isInterleaved), sampleRate=\(format.sampleRate)")
            bufferListPointer.unsafeMutablePointer.deallocate()
            return nil
        }

        // Keep the block buffer (the actual sample bytes) alive until the AVAudioPCMBuffer
        // that references it is deallocated - AVAudioPCMBuffer takes ownership of freeing
        // the list pointer itself once passed to `bufferListNoCopy:`, so the deallocator
        // must only release our own reference, not touch `list`. Deallocating it ourselves
        // double-frees it (AVAudioPCMBuffer frees it too), aborting with a libmalloc
        // "pointer being freed was not allocated" crash - verified empirically since this
        // isn't documented behavior.
        let retainedBlockBuffer = blockBuffer
        let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: bufferListPointer.unsafeMutablePointer,
            deallocator: { _ in
                _ = retainedBlockBuffer
            }
        )

        guard let pcmBuffer else {
            logger.error("pcmBuffer(\(label, privacy: .public)) dropped - AVAudioPCMBuffer(bufferListNoCopy:) init failed, channelCount=\(channelCount), interleaved=\(format.isInterleaved)")
            bufferListPointer.unsafeMutablePointer.deallocate()
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        return pcmBuffer
    }

    /// Wraps an `AVAudioPCMBuffer`'s audio data in a `CMSampleBuffer` for `AVAssetWriter`.
    private static func sampleBuffer(from pcmBuffer: AVAudioPCMBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        let formatDescription = pcmBuffer.format.formatDescription

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(pcmBuffer.format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(pcmBuffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard createStatus == noErr, let sampleBuffer else { return nil }

        let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcmBuffer.audioBufferList
        )

        guard setStatus == noErr else { return nil }
        return sampleBuffer
    }
}
