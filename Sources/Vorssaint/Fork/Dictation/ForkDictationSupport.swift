// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import CoreGraphics
import Foundation

/// The key held to dictate. Only keys that type nothing on their own: a
/// letter or a shortcut would fire in the app in front at the same time.
enum ForkDictationTrigger: String, CaseIterable, Identifiable {
    case rightCommand
    case rightOption
    case rightControl
    case rightShift
    case fn

    static let fallback: ForkDictationTrigger = .rightCommand

    var id: String { rawValue }

    /// The key's virtual key code, as a flagsChanged event carries it.
    var keyCode: Int64 {
        switch self {
        case .rightCommand: return 54
        case .rightShift: return 60
        case .rightOption: return 61
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    /// The flag that is set while this very key is down. The right-hand
    /// keys have device bits of their own (IOLLEvent.h), so the left-hand
    /// key held at the same time does not count.
    var downMask: UInt64 {
        switch self {
        case .rightCommand: return 0x10
        case .rightShift: return 0x04
        case .rightOption: return 0x40
        case .rightControl: return 0x2000
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    var symbol: String {
        switch self {
        case .rightCommand: return "⌘"
        case .rightOption: return "⌥"
        case .rightControl: return "⌃"
        case .rightShift: return "⇧"
        case .fn: return "fn 🌐"
        }
    }

    static var current: ForkDictationTrigger {
        UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationTrigger)
            .flatMap(ForkDictationTrigger.init(rawValue:)) ?? fallback
    }

    /// Whether a flagsChanged event for `keyCode` with `flags` presses
    /// (true) or releases (false) this key; nil when it is another key.
    func isDown(keyCode: Int64, flags: UInt64) -> Bool? {
        guard keyCode == self.keyCode else { return nil }
        return flags & downMask != 0
    }
}

/// When to listen, from the trigger key alone, the way Wispr Flow does:
///
/// - held, then released: dictates what was said while it was down;
/// - tapped: hands-free, until the next press of the key;
/// - held together with another key: a shortcut, so nothing happens;
/// - Escape: gives up what was said.
struct ForkDictationGesture {
    enum State: Equatable {
        case idle
        case holding(since: TimeInterval)
        case handsFree
        /// Done or given up, and the key is still down: its release is not
        /// a new press.
        case awaitingRelease
    }

    enum Command: Equatable {
        case none
        case start
        case finish
        case cancel
    }

    /// A press shorter than this is a tap.
    static let tapLimit: TimeInterval = 0.35

    private(set) var state: State = .idle

    var isListening: Bool {
        switch state {
        case .holding, .handsFree: return true
        case .idle, .awaitingRelease: return false
        }
    }

    mutating func triggerDown(at time: TimeInterval) -> Command {
        switch state {
        case .idle:
            state = .holding(since: time)
            return .start
        case .handsFree:
            state = .awaitingRelease
            return .finish
        case .holding, .awaitingRelease:
            return .none
        }
    }

    mutating func triggerUp(at time: TimeInterval) -> Command {
        switch state {
        case let .holding(since):
            if time - since < Self.tapLimit {
                state = .handsFree
                return .none
            }
            state = .idle
            return .finish
        case .awaitingRelease:
            state = .idle
            return .none
        case .idle, .handsFree:
            return .none
        }
    }

    /// Another key while the trigger is held: a shortcut, not a dictation.
    /// Hands-free, the person may type and keep talking.
    mutating func otherKey() -> Command {
        guard case .holding = state else { return .none }
        state = .awaitingRelease
        return .cancel
    }

    mutating func escape() -> Command {
        switch state {
        case .holding:
            state = .awaitingRelease
            return .cancel
        case .handsFree:
            state = .idle
            return .cancel
        case .idle, .awaitingRelease:
            return .none
        }
    }

    /// The dictation ended on its own (an error, the time limit).
    mutating func end(triggerHeld: Bool) {
        state = triggerHeld ? .awaitingRelease : .idle
    }
}

enum ForkDictationSupport {
    /// The longest dictation: a hands-free one forgotten does not keep the
    /// microphone open.
    static let maximumDuration: TimeInterval = 5 * 60
    /// How long the recognizer may take to settle once the person stops.
    static let finishTimeout: TimeInterval = 4

    /// What goes into the text field: nothing when nothing was understood.
    static func insertion(_ transcript: String) -> String? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The language to recognize: the one chosen, else the first of the
    /// person's languages the recognizer knows, matching the region first.
    /// Identifiers are compared as BCP 47 ("fr-FR").
    static func localeIdentifier(chosen: String, supported: [String], preferred: [String]) -> String? {
        let supported = supported.map(normalized)
        if !chosen.isEmpty, supported.contains(normalized(chosen)) { return normalized(chosen) }
        for language in preferred.map(normalized) {
            if supported.contains(language) { return language }
            let base = language.split(separator: "-").first.map(String.init) ?? language
            let sameLanguage = supported.filter { $0 == base || $0.hasPrefix(base + "-") }.sorted()
            if let match = sameLanguage.first { return match }
        }
        return supported.contains("en-US") ? "en-US" : supported.sorted().first
    }

    // MARK: - Vocabulary

    /// The most words handed to the recognizer: it weighs them all on each
    /// guess, and Apple advises keeping the list short.
    static let vocabularyLimit = 100

    /// The person's own words, stored one per line: hints for the
    /// recognizer, for names and terms it would otherwise mishear.
    static func vocabulary(from stored: String) -> [String] {
        var seen = Set<String>()
        return stored.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(vocabularyLimit)
            .map { $0 }
    }

    static func storedVocabulary(_ words: [String]) -> String {
        words.joined(separator: "\n")
    }

    struct Replacement: Equatable, Hashable {
        var heard: String
        var written: String
    }

    /// Stored one per line, what is heard and what to write separated by a
    /// tab.
    static func replacements(from stored: String) -> [Replacement] {
        stored.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2 else { return nil }
            let heard = parts[0].trimmingCharacters(in: .whitespaces)
            let written = parts[1].trimmingCharacters(in: .whitespaces)
            return heard.isEmpty ? nil : Replacement(heard: heard, written: written)
        }
    }

    static func storedReplacements(_ replacements: [Replacement]) -> String {
        replacements.map { "\($0.heard)\t\($0.written)" }.joined(separator: "\n")
    }

    /// Writes each replacement in place of what was heard, as whole words,
    /// whatever the case. The longest first, so "pull request" wins over
    /// "pull".
    static func applying(_ replacements: [Replacement], to text: String) -> String {
        var result = text
        for replacement in replacements.sorted(by: { $0.heard.count > $1.heard.count }) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: replacement.heard)
                + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement.written))
        }
        return result
    }

    static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// A level between 0 and 1 for the bars, from a buffer's RMS power:
    /// speech sits around -40 to -10 dB.
    static func level(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 50) / 40))
    }
}
