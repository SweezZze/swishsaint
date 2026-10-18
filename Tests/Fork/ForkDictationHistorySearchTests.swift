// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// How the dictations window sorts, groups and searches the history.
enum ForkDictationHistorySearchTests {
    static func run(_ suite: TestSuite) {
        typealias Listing = ForkDictationHistoryListing
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12))!
        func record(_ text: String, hoursAgo: Double, pinned: Bool = false, raw: String = "",
                    target: String? = nil) -> ForkDictationRecord {
            ForkDictationRecord(date: noon.addingTimeInterval(-hoursAgo * 3600), duration: 3, engine: "parakeet",
                                language: nil, rawText: raw, text: text, outcome: .pasted, targetName: target,
                                isPinned: pinned, hasAudio: true)
        }
        let a = record("Bonjour Hector", hoursAgo: 1)
        let b = record("Résumé du rendez-vous", hoursAgo: 3, target: "Mail")
        let c = record("Ancien", hoursAgo: 30, pinned: true)
        let d = record("Hier soir", hoursAgo: 20)
        let records = [d, a, c, b]

        let sections = Listing.sections(records, query: "", calendar: calendar)
        suite.expect(sections.first?.kind == .pinned && sections.first?.records == [c],
                     "pinned dictations come first, whatever their day")
        suite.expect(sections.count == 3, "then one section per day: today and yesterday")
        suite.expect(sections[1].records == [a, b], "a day lists its dictations newest first")
        suite.expect(sections[1].kind == .day(calendar.startOfDay(for: noon)), "the day section is named by its start")
        suite.expect(sections[2].records == [d], "yesterday's dictation in its own section")
        suite.expect(Listing.ordered(sections) == [c, a, b, d], "the arrow keys follow the order shown")

        let accents = Listing.sections(records, query: "resume", calendar: calendar)
        suite.expect(accents.count == 1 && accents[0].kind == .results && accents[0].records == [b],
                     "a search ignores accents and case, and lists matches without days")
        suite.expect(Listing.sections(records, query: "rendez mail", calendar: calendar).first?.records == [b],
                     "every word must match, the target app counts")
        suite.expect(Listing.sections(records, query: "  ", calendar: calendar).count == 3,
                     "a blank search is no search")
        suite.expect(Listing.sections(records, query: "zzz", calendar: calendar).isEmpty,
                     "no match gives no section")
        let heard = record("Écrit", hoursAgo: 2, raw: "entendu autrement")
        suite.expect(Listing.sections([heard], query: "autrement", calendar: calendar).first?.records == [heard],
                     "the text as heard is searched too")
        suite.expect(Listing.duration(0) == "0:00" && Listing.duration(61.4) == "1:01" && Listing.duration(-3) == "0:00",
                     "durations read m:ss")
    }
}
