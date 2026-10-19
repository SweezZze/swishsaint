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
        ownMedia(suite)
        caseOnly(suite)
        renameTable(suite)
        renamedRow(suite)
        lock(suite)
        rescans(suite)
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

    // MARK: - M.4 The meeting's own media

    private static func ownMedia(_ suite: TestSuite) {
        let old = "2026-10-19 11h30 — Point"
        let new = "2026-10-19 11h30 — Point Acme"
        // A clip saved beside the meeting's video, whose name sorts first.
        let names = ["\(old) extrait.mp4", "\(old).mp4", "\(old).m4a", "meeting.json"]
        let renames = ForkMeetingFolder.mediaRenames(from: old, to: new, names: names)
        suite.expect(renames.moves == [ForkMeetingFolder.Move(from: "\(old).mp4", to: "\(new).mp4"),
                                       ForkMeetingFolder.Move(from: "\(old).m4a", to: "\(new).m4a")]
                        && renames.blocked.isEmpty,
                     "a rename moves the files named after the old folder, never a clip saved beside them")
        var sidecar = meeting(startedAt: date(2026, 10, 19, 11, 30), title: "Point")
        sidecar.titleSource = .user
        let plan = ForkMeetingRename.plan(title: "Point Acme", folderName: old, sidecar: .success(sidecar), names: names,
                                          live: false, calendar: paris, occupant: { _ in .free })
        if case let .success(made) = plan {
            suite.expect(made.folder == ForkMeetingFolder.Move(from: old, to: new)
                            && made.media.moves.map(\.from) == ["\(old).mp4", "\(old).m4a"],
                         "the folder's plan names the targets after the new name, the sources after the old one")
        } else {
            suite.expect(false, "the meeting with a clip beside it can be renamed")
        }
        let byHand = ForkMeetingFolder.mediaRenames(from: old, to: new, names: ["Rush.mp4", "meeting.json"])
        suite.expect(byHand.moves == [ForkMeetingFolder.Move(from: "Rush.mp4", to: "\(new).mp4")],
                     "a video renamed by hand, alone in its folder, still follows the folder")
    }

    // MARK: - M.5 A change of case alone

    private static func caseOnly(_ suite: TestSuite) {
        let lower = "2026-10-19 10h02 — point hebdo"
        let upper = "2026-10-19 10h02 — Point hebdo"
        let names = ["\(lower).mp4", "\(lower).m4a", "meeting.json"]
        var sidecar = meeting(startedAt: date(2026, 10, 19, 10, 2), title: "point hebdo")
        sidecar.titleSource = .user
        // APFS: every case of the name is the folder itself.
        let disk: (String) -> ForkMeetingFolder.Occupant = { $0.lowercased() == lower.lowercased() ? .sameMeeting : .free }
        func plan(_ occupant: @escaping (String) -> ForkMeetingFolder.Occupant) -> ForkMeetingRename.Plan? {
            try? ForkMeetingRename.plan(title: "Point hebdo", folderName: lower, sidecar: .success(sidecar), names: names,
                                        live: false, calendar: paris, occupant: occupant).get()
        }
        let unaware = plan(disk)
        suite.expect(unaware?.folder?.to == upper + " (2)",
                     "asked of the disk alone, the folder's own name in another case looks taken")
        let made = plan(ForkMeetingRename.occupant(sameFolder: { $0.lowercased() == lower.lowercased() }, disk: disk))
        suite.expect(made?.folder == ForkMeetingFolder.Move(from: lower, to: upper) && made?.folderKept == nil,
                     "a change of case alone renames the folder to the same name in the new case, without a number")
        suite.expect(made?.media.moves == [ForkMeetingFolder.Move(from: "\(lower).mp4", to: "\(upper).mp4"),
                                           ForkMeetingFolder.Move(from: "\(lower).m4a", to: "\(upper).m4a")]
                        && made?.media.blocked.isEmpty == true,
                     "and its media follow: a file is never in the way of a change of case of its own name")
        let other = ForkMeetingFolder.mediaRenames(from: lower, to: upper, names: names + ["\(upper).MP4"])
        suite.expect(other.blocked == ["\(lower).mp4"] && other.moves.map(\.from) == ["\(lower).m4a"],
                     "on a volume that tells cases apart, another file holding the new name still blocks the move")
    }

    // MARK: - M.2 Writes during a rename

    private static func renameTable(_ suite: TestSuite) {
        var table = ForkMeetingRenameTable()
        suite.expect(table.resolve("/M/a") == "/M/a", "a folder never renamed is written where it is")
        table.record(from: "/M/a", to: "/M/b")
        suite.expect(table.resolve("/M/a") == "/M/b" && table.resolve("/M/b") == "/M/b",
                     "a note sent to the old name while the folder moved lands in the renamed folder")
        table.record(from: "/M/b", to: "/M/c")
        suite.expect(table.resolve("/M/a") == "/M/c", "through two renames in a row")
        table.record(from: "/M/c", to: "/M/a")
        suite.expect(table.resolve("/M/a") == "/M/a" && table.resolve("/M/b") == "/M/a",
                     "a folder renamed back to an old name never loops")
        table.forget("/M/b")
        table.forget("/M/c")
        suite.expect(table.moves.isEmpty && table.resolve("/M/b") == "/M/b",
                     "once the window writes to the new name, the old one is free again for another folder")
        var same = ForkMeetingRenameTable()
        same.record(from: "/M/a", to: "/M/a")
        suite.expect(same.moves.isEmpty, "a rename that kept the name records nothing")
    }

    private static func renamedRow(_ suite: TestSuite) {
        let old = "2026-10-18 10h02 — Weekly sync"
        let new = "2026-10-18 10h02 — Point Acme"
        guard let row = entry(meeting(), folderName: old) else {
            suite.expect(false, "the row is built")
            return
        }
        let moved = row.renamed(to: new, media: [ForkMeetingFolder.Move(from: "\(old).mp4", to: "\(new).mp4")],
                                title: "Point Acme")
        suite.expect(moved.folderName == new && moved.video == "\(new).mp4" && moved.playable == "\(new).mp4"
                        && moved.audio == "\(old).m4a" && moved.title == "Point Acme",
                     "a renamed row shows its new folder, its media under the names they now have, and its title")
        suite.expect(moved.identity == row.identity && moved.id == row.id && moved.notes == row.notes,
                     "it is the same meeting for the detail: its fields, focus and player stay")
        suite.expect(row.renamed(to: old, media: [], title: "").title == nil
                        && row.renamed(to: old, media: [], title: nil).title == "Weekly sync",
                     "a cleared title shows the default name; a title not saved stays as it was")
        if let unreadable = ForkMeetingLibraryEntry(folderName: old, sidecar: .failure(.corrupt("x")),
                                                    contents: contents(folderName: old), calendar: paris) {
            suite.expect(unreadable.identity != row.identity && unreadable.identity.contains(old),
                         "a record without an id is kept by its folder's name")
        }
        suite.expect(ForkMeetingRename.folderLags(folderName: old, startedAt: date(2026, 10, 18), title: "Point Acme",
                                                  calendar: paris)
                        && !ForkMeetingRename.folderLags(folderName: new, startedAt: date(2026, 10, 18), title: "Point Acme",
                                                         calendar: paris)
                        && !ForkMeetingRename.folderLags(folderName: "Rangé à la main", startedAt: date(2026, 10, 18),
                                                         title: "Point Acme", calendar: paris)
                        && !ForkMeetingRename.folderLags(folderName: old, startedAt: nil, title: "Point Acme", calendar: paris)
                        && ForkMeetingRename.folderLags(folderName: "2026-10-18 10h02 — point acme",
                                                        startedAt: date(2026, 10, 18), title: "Point Acme", calendar: paris),
                     "committing the title renames a folder that lags behind it, even with nothing typed; never one filed by hand")
    }

    // MARK: - M.3 Reading again only what changed

    private static func rescans(_ suite: TestSuite) {
        let root = "/Users/x/Movies/Réunions"
        suite.expect(ForkMeetingLibrary.rescan(paths: ["\(root)/\(folder)/"], root: root) == .folders([folder])
                        && ForkMeetingLibrary.rescan(paths: ["\(root)/\(folder)"], root: root + "/") == .folders([folder]),
                     "a note saved in a meeting's folder reads that folder alone")
        suite.expect(ForkMeetingLibrary.rescan(paths: ["\(root)/A/", "\(root)/B/.recording.mp4"], root: root) == .folders(["A", "B"]),
                     "changes in two meetings read those two")
        suite.expect(ForkMeetingLibrary.rescan(paths: ["\(root)/A/", "\(root)/"], root: root) == .all
                        && ForkMeetingLibrary.rescan(paths: [root], root: root) == .all
                        && ForkMeetingLibrary.rescan(paths: ["/Users/x/Movies/Other/A/"], root: root) == .all
                        && ForkMeetingLibrary.rescan(paths: [], root: root) == .all,
                     "a folder added, renamed or gone in the meetings folder, or anything unexpected, reads everything")
        suite.expect(ForkMeetingLibrary.Rescan.folders(["A"]).merged(with: .folders(["B"])) == .folders(["A", "B"])
                        && ForkMeetingLibrary.Rescan.folders(["A"]).merged(with: .all) == .all
                        && ForkMeetingLibrary.Rescan.all.merged(with: .folders(["B"])) == .all,
                     "asks gathered while a scan runs add up; one for everything wins")
        let rows = [meeting(), meeting(), meeting()].enumerated().compactMap { index, sidecar in
            entry(sidecar, folderName: "f\(index)")
        }
        guard rows.count == 3, let fresh = entry(meeting(title: "Nouveau"), folderName: "f1") else {
            suite.expect(false, "the rows are built")
            return
        }
        let merged = ForkMeetingLibrary.merged(rows, scanned: ["f1", "f2"], with: [fresh])
        suite.expect(merged.map(\.folderName) == ["f0", "f1"] && merged[1].title == "Nouveau" && merged[0] == rows[0],
                     "a folder read again replaces its row, one gone leaves the list, the others stay as they were")
    }

    // MARK: - M.m The lock of another copy

    private static func lock(_ suite: TestSuite) {
        func contents(master: Bool = false, draft: Bool = false) -> ForkMeetingFolder.Contents {
            var names = ["\(folder).mp4", "meeting.json"]
            if master { names.append(ForkMeetingFolder.masterName) }
            if draft { names.append(ForkMeetingFolder.videoDraftName) }
            return ForkMeetingFolder.contents(of: names, folderName: folder)
        }
        func state(_ value: ForkMeetingSidecar.State?) -> Result<ForkMeetingSidecar, ForkMeetingSidecarFault> {
            var sidecar = meeting()
            sidecar.state = value
            return .success(sidecar)
        }
        suite.expect(ForkMeetingLibraryLock.mayBeHeldElsewhere(state(.recording), contents: contents(master: true))
                        && ForkMeetingLibraryLock.mayBeHeldElsewhere(state(.finalizing), contents: contents())
                        && ForkMeetingLibraryLock.mayBeHeldElsewhere(state(.interrupted), contents: contents()),
                     "an unfinished meeting, interrupted included, is asked about before the library writes to it")
        suite.expect(ForkMeetingLibraryLock.mayBeHeldElsewhere(state(.complete), contents: contents(master: true))
                        && ForkMeetingLibraryLock.mayBeHeldElsewhere(state(.complete), contents: contents(draft: true))
                        && !ForkMeetingLibraryLock.mayBeHeldElsewhere(state(.complete), contents: contents())
                        && ForkMeetingLibraryLock.mayBeHeldElsewhere(.failure(.corrupt("x")), contents: contents()),
                     "a complete meeting with leftovers of a recording is asked about too; a clean one is not")
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
