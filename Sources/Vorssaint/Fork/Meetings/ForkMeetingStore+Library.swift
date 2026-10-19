// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation
import os

/// The library's side of the store: the meetings listed, renamed, edited,
/// sent to the Trash, copied for the editor and exported.
///
/// - **Every change of a folder runs on the store's queue**, after every
///   `meeting.json` write asked before it: a note typed just before a rename
///   lands in the folder before it moves, and one sent to the old name while
///   it moved lands where it went (`renameTable`), never in a folder that is
///   gone.
/// - **Nothing this process records or finishes is touched** (`claim`), nor,
///   at the click, a folder another copy of the app holds.
/// - A meeting only ever goes to the **Trash**: a volume without one keeps
///   the meeting and says so.
/// - The scans run off the main thread; each video's length and tracks are
///   read once per change of the file (`ForkMeetingProbeCache`).
extension ForkMeetingStore {
    struct LibraryScan {
        let root: URL
        /// No meeting recorded yet: the folder is made at the first one.
        let rootExists: Bool
        let entries: [ForkMeetingLibraryEntry]
        /// What was measured of each row's playable file, by folder name.
        let probes: [String: ForkMeetingProbeCache.Probe]
        /// The folders this scan read, when it read only some
        /// (`ForkMeetingLibrary.Rescan`); `nil`: all of them.
        var only: Set<String>? = nil
    }

    enum LibraryFailure: Error, Equatable {
        /// Recording or finishing, here or in another copy of the app.
        case meetingInProgress
        /// The folder is not where the list saw it any more.
        case gone
        case renameRefused(ForkMeetingRename.Refusal)
        case editorCopyRefused(ForkMeetingEditorCopy.Refusal)
        case exportRefused(ForkMeetingAudioExport.Refusal)
        /// The file operation failed: why, for the log.
        case failed(String)
    }

    struct RenameResult: Equatable {
        /// The folder's name now: the new one, or the old one kept.
        let folderName: String
        let plan: ForkMeetingRename.Plan
        /// The plan's folder move was refused by the disk: only the title
        /// changed.
        let folderMoveFailed: Bool
        /// Media whose move the disk refused.
        let mediaKept: [String]
        /// The media that did move, old name to new, inside the folder.
        let mediaMoved: [ForkMeetingFolder.Move]
        /// `meeting.json` took the title (or had nothing to take). `false`:
        /// the folder may have moved, the title is not saved.
        let titleSaved: Bool
    }

    private static let libraryLog = Logger(subsystem: "fork.meetings", category: "library")

    // MARK: - Listing

    /// Every meeting folder in the meetings folder, as rows. Any thread; the
    /// scan runs off the main thread, `completion` on the callback queue.
    ///
    /// - `writing`: the folders (standardized paths) this app is recording
    ///   or finishing, from its service, besides the ones it holds locked.
    /// - `probing`: the videos are measured (length, tracks); the automatic
    ///   bin needs none of it.
    /// - `only`: these folders alone, the others left as the caller has
    ///   them.
    func scanLibrary(writing: Set<String> = [], probing: Bool = true, only: Set<String>? = nil,
                     completion: @escaping (LibraryScan) -> Void) {
        let root = self.root()
        Task.detached(priority: .utility) { [self] in
            var scan = await libraryScan(root: root, writing: writing, probing: probing, only: only)
            scan.only = only
            callbackQueue.async { completion(scan) }
        }
    }

    private func libraryScan(root: URL, writing: Set<String>, probing: Bool,
                             only: Set<String>? = nil) async -> LibraryScan {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? manager.contentsOfDirectory(atPath: root.path) else {
            return LibraryScan(root: root, rootExists: false, entries: [], probes: [:])
        }
        var entries: [ForkMeetingLibraryEntry] = []
        var probes: [String: ForkMeetingProbeCache.Probe] = [:]
        var measured = Set<String>()
        for name in names.sorted() where !name.hasPrefix(".") && only?.contains(name) != false {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard let first = libraryEntry(folder, writing: writing) else { continue }
            var probe: ForkMeetingProbeCache.Probe?
            if probing, let playable = first.entry.playable {
                let url = folder.appendingPathComponent(playable)
                probe = await ForkMeetingLibraryProbes.shared.probe(url)
                measured.insert(url.path)
            }
            if let probe { probes[name] = probe }
            entries.append(probe?.seconds == nil ? first.entry : first.measured(probe?.seconds) ?? first.entry)
        }
        // A partial scan saw only some files: the others' measures stay.
        if probing, only == nil { ForkMeetingLibraryProbes.shared.keep(only: measured) }
        return LibraryScan(root: root, rootExists: true, entries: entries, probes: probes)
    }

