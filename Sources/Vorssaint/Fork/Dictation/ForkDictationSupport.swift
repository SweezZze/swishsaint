// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze
// Copyright (C) 2026 Martial

import CoreGraphics
import Foundation

/// A key that dictates when held alone. Only keys that type nothing on
/// their own: a letter would fire in the app in front at the same time.
/// Combinations are `ForkDictationShortcut.Key.combo`.
enum ForkDictationTrigger: String, CaseIterable, Identifiable, Codable {
    case rightCommand
    case rightOption
    case rightControl
    case rightShift
    case fn
    case leftCommand
    case leftOption
    case leftControl
    case leftShift

    static let fallback: ForkDictationTrigger = .rightCommand

    var id: String { rawValue }

    /// The key's virtual key code, as a flagsChanged event carries it.
    var keyCode: Int64 {
        switch self {
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .leftShift: return 56
        case .leftOption: return 58
        case .leftControl: return 59
        case .rightShift: return 60
        case .rightOption: return 61
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    /// The flag that is set while this very key is down. Each side has a
    /// device bit of its own (IOLLEvent.h), so the other side held at the
    /// same time does not count.
    var downMask: UInt64 {
        switch self {
        case .rightCommand: return 0x10
        case .leftCommand: return 0x08
        case .rightShift: return 0x04
        case .leftShift: return 0x02
        case .rightOption: return 0x40
        case .leftOption: return 0x20
        case .rightControl: return 0x2000
        case .leftControl: return 0x01
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    var symbol: String {
        switch self {
        case .rightCommand, .leftCommand: return "⌘"
        case .rightOption, .leftOption: return "⌥"
        case .rightControl, .leftControl: return "⌃"
        case .rightShift, .leftShift: return "⇧"
        case .fn: return "fn 🌐"
        }
    }

    /// fn starts no shortcut of its own, so the microphone may open on the
    /// press. The others wait a moment to see whether a shortcut follows.
    var armsImmediately: Bool { self == .fn }

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

/// When to listen, from the shortcut alone. Hybrid is the way Wispr Flow
/// does it:
///
/// - held, then released: dictates what was said while it was down;
/// - tapped: hands-free, until the next press of the key;
/// - held together with another key: a shortcut, so nothing happens;
/// - Escape: gives up what was said.
///
/// Hold only dictates while the key is down, and toggle always goes
/// hands-free on the release. In every mode another key during the first
/// press is a keyboard shortcut, never a dictation.
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
        /// Given up on purpose (Escape): said so, with a sound.
        case cancel
        /// Not a dictation after all (a keyboard shortcut, a press too short
        /// to hold): dropped without a sound or a word.
        case abort
    }

    /// A press shorter than this is a tap.
    static let tapLimit: TimeInterval = 0.35

    let mode: ForkDictationShortcut.Mode
    private(set) var state: State = .idle

    init(mode: ForkDictationShortcut.Mode = .hybrid) {
        self.mode = mode
    }

    var isListening: Bool {
        switch state {
        case .holding, .handsFree: return true
        case .idle, .awaitingRelease: return false
        }
    }

    var isHandsFree: Bool { state == .handsFree }

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
            let tapped = time - since < Self.tapLimit
            switch mode {
            case .hybrid:
                state = tapped ? .handsFree : .idle
                return tapped ? .none : .finish
            case .hold:
                state = .idle
                return tapped ? .abort : .finish
            case .toggle:
                state = .handsFree
                return .none
            }
        case .awaitingRelease:
            state = .idle
            return .none
        case .idle, .handsFree:
            return .none
        }
    }

    /// Another key (or a click) while the shortcut is held: a keyboard
    /// shortcut, not a dictation. Once the person has been speaking a while
    /// (`keepsListening`), it is part of the dictation, not a reason to drop
    /// it. Hands-free, the person may type and keep talking.
    mutating func otherKey(keepsListening: Bool = false) -> Command {
        guard case .holding = state, !keepsListening else { return .none }
        state = .awaitingRelease
        return .abort
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

    /// The dictation ended on its own (an error, the time limit, silence).
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

    /// Pieces of one dictation put back together: a space between words,
    /// none where Chinese, Japanese or Korean text, or full-width
    /// punctuation, meets the next piece.
    static func joined(_ pieces: [String]) -> String {
        var result = ""
        for piece in pieces where !piece.isEmpty {
            if let last = result.unicodeScalars.last, let first = piece.unicodeScalars.first,
               !isWide(last), !isWide(first) {
                result += " "
            }
            result += piece
        }
        return result
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF, 0x3130...0x318F,
             0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF,
             0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

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

    /// Applied by `ForkDictationReplacements`, in a single pass.
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

/// Clicks, the wheel and system keys seen while a shortcut is held: which
/// of them mean the shortcut is part of something else.
enum ForkDictationOtherInput {
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS: the media, volume and brightness keys.
    static let mediaKeysSubtype = 8
    private static let keyDownState: UInt32 = 0x0A

    /// The momentum that keeps a flick scrolling for a second or two is not
    /// the person touching anything.
    static func scrollCounts(momentumPhase: Int64) -> Bool {
        momentumPhase == 0
    }

    /// Only the press of a media key; its release, its repeats and the other
    /// system events (power, eject, auxiliary buttons) do not count.
    static func systemKeyCounts(subtype: Int, data1: Int) -> Bool {
        guard subtype == mediaKeysSubtype else { return false }
        let raw = UInt32(truncatingIfNeeded: data1)
        return (raw >> 8) & 0xFF == keyDownState && raw & 0x1 == 0
    }
}
