// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AVFoundation
import CoreMedia
import VideoToolbox

/// The sound levels of what the writer just wrote, 0…1 peaks, for the
/// pill's two meters.
struct ForkMeetingLevels: Equatable {
    var meeting: Float
    var microphone: Float

    static let silent = ForkMeetingLevels(meeting: 0, microphone: 0)
}

/// Writes a meeting's master: a fragmented MP4 with the picture and two mono
/// sound tracks, the meeting and the microphone, always in that order.
///
/// - **Compressed once, while it records**, at the preset's rate: HEVC when
///   the encoder really encodes at this size, H.264 otherwise. Each optional
///   compression key is tried with `canApply` first: a key the encoder
///   rejects raises an Objective-C exception Swift cannot catch (bran
///   `3350e66`).
/// - **Fragments of two seconds**: after a crash or a `kill -9`, everything
///   but the last fragment plays (measured in spike S1: under a second lost).
/// - **Every sound converted here to 48 kHz mono**, whatever its source
///   sends. The encoder takes the format of the first buffer for the whole
///   file, so a microphone that drops to 16 kHz mid-meeting (AirPods going
///   to call mode) would otherwise come out three times too high, without
///   an error (spike S1).
/// - **Continuous tracks**: a source that stops, restarts or is off leaves
///   silence, never a hole, so the final pass mixes tracks of equal length
///   and a transcript keeps its timing.
/// - **Pauses inside the file**, on the official recorder's clock: samples
///   taken during a pause are dropped and everything after moves back by
///   the pause's length.
/// - A still screen sends no frame: the last one is written again every
///   second, so the picture lasts as long as the sound, even after a crash.
///
/// Everything happens on `queue`, serial; the methods may be called from any
/// thread. The failure callback is called once at most.
final class ForkMeetingWriter: @unchecked Sendable {
    /// The audio tracks, in their order in the file. The final pass finds
    /// them by that order; the titles are only a help for a person reading
    /// the file (an MP4 keeps a track's title, not its identifier).
    enum Track: Int, CaseIterable {
        case meeting = 0
        case microphone = 1

        var title: String {
            switch self {
            case .meeting: return "Réunion"
            case .microphone: return "Micro"
            }
        }
    }

    static let sampleRate = Double(ForkMeetingQuality.Rates.audioSampleRate)
    static let fragmentSeconds: Double = 2
    /// No new frame for this long: the last one is written again.
    static let stillFrameInterval: Double = 1
    /// A source that sent nothing for this long is filled with silence, up
    /// to this far behind the clock. A source that keeps sending, even late,
    /// is never padded over: its own buffers close their holes.
    static let silenceDelay: Double = 2

    private static let preparationQueue = DispatchQueue(label: "fork.meetings.writer.prepare", qos: .userInitiated)

    let queue = DispatchQueue(label: "fork.meetings.writer", qos: .userInitiated)
    let url: URL
    let outputSize: ForkMeetingPixelSize
    let codec: AVVideoCodecType

    /// Writer queue. Called once, the first time an append fails.
    var onFailure: ((ForkMeetingFailure) -> Void)?

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInputs: [AVAssetWriterInput]
    private let pauseClock: RecorderPauseClock
    private let targetFormat: AVAudioFormat

    // Writer queue only.
    private var started = false
    private var finishing = false
    private var failed = false
    private var timelines = [ForkMeetingTrackTimeline](repeating: ForkMeetingTrackTimeline(), count: Track.allCases.count)
    private var converters: [AVAudioConverter?] = [nil, nil]
    /// Host seconds of each track's last real buffer, 0 for none yet.
    private var lastFed: [Double] = [0, 0]
    private var lastVideoSample: CMSampleBuffer?
    private var lastVideoTime: CMTime = .invalid
    private var placeholder: CMSampleBuffer?
    private var ticker: DispatchSourceTimer?
    private(set) var videoFrameCount = 0

    private let levelLock = NSLock()
    /// Under `levelLock`: each track's last peak and when, in host seconds.
    private var peaks: [(value: Float, at: Double)] = [(0, 0), (0, 0)]

