// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

// What the library may do to a meeting, decided apart from the file
// operations: renaming, the notes and title saved as they are typed, the
// automatic bin and the copy the editor opens. The store and the window act
// on these answers.

/// A change the library makes to `meeting.json`. Separate from the session's
/// patch: the session never touches a title or the notes once the meeting
/// has a folder, and the library never touches the recording's facts.
struct ForkMeetingSidecarEdit: Equatable {
    /// The title the person gave; an empty one clears it, and the row shows
    /// the default name again. `nil`: unchanged.
    var title: String?
    var notes: String?

    var isEmpty: Bool { title == nil && notes == nil }

    func applied(to sidecar: ForkMeetingSidecar) -> ForkMeetingSidecar {
        var result = sidecar
        if let title {
            result.title = title.isEmpty ? nil : title
            result.titleSource = title.isEmpty ? nil : .user
        }
        if let notes { result.notes = notes }
        return result
    }

    /// The sidecar to write, or `nil` when it must stay as it is on the
    /// disk: missing, unreadable, corrupt, or from a later version, exactly
    /// as for the session's patch.
    static func rewriting(_ read: Result<ForkMeetingSidecar, ForkMeetingSidecarFault>,
                          with edit: ForkMeetingSidecarEdit) -> ForkMeetingSidecar? {
        guard case let .success(sidecar) = read, sidecar.isRewritable else { return nil }
        return edit.applied(to: sidecar)
    }

    /// The later edit wins field by field.
    func merged(with later: ForkMeetingSidecarEdit) -> ForkMeetingSidecarEdit {
        ForkMeetingSidecarEdit(title: later.title ?? title, notes: later.notes ?? notes)
    }
}

// MARK: - Renaming

/// A new title renames the meeting's folder and its media with it, so the
/// three never disagree (§3.1, step 7): `2026-10-18 10h02 — Weekly sync/`
/// holding `2026-10-18 10h02 — Weekly sync.mp4`.
///
/// - The title is saved as it is typed (`ForkMeetingEditCoalescer`); the
///   folder moves **once**, when the field is committed (Return, leaving
///   the field, closing the window). Renaming the folder at each pause in
///   the typing would move files the player has open, a dozen times.
/// - A folder renamed by hand (its name no longer starts with the stamp)
///   keeps its name: the person filed it, and only the title changes.
/// - Nothing is renamed while this app, or another copy of it, may still be
///   writing the folder: recording, finishing, or left unfinished for the
///   recovery, which finds folders by scanning and would otherwise race the
///   move.
enum ForkMeetingRename {
    enum Refusal: Error, Equatable {
        case meetingInProgress
        /// `meeting.json` will not decode: there is nowhere to keep a title.
        case sidecarUnreadable
        /// Written by a later version: read, never rewritten.
        case sidecarFromLaterVersion
    }

    /// Why the folder keeps its name while the title changes.
    enum FolderKept: Equatable {
        /// Already named after this title (disambiguated included).
        case alreadyNamed
        /// No title left to name it after: the stamp alone stays as written.
        case noTitle
        case renamedByHand
        /// Fifty folders already carry the name: the folder keeps its own.
        case namesExhausted
    }

    struct Plan: Equatable {
        /// What `meeting.json` gets, `nil` when it already says it.
        var edit: ForkMeetingSidecarEdit?
        /// The folder's move, inside the meetings folder.
        var folder: ForkMeetingFolder.Move?
        var folderKept: FolderKept?
        /// The media that follow the folder's new name; empty when it keeps
        /// its own.
        var media = ForkMeetingFolder.MediaRenames()
    }

