// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// One meeting as the library lists it, made from what its folder holds:
/// the folder's name, its `meeting.json` (or why it could not be read), the
/// media found by extension, and what the store measured (sizes, length).
///
/// Nothing here reads the disk. The store scans, this describes, the window
/// shows: the same facts always give the same row, which is what the tests
/// rely on.
struct ForkMeetingLibraryEntry: Equatable {
    /// What a row says about its meeting, besides its title.
    enum Status: Equatable {
        case complete
        /// Recovered after a crash or a quit: whole and playable, flagged ⚠
        /// so the person knows its end may be missing a few seconds.
        case recovered
        /// Never closed properly and not recovered: flagged ⚠, kept, maybe
        /// with only its master to play.
        case interrupted(Cause)
        /// Being recorded by this app right now.
        case recording
        /// Its final pass runs, or waits for the next launch to run again.
        case finalizing
        /// `meeting.json` is there but will not decode: shown from its folder
        /// alone, and never rewritten.
        case unreadable

        /// The rows marked ⚠.
        var isFlagged: Bool {
            switch self {
            case .recovered, .interrupted, .unreadable: return true
            case .complete, .recording, .finalizing: return false
            }
        }

        /// A meeting this app is still writing: nothing may move, rename or
        /// trash it.
        var isInProgress: Bool { self == .recording || self == .finalizing }
    }

    /// Why an interrupted meeting did not end well, as its row says it.
    enum Cause: Equatable {
        case stopped(ForkMeetingStopReason)
        /// Its final pass failed twice: the master stays as it is.
        case finalPassFailed
        case unknown
    }

    /// Where `date` comes from: the sidecar's start, the stamp the folder's
    /// name begins with, or the folder's creation as the store read it.
    enum DateSource: Equatable {
        case sidecar
        case folderName
        case folderCreated
    }

    /// The folder's name: unique in the meetings folder, so it is what the
    /// list selects. A rename changes it; `identity` stays.
    private(set) var folderName: String
    let id: UUID?
    let status: Status
    /// The title written in `meeting.json`; for a sidecar that cannot be
    /// read, what follows the stamp in the folder's name.
    private(set) var title: String?
    let date: Date?
    let dateSource: DateSource?
    /// The sidecar's own times: only these decide a meeting's age for the
    /// automatic bin, never a guess from a name.
    let startedAt: Date?
    let endedAt: Date?
    /// Seconds recorded, pauses excluded; the video's length when the
    /// sidecar does not say.
    let seconds: Double?
    /// What the folder weighs, as the store measured it.
    let bytes: Int64?
    let provider: String?
    let meetCode: String?
    let notes: String
    /// The file the player opens: the final video, or, for an interrupted
    /// meeting, its master, readable up to its last fragment.
    private(set) var playable: String?
    private(set) var video: String?
    private(set) var audio: String?
    /// From a later version of the app, unreadable, or not written by it:
    /// shown, never written.
    let isReadOnly: Bool
    /// `meeting.json` was not written by this app (`isWrittenByMeetings`).
    let isForeign: Bool
    /// The playable file's date on the disk, as the store read it: it can
    /// only make the meeting younger for the automatic bin.
    let videoModified: Date?
    /// The folder's file number on its volume, as the store read it: a
    /// rename keeps it, a copy (the Finder's Duplicate, same `meeting.json`
    /// and same id) has its own.
    let folderFile: UInt64?

