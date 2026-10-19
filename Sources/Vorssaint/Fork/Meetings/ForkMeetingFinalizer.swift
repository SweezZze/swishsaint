// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AVFoundation
import Foundation
import os

/// Turns a closed master into the meeting's files, one meeting at a time,
/// apart from any session: the next meeting may record meanwhile.
///
/// ```
/// .recording.mp4 ─copy─► .finalizing.mp4 ─verified─► <name>.mp4 ─► master removed
///                                                        └─copy of the Mix─► .finalizing.m4a ─► <name>.m4a
/// ```
///
/// A master without picture (a meeting recorded with its sound only) takes
/// the same path to `<name>.m4a` through `.finalizing.m4a`: the mix and the
/// two sources, no separate M4A, since the final file is one.
///
/// - The copy keeps the picture and both sources untouched and adds the
///   mixed track every player plays (`ForkMeetingFinalPass`): about 15 s
///   an hour of meeting, measured in spike S1.
/// - The draft replaces the final file only once a **fresh** `AVURLAsset`
///   plays it whole (an asset caches what it read the first time), with its
///   size read by `FileManager`; the master goes only after that.
/// - No room for the copy: the master itself becomes the final file, its
///   tracks separate (`skipped-disk`). Any failure keeps the master and
///   removes nothing (`failed`); the next launch tries again.
/// - Never a fixed delay: every step waits for what it needs to be done,
///   and a copy that stops moving for two minutes is abandoned.
///
/// Every job ends with exactly one call of each completion given for its
/// folder, on the callback queue, and `meeting.json` updated: `complete`
/// with its `finalPass` on success, only `finalPass: failed` otherwise.
/// The end time is the recording's, written when it closed; nothing here
/// writes one.
final class ForkMeetingFinalizer: ObservableObject, @unchecked Sendable {
    static let shared = ForkMeetingFinalizer()

    /// The names the final file gives its audio tracks, in the person's
    /// language: QuickTime and VLC show them in their audio menu.
    struct TrackTitles: Equatable {
        var mix: String
        var meeting: String
        var microphone: String

        static let standard = TrackTitles(mix: "Mix", meeting: "Meeting", microphone: "Microphone")

        func title(_ role: ForkMeetingFinalPass.SourceRole) -> String? {
            switch role {
            case .meeting: return meeting
            case .microphone: return microphone
            case .extra: return nil
            }
        }
    }

    struct Outcome: Equatable {
        let folder: URL
        let finalPass: ForkMeetingSidecar.FinalPass
        /// The final video, or the final `.m4a` of a meeting without
        /// picture; `nil` on a failure, the master then stays as it was,
        /// readable with its separate tracks.
        let video: URL?
        /// The M4A, when one was asked for and made.
        let audio: URL?
        /// How long the meeting plays.
        let seconds: TimeInterval?
        let videoBytes: Int64?
        let audioBytes: Int64?
        /// What went wrong, for the log: the failure, or the M4A that was
        /// not made. Never shown as is.
        let note: String?

        var succeeded: Bool { finalPass != .failed }
    }

    struct Progress: Equatable {
        let folder: URL
        /// 0…1 for the whole job, M4A included.
        let fraction: Double
    }

    /// Callback queue (the main thread in the app): the job running and how
    /// far it is; `nil` when none runs.
    @Published private(set) var progress: Progress?

    /// A copy that appends nothing for this long is abandoned: silence, not
    /// a duration, since the copy's length follows the meeting's.
    static let stallTimeout: TimeInterval = 120

    private static let log = Logger(subsystem: "fork.meetings", category: "finalizer")

    private struct Job {
        let serial: Int
        let folder: URL
        let extractAudio: Bool
        let titles: TrackTitles
        var completions: [(Outcome) -> Void]
    }

    private enum PassError: Error, CustomStringConvertible {
        case noVideo
        case cannotSetUp(String)
        case reading(String)
        case writing(String)
        case stalled
        case incomplete(Double?, of: Double)

        var description: String {
            switch self {
            case .noVideo: return "the master has no picture"
            case let .cannotSetUp(what): return "cannot set up \(what)"
            case let .reading(why): return "reading failed: \(why)"
            case let .writing(why): return "writing failed: \(why)"
            case .stalled: return "nothing written for \(Int(ForkMeetingFinalizer.stallTimeout)) s"
            case let .incomplete(seconds, master):
                return "the copy plays \(seconds.map { "\(Int($0)) s" } ?? "nothing") of \(Int(master)) s"
            }
        }
    }

