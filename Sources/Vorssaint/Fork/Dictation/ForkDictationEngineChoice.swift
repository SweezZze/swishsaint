// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The engine the person picked on the Dictation page.
enum ForkDictationEngineSetting: String, CaseIterable {
    /// Parakeet when it is installed and knows the language, else Apple.
    case auto
    case parakeet
    case apple

    static let fallback: ForkDictationEngineSetting = .auto
}

enum ForkDictationEngineKind: Equatable {
    /// NVIDIA Parakeet TDT 0.6B v3, on this Mac.
    case parakeet
    /// Apple's speech recognition, on this Mac or on Apple's servers.
    case apple
}

enum ForkDictationEngineChoice {
    /// The 25 European languages Parakeet v3 was trained on (ISO 639-1).
    /// Parakeet finds the language by itself among them.
    static var parakeetLanguages: Set<String> { ForkParakeetLanguages.supported }

    /// Whether Parakeet knows `language` (BCP 47). An empty language is the
    /// automatic one, which Parakeet detects.
    static func parakeetKnows(_ language: String) -> Bool {
        ForkParakeetLanguages.baseCode(language).isEmpty || ForkParakeetLanguages.isSupported(language)
    }

    /// The language that picks the engine: `language` when one is chosen,
    /// else the first of the person's own. Parakeet still detects the
    /// language itself; this only keeps Automatic from handing it Japanese.
    static func choiceLanguage(_ language: String, preferred: [String]) -> String {
        language.isEmpty ? (preferred.first ?? "") : language
    }

    /// The engine for one dictation. `language`: the shortcut's own, else
    /// the dictation's, else the system's.
    static func resolve(setting: ForkDictationEngineSetting, parakeetInstalled: Bool,
                        language: String) -> Result<ForkDictationEngineKind, ForkDictationFailure> {
        switch setting {
        case .apple:
            return .success(.apple)
        case .parakeet:
            return parakeetInstalled ? .success(.parakeet) : .failure(.modelMissing)
        case .auto:
            return .success(parakeetInstalled && parakeetKnows(language) ? .parakeet : .apple)
        }
    }
}
