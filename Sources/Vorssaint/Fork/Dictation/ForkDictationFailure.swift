// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Each way a dictation can fail. Every case is one the service actually
/// raises, and each says what to do: a message that only names the problem
/// is no better than silence.
enum ForkDictationFailure: Error, Equatable {
    case accessibilityMissing
    case microphoneDenied
    /// The microphones are muted from Vorssaint's own mute.
    case microphoneMutedInVorssaint
    /// The microphone started but sends nothing: no samples, or only zeros.
    case microphoneSilent
    case captureFailed
    /// macOS hides every key from event taps while a password field, or
    /// Terminal's Secure Keyboard Entry, is on. `app` when it can be named.
    case secureInput(app: String?)
    case speechDenied
    /// A local build without the speech recognition usage text.
    case speechUnavailableInBuild
    case languageUnavailable
    case modelMissing
    case modelDamaged
    case transcriptionFailed
}

/// The button offered next to a failure.
enum ForkDictationFailureAction: Equatable {
    case openAccessibility
    case openMicrophonePrivacy
    case unmuteMicrophone
    case openSpeechPrivacy
    case downloadModel
    case redownloadModel
    case openSettingsPage
}

extension ForkDictationFailure {
    /// A few words, for the island and the bubble.
    func summary(_ s: ForkDictationStrings) -> String {
        switch self {
        case .accessibilityMissing: return s.failAccessibility
        case .microphoneDenied: return s.failMicrophoneDenied
        case .microphoneMutedInVorssaint: return s.failMicrophoneMuted
        case .microphoneSilent: return s.failMicrophoneSilent
        case .captureFailed: return s.failCapture
        case let .secureInput(app):
            guard let app, !app.isEmpty else { return s.failSecureInput }
            return String(format: s.failSecureInputFormat, app)
        case .speechDenied: return s.failSpeechDenied
        case .speechUnavailableInBuild: return s.failBuild
        case .languageUnavailable: return s.failLanguage
        case .modelMissing: return s.failModelMissing
        case .modelDamaged: return s.failModelDamaged
        case .transcriptionFailed: return s.failTranscription
        }
    }

    /// What to do about it, in a full sentence: the Dictation page and
    /// VoiceOver.
    func remedy(_ s: ForkDictationStrings) -> String {
        switch self {
        case .accessibilityMissing: return s.failAccessibilityRemedy
        case .microphoneDenied: return s.failMicrophoneDeniedRemedy
        case .microphoneMutedInVorssaint: return s.failMicrophoneMutedRemedy
        case .microphoneSilent: return s.failMicrophoneSilentRemedy
        case .captureFailed: return s.failCaptureRemedy
        case .secureInput: return s.failSecureInputRemedy
        case .speechDenied: return s.failSpeechDeniedRemedy
        case .speechUnavailableInBuild: return s.failBuildRemedy
        case .languageUnavailable: return s.failLanguageRemedy
        case .modelMissing: return s.failModelMissingRemedy
        case .modelDamaged: return s.failModelDamagedRemedy
        case .transcriptionFailed: return s.failTranscriptionRemedy
        }
    }

    var action: ForkDictationFailureAction? {
        switch self {
        case .accessibilityMissing: return .openAccessibility
        case .microphoneDenied: return .openMicrophonePrivacy
        case .microphoneMutedInVorssaint: return .unmuteMicrophone
        case .microphoneSilent, .captureFailed, .languageUnavailable: return .openSettingsPage
        case .speechDenied: return .openSpeechPrivacy
        case .modelMissing: return .downloadModel
        case .modelDamaged: return .redownloadModel
        case .secureInput, .speechUnavailableInBuild, .transcriptionFailed: return nil
        }
    }

    var isSecureInput: Bool {
        if case .secureInput = self { return true }
        return false
    }

    /// A cause that stays until the person acts on it, worth a banner on the
    /// Dictation page. The others belong to one dictation and pass with it.
    var isLasting: Bool {
        switch self {
        case .accessibilityMissing, .microphoneDenied, .microphoneMutedInVorssaint, .speechDenied,
             .speechUnavailableInBuild, .modelMissing, .modelDamaged:
            return true
        case .microphoneSilent, .captureFailed, .secureInput, .languageUnavailable, .transcriptionFailed:
            return false
        }
    }

    /// Every case, for the checks that each one explains itself.
    static let all: [ForkDictationFailure] = [
        .accessibilityMissing, .microphoneDenied, .microphoneMutedInVorssaint, .microphoneSilent,
        .captureFailed, .secureInput(app: nil), .secureInput(app: "Terminal"), .speechDenied,
        .speechUnavailableInBuild, .languageUnavailable, .modelMissing, .modelDamaged, .transcriptionFailed,
    ]
}