    /// `nil` for a folder without `meeting.json`: what tells a meeting
    /// folder from any other folder in the same place is its sidecar.
    ///
    /// - `live`: this app records or finishes this very folder now (the
    ///   store's claim). A sidecar left in `recording` by a crash is not
    ///   live: it is interrupted until the recovery runs.
    /// - `videoSeconds`: the final video's length, when the store probed it.
    /// - `videoModified`: the date of the file the row plays.
    /// - `folderFile`: the folder's file number.
    init?(folderName: String,
          sidecar: Result<ForkMeetingSidecar, ForkMeetingSidecarFault>,
          contents: ForkMeetingFolder.Contents,
          live: Bool = false,
          bytes: Int64? = nil,
          videoSeconds: Double? = nil,
          folderCreated: Date? = nil,
          videoModified: Date? = nil,
          folderFile: UInt64? = nil,
          calendar: Calendar = .current) {
        guard contents.hasSidecar else { return nil }
        if case .failure(.absent) = sidecar { return nil }
        self.folderName = folderName
        self.bytes = bytes
        self.videoModified = videoModified
        self.folderFile = folderFile
        video = contents.video
        audio = contents.audio
        let stamped = ForkMeetingLibrary.stampDate(folderName, calendar: calendar)
        switch sidecar {
        case .failure:
            id = nil
            status = .unreadable
            title = ForkMeetingLibrary.folderTitle(folderName)
            startedAt = nil
            endedAt = nil
            seconds = videoSeconds
            provider = nil
            meetCode = nil
            notes = ""
            isReadOnly = true
            isForeign = false
        case let .success(meeting):
            id = meeting.id
            status = Self.status(of: meeting, contents: contents, live: live)
            let written = meeting.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            title = written.isEmpty ? nil : written
            startedAt = meeting.startedAt
            endedAt = meeting.endedAt
            let recorded = meeting.recordedSeconds ?? 0
            seconds = recorded > 0 ? recorded : videoSeconds
            provider = meeting.provider
            meetCode = meeting.meetCode
            notes = meeting.notes ?? ""
            isForeign = !meeting.isWrittenByMeetings
            isReadOnly = !meeting.isRewritable || isForeign
        }
        if let startedAt {
            date = startedAt
            dateSource = .sidecar
        } else if let stamped {
            date = stamped
            dateSource = .folderName
        } else {
            date = folderCreated
            dateSource = folderCreated == nil ? nil : .folderCreated
        }
        switch status {
        case .interrupted, .unreadable:
            playable = contents.video ?? (contents.hasMaster ? ForkMeetingFolder.masterName : nil)
        case .recording, .finalizing:
            // The master is being written, the final file being replaced.
            playable = nil
        case .complete, .recovered:
            playable = contents.video
        }
    }

    /// What a sidecar's state means for its row. A state this version does
    /// not know (a later one's) reads as complete when there is a video to
    /// play, interrupted otherwise: neither hides the meeting.
    static func status(of meeting: ForkMeetingSidecar, contents: ForkMeetingFolder.Contents,
                       live: Bool) -> Status {
        if live { return meeting.state == .finalizing ? .finalizing : .recording }
        switch meeting.state {
        case .complete?:
            return meeting.recovered == true ? .recovered : .complete
        case .finalizing?:
            // A pass that failed waits for its last try at the next launch,
            // its master shown under the meeting's name when it plays
            // (`ForkMeetingStore.revealMaster`): flagged, and playable.
            if meeting.finalPass == .failed { return .interrupted(.finalPassFailed) }
            // Cut short by a quit: the next launch runs it again.
            return .finalizing
        case .recording?:
            // Not ours: a crash the recovery has not seen yet.
            return .interrupted(cause(of: meeting, fallback: .crash))
        case .interrupted?:
            return .interrupted(cause(of: meeting, fallback: nil))
        case nil:
            return contents.video == nil ? .interrupted(.unknown) : .complete
        }
    }

    private static func cause(of meeting: ForkMeetingSidecar, fallback: ForkMeetingStopReason?) -> Cause {
        if meeting.finalPass == .failed { return .finalPassFailed }
        guard let reason = meeting.stopReason ?? fallback else { return .unknown }
        // A Stop or a meeting that ended are not causes of anything going
        // wrong: what went wrong came after, unsaid.
        switch reason {
        case .user, .meetingEnded: return .unknown
        default: return .stopped(reason)
        }
    }

    /// What the detail is kept by through a rename: the folder's file
    /// number, which a rename keeps and a copy does not (two folders may
    /// carry the same id); its name when the store could not read it.
    var identity: String { folderFile.map { "file:\($0)" } ?? "folder:\(folderName)" }

    /// The same row once the store renamed its folder, its media and its
    /// title (`ForkMeetingStore.RenameResult`), before the next scan says
    /// so: the list and the detail follow at once.
    func renamed(to folder: String, media: [ForkMeetingFolder.Move], title edited: String?) -> ForkMeetingLibraryEntry {
        var row = self
        row.folderName = folder
        func follow(_ name: String?) -> String? {
            guard let name else { return nil }
            return media.first { $0.from == name }?.to ?? name
        }
        row.video = follow(video)
        row.audio = follow(audio)
        row.playable = follow(playable)
        if let edited {
            let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
            row.title = trimmed.isEmpty ? nil : trimmed
        }
        return row
    }

