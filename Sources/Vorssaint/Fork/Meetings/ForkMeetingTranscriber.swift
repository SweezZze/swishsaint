// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AVFoundation
import Combine
import Foundation
import NaturalLanguage
import os

/// Transcribes a meeting on this Mac with Parakeet: its "Meeting" track
/// (the participants), then its "Microphone" track (the person), read from
/// the final file at 16 kHz, merged by time into `<name>.txt` and
/// `<name>.srt` beside the video, and noted in `meeting.json`.
///
/// - **An engine of its own**, at `.utility`, loaded for the job and freed
///   after it: the dictation's stays as it is, ready, and is never queued
///   behind an hour of meeting (spike S6: +10.6 MB, a dictation 61 → 66 ms
///   meanwhile).
/// - **One job at a time**, on one serial queue; the others wait their turn.
///   An automatic one also waits while a meeting records.
/// - **The meeting track first**: the echo filter of the microphone needs its
///   words and its energy (`ForkMeetingEcho`).
/// - `languageCode: nil`: Parakeet finds the language itself; a filter set
///   to French would cut the English of a mixed meeting (S6: 6 → 23 % of
///   errors).
/// - Cancelled at any window; nothing is written then, and a transcript
///   already there stays.
///
/// State on the main thread; the work on `work`.
final class ForkMeetingTranscriber: ObservableObject {
    static let shared = ForkMeetingTranscriber()

    enum Phase: Equatable {
        case idle
        /// Queued behind another, or behind a recording.
        case waiting
        /// The share done, 0…1.
        case running(Double)
    }

    /// How a job ended, for the notice and the detail.
    enum Outcome: Equatable {
        case done(words: Int)
        case failed(ForkMeetingTranscriptFailure)

        struct Entry: Equatable {
            let job: Job
            let outcome: Outcome
        }
    }

    struct Job: Equatable {
        let folder: URL
        /// The meeting's id: known from the library, or found when the job
        /// reads `meeting.json` (a meeting just saved).
        var id: UUID?
        /// Started on its own after a meeting: its end is said in a notice.
        let automatic: Bool
        let asked: Date

        /// The same meeting: the same id, or the same folder.
        func isFor(id other: UUID?, folder path: URL) -> Bool {
            if let id, let other, id == other { return true }
            return folder.standardizedFileURL.path == path.standardizedFileURL.path
        }
    }

    struct Running: Equatable {
        var job: Job
        var fraction: Double
    }

    /// The job at work and its share done.
    @Published private(set) var running: Running?
    @Published private(set) var waiting: [Job] = []
    /// What the last job of each meeting did, while the app runs: the detail
    /// says a failure until the next try.
    @Published private(set) var outcomes: [Outcome.Entry] = []

    private let store: ForkMeetingStore
    private let defaults: UserDefaults
    private let modelDirectory: () -> URL?
    private let isRecording: () -> Bool
    private let notify: (Job, Outcome) -> Void
    private let work = DispatchQueue(label: "fork.meetings.transcriber", qos: .utility)
    private let log = Logger(subsystem: "fork.meetings", category: "transcript")
    private var stop: ForkMeetingTranscriptStop?
    private var enabled = true
    private var observers: Set<AnyCancellable> = []

    /// What the recipe measures of the last job.
    struct Measure: Equatable {
        var audioSeconds: Double = 0
        var processingSeconds: Double = 0
        var loadSeconds: Double = 0
        var windows = 0
        var echoRemoved = 0
        var echoGain: Float?
        var echoDelay: Double?
        var peakSamplesHeld = 0
    }

    private(set) var lastMeasure = Measure()

    init(store: ForkMeetingStore = .shared, defaults: UserDefaults = .standard,
         modelDirectory: @escaping () -> URL? = { ForkParakeetModelStore.shared.installedDirectory },
         isRecording: @escaping () -> Bool = { ForkMeetingService.shared.isRecording },
         notify: ((Job, Outcome) -> Void)? = nil) {
        self.store = store
        self.defaults = defaults
        self.modelDirectory = modelDirectory
        self.isRecording = isRecording
        self.notify = notify ?? { job, outcome in ForkMeetingPresenter.shared.showTranscript(folder: job.folder, outcome: outcome) }
    }

    // MARK: - Asking