    // MARK: - Making

    /// Builds the writer off the main thread (encoder discovery can wait on
    /// VideoToolbox), then answers on `completionQueue`.
    static func prepare(url: URL, outputSize: ForkMeetingPixelSize, quality: ForkMeetingQuality,
                        pauseClock: RecorderPauseClock, completionQueue: DispatchQueue,
                        completion: @escaping (ForkMeetingWriter?) -> Void) {
        let box = PauseClockBox(pauseClock)
        preparationQueue.async {
            let writer = ForkMeetingWriter(url: url, outputSize: outputSize, quality: quality, pauseClock: box.clock)
            completionQueue.async { completion(writer) }
        }
    }

    init?(url: URL, outputSize: ForkMeetingPixelSize, quality: ForkMeetingQuality, pauseClock: RecorderPauseClock) {
        guard outputSize.width >= 2, outputSize.height >= 2,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1,
                                         interleaved: false),
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        writer.movieFragmentInterval = CMTime(seconds: Self.fragmentSeconds, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        let width = outputSize.width, height = outputSize.height
        var chosen: (AVVideoCodecType, [String: Any])?
        for codec in [AVVideoCodecType.hevc, .h264] {
            if codec == .hevc, !RecorderWriter.hevcEncodes(width: width, height: height) { continue }
            if let settings = Self.videoSettings(writer: writer, codec: codec, width: width, height: height,
                                                 bitRate: quality.videoBitRate) {
                chosen = (codec, settings)
                break
            }
        }
        guard let (codec, settings) = chosen else { return nil }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { return nil }
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: ForkMeetingQuality.Rates.sourceAudio,
        ]
        guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else { return nil }
        var audioInputs: [AVAssetWriterInput] = []
        for track in Track.allCases {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            input.metadata = [Self.title(track.title)]
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            audioInputs.append(input)
        }

