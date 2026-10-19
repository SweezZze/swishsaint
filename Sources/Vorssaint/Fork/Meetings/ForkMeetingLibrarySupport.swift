// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

// What the library's store and window decide without touching a file: the
// lengths kept between two scans, the audio an export takes, the row kept
// selected after the folder changed, and the words a row is read with.

/// What the store measured of a meeting's video, kept between two scans:
/// opening every video at each change of the folder would cost a fresh
/// `AVURLAsset` per meeting, every time a note is saved.
///
/// A measure is reused only while the file keeps the date and the size it
/// had when it was measured. A file without a readable date is measured
/// again every time: nothing tells it did not change.
struct ForkMeetingProbeCache: Equatable {
    struct Stamp: Equatable {
        var modified: Date?
        var size: Int64?
    }

    struct Probe: Equatable {
        /// How long it plays; `nil` when it does not open.
        var seconds: Double?
        /// Its audio tracks; `nil` when it could not tell.
        var audioTracks: Int?
        /// The final pass's layout: the first audio track, enabled, is a mix
        /// of the others, which are not.
        var hasMix = false
    }

    private struct Slot: Equatable {
        var stamp: Stamp
        var probe: Probe
    }

    private var slots: [String: Slot] = [:]

    var count: Int { slots.count }

    func probe(for path: String, stamp: Stamp) -> Probe? {
        guard stamp.modified != nil, let slot = slots[path], slot.stamp == stamp else { return nil }
        return slot.probe
    }

    mutating func remember(_ probe: Probe, for path: String, stamp: Stamp) {
        guard stamp.modified != nil else { return }
        slots[path] = Slot(stamp: stamp, probe: probe)
    }

    /// After a scan: the files gone (trashed, renamed) are forgotten, so
    /// the cache never outgrows the library.
    mutating func keep(only paths: Set<String>) {
        slots = slots.filter { paths.contains($0.key) }
    }
}

// MARK: - Exporting the audio

/// "Export Audio (M4A)…": the meeting's sound as one file, never encoded
/// again when it need not be.
///
/// - The M4A the final pass made is copied as it is.
/// - Without one (turned off, or not made), the final file's mix is copied
///   out of it, still without encoding.
/// - A file with no mix (a master, or a final file that kept the master's
///   two tracks for room) has its sources mixed into a new M4A: the only
///   case that encodes, since one of its tracks alone would be half the
///   meeting.
enum ForkMeetingAudioExport {
    enum Route: Equatable {
        /// A file of the meeting's folder, copied.
        case copy(String)
        /// The first audio track of that video, copied out.
        case extractMix(String)
        /// Every audio track of that video, mixed into AAC.
        case mixDown(String)
    }

    enum Refusal: Error, Equatable {
        case meetingInProgress
        case noAudio
    }

    static func route(_ entry: ForkMeetingLibraryEntry, probe: ForkMeetingProbeCache.Probe?,
                      live: Bool = false) -> Result<Route, Refusal> {
        if live || entry.status.isInProgress { return .failure(.meetingInProgress) }
        if let audio = entry.audio { return .success(.copy(audio)) }
        guard let video = entry.playable, (probe?.audioTracks ?? 1) > 0 else { return .failure(.noAudio) }
        if probe?.hasMix == true, video != ForkMeetingFolder.masterName { return .success(.extractMix(video)) }
        return .success(.mixDown(video))
    }

    /// The name the save panel suggests: the meeting's own, as its M4A
    /// would be called in its folder.
    static func suggestedName(_ entry: ForkMeetingLibraryEntry) -> String {
        "\(entry.folderName).\(ForkMeetingFolder.audioExtension)"
    }
}

// MARK: - Reading the folder again

extension ForkMeetingLibrary {
    /// What the window reads again after a change: every folder, or only
    /// those that changed. A note saved, a meeting finishing, touch one
    /// meeting's folder: reading it alone keeps typing in a library of
    /// hundreds of meetings from reading them all twice a second.
    enum Rescan: Equatable {
        case all
        case folders(Set<String>)

        /// Two asks gathered while a scan runs.
        func merged(with other: Rescan) -> Rescan {
            switch (self, other) {
            case let (.folders(one), .folders(two)): return .folders(one.union(two))
            default: return .all
            }
        }
    }

    /// The meeting folders FSEvents names (`paths`, as it reports them,
    /// directories with or without their final slash) under `root`: a
    /// change inside a meeting's folder is that folder's; a change of the
    /// meetings folder itself (a folder added, renamed, sent to the Trash)
    /// or anywhere else is everything's.
    static func rescan(paths: [String], root: String) -> Rescan {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        var folders = Set<String>()
        for path in paths {
            guard path.hasPrefix(base + "/") else { return .all }
            let inside = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: true)
            guard let first = inside.first else { return .all }
            folders.insert(String(first))
        }
        return folders.isEmpty ? .all : .folders(folders)
    }

    /// The rows after a scan of `scanned` folders alone: theirs replaced
    /// by what the scan found (none for a folder gone), the others kept.
    static func merged(_ entries: [ForkMeetingLibraryEntry], scanned names: Set<String>,
                       with found: [ForkMeetingLibraryEntry]) -> [ForkMeetingLibraryEntry] {
        (entries.filter { !names.contains($0.folderName) } + found).sorted { $0.folderName < $1.folderName }
    }
}

