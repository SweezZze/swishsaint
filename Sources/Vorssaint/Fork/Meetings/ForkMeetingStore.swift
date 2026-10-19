// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AVFoundation
import Foundation
import os

/// The meetings on the disk: where they go, the folder of a new one, every
/// write of its `meeting.json`, and what a launch finds unfinished.
///
/// - **One serial queue writes every `meeting.json`**, in the order asked: a
///   pause noted, then the stop, then the final pass, never the other way
///   round. Each write reads the file as it is, applies its patch and
///   replaces the file through a draft (`replaceItemAt`), so a crash leaves
///   the old file or the new one, never half of one. A file that does not
///   decode, or comes from a later version, is never rewritten.
/// - **A folder being recorded or finished is locked** (`claim`), with an
///   advisory lock the system drops when the process dies, `kill -9`
///   included: the launch of a second copy of the app (a local build beside
///   the installed one) never takes a live recording for a crashed one.
/// - Nothing here removes a file the recovery plan did not allow to remove.
///
/// The library (listing, renaming, notes, the Trash) is in `+Library`.
final class ForkMeetingStore: @unchecked Sendable {
    static let shared = ForkMeetingStore()

    enum Failure: Error, Equatable {
        /// A folder is being made for another start: two starts in the same
        /// instant would otherwise make a second, ghost folder.
        case alreadyOpening
        /// The meetings folder or the meeting's own could not be made:
        /// read-only, volume gone.
        case folderUnavailable(String)
        /// Fifty folders already carry this meeting's name.
        case namesExhausted
        /// The folder is there but its first `meeting.json` was refused.
        case sidecarNotWritten(String)
    }

    /// What the launch did with one unfinished folder.
    struct Recovery: Equatable {
        let folder: URL
        let action: ForkMeetingRecoveryPlan.Action
        /// The final pass, when one ran.
        let outcome: ForkMeetingFinalizer.Outcome?
        /// How long the meeting now plays, when it does.
        let seconds: TimeInterval?

        /// A meeting that never closed (a crash, a quit) and plays again:
        /// "Meeting recovered · 37 min".
        var isRecovered: Bool {
            guard case let .finalize(_, recovered, _) = action, recovered else { return false }
            return outcome?.succeeded == true
        }
    }

    /// The draft every `meeting.json` is written to before it replaces the
    /// file. Hidden, so the folder's contents never count it.
    static let sidecarDraftName = ".meeting.json.draft"
    /// Held while a meeting records and while its final pass runs.
    static let lockName = ".meeting.lock"

    private static let log = Logger(subsystem: "fork.meetings", category: "store")
    /// Who may read a meeting: its owner alone, wherever the folder is (a
    /// folder chosen outside Movies may be readable by every account).
    static let folderPermissions: Int16 = 0o700

    private let defaults: UserDefaults
    private let strings: () -> ForkMeetingStrings
    let callbackQueue: DispatchQueue
    /// Where a finished meeting is listed; the official Recent captures in
    /// the app.
    private let recentCaptures: (URL) -> Void
    /// A listed meeting's video renamed from the library: its entry in the
    /// official Recent captures follows it (old, new).
    let recentCaptureMoved: (URL, URL) -> Void
    /// Store queue only: the folders the library renamed, until the window
    /// stops writing to their old names (`ForkMeetingRenameTable`).
    var renameTable = ForkMeetingRenameTable()
    /// Every write of a `meeting.json`, and the making of a folder; the
    /// library's renames and moves to the Trash too (`+Library`).
    let queue = DispatchQueue(label: "fork.meetings.store", qos: .utility)
    private let lock = NSLock()
    /// Under `lock`: a folder is being made.
    private var opening = false
    /// Under `lock`: the folders this process made, by meeting. Their
    /// meeting is this process's business: the recovery never touches them.
    private var made: [UUID: URL] = [:]
    /// Under `lock`: the lock file held for each claimed folder, by path.
    private var claims: [String: Int32] = [:]

    /// - Parameters:
    ///   - callbackQueue: where every completion is called; the main queue
    ///     in the app.
    ///   - recentCaptures: lists a finished meeting's video, any thread;
    ///     the official Recent captures by default.
    init(defaults: UserDefaults = .standard,
         strings: @escaping () -> ForkMeetingStrings = { ForkMeetingStrings.current },
         callbackQueue: DispatchQueue = .main,
         recentCaptures: @escaping (URL) -> Void = ForkMeetingStore.officialRecentCaptures,
         recentCaptureMoved: @escaping (URL, URL) -> Void = ForkMeetingStore.officialRecentCaptureMoved) {
        self.defaults = defaults
        self.strings = strings
        self.callbackQueue = callbackQueue
        self.recentCaptures = recentCaptures
        self.recentCaptureMoved = recentCaptureMoved
    }

