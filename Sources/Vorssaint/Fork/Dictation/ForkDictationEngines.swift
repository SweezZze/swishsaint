// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Combine
import Foundation

/// The two engines, made once, and the rule that picks one per dictation
/// (`ForkDictationEngineChoice`). Main thread only.
final class ForkDictationEngines {
    static let shared = ForkDictationEngines()

    let apple = ForkAppleSpeechEngine()
    let parakeet: ForkParakeetSpeechEngine
    /// Apple's engine for the history alone: a dictation that begins or is
    /// cancelled while a recording is transcribed again never touches it.
    /// Parakeet shares its loaded model instead (`transcribeDetached`).
    private let historyApple = ForkAppleSpeechEngine()

    private let store: ForkParakeetModelStore
    private var storeObserver: AnyCancellable?

    init(store: ForkParakeetModelStore = .shared) {
        self.store = store
        parakeet = ForkParakeetSpeechEngine(store: store)
        // A model that has just been installed is loaded at once, so the
        // first dictation does not wait for the Neural Engine to compile it.
        storeObserver = store.$state
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .installed = state { self?.warmUpIfWanted() }
            }
    }

    static var setting: ForkDictationEngineSetting {
        UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationEngine)
            .flatMap(ForkDictationEngineSetting.init(rawValue:)) ?? .fallback
    }

    var isParakeetInstalled: Bool {
        store.installedDirectory != nil
    }

    /// Which engine a dictation in `language` (BCP 47, empty: automatic)
    /// would use, for the settings page too. An automatic language is the
    /// person's own here. Apple in a build that cannot ask for speech
    /// recognition (a local one) is a failure already, not "ready".
    func kind(for setting: ForkDictationEngineSetting = ForkDictationEngines.setting,
              language: String) -> Result<ForkDictationEngineKind, ForkDictationFailure> {
        let language = ForkDictationEngineChoice.choiceLanguage(language, preferred: Locale.preferredLanguages)
        let kind = ForkDictationEngineChoice.resolve(setting: setting, parakeetInstalled: isParakeetInstalled,
                                                     language: language)
        if case .success(.apple) = kind, !ForkAppleSpeechEngine.canAskForSpeechRecognition {
            return .failure(.speechUnavailableInBuild)
        }
        return kind
    }

    func engine(for setting: ForkDictationEngineSetting = ForkDictationEngines.setting,
                language: String) -> Result<ForkDictationEngine, ForkDictationFailure> {
        kind(for: setting, language: language).map { kind -> ForkDictationEngine in
            switch kind {
            case .parakeet: return parakeet
            case .apple: return apple
            }
        }
    }

    /// When dictation is on and Parakeet may serve it: loads the model in
    /// the background (it is freed again after the idle delay).
    func warmUpIfWanted() {
        guard UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationEnabled),
              Self.setting != .apple, isParakeetInstalled
        else { return }
        parakeet.warmUpInBackground()
    }

    /// Transcribes audio kept in the dictation history, apart from any
    /// dictation: Parakeet through its detached path, Apple through an
    /// engine of its own. `language` nil: the dictation language.
    /// `completion` on the main thread, with the raw text, called once.
    func transcribe(samples: [Float], setting: ForkDictationEngineSetting, language: String?,
                    completion: @escaping (Result<String, ForkDictationFailure>) -> Void) {
        let language = language
            ?? UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationLocale) ?? ""
        switch kind(for: setting, language: language) {
        case let .failure(failure):
            completion(.failure(failure))
        case .success(.parakeet):
            parakeet.transcribeDetached(samples, language: language, completion: completion)
        case .success(.apple):
            transcribeWithApple(samples, language: language, completion: completion)
        }
    }

    private func transcribeWithApple(_ samples: [Float], language: String,
                                     completion: @escaping (Result<String, ForkDictationFailure>) -> Void) {
        let engine = historyApple
        let vocabulary = ForkDictationSupport.vocabulary(
            from: UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationVocabulary) ?? "")
        if let failure = engine.begin(language: language, vocabulary: vocabulary) {
            completion(.failure(failure))
            return
        }
        var answered = false
        let answer: (Result<String, ForkDictationFailure>) -> Void = { result in
            guard !answered else { return }
            answered = true
            engine.onFailure = nil
            engine.onStopped = nil
            completion(result)
        }
        engine.onFailure = { failure in
            engine.cancel()
            answer(.failure(failure))
        }
        engine.onStopped = nil
        // Apple recognizes what it is fed: the recording goes in by blocks,
        // as the microphone would have sent it, then the request ends.
        DispatchQueue.global(qos: .userInitiated).async {
            let block = 1600
            samples.withUnsafeBufferPointer { all in
                var start = 0
                while start < all.count {
                    let end = min(start + block, all.count)
                    engine.append(UnsafeBufferPointer(rebasing: all[start..<end]))
                    start = end
                }
            }
            DispatchQueue.main.async { engine.finish(samples: samples, completion: answer) }
        }
    }

    /// Gives up a history transcription that outlived its guard delay.
    func cancelHistoryTranscription() {
        historyApple.cancel()
    }

    /// Dictation turned off or the app quitting: nothing stays in memory.
    func suspend() {
        apple.cancel()
        historyApple.cancel()
        parakeet.cancel()
        parakeet.unload()
    }
}
