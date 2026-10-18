// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Ported from bran's MeetingFolderTests, plus renaming and the root folder.
enum ForkMeetingFolderTests {
    static func run(_ suite: TestSuite) {
        stamps(suite)
        names(suite)
        fileSystemLimit(suite)
        sanitizing(suite)
        reserving(suite)
        contents(suite)
        renaming(suite)
        root(suite)
    }

    /// Built from components, never from an ISO string: the stamp reads the
    /// Mac's time zone, and 9:57 must be 9:57 wherever the tests run. In the
    /// Gregorian calendar, as the stamp is, whatever the Mac's calendar.
    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return Calendar(identifier: .gregorian).date(from: parts) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    private static func stamps(_ suite: TestSuite) {
        suite.expect(ForkMeetingFolder.stamp(date(2026, 1, 5, 9, 7)) == "2026-01-05 09h07"
                        && ForkMeetingFolder.stamp(date(2026, 10, 18, 10, 2)) == "2026-10-18 10h02"
                        && ForkMeetingFolder.stamp(date(2026, 12, 31, 23, 59)) == "2026-12-31 23h59"
                        && ForkMeetingFolder.stamp(date(2026, 8, 11, 0, 0)) == "2026-08-11 00h00",
                     "the stamp is zero-padded, year first")
        let stamps = (0..<24).map { ForkMeetingFolder.stamp(date(2026, 8, 11, $0, 30)) }
        suite.expect(stamps.allSatisfy { !$0.contains(":") && !$0.contains("/") },
                     "a stamp never holds a colon, which the Finder shows as a slash, nor a slash")
        let chronological = [date(2025, 12, 31, 23, 59), date(2026, 1, 1, 0, 0), date(2026, 1, 5, 9, 7),
                             date(2026, 1, 5, 9, 8), date(2026, 1, 5, 10, 0), date(2026, 2, 1, 8, 0),
                             date(2026, 8, 11, 9, 57), date(2026, 10, 1, 8, 0), date(2026, 12, 31, 23, 59)]
        let sorted = chronological.map { ForkMeetingFolder.stamp($0) }
        suite.expect(sorted.sorted() == sorted, "sorting folders by name sorts meetings by date")
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let instant = Date(timeIntervalSince1970: 1_792_310_520) // 2026-10-18 08:02 UTC
        suite.expect(ForkMeetingFolder.stamp(instant, calendar: tokyo) == "2026-10-18 17h02",
                     "the stamp is the time of whoever held the meeting, in their time zone")
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = tokyo.timeZone
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = tokyo.timeZone
        suite.expect(ForkMeetingFolder.stamp(instant, calendar: japanese) == "2026-10-18 17h02"
                        && ForkMeetingFolder.stamp(instant, calendar: buddhist) == "2026-10-18 17h02"
                        && ForkMeetingFolder.name(startedAt: instant, title: "Point", calendar: japanese) == "2026-10-18 17h02 — Point",
                     "a Mac set to the Japanese or Buddhist calendar still writes the Gregorian year, so names keep sorting by date")
    }

    private static func names(_ suite: TestSuite) {
        let start = date(2026, 8, 11, 9, 57)
        suite.expect(ForkMeetingFolder.name(startedAt: start, title: "SA ACME") == "2026-08-11 09h57 — SA ACME",
                     "with a title, the stamp still leads")
        let blank: [String?] = [nil, "", "     ", "..."]
        suite.expect(blank.allSatisfy { ForkMeetingFolder.name(startedAt: start, title: $0) == "2026-08-11 09h57" },
                     "without a title that survives, the stamp alone, never a name ending in a dash")
        suite.expect(ForkMeetingFolder.name(startedAt: start, title: "Closing L'Étoile & Fils")
                        == "2026-08-11 09h57 — Closing L'Étoile & Fils",
                     "an ordinary title goes through untouched")
        let sixty = String(repeating: "é", count: 60)
        suite.expect(ForkMeetingFolder.name(startedAt: start, title: sixty).hasSuffix(sixty),
                     "sixty accented letters fit")
    }