// MARK: - Selection

extension ForkMeetingLibrary {
    /// The row selected once the list changed under it: the same meeting,
    /// followed through a rename; else, when it went (to the Trash, or
    /// renamed in the Finder), the one that came after it, else the one
    /// before; nothing in an empty list.
    static func keptSelection(_ selected: String?, renamed: [String: String] = [:],
                              before: [String], after: [String]) -> String? {
        guard !after.isEmpty else { return nil }
        guard let selected else { return nil }
        let present = Set(after)
        if present.contains(selected) { return selected }
        if let new = renamed[selected], present.contains(new) { return new }
        if let index = before.firstIndex(of: selected) {
            if let next = before[(index + 1)...].first(where: present.contains) { return next }
            if let previous = before[..<index].last(where: present.contains) { return previous }
        }
        return after.first
    }

    /// The row a move to the Trash selects: the next one, else the previous.
    static func neighbour(of folder: String, in order: [String]) -> String? {
        guard let index = order.firstIndex(of: folder) else { return nil }
        if order.indices.contains(index + 1) { return order[index + 1] }
        return index > 0 ? order[index - 1] : nil
    }

    /// The rows as the list shows them, top to bottom.
    static func order(_ groups: [Group]) -> [String] {
        groups.flatMap { $0.entries.map(\.folderName) }
    }
}

// MARK: - Words

/// The numbers a row and the detail show, in the app's language.
enum ForkMeetingLibraryText {
    /// "52 min", "1 h 5 min", "45 s": seconds only under a minute.
    static func duration(_ seconds: Double?, language: AppLanguage) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.formattingLocale()
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        if seconds < 60 {
            formatter.allowedUnits = [.second]
            return formatter.string(from: seconds.rounded())
        }
        formatter.allowedUnits = [.hour, .minute]
        return formatter.string(from: (seconds / 60).rounded() * 60)
    }

    /// "10:02", "10:02 AM": the time of day, as the region of the app's
    /// language writes it.
    static func time(_ date: Date, language: AppLanguage, calendar: Calendar = .current) -> String {
        formatter(language: language, calendar: calendar, template: "jmm").string(from: date)
    }

    /// "Sunday, October 18, 2026 at 10:02": under the detail's title.
    static func longDate(_ date: Date, language: AppLanguage, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.formattingLocale()
        formatter.calendar = ForkMeetingLibrary.gregorian(calendar)
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func formatter(language: AppLanguage, calendar: Calendar, template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.formattingLocale()
        formatter.calendar = ForkMeetingLibrary.gregorian(calendar)
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// The service's short name ("Meet", "Zoom"); `nil` for a meeting
    /// recorded by hand, a provider this version does not know, or an id
    /// several services share: `meeting.json` says `web` for every other
    /// web call (Whereby, Jitsi…), and naming the table's first one would
    /// call a Jitsi meeting Zoom.
    static func providerName(_ id: String?) -> String? {
        guard let id else { return nil }
        let named = ForkMeetingProviderTable.current.providers.filter { $0.id == id }
        return named.count == 1 ? named[0].shortName : nil
    }

    /// The line under a row's title: "Meet · 410 MB", then its status.
    static func caption(_ entry: ForkMeetingLibraryEntry, strings: ForkMeetingStrings,
                        language: AppLanguage) -> String {
        var parts: [String] = []
        if let name = providerName(entry.provider) { parts.append(name) }
        if let bytes = entry.bytes, bytes > 0 { parts.append(ForkMeetingLiveText.size(bytes, language: language)) }
        if let status = ForkMeetingLibrary.statusText(entry.status, strings: strings) { parts.append(status) }
        return parts.joined(separator: " · ")
    }

    /// What VoiceOver reads for a row, in one breath: its title, its time,
    /// its length, its service and its status, ⚠ said in words.
    static func accessibilityLabel(_ entry: ForkMeetingLibraryEntry, strings: ForkMeetingStrings,
                                   language: AppLanguage, calendar: Calendar = .current) -> String {
        var parts = [entry.displayTitle(strings)]
        if let date = entry.date { parts.append(time(date, language: language, calendar: calendar)) }
        if let length = duration(entry.seconds, language: language) { parts.append(length) }
        if let name = providerName(entry.provider) { parts.append(name) }
        if let status = ForkMeetingLibrary.statusText(entry.status, strings: strings) { parts.append(status) }
        return parts.joined(separator: ", ")
    }

    /// The line an action that went wrong, or was done in part, leaves in
    /// the detail; `nil` when the rename went as asked.
    static func renameNote(_ plan: ForkMeetingRename.Plan, strings: ForkMeetingStrings) -> String? {
        if !plan.media.blocked.isEmpty { return strings.renameMediaKept }
        switch plan.folderKept {
        case .renamedByHand?: return strings.renameFolderKept
        case .namesExhausted?: return strings.renameNamesExhausted
        case .alreadyNamed?, .noTitle?, nil: return nil
        }
    }

    static func refusal(_ refusal: ForkMeetingRename.Refusal, strings: ForkMeetingStrings) -> String {
        switch refusal {
        case .meetingInProgress: return strings.refusedWhileRecording
        case .sidecarUnreadable, .sidecarFromLaterVersion: return strings.renameUnreadable
        case .notWrittenHere: return strings.statusForeign
        }
    }
}
