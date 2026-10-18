// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The person's corrections, "heard → written", applied to a transcript.
///
/// - Whole words only: "sdr" never touches "sdrastvouitie".
/// - Case and accents ignored: "resume" catches "Résumé".
/// - The longest rule first; between two of the same length, the one
///   declared first.
/// - **A single pass**: what a rule writes is a result, never read again by
///   another rule. With "sdr → commercial" and "commercial → vendeur", "sdr"
///   becomes "commercial", not "vendeur"; and "meet → réunion" cannot eat the
///   "Meet" that "google meet → Google Meet" just wrote.
/// - Literal text on both sides: ".*", "c++" or "$1" are just characters.
enum ForkDictationReplacements {
    static func apply(_ rules: [ForkDictationSupport.Replacement], to text: String) -> String {
        let usable = rules.filter {
            !$0.heard.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.written.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !usable.isEmpty, !text.isEmpty else { return text }

        // sorted(by:) is not stable: the declaration index breaks ties.
        let ordered = usable.enumerated()
            .sorted { left, right in
                left.element.heard.count == right.element.heard.count
                    ? left.offset < right.offset
                    : left.element.heard.count > right.element.heard.count
            }
            .map(\.element)

        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if let hit = match(ordered, in: text, at: index) {
                result += hit.written
                index = hit.end
                continue
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    /// The first rule that matches exactly at `index`, between two word
    /// boundaries.
    private static func match(_ rules: [ForkDictationSupport.Replacement], in text: String,
                              at index: String.Index) -> (written: String, end: String.Index)? {
        let startsWord = index == text.startIndex || !isWordCharacter(text[text.index(before: index)])
        guard startsWord else { return nil }
        for rule in rules {
            guard let found = text.range(of: rule.heard,
                                         options: [.caseInsensitive, .diacriticInsensitive, .anchored],
                                         range: index..<text.endIndex),
                  !found.isEmpty else { continue }
            let endsWord = found.upperBound == text.endIndex || !isWordCharacter(text[found.upperBound])
            guard endsWord else { continue }
            return (rule.written, found.upperBound)
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