    /// The title as it is kept: one line, no blank around it.
    static func cleaned(_ title: String) -> String {
        title.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// - `live`: this app records or finishes the folder now.
    /// - `names`: what the folder holds, as it is on the disk now.
    /// - `occupant`: what sits at a name beside it, from the store's look at
    ///   the disk. A rename only ever takes a name entirely free.
    static func plan(title: String, folderName: String,
                     sidecar: Result<ForkMeetingSidecar, ForkMeetingSidecarFault>,
                     names: [String], live: Bool, calendar: Calendar = .current,
                     occupant: (String) -> ForkMeetingFolder.Occupant) -> Result<Plan, Refusal> {
        guard case let .success(meeting) = sidecar else { return .failure(.sidecarUnreadable) }
        guard meeting.isRewritable else { return .failure(.sidecarFromLaterVersion) }
        if live || meeting.state == .recording || meeting.state == .finalizing {
            return .failure(.meetingInProgress)
        }
        let wanted = cleaned(title)
        var plan = Plan()
        let current = meeting.title.map(cleaned) ?? ""
        if wanted != current || (!wanted.isEmpty && meeting.titleSource != .user) {
            plan.edit = ForkMeetingSidecarEdit(title: wanted)
        }
        guard let startedAt = meeting.startedAt else {
            // No stamp to check the name against: the folder is not ours to
            // judge.
            plan.folderKept = .renamedByHand
            return .success(plan)
        }
        let stamp = ForkMeetingFolder.stamp(startedAt, calendar: calendar)
        guard folderName.hasPrefix(stamp) else {
            plan.folderKept = .renamedByHand
            return .success(plan)
        }
        guard !wanted.isEmpty, ForkMeetingFolder.sanitized(wanted) != nil else {
            plan.folderKept = .noTitle
            return .success(plan)
        }
        guard let desired = ForkMeetingFolder.renamedFolder(current: folderName, startedAt: startedAt,
                                                            title: wanted, calendar: calendar) else {
            plan.folderKept = .alreadyNamed
            return .success(plan)
        }
        switch ForkMeetingFolder.reserve(base: desired, forRename: true, occupant: occupant) {
        case let .create(name):
            plan.folder = ForkMeetingFolder.Move(from: folderName, to: name)
            plan.media = ForkMeetingFolder.mediaRenames(folderName: name, names: names)
        case .adopt, .exhausted:
            plan.folderKept = .namesExhausted
        }
        return .success(plan)
    }
}

/// The title and the notes, saved while they are typed but never at each
/// key (one of bran's faults): the first change opens a half-second window,
/// and everything typed in it is written once when it closes. A long stretch
/// of typing is still saved every half second, so a crash loses at most
/// that, which a delay pushed back at each key would not promise.
///
/// Keyed by the folder's name; a rename moves what is pending with it. Time
/// is given, never read, so the tests need no clock.
struct ForkMeetingEditCoalescer {
    static let interval: TimeInterval = 0.5

    struct Pending: Equatable {
        var edit: ForkMeetingSidecarEdit
        var deadline: Date
    }

    private(set) var pending: [String: Pending] = [:]

    mutating func note(_ edit: ForkMeetingSidecarEdit, in folder: String, at now: Date) {
        guard !edit.isEmpty else { return }
        if var open = pending[folder] {
            open.edit = open.edit.merged(with: edit)
            pending[folder] = open
        } else {
            pending[folder] = Pending(edit: edit, deadline: now.addingTimeInterval(Self.interval))
        }
    }

    /// When the next write is due, for the one timer the window keeps.
    var nextDeadline: Date? { pending.values.map(\.deadline).min() }

    /// The edits whose window has closed, taken out, in folder order.
    mutating func takeDue(at now: Date) -> [(folder: String, edit: ForkMeetingSidecarEdit)] {
        let due = pending.filter { $0.value.deadline <= now }.keys.sorted()
        return due.compactMap { folder in pending.removeValue(forKey: folder).map { (folder, $0.edit) } }
    }

    /// Everything pending now, before a rename, a move to the bin, the
    /// window's closing or the app's quitting; or only one folder's.
    mutating func flush(_ folder: String? = nil) -> [(folder: String, edit: ForkMeetingSidecarEdit)] {
        let keys = folder.map { [$0] } ?? pending.keys.sorted()
        return keys.compactMap { key in pending.removeValue(forKey: key).map { (key, $0.edit) } }
    }

    /// A folder renamed: what is still pending follows it.
    mutating func move(from old: String, to new: String) {
        guard let open = pending.removeValue(forKey: old) else { return }
        if let there = pending[new] {
            pending[new] = Pending(edit: open.edit.merged(with: there.edit), deadline: min(open.deadline, there.deadline))
        } else {
            pending[new] = open
        }
    }

    /// A folder gone (to the bin, or vanished from the disk): nothing to
    /// write any more.
    mutating func forget(_ folder: String) {
        pending.removeValue(forKey: folder)
    }
}

// MARK: - The automatic bin

/// `fork.meetings.retentionDays`: meetings older than this many days go to
/// the bin, never deleted outright. 0, the default, never.
///
/// **When**: at a launch with the feature on, then once a day while the app
/// runs. Lowering the setting asks first, with the number of meetings it
/// would take; raising it or turning it off takes nothing.
///
/// **Never**, whatever its age:
/// - a meeting being recorded or finished, or left unfinished for the
///   recovery: what is still being written is not old;
/// - a meeting flagged ⚠ (recovered, interrupted, unreadable sidecar): it is
///   the one the person may not have looked at yet, and nothing records
///   whether they did, so it waits for their hand. They are few;
/// - a sidecar from a later version, which this one does not judge;
/// - a meeting whose sidecar gives no date: an age is never guessed from a
///   folder's name or its dates on the disk, which a copy or a restore
///   resets;
/// - today's meetings, nor one dated in the future by a clock set wrong.
///
/// The age is counted in whole days from the day the meeting ended, in the
/// Gregorian calendar, and must be **more** than the setting: a meeting of
/// October 18 kept 30 days is still there all of November 17 and goes on
/// November 18, whatever the hour it was held.
enum ForkMeetingRetention {
    static let choices = [0, 30, 90, 365]
    static let fallback = 0
    static let sweepInterval: TimeInterval = 86_400

    /// Only the values the page offers: a backup or a hand-written default
    /// with anything else never empties a library.
    static func sanitized(_ days: Int) -> Int {
        choices.contains(days) ? days : fallback
    }