    /// One folder as the library reads it, unmeasured: `nil` for anything
    /// but a meeting's folder. Read straight from the disk: every write
    /// replaces `meeting.json` whole, so a read never meets half of one.
    private struct FolderLook {
        let entry: ForkMeetingLibraryEntry
        let sidecar: Result<ForkMeetingSidecar, ForkMeetingSidecarFault>
        let contents: ForkMeetingFolder.Contents
        let live: Bool
        let bytes: Int64
        let created: Date?

        /// The same row with the video's length the store measured.
        func measured(_ seconds: Double?) -> ForkMeetingLibraryEntry? {
            ForkMeetingLibraryEntry(folderName: entry.folderName, sidecar: sidecar, contents: contents, live: live,
                                    bytes: bytes, videoSeconds: seconds, folderCreated: created,
                                    videoModified: entry.videoModified, folderFile: entry.folderFile)
        }
    }

    private func libraryEntry(_ folder: URL, writing: Set<String>) -> FolderLook? {
        let manager = FileManager.default
        let name = folder.lastPathComponent
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let inside = try? manager.contentsOfDirectory(atPath: folder.path) else { return nil }
        guard inside.contains(ForkMeetingFolder.sidecarName) else { return nil }
        let sidecar = ForkMeetingSidecar.read(at: folder.appendingPathComponent(ForkMeetingFolder.sidecarName))
        let contents = ForkMeetingFolder.contents(of: inside, folderName: name,
                                                  alsoNamed: (try? sidecar.get())?.recordedName())
        let live = isClaimedHere(folder) || writing.contains(folder.standardizedFileURL.path)
        let bytes = Self.folderBytes(folder, names: inside)
        let attributes = try? manager.attributesOfItem(atPath: folder.path)
        let created = attributes?[.creationDate] as? Date
        let file = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        // A first look tells which file the row plays; its date then joins
        // the row, for the automatic bin.
        guard let first = ForkMeetingLibraryEntry(folderName: name, sidecar: sidecar, contents: contents, live: live,
                                                  bytes: bytes, folderCreated: created, folderFile: file) else { return nil }
        let modified = first.playable.flatMap {
            (try? manager.attributesOfItem(atPath: folder.appendingPathComponent($0).path))?[.modificationDate] as? Date
        }
        let entry = modified == nil ? first
            : ForkMeetingLibraryEntry(folderName: name, sidecar: sidecar, contents: contents, live: live, bytes: bytes,
                                      folderCreated: created, videoModified: modified, folderFile: file) ?? first
        return FolderLook(entry: entry, sidecar: sidecar, contents: contents, live: live, bytes: bytes, created: created)
    }

