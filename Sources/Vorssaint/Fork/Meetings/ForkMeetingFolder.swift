// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// How a meeting is laid out on the disk: one folder per meeting, named
/// after its start and its title, holding media named after the folder and
/// a `meeting.json` with a fixed name.
///
/// ```
/// ~/Movies/Meetings/
///     2026-10-18 10h02 — Weekly sync/
///         2026-10-18 10h02 — Weekly sync.mp4
///         2026-10-18 10h02 — Weekly sync.m4a
///         meeting.json
///         .recording.mp4        the fragmented master, while it records
/// ```
///
/// - The media are found **by extension**, never by name: renaming the
///   folder in the Finder, the natural gesture when filing meetings, breaks
///   nothing.
/// - The media carry the folder's name: dragged into a mail or a drive, a
///   file still says which meeting it is.
/// - The sidecar keeps a fixed name: it is what tells a meeting folder from
///   any other folder in the same place.
///
/// Ported from bran's `MeetingFolder`, with its measurements. Everything here
/// is names and decisions; the store does the file operations.
enum ForkMeetingFolder {
    static let sidecarName = "meeting.json"
    static let videoExtension = "mp4"
    static let audioExtension = "m4a"
    /// The master the writer fills while the meeting records. Hidden: it is
    /// not the file anyone should open, and it goes once the final pass is
    /// verified.
    static let masterName = ".recording.mp4"
    /// The final pass writes here, then replaces the final file with it:
    /// never a removal followed by a write.
    static let videoDraftName = ".finalizing.mp4"
    static let audioDraftName = ".finalizing.m4a"

    // MARK: - Root

    /// Where the meetings go. An empty setting means the default, a folder
    /// named in the person's language inside Movies ("Meetings", "Réunions").
    /// `needsStoring` asks the caller to save that path at the first
    /// recording: the library must not move when the language changes later.
    struct Root: Equatable {
        let url: URL
        let needsStoring: Bool
    }

