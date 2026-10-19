// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AVFoundation
import Combine
import Foundation
import os

/// The dictation history: each dictation's text and outcome, and its audio
/// for a week (pinned ones keep it), so it can be heard and transcribed
/// again.
///
/// Everything stays on this Mac, in the app's private folder
/// (`Dictations/`): one Apple Lossless file per dictation and an index. It is machine
/// state, out of the settings backup; only the on/off setting is backed up.
/// The records are published on the main thread; files are written on a
/// serial queue.
final class ForkDictationArchive: ObservableObject {
    static let shared = ForkDictationArchive()

    /// Newest first.
    @Published private(set) var records: [ForkDictationRecord] = []
    /// The audio files' total size, in bytes.
    @Published private(set) var audioBytes: Int64 = 0
    /// The record being transcribed again, if any.
    @Published private(set) var retranscribing: UUID?

    static let sampleRate: Double = 16_000

    private let directory: URL
    private let queue = DispatchQueue(label: "fork.dictation.archive", qos: .utility)
    private let log = Logger(subsystem: "fork.dictation", category: "archive")
    private var purgeTimer: Timer?
    /// Bumped by each transcription again and by its guard: a late answer
    /// is dropped.
    private var retranscribeGeneration = 0
    private var retranscribeGuard: DispatchWorkItem?
    /// How long a transcription again may take before it is given up.
    static let retranscribeTimeout: TimeInterval = 120