    /// Measured by bran on APFS: the limit is 255 UTF-16 units of the
    /// decomposed form. Each name is really created, with the longest
    /// suffix and a media file inside.
    private static func fileSystemLimit(_ suite: TestSuite) {
        let start = date(2026, 8, 11, 9, 57)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForkMeetingFolderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hostile = [
            String(repeating: "👨‍👩‍👧‍👦", count: 60),
            String(repeating: "e" + String(repeating: "\u{0301}", count: 20), count: 60),
            String(repeating: "é", count: 300),
            String(repeating: "a", count: 4000),
        ]
        var created = 0
        for title in hostile {
            let name = ForkMeetingFolder.name(startedAt: start, title: title)
            let target = folder.appendingPathComponent("\(name) (50)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: target.appendingPathComponent("\(name) (50).mp4"))
                if name.hasPrefix("2026-08-11 09h57") { created += 1 }
            } catch {
                suite.expect(false, "\(name.prefix(30))… could not be created: \(error)")
            }
        }
        suite.expect(created == hostile.count,
                     "a title the file system would refuse is brought down to a name that is created, with its media")
        suite.expect(hostile.allSatisfy { ForkMeetingFolder.bytes(ForkMeetingFolder.name(startedAt: start, title: $0))
                                            <= ForkMeetingFolder.byteLimit },
                     "and two such names, the folder and its media, never make a path longer than macOS takes")
        suite.expect(ForkMeetingFolder.units("é") == 2 && ForkMeetingFolder.units("e\u{0301}") == 2
                        && ForkMeetingFolder.units("a") == 1,
                     "a precomposed é weighs two units on the disk")
    }

    private static func sanitizing(_ suite: TestSuite) {
        suite.expect(ForkMeetingFolder.sanitized("Acme/Globex") == "Acme Globex"
                        && ForkMeetingFolder.sanitized("Acme:Globex") == "Acme Globex"
                        && ForkMeetingFolder.sanitized("A/B:C") == "A B C",
                     "a path separator becomes a space, so two words stay two words")
        suite.expect(ForkMeetingFolder.sanitized("Point    hebdo") == "Point hebdo"
                        && ForkMeetingFolder.sanitized("Point\nhebdo") == "Point hebdo"
                        && ForkMeetingFolder.sanitized("Point\t/  hebdo") == "Point hebdo"
                        && ForkMeetingFolder.sanitized("  Point hebdo  ") == "Point hebdo",
                     "runs of spaces and line breaks fold into one space")
        suite.expect(ForkMeetingFolder.sanitized(".RDV") == "RDV" && ForkMeetingFolder.sanitized("..RDV") == "RDV"
                        && ForkMeetingFolder.sanitized("...RDV") == "RDV" && ForkMeetingFolder.sanitized("..") == nil
                        && ForkMeetingFolder.sanitized("R.D.V. LACME") == "R.D.V. LACME",
                     "leading dots, which would hide the folder, go; dots inside stay")
        suite.expect(ForkMeetingFolder.sanitized("Closing L'Étoile & Fils") == "Closing L'Étoile & Fils"
                        && ForkMeetingFolder.sanitized("Réunion « à chaud » — n°3") == "Réunion « à chaud » — n°3",
                     "accents, apostrophes, ampersands and quotes stay as written")
        let cutOnSpace = String(repeating: "a", count: 59) + " " + String(repeating: "b", count: 10)
        suite.expect(ForkMeetingFolder.sanitized(cutOnSpace) == String(repeating: "a", count: 59),
                     "a long title is cut at a space, without a trailing blank")
        suite.expect(ForkMeetingFolder.sanitized(String(repeating: "z", count: 100))?.count == 60
                        && ForkMeetingFolder.sanitized(String(repeating: "c", count: 60)) == String(repeating: "c", count: 60),
                     "a title of one block is cut at sixty characters; one that fits is untouched")
        suite.expect(["", "   ", "\n\t", "///", ":::"].allSatisfy { ForkMeetingFolder.sanitized($0) == nil },
                     "a blank title gives nil, never an empty string")
    }