    /// Main thread. `false`: the feature is off, or the meeting is already
    /// queued or being transcribed.
    @discardableResult
    func transcribe(_ folder: URL, id: UUID?, automatic: Bool = false) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled, phase(id: id, folder: folder) == .idle else { return false }
        outcomes.removeAll { $0.job.isFor(id: id, folder: folder) }
        waiting.append(Job(folder: folder, id: id, automatic: automatic, asked: Date()))
        startNext()
        return true
    }

    /// The meeting just saved, when the setting asks for it.
    func meetingSaved(_ folder: URL, recovered: Bool) {
        guard ForkMeetingTranscript.transcribesAutomatically(
            featureOn: ForkMeetingService.shared.isWanted,
            settingOn: defaults.bool(forKey: ForkDefaultsKey.meetingsTranscribe), recovered: recovered) else { return }
        transcribe(folder, id: nil, automatic: true)
    }

    /// Main thread: stops this meeting's job at its next window, or takes it
    /// out of the queue.
    func cancel(id: UUID?, folder: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        waiting.removeAll { $0.isFor(id: id, folder: folder) }
        if running?.job.isFor(id: id, folder: folder) == true { stop?.cancel() }
    }

    func phase(id: UUID?, folder: URL) -> Phase {
        if let running, running.job.isFor(id: id, folder: folder) { return .running(running.fraction) }
        return waiting.contains { $0.isFor(id: id, folder: folder) } ? .waiting : .idle
    }

    func outcome(id: UUID?, folder: URL) -> Outcome? {
        outcomes.last { $0.job.isFor(id: id, folder: folder) }?.outcome
    }

    var isBusy: Bool { running != nil || !waiting.isEmpty }

    /// Every switch of the feature: off, the job stops and the queue empties;
    /// on, a job waiting for a recording to end goes when it ends.
    func sync(enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.enabled = enabled
        guard enabled else {
            observers.removeAll()
            waiting.removeAll()
            stop?.cancel()
            return
        }
        guard observers.isEmpty else { return }
        ForkMeetingService.shared.$isRecording.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.startNext() }
            .store(in: &observers)
    }

    // MARK: - Running

    private func startNext() {
        guard running == nil, enabled else { return }
        let recording = isRecording()
        guard let index = waiting.firstIndex(where: { ForkMeetingTranscript.mayStart(automatic: $0.automatic, recording: recording) })
        else { return }
        let job = waiting.remove(at: index)
        let stop = ForkMeetingTranscriptStop()
        self.stop = stop
        running = Running(job: job, fraction: 0)
        let directory = modelDirectory()
        let label = self.labels()
        let rules = ForkDictationSupport.replacements(
            from: defaults.string(forKey: ForkDefaultsKey.dictationReplacements) ?? "")
        work.async { [weak self] in
            guard let self else { return }
            var measure = Measure()
            var found = job
            let result = self.run(job, directory: directory, stop: stop, label: label, rules: rules,
                                  found: &found, measure: &measure)
            DispatchQueue.main.async { self.finished(found, result, measure: measure) }
        }
    }

    private func finished(_ job: Job, _ result: Result<Int, ForkMeetingTranscriptFailure>, measure: Measure) {
        running = nil
        stop = nil
        lastMeasure = measure
        let outcome: Outcome
        switch result {
        case let .success(words): outcome = .done(words: words)
        case let .failure(failure): outcome = .failed(failure)
        }
        outcomes.removeAll { $0.job.isFor(id: job.id, folder: job.folder) }
        outcomes.append(Outcome.Entry(job: job, outcome: outcome))
        log.notice("transcript of \(job.folder.lastPathComponent, privacy: .private): \(String(describing: outcome), privacy: .public)")
        // The person stopped it: nothing to tell. An automatic job is told,
        // once the saved notice had its time.
        if job.automatic, outcome != .failed(.cancelled), enabled {
            let wait = max(0, job.asked.addingTimeInterval(Self.noticeDelay).timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, self.enabled else { return }
                self.notify(job, outcome)
            }
        }
        startNext()
    }

    /// The job found its meeting's id: the detail follows it by that id
    /// from now on, through a rename.
    private func identified(_ id: UUID?) {
        guard let id, var running, running.job.id == nil else { return }
        running.job.id = id
        self.running = running
    }

    /// The saved notice holds this long: a transcript's comes after it.
    static let noticeDelay: TimeInterval = 9

    /// "Me: ", "Moi : ", in the person's language when the job starts.
    private func labels() -> (ForkMeetingSpeaker) -> String {
        let text = ForkMeetingStrings.current
        let me = text.transcriptMeLabel, others = text.transcriptOthersLabel
        return { $0 == .me ? me : others }
    }

    // MARK: - The work

    /// Work queue. The words kept, or why not.
    private func run(_ job: Job, directory: URL?, stop: ForkMeetingTranscriptStop,
                     label: @escaping (ForkMeetingSpeaker) -> String, rules: [ForkDictationSupport.Replacement],
                     found: inout Job, measure: inout Measure) -> Result<Int, ForkMeetingTranscriptFailure> {
        let result = transcribeOnWork(job, directory: directory, stop: stop, label: label, rules: rules,
                                      found: &found, measure: &measure)
        if case let .failure(failure) = result, failure != .cancelled, failure != .meetingInProgress {
            store.recordTranscriptFailure(failure, at: Date(), in: found.folder, id: found.id)
        }
        return result
    }

    private func transcribeOnWork(_ job: Job, directory: URL?, stop: ForkMeetingTranscriptStop,
                                  label: @escaping (ForkMeetingSpeaker) -> String,
                                  rules: [ForkDictationSupport.Replacement],
                                  found: inout Job, measure: inout Measure) -> Result<Int, ForkMeetingTranscriptFailure> {
        guard let directory else { return .failure(.modelMissing) }
        let source: ForkMeetingStore.TranscriptSource
        switch store.transcriptSource(job.folder, id: job.id) {
        case let .failure(failure): return .failure(failure)
        case let .success(located): source = located
        }
        found.id = found.id ?? source.id
        let id = found.id
        DispatchQueue.main.async { [weak self] in self?.identified(id) }
        let url = source.folder.appendingPathComponent(source.file)
        guard let audio = ForkMeetingTrackSource.audioTracks(of: url) else { return .failure(.unreadable) }
        guard let tracks = ForkMeetingTranscript.tracks(audioTrackCount: audio.tracks.count, isMaster: source.isMaster) else {
            return .failure(.noAudio)
        }
        let order = [tracks.meeting] + (tracks.microphone.map { [$0] } ?? [])

        let engine = ForkParakeetEngine(qos: .utility)
        defer { engine.unload() }
        let loadStarted = Date()
        do {
            try engine.load(from: directory)
        } catch {
            log.error("Parakeet did not load: \(String(describing: error), privacy: .public)")
            if case .missingModel = error as? ForkParakeetError { return .failure(.modelMissing) }
            return .failure(.engine)
        }
        measure.loadSeconds = Date().timeIntervalSince(loadStarted)

        var heard: [[ForkParakeetWord]] = []
        var envelopes: [ForkMeetingEnvelope] = []
        var lastPublished: Double?
        for (place, index) in order.enumerated() {
            guard !stop.isCancelled else { return .failure(.cancelled) }
            let reader: ForkMeetingTrackSource
            do {
                reader = try ForkMeetingTrackSource(asset: audio.asset, track: audio.tracks[index])
            } catch {
                return .failure(.unreadable)
            }
            do {
                let transcript = try engine.transcribeLong(reader, languageCode: nil) { [weak self] seconds in
                    let fraction = ForkMeetingTranscript.progress(trackIndex: place, tracks: order.count,
                                                                  seconds: seconds, duration: audio.duration)
                    if ForkMeetingFinalPass.shouldPublish(fraction, last: lastPublished) {
                        lastPublished = fraction
                        DispatchQueue.main.async { self?.progressed(fraction, of: job) }
                    }
                    return !stop.isCancelled
                }
                heard.append(transcript.words)
                envelopes.append(reader.envelope)
                measure.audioSeconds += transcript.audioDuration
                measure.processingSeconds += transcript.processingTime
                measure.windows += transcript.windowCount
                measure.peakSamplesHeld = max(measure.peakSamplesHeld, reader.peakHeld)
            } catch ForkParakeetError.cancelled {
                return .failure(.cancelled)
            } catch is ForkMeetingTrackSource.Failure {
                return .failure(.unreadable)
            } catch {
                log.error("Parakeet failed: \(String(describing: error), privacy: .public)")
                return .failure(.engine)
            }
        }
        guard !stop.isCancelled else { return .failure(.cancelled) }

        let document = ForkMeetingTranscriptFormat.document(
            me: heard.count > 1 ? heard[1] : [], participants: heard[0],
            microEnvelope: envelopes.count > 1 ? envelopes[1] : nil, meetingEnvelope: envelopes.first,
            label: label, rewrite: { ForkDictationReplacements.apply(rules, to: $0) })
        measure.echoRemoved = document.echo?.echo.count ?? 0
        measure.echoGain = document.echo?.gain
        measure.echoDelay = document.echo?.delay
        let words = heard.joined().map(\.text).joined(separator: " ")
        let language = ForkMeetingTranscript.baseLanguage(NLLanguageRecognizer.dominantLanguage(for: words)?.rawValue)
        let record = ForkMeetingTranscriptRecord(state: .done, words: document.words, language: language, at: Date())
        guard !stop.isCancelled else { return .failure(.cancelled) }
        switch store.writeTranscript(document, record: record, in: source.folder, id: source.id) {
        case let .failure(failure): return .failure(failure)
        case let .success(written):
            found = Job(folder: written, id: found.id, automatic: found.automatic, asked: found.asked)
            return .success(document.words)
        }
    }

    private func progressed(_ fraction: Double, of job: Job) {
        guard var running, running.job.asked == job.asked, running.job.folder == job.folder,
              fraction > running.fraction else { return }
        running.fraction = fraction
        self.running = running
    }
}