    private let store: ForkMeetingStore
    private let freeBytes: (URL) -> Int64?
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    /// Under `lock`: the first one runs.
    private var jobs: [Job] = []
    private var running = false
    private var lastSerial = 0
    /// Callback queue: the job whose progress may be published.
    private var publishing: Int?

    /// - Parameters:
    ///   - freeBytes: the free space of a folder's volume, read off the main
    ///     thread; `nil` when unknown.
    ///   - callbackQueue: where the completions and `progress` go; the main
    ///     queue in the app.
    init(store: ForkMeetingStore = .shared,
         freeBytes: @escaping (URL) -> Int64? = ForkMeetingStore.freeBytes(at:),
         callbackQueue: DispatchQueue = .main) {
        self.store = store
        self.freeBytes = freeBytes
        self.callbackQueue = callbackQueue
    }

    /// Whether a final pass runs or waits. Any thread.
    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !jobs.isEmpty
    }

    /// Whether this folder's final pass runs or waits. Any thread.
    func isQueued(_ folder: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return jobs.contains { Self.same($0.folder, folder) }
    }

    /// Queues the final pass of `folder`, whose master is closed. Any
    /// thread. A folder already queued is not done twice: `completion`
    /// joins that job, and is called once with its outcome.
    ///
    /// - Parameter extractAudio: also make the M4A (the setting
    ///   `fork.meetings.extractAudio`).
    func finalize(_ folder: URL, extractAudio: Bool, titles: TrackTitles = .standard,
                  completion: @escaping (Outcome) -> Void) {
        lock.lock()
        if let index = jobs.firstIndex(where: { Self.same($0.folder, folder) }) {
            jobs[index].completions.append(completion)
            lock.unlock()
            return
        }
        lastSerial += 1
        jobs.append(Job(serial: lastSerial, folder: folder, extractAudio: extractAudio, titles: titles,
                        completions: [completion]))
        let starts = !running
        running = true
        lock.unlock()
        ForkMeetingActivity.beginFinalizing()
        if starts { runNext() }
    }

    private func runNext() {
        lock.lock()
        guard let job = jobs.first else {
            running = false
            lock.unlock()
            return
        }
        lock.unlock()
        callbackQueue.async { [self] in
            publishing = job.serial
            progress = Progress(folder: job.folder, fraction: 0)
        }
        Task.detached(priority: .utility) { [self] in
            let outcome = await run(job)
            let finished = removeFirstJob()
            Self.log.notice("final pass of \(job.folder.lastPathComponent, privacy: .private): \(outcome.finalPass.rawValue, privacy: .public) \(outcome.note ?? "", privacy: .private)")
            callbackQueue.async { [self] in
                if publishing == job.serial {
                    publishing = nil
                    progress = nil
                }
                finished.completions.forEach { $0(outcome) }
            }
            ForkMeetingActivity.endFinalizing()
            runNext()
        }
    }

    /// The job that just ran, with every completion that joined it.
    private func removeFirstJob() -> Job {
        lock.lock()
        defer { lock.unlock() }
        return jobs.removeFirst()
    }

    private static func same(_ one: URL, _ other: URL) -> Bool {
        one.standardizedFileURL.path == other.standardizedFileURL.path
    }

    // MARK: - One job

    private struct Paths {
        let folder: URL
        let master: URL
        let final: URL
        let draft: URL
        let audio: URL
        let audioDraft: URL
        /// Recorded without picture: the final file is the `.m4a`.
        let soundOnly: Bool

        init(_ folder: URL, soundOnly: Bool = false) {
            let name = folder.lastPathComponent
            self.folder = folder
            self.soundOnly = soundOnly
            master = folder.appendingPathComponent(ForkMeetingFolder.masterName)
            final = folder.appendingPathComponent("\(name).\(ForkMeetingFolder.finalExtension(audioOnly: soundOnly))")
            draft = folder.appendingPathComponent(soundOnly ? ForkMeetingFolder.audioDraftName
                                                            : ForkMeetingFolder.videoDraftName)
            audio = folder.appendingPathComponent("\(name).\(ForkMeetingFolder.audioExtension)")
            audioDraft = folder.appendingPathComponent(ForkMeetingFolder.audioDraftName)
        }
    }

    private func run(_ job: Job) async -> Outcome {
        var paths = Paths(job.folder)
        let manager = FileManager.default
        // The final pass is short, but the Mac must not doze off in the
        // middle of it, nor the app be ended suddenly.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated],
                                                             reason: "Finishing a meeting recording")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        // Held by another copy of the app: its meeting, not ours to touch,
        // not even its `meeting.json`.
        guard store.claim(job.folder) else {
            return Outcome(folder: job.folder, finalPass: .failed, video: nil, audio: nil, seconds: nil,
                           videoBytes: nil, audioBytes: nil, note: "held by another copy of the app")
        }
        defer { store.release(job.folder) }
        // Left by a pass cut short: never anything but ours.
        try? manager.removeItem(at: paths.draft)
        try? manager.removeItem(at: paths.audioDraft)

        guard let masterSeconds = await Self.playableSeconds(at: paths.master), masterSeconds > 0 else {
            return failed(job, note: "the master is missing or does not open", seconds: nil)
        }
        // Told by `meeting.json`, as the library reads it; by the master's
        // own tracks when it cannot say (unreadable, or a capture this
        // version does not know).
        let target = (try? store.sidecar(in: job.folder).get())?.capture?.target
        let soundOnly: Bool
        if let target { soundOnly = !target.filmsPicture } else { soundOnly = await Self.hasNoPicture(paths.master) }
        if soundOnly { paths = Paths(job.folder, soundOnly: true) }
        let masterBytes = Self.fileSize(paths.master) ?? 0
        if ForkMeetingFinalPass.route(freeBytes: freeBytes(job.folder), masterBytes: masterBytes) == .promoteMaster {
            return await promote(job, paths: paths, masterSeconds: masterSeconds, note: nil)
        }

        let layout: ForkMeetingFinalPass.Layout
        let seconds: Double
        do {
            (layout, seconds) = try await copy(job, paths: paths, masterSeconds: masterSeconds)
        } catch {
            try? manager.removeItem(at: paths.draft)
            // The disk may have filled during the copy: the master is then
            // the best file there can be.
            if let free = freeBytes(job.folder),
               ForkMeetingFinalPass.route(freeBytes: free, masterBytes: masterBytes) == .promoteMaster {
                return await promote(job, paths: paths, masterSeconds: masterSeconds, note: "\(error)")
            }
            return failed(job, note: "\(error)", seconds: masterSeconds)
        }

        // The copy is verified and in place: only now the master goes.
        do {
            try manager.removeItem(at: paths.master)
        } catch {
            // Harmless: the next launch removes it, the final being whole.
            Self.log.error("master kept in \(job.folder.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
        }

        var audio: URL?
        var note: String?
        // Without picture the final file is the M4A already.
        if job.extractAudio, layout.hasMix, !paths.soundOnly {
            do {
                try await extractMix(from: paths.final, to: paths.audio, draft: paths.audioDraft) { [self] seconds in
                    publish(ForkMeetingFinalPass.progress(copy: 1, audio: seconds, extractsAudio: true), for: job)
                }
                audio = paths.audio
            } catch {
                try? manager.removeItem(at: paths.audioDraft)
                note = "no M4A: \(error)"
            }
        }
        publish(1, for: job)
        store.write(ForkMeetingSidecarPatch(state: .complete, finalPass: .done), in: job.folder)
        // Recent captures lists what was filmed, never a sound alone.
        if !paths.soundOnly { store.addToRecentCaptures(paths.final) }
        return Outcome(folder: job.folder, finalPass: .done, video: paths.final, audio: audio, seconds: seconds,
                       videoBytes: Self.fileSize(paths.final), audioBytes: audio.flatMap(Self.fileSize), note: note)
    }

    /// The master becomes the final file: a rename, no copy, its tracks as
    /// the writer left them. No M4A: there is no mixed track to copy, and
    /// no room to make one.
    ///
    /// `skipped-disk` is written **before** the rename: the app may end right
    /// after it, and the next launch then finds a final file without its
    /// master, which it can only take for a final pass that went well. Ended
    /// before the rename instead, the master is still there and the next
    /// launch runs the pass again, which writes its own outcome.
    private func promote(_ job: Job, paths: Paths, masterSeconds: Double, note: String?) async -> Outcome {
        store.write(ForkMeetingSidecarPatch(finalPass: .skippedDisk), in: job.folder)
        do {
            if ForkMeetingStore.isSameFile(paths.final, paths.master) {
                // The master already has the meeting's name (a pass that
                // failed, shown): only its hidden name goes.
                try FileManager.default.removeItem(at: paths.master)
            } else {
                try ForkMeetingStore.replace(paths.final, with: paths.master)
            }
        } catch {
            return failed(job, note: "the master could not become the final file: \(error.localizedDescription)",
                          seconds: masterSeconds)
        }
        let seconds = await Self.playableSeconds(at: paths.final) ?? masterSeconds
        publish(1, for: job)
        store.write(ForkMeetingSidecarPatch(state: .complete, finalPass: .skippedDisk), in: job.folder)
        if !paths.soundOnly { store.addToRecentCaptures(paths.final) }
        return Outcome(folder: job.folder, finalPass: .skippedDisk, video: paths.final, audio: nil, seconds: seconds,
                       videoBytes: Self.fileSize(paths.final), audioBytes: nil, note: note)
    }

    /// The master stays where it is; `state` stays `finalizing`, so the
    /// next launch tries again.
    private func failed(_ job: Job, note: String, seconds: Double?) -> Outcome {
        store.write(ForkMeetingSidecarPatch(finalPass: .failed), in: job.folder)
        return Outcome(folder: job.folder, finalPass: .failed, video: nil, audio: nil, seconds: seconds,
                       videoBytes: nil, audioBytes: nil, note: note)
    }

    // MARK: - The copy

    /// Writes the draft, verifies it with a fresh asset and puts it in
    /// place. Throws, leaving the master untouched, at the first problem.
    private func copy(_ job: Job, paths: Paths,
                      masterSeconds: Double) async throws -> (ForkMeetingFinalPass.Layout, Double) {
        let asset = AVURLAsset(url: paths.master, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        // Without picture, a picture track (never written) would not be
        // copied into an `.m4a` either.
        let video = paths.soundOnly ? nil : try await asset.loadTracks(withMediaType: .video).first
        guard video != nil || paths.soundOnly else { throw PassError.noVideo }
        // By order: an `.mp4` keeps no track identifier the writer could set.
        let sources = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        let layout = ForkMeetingFinalPass.layout(audioTracks: sources.count)
        let duration = try await asset.load(.duration)

        let reader = try AVAssetReader(asset: asset)
        var readers = [reader]
        let videoOutput = video.map { AVAssetReaderTrackOutput(track: $0, outputSettings: nil) }
        let copyOutputs = sources.map { AVAssetReaderTrackOutput(track: $0, outputSettings: nil) }
        for output in [videoOutput].compactMap({ $0 }) + copyOutputs {
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw PassError.cannotSetUp("a copied track") }
            reader.add(output)
        }

        let rate = layout.hasMix ? await Self.sampleRate(of: sources[layout.mixed[0]]) : 48_000
        var mixOutput: AVAssetReaderAudioMixOutput?
        if layout.hasMix {
            let mixed = layout.mixed.map { sources[$0] }
            let output = AVAssetReaderAudioMixOutput(audioTracks: mixed, audioSettings: Self.mixReadSettings(rate))
            let mix = AVMutableAudioMix()
            let volume = ForkMeetingFinalPass.mixVolume(sources: mixed.count)
            mix.inputParameters = mixed.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(volume, at: .zero)
                return parameters
            }
            output.audioMix = mix
            output.alwaysCopiesSampleData = false
            // One reader takes the copies and the mix together (S1); a
            // second one is the fallback.
            if reader.canAdd(output) {
                reader.add(output)
            } else {
                let second = try AVAssetReader(asset: asset)
                guard second.canAdd(output) else { throw PassError.cannotSetUp("the mix") }
                second.add(output)
                readers.append(second)
            }
            mixOutput = output
        }

        let writer = try AVAssetWriter(outputURL: paths.draft, fileType: paths.soundOnly ? .m4a : .mp4)
        var inputs: [AVAssetWriterInput] = []
        var videoInput: AVAssetWriterInput?
        if let video {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                           sourceFormatHint: try await video.load(.formatDescriptions).first)
            input.transform = try await video.load(.preferredTransform)
            inputs.append(input)
            videoInput = input
        }
        var mixInput: AVAssetWriterInput?
        if layout.hasMix {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: ForkMeetingQuality.Rates.mixAudio,
            ]
            // An unsupported setting raises an exception Swift cannot catch:
            // asked first.
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
                throw PassError.cannotSetUp("the mixed track's encoder")
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.metadata = Self.titled(job.titles.mix)
            input.marksOutputTrackAsEnabled = true
            inputs.append(input)
            mixInput = input
        }
        var copyInputs: [AVAssetWriterInput] = []
        for (index, track) in sources.enumerated() {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                           sourceFormatHint: try await track.load(.formatDescriptions).first)
            input.metadata = job.titles.title(layout.copied[index]).map(Self.titled) ?? []
            // Only the mix plays: two sources and a mix on at once would
            // play the meeting three times over.
            input.marksOutputTrackAsEnabled = false
            inputs.append(input)
            copyInputs.append(input)
        }
        for input in inputs {
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw PassError.cannotSetUp("a track of the final file") }
            writer.add(input)
        }
        if let mixInput {
            // Players offer them as alternatives, the mix by default.
            let group = AVAssetWriterInputGroup(inputs: [mixInput] + copyInputs, defaultInput: mixInput)
            if writer.canAdd(group) { writer.add(group) }
        }

        for reader in readers where !reader.startReading() {
            throw PassError.reading(reader.error?.localizedDescription ?? "did not start")
        }
        guard writer.startWriting() else {
            readers.forEach { $0.cancelReading() }
            throw PassError.writing(writer.error?.localizedDescription ?? "did not start")
        }
        writer.startSession(atSourceTime: .zero)

        let extractsAudio = job.extractAudio && layout.hasMix && !paths.soundOnly
        // The progress follows the picture, or the first track copied
        // without one.
        let progress: @Sendable (Double) -> Void = { [self] seconds in
            publish(ForkMeetingFinalPass.progress(copy: seconds / masterSeconds, extractsAudio: extractsAudio),
                    for: job)
        }
        var pairs: [Pair] = []
        if let videoOutput, let videoInput {
            pairs.append(Pair(output: videoOutput, input: videoInput, label: "video", onAppend: progress))
        }
        if let mixOutput, let mixInput {
            pairs.append(Pair(output: mixOutput, input: mixInput, label: "mix", onAppend: pairs.isEmpty ? progress : nil))
        }
        for (index, output) in copyOutputs.enumerated() {
            pairs.append(Pair(output: output, input: copyInputs[index], label: "source\(index)",
                              onAppend: pairs.isEmpty ? progress : nil))
        }
        let stalled = await Self.pump(pairs, abandon: Abandon(readers: readers, writer: writer))
        guard !stalled else { throw PassError.stalled }
        for reader in readers where reader.status != .completed {
            writer.cancelWriting()
            throw PassError.reading(reader.error?.localizedDescription ?? "status \(reader.status.rawValue)")
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw PassError.writing(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }

        let seconds = await Self.playableSeconds(at: paths.draft)
        guard ForkMeetingFinalPass.isWhole(seconds: seconds, masterSeconds: masterSeconds),
              (Self.fileSize(paths.draft) ?? 0) > 0, let seconds else {
            throw PassError.incomplete(seconds, of: masterSeconds)
        }
        try ForkMeetingStore.replace(paths.final, with: paths.draft)
        return (layout, seconds)
    }

    /// The M4A of a final file whose own was never made (the app quit right
    /// after the copy), named after the video and beside it. Only from a
    /// file the final pass wrote: its mix enabled, its sources not. A
    /// promoted master has no mix, and its meeting track alone would be a
    /// false M4A. `nil` when nothing was made. Off the main thread.
    @discardableResult
    func remakeAudio(from video: URL) async -> URL? {
        let folder = video.deletingLastPathComponent()
        let audio = video.deletingPathExtension().appendingPathExtension(ForkMeetingFolder.audioExtension)
        let draft = folder.appendingPathComponent(ForkMeetingFolder.audioDraftName)
        guard !FileManager.default.fileExists(atPath: audio.path), await Self.hasMix(video) else { return nil }
        do {
            try await extractMix(from: video, to: audio, draft: draft, progress: nil)
            return audio
        } catch {
            try? FileManager.default.removeItem(at: draft)
            Self.log.error("no M4A for \(folder.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// A master with sound and no picture: a meeting recorded without it.
    /// `false` when it cannot tell, and the pass then fails as it would.
    static func hasNoPicture(_ master: URL) async -> Bool {
        let asset = AVURLAsset(url: master)
        guard let video = try? await asset.loadTracks(withMediaType: .video),
              let audio = try? await asset.loadTracks(withMediaType: .audio) else { return false }
        return video.isEmpty && !audio.isEmpty
    }

    /// The final pass's layout: the first audio track, the mix, plays; the
    /// sources after it do not.
    private static func hasMix(_ video: URL) async -> Bool {
        let asset = AVURLAsset(url: video)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio).sorted(by: { $0.trackID < $1.trackID }),
              tracks.count >= 2 else { return false }
        var enabled: [Bool] = []
        for track in tracks {
            guard let isEnabled = try? await track.load(.isEnabled) else { return false }
            enabled.append(isEnabled)
        }
        return enabled.first == true && enabled.dropFirst().allSatisfy { !$0 }
    }

    /// The M4A: the final file's mix, copied as it is (about a second an
    /// hour), never encoded again. `progress` gets the share copied, 0…1.
    private func extractMix(from final: URL, to audio: URL, draft: URL,
                            progress: (@Sendable (Double) -> Void)?) async throws {
        let asset = AVURLAsset(url: final)
        // The mix is the first audio track the copy wrote.
        guard let mix = try await asset.loadTracks(withMediaType: .audio).min(by: { $0.trackID < $1.trackID }) else {
            throw PassError.cannotSetUp("the M4A: no mixed track")
        }
        let mixSeconds = try await mix.load(.timeRange).duration.seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: mix, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PassError.cannotSetUp("the M4A's reader") }
        reader.add(output)
        try? FileManager.default.removeItem(at: draft)
        let writer = try AVAssetWriter(outputURL: draft, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                       sourceFormatHint: try await mix.load(.formatDescriptions).first)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw PassError.cannotSetUp("the M4A's writer") }
        writer.add(input)
        guard reader.startReading() else { throw PassError.reading(reader.error?.localizedDescription ?? "") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw PassError.writing(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)
        let stalled = await Self.pump([Pair(output: output, input: input, label: "m4a", onAppend: { seconds in
            progress?(seconds / max(mixSeconds, 1))
        })], abandon: Abandon(readers: [reader], writer: writer))
        guard !stalled else { throw PassError.stalled }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw PassError.reading(reader.error?.localizedDescription ?? "status \(reader.status.rawValue)")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw PassError.writing(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        let seconds = await Self.playableSeconds(at: draft)
        guard ForkMeetingFinalPass.isWhole(seconds: seconds, masterSeconds: mixSeconds),
              (Self.fileSize(draft) ?? 0) > 0 else {
            throw PassError.incomplete(seconds, of: mixSeconds)
        }
        try ForkMeetingStore.replace(audio, with: draft)
    }

    // MARK: - Moving samples

    /// One reader output feeding one writer input.
    private struct Pair: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let label: String
        /// Each appended sample's time, in seconds: the picture's gives the
        /// progress.
        var onAppend: (@Sendable (Double) -> Void)?
    }

    /// Cancels a pass whose samples stopped moving. Called once, from the
    /// stall watch, when no pump touches the reader or the writer any more.
    private struct Abandon: @unchecked Sendable {
        let readers: [AVAssetReader]
        let writer: AVAssetWriter

        func callAsFunction() {
            readers.forEach { $0.cancelReading() }
            writer.cancelWriting()
        }
    }

    /// What every pump of one pass shares: when a sample last moved, and
    /// how to let each pump go when nothing moves any more.
    private final class Flow: @unchecked Sendable {
        private let lock = NSLock()
        private var lastMove = DispatchTime.now().uptimeNanoseconds
        private var releases: [() -> Void] = []
        private var stalled = false

        var isStalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stalled
        }

        func moved() {
            lock.lock()
            lastMove = DispatchTime.now().uptimeNanoseconds
            lock.unlock()
        }

        func onStall(_ release: @escaping () -> Void) {
            lock.lock()
            releases.append(release)
            lock.unlock()
        }

        /// Silent for `limit`: releases every pump, once.
        func stallIfSilent(for limit: TimeInterval) -> Bool {
            lock.lock()
            let silent = Double(DispatchTime.now().uptimeNanoseconds - lastMove) / 1e9
            guard !stalled, silent >= limit else {
                lock.unlock()
                return false
            }
            stalled = true
            let pending = releases
            lock.unlock()
            pending.forEach { $0() }
            return true
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        /// `true` the first time only.
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return false }
            done = true
            return true
        }
    }

    /// Moves every pair, each on its own queue: a shared one can stall the
    /// writer, which waits for one track while the queue feeds another
    /// (S1). Returns once every input is finished, `true` when the pass was
    /// abandoned for silence; `abandon` then cancels the reading and the
    /// writing.
    private static func pump(_ pairs: [Pair], abandon: Abandon) async -> Bool {
        let flow = Flow()
        let watch = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watch.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
        watch.setEventHandler {
            if flow.stallIfSilent(for: stallTimeout) { abandon() }
        }
        watch.resume()
        await withTaskGroup(of: Void.self) { group in
            for pair in pairs {
                group.addTask { await pump(pair, flow: flow) }
            }
        }
        watch.cancel()
        return flow.isStalled
    }

    private static func pump(_ pair: Pair, flow: Flow) async {
        let queue = DispatchQueue(label: "fork.meetings.finalize." + pair.label, qos: .utility)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            // Abandoned: nothing calls back any more, so the continuation
            // is resumed from here; the input is left to `cancelWriting`.
            flow.onStall {
                if once.claim() { continuation.resume() }
            }
            // AVFoundation calls this block on `queue` only.
            pair.input.requestMediaDataWhenReady(on: queue) {
                while pair.input.isReadyForMoreMediaData {
                    guard !flow.isStalled, let sample = pair.output.copyNextSampleBuffer(),
                          pair.input.append(sample) else {
                        if once.claim() {
                            pair.input.markAsFinished()
                            continuation.resume()
                        }
                        return
                    }
                    flow.moved()
                    if let onAppend = pair.onAppend {
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        if time.isNumeric { onAppend(time.seconds) }
                    }
                }
            }
        }
    }

    // MARK: - Progress

    private final class Gate: @unchecked Sendable {
        let lock = NSLock()
        var serial = 0
        var last: Double?
    }

    private let gate = Gate()

    /// Any thread: a whole percent more, or the end.
    private func publish(_ fraction: Double, for job: Job) {
        gate.lock.lock()
        if gate.serial != job.serial {
            gate.serial = job.serial
            gate.last = nil
        }
        let worth = ForkMeetingFinalPass.shouldPublish(fraction, last: gate.last)
        if worth { gate.last = fraction }
        gate.lock.unlock()
        guard worth else { return }
        callbackQueue.async { [self] in
            // A report that arrives after its job ended must not bring the
            // gauge back over the next meeting's.
            guard publishing == job.serial else { return }
            progress = Progress(folder: job.folder, fraction: min(max(fraction, 0), 1))
        }
    }

    // MARK: - Reading files

    /// How long a file plays as a **fresh** asset sees it, or `nil` when it
    /// does not open or play. Never an asset kept from before: it would
    /// answer what it read the first time, even after the file changed.
    static func playableSeconds(at url: URL) async -> Double? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let loaded = try? await asset.load(.duration, .isPlayable), loaded.1, loaded.0.isNumeric else {
            return nil
        }
        let seconds = loaded.0.seconds
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    /// The size `FileManager` reads now, not a cached resource value.
    static func fileSize(_ url: URL) -> Int64? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private static func sampleRate(of track: AVAssetTrack) async -> Double {
        guard let format = try? await track.load(.formatDescriptions).first,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mSampleRate > 0 else { return Double(ForkMeetingQuality.Rates.audioSampleRate) }
        return description.mSampleRate
    }

    private static func mixReadSettings(_ rate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// One title per track: in an `.mp4` the common title and the
    /// QuickTime track name land in the same box, so both would show it
    /// twice (S1).
    private static func titled(_ title: String) -> [AVMetadataItem] {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        return [item]
    }
}
