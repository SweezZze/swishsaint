// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What the island or the bubble shows. Drawn by the presenter, decided by
/// the machine.
enum ForkDictationPresentation: Equatable {
    case hidden
    /// `startedAt`: when the microphone really opened, for the timer.
    /// `nearLimit`: the last thirty seconds before the time limit.
    case listening(handsFree: Bool, startedAt: Date, nearLimit: Bool)
    case transcribing
    case pasted(excerpt: String)
    /// Left on the clipboard on purpose (the Copy action).
    case copied(excerpt: String)
    /// The paste could not happen: the text waits on the clipboard.
    case keptInClipboard
    /// `afterSilence`: hands-free stopped after a minute without a voice.
    case nothingHeard(afterSilence: Bool)
    case cancelled
    /// A press while the last dictation is still being written.
    case busy
    case failure(ForkDictationFailure)

    /// How long this state stays before it hides itself; nil while it lasts
    /// until replaced.
    var holdDuration: TimeInterval? {
        switch self {
        case .hidden, .listening, .transcribing: return nil
        case .pasted: return 1.6
        case .copied, .keptInClipboard: return 4
        case .nothingHeard: return 1.4
        case .cancelled: return 0.9
        case .busy: return 0.6
        case .failure: return 4
        }
    }

    static let excerptLength = 42

    /// The start of a dictation on one line, short enough for the island.
    static func excerpt(_ text: String) -> String {
        let line = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard line.count > excerptLength else { return line }
        let cut = line.prefix(excerptLength - 1).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }
}

/// Where the dictation shows itself.
enum ForkDictationFeedbackSetting: String, CaseIterable {
    /// The island when it can show the microphone, else the bubble.
    case auto
    case island
    case bubble

    static let fallback: ForkDictationFeedbackSetting = .auto
}