    // MARK: - Root

    /// The meetings folder. Any thread. `storing` freezes the default path
    /// (a folder named in the person's language) in the settings, so a later
    /// change of language does not move the library: done when a first
    /// meeting is made there.
    func root(storing: Bool = false) -> URL {
        let manager = FileManager.default
        let movies = manager.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        let stored = defaults.string(forKey: ForkDefaultsKey.meetingsFolder) ?? ""
        let root = ForkMeetingFolder.root(stored: stored, movies: movies, strings: strings())
        if storing, root.needsStoring {
            defaults.set(root.url.path, forKey: ForkDefaultsKey.meetingsFolder)
        }
        return root.url
    }

    // MARK: - A new meeting

    /// Makes the folder of a meeting about to record and writes its first
    /// `meeting.json` (`state: recording`, no end): from then on a missing
    /// end is the mark of a meeting that did not end well.
    ///
    /// Any thread; the work runs on the store's queue, `completion` once on
    /// the callback queue. The same `id` asked again gets the same folder,
    /// never a sibling; another start while a folder is being made is
    /// refused (`alreadyOpening`). The folder comes back claimed.
    func createMeeting(id: UUID, startedAt: Date, origin: ForkMeetingOrigin, title: String?,
                       titleSource: ForkMeetingSidecar.TitleSource?, capture: ForkMeetingSidecar.Capture,
                       meeting: ForkMeetingCandidate? = nil,
                       completion: @escaping (Result<URL, Failure>) -> Void) {
        lock.lock()
        if let known = made[id] {
            lock.unlock()
            callbackQueue.async { completion(.success(known)) }
            return
        }
        guard !opening else {
            lock.unlock()
            callbackQueue.async { completion(.failure(.alreadyOpening)) }
            return
        }
        opening = true
        lock.unlock()

        let root = self.root()
        let started = ForkMeetingSidecar.started(id: id, startedAt: startedAt, origin: origin, title: title,
                                                 titleSource: titleSource, capture: capture,
                                                 provider: meeting?.provider, meetCode: meeting?.meetCode,
                                                 app: meeting?.appBundle)
        queue.async { [self] in
            let result = makeFolder(in: root, for: started, id: id,
                                    name: ForkMeetingFolder.name(startedAt: startedAt, title: title))
            lock.lock()
            opening = false
            if case let .success(folder) = result { made[id] = folder } else { made[id] = nil }
            lock.unlock()
            if case let .success(folder) = result {
                _ = self.root(storing: true)
                claim(folder)
            }
            callbackQueue.async { completion(result) }
        }
    }