    static func root(stored: String, movies: URL, strings: ForkMeetingStrings) -> Root {
        let path = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty else {
            return Root(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true),
                        needsStoring: false)
        }
        return Root(url: movies.appendingPathComponent(strings.folderName, isDirectory: true), needsStoring: true)
    }

    /// The title shown for a meeting: its own, or the default name of one
    /// recorded by hand. `nil` stays `nil` in the sidecar, so the default
    /// follows the language of whoever looks.
    static func displayTitle(_ title: String?, strings: ForkMeetingStrings) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? strings.untitledMeeting : trimmed
    }

    // MARK: - Names

    /// `2026-10-18 10h02`: year first so that sorting by name, the one sort
    /// the Finder offers on a column of names, is sorting by date. Neither
    /// `DateFormatter` nor `FormatStyle`, which follow the region and would
    /// change the name's shape from one Mac to the next; `h` rather than `:`,
    /// which the Finder shows as `/`. Always the Gregorian calendar, in the
    /// Mac's time zone: a Mac set to the Japanese calendar would otherwise
    /// write year 8 of Reiwa and break the sort, while a meeting held at 10:02
    /// is called 10h02 by whoever held it. Only `calendar`'s time zone is read.
    static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02dh%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1,
                      parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The folder's name: the stamp, then the title when one survives
    /// sanitizing. The stamp always leads and never changes, so the folder
    /// stays findable whatever the title becomes.
    static func name(startedAt: Date, title: String?, calendar: Calendar = .current) -> String {
        let head = stamp(startedAt, calendar: calendar)
        guard let title = title.flatMap(sanitized) else { return head }
        return fitted("\(head) — \(title)", fallback: head)
    }

    /// What macOS counts in a file name: 255 UTF-16 units of the
    /// **decomposed** form, neither bytes nor characters. Measured on APFS:
    /// 128 precomposed "é" are refused (256 units once decomposed), 127
    /// emoji and an "a" pass (255). A window title can carry anything.
    static let componentLimit = 255

    /// Kept free for what is appended after the name is chosen: the longest
    /// disambiguation suffix, " (50)", and a media extension, ".mp4". Without
    /// it a folder right at the limit would be created and its video refused.
    static let reservedUnits = 9

    static func units(_ text: String) -> Int {
        text.decomposedStringWithCanonicalMapping.utf16.count
    }

    /// A whole path is at most 1024 bytes (`PATH_MAX`) of decomposed UTF-8,
    /// and a meeting's media sit two names deep, `<root>/<name>/<name>.mp4`:
    /// two names of 255 units can pass one by one and still make a path
    /// macOS refuses (measured: twenty emoji families, 1182 bytes). Under
    /// this, the root keeps more than 500 bytes. Only titles heavy with emoji
    /// (a family weighs 25 bytes) or combining marks ever meet it.
    static let byteLimit = 240

    static func bytes(_ text: String) -> Int {
        text.decomposedStringWithCanonicalMapping.utf8.count
    }

    /// Brings a name under both limits by dropping whole characters from the
    /// end: cutting inside a decomposed "é" would leave a stray accent, and
    /// inside an emoji family a lone figure. Falls back to `fallback` when
    /// nothing of the title survives.
    static func fitted(_ name: String, fallback: String) -> String {
        let budget = componentLimit - reservedUnits
        func tooLong(_ text: String) -> Bool { units(text) > budget || bytes(text) > byteLimit }
        guard tooLong(name) else { return name }
        // A character weighs at least one unit: `budget` characters is a safe
        // first cut, leaving the loop a handful of turns.
        var cut = String(name.prefix(budget))
        while !cut.isEmpty, tooLong(cut) { cut.removeLast() }
        let trimmed = cut.trimmingCharacters(in: trailingNoise)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// A readable title, not a file system one: past it the Finder and the
    /// library cut it in the middle anyway.
    static let titleLimit = 60

    /// Spaces, dashes of every length (one already separates the stamp from
    /// the title) and dots, which the Finder reads as an extension.
    private static let trailingNoise = CharacterSet(charactersIn: " .-–—_")

    /// The title as it may enter a file name, or `nil` when nothing is left,
    /// so a blank title gives `2026-10-18 10h02` and never a name ending in
    /// " — ".
    ///
    /// `/` (the path separator), `:` (shown as `/` by the Finder) and control
    /// characters (category Cc) become a space, so "Acme/Globex" reads as two
    /// words; leading dots go, they would hide the folder. Accents,
    /// apostrophes and ampersands stay: "Closing L'Étoile & Fils" is the name
    /// the person wrote. So do format characters (Cf), which
    /// `CharacterSet.controlCharacters` also holds: the zero-width joiner
    /// inside an emoji family or a rainbow flag, the soft hyphen.
    static func sanitized(_ title: String) -> String? {
        var cleaned = ""
        var lastWasSpace = false
        for character in title {
            let forbidden = character == "/" || character == ":"
                || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
            if forbidden || character.isWhitespace {
                if !lastWasSpace, !cleaned.isEmpty { cleaned.append(" ") }
                lastWasSpace = true
                continue
            }
            cleaned.append(character)
            lastWasSpace = false
        }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        var trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        if trimmed.count > titleLimit {
            // Cut at a space when there is one in the last quarter: a name
            // stopping mid-word reads like a damaged file.
            let hard = String(trimmed.prefix(titleLimit))
            let floor = hard.index(hard.startIndex, offsetBy: titleLimit * 3 / 4)
            if let space = hard.lastIndex(of: " "), space >= floor {
                trimmed = String(hard[hard.startIndex..<space])
            } else {
                trimmed = hard
            }
        }
        // After the cut, which can leave a dangling dash.
        trimmed = trimmed.trimmingCharacters(in: trailingNoise)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Same name twice

    /// Fifty meetings started in the same minute with the same title is
    /// already absurd; the bound keeps a read-only folder from looping while
    /// a meeting waits to start.
    static let maximumSiblings = 50

    /// `base`, then `base (2)` … `base (50)`.
    static func candidates(base: String) -> [String] {
        [base] + (2...maximumSiblings).map { "\(base) (\($0))" }
    }

    /// What already sits at a candidate name, as the store sees it.
    enum Occupant: Equatable {
        case free
        /// A folder without a sidecar: almost surely this very meeting's own
        /// earlier pass, interrupted before it wrote one.
        case folderWithoutSidecar
        /// A folder whose sidecar carries this meeting's id.
        case sameMeeting
        /// Another meeting, an unreadable sidecar, or a file: never touched.
        case taken
    }

    enum Reservation: Equatable {
        /// Nothing there: create it, or move the folder there.
        case create(String)
        /// Our own folder already: use it as it is.
        case adopt(String)
        /// Every name is taken: say so, never write into someone else's.
        case exhausted
    }

    /// The first name this meeting may use. `forRename` asks for a name
    /// entirely free, since a folder is never merged into another to change
    /// a title; otherwise a folder this meeting already owns is taken back.
    /// Two meetings never share a folder: the second one's media would
    /// carry the same names as the first one's.
    static func reserve(base: String, forRename: Bool = false,
                        occupant: (String) -> Occupant) -> Reservation {
        for name in candidates(base: base) {
            switch occupant(name) {
            case .free: return .create(name)
            case .folderWithoutSidecar, .sameMeeting:
                if !forRename { return .adopt(name) }
            case .taken:
                continue
            }
        }
        return .exhausted
    }

    // MARK: - Contents

    /// What a meeting folder holds, found by extension.
    struct Contents: Equatable {
        /// The finished video: a visible `.mp4`, preferably the one named
        /// after the folder.
        var video: String?
        var audio: String?
        var hasSidecar = false
        var hasMaster = false
        var hasVideoDraft = false
        var hasAudioDraft = false
    }

    static func contents(of names: [String], folderName: String) -> Contents {
        var contents = Contents()
        var videos: [String] = []
        var audios: [String] = []
        for name in names {
            switch name {
            case sidecarName: contents.hasSidecar = true
            case masterName: contents.hasMaster = true
            case videoDraftName: contents.hasVideoDraft = true
            case audioDraftName: contents.hasAudioDraft = true
            default:
                guard !name.hasPrefix(".") else { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                if ext == videoExtension { videos.append(name) }
                if ext == audioExtension { audios.append(name) }
            }
        }
        contents.video = preferred(videos, stem: folderName)
        contents.audio = preferred(audios, stem: folderName)
        return contents
    }

    private static func preferred(_ names: [String], stem: String) -> String? {
        names.first { ($0 as NSString).deletingPathExtension == stem } ?? names.sorted().first
    }

    // MARK: - Renaming

    /// The name the folder should take for this title, or `nil` to leave it:
    /// no title (the default name stays as it was written), already right
    /// (disambiguated included), or **renamed by hand**. Every name written
    /// here starts with the stamp; one that no longer does was filed by the
    /// person, and a title arriving later must not undo that.
    static func renamedFolder(current: String, startedAt: Date, title: String?,
                              calendar: Calendar = .current) -> String? {
        guard current.hasPrefix(stamp(startedAt, calendar: calendar)),
              let title, sanitized(title) != nil else { return nil }
        let desired = name(startedAt: startedAt, title: title, calendar: calendar)
        guard !candidates(base: desired).contains(current) else { return nil }
        return desired
    }

    struct Move: Equatable {
        let from: String
        let to: String
    }

    struct MediaRenames: Equatable {
        var moves: [Move] = []
        /// Media left alone because their new name is already used in the
        /// folder: neither file is touched, and the caller says so.
        var blocked: [String] = []
    }

    /// The media that follow the folder's name, read from what is on the
    /// disk rather than from what was written, since the person may have
    /// renamed things in between. Each keeps its own extension: renaming
    /// never changes what a file holds.
    static func mediaRenames(folderName: String, names: [String]) -> MediaRenames {
        let found = contents(of: names, folderName: folderName)
        var result = MediaRenames()
        for media in [found.video, found.audio].compactMap({ $0 }) {
            let target = "\(folderName).\((media as NSString).pathExtension)"
            guard media != target else { continue }
            // APFS ignores case: "F.mp4" and "f.MP4" are the same file.
            if names.contains(where: { $0.lowercased() == target.lowercased() }) {
                result.blocked.append(media)
            } else {
                result.moves.append(Move(from: media, to: target))
            }
        }
        return result
    }
}