    private static func reserving(_ suite: TestSuite) {
        let base = "2026-10-18 10h02 — Point hebdo"
        let candidates = ForkMeetingFolder.candidates(base: base)
        suite.expect(candidates.count == 50 && candidates.first == base && candidates[1] == "\(base) (2)"
                        && candidates.last == "\(base) (50)",
                     "a name, then (2) up to (50)")
        suite.expect(ForkMeetingFolder.reserve(base: base) { _ in .free } == .create(base),
                     "a free name is taken as it is")
        suite.expect(ForkMeetingFolder.reserve(base: base) { $0 == base ? .taken : .free } == .create("\(base) (2)"),
                     "two meetings in the same minute with the same title never share a folder")
        suite.expect(ForkMeetingFolder.reserve(base: base) { $0 == base ? .folderWithoutSidecar : .free } == .adopt(base)
                        && ForkMeetingFolder.reserve(base: base) { $0 == base ? .sameMeeting : .free } == .adopt(base),
                     "a folder this meeting already began is taken back, not orphaned")
        suite.expect(ForkMeetingFolder.reserve(base: base, forRename: true) { $0 == base ? .sameMeeting : .free }
                        == .create("\(base) (2)"),
                     "a rename only goes to a name entirely free: folders are never merged")
        suite.expect(ForkMeetingFolder.reserve(base: base) { _ in .taken } == .exhausted,
                     "when fifty names are taken it says so instead of writing into someone else's folder")
    }

    private static func contents(_ suite: TestSuite) {
        let folder = "2026-10-18 10h02 — Point hebdo"
        let found = ForkMeetingFolder.contents(of: ["Renamed in Finder.mp4", "\(folder).m4a", "meeting.json",
                                                    ".recording.mp4", ".finalizing.mp4", "notes.pdf", ".DS_Store"],
                                               folderName: folder)
        suite.expect(found.video == "Renamed in Finder.mp4" && found.audio == "\(folder).m4a" && found.hasSidecar
                        && found.hasMaster && found.hasVideoDraft && !found.hasAudioDraft,
                     "media are found by extension, whatever their name; the master and drafts are recognized")
        let two = ForkMeetingFolder.contents(of: ["a.mp4", "\(folder).mp4", "z.MP4"], folderName: folder)
        suite.expect(two.video == "\(folder).mp4", "of several videos, the one named after the folder is the meeting's")
        let upper = ForkMeetingFolder.contents(of: ["Clip.MP4"], folderName: folder)
        suite.expect(upper.video == "Clip.MP4", "an extension in capitals still counts")
        let hidden = ForkMeetingFolder.contents(of: [".recording.mp4", "._x.mp4"], folderName: folder)
        suite.expect(hidden.video == nil && hidden.audio == nil && !hidden.hasSidecar,
                     "the master and hidden files are never taken for the finished video")
    }

