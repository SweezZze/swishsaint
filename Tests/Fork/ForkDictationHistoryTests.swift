// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What the dictation history keeps, for how long, and how it is written.
enum ForkDictationHistoryTests {
    static func run(_ suite: TestSuite) {
        retention(suite)
        index(suite)
        shortcuts(suite)
    }

    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let day: TimeInterval = 24 * 3600

    private static func record(daysAgo: Double, pinned: Bool = false, audio: Bool = true) -> ForkDictationRecord {
        ForkDictationRecord(date: now.addingTimeInterval(-daysAgo * day), duration: 3, engine: "parakeet",
                            language: nil, rawText: "bonjour", text: "Bonjour", outcome: .pasted,
                            isPinned: pinned, hasAudio: audio)
    }

    private static func retention(_ suite: TestSuite) {
        let fresh = record(daysAgo: 1)
        let old = record(daysAgo: 8)
        let oldPinned = record(daysAgo: 30, pinned: true)
        let oldSilent = record(daysAgo: 9, audio: false)
        let plan = ForkDictationRetention.plan([fresh, old, oldPinned, oldSilent], now: now)
        suite.expect(plan.dropAudio == [old.id], "audio older than a week goes, pinned or already gone aside")
        suite.expect(plan.dropRecords.isEmpty, "under the cap, every record stays")

        let edge = record(daysAgo: 6.9)
        suite.expect(ForkDictationRetention.plan([edge], now: now).dropAudio.isEmpty, "a week is a full week")

        let cap = ForkDictationRetention.maximumRecords
        var many = (0..<cap).map { record(daysAgo: Double($0) / 100, audio: false) }
        let pinnedOldest = record(daysAgo: 400, pinned: true, audio: false)
        let unpinnedOldest = record(daysAgo: 300, audio: false)
        many += [pinnedOldest, unpinnedOldest]
        let capped = ForkDictationRetention.plan(many, now: now)
        suite.expect(capped.dropRecords.count == 2, "past the cap, only the excess goes")
        suite.expect(capped.dropRecords.contains(unpinnedOldest.id) && !capped.dropRecords.contains(pinnedOldest.id),
                     "the oldest unpinned records go first, pinned ones stay")
        suite.expect(capped.dropAudio.isEmpty, "a record dropped whole is not counted twice")
    }

    private static func index(_ suite: TestSuite) {
        var failed = record(daysAgo: 2)
        failed.outcome = .failed
        failed.failure = "transcriptionFailed"
        failed.targetBundleID = "com.apple.TextEdit"
        failed.clipboardEntryID = UUID()
        let records = [record(daysAgo: 3), failed, record(daysAgo: 0.5, pinned: true)]
        let data = try? ForkDictationIndex.encode(records)
        let decoded = data.flatMap(ForkDictationIndex.decode) ?? []
        suite.expect(decoded.count == 3 && decoded.map(\.id) == records.sorted { $0.date > $1.date }.map(\.id),
                     "the index reads back newest first")
        suite.expect(decoded.first(where: { $0.id == failed.id }) == failed, "every field survives the index")
        suite.expect(ForkDictationIndex.decode(Data("not json".utf8)) == nil,
                     "an unreadable index is said so, to be set aside rather than written over")

        // One record a later version wrote with a field this one does not
        // know, one missing fields, one broken: only the broken one goes.
        let known = record(daysAgo: 1)
        let later = UUID(), sparse = UUID()
        let json = """
        [\(String(decoding: (try? ForkDictationIndex.encode([known])) ?? Data(), as: UTF8.self).dropFirst().dropLast()),
         {"id": "\(later.uuidString)", "text": "Plus tard", "hasAudio": true, "isPinned": true,
          "outcome": "pasted", "newField": {"x": 1}, "date": 1},
         {"id": "\(sparse.uuidString)"},
         {"id": "not a uuid", "text": "lost"},
         {"id": "\(UUID().uuidString)", "outcome": "a future outcome", "text": "Kept"}]
        """
        let partial = ForkDictationIndex.decode(Data(json.utf8)) ?? []
        suite.expect(partial.count == 4, "a record that cannot be read costs only itself (got \(partial.count))")
        suite.expect(partial.contains { $0.id == known.id && $0 == known }, "a known record reads back whole")
        suite.expect(partial.first { $0.id == later }.map { $0.isPinned && $0.text == "Plus tard" } == true,
                     "an unknown field is ignored, the pin stays")
        suite.expect(partial.first { $0.id == sparse }.map { !$0.hasAudio && $0.text.isEmpty } == true,
                     "missing fields take safe defaults")
        suite.expect(partial.contains { $0.text == "Kept" && $0.outcome == .inHistoryOnly },
                     "an outcome this version does not know reads as kept in the history")

        let names = ["\(known.id.uuidString).m4a", "\(UUID().uuidString).m4a", ".x.partial.m4a", "index.json"]
        suite.expect(ForkDictationIndex.orphans(names, records: [known]) == [names[1]],
                     "only audio no record names is an orphan; partial files and the index are left alone")
    }

    private static func shortcuts(_ suite: TestSuite) {
        let history = ForkDictationShortcut(key: .modifier(.rightOption), action: .openHistory)
        suite.expect(history.action.isInstant && history.armingDelay == 0,
                     "the history shortcut acts at once, without arming the microphone")
        suite.expect(!ForkDictationShortcut.Action.paste.isInstant && !ForkDictationShortcut.Action.copy.isInstant,
                     "dictating shortcuts listen")
        let stored = ForkDictationShortcuts.encode([.default, history])
        let read = ForkDictationShortcuts.decode(stored: stored, legacyTrigger: "")
        suite.expect(read.count == 2 && read[1].action == .openHistory, "the history shortcut is saved and read back")
    }
}
