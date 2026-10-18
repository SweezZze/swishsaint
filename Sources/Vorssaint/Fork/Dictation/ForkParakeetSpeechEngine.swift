// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Combine
import Foundation
import os

/// Parakeet as a dictation engine: the model is loaded at the first press
/// (or ahead of it, once installed), shared by every dictation, and freed
/// after a few idle minutes.
///
/// Main thread only. The model itself runs on `ForkParakeetEngine`'s queue.
final class ForkParakeetSpeechEngine: ForkDictationEngine {
    let kind = ForkDictationEngineKind.parakeet
    /// Parakeet only works once the capture is over: nothing fails while the
    /// person speaks.
    var onFailure: ((ForkDictationFailure) -> Void)?
    /// Parakeet hears nothing live, so it never stops on its own.
    var onStopped: (() -> Void)?

    private enum Load {
        case idle
        case loading(URL)
        case loaded(URL)
    }

    private let core: ForkParakeetEngine
    private let store: ForkParakeetModelStore
    /// Minutes before an idle model is freed: the setting, unless a test
    /// injects its own.
    private let unloadDelay: () -> TimeInterval
    private let log = Logger(subsystem: "fork.dictation", category: "parakeet")

    private var load = Load.idle
    /// Answered when the load in progress ends (nil: loaded).
    private var waiters: [(ForkDictationFailure?) -> Void] = []
    /// Bumped by every load, so an old load's answer is not taken for a
    /// newer one's after an unload.
    private var loadGeneration = 0
    /// Bumped by `begin` and `cancel`: a transcription that answers for an
    /// older dictation is dropped.
    private var session = 0
    private var languageCode: String?
    /// A dictation is between `begin` and its answer: the model stays.
    private var isBusy = false
    private var unloadTimer: Timer?
    private var storeObserver: AnyCancellable?

    /// How many loads actually reached the model, for the checks.
    private(set) var loadCount = 0