    private static func renaming(_ suite: TestSuite) {
        let start = date(2026, 10, 18, 10, 2)
        let current = "2026-10-18 10h02 — Meeting"
        suite.expect(ForkMeetingFolder.renamedFolder(current: current, startedAt: start, title: "Point hebdo Acme")
                        == "2026-10-18 10h02 — Point hebdo Acme",
                     "a new title renames the folder, the stamp kept")
        suite.expect(ForkMeetingFolder.renamedFolder(current: "Acme — archive", startedAt: start, title: "Point hebdo") == nil,
                     "a folder renamed by hand in the Finder is left as the person filed it")
        suite.expect(ForkMeetingFolder.renamedFolder(current: current, startedAt: start, title: nil) == nil
                        && ForkMeetingFolder.renamedFolder(current: current, startedAt: start, title: "  ") == nil,
                     "without a title, the folder keeps the name it was given")
        suite.expect(ForkMeetingFolder.renamedFolder(current: "2026-10-18 10h02 — Point hebdo (2)", startedAt: start,
                                                     title: "Point hebdo") == nil,
                     "a folder already right, numbered or not, is not renamed again")

        let folder = "2026-10-18 10h02 — Point hebdo Acme"
        let renames = ForkMeetingFolder.mediaRenames(folderName: folder,
                                                     names: ["2026-10-18 10h02 — Meeting.mp4", "2026-10-18 10h02 — Meeting.m4a",
                                                             "meeting.json", ".recording.mp4", "slides.pdf"])
        suite.expect(renames.moves == [.init(from: "2026-10-18 10h02 — Meeting.mp4", to: "\(folder).mp4"),
                                       .init(from: "2026-10-18 10h02 — Meeting.m4a", to: "\(folder).m4a")]
                        && renames.blocked.isEmpty,
                     "the video and the audio take the folder's name; the sidecar, the master and other files stay")
        suite.expect(ForkMeetingFolder.mediaRenames(folderName: folder, names: ["\(folder).mp4", "meeting.json"]).moves.isEmpty,
                     "media already named right are not moved")
        let blocked = ForkMeetingFolder.mediaRenames(folderName: "F", names: ["a.mp4", "f.MP4"])
        suite.expect(blocked.moves.isEmpty && blocked.blocked == ["a.mp4"],
                     "a new name already used in the folder, in any case, leaves both files untouched")
        let clash = ForkMeetingFolder.mediaRenames(folderName: folder, names: ["Old.mp4", "\(folder).mov", "x.m4a", "\(folder).m4a"])
        suite.expect(clash.moves == [.init(from: "Old.mp4", to: "\(folder).mp4")],
                     "each file keeps its own extension; renaming never changes what a file holds")
    }

    private static func root(_ suite: TestSuite) {
        let movies = URL(fileURLWithPath: "/Users/someone/Movies", isDirectory: true)
        let french = ForkMeetingStrings.strings(.fr)
        let fallback = ForkMeetingFolder.root(stored: "", movies: movies, strings: french)
        suite.expect(fallback.url.path == "/Users/someone/Movies/Réunions" && fallback.needsStoring,
                     "by default the meetings go to a folder of Movies named in the person's language, saved at the first recording")
        let english = ForkMeetingFolder.root(stored: "", movies: movies, strings: .strings(.enUS))
        suite.expect(english.url.lastPathComponent == "Meetings", "in English the folder is Meetings")
        let chosen = ForkMeetingFolder.root(stored: "/Volumes/NAS/Calls", movies: movies, strings: french)
        suite.expect(chosen.url.path == "/Volumes/NAS/Calls" && !chosen.needsStoring,
                     "a chosen folder is used as it is, whatever the language")
        let tilde = ForkMeetingFolder.root(stored: "~/Calls", movies: movies, strings: french)
        suite.expect(tilde.url.path.hasSuffix("/Calls") && !tilde.url.path.hasPrefix("~"), "a path with a tilde is expanded")
        let names = AppLanguage.allCases.map { ForkMeetingStrings.strings($0).folderName }
        suite.expect(names.allSatisfy { ForkMeetingFolder.sanitized($0) == $0 && ForkMeetingFolder.units($0) < 64 },
                     "the default folder's name is a valid file name in every language")
        suite.expect(ForkMeetingFolder.displayTitle(nil, strings: french) == "Réunion"
                        && ForkMeetingFolder.displayTitle("  ", strings: .strings(.enUS)) == "Meeting"
                        && ForkMeetingFolder.displayTitle("Point hebdo", strings: french) == "Point hebdo",
                     "a meeting without a name shows the default one, in the language of whoever looks")
    }
}