    /// At the first look after a launch, then every day. A clock moved back
    /// sweeps again rather than waiting for the old date to come round.
    static func isSweepDue(lastSweep: Date?, now: Date) -> Bool {
        guard let lastSweep else { return true }
        return now < lastSweep || now.timeIntervalSince(lastSweep) >= sweepInterval
    }

    enum Kept: Equatable {
        case off
        case recent
        case inProgress
        case flagged
        case laterVersion
        case undated
    }

    enum Verdict: Equatable {
        case trash
        case keep(Kept)
    }

    static func verdict(_ entry: ForkMeetingLibraryEntry, days: Int, now: Date,
                        calendar: Calendar = .current) -> Verdict {
        let days = sanitized(days)
        guard days > 0 else { return .keep(.off) }
        if entry.status.isInProgress { return .keep(.inProgress) }
        if entry.status.isFlagged { return .keep(.flagged) }
        if entry.isReadOnly { return .keep(.laterVersion) }
        guard let reference = entry.endedAt ?? entry.startedAt else { return .keep(.undated) }
        let gregorian = ForkMeetingLibrary.gregorian(calendar)
        let distance = gregorian.dateComponents([.day], from: gregorian.startOfDay(for: reference),
                                                to: gregorian.startOfDay(for: now)).day ?? 0
        return distance > days ? .trash : .keep(.recent)
    }

    /// The folders a sweep sends to the bin, minus those the app is busy
    /// with (`live`), whatever their sidecar says.
    static func due(_ entries: [ForkMeetingLibraryEntry], days: Int, now: Date, live: Set<String> = [],
                    calendar: Calendar = .current) -> [String] {
        entries.filter { !live.contains($0.folderName) && verdict($0, days: days, now: now, calendar: calendar) == .trash }
            .map(\.folderName)
            .sorted()
    }

    /// Turning the bin on or lowering its delay asks first, when it would
    /// take something now (`due`); nothing else does.
    static func needsConfirmation(from old: Int, to new: Int, due: Int) -> Bool {
        let old = sanitized(old), new = sanitized(new)
        return due > 0 && new > 0 && (old == 0 || new < old)
    }
}

// MARK: - Trimming in the editor

/// "Trim in Editor" opens a **copy** in the official editor, which removes
/// its take when it closes (`RecorderEditorController`): handed the meeting's
/// own file, it would delete the meeting.
///
/// - **Where**: a new take of the official store (`RecorderTakeStore.makeTake`,
///   its `take.mov`), in the app's private storage, never in the meeting's
///   folder. The take goes with the editor; what the person saves from it
///   goes where the official editor saves, under its names.
/// - **What**: the final video, never the master while it is written, never
///   a draft. An interrupted meeting with only its master offers the master,
///   readable up to its last fragment.
/// - **The sound**: the editor tells a take's sources apart by track
///   metadata an `.mp4` drops (spike S1), and falls back on their order:
///   first track the Mac's sound, second the microphone. The final file
///   starts with the mix, so it would hear the participants twice and take
///   the meeting for the microphone: its copy keeps only the two sources,
///   meeting then microphone, copied without re-encoding. A master, or a
///   final file that kept the master's tracks (`skipped-disk`), already has
///   that order and is cloned as it is (APFS: no cost on the same volume).
/// - The original is only ever read.
enum ForkMeetingEditorCopy {
    enum Refusal: Error, Equatable {
        case meetingInProgress
        case noVideo
        /// The editor belongs to Screen Capture: off or uninstalled, there is
        /// no editor to open.
        case editorUnavailable
    }

    enum Audio: Equatable {
        /// Cloned as it is.
        case asIs
        /// Copied without its first audio track, the mix.
        case withoutMix
    }

    struct Plan: Equatable {
        /// The file in the meeting's folder the copy is made from.
        let source: String
        let audio: Audio
    }

    /// The final file's audio: the mix, then the meeting, then the
    /// microphone (`ForkMeetingFinalPass`).
    static let finalAudioTracks = 3

    /// - `audioTracks`: the audio tracks the store counted in `source`; `nil`
    ///   when it could not tell, and the file is then cloned as it is.
    static func plan(_ entry: ForkMeetingLibraryEntry, audioTracks: Int?, editorAvailable: Bool,
                     live: Bool = false) -> Result<Plan, Refusal> {
        if live || entry.status.isInProgress { return .failure(.meetingInProgress) }
        guard editorAvailable else { return .failure(.editorUnavailable) }
        guard let source = entry.playable else { return .failure(.noVideo) }
        let audio: Audio = audioTracks == finalAudioTracks && source != ForkMeetingFolder.masterName ? .withoutMix : .asIs
        return .success(Plan(source: source, audio: audio))
    }

    /// The tracks the copy keeps, by their index among the file's audio
    /// tracks; every one for a clone.
    static func keptAudioTracks(_ plan: Plan, count: Int) -> [Int] {
        switch plan.audio {
        case .asIs: return Array(0..<max(0, count))
        case .withoutMix: return Array(1..<max(1, count))
        }
    }
}