    init(core: ForkParakeetEngine = ForkParakeetEngine(),
         store: ForkParakeetModelStore = .shared,
         unloadDelay: (() -> TimeInterval)? = nil) {
        self.core = core
        self.store = store
        self.unloadDelay = unloadDelay ?? {
            let minutes = UserDefaults.standard.integer(forKey: ForkDefaultsKey.dictationUnloadMinutes)
            return TimeInterval(max(1, minutes == 0 ? 5 : minutes) * 60)
        }
        // A model deleted from the settings must not stay in memory.
        storeObserver = store.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if case .installed = state { return }
                if case .verifying = state { return }
                self.unload()
            }
    }

    var isLoaded: Bool {
        if case .loaded = load { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = load { return true }
        return false
    }

    // MARK: ForkDictationEngine

    func prepare() {
        ensureLoaded { _ in }
    }

    /// Loads the model ahead of the first dictation: the very first load on
    /// a Mac compiles it for the Neural Engine, which takes several seconds.
    func warmUpInBackground() {
        guard store.installedDirectory != nil else { return }
        ensureLoaded { _ in }
    }

    func begin(language: String, vocabulary: [String]) -> ForkDictationFailure? {
        guard store.installedDirectory != nil else { return .modelMissing }
        session += 1
        isBusy = true
        unloadTimer?.invalidate()
        let code = ForkParakeetLanguages.baseCode(language)
        // Only a language Parakeet knows filters the alphabet; it finds the
        // language itself either way.
        languageCode = ForkParakeetLanguages.supported.contains(code) ? code : nil
        ensureLoaded { _ in }
        return nil
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {}

    func finish(samples: [Float], completion: @escaping (Result<String, ForkDictationFailure>) -> Void) {
        let session = self.session
        let languageCode = self.languageCode
        isBusy = true
        ensureLoaded { [weak self] failure in
            guard let self, self.session == session else { return }
            if let failure {
                self.answer(.failure(failure), completion)
                return
            }
            self.core.transcribe(samples, languageCode: languageCode) { [weak self] result in
                guard let self, self.session == session else { return }
                switch result {
                case let .success(transcript):
                    self.log.debug("transcribed \(transcript.audioDuration, format: .fixed(precision: 1)) s in \(transcript.processingTime, format: .fixed(precision: 2)) s")
                    self.answer(.success(transcript.text), completion)
                case let .failure(error):
                    self.log.error("transcription failed: \(String(describing: error), privacy: .public)")
                    self.answer(.failure(Self.failure(for: error)), completion)
                }
            }
        }
    }

    func cancel() {
        session += 1
        isBusy = false
        scheduleUnload()
    }

    /// Frees the model now, unless a dictation is using it.
    func unload() {
        unloadTimer?.invalidate()
        unloadTimer = nil
        guard !isBusy else { return }
        if case .idle = load { return }
        loadGeneration += 1
        load = .idle
        finishWaiters(.modelMissing)
        core.unload()
        log.debug("model unloaded")
    }

    // MARK: Loading

    private func ensureLoaded(_ done: @escaping (ForkDictationFailure?) -> Void) {
        ensureLoaded(retrying: true, done)
    }

    private func ensureLoaded(retrying: Bool, _ done: @escaping (ForkDictationFailure?) -> Void) {
        guard let directory = store.installedDirectory else {
            done(.modelMissing)
            return
        }
        switch load {
        case let .loaded(loaded) where loaded == directory:
            done(nil)
            return
        case let .loading(loading) where loading == directory:
            waiters.append(done)
            return
        default:
            break
        }
        waiters.append(done)
        loadGeneration += 1
        let generation = loadGeneration
        load = .loading(directory)
        loadCount += 1
        let started = Date()
        core.prepare(from: directory) { [weak self] error in
            guard let self, self.loadGeneration == generation else { return }
            if let error {
                self.log.error("model load failed: \(String(describing: error), privacy: .public)")
                self.loadFailed(error, directory: directory, generation: generation, retrying: retrying)
                return
            }
            self.log.debug("model ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
            self.load = .loaded(directory)
            self.finishWaiters(nil)
            self.scheduleUnload()
        }
    }

    /// A load can fail once for a passing reason (the Neural Engine busy,
    /// memory short): it is tried again before anything is said. Only files
    /// that no longer match their checksums make a damaged model, worth
    /// downloading 461 MB again.
    private func loadFailed(_ error: Error, directory: URL, generation: Int, retrying: Bool) {
        load = .idle
        if case .missingModel = error as? ForkParakeetError {
            finishWaiters(.modelMissing)
            return
        }
        if retrying {
            let waiting = waiters
            waiters = []
            ensureLoaded(retrying: false) { failure in waiting.forEach { $0(failure) } }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let damaged = !ForkParakeetManifest.missing(in: directory, checksum: true).isEmpty
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                self.finishWaiters(damaged ? .modelDamaged : .transcriptionFailed)
            }
        }
    }

    private func finishWaiters(_ failure: ForkDictationFailure?) {
        let waiting = waiters
        waiters = []
        waiting.forEach { $0(failure) }
    }

    private func answer(_ result: Result<String, ForkDictationFailure>,
                        _ completion: (Result<String, ForkDictationFailure>) -> Void) {
        isBusy = false
        scheduleUnload()
        completion(result)
    }

    private func scheduleUnload() {
        unloadTimer?.invalidate()
        guard !isBusy, isLoaded else { return }
        let timer = Timer(timeInterval: unloadDelay(), repeats: false) { [weak self] _ in
            self?.unload()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        unloadTimer = timer
    }

    /// A missing file is a missing model; anything else while transcribing
    /// is a failed transcription.
    private static func failure(for error: Error) -> ForkDictationFailure {
        if case .missingModel = error as? ForkParakeetError { return .modelMissing }
        return .transcriptionFailed
    }
}
