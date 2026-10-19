// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The library's rows, days, search, renaming, saved typing, automatic bin
/// and editor copy: all decided from facts, so every case is written here
/// without a disk or a clock.
enum ForkMeetingLibraryTests {
    static func run(_ suite: TestSuite) {
        entries(suite)
        stamps(suite)
        order(suite)
        days(suite)
        headings(suite)
        search(suite)
        statusWords(suite)
        renaming(suite)
        edits(suite)
        coalescing(suite)
        retention(suite)
        editorCopy(suite)
        texts(suite)
        latestFolders(suite)
    }

    private static let english = ForkMeetingStrings.strings(.enUS)
    private static let languages = AppLanguage.allCases

    private static func zone(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .current
        return calendar
    }

    private static let paris = zone("Europe/Paris")

    /// A time on the wall in `calendar`'s zone.
    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10, _ minute: Int = 2,
                             in calendar: Calendar = paris) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return calendar.date(from: parts) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    private static func sidecar(state: ForkMeetingSidecar.State? = .complete, title: String? = "Weekly sync",
                                startedAt: Date? = date(2026, 10, 18), endedAt: Date? = nil,
                                recorded: Double? = 3120, provider: String? = "meet",
                                meetCode: String? = "abc-defg-hij", notes: String? = "",
                                recovered: Bool? = false, stopReason: ForkMeetingStopReason? = nil,
                                finalPass: ForkMeetingSidecar.FinalPass? = nil,
                                schema: Int = ForkMeetingSidecar.currentSchema,
                                titleSource: ForkMeetingSidecar.TitleSource? = .window) -> ForkMeetingSidecar {
        var meeting = ForkMeetingSidecar.started(id: UUID(), startedAt: startedAt ?? Date(), origin: .manual,
                                                 title: title, titleSource: titleSource,
                                                 capture: ForkMeetingSidecar.Capture())
        meeting.schema = schema
        meeting.state = state
        meeting.startedAt = startedAt
        meeting.endedAt = endedAt ?? startedAt.map { $0.addingTimeInterval(3120) }
        meeting.recordedSeconds = recorded
        meeting.provider = provider
        meeting.meetCode = meetCode
        meeting.notes = notes
        meeting.recovered = recovered
        meeting.stopReason = stopReason
        meeting.finalPass = finalPass
        return meeting
    }

    private static let folder = "2026-10-18 10h02 — Weekly sync"

    private static func contents(video: Bool = true, audio: Bool = true, master: Bool = false,
                                 sidecar: Bool = true) -> ForkMeetingFolder.Contents {
        var names: [String] = []
        if video { names.append("\(folder).mp4") }
        if audio { names.append("\(folder).m4a") }
        if master { names.append(ForkMeetingFolder.masterName) }
        if sidecar { names.append(ForkMeetingFolder.sidecarName) }
        return ForkMeetingFolder.contents(of: names, folderName: folder)
    }

    private static func entry(_ meeting: ForkMeetingSidecar = sidecar(), folderName: String = folder,
                              contents: ForkMeetingFolder.Contents = contents(), live: Bool = false,
                              videoSeconds: Double? = nil, folderCreated: Date? = nil) -> ForkMeetingLibraryEntry? {
        ForkMeetingLibraryEntry(folderName: folderName, sidecar: .success(meeting), contents: contents, live: live,
                                bytes: 410_000_000, videoSeconds: videoSeconds, folderCreated: folderCreated,
                                calendar: paris)
    }

    // MARK: - Rows

    private static func entries(_ suite: TestSuite) {
        suite.expect(ForkMeetingLibraryEntry(folderName: "Holiday photos", sidecar: .failure(.absent),
                                             contents: ForkMeetingFolder.Contents(), calendar: paris) == nil
                        && ForkMeetingLibraryEntry(folderName: folder, sidecar: .success(sidecar()),
                                                   contents: contents(sidecar: false), calendar: paris) == nil,
                     "a folder without meeting.json is not a meeting, and the library leaves it out")

        let complete = entry()
        suite.expect(complete?.status == .complete && complete?.title == "Weekly sync"
                        && complete?.seconds == 3120 && complete?.bytes == 410_000_000
                        && complete?.playable == "\(folder).mp4" && complete?.audio == "\(folder).m4a"
                        && complete?.provider == "meet" && complete?.meetCode == "abc-defg-hij"
                        && complete?.dateSource == .sidecar && complete?.isReadOnly == false,
                     "a finished meeting shows its title, length, size, provider and code, and plays its video")
        suite.expect(entry(sidecar(recovered: true))?.status == .recovered
                        && entry(sidecar(recovered: true))?.status.isFlagged == true
                        && complete?.status.isFlagged == false,
                     "a meeting recovered after a crash is complete but flagged ⚠")

        let crashed = entry(sidecar(state: .recording), contents: contents(video: false, master: true))
        suite.expect(crashed?.status == .interrupted(.stopped(.crash))
                        && crashed?.playable == ForkMeetingFolder.masterName,
                     "a sidecar left recording by a crash reads as interrupted by a crash, and its master still plays")
        suite.expect(entry(sidecar(state: .interrupted, stopReason: .quit))?.status == .interrupted(.stopped(.quit))
                        && entry(sidecar(state: .interrupted, stopReason: .disk, finalPass: .failed))?.status
                            == .interrupted(.finalPassFailed)
                        && entry(sidecar(state: .interrupted, stopReason: .user))?.status == .interrupted(.unknown)
                        && entry(sidecar(state: .interrupted))?.status == .interrupted(.unknown),
                     "an interrupted meeting says why: its stop, a final pass that failed twice, or nothing it can tell")

        let recording = entry(sidecar(state: .recording), contents: contents(video: false, master: true), live: true)
        suite.expect(recording?.status == .recording && recording?.playable == nil
                        && recording?.status.isInProgress == true,
                     "the meeting being recorded is not interrupted, and its master is not offered to the player")
        suite.expect(entry(sidecar(state: .finalizing), live: true)?.status == .finalizing
                        && entry(sidecar(state: .finalizing))?.status == .finalizing
                        && entry(sidecar(state: .finalizing))?.playable == nil,
                     "a final pass running, or cut short and waiting for the next launch, reads as finishing")
        suite.expect(entry(sidecar(state: .complete), live: true)?.status == .recording,
                     "a folder this app is busy with is in progress whatever its sidecar says")

        let unreadable = ForkMeetingLibraryEntry(folderName: folder, sidecar: .failure(.corrupt("bad")),
                                                 contents: contents(), videoSeconds: 61, calendar: paris)
        suite.expect(unreadable?.status == .unreadable && unreadable?.title == "Weekly sync"
                        && unreadable?.date == date(2026, 10, 18) && unreadable?.dateSource == .folderName
                        && unreadable?.seconds == 61 && unreadable?.isReadOnly == true
                        && unreadable?.playable == "\(folder).mp4" && unreadable?.startedAt == nil,
                     "an unreadable meeting.json still gives a row, named and dated from its folder, read-only")
        suite.expect(entry(sidecar(schema: ForkMeetingSidecar.currentSchema + 1))?.isReadOnly == true
                        && entry(sidecar(schema: ForkMeetingSidecar.currentSchema + 1))?.status == .complete,
                     "a meeting from a later version is shown but never written")
        suite.expect(entry(sidecar(state: nil))?.status == .complete
                        && entry(sidecar(state: nil), contents: contents(video: false))?.status == .interrupted(.unknown),
                     "a state this version does not know reads as complete with a video, interrupted without, never hidden")

        suite.expect(entry(sidecar(recorded: 0), videoSeconds: 75)?.seconds == 75
                        && entry(sidecar(recorded: nil), videoSeconds: nil)?.seconds == nil
                        && entry(sidecar(recorded: 42), videoSeconds: 75)?.seconds == 42,
                     "the length is the seconds recorded, or the video's when the sidecar never got to say")
        suite.expect(entry(sidecar(title: "  Point hebdo \n"))?.title == "Point hebdo"
                        && entry(sidecar(title: "   "))?.title == nil
                        && entry(sidecar(title: nil))?.displayTitle(english) == english.untitledMeeting
                        && entry(sidecar(title: nil))?.displayTitle(.strings(.fr)) == ForkMeetingStrings.strings(.fr).untitledMeeting,
                     "a blank title shows the default name, in the language of whoever looks")

        let created = date(2026, 3, 1)
        let undatedSidecar = entry(sidecar(startedAt: nil), folderName: "Filed by hand", folderCreated: created)
        suite.expect(entry(sidecar(startedAt: nil))?.date == date(2026, 10, 18)
                        && entry(sidecar(startedAt: nil))?.dateSource == .folderName
                        && undatedSidecar?.date == created && undatedSidecar?.dateSource == .folderCreated
                        && entry(sidecar(startedAt: nil), folderName: "Filed by hand")?.date == nil,
                     "without a start in its sidecar, a row is dated from its folder's name, then its creation")
        suite.expect(entry(sidecar(notes: "Budget: 12 k€"))?.notes == "Budget: 12 k€"
                        && entry(sidecar(notes: nil))?.notes == "",
                     "the notes come with the row")
    }

    private static func stamps(_ suite: TestSuite) {
        suite.expect(ForkMeetingLibrary.stampDate("2026-10-18 10h02 — Weekly sync", calendar: paris) == date(2026, 10, 18)
                        && ForkMeetingLibrary.stampDate("2026-10-18 10h02", calendar: paris) == date(2026, 10, 18),
                     "the stamp a folder starts with is read back at its minute")
        let tokyo = zone("Asia/Tokyo")
        suite.expect(ForkMeetingLibrary.stampDate("2026-10-18 17h02", calendar: tokyo)
                        == Date(timeIntervalSince1970: 1_792_310_520),
                     "the stamp is read in the time zone it was written in")
        suite.expect(["Weekly sync", "2026-13-18 10h02", "2026-02-30 10h02", "2026-10-18 24h00", "2026-10-18 10:02",
                      "2026-1O-18 10h02", "２０２６-10-18 10h02", "2026-10-18"].allSatisfy {
                        ForkMeetingLibrary.stampDate($0, calendar: paris) == nil
                     },
                     "a name without a real stamp gives no date: no month 13, no February 30, no colon, no other digits")
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = paris.timeZone
        suite.expect(ForkMeetingLibrary.stampDate(folder, calendar: japanese) == date(2026, 10, 18),
                     "a Mac set to the Japanese calendar reads the Gregorian stamp as it was written")
        suite.expect(ForkMeetingLibrary.folderTitle(folder) == "Weekly sync"
                        && ForkMeetingLibrary.folderTitle("2026-10-18 10h02 — Weekly sync (2)") == "Weekly sync (2)"
                        && ForkMeetingLibrary.folderTitle("2026-10-18 10h02") == nil
                        && ForkMeetingLibrary.folderTitle("Acme — archive") == "Acme — archive",
                     "the title in a folder's name is what follows its stamp; a folder renamed by hand is its own title")
    }

    private static func order(_ suite: TestSuite) {
        let older = entry(sidecar(startedAt: date(2026, 10, 17)), folderName: "b")
        let newer = entry(sidecar(startedAt: date(2026, 10, 18)), folderName: "a")
        let twinA = entry(sidecar(startedAt: date(2026, 10, 16)), folderName: "x")
        let twinB = entry(sidecar(startedAt: date(2026, 10, 16)), folderName: "y")
        let undated = entry(sidecar(startedAt: nil), folderName: "z")
        let rows = [undated, older, twinA, newer, twinB].compactMap { $0 }
        suite.expect(ForkMeetingLibrary.sorted(rows).map(\.folderName) == ["a", "b", "y", "x", "z"],
                     "newest first, a stable order for meetings of the same minute, undated ones last")
    }

    // MARK: - Days

    private static func days(_ suite: TestSuite) {
        let now = date(2026, 10, 18, 9, 0)
        func day(_ when: Date?) -> ForkMeetingLibrary.Day { ForkMeetingLibrary.day(of: when, now: now, calendar: paris) }
        suite.expect(day(date(2026, 10, 18, 0, 1)) == .today && day(date(2026, 10, 18, 23, 59)) == .today
                        && day(date(2026, 10, 17, 23, 59)) == .yesterday && day(date(2026, 10, 17, 0, 0)) == .yesterday,
                     "today and yesterday are calendar days, not the last 24 hours")
        suite.expect(day(date(2026, 10, 16)) == .weekday(date(2026, 10, 16, 0, 0))
                        && day(date(2026, 10, 12)) == .weekday(date(2026, 10, 12, 0, 0))
                        && day(date(2026, 10, 11)) == .date(date(2026, 10, 11, 0, 0), sameYear: true),
                     "two to six days ago reads as a weekday; a week ago reads as a date")
        suite.expect(day(date(2025, 12, 31)) == .date(date(2025, 12, 31, 0, 0), sameYear: false)
                        && day(date(2026, 10, 25)) == .date(date(2026, 10, 25, 0, 0), sameYear: true)
                        && day(nil) == .undated,
                     "a meeting of another year says its year; one in the future (a clock set wrong) its date")
        // Summer time ends in Paris on October 25, 2026: that day has 25 hours.
        let afterChange = date(2026, 10, 26, 8, 0)
        suite.expect(ForkMeetingLibrary.day(of: date(2026, 10, 25, 23, 30), now: afterChange, calendar: paris) == .yesterday
                        && ForkMeetingLibrary.day(of: date(2026, 10, 25, 0, 30), now: afterChange, calendar: paris) == .yesterday,
                     "a day of 25 hours is still one day")
        let instant = Date(timeIntervalSince1970: 1_792_367_400) // 2026-10-18 23:50 UTC
        suite.expect(ForkMeetingLibrary.day(of: instant, now: instant.addingTimeInterval(600), calendar: zone("Asia/Tokyo")) == .today
                        && ForkMeetingLibrary.day(of: instant, now: date(2026, 10, 19, 9, 0, in: zone("Asia/Tokyo")),
                                                  calendar: zone("Asia/Tokyo")) == .today
                        && ForkMeetingLibrary.day(of: instant, now: date(2026, 10, 19, 9, 0, in: zone("UTC")),
                                                  calendar: zone("UTC")) == .yesterday,
                     "days are counted in the time zone given, not in the tests' own")
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = paris.timeZone
        suite.expect(ForkMeetingLibrary.day(of: date(2025, 12, 31), now: now, calendar: buddhist)
                        == .date(date(2025, 12, 31, 0, 0), sameYear: false),
                     "whatever calendar the Mac uses, days are Gregorian days")

        let rows = [
            entry(sidecar(startedAt: date(2026, 10, 18, 8, 40)), folderName: "t2"),
            entry(sidecar(startedAt: date(2026, 10, 17, 16, 0)), folderName: "y1"),
            entry(sidecar(startedAt: date(2026, 10, 18, 10, 2)), folderName: "t1"),
            entry(sidecar(startedAt: date(2026, 9, 1)), folderName: "old"),
            entry(sidecar(startedAt: nil), folderName: "none"),
            entry(sidecar(startedAt: date(2026, 10, 15)), folderName: "w1"),
        ].compactMap { $0 }
        let groups = ForkMeetingLibrary.groups(rows, now: now, calendar: paris)
        suite.expect(groups.map(\.day) == [.today, .yesterday, .weekday(date(2026, 10, 15, 0, 0)),
                                           .date(date(2026, 9, 1, 0, 0), sameYear: true), .undated]
                        && groups.map { $0.entries.map(\.folderName) } == [["t1", "t2"], ["y1"], ["w1"], ["old"], ["none"]],
                     "rows are grouped under their day, newest day first, newest meeting first inside it")
        suite.expect(ForkMeetingLibrary.groups([], now: now, calendar: paris).isEmpty,
                     "an empty library has no headings")
    }

    private static func headings(_ suite: TestSuite) {
        func heading(_ day: ForkMeetingLibrary.Day, _ language: AppLanguage) -> String {
            ForkMeetingLibrary.heading(day, strings: .strings(language), language: language, calendar: paris)
        }
        suite.expect(heading(.today, .enUS) == "Today" && heading(.yesterday, .fr) == "Hier"
                        && heading(.undated, .enUS) == english.groupUndated,
                     "today, yesterday and undated are the library's own words")
        let wednesday = ForkMeetingLibrary.Day.weekday(date(2026, 10, 14, 0, 0))
        suite.expect(heading(wednesday, .enUS) == "Wednesday" && heading(wednesday, .fr) == "Mercredi"
                        && heading(wednesday, .es) == "Miércoles",
                     "a weekday is named in the app's language, its first letter raised for a heading")
        let sameYear = heading(.date(date(2026, 9, 1, 0, 0), sameYear: true), .fr)
        let otherYear = heading(.date(date(2025, 12, 31, 0, 0), sameYear: false), .enUS)
        suite.expect(sameYear.contains("1") && sameYear.contains("eptembre") && !sameYear.contains("2026")
                        && otherYear.contains("December") && otherYear.contains("31") && otherYear.contains("2025"),
                     "an older day says its date, and its year only when it is not this one: \(sameYear), \(otherYear)")
        suite.expect(languages.allSatisfy { !heading(wednesday, $0).isEmpty && heading(wednesday, $0) != heading(.today, $0) },
                     "every language names its weekdays")
    }

    // MARK: - Search

    private static func search(_ suite: TestSuite) {
        guard let row = entry(sidecar(title: "Closing L’Étoile & Fils", notes: "Budget validé, relancer Zoë")) else {
            suite.expect(false, "the search row is built")
            return
        }
        func finds(_ query: String, _ entry: ForkMeetingLibraryEntry = row) -> Bool {
            ForkMeetingLibrary.matches(entry, query: query, strings: english,
                                       providerName: { $0 == "meet" ? "Google Meet" : nil })
        }
        suite.expect(finds("closing") && finds("CLOSING") && finds("etoile") && finds("ÉTOILE") && finds("Étoile"),
                     "the search ignores case and accents")
        let decomposed = "E\u{0301}toile"
        suite.expect(finds(decomposed) && finds("zoe") && finds("Zoe\u{0308}"),
                     "an accent typed as a separate mark (NFD) finds the precomposed letter, and the other way round")
        suite.expect(finds("l'etoile") && finds("l’étoile"), "a straight apostrophe finds a typographic one")
        suite.expect(finds("budget relancer") && finds("relancer   closing") && !finds("budget dropped"),
                     "several words must all be there, in any order and any field")
        suite.expect(finds("meet") && finds("google") && finds("abc-defg-hij") && finds("abcdefghij") && finds("defg"),
                     "a meeting is found by its provider, its provider's name and its Meet code, with or without dashes")
        suite.expect(finds("2026-10-18") && finds("10h02"), "and by its folder's name")
        suite.expect(finds("") && finds("   "), "an empty search keeps every row")
        suite.expect(!finds("zanzibar"), "a word found nowhere hides the row")
        suite.expect(finds("ｃｌｏｓｉｎｇ"), "full-width letters find their usual ones")
        if let untitled = entry(sidecar(title: nil, notes: "")) {
            suite.expect(ForkMeetingLibrary.matches(untitled, query: english.untitledMeeting, strings: english),
                         "a meeting without a title is found by the name it shows")
        }
        let rows = [row, entry(sidecar(title: "Démo client"), folderName: "other")].compactMap { $0 }
        suite.expect(ForkMeetingLibrary.filtered(rows, query: "demo", strings: english).map(\.folderName) == ["other"]
                        && ForkMeetingLibrary.filtered(rows, query: "", strings: english).count == 2,
                     "filtering keeps only the rows that match")
    }

    private static func statusWords(_ suite: TestSuite) {
        let causes: [ForkMeetingLibraryEntry.Cause] = ForkMeetingStopReason.allCases.map { .stopped($0) }
            + [.finalPassFailed, .unknown]
        let statuses: [ForkMeetingLibraryEntry.Status] = [.recovered, .recording, .finalizing, .unreadable]
            + causes.map { .interrupted($0) }
        var tooLong: [String] = []
        for language in languages {
            let strings = ForkMeetingStrings.strings(language)
            for status in statuses {
                let text = ForkMeetingLibrary.statusText(status, strings: strings) ?? ""
                if text.isEmpty || text.count > 28 { tooLong.append("\(language.rawValue): \(text)") }
            }
        }
        suite.expect(tooLong.isEmpty, "every status beside a row is said in 28 characters at most, cause included: \(tooLong)")
        suite.expect(ForkMeetingLibrary.statusText(.complete, strings: english) == nil,
                     "a complete meeting needs no word")
        suite.expect(ForkMeetingLibrary.statusText(.interrupted(.stopped(.crash)), strings: english) == "Interrupted: crash"
                        && ForkMeetingLibrary.statusText(.interrupted(.stopped(.crash)), strings: .strings(.fr))
                            == "Interrompue\u{00A0}: plantage"
                        && ForkMeetingLibrary.statusText(.recovered, strings: .strings(.fr)) == "Récupérée",
                     "an interrupted meeting says why, in the person's language")
        let distinct = Set([ForkMeetingStopReason.crash, .quit, .disk, .permission, .sleep, .featureDisabled, .captureStopped]
            .map { ForkMeetingLibrary.causeText(.stopped($0), strings: english) }
            + [ForkMeetingLibrary.causeText(.finalPassFailed, strings: english)])
        suite.expect(distinct.count == 8, "each cause has its own words")
    }

    // MARK: - Renaming

    private static func renaming(_ suite: TestSuite) {
        let names = ["\(folder).mp4", "\(folder).m4a", "meeting.json"]
        func plan(_ title: String, _ meeting: ForkMeetingSidecar = sidecar(), folderName: String = folder,
                  live: Bool = false, taken: Set<String> = [],
                  read: Result<ForkMeetingSidecar, ForkMeetingSidecarFault>? = nil)
            -> Result<ForkMeetingRename.Plan, ForkMeetingRename.Refusal> {
            ForkMeetingRename.plan(title: title, folderName: folderName, sidecar: read ?? .success(meeting),
                                   names: names, live: live, calendar: paris,
                                   occupant: { taken.contains($0) ? .taken : .free })
        }
        let target = "2026-10-18 10h02 — Point hebdo Acme"
        guard case let .success(renamed) = plan("Point hebdo Acme") else {
            suite.expect(false, "a meeting at rest can be renamed")
            return
        }
        suite.expect(renamed.edit == ForkMeetingSidecarEdit(title: "Point hebdo Acme")
                        && renamed.folder == ForkMeetingFolder.Move(from: folder, to: target)
                        && renamed.folderKept == nil
                        && renamed.media.moves == [ForkMeetingFolder.Move(from: "\(folder).mp4", to: "\(target).mp4"),
                                                   ForkMeetingFolder.Move(from: "\(folder).m4a", to: "\(target).m4a")]
                        && renamed.media.blocked.isEmpty,
                     "a new title renames the folder and its media together, each keeping its extension")
        if case let .success(twin) = plan("Point hebdo Acme", taken: [target]) {
            suite.expect(twin.folder?.to == target + " (2)" && twin.media.moves.first?.to == target + " (2).mp4",
                         "a name already used gets the next free one, and the media follow it")
        }
        let all = Set(ForkMeetingFolder.candidates(base: target))
        if case let .success(full) = plan("Point hebdo Acme", taken: all) {
            suite.expect(full.folder == nil && full.folderKept == .namesExhausted && full.edit != nil,
                         "with fifty folders of that name, the title changes and the folder keeps its own")
        }

        suite.expect(plan("Anything", live: true) == .failure(.meetingInProgress)
                        && plan("Anything", sidecar(state: .recording)) == .failure(.meetingInProgress)
                        && plan("Anything", sidecar(state: .finalizing)) == .failure(.meetingInProgress),
                     "nothing is renamed while a meeting is recorded or finished in that folder, by this app or another")
        suite.expect(plan("Anything", read: .failure(.corrupt("x"))) == .failure(.sidecarUnreadable)
                        && plan("Anything", read: .failure(.unreadable("x"))) == .failure(.sidecarUnreadable)
                        && plan("Anything", sidecar(schema: ForkMeetingSidecar.currentSchema + 1))
                            == .failure(.sidecarFromLaterVersion),
                     "an unreadable sidecar or one from a later version is never rewritten for a title")
        if case let .success(byHand) = plan("Point hebdo", folderName: "Acme — archive") {
            suite.expect(byHand.folder == nil && byHand.folderKept == .renamedByHand
                            && byHand.edit == ForkMeetingSidecarEdit(title: "Point hebdo") && byHand.media.moves.isEmpty,
                         "a folder renamed by hand keeps its name and its media theirs; only the title changes")
        }
        if case let .success(noStart) = plan("Point hebdo", sidecar(startedAt: nil)) {
            suite.expect(noStart.folder == nil && noStart.folderKept == .renamedByHand,
                         "without a start to check the stamp against, the folder is left as it is")
        }
        if case let .success(cleared) = plan("   ") {
            suite.expect(cleared.edit == ForkMeetingSidecarEdit(title: "") && cleared.folder == nil
                            && cleared.folderKept == .noTitle,
                         "an empty title clears it, the default name shows again, and the folder stays as written")
        }
        if case let .success(slashes) = plan("/::/") {
            suite.expect(slashes.folder == nil && slashes.folderKept == .noTitle && slashes.edit?.title == "/::/",
                         "a title with nothing a file name can hold is kept as a title only")
        }
        let named = sidecar(title: "Weekly sync", titleSource: .user)
        if case let .success(same) = plan("Weekly sync", named) {
            suite.expect(same.edit == nil && same.folder == nil && same.folderKept == .alreadyNamed,
                         "the same title again changes nothing")
        }
        if case let .success(confirmed) = plan("Weekly sync") {
            suite.expect(confirmed.edit == ForkMeetingSidecarEdit(title: "Weekly sync") && confirmed.folder == nil,
                         "keeping a window's title as it is makes it the person's: no window may rename it later")
        }
        if case let .success(twoLines) = plan("Point\nhebdo  ") {
            suite.expect(twoLines.edit?.title == "Point hebdo" && twoLines.folder?.to == "2026-10-18 10h02 — Point hebdo",
                         "a title is one line, without blanks around it")
        }
        let clash = ForkMeetingRename.plan(title: "Point hebdo", folderName: folder, sidecar: .success(sidecar()),
                                           names: ["\(folder).mp4", "2026-10-18 10h02 — point hebdo.MP4", "meeting.json"],
                                           live: false, calendar: paris, occupant: { _ in .free })
        if case let .success(blocked) = clash {
            suite.expect(blocked.folder != nil && blocked.media.moves.isEmpty && blocked.media.blocked == ["\(folder).mp4"],
                         "a medium whose new name is already used in the folder is left alone, and said")
        }
    }

    private static func edits(_ suite: TestSuite) {
        let meeting = sidecar(title: "Weekly sync", notes: "old", titleSource: .window)
        let titled = ForkMeetingSidecarEdit(title: "Point hebdo").applied(to: meeting)
        suite.expect(titled.title == "Point hebdo" && titled.titleSource == .user && titled.notes == "old"
                        && titled.state == meeting.state && titled.recordedSeconds == meeting.recordedSeconds,
                     "a title given in the library is the person's, and nothing else changes")
        let cleared = ForkMeetingSidecarEdit(title: "").applied(to: meeting)
        suite.expect(cleared.title == nil && cleared.titleSource == nil, "an empty title clears the title and its source")
        let noted = ForkMeetingSidecarEdit(notes: "  Budget\n").applied(to: meeting)
        suite.expect(noted.notes == "  Budget\n" && noted.title == "Weekly sync" && noted.titleSource == .window,
                     "notes are kept exactly as typed")
        suite.expect(ForkMeetingSidecarEdit.rewriting(.failure(.corrupt("x")), with: ForkMeetingSidecarEdit(notes: "a")) == nil
                        && ForkMeetingSidecarEdit.rewriting(.failure(.absent), with: ForkMeetingSidecarEdit(notes: "a")) == nil
                        && ForkMeetingSidecarEdit.rewriting(.success(sidecar(schema: ForkMeetingSidecar.currentSchema + 1)),
                                                            with: ForkMeetingSidecarEdit(notes: "a")) == nil,
                     "a corrupt, missing or later sidecar is never rewritten for an edit")
        let json = Data(#"{"schema":1,"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","state":"complete","title":"A","partner":{"job":"7"},"capture":{"fps":30}}"#.utf8)
        if case let .success(read) = ForkMeetingSidecar.decode(json),
           let written = ForkMeetingSidecarEdit.rewriting(.success(read), with: ForkMeetingSidecarEdit(notes: "n")),
           let data = try? written.encoded(), case let .success(back) = ForkMeetingSidecar.decode(data) {
            suite.expect(back.notes == "n" && back.preserved["partner"] == .object(["job": .string("7")])
                            && back.capture?.preserved["fps"] == .number(30),
                         "an edit keeps every key this version does not know")
        } else {
            suite.expect(false, "an edited sidecar round-trips")
        }
        suite.expect(ForkMeetingSidecarEdit(title: "a", notes: "b").merged(with: ForkMeetingSidecarEdit(notes: "c"))
                        == ForkMeetingSidecarEdit(title: "a", notes: "c"),
                     "a later edit wins field by field")
    }

    private static func coalescing(_ suite: TestSuite) {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        var coalescer = ForkMeetingEditCoalescer()
        coalescer.note(ForkMeetingSidecarEdit(notes: "B"), in: "f", at: at(0))
        coalescer.note(ForkMeetingSidecarEdit(notes: "Bu"), in: "f", at: at(0.2))
        coalescer.note(ForkMeetingSidecarEdit(title: "Point"), in: "f", at: at(0.4))
        suite.expect(coalescer.nextDeadline == at(0.5) && coalescer.takeDue(at: at(0.49)).isEmpty,
                     "nothing is written at each key: the first change opens a half-second window")
        let first = coalescer.takeDue(at: at(0.5))
        suite.expect(first.count == 1 && first.first?.folder == "f"
                        && first.first?.edit == ForkMeetingSidecarEdit(title: "Point", notes: "Bu")
                        && coalescer.nextDeadline == nil,
                     "everything typed in the window is written once, the latest text of each field")
        var typing = ForkMeetingEditCoalescer()
        var writes = 0
        for step in 0..<40 {
            typing.note(ForkMeetingSidecarEdit(notes: String(repeating: "a", count: step + 1)), in: "f", at: at(Double(step) * 0.1))
            writes += typing.takeDue(at: at(Double(step) * 0.1)).count
        }
        suite.expect((6...8).contains(writes) && typing.pending.count == 1,
                     "four seconds of steady typing are saved about every half second, never put off until it stops: \(writes)")
        var many = ForkMeetingEditCoalescer()
        many.note(ForkMeetingSidecarEdit(notes: "x"), in: "b", at: at(0))
        many.note(ForkMeetingSidecarEdit(notes: "y"), in: "a", at: at(0.3))
        suite.expect(many.nextDeadline == at(0.5) && many.takeDue(at: at(0.6)).map(\.folder) == ["b"]
                        && many.nextDeadline == at(0.8),
                     "each folder has its own window")
        many.note(ForkMeetingSidecarEdit(notes: "z"), in: "c", at: at(0.6))
        let flushed = many.flush()
        suite.expect(flushed.map(\.folder) == ["a", "c"] && many.pending.isEmpty,
                     "closing the window or quitting writes everything still pending at once")
        var renamed = ForkMeetingEditCoalescer()
        renamed.note(ForkMeetingSidecarEdit(notes: "n"), in: "old", at: at(0))
        renamed.move(from: "old", to: "new")
        suite.expect(renamed.flush("old").isEmpty && renamed.flush("new").first?.edit == ForkMeetingSidecarEdit(notes: "n"),
                     "what is pending follows a renamed folder")
        var trashed = ForkMeetingEditCoalescer()
        trashed.note(ForkMeetingSidecarEdit(notes: "n"), in: "gone", at: at(0))
        trashed.note(ForkMeetingSidecarEdit(), in: "empty", at: at(0))
        trashed.forget("gone")
        suite.expect(trashed.pending.isEmpty && trashed.nextDeadline == nil,
                     "a folder sent to the Trash has nothing left to write, and an empty edit opens no window")
    }

    // MARK: - The automatic bin

    private static func retention(_ suite: TestSuite) {
        suite.expect(ForkMeetingRetention.choices == [0, 30, 90, 365]
                        && ForkMeetingRetention.sanitized(30) == 30 && ForkMeetingRetention.sanitized(365) == 365
                        && ForkMeetingRetention.sanitized(7) == 0 && ForkMeetingRetention.sanitized(-1) == 0
                        && ForkMeetingRetention.sanitized(100_000) == 0,
                     "only the delays the page offers count; anything else, from a backup or by hand, empties nothing")
        let now = date(2026, 11, 18, 9, 0)
        func verdict(_ meeting: ForkMeetingSidecar, days: Int = 30, live: Bool = false,
                     contents: ForkMeetingFolder.Contents = contents()) -> ForkMeetingRetention.Verdict? {
            entry(meeting, contents: contents, live: live).map {
                ForkMeetingRetention.verdict($0, days: days, now: now, calendar: paris)
            }
        }
        // Thirty days after October 19 is November 18: still there all day.
        let october18 = sidecar(startedAt: date(2026, 10, 18, 23, 0), endedAt: date(2026, 10, 18, 23, 50))
        let october19 = sidecar(startedAt: date(2026, 10, 19, 0, 5))
        suite.expect(verdict(october18) == .trash && verdict(october19) == .keep(.recent),
                     "a meeting goes once more than thirty whole days have passed since its day, whatever its hour")
        let lateNight = sidecar(startedAt: date(2026, 10, 18, 23, 30), endedAt: date(2026, 10, 19, 0, 40))
        suite.expect(verdict(lateNight) == .keep(.recent), "a meeting is as old as the day it ended")
        suite.expect(verdict(october18, days: 0) == .keep(.off) && verdict(october18, days: 7) == .keep(.off)
                        && verdict(october18, days: 90) == .keep(.recent),
                     "off, an unknown delay or a longer one takes nothing")
        suite.expect(verdict(sidecar(state: .recording, startedAt: date(2025, 1, 1)), live: true) == .keep(.inProgress)
                        && verdict(sidecar(state: .finalizing, startedAt: date(2025, 1, 1))) == .keep(.inProgress)
                        && verdict(sidecar(startedAt: date(2025, 1, 1)), live: true) == .keep(.inProgress),
                     "a meeting being recorded or finished is never old")
        suite.expect(verdict(sidecar(startedAt: date(2025, 1, 1), recovered: true)) == .keep(.flagged)
                        && verdict(sidecar(state: .interrupted, startedAt: date(2025, 1, 1), stopReason: .crash)) == .keep(.flagged)
                        && verdict(sidecar(state: .recording, startedAt: date(2025, 1, 1)),
                                   contents: contents(video: false, master: true)) == .keep(.flagged),
                     "a meeting flagged ⚠ waits for the person's hand, however old")
        if let unreadable = ForkMeetingLibraryEntry(folderName: "2025-01-01 10h02 — Old", sidecar: .failure(.corrupt("x")),
                                                    contents: contents(), calendar: paris) {
            suite.expect(ForkMeetingRetention.verdict(unreadable, days: 30, now: now, calendar: paris) == .keep(.flagged),
                         "an unreadable meeting is never taken, even with an old stamp in its name")
        }
        suite.expect(verdict(sidecar(startedAt: date(2025, 1, 1), schema: ForkMeetingSidecar.currentSchema + 1))
                        == .keep(.laterVersion),
                     "a later version's meeting is not this one's to judge")
        if let noDate = entry(sidecar(startedAt: nil), folderCreated: date(2020, 1, 1)) {
            suite.expect(noDate.date != nil && ForkMeetingRetention.verdict(noDate, days: 30, now: now, calendar: paris)
                            == .keep(.undated),
                         "an age is never guessed from a folder's name or its dates on the disk")
        }
        suite.expect(verdict(sidecar(startedAt: date(2026, 11, 18, 8, 0))) == .keep(.recent)
                        && verdict(sidecar(startedAt: date(2027, 1, 1))) == .keep(.recent),
                     "today's meetings stay, and so does one dated in the future by a clock set wrong")

        let rows = [
            entry(october18, folderName: "old"),
            entry(october19, folderName: "recent"),
            entry(sidecar(startedAt: date(2026, 1, 1)), folderName: "older"),
            entry(sidecar(startedAt: date(2026, 1, 2)), folderName: "busy"),
        ].compactMap { $0 }
        suite.expect(ForkMeetingRetention.due(rows, days: 30, now: now, live: ["busy"], calendar: paris) == ["old", "older"],
                     "a sweep takes the old meetings and leaves the one the app is busy with")
        suite.expect(ForkMeetingRetention.isSweepDue(lastSweep: nil, now: now)
                        && !ForkMeetingRetention.isSweepDue(lastSweep: now.addingTimeInterval(-3600), now: now)
                        && ForkMeetingRetention.isSweepDue(lastSweep: now.addingTimeInterval(-86_400), now: now)
                        && ForkMeetingRetention.isSweepDue(lastSweep: now.addingTimeInterval(3600), now: now),
                     "a sweep at launch, then once a day; a clock moved back sweeps again")
        suite.expect(ForkMeetingRetention.needsConfirmation(from: 0, to: 30, due: 3)
                        && ForkMeetingRetention.needsConfirmation(from: 365, to: 90, due: 1)
                        && !ForkMeetingRetention.needsConfirmation(from: 0, to: 30, due: 0)
                        && !ForkMeetingRetention.needsConfirmation(from: 30, to: 90, due: 5)
                        && !ForkMeetingRetention.needsConfirmation(from: 30, to: 0, due: 5),
                     "turning the bin on or shortening it asks first when it would take something now")
    }

    // MARK: - The editor's copy

    private static func editorCopy(_ suite: TestSuite) {
        guard let complete = entry() else { return }
        let final = ForkMeetingEditorCopy.plan(complete, audioTracks: 3, editorAvailable: true)
        suite.expect(final == .success(ForkMeetingEditorCopy.Plan(source: "\(folder).mp4", audio: .withoutMix)),
                     "the editor gets a copy of the final video without its mix, so it never hears the participants twice")
        if case let .success(plan) = final {
            suite.expect(ForkMeetingEditorCopy.keptAudioTracks(plan, count: 3) == [1, 2],
                         "the copy keeps the meeting then the microphone, the order the editor reads as its two sources")
        }
        let skipped = ForkMeetingEditorCopy.plan(complete, audioTracks: 2, editorAvailable: true)
        suite.expect(skipped == .success(ForkMeetingEditorCopy.Plan(source: "\(folder).mp4", audio: .asIs))
                        && ForkMeetingEditorCopy.plan(complete, audioTracks: nil, editorAvailable: true)
                            == .success(ForkMeetingEditorCopy.Plan(source: "\(folder).mp4", audio: .asIs))
                        && ForkMeetingEditorCopy.keptAudioTracks(ForkMeetingEditorCopy.Plan(source: "x", audio: .asIs), count: 2) == [0, 1],
                     "a file that kept the master's two tracks, or one the store could not count, is cloned as it is")
        if let crashed = entry(sidecar(state: .interrupted, stopReason: .crash), contents: contents(video: false, master: true)) {
            suite.expect(ForkMeetingEditorCopy.plan(crashed, audioTracks: 3, editorAvailable: true)
                            == .success(ForkMeetingEditorCopy.Plan(source: ForkMeetingFolder.masterName, audio: .asIs)),
                         "an interrupted meeting with only its master offers a copy of the master")
        }
        if let recording = entry(sidecar(state: .recording), contents: contents(video: false, master: true), live: true) {
            suite.expect(ForkMeetingEditorCopy.plan(recording, audioTracks: 2, editorAvailable: true) == .failure(.meetingInProgress)
                            && ForkMeetingEditorCopy.plan(complete, audioTracks: 3, editorAvailable: true, live: true)
                                == .failure(.meetingInProgress),
                         "a meeting being written is never copied half-way")
        }
        suite.expect(ForkMeetingEditorCopy.plan(complete, audioTracks: 3, editorAvailable: false) == .failure(.editorUnavailable),
                     "with Screen recording off there is no editor to open")
        if let audioOnly = entry(contents: contents(video: false)) {
            suite.expect(ForkMeetingEditorCopy.plan(audioOnly, audioTracks: nil, editorAvailable: true) == .failure(.noVideo),
                         "a meeting without a video has nothing to trim")
        }
    }

    // MARK: - Texts

    private static func texts(_ suite: TestSuite) {
        let short: [KeyPath<ForkMeetingStrings, String>] = [
            \.groupToday, \.groupYesterday, \.groupUndated, \.columnTitle, \.columnDuration, \.columnSize,
            \.columnApp, \.columnMeetCode, \.actionRename, \.actionExportAudio, \.actionCopyPath, \.actionTrash,
            \.actionTrim, \.noticePathCopied, \.statusRecovered, \.statusUnreadable, \.searchPlaceholder, \.emptyTitle,
            \.notesPlaceholder, \.retentionTitle, \.retentionNever, \.openLibrary, \.actionShowMeeting, \.actionMore,
            \.playerNoVideo, \.causeCancelled,
        ]
        var tooLong: [String] = []
        for language in languages {
            let strings = ForkMeetingStrings.strings(language)
            for path in short where strings[keyPath: path].count > 28 {
                tooLong.append("\(language.rawValue): \(strings[keyPath: path])")
            }
            for days in ForkMeetingRetention.choices where days > 0 && strings.retentionDays(days).count > 28 {
                tooLong.append("\(language.rawValue): \(strings.retentionDays(days))")
            }
        }
        suite.expect(tooLong.isEmpty, "the library's headings, columns, actions and choices fit in 28 characters: \(tooLong)")
        let all = languages.map(ForkMeetingStrings.strings)
        suite.expect(all.allSatisfy { $0.confirmTrash("Point hebdo").contains("Point hebdo")
                        && $0.searchNoResults("zanzibar").contains("zanzibar")
                        && $0.statusInterrupted("x").contains("x")
                        && $0.retentionDays(365).contains("365") },
                     "every language names the meeting, the search, the cause and the delay it is about")
        suite.expect(all.allSatisfy { strings in
                        let text = strings.retentionConfirm(count: 12, days: 90)
                        return text.contains("12") && text.contains("90")
                            && text.range(of: "90")?.lowerBound != text.range(of: "12")?.lowerBound
                     } && english.retentionConfirm(count: 12, days: 90).hasPrefix("Meetings older than 90 days: 12."),
                     "the confirmation says how many meetings and how old, each number in its place")
        suite.expect(all.allSatisfy { $0.actionExportAudio.contains("M4A") },
                     "the export is the audio file alone, until the exporters come")
        suite.expect(all.allSatisfy { strings in
                        let actions = [strings.actionRename, strings.actionExportAudio, strings.actionCopyPath,
                                       strings.actionTrash, strings.actionTrim, strings.actionShow]
                        return Set(actions).count == actions.count
                     },
                     "every action of the menu has its own words in every language")
        suite.expect(ForkMeetingStrings.strings(.fr).actionTrim == "Couper dans l’éditeur"
                        && ForkMeetingStrings.strings(.fr).retentionTitle == "Corbeille automatique"
                        && ForkMeetingStrings.strings(.fr).actionTrash == "Placer dans la corbeille",
                     "in French: Couper dans l’éditeur, Corbeille automatique, Placer dans la corbeille")
    }

    // MARK: - Folders the recorder leaves today

    /// The states the recorder writes since the library's rules were first
    /// set: a cancel whose folder stayed, a final pass that failed and waits
    /// for its last try, with or without its master to show.
    private static func latestFolders(_ suite: TestSuite) {
        let now = date(2027, 3, 1)
        if let cancelled = entry(sidecar(state: .interrupted, stopReason: .cancelled)) {
            suite.expect(cancelled.status == .interrupted(.stopped(.cancelled)) && cancelled.status.isFlagged
                            && ForkMeetingLibrary.statusText(cancelled.status, strings: english) == "Interrupted: cancelled"
                            && ForkMeetingRetention.verdict(cancelled, days: 30, now: now, calendar: paris) == .keep(.flagged),
                         "a cancelled recording whose folder could not go yet is listed, flagged, and left to the next launch")
        }
        let failed = sidecar(state: .finalizing, finalPass: .failed)
        if let shown = entry(failed, contents: contents(master: true)) {
            suite.expect(shown.status == .interrupted(.finalPassFailed) && shown.playable == "\(folder).mp4"
                            && ForkMeetingEditorCopy.plan(shown, audioTracks: 2, editorAvailable: true)
                                == .success(ForkMeetingEditorCopy.Plan(source: "\(folder).mp4", audio: .asIs))
                            && ForkMeetingRetention.verdict(shown, days: 30, now: now, calendar: paris) == .keep(.flagged),
                         "a final pass that failed is flagged, its master shown under the meeting's name plays and is copied as it is")
        }
        if let missing = entry(failed, contents: contents(video: false, audio: false)) {
            suite.expect(missing.status == .interrupted(.finalPassFailed) && missing.playable == nil,
                         "a final pass that failed with no master left has nothing to play")
        }
        let renamed = ForkMeetingRename.plan(title: "Budget \u{202E}xslx.4pm", folderName: folder,
                                             sidecar: .success(sidecar()), names: [], live: false, calendar: paris,
                                             occupant: { _ in .free })
        if case let .success(plan) = renamed {
            let title = plan.edit?.title ?? ""
            let name = plan.folder?.to ?? ""
            suite.expect(title == "Budget xslx.4pm" && !name.unicodeScalars.contains { $0.value == 0x202E }
                            && name.hasSuffix("Budget xslx.4pm"),
                         "a title cannot reorder what the row or the folder's name shows")
        } else {
            suite.expect(false, "a title with a bidi override is still a title")
        }
        suite.expect(ForkMeetingRename.plan(title: "New", folderName: folder, sidecar: .success(failed), names: [],
                                            live: false, calendar: paris, occupant: { _ in .free })
                        == .failure(.meetingInProgress),
                     "a meeting whose last try is still to come keeps its folder's name until then")
    }
}