    /// What a meeting weighs: its files, the hidden master included.
    static func folderBytes(_ folder: URL, names: [String]) -> Int64 {
        names.reduce(Int64(0)) { total, name in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.size]
            return total + ((size as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Another copy of the app holds the folder's lock: its meeting records
    /// or finishes there. Asked only at the moment of an action on a folder
    /// that shows signs of it (`ForkMeetingLibraryLock`), never while
    /// scanning: the brief shared lock it takes would make that copy's
    /// recovery pass by.
    static func isLockedElsewhere(_ folder: URL) -> Bool {
        let descriptor = open(folder.path + "/" + lockName, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(descriptor, LOCK_UN)
        return false
    }

    /// Store queue. A meeting that is being written here, or elsewhere:
    /// the lock is asked whenever the folder shows signs of another copy at
    /// work (`ForkMeetingLibraryLock`).
    private func isBusy(_ folder: URL, live: Bool) -> Bool {
        if live || isClaimedHere(folder) { return true }
        let sidecar = ForkMeetingSidecar.read(at: folder.appendingPathComponent(ForkMeetingFolder.sidecarName))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let contents = ForkMeetingFolder.contents(of: names, folderName: folder.lastPathComponent)
        guard ForkMeetingLibraryLock.mayBeHeldElsewhere(sidecar, contents: contents) else { return false }
        return Self.isLockedElsewhere(folder)
    }

    /// Store queue. Where a write addressed to `folder` goes now.
    private func resolved(_ folder: URL) -> URL {
        let path = Self.tablePath(folder)
        let now = renameTable.resolve(path, fileAt: Self.fileNumber)
        return now == path ? folder : URL(fileURLWithPath: now, isDirectory: true)
    }

    /// A folder's path as the rename table keys it: its parent resolved by
    /// `realpath`, then its name. `standardizedFileURL` drops `/private` only
    /// for a path that exists, so a name before and after a move would not
    /// match.
    static func tablePath(_ folder: URL) -> String {
        ForkMeetingFolderWatch.realPath(folder.deletingLastPathComponent().path) + "/" + folder.lastPathComponent
    }

    static func fileNumber(_ path: String) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// The window writes to `folder`'s new name from now on: the move it
    /// made is forgotten once every write sent before is done. The store
    /// forgets it by itself after `ForkMeetingRenameTable.lifetime`, window
    /// or not.
    func forgetRename(of folder: URL) {
        let path = Self.tablePath(folder)
        queue.async { [self] in renameTable.forget(path) }
    }

    /// Waits, at most `seconds`, for everything asked of the store's queue
    /// so far. `false`: it was still busy. Off the store's queue.
    @discardableResult
    func drain(within seconds: TimeInterval) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + seconds) == .success
    }

    // MARK: - Title and notes

    /// Applies a library edit to the folder's `meeting.json`, after every
    /// write asked before, in the folder where it is now if a rename moved
    /// it meanwhile. A sidecar that does not decode, comes from a later
    /// version or from another app, is left as it is; so is a meeting
    /// another copy of the app holds (`meetingInProgress`). `expecting`: the
    /// meeting's id as the window shows it; a folder holding another
    /// meeting by then is left as it is (`gone`). `completion` on the
    /// callback queue.
    func applyEdit(_ edit: ForkMeetingSidecarEdit, in folder: URL, expecting id: UUID? = nil,
                   completion: ((Result<Void, LibraryFailure>) -> Void)? = nil) {
        queue.async { [self] in
            let written = writeEdit(edit, in: resolved(folder), expecting: id)
            if let completion { callbackQueue.async { completion(written) } }
        }
    }

    /// Store queue.
    private func writeEdit(_ edit: ForkMeetingSidecarEdit, in folder: URL,
                           expecting id: UUID? = nil) -> Result<Void, LibraryFailure> {
        guard !isBusy(folder, live: false) else {
            Self.libraryLog.error("edit refused, the meeting is being written: \(folder.lastPathComponent, privacy: .private)")
            return .failure(.meetingInProgress)
        }
        let read = ForkMeetingSidecar.read(at: folder.appendingPathComponent(ForkMeetingFolder.sidecarName))
        if let id, (try? read.get())?.id != id {
            Self.libraryLog.error("edit refused, another meeting is there now: \(folder.lastPathComponent, privacy: .private)")
            return .failure(.gone)
        }
        guard let next = ForkMeetingSidecarEdit.rewriting(read, with: edit) else {
            Self.libraryLog.error("edit left out in \(folder.lastPathComponent, privacy: .private)")
            return .failure(.failed("meeting.json not rewritable"))
        }
        if let failure = writeSidecar(next, in: folder) { return .failure(.failed(failure)) }
        return .success(())
    }

    // MARK: - Renaming

    /// The title the person committed: `meeting.json` says it
    /// (`titleSource: user`), and the folder and its media take its name
    /// when they still carry the stamp (`ForkMeetingRename.plan`). Any
    /// thread; the work runs on the store's queue, `completion` on the
    /// callback queue.
    func renameMeeting(_ folderName: String, title: String, live: Bool,
                       completion: @escaping (Result<RenameResult, LibraryFailure>) -> Void) {
        let root = self.root()
        queue.async { [self] in
            let result = rename(folderName, in: root, title: title, live: live)
            callbackQueue.async { completion(result) }
        }
    }

    private func rename(_ folderName: String, in root: URL, title: String,
                        live: Bool) -> Result<RenameResult, LibraryFailure> {
        let manager = FileManager.default
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return .failure(.gone) }
        let read = ForkMeetingSidecar.read(at: folder.appendingPathComponent(ForkMeetingFolder.sidecarName))
        let id = (try? read.get())?.id
        let plan: ForkMeetingRename.Plan
        switch ForkMeetingRename.plan(title: title, folderName: folderName, sidecar: read, names: names,
                                      live: isBusy(folder, live: live),
                                      occupant: ForkMeetingRename.occupant(
                                          sameFolder: { Self.isSameFile(root.appendingPathComponent($0, isDirectory: true), folder) },
                                          disk: { Self.occupant(of: root.appendingPathComponent($0, isDirectory: true), id: id) })) {
        case let .failure(refusal): return .failure(.renameRefused(refusal))
        case let .success(made): plan = made
        }
        var current = folderName
        var folderMoveFailed = false
        if let move = plan.folder {
            let to = root.appendingPathComponent(move.to, isDirectory: true)
            do {
                try manager.moveItem(at: root.appendingPathComponent(move.from, isDirectory: true), to: to)
                current = move.to
                // Writes still addressed to the old name land here, for a
                // while.
                let old = Self.tablePath(folder), new = Self.tablePath(to)
                renameTable.record(from: old, to: new, file: Self.fileNumber(to.path))
                queue.asyncAfter(deadline: .now() + ForkMeetingRenameTable.lifetime) { [self] in
                    renameTable.forget(old, to: new)
                }
            } catch {
                folderMoveFailed = true
                Self.libraryLog.error("folder kept its name: \(error.localizedDescription, privacy: .private)")
            }
        }
        let now = root.appendingPathComponent(current, isDirectory: true)
        var mediaKept = plan.media.blocked
        var mediaMoved: [ForkMeetingFolder.Move] = []
        if !folderMoveFailed {
            for move in plan.media.moves {
                do {
                    try manager.moveItem(at: now.appendingPathComponent(move.from), to: now.appendingPathComponent(move.to))
                    mediaMoved.append(move)
                } catch {
                    mediaKept.append(move.from)
                }
            }
        }
        // The video's entry in Recent captures, when the meeting is listed
        // there, follows it.
        let video = ForkMeetingFolder.contents(of: names, folderName: folderName,
                                               alsoNamed: (try? read.get())?.recordedName()).video
        if let video, current != folderName {
            let moved = mediaMoved.first { $0.from == video }?.to ?? video
            recentCaptureMoved(folder.appendingPathComponent(video), now.appendingPathComponent(moved))
        }
        var titleSaved = true
        if let edit = plan.edit, case .failure = writeEdit(edit, in: now) {
            // The folder may have moved all the same: the window follows it.
            titleSaved = false
        }
        return .success(RenameResult(folderName: current, plan: plan, folderMoveFailed: folderMoveFailed,
                                     mediaKept: mediaKept, mediaMoved: mediaMoved, titleSaved: titleSaved))
    }

    // MARK: - Trash

    /// Moves the meeting's folder to the Trash, never deletes it: a volume
    /// without a Trash keeps it, and the failure says so. Refused for a
    /// meeting being written. `completion` on the callback queue, with
    /// where the folder now is.
    func trashMeeting(_ folderName: String, live: Bool, completion: @escaping (Result<URL?, LibraryFailure>) -> Void) {
        let root = self.root()
        queue.async { [self] in
            let result = trash(folderName, in: root, live: live)
            callbackQueue.async { completion(result) }
        }
    }

    /// Store queue.
    private func trash(_ folderName: String, in root: URL, live: Bool) -> Result<URL?, LibraryFailure> {
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return .failure(.gone) }
        guard !isBusy(folder, live: live) else { return .failure(.meetingInProgress) }
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: &trashed)
            return .success(trashed as URL?)
        } catch {
            Self.libraryLog.error("not moved to the Trash: \(error.localizedDescription, privacy: .private)")
            return .failure(.failed(error.localizedDescription))
        }
    }

    // MARK: - Automatic bin

    /// The meetings `days` would send to the Trash now
    /// (`ForkMeetingRetention.due`), and how many the library lists.
    /// `completion` on the callback queue.
    func retentionDue(days: Int, now: Date = Date(), writing: Set<String> = [], calendar: Calendar = .current,
                      completion: @escaping (_ due: [String], _ library: Int) -> Void) {
        scanLibrary(writing: writing, probing: false) { scan in
            completion(ForkMeetingRetention.due(scan.entries, days: days, now: now, calendar: calendar), scan.entries.count)
        }
    }

    /// Sends what `days` makes due to the Trash, unless there is too much
    /// of it at once (`ForkMeetingRetention.sweep`): then nothing goes and
    /// the outcome says how many wait. Each folder is its own turn on the
    /// store's queue, its `meeting.json` read again right before it goes:
    /// a note typed meanwhile, or a quit, never waits behind the whole
    /// sweep, and a meeting that changed since the scan is judged as it is
    /// now. `confirmed`: the number the person agreed to. `stop`: once
    /// cancelled (the feature turned off), no further folder goes.
    /// `completion` on the callback queue.
    func sweepRetention(days: Int, now: Date = Date(), writing: Set<String> = [], calendar: Calendar = .current,
                        confirmed: Int? = nil, stop: ForkMeetingSweepStop? = nil,
                        completion: ((ForkMeetingRetention.Sweep) -> Void)? = nil) {
        retentionDue(days: days, now: now, writing: writing, calendar: calendar) { [self] due, library in
            if stop?.isCancelled == true {
                callbackQueue.async { completion?(.trash([])) }
                return
            }
            let decided = ForkMeetingRetention.sweep(due: due, library: library, confirmed: confirmed)
            guard case let .trash(names) = decided else {
                if case let .held(count) = decided {
                    Self.libraryLog.notice("automatic bin held: \(count, privacy: .public) of \(library, privacy: .public) meetings")
                }
                callbackQueue.async { completion?(decided) }
                return
            }
            let root = self.root()
            let gone = ForkMeetingSweepTally()
            for name in names {
                queue.async { [self] in
                    let folder = root.appendingPathComponent(name, isDirectory: true)
                    // Judged again as the folder is now.
                    guard stop?.isCancelled != true, !writing.contains(folder.standardizedFileURL.path),
                          let look = libraryEntry(folder, writing: writing),
                          ForkMeetingRetention.verdict(look.entry, days: days, now: now, calendar: calendar) == .trash,
                          case .success = trash(name, in: root, live: false) else { return }
                    gone.add(name)
                }
            }
            queue.async { [self] in
                let names = gone.names
                if !names.isEmpty { Self.libraryLog.notice("automatic bin: \(names.count, privacy: .public) meetings") }
                callbackQueue.async { completion?(.trash(names)) }
            }
        }
    }

    // MARK: - Editor

    /// A copy of the meeting for the official editor, in a new take of its
    /// own store, which the editor removes when it closes: the meeting's
    /// files are only read (`ForkMeetingEditorCopy`). `editorAvailable` is
    /// read on the main thread by the caller. `completion` on the callback
    /// queue with the take, for `ScreenRecorderService.openEditor`.
    func makeEditorTake(for entry: ForkMeetingLibraryEntry, probe: ForkMeetingProbeCache.Probe?,
                        editorAvailable: Bool, live: Bool,
                        completion: @escaping (Result<RecorderTakeStore.Take, LibraryFailure>) -> Void) {
        let folder = root().appendingPathComponent(entry.folderName, isDirectory: true)
        let plan: ForkMeetingEditorCopy.Plan
        switch ForkMeetingEditorCopy.plan(entry, audioTracks: probe?.audioTracks, editorAvailable: editorAvailable,
                                          live: live || isClaimedHere(folder)) {
        case let .failure(refusal):
            callbackQueue.async { completion(.failure(.editorCopyRefused(refusal))) }
            return
        case let .success(made): plan = made
        }
        let source = folder.appendingPathComponent(plan.source)
        let count = probe?.audioTracks ?? 0
        Task.detached(priority: .userInitiated) { [callbackQueue] in
            let result = await Self.editorTake(from: source, plan: plan, audioTracks: count)
            callbackQueue.async { completion(result) }
        }
    }

    private static func editorTake(from source: URL, plan: ForkMeetingEditorCopy.Plan,
                                   audioTracks: Int) async -> Result<RecorderTakeStore.Take, LibraryFailure> {
        let takes = RecorderTakeStore.shared
        switch plan.audio {
        case .asIs:
            // A clone on the same volume (APFS): nothing to wait for.
            guard let take = takes.importVideo(at: source) else { return .failure(.failed("the copy was refused")) }
            return .success(take)
        case .withoutMix:
            let size = ForkMeetingFinalizer.fileSize(source) ?? 0
            guard RecorderTakeStore.canImport(fileSize: size, availableBytes: takes.freeBytes()),
                  let take = takes.makeTake() else { return .failure(.failed("no room for the copy")) }
            do {
                try await ForkMeetingLibraryMedia.copyForEditor(
                    from: source, keeping: ForkMeetingEditorCopy.keptAudioTracks(plan, count: audioTracks), to: take.videoURL)
                return .success(take)
            } catch {
                takes.delete(take)
                return .failure(.failed(String(describing: error)))
            }
        }
    }

    // MARK: - Export

    /// The meeting's audio as an M4A at `destination`, the place the person
    /// chose (`ForkMeetingAudioExport`). `completion` on the callback queue.
    func exportAudio(of entry: ForkMeetingLibraryEntry, probe: ForkMeetingProbeCache.Probe?, live: Bool,
                     to destination: URL, completion: @escaping (Result<Void, LibraryFailure>) -> Void) {
        let folder = root().appendingPathComponent(entry.folderName, isDirectory: true)
        let route: ForkMeetingAudioExport.Route
        switch ForkMeetingAudioExport.route(entry, probe: probe, live: live || isClaimedHere(folder)) {
        case let .failure(refusal):
            callbackQueue.async { completion(.failure(.exportRefused(refusal))) }
            return
        case let .success(made): route = made
        }
        Task.detached(priority: .userInitiated) { [callbackQueue] in
            let result: Result<Void, LibraryFailure>
            do {
                try await ForkMeetingLibraryMedia.exportAudio(route, folder: folder, to: destination)
                result = .success(())
            } catch {
                result = .failure(.failed(String(describing: error)))
            }
            callbackQueue.async { completion(result) }
        }
    }
}