    init(directory: URL? = nil) {
        // Outside a real bundle (a test tool) there is no container: the
        // history then lives in the temporary folder.
        let container = PrivateFileStore.containerURL ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? container.appendingPathComponent("Dictations", isDirectory: true)
        load()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.purge() }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        purgeTimer = timer
        DispatchQueue.main.async { [weak self] in self?.purge() }
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationKeepsHistory)
    }

    // MARK: Adding

    /// Keeps a dictation, with its audio when given. Nothing is kept when
    /// the history is off, or when the text looks like a secret and the
    /// clipboard history filters those out.
    func add(_ record: ForkDictationRecord, samples: [Float]?) {
        precondition(Thread.isMainThread)
        guard isEnabled, !Self.skips(record.text) else { return }
        var record = record
        record.hasAudio = samples?.isEmpty == false
        records.insert(record, at: 0)
        let snapshot = records
        let url = audioFile(record.id)
        let directory = directory
        queue.async { [weak self] in
            guard let self else { return }
            if let samples, !samples.isEmpty {
                do {
                    PrivateFileStore.createDirectory(at: directory)
                    try Self.writeAudio(samples, to: url)
                } catch {
                    self.log.error("audio not kept: \(error.localizedDescription, privacy: .private)")
                    DispatchQueue.main.async { self.update(record.id) { $0.hasAudio = false } }
                }
            }
            self.writeIndex(snapshot)
            self.measure()
        }
        trimToCap()
    }

    /// The clipboard history's filter applies here too: a password said
    /// aloud is no more kept than a copied one.
    static func skips(_ text: String) -> Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.clipboardHistoryFilterSensitiveText)
            && ClipboardHistorySensitiveText.looksSensitive(text)
    }

    // MARK: Changing

    func update(_ id: UUID, _ change: (inout ForkDictationRecord) -> Void) {
        precondition(Thread.isMainThread)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        saveIndex()
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        update(id) { $0.isPinned = pinned }
    }

    func delete(_ id: UUID) {
        precondition(Thread.isMainThread)
        records.removeAll { $0.id == id }
        let url = audioFile(id)
        queue.async { try? FileManager.default.removeItem(at: url) }
        saveIndex()
    }

    /// Several at once, with one write of the index: "Clear unpinned".
    func delete(_ ids: Set<UUID>) {
        precondition(Thread.isMainThread)
        guard !ids.isEmpty else { return }
        if let retranscribing, ids.contains(retranscribing) { endRetranscription() }
        records.removeAll { ids.contains($0.id) }
        let urls = ids.map(audioFile)
        queue.async { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        saveIndex()
    }

    func deleteAll() {
        precondition(Thread.isMainThread)
        endRetranscription()
        records = []
        let directory = directory
        queue.async { [weak self] in
            try? FileManager.default.removeItem(at: directory)
            DispatchQueue.main.async { self?.audioBytes = 0 }
        }
    }

    // MARK: Audio

    func audioURL(for id: UUID) -> URL? {
        guard records.first(where: { $0.id == id })?.hasAudio == true else { return nil }
        let url = audioFile(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The recording as 16 kHz mono Float32, decoded off the main thread;
    /// `completion` on the main thread, nil when there is none.
    func loadSamples(_ id: UUID, completion: @escaping ([Float]?) -> Void) {
        guard let url = audioURL(for: id) else {
            completion(nil)
            return
        }
        queue.async {
            let samples = try? Self.readAudio(url)
            DispatchQueue.main.async { completion(samples) }
        }
    }

    /// Transcribes a kept recording again, with `engine` (Parakeet or Apple,
    /// or the automatic choice) and `language` (nil: the dictation's). The
    /// record takes the new text. One at a time; a dictation may run
    /// meanwhile, the engines keep the two apart. `completion` is called
    /// once, at the latest after `retranscribeTimeout`.
    func retranscribe(_ id: UUID, engine setting: ForkDictationEngineSetting, language: String?,
                      completion: @escaping (Result<String, ForkDictationFailure>) -> Void) {
        precondition(Thread.isMainThread)
        guard retranscribing == nil else {
            completion(.failure(.transcriptionFailed))
            return
        }
        retranscribing = id
        retranscribeGeneration += 1
        let generation = retranscribeGeneration
        let finish: (Result<String, ForkDictationFailure>) -> Void = { [weak self] result in
            guard let self, self.retranscribeGeneration == generation else { return }
            self.endRetranscription()
            completion(result)
        }
        let guardWork = DispatchWorkItem { [weak self] in
            ForkDictationEngines.shared.cancelHistoryTranscription()
            self?.log.error("transcription again gave up after \(Self.retranscribeTimeout, format: .fixed(precision: 0)) s")
            finish(.failure(.transcriptionFailed))
        }
        retranscribeGuard = guardWork
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retranscribeTimeout, execute: guardWork)
        loadSamples(id) { [weak self] samples in
            guard let self, self.retranscribeGeneration == generation else { return }
            guard let samples else { return finish(.failure(.transcriptionFailed)) }
            let engines = ForkDictationEngines.shared
            let kind = engines.kind(for: setting, language: language ?? "")
            engines.transcribe(samples: samples, setting: setting, language: language) { result in
                guard self.retranscribeGeneration == generation else { return }
                if case let .success(raw) = result {
                    let text = ForkDictationService.corrected(raw)
                    self.update(id) { record in
                        record.rawText = raw
                        record.text = text
                        record.language = language ?? record.language
                        if case let .success(kind) = kind { record.engine = kind.storedName }
                        if record.outcome == .failed {
                            record.outcome = .inHistoryOnly
                            record.failure = nil
                        }
                    }
                    finish(.success(text))
                } else if case let .failure(failure) = result {
                    finish(.failure(failure))
                }
            }
        }
    }

    /// Ends the transcription again under way, if any: its answer, should
    /// it still come, is dropped.
    private func endRetranscription() {
        retranscribeGuard?.cancel()
        retranscribeGuard = nil
        retranscribeGeneration += 1
        if retranscribing != nil { retranscribing = nil }
    }

    // MARK: Retention

    /// Drops the audio past a week and the records past the cap, pinned
    /// ones aside. At launch, then every hour.
    func purge() {
        precondition(Thread.isMainThread)
        let plan = ForkDictationRetention.plan(records, now: Date())
        guard !plan.dropAudio.isEmpty || !plan.dropRecords.isEmpty else {
            let snapshot = records
            queue.async { [weak self] in
                self?.removeOrphans(keeping: snapshot)
                self?.measure()
            }
            return
        }
        let dropped = Set(plan.dropRecords)
        let silenced = Set(plan.dropAudio)
        records = records.compactMap { record in
            guard !dropped.contains(record.id) else { return nil }
            var record = record
            if silenced.contains(record.id) { record.hasAudio = false }
            return record
        }
        let files = (plan.dropAudio + plan.dropRecords).map(audioFile)
        let snapshot = records
        queue.async { [weak self] in
            files.forEach { try? FileManager.default.removeItem(at: $0) }
            self?.writeIndex(snapshot)
            self?.removeOrphans(keeping: snapshot)
            self?.measure()
        }
    }

    private func trimToCap() {
        guard records.count > ForkDictationRetention.maximumRecords else { return }
        purge()
    }

    // MARK: Files

    private var indexFile: URL { directory.appendingPathComponent("index.json") }

    private func audioFile(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).m4a")
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexFile) else { return }
        guard let decoded = ForkDictationIndex.decode(data) else {
            // Set aside, never written over: a later version may read it.
            // The audio, of no use without its text, goes at the next purge.
            let aside = directory.appendingPathComponent(
                "index.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexFile, to: aside)
            log.error("unreadable index set aside")
            return
        }
        records = decoded
        queue.async { [weak self] in self?.measure() }
    }

    /// On the queue. Audio files no record names: left by a crash, a
    /// deleted record or an index set aside.
    private func removeOrphans(keeping records: [ForkDictationRecord]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in ForkDictationIndex.orphans(names, records: records) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func saveIndex() {
        let snapshot = records
        queue.async { [weak self] in self?.writeIndex(snapshot) }
    }

    /// On the queue.
    private func writeIndex(_ records: [ForkDictationRecord]) {
        guard PrivateFileStore.createDirectory(at: directory),
              let data = try? ForkDictationIndex.encode(records),
              PrivateFileStore.write(data, to: indexFile)
        else {
            log.error("index not written")
            return
        }
    }

    /// On the queue.
    private func measure() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.filter { $0.pathExtension == "m4a" }.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        DispatchQueue.main.async { [weak self] in
            if self?.audioBytes != bytes { self?.audioBytes = bytes }
        }
    }

    // MARK: Apple Lossless

    private static var pcmFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// 16 kHz mono Apple Lossless (16-bit), about 1 MB a minute. Lossless
    /// on purpose: AAC, even at 48 kb/s, made Parakeet write different
    /// words on two recordings out of three, and transcribing again must
    /// give what the dictation heard. Written to a temporary file first, so
    /// a crash never leaves half a recording under the real name.
    static func writeAudio(_ samples: [Float], to url: URL) throws {
        guard let format = pcmFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw CocoaError(.fileWriteUnknown) }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ]
        let partial = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).partial.m4a")
        try? FileManager.default.removeItem(at: partial)
        do {
            // The file is closed (and its header finished) when it goes away.
            let file = try AVAudioFile(forWriting: partial, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
    }

    /// The recording back as 16 kHz mono Float32.
    static func readAudio(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard file.processingFormat.sampleRate != sampleRate, let target = pcmFormat,
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { return samples }
        let ratio = sampleRate / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 1024)
        else { return samples }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let converted = output.floatChannelData?[0] else { return samples }
        return Array(UnsafeBufferPointer(start: converted, count: Int(output.frameLength)))
    }
}

extension ForkDictationEngineKind {
    /// How a record names its engine.
    var storedName: String {
        switch self {
        case .parakeet: return "parakeet"
        case .apple: return "apple"
        }
    }
}
