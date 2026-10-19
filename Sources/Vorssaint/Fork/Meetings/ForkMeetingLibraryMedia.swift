// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AVFoundation
import Foundation

/// What the library reads of a meeting's media, and the copies it makes of
/// them: the editor's take and the exported M4A. The meeting's own files are
/// only ever read; every copy is written through a draft beside its
/// destination, which then replaces it, so a copy cut short never leaves a
/// half file under the final name.
///
/// Off the main thread, every one of them.
enum ForkMeetingLibraryMedia {
    enum Failure: Error, CustomStringConvertible {
        case noVideo
        case noAudio
        case cannotSetUp(String)
        case reading(String)
        case writing(String)
        case incomplete

        var description: String {
            switch self {
            case .noVideo: return "no video track"
            case .noAudio: return "no audio track"
            case let .cannotSetUp(what): return "cannot set up \(what)"
            case let .reading(why): return "reading: \(why)"
            case let .writing(why): return "writing: \(why)"
            case .incomplete: return "the copy is shorter than its source"
            }
        }
    }

    // MARK: - Probing

    /// The file's date and size as `FileManager` reads them now.
    static func stamp(_ url: URL) -> ForkMeetingProbeCache.Stamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ForkMeetingProbeCache.Stamp(modified: attributes?[.modificationDate] as? Date,
                                           size: (attributes?[.size] as? NSNumber)?.int64Value)
    }

    /// How long a video plays, how many audio tracks it has and whether the
    /// first is the final pass's mix: through a **fresh** asset, never one
    /// kept from before, which would answer what it read the first time.
    static func probe(_ url: URL) async -> ForkMeetingProbeCache.Probe {
        var probe = ForkMeetingProbeCache.Probe()
        probe.seconds = await ForkMeetingFinalizer.playableSeconds(at: url)
        guard probe.seconds != nil else { return probe }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return probe }
        let ordered = tracks.sorted { $0.trackID < $1.trackID }
        probe.audioTracks = ordered.count
        if ordered.count >= 3 {
            var enabled: [Bool] = []
            for track in ordered { enabled.append((try? await track.load(.isEnabled)) ?? false) }
            probe.hasMix = enabled.first == true && enabled.dropFirst().allSatisfy { !$0 }
        }
        return probe
    }

    // MARK: - The editor's copy

    /// The video and the audio tracks at `kept` (their index among the
    /// file's audio tracks, in track order), copied without encoding into a
    /// QuickTime file at `destination`. The tracks carry the official
    /// recorder's source identifiers, the meeting first, then the
    /// microphone (`RecorderAudioSource`), so the editor never has to guess
    /// them from their order.
    static func copyForEditor(from source: URL, keeping kept: [Int], to destination: URL) async throws {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let audio = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        let chosen = kept.filter { audio.indices.contains($0) }.map { audio[$0] }
        var tracks: [Passthrough.Track] = [
            Passthrough.Track(track: video, metadata: [], transform: try await video.load(.preferredTransform)),
        ]
        let sources: [RecorderAudioSource] = [.system, .microphone]
        for (index, track) in chosen.enumerated() {
            tracks.append(Passthrough.Track(track: track,
                                            metadata: sources.indices.contains(index) ? sources[index].trackMetadata : []))
        }
        try await Passthrough.copy(asset, tracks: tracks, to: destination, fileType: .mov)
    }

    // MARK: - The exported audio

    /// Writes the meeting's audio at `destination` as `route` says.
    static func exportAudio(_ route: ForkMeetingAudioExport.Route, folder: URL, to destination: URL) async throws {
        switch route {
        case let .copy(name):
            let source = folder.appendingPathComponent(name)
            let draft = draftURL(for: destination)
            try? FileManager.default.removeItem(at: draft)
            do {
                try FileManager.default.copyItem(at: source, to: draft)
                try ForkMeetingStore.replace(destination, with: draft)
            } catch {
                try? FileManager.default.removeItem(at: draft)
                throw Failure.writing(error.localizedDescription)
            }
        case let .extractMix(name):
            let asset = AVURLAsset(url: folder.appendingPathComponent(name))
            guard let mix = try await asset.loadTracks(withMediaType: .audio).min(by: { $0.trackID < $1.trackID }) else {
                throw Failure.noAudio
            }
            try await Passthrough.copy(asset, tracks: [Passthrough.Track(track: mix, metadata: [])],
                                       to: destination, fileType: .m4a)
        case let .mixDown(name):
            try await mixDown(folder.appendingPathComponent(name), to: destination)
        }
    }

    /// Every audio track of `source` mixed into one AAC file, as the final
    /// pass mixes its own: read as one mono stream, each source at the
    /// volume that keeps the sum from clipping, encoded once.
    private static func mixDown(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        guard !tracks.isEmpty else { throw Failure.noAudio }
        let duration = try await Passthrough.span(of: tracks)
        let rate = Double(ForkMeetingQuality.Rates.audioSampleRate)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let mix = AVMutableAudioMix()
        let volume = ForkMeetingFinalPass.mixVolume(sources: tracks.count)
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(volume, at: .zero)
            return parameters
        }
        output.audioMix = mix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.cannotSetUp("the mix's reader") }
        reader.add(output)
        let draft = draftURL(for: destination)
        try? FileManager.default.removeItem(at: draft)
        let writer = try AVAssetWriter(outputURL: draft, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: ForkMeetingQuality.Rates.mixAudio,
        ]
        // An unsupported setting raises an exception Swift cannot catch.
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw Failure.cannotSetUp("the mix's encoder")
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure.cannotSetUp("the mix's writer") }
        writer.add(input)
        try await Passthrough.run(reader: reader, writer: writer, pairs: [(output, input)], duration: duration,
                                  draft: draft, destination: destination)
    }

    /// Hidden, beside the destination: the same volume, so the replace that
    /// follows is a rename.
    static func draftURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).draft.\(destination.pathExtension)")
    }

    // MARK: - Passthrough

    /// Tracks copied sample by sample, never decoded, each fed from its own
    /// queue: a queue shared by several inputs can stall the writer, which
    /// waits on one track while the queue feeds another (spike S1).
    enum Passthrough {
        struct Track: @unchecked Sendable {
            let track: AVAssetTrack
            let metadata: [AVMetadataItem]
            var transform: CGAffineTransform = .identity
        }

        /// The length the copy must keep: that of the tracks it copies,
        /// which for the sound alone can end a little before the picture.
        static func span(of tracks: [AVAssetTrack]) async throws -> CMTime {
            var end = CMTime.zero
            for track in tracks {
                let range = try await track.load(.timeRange)
                if range.end > end { end = range.end }
            }
            return end
        }

        static func copy(_ asset: AVAsset, tracks: [Track], to destination: URL, fileType: AVFileType) async throws {
            let duration = try await span(of: tracks.map(\.track))
            let reader = try AVAssetReader(asset: asset)
            let draft = draftURL(for: destination)
            try? FileManager.default.removeItem(at: draft)
            let writer = try AVAssetWriter(outputURL: draft, fileType: fileType)
            var pairs: [Pair] = []
            for (index, item) in tracks.enumerated() {
                let output = AVAssetReaderTrackOutput(track: item.track, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw Failure.cannotSetUp("track \(index)'s reader") }
                reader.add(output)
                let input = AVAssetWriterInput(mediaType: item.track.mediaType, outputSettings: nil,
                                               sourceFormatHint: try await item.track.load(.formatDescriptions).first)
                input.expectsMediaDataInRealTime = false
                input.metadata = item.metadata
                input.transform = item.transform
                input.marksOutputTrackAsEnabled = true
                guard writer.canAdd(input) else { throw Failure.cannotSetUp("track \(index)'s writer") }
                writer.add(input)
                pairs.append(Pair(output: output, input: input, label: "\(index)"))
            }
            try await run(reader: reader, writer: writer, pairs: pairs.map { ($0.output, $0.input) }, duration: duration,
                          draft: draft, destination: destination)
        }

        /// Moves every pair, then checks the draft plays as long as its
        /// source before it takes the destination's name.
        static func run(reader: AVAssetReader, writer: AVAssetWriter,
                        pairs: [(AVAssetReaderOutput, AVAssetWriterInput)], duration: CMTime,
                        draft: URL, destination: URL) async throws {
            guard reader.startReading() else { throw Failure.reading(reader.error?.localizedDescription ?? "did not start") }
            guard writer.startWriting() else {
                reader.cancelReading()
                throw Failure.writing(writer.error?.localizedDescription ?? "did not start")
            }
            writer.startSession(atSourceTime: .zero)
            let moving = pairs.enumerated().map { Pair(output: $0.element.0, input: $0.element.1, label: "\($0.offset)") }
            await withTaskGroup(of: Void.self) { group in
                for pair in moving { group.addTask { await pump(pair) } }
            }
            guard reader.status == .completed else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: draft)
                throw Failure.reading(reader.error?.localizedDescription ?? "status \(reader.status.rawValue)")
            }
            writer.endSession(atSourceTime: duration)
            await writer.finishWriting()
            guard writer.status == .completed else {
                try? FileManager.default.removeItem(at: draft)
                throw Failure.writing(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
            }
            let seconds = await ForkMeetingFinalizer.playableSeconds(at: draft) ?? 0
            guard ForkMeetingFinalPass.isWhole(seconds: seconds, masterSeconds: duration.seconds) else {
                try? FileManager.default.removeItem(at: draft)
                throw Failure.incomplete
            }
            try ForkMeetingStore.replace(destination, with: draft)
        }

        private struct Pair: @unchecked Sendable {
            let output: AVAssetReaderOutput
            let input: AVAssetWriterInput
            let label: String
        }

        private final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false

            func claim() -> Bool {
                lock.withLock {
                    guard !done else { return false }
                    done = true
                    return true
                }
            }
        }

        private static func pump(_ pair: Pair) async {
            let queue = DispatchQueue(label: "fork.meetings.library.copy." + pair.label, qos: .utility)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = Once()
                pair.input.requestMediaDataWhenReady(on: queue) {
                    while pair.input.isReadyForMoreMediaData {
                        guard let sample = pair.output.copyNextSampleBuffer(), pair.input.append(sample) else {
                            if once.claim() {
                                pair.input.markAsFinished()
                                continuation.resume()
                            }
                            return
                        }
                    }
                }
            }
        }
    }
}