    /// The title a row shows: its own, or the default name of a meeting
    /// recorded without one, in the language of whoever looks.
    func displayTitle(_ strings: ForkMeetingStrings) -> String {
        ForkMeetingFolder.displayTitle(title, strings: strings)
    }
}

/// The library's lists: sorting, the days rows are grouped under, and the
/// search.
enum ForkMeetingLibrary {
    // MARK: - Folder names

    /// The start a folder's name begins with (`2026-10-18 10h02`), read back
    /// in the Gregorian calendar and the time zone it was written in.
    /// `nil` for a folder renamed by hand without it.
    static func stampDate(_ folderName: String, calendar: Calendar = .current) -> Date? {
        guard let parts = stampParts(folderName) else { return nil }
        let gregorian = self.gregorian(calendar)
        guard let date = gregorian.date(from: parts),
              gregorian.component(.day, from: date) == parts.day else { return nil }
        return date
    }

    /// The stamp's numbers, when the name starts with one: its shape, then
    /// numbers a clock and a calendar can hold.
    private static func stampParts(_ folderName: String) -> DateComponents? {
        let head = Array(folderName.prefix(16))
        guard head.count == 16 else { return nil }
        for (character, expected) in zip(head, Array("0000-00-00 00h00")) {
            if expected == "0" ? !(character.isASCII && character.isNumber) : character != expected { return nil }
        }
        func number(_ range: Range<Int>) -> Int { Int(String(head[range])) ?? -1 }
        var parts = DateComponents()
        parts.year = number(0..<4)
        parts.month = number(5..<7)
        parts.day = number(8..<10)
        parts.hour = number(11..<13)
        parts.minute = number(14..<16)
        guard let month = parts.month, (1...12).contains(month), let day = parts.day, (1...31).contains(day),
              let hour = parts.hour, hour < 24, let minute = parts.minute, minute < 60 else { return nil }
        return parts
    }