        self.url = url
        self.outputSize = outputSize
        self.codec = codec
        self.writer = writer
        self.videoInput = videoInput
        self.audioInputs = audioInputs
        self.pauseClock = pauseClock
        targetFormat = format
    }

    /// The official clock is not `Sendable`; it is only handed from the
    /// caller's thread to the preparation queue, which it is safe across
    /// (every member takes its own lock).
    private struct PauseClockBox: @unchecked Sendable {
        let clock: RecorderPauseClock
        init(_ clock: RecorderPauseClock) { self.clock = clock }
    }

    /// Only one title per track: an MP4 writes the common title and the
    /// QuickTime track name to the same atom, and both would double it.
    private static func title(_ text: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = text as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    /// The settings for `codec`, its optional keys kept only when `canApply`
    /// accepts them one by one; `nil` when even the bit rate is refused.
    private static func videoSettings(writer: AVAssetWriter, codec: AVVideoCodecType, width: Int, height: Int,
                                      bitRate: Int) -> [String: Any]? {
        func settings(_ compression: [String: Any]) -> [String: Any] {
            [AVVideoCodecKey: codec,
             AVVideoWidthKey: width,
             AVVideoHeightKey: height,
             AVVideoCompressionPropertiesKey: compression,
             AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
             ]]
        }
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitRate]
        guard writer.canApply(outputSettings: settings(compression), forMediaType: .video) else { return nil }
        let frameRate = ForkMeetingQuality.Rates.frameRate
        let optional: [(String, Any)] = [
            (AVVideoExpectedSourceFrameRateKey, frameRate),
            (AVVideoMaxKeyFrameIntervalKey, ForkMeetingQuality.keyframeInterval),
            (AVVideoMaxKeyFrameIntervalDurationKey, Double(ForkMeetingQuality.Rates.keyframeSeconds)),
            // No reordering: screen content gains little from B-frames, and a
            // file without them is quicker to scrub.
            (AVVideoAllowFrameReorderingKey, false),
            (AVVideoProfileLevelKey, codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel as String
                                                    : AVVideoProfileLevelH264HighAutoLevel),
        ]
        for (key, value) in optional {
            var trial = compression
            trial[key] = value
            if writer.canApply(outputSettings: settings(trial), forMediaType: .video) { compression = trial }
        }
        return settings(compression)
    }

    // MARK: - Writing

    /// Opens the file. Any thread, before the first sample.
    func start() -> Bool {
        queue.sync {
            guard writer.status == .unknown, writer.startWriting() else { return false }
            return true
        }
    }

    /// The recording's zero, in host seconds: the instant the stream is
    /// asked to start. Later sources (a stream rebuilt after a sleep) keep
    /// this origin.
    func beginSession(atHostTime time: Double) {
        queue.sync {
            guard !started, writer.status == .writing, pauseClock.begin(at: time) else { return }
            writer.startSession(atSourceTime: .zero)
            started = true
            startTicker()
        }
    }

    /// A screen frame, timed on the host clock.
    func appendVideo(_ sample: CMSampleBuffer) {
        queue.async { [self] in
            guard let time = fileTime(of: sample) else { return }
            // The first picture is held from the very start, so the file
            // does not open on black while the stream comes up.
            writeVideo(sample, at: videoFrameCount == 0 ? .zero : time)
        }
    }

    /// A buffer of sound for `track`, in any PCM format, timed on the host
    /// clock.
    func appendAudio(_ sample: CMSampleBuffer, to track: Track) {
        queue.async { [self] in
            guard started, !finishing, !failed, CMSampleBufferIsValid(sample),
                  let time = fileTime(of: sample) else { return }
            guard let samples = convert(sample, track: track), !samples.isEmpty else { return }
            let start = Int64((time.seconds * Self.sampleRate).rounded())
            guard let placement = timelines[track.rawValue].place(start: start, count: Int64(samples.count))
            else { return }
            if placement.silence > 0 {
                writeSilence(placement.silence, at: placement.start - placement.silence, track: track)
            }
            let kept = samples.dropFirst(Int(placement.skip))
            lastFed[track.rawValue] = Self.hostSeconds()
            writeSamples(Array(kept), at: placement.start, track: track)
            publish(peak: Self.peak(kept), track: track)
        }
    }

    /// The levels of the last tenth of a second written, 0 for a track that
    /// has said nothing for longer. Any thread.
    var levels: ForkMeetingLevels {
        let now = Self.hostSeconds()
        return levelLock.withLock {
            func level(_ track: Track) -> Float {
                let peak = peaks[track.rawValue]
                return now - peak.at < 0.3 ? min(1, peak.value) : 0
            }
            return ForkMeetingLevels(meeting: level(.meeting), microphone: level(.microphone))
        }
    }

    /// Closes the file, the picture lasting until `end` (host seconds), and
    /// answers on the writer queue. Called once every source has stopped and
    /// drained, so nothing can arrive after it.
    func finish(atHostTime end: Double, completion: @escaping (ForkMeetingWriterResult) -> Void) {
        queue.async { [self] in
            ticker?.cancel()
            ticker = nil
            finishing = true
            guard started, writer.status == .writing else {
                if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
                completion(.failed(failed ? .writerFailed : .captureFailed))
                return
            }
            guard !failed else {
                // What the fragments hold stays on the disk for the recovery:
                // cancelling would delete it.
                completion(.failed(failure(writer.error)))
                return
            }
            let seconds = pauseClock.elapsed(at: end)
            let endTime = CMTime(seconds: seconds, preferredTimescale: 600_000_000)
            if videoFrameCount == 0 { writePlaceholder() }
            if let lastVideoSample, endTime > lastVideoTime { writeVideo(lastVideoSample, at: endTime) }
            let endSample = Int64((seconds * Self.sampleRate).rounded())
            for track in Track.allCases {
                let silence = timelines[track.rawValue].pad(to: endSample)
                if silence > 0 { writeSilence(silence, at: endSample - silence, track: track) }
            }
            writer.endSession(atSourceTime: max(endTime, lastVideoTime.isNumeric ? lastVideoTime : .zero))
            lastVideoSample = nil
            placeholder = nil
            videoInput.markAsFinished()
            audioInputs.forEach { $0.markAsFinished() }
            writer.finishWriting { [self] in
                queue.async { [self] in
                    if writer.status == .completed {
                        completion(.finished(recordedSeconds: seconds))
                    } else {
                        completion(.failed(failure(writer.error)))
                    }
                }
            }
        }
    }

    /// Gives up a file nothing was written to, and removes it. Any thread;
    /// `completion` runs on the writer queue once the file is gone.
    func cancel(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            ticker?.cancel()
            ticker = nil
            finishing = true
            lastVideoSample = nil
            if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            completion?()
        }
    }

    // MARK: - Writer queue

    /// Where a sample falls in the file, pauses taken out; `nil` before the
    /// session or inside a pause.
    private func fileTime(of sample: CMSampleBuffer) -> CMTime? {
        guard started, !finishing, !failed else { return nil }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        guard presentation.isNumeric else { return nil }
        let duration = CMSampleBufferGetDuration(sample)
        var seconds = duration.isNumeric ? max(0, duration.seconds) : 0
        if seconds == 0, let description = CMSampleBufferGetFormatDescription(sample),
           CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
           let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
           stream.mSampleRate > 0 {
            seconds = Double(CMSampleBufferGetNumSamples(sample)) / stream.mSampleRate
        }
        guard let mapped = pauseClock.sampleTime(start: presentation.seconds, duration: seconds) else { return nil }
        return CMTime(seconds: mapped, preferredTimescale: 600_000_000)
    }

    private func writeVideo(_ sample: CMSampleBuffer, at time: CMTime) {
        guard started, !failed, time.isNumeric else { return }
        // Times only go forward: a frame stamped before the last one written
        // (a still frame repeated meanwhile) is dropped, never appended.
        if lastVideoTime.isNumeric, time <= lastVideoTime { return }
        guard videoInput.isReadyForMoreMediaData else { return }
        guard let retimed = RecorderSampleTiming.retimed(sample, to: time) else { return }
        guard videoInput.append(retimed) else { return fail() }
        videoFrameCount += 1
        lastVideoSample = sample
        lastVideoTime = time
    }

    /// Every half second: a still screen gets its last frame again, a stream
    /// that never sent one gets black, and a silent source gets silence.
    private func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    private func tick() {
        guard started, !finishing, !failed else { return }
        let host = Self.hostSeconds()
        let now = pauseClock.elapsed(at: host)
        if videoFrameCount == 0 {
            if now > 0.5 { writePlaceholder() }
        } else if let lastVideoSample, lastVideoTime.isNumeric,
                  now - lastVideoTime.seconds >= Self.stillFrameInterval + 0.5 {
            writeVideo(lastVideoSample, at: CMTime(seconds: now - 0.5, preferredTimescale: 600_000_000))
        }
        let behind = Int64(((now - Self.silenceDelay) * Self.sampleRate).rounded(.down))
        guard behind > 0 else { return }
        for track in Track.allCases where host - lastFed[track.rawValue] >= Self.silenceDelay {
            let silence = timelines[track.rawValue].pad(to: behind)
            if silence > 0 { writeSilence(silence, at: behind - silence, track: track) }
        }
    }

    /// A black frame at the start, for a stream that has shown nothing yet
    /// (a minimized window): the file still has a picture track to play.
    private func writePlaceholder() {
        guard videoFrameCount == 0 else { return }
        if placeholder == nil { placeholder = Self.blackFrame(outputSize) }
        guard let placeholder else { return }
        writeVideo(placeholder, at: .zero)
    }

    private func writeSilence(_ count: Int64, at start: Int64, track: Track) {
        var position = start
        var left = count
        // A long hole (a source off for the whole meeting is filled every
        // half second, but a rebuilt microphone may leave seconds) goes in
        // one-second buffers.
        while left > 0 {
            let chunk = Int(min(left, Int64(Self.sampleRate)))
            writeSamples([Float](repeating: 0, count: chunk), at: position, track: track)
            position += Int64(chunk)
            left -= Int64(chunk)
        }
    }

    private func writeSamples(_ samples: [Float], at start: Int64, track: Track) {
        guard !failed, !samples.isEmpty else { return }
        let input = audioInputs[track.rawValue]
        // A full input drops this buffer; the next one finds the hole and
        // fills it with silence.
        guard input.isReadyForMoreMediaData,
              let buffer = Self.sampleBuffer(samples, start: start, format: targetFormat) else { return }
        guard input.append(buffer) else { return fail() }
    }

    private func fail() {
        guard !failed else { return }
        failed = true
        onFailure?(failure(writer.error))
    }

    private func failure(_ error: Error?) -> ForkMeetingFailure {
        guard let error = error as NSError?, error.domain == AVFoundationErrorDomain else { return .writerFailed }
        return error.code == AVError.Code.diskFull.rawValue ? .diskFull : .writerFailed
    }

    // MARK: - Sound

    /// The buffer as 48 kHz mono Float32 samples. A source that changes its
    /// format (a device switch) gets a new converter; the same one is kept
    /// otherwise, so the resampler's state carries across buffers.
    private func convert(_ sample: CMSampleBuffer, track: Track) -> [Float]? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              stream.mFormatID == kAudioFormatLinearPCM, stream.mSampleRate > 0 else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let count = AVAudioFrameCount(exactly: frames),
              let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        source.frameLength = count
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                           into: source.mutableAudioBufferList) == noErr
        else { return nil }
        if format == targetFormat, let channel = source.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(source.frameLength)))
        }
        if converters[track.rawValue]?.inputFormat != format {
            let converter = AVAudioConverter(from: format, to: targetFormat)
            // Mixed down, not the first channel kept: a stereo call can put a
            // voice on one side only.
            converter?.downmix = true
            converters[track.rawValue] = converter
        }
        guard let converter = converters[track.rawValue] else { return nil }
        let capacity = AVAudioFrameCount(Double(count) * Self.sampleRate / format.sampleRate) + 64
        guard let target = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        let handedOver = Latch()
        var error: NSError?
        let status = converter.convert(to: target, error: &error) { _, inputStatus in
            guard handedOver.close() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil, let channel = target.floatChannelData?[0] else {
            converters[track.rawValue] = nil
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(target.frameLength)))
    }

    private func publish(peak: Float, track: Track) {
        let now = Self.hostSeconds()
        levelLock.withLock { peaks[track.rawValue] = (peak, now) }
    }

    private static func peak(_ samples: ArraySlice<Float>) -> Float {
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample)) }
        return peak
    }

    /// Mono Float32 samples as a buffer stamped at sample `start`.
    private static func sampleBuffer(_ samples: [Float], start: Int64, format: AVAudioFormat) -> CMSampleBuffer? {
        guard let count = AVAudioFrameCount(exactly: samples.count),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let channel = pcm.floatChannelData?[0] else { return nil }
        pcm.frameLength = count
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        let timescale = CMTimeScale(sampleRate)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: timescale),
                                        presentationTimeStamp: CMTime(value: start, timescale: timescale),
                                        decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format.formatDescription,
                                   sampleCount: samples.count, sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &buffer) == noErr,
              let buffer,
              CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0, bufferList: pcm.audioBufferList) == noErr
        else { return nil }
        return buffer
    }

    // MARK: - Picture

    /// A video-range black frame in the stream's pixel format.
    private static func blackFrame(_ size: ForkMeetingPixelSize) -> CMSampleBuffer? {
        var pixels: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attributes as CFDictionary, &pixels) == kCVReturnSuccess,
              let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        for (plane, value) in [(0, UInt8(16)), (1, UInt8(128))] {
            if let base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane) {
                memset(base, Int32(value), CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
                       * CVPixelBufferGetHeightOfPlane(pixels, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                           formatDescriptionOut: &description) == noErr,
              let description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                       formatDescription: description, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    static func hostSeconds() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    /// Single use: the first `close` returns true, the next ones false.
    private final class Latch: @unchecked Sendable {
        private var isOpen = true
        func close() -> Bool {
            defer { isOpen = false }
            return isOpen
        }
    }
}