/// A job's stop, asked on the main thread, read at each window.
final class ForkMeetingTranscriptStop: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// One audio track of a meeting's file, decoded and resampled to 16 kHz mono
/// Float32 by AVAssetReader, served in order: no 16 kHz file in between, and
/// a few seconds in memory at a time. Its energy is measured on the way, for
/// the echo filter.
final class ForkMeetingTrackSource: ForkParakeetSampleSource {
    enum Failure: Error, Equatable {
        case cannotRead(String)
    }

    /// The file's audio tracks by order, and its length.
    struct Audio {
        let asset: AVURLAsset
        let tracks: [AVAssetTrack]
        let duration: TimeInterval
    }

    private final class Box: @unchecked Sendable {
        var audio: Audio?
    }

    /// Blocks until the file's tracks are loaded: never on the main thread.
    static func audioTracks(of url: URL) -> Audio? {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            if let tracks = try? await asset.loadTracks(withMediaType: .audio),
               let duration = try? await asset.load(.duration) {
                box.audio = Audio(asset: asset, tracks: tracks.sorted { $0.trackID < $1.trackID },
                                  duration: duration.seconds.isFinite ? duration.seconds : 0)
            }
            done.signal()
        }
        done.wait()
        return box.audio
    }

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: [Float] = []
    private var pendingOffset = 0
    private(set) var envelope = ForkMeetingEnvelope()
    /// The most samples held at once by this source.
    private(set) var peakHeld = 0

    init(asset: AVAsset, track: AVAssetTrack) throws {
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: ForkParakeetShape.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.cannotRead("output") }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.cannotRead(reader.error?.localizedDescription ?? "startReading")
        }
    }

    deinit { reader.cancelReading() }

    func read(into buffer: UnsafeMutableBufferPointer<Float>) throws -> Int {
        var written = 0
        while written < buffer.count {
            if pendingOffset >= pending.count {
                guard refill() else { break }
            }
            let count = min(buffer.count - written, pending.count - pendingOffset)
            for index in 0..<count { buffer[written + index] = pending[pendingOffset + index] }
            envelope.add(pending[pendingOffset..<(pendingOffset + count)])
            written += count
            pendingOffset += count
        }
        if written == 0, reader.status == .failed {
            throw Failure.cannotRead(reader.error?.localizedDescription ?? "failed")
        }
        return written
    }

    private func refill() -> Bool {
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes >= MemoryLayout<Float>.size else { continue }
            pending = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            let status = pending.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            pendingOffset = 0
            peakHeld = max(peakHeld, pending.count)
            return true
        }
        return false
    }
}