    /// What follows the stamp and its dash, for a meeting whose sidecar
    /// cannot say its title; a folder renamed by hand is its own title.
    static func folderTitle(_ folderName: String) -> String? {
        var rest = Substring(folderName)
        if stampParts(folderName) != nil {
            rest = rest.dropFirst(16)
            let separator = " — "
            if rest.hasPrefix(separator) { rest = rest.dropFirst(separator.count) }
        }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// The calendar every day of the library is counted in: Gregorian, as
    /// the folder names are, in the injected calendar's time zone.
    static func gregorian(_ calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    // MARK: - Order

    /// Newest first; meetings without a date last; the folder's name breaks
    /// ties, so two refreshes never swap rows.
    static func sorted(_ entries: [ForkMeetingLibraryEntry]) -> [ForkMeetingLibraryEntry] {
        entries.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?) where left != right: return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.folderName > rhs.folderName
            }
        }
    }

    // MARK: - Days

    /// The heading a day's meetings sit under.
    enum Day: Equatable {
        case today
        case yesterday
        /// Two to six days ago: the weekday is enough.
        case weekday(Date)
        /// Older, or in the future (a clock set wrong): the date.
        case date(Date, sameYear: Bool)
        case undated
    }

    struct Group: Equatable {
        let day: Day
        let entries: [ForkMeetingLibraryEntry]
    }

    /// The last seven days by name, the way Mail and Messages do: a calendar
    /// week starts on a day that changes with the region, and would leave a
    /// Monday with nothing but Today.
    static func day(of date: Date?, now: Date, calendar: Calendar) -> Day {
        guard let date else { return .undated }
        let gregorian = self.gregorian(calendar)
        let start = gregorian.startOfDay(for: date)
        let today = gregorian.startOfDay(for: now)
        let distance = gregorian.dateComponents([.day], from: start, to: today).day ?? 0
        switch distance {
        case 0: return .today
        case 1: return .yesterday
        case 2...6: return .weekday(start)
        default:
            let sameYear = gregorian.component(.year, from: start) == gregorian.component(.year, from: today)
            return .date(start, sameYear: sameYear)
        }
    }

    /// The rows sorted, then cut into days in their order.
    static func groups(_ entries: [ForkMeetingLibraryEntry], now: Date,
                       calendar: Calendar = .current) -> [Group] {
        var groups: [Group] = []
        var current: (day: Day, entries: [ForkMeetingLibraryEntry])?
        for entry in sorted(entries) {
            let day = day(of: entry.date, now: now, calendar: calendar)
            if let open = current, open.day == day {
                current?.entries.append(entry)
            } else {
                if let open = current { groups.append(Group(day: open.day, entries: open.entries)) }
                current = (day, [entry])
            }
        }
        if let open = current { groups.append(Group(day: open.day, entries: open.entries)) }
        return groups
    }

    /// "Today", "Wednesday", "October 2", "October 2, 2025": in the app's
    /// language, its first letter raised, since French and Spanish write
    /// weekdays in lower case and this is a heading.
    static func heading(_ day: Day, strings: ForkMeetingStrings, language: AppLanguage,
                        calendar: Calendar = .current) -> String {
        let template: String
        let date: Date
        switch day {
        case .today: return strings.groupToday
        case .yesterday: return strings.groupYesterday
        case .undated: return strings.groupUndated
        case let .weekday(start):
            template = "EEEE"
            date = start
        case let .date(start, sameYear):
            template = sameYear ? "dMMMM" : "dMMMMy"
            date = start
        }
        let formatter = DateFormatter()
        let locale = language.formattingLocale()
        formatter.locale = locale
        formatter.calendar = gregorian(calendar)
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        let text = formatter.string(from: date)
        guard let first = text.first else { return text }
        return String(first).uppercased(with: locale) + text.dropFirst()
    }

    // MARK: - Search

    /// What a search compares: case, accents, widths and the way a letter
    /// is written (NFC "é" or NFD "e" + accent) never matter, nor a
    /// typographic apostrophe against a straight one.
    static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
    }

    /// The words of a query, folded: "  Point   HEBDO " is two words.
    static func terms(_ query: String) -> [String] {
        folded(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Everything a row can be found by: its title as shown, its notes, its
    /// provider (its id and, when the caller knows it, its name), its Meet
    /// code with and without dashes, and its folder's name.
    static func haystack(_ entry: ForkMeetingLibraryEntry, strings: ForkMeetingStrings,
                         providerName: (String) -> String? = { _ in nil }) -> String {
        var fields = [entry.displayTitle(strings), entry.notes, entry.folderName]
        if let provider = entry.provider {
            fields.append(provider)
            if let name = providerName(provider) { fields.append(name) }
        }
        if let code = entry.meetCode {
            fields.append(code)
            fields.append(code.replacingOccurrences(of: "-", with: ""))
        }
        return folded(fields.joined(separator: "\n"))
    }

    /// Every word of the query is somewhere in the row, in any field, in any
    /// order. An empty query keeps every row.
    static func matches(_ entry: ForkMeetingLibraryEntry, query: String, strings: ForkMeetingStrings,
                        providerName: (String) -> String? = { _ in nil }) -> Bool {
        let words = terms(query)
        guard !words.isEmpty else { return true }
        let text = haystack(entry, strings: strings, providerName: providerName)
        return words.allSatisfy { text.contains($0) }
    }

    static func filtered(_ entries: [ForkMeetingLibraryEntry], query: String, strings: ForkMeetingStrings,
                         providerName: (String) -> String? = { _ in nil }) -> [ForkMeetingLibraryEntry] {
        entries.filter { matches($0, query: query, strings: strings, providerName: providerName) }
    }

    // MARK: - Words on a row

    /// The status beside a flagged or unfinished row; `nil` for a complete
    /// one, which needs no word.
    static func statusText(_ status: ForkMeetingLibraryEntry.Status, strings: ForkMeetingStrings) -> String? {
        switch status {
        case .complete: return nil
        case .recovered: return strings.statusRecovered
        case let .interrupted(cause): return strings.statusInterrupted(causeText(cause, strings: strings))
        case .recording: return strings.stateRecording
        case .finalizing: return strings.pillFinalizing
        case .unreadable: return strings.statusUnreadable
        }
    }

    static func causeText(_ cause: ForkMeetingLibraryEntry.Cause, strings: ForkMeetingStrings) -> String {
        switch cause {
        case .finalPassFailed: return strings.causeFinalPass
        case .unknown: return strings.causeUnknown
        case let .stopped(reason):
            switch reason {
            case .crash: return strings.causeCrash
            case .quit: return strings.causeQuit
            case .disk: return strings.causeDisk
            case .permission: return strings.causePermission
            case .sleep: return strings.causeSleep
            case .featureDisabled: return strings.causeFeatureOff
            case .captureStopped: return strings.causeCaptureStopped
            case .cancelled: return strings.causeCancelled
            case .user, .meetingEnded: return strings.causeUnknown
            }
        }
    }
}
