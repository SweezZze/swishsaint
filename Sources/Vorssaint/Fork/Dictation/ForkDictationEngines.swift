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

    /// Dictation turned off or the app quitting: nothing stays in memory.
    func suspend() {
        apple.cancel()
        parakeet.cancel()
        parakeet.unload()
    }
}
