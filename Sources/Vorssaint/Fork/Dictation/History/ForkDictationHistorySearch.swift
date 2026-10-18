// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// How the history panel lists the dictations: pinned ones first, then the
/// others by day, newest first. A search lists its matches alone, newest
/// first, without the days.
enum ForkDictationHistoryListing {
    struct Section: Equatable {
        enum Kind: Equatable {
            case pinned
            /// The day's start, in the calendar given.
            case day(Date)
            case results
        }

        let kind: Kind
        let records: [ForkDictationRecord]
    }

    static func sections(_ records: [ForkDictationRecord], query: String,
                         calendar: Calendar) -> [Section] {
        let newestFirst = records.sorted { $0.date > $1.date }
        let tokens = searchTokens(query)
        guard tokens.isEmpty else {
            let found = newestFirst.filter { matches($0, tokens: tokens) }
            return found.isEmpty ? [] : [Section(kind: .results, records: found)]
        }
        var sections: [Section] = []
        let pinned = newestFirst.filter(\.isPinned)
        if !pinned.isEmpty { sections.append(Section(kind: .pinned, records: pinned)) }
        var days: [(Date, [ForkDictationRecord])] = []
        for record in newestFirst where !record.isPinned {
            let day = calendar.startOfDay(for: record.date)
            if let last = days.last, last.0 == day {
                days[days.count - 1].1.append(record)
            } else {
                days.append((day, [record]))
            }
        }
        sections += days.map { Section(kind: .day($0.0), records: $0.1) }
        return sections
    }

    /// The records in the order the panel shows them, for the arrow keys
    /// and ⌘1 to ⌘9.
    static func ordered(_ sections: [Section]) -> [ForkDictationRecord] {
        sections.flatMap(\.records)
    }

    /// The words of a search, folded the way the text is: case and accents
    /// ignored, so "resume" finds « résumé ».
    static func searchTokens(_ query: String) -> [String] {
        folded(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Every word must appear, in the text, the text as heard, or the app it
    /// went to.
    static func matches(_ record: ForkDictationRecord, tokens: [String]) -> Bool {
        let haystack = folded([record.text, record.rawText, record.targetName ?? ""].joined(separator: "\n"))
        return tokens.allSatisfy { haystack.contains($0) }
    }

    /// "m:ss", like the bubble's clock.
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
