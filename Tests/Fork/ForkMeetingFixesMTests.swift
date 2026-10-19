// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The library's corrections after its review: the automatic bin judges
/// only this app's meetings, by their real age and never in bulk on its
/// own; a rename takes the meeting's own media under the new name, and a
/// change of case alone keeps the folder; what is typed during a rename
/// follows it; the window reads again only what changed.
enum ForkMeetingFixesMTests {
    static func run(_ suite: TestSuite) {
        foreignRecords(suite)
        age(suite)
        clock(suite)
        bulk(suite)
        texts(suite)
    }

    private static let languages = AppLanguage.allCases

    private static let paris: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10, _ minute: Int = 2) -> Date {
        paris.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
            ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    private static let folder = "2026-10-18 10h02 — Weekly sync"

    private static func contents(names: [String]? = nil, folderName: String = folder) -> ForkMeetingFolder.Contents {
        ForkMeetingFolder.contents(of: names ?? ["\(folderName).mp4", "\(folderName).m4a", ForkMeetingFolder.sidecarName],
                                   folderName: folderName)
    }

    private static func meeting(startedAt: Date = date(2026, 10, 18), endedAt: Date? = nil,
                                title: String? = "Weekly sync") -> ForkMeetingSidecar {
        var sidecar = ForkMeetingSidecar.started(id: UUID(), startedAt: startedAt, origin: .offered, title: title,
                                                 titleSource: .window, capture: ForkMeetingSidecar.Capture())
        sidecar.state = .complete
        sidecar.endedAt = endedAt ?? startedAt.addingTimeInterval(3120)
        sidecar.recordedSeconds = 3120
        return sidecar
    }

    private static func entry(_ sidecar: ForkMeetingSidecar, folderName: String = folder,
                              videoModified: Date? = nil) -> ForkMeetingLibraryEntry? {
        ForkMeetingLibraryEntry(folderName: folderName, sidecar: .success(sidecar),
                                contents: contents(folderName: folderName), videoModified: videoModified,
                                calendar: paris)
    }

    private static func decoded(_ json: String) -> ForkMeetingSidecar? {
        try? ForkMeetingSidecar.decode(Data(json.utf8)).get()
    }

    // MARK: - M.1 Only this app's meetings

    private static func foreignRecords(_ suite: TestSuite) {
        let now = date(2026, 11, 18, 9, 0)
        // What the review found: any JSON object called meeting.json, from
        // another app, read as a complete meeting and sent to the Trash.
        guard let other = decoded(#"{"endedAt":"2025-01-10T10:00:00Z","kind":"other app"}"#),
              let otherRow = entry(other, folderName: "Projet client") else {
            suite.expect(false, "another app's meeting.json is listed")
            return
        }
        suite.expect(!other.isWrittenByMeetings && otherRow.isForeign && otherRow.isReadOnly,
                     "a meeting.json without this app's schema and id is someone else's: listed, read only")
        suite.expect(ForkMeetingRetention.verdict(otherRow, days: 30, now: now, calendar: paris) == .keep(.notWrittenHere)
                        && ForkMeetingRetention.due([otherRow], days: 30, now: now, calendar: paris).isEmpty,
                     "the automatic bin never takes a folder whose meeting.json this app did not write, however old")
        var noID = meeting(startedAt: date(2025, 1, 1))
        noID.id = nil
        var noSchema = meeting(startedAt: date(2025, 1, 1))
        noSchema.schema = nil
        let ours = meeting(startedAt: date(2025, 1, 1))
        suite.expect(!noID.isWrittenByMeetings && !noSchema.isWrittenByMeetings && ours.isWrittenByMeetings
                        && entry(noID).map { ForkMeetingRetention.verdict($0, days: 30, now: now, calendar: paris) }
                            == .keep(.notWrittenHere)
                        && entry(noSchema).map { ForkMeetingRetention.verdict($0, days: 30, now: now, calendar: paris) }
                            == .keep(.notWrittenHere)
                        && entry(ours).map { ForkMeetingRetention.verdict($0, days: 30, now: now, calendar: paris) } == .trash,
                     "this app always writes a schema and an id: missing either, the record is not its own")
        suite.expect(ForkMeetingSidecarEdit.rewriting(.success(other), with: ForkMeetingSidecarEdit(notes: "x")) == nil
                        && ForkMeetingSidecarEdit.rewriting(.success(noID), with: ForkMeetingSidecarEdit(notes: "x")) == nil
                        && ForkMeetingSidecarEdit.rewriting(.success(ours), with: ForkMeetingSidecarEdit(notes: "x"))?.notes == "x",
                     "the library never rewrites another app's meeting.json, not even for notes")
        let plan = ForkMeetingRename.plan(title: "Renommée", folderName: "Projet client", sidecar: .success(other),
                                          names: ["rush.mp4", "meeting.json"], live: false, calendar: paris,
                                          occupant: { _ in .free })
        suite.expect(plan == .failure(.notWrittenHere),
                     "nor renames its folder or its files for a title")
    }

    // MARK: - M.1 Age

    private static func age(_ suite: TestSuite) {
        let now = date(2026, 11, 18, 9, 0)
        func verdict(_ row: ForkMeetingLibraryEntry?) -> ForkMeetingRetention.Verdict? {
            row.map { ForkMeetingRetention.verdict($0, days: 30, now: now, calendar: paris) }
        }
        let old = meeting(startedAt: date(2026, 10, 1))
        suite.expect(verdict(entry(old, videoModified: date(2026, 11, 10))) == .keep(.recent),
                     "a video written later than its record says makes the meeting younger: it counts from the disk's date")
        suite.expect(verdict(entry(old, videoModified: date(2020, 1, 1))) == .trash
                        && verdict(entry(meeting(startedAt: date(2026, 11, 1)), videoModified: date(2020, 1, 1))) == .keep(.recent),
                     "an older date on the disk (a copy, a restore) never makes a meeting older than its record")
        suite.expect(verdict(entry(old)) == .trash, "without a date on the disk, the record's end alone counts")
    }

    // MARK: - M.1 Clocks

    private static func clock(_ suite: TestSuite) {
        let rows = (1...40).compactMap { day in
            entry(meeting(startedAt: date(2026, 1, 1).addingTimeInterval(Double(day) * 86_400)),
                  folderName: String(format: "2026-01-%02d 10h02 — M", day))
        }
        // Three years ahead: everything is old.
        let ahead = date(2029, 11, 18)
        let dueAhead = ForkMeetingRetention.due(rows, days: 365, now: ahead, calendar: paris)
        suite.expect(dueAhead.count == 40 && ForkMeetingRetention.sweep(due: dueAhead, library: rows.count) == .held(40),
                     "a clock years ahead makes the whole library due, and the sweep takes none of it on its own")
        // Set back: every meeting is in the future.
        let behind = date(2025, 6, 1)
        let dueBehind = ForkMeetingRetention.due(rows, days: 30, now: behind, calendar: paris)
        suite.expect(dueBehind.isEmpty && ForkMeetingRetention.sweep(due: dueBehind, library: rows.count) == .nothing
                        && rows.allSatisfy { ForkMeetingRetention.verdict($0, days: 30, now: behind, calendar: paris) == .keep(.recent) },
                     "a clock set back finds every meeting recent: nothing goes")
    }

    // MARK: - M.1 Never in bulk

    private static func bulk(_ suite: TestSuite) {
        func names(_ count: Int) -> [String] { (0..<count).map { "m\($0)" } }
        suite.expect(ForkMeetingRetention.sweep(due: names(10), library: 100) == .trash(names(10))
                        && ForkMeetingRetention.sweep(due: names(11), library: 100) == .held(11),
                     "ten meetings at once go; an eleventh holds the sweep, whatever the library's size")
        suite.expect(ForkMeetingRetention.sweep(due: names(10), library: 40) == .trash(names(10))
                        && ForkMeetingRetention.sweep(due: names(3), library: 11) == .held(3)
                        && ForkMeetingRetention.sweep(due: names(1), library: 4) == .trash(names(1))
                        && ForkMeetingRetention.sweep(due: names(2), library: 4) == .held(2),
                     "a quarter of the library goes; more than a quarter holds the sweep")
        suite.expect(ForkMeetingRetention.sweep(due: [], library: 0) == .nothing
                        && ForkMeetingRetention.sweep(due: names(1), library: 1) == .held(1),
                     "nothing due does nothing; the last meeting of a library is never taken unasked")
        suite.expect(ForkMeetingRetention.sweep(due: names(37), library: 40, confirmed: 37) == .trash(names(37))
                        && ForkMeetingRetention.sweep(due: names(30), library: 40, confirmed: 37) == .trash(names(30))
                        && ForkMeetingRetention.sweep(due: names(38), library: 40, confirmed: 37) == .held(38),
                     "once the person agreed to a number, that many go; more found by then asks again")
    }

    // MARK: - Texts

    private static func texts(_ suite: TestSuite) {
        let all = languages.map { ($0, ForkMeetingStrings.strings($0)) }
        suite.expect(all.allSatisfy { _, text in
                        let many = text.retentionHeld(count: 37, days: 30)
                        let one = text.retentionHeld(count: 1, days: 90)
                        return many.contains("37") && many.contains("30") && one.contains("90") && !one.contains("%")
                            && !text.retentionHeldCaption.isEmpty && !text.renameTitleNotSaved.isEmpty
                            && text.statusForeign.contains("meeting.json")
                     },
                     "a held sweep says how many meetings and how old, one meeting included, in every language")
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(french.retentionHeld(count: 37, days: 30) == "37\u{00A0}réunions de plus de 30\u{00A0}jours\u{00A0}: les mettre à la Corbeille\u{00A0}?"
                        && ForkMeetingStrings.strings(.enUS).retentionHeld(count: 1, days: 30)
                            == "1 meeting older than 30 days: move it to the Trash?",
                     "in French: « 37 réunions de plus de 30 jours : les mettre à la Corbeille ? »")
    }
}