/// Cancels a sweep between two folders: the feature turned off, or the
/// setting changed. Any thread.
final class ForkMeetingSweepStop: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}

/// The folders a sweep sent to the Trash, gathered across its turns on
/// the store's queue.
private final class ForkMeetingSweepTally: @unchecked Sendable {
    private let lock = NSLock()
    private var gone: [String] = []

    var names: [String] { lock.withLock { gone } }

    func add(_ name: String) { lock.withLock { gone.append(name) } }
}

/// The videos' measures, kept between scans and shared by every scan:
/// `ForkMeetingProbeCache` behind a lock. Any thread.
final class ForkMeetingLibraryProbes: @unchecked Sendable {
    static let shared = ForkMeetingLibraryProbes()

    private let lock = NSLock()
    private var cache = ForkMeetingProbeCache()
    private var opened = 0

    /// How many files were opened since launch, for the recipe harness.
    var openedCount: Int { lock.withLock { opened } }

    /// The file's measure: the one kept while its date and size hold, a
    /// fresh one otherwise.
    func probe(_ url: URL) async -> ForkMeetingProbeCache.Probe {
        let stamp = ForkMeetingLibraryMedia.stamp(url)
        if let known = lock.withLock({ cache.probe(for: url.path, stamp: stamp) }) { return known }
        let probe = await ForkMeetingLibraryMedia.probe(url)
        lock.withLock {
            opened += 1
            cache.remember(probe, for: url.path, stamp: stamp)
        }
        return probe
    }

    func keep(only paths: Set<String>) {
        lock.withLock { cache.keep(only: paths) }
    }
}