    /// Store queue. The folder is this process's (`made`) before it exists:
    /// a recovery scanning meanwhile never takes a meeting about to record
    /// for one a crash left.
    private func makeFolder(in root: URL, for sidecar: ForkMeetingSidecar, id: UUID,
                            name base: String) -> Result<URL, Failure> {
        let manager = FileManager.default
        // The meetings folder itself, never its parents: a folder chosen on
        // a disk that is not plugged in must not be made again, empty, on
        // the Mac's own disk under /Volumes.
        if !manager.fileExists(atPath: root.path) {
            do {
                try manager.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: Self.folderPermissions])
            } catch {
                return .failure(.folderUnavailable(error.localizedDescription))
            }
        }
        func occupant(_ name: String) -> ForkMeetingFolder.Occupant {
            Self.occupant(of: root.appendingPathComponent(name, isDirectory: true), id: id)
        }
        func reserve(_ folder: URL) {
            lock.withLock { made[id] = folder }
        }
        let folder: URL
        var createdHere = false
        switch ForkMeetingFolder.reserve(base: base, occupant: occupant) {
        case .exhausted:
            return .failure(.namesExhausted)
        case let .adopt(name):
            folder = root.appendingPathComponent(name, isDirectory: true)
            reserve(folder)
            // Ours already, sidecar included: nothing to write again.
            if occupant(name) == .sameMeeting { return .success(folder) }
            // An empty folder of ours left behind: closed to the others too.
            try? manager.setAttributes([.posixPermissions: Self.folderPermissions], ofItemAtPath: folder.path)
        case let .create(name):
            folder = root.appendingPathComponent(name, isDirectory: true)
            reserve(folder)
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: Self.folderPermissions])
                createdHere = true
            } catch {
                return .failure(.folderUnavailable(error.localizedDescription))
            }
        }
        if let failure = writeSidecar(sidecar, in: folder) {
            // Without a sidecar the folder is not a meeting's: one made here
            // and still empty goes, so the library never shows a ghost.
            if createdHere, (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? manager.removeItem(at: folder)
            }
            return .failure(.sidecarNotWritten(failure))
        }
        return .success(folder)
    }

    static func occupant(of folder: URL, id: UUID?) -> ForkMeetingFolder.Occupant {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return .free }
        guard isDirectory.boolValue else { return .taken }
        switch ForkMeetingSidecar.read(at: folder.appendingPathComponent(ForkMeetingFolder.sidecarName)) {
        case .failure(.absent): return isAdoptable(folder) ? .folderWithoutSidecar : .taken
        case let .success(sidecar) where sidecar.id != nil && sidecar.id == id: return .sameMeeting
        default: return .taken
        }
    }

    /// A folder without a `meeting.json` is taken over only when it is ours
    /// and holds nothing (a start that died before its first write, or a
    /// folder the Finder opened): never one that belongs to another account,
    /// whose files a meeting would then be written among.
    static func isAdoptable(_ folder: URL) -> Bool {
        let manager = FileManager.default
        guard let owner = (try? manager.attributesOfItem(atPath: folder.path))?[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return false }
        return names.allSatisfy { $0 == ".DS_Store" }
    }

    // MARK: - meeting.json

    /// Applies `patch` to the folder's `meeting.json`, after every write
    /// asked before. Any thread; `completion`, if any, on the callback
    /// queue: `false` when the file was left as it is (missing, corrupt,
    /// from a later version) or could not be written.
    func update(_ folder: URL, with patch: ForkMeetingSidecarPatch, completion: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            let written = apply(patch, in: folder)
            if let completion { callbackQueue.async { completion(written) } }
        }
    }

    /// The same, waiting for the write. Off the main thread, never on the
    /// store's queue: for the finalizer and the recovery, which must know
    /// the file is written before they go on.
    @discardableResult
    func write(_ patch: ForkMeetingSidecarPatch, in folder: URL) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { apply(patch, in: folder) }
    }

    /// `meeting.json` as it is once every write asked before is done. Off
    /// the store's queue.
    func sidecar(in folder: URL) -> Result<ForkMeetingSidecar, ForkMeetingSidecarFault> {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { ForkMeetingSidecar.read(at: folder.appendingPathComponent(ForkMeetingFolder.sidecarName)) }
    }

    /// Store queue.
    private func apply(_ patch: ForkMeetingSidecarPatch, in folder: URL) -> Bool {
        let url = folder.appendingPathComponent(ForkMeetingFolder.sidecarName)
        let read = ForkMeetingSidecar.read(at: url)
        guard let next = ForkMeetingSidecar.rewriting(read, with: patch) else {
            Self.log.error("meeting.json left as it is in \(folder.lastPathComponent, privacy: .private): \(String(describing: read), privacy: .private)")
            return false
        }
        return writeSidecar(next, in: folder) == nil
    }

    /// Store queue. Through a draft, then `replaceItemAt`: never a removal
    /// followed by a write, which a crash in between would leave with no
    /// sidecar at all. `nil` when written, else why not.
    func writeSidecar(_ sidecar: ForkMeetingSidecar, in folder: URL) -> String? {
        let manager = FileManager.default
        let target = folder.appendingPathComponent(ForkMeetingFolder.sidecarName)
        let draft = folder.appendingPathComponent(Self.sidecarDraftName)
        do {
            let data = try sidecar.encoded()
            try? manager.removeItem(at: draft)
            try data.write(to: draft)
            try Self.replace(target, with: draft)
            return nil
        } catch {
            try? manager.removeItem(at: draft)
            Self.log.error("meeting.json not written in \(folder.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return error.localizedDescription
        }
    }

    /// `replaceItemAt` creates the destination when it is missing (measured
    /// in spike S1, on macOS 26 and 27); the move stays as a fallback
    /// for a volume that refuses.
    static func replace(_ destination: URL, with source: URL) throws {
        let manager = FileManager.default
        do {
            _ = try manager.replaceItemAt(destination, withItemAt: source)
        } catch {
            guard !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: source.path) else {
                throw error
            }
            try manager.moveItem(at: source, to: destination)
        }
    }

    // MARK: - Lock

    /// Takes the folder's lock for this process, or confirms it holds it.
    /// `false` only when another process holds it: its meeting is live
    /// there. A volume that cannot lock (some network shares) never blocks.
    /// Any thread.
    @discardableResult
    func claim(_ folder: URL) -> Bool {
        claim(folder, sharedHere: true)
    }

    /// `sharedHere` false: refused too when this process holds it already
    /// (the recovery never takes a lock a meeting of this process holds).
    private func claim(_ folder: URL, sharedHere: Bool) -> Bool {
        let path = folder.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if claims[path] != nil { return sharedHere }
        let descriptor = open(path + "/" + Self.lockName, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return true }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(descriptor)
            return reason != EWOULDBLOCK
        }
        claims[path] = descriptor
        return true
    }

    /// Drops the folder's lock and its file. Any thread; nothing when not held.
    func release(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        lock.lock()
        let descriptor = claims.removeValue(forKey: path)
        lock.unlock()
        guard let descriptor else { return }
        unlink(path + "/" + Self.lockName)
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// This process holds the folder's lock: a meeting of its own records
    /// or finishes there.
    func isClaimedHere(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        return lock.withLock { claims[path] != nil }
    }

    /// The lock for the recovery alone: refused when this process already
    /// holds it, not only when another one does.
    private func claimForRecovery(_ folder: URL) -> Bool {
        claim(folder, sharedHere: false)
    }

    private func isMadeHere(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        return made.values.contains { $0.standardizedFileURL.path == path }
    }

    // MARK: - Launch

    /// Finds what the last run left unfinished and does what
    /// `ForkMeetingRecoveryPlan` says: final pass again, complete, mark
    /// interrupted, or a cancelled one to the Trash. Never touches a folder this process made, nor one
    /// another copy of the app holds.
    ///
    /// Any thread; the scan runs off the main thread, final passes one at
    /// a time through `finalizer`; `completion` once on the callback queue,
    /// with every folder acted on.
    func recoverAtLaunch(using finalizer: ForkMeetingFinalizer, extractAudio: Bool,
                         titles: ForkMeetingFinalizer.TrackTitles = .standard,
                         completion: @escaping ([Recovery]) -> Void) {
        let root = self.root()
        Task.detached(priority: .utility) { [self] in
            let found = await recover(root: root, finalizer: finalizer, extractAudio: extractAudio, titles: titles)
            callbackQueue.async { completion(found) }
        }
    }

    private func recover(root: URL, finalizer: ForkMeetingFinalizer, extractAudio: Bool,
                         titles: ForkMeetingFinalizer.TrackTitles) async -> [Recovery] {
        let manager = FileManager.default
        // No folder yet is the first launch, not a problem.
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return [] }
        var found: [Recovery] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !isMadeHere(folder), !isClaimedHere(folder),
                  let entries = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
            let contents = ForkMeetingFolder.contents(of: entries, folderName: name)
            guard contents.hasSidecar else { continue }
            let sidecar = self.sidecar(in: folder)
            guard ForkMeetingRecoveryPlan.needsInspection(sidecar, contents: contents) else { continue }
            // Before probing anything: a master another copy of the app is
            // still writing must not even be opened, nor one this process
            // claimed in the meantime (its claim is never shared, nor let go
            // by the recovery).
            guard claimForRecovery(folder) else { continue }
            guard !isMadeHere(folder) else {
                release(folder)
                continue
            }
            if let recovery = await recover(folder, contents: contents, sidecar: sidecar, finalizer: finalizer,
                                            extractAudio: extractAudio, titles: titles) {
                found.append(recovery)
            }
            release(folder)
        }
        return found
    }

    private func recover(_ folder: URL, contents: ForkMeetingFolder.Contents,
                         sidecar: Result<ForkMeetingSidecar, ForkMeetingSidecarFault>,
                         finalizer: ForkMeetingFinalizer, extractAudio: Bool,
                         titles: ForkMeetingFinalizer.TrackTitles) async -> Recovery? {
        let manager = FileManager.default
        let master = folder.appendingPathComponent(ForkMeetingFolder.masterName)
        // The final file: the video, or the `.m4a` of a meeting without picture.
        let audioOnly = (try? sidecar.get())?.isAudioOnly == true
        let video = contents.media(audioOnly: audioOnly).map { folder.appendingPathComponent($0) }
        var facts = ForkMeetingRecoveryPlan.Facts(sidecar: sidecar,
                                                  hasDrafts: contents.hasVideoDraft || contents.hasAudioDraft)
        if contents.hasMaster {
            facts.master = ForkMeetingRecoveryPlan.Media(duration: await ForkMeetingFinalizer.playableSeconds(at: master))
        }
        if let video {
            facts.final = ForkMeetingRecoveryPlan.Media(duration: await ForkMeetingFinalizer.playableSeconds(at: video))
            facts.finalIsMaster = contents.hasMaster && Self.isSameFile(video, master)
        }
        let action = ForkMeetingRecoveryPlan.plan(facts)
        let patch = ForkMeetingRecoveryPlan.patch(for: action, facts: facts)
        Self.log.notice("recovery of \(folder.lastPathComponent, privacy: .private): \(String(describing: action), privacy: .public)")

        switch action {
        case .leave:
            return nil
        case .discard:
            // The lock first: it is in the folder.
            release(folder)
            let outcome = ForkMeetingDiscardOutcome.discard(trash: { try manager.trashItem(at: folder, resultingItemURL: nil) },
                                                            remove: { try manager.removeItem(at: folder) })
            if outcome == .kept { Self.log.error("a cancelled meeting stays in its folder") }
            return nil
        case .markInterrupted:
            if let patch { write(patch, in: folder) }
            return Recovery(folder: folder, action: action, outcome: nil, seconds: nil)
        case let .complete(removeMaster, discardDrafts):
            if let patch { write(patch, in: folder) }
            if removeMaster { try? manager.removeItem(at: master) }
            if discardDrafts { discardDraftFiles(in: folder) }
            // The app died between the final file and its M4A: made again,
            // from the final file's mix. Without picture the final file is
            // the M4A, and Recent captures lists only what was filmed.
            if extractAudio, !audioOnly, contents.audio == nil, let video {
                await finalizer.remakeAudio(from: video)
            }
            if let video, !audioOnly { addToRecentCaptures(video) }
            return Recovery(folder: folder, action: action, outcome: nil, seconds: facts.final?.duration)
        case .finalize:
            // The finalizer drops the stale drafts itself before it writes.
            if let patch { write(patch, in: folder) }
            let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<ForkMeetingFinalizer.Outcome, Never>) in
                finalizer.finalize(folder, extractAudio: extractAudio, titles: titles) { continuation.resume(returning: $0) }
            }
            return Recovery(folder: folder, action: action, outcome: outcome, seconds: outcome.seconds)
        }
    }

    private func discardDraftFiles(in folder: URL) {
        for name in [ForkMeetingFolder.videoDraftName, ForkMeetingFolder.audioDraftName] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: - A final pass that failed

    /// Where the recording of a meeting whose final pass failed now is.
    enum Revealed: Equatable {
        /// Under the meeting's name, where a final file would be.
        case visible(URL)
        /// Still under its hidden name: it does not play, or could not be
        /// given the name.
        case hidden(URL)
        /// No master at all.
        case none
        /// Another copy of the app holds the folder.
        case elsewhere
    }

    /// Shows the master of a meeting whose final pass failed under the
    /// meeting's name, when it plays (`readable`): a second name for the
    /// same file (a hard link), so its tracks stay separate, as when the
    /// pass is skipped for room, and the master stays where the next launch
    /// looks for it. `meeting.json` keeps `finalizing` and its pass `failed`:
    /// the next launch makes the pass's last try, and a file there it is
    /// the master's own (`ForkMeetingRecoveryPlan.Facts.finalIsMaster`). On
    /// a volume without hard links the master takes the name instead and
    /// the meeting is `complete`, as before. Never over a final file already
    /// there, never in a folder another copy of the app holds. Any thread;
    /// `completion` on the callback queue.
    func revealMaster(in folder: URL, readable: Bool, completion: @escaping (Revealed) -> Void) {
        queue.async { [self] in
            let revealed = reveal(folder, readable: readable)
            callbackQueue.async { completion(revealed) }
        }
    }

    /// Store queue.
    private func reveal(_ folder: URL, readable: Bool) -> Revealed {
        let manager = FileManager.default
        let master = folder.appendingPathComponent(ForkMeetingFolder.masterName)
        guard manager.fileExists(atPath: master.path) else { return .none }
        let path = folder.standardizedFileURL.path
        let held = lock.withLock { claims[path] != nil }
        guard claim(folder) else { return .elsewhere }
        defer { if !held { release(folder) } }
        // A master that does not play is never shown as the meeting.
        guard readable else { return .hidden(master) }
        // Without picture, under the `.m4a`'s name: an MP4 and an M4A are
        // the same container.
        let audioOnly = (try? ForkMeetingSidecar.read(at: folder.appendingPathComponent(ForkMeetingFolder.sidecarName))
            .get())?.isAudioOnly == true
        let final = folder.appendingPathComponent(
            "\(folder.lastPathComponent).\(ForkMeetingFolder.finalExtension(audioOnly: audioOnly))")
        if manager.fileExists(atPath: final.path) {
            // Shown already (its pass's last try failed too), or a real
            // final file, never written over.
            return Self.isSameFile(final, master) ? .visible(final) : .hidden(master)
        }
        do {
            try manager.linkItem(at: master, to: final)
        } catch {
            do {
                try Self.replace(final, with: master)
            } catch {
                Self.log.error("master left hidden in \(folder.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
                return .hidden(master)
            }
            _ = apply(ForkMeetingSidecarPatch(state: .complete), in: folder)
        }
        if !audioOnly { addToRecentCaptures(final) }
        return .visible(final)
    }

    /// Two names of one file (a hard link): same volume, same file number.
    static func isSameFile(_ one: URL, _ other: URL) -> Bool {
        let manager = FileManager.default
        guard let a = try? manager.attributesOfItem(atPath: one.path),
              let b = try? manager.attributesOfItem(atPath: other.path),
              let fileA = a[.systemFileNumber] as? NSNumber, let fileB = b[.systemFileNumber] as? NSNumber,
              let volumeA = a[.systemNumber] as? NSNumber, let volumeB = b[.systemNumber] as? NSNumber else { return false }
        return fileA == fileB && volumeA == volumeB
    }

    // MARK: - Recent captures

    /// Adds a finished meeting to the official Recent captures, as the
    /// official recorder does for a recording it saves outside its own
    /// folders: only the path is kept there, the file stays where it is,
    /// and an entry whose file moved or went away is dropped by itself.
    /// Removing the entry or clearing the list never touches the file.
    func addToRecentCaptures(_ video: URL) {
        recentCaptures(video)
    }

    static func officialRecentCaptures(_ video: URL) {
        DispatchQueue.main.async {
            RecentCaptureService.shared.recordRecording(at: video)
        }
    }

    /// The entry of a meeting the library renamed: the old one removed, a
    /// new one at the new path, only when the meeting was listed (the person
    /// may have taken it out of the list).
    static func officialRecentCaptureMoved(_ old: URL, _ new: URL) {
        DispatchQueue.main.async {
            let service = RecentCaptureService.shared
            let path = old.standardizedFileURL.path
            let listed = service.entries.filter { $0.recordingPath == path }
            guard !listed.isEmpty else { return }
            listed.forEach(service.remove)
            service.recordRecording(at: new)
        }
    }

    // MARK: - Free space

    /// The free space of the volume `url` is on, or of its nearest existing
    /// parent. **Off the main thread**: 8 ms a reading, 30 the first (S5).
    /// `nil` when it cannot be read, never a zero made up.
    static func freeBytes(at url: URL) -> Int64? {
        let manager = FileManager.default
        // A new URL each time: an URL keeps the resource values it read.
        var probe = URL(fileURLWithPath: url.path)
        while !manager.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { return nil }
            probe = parent
        }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                              .volumeAvailableCapacityKey]) else { return nil }
        return ForkMeetingFreeSpace.resolve(important: values.volumeAvailableCapacityForImportantUsage,
                                            available: values.volumeAvailableCapacity)
    }

    /// The meetings folder's free space, read off the main thread;
    /// `completion` on the callback queue.
    func readFreeBytes(completion: @escaping (Int64?) -> Void) {
        let root = self.root()
        DispatchQueue.global(qos: .utility).async { [callbackQueue] in
            let free = Self.freeBytes(at: root)
            callbackQueue.async { completion(free) }
        }
    }
}
