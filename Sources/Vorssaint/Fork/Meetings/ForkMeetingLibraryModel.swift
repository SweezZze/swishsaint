// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import Combine
import CoreServices
import UniformTypeIdentifiers

/// What the Meetings window shows and does: the rows scanned from the disk,
/// the search, the selection, the title and notes typed, and every action
/// of the detail, run through the store.
///
/// The disk is the truth: every action ends with a new scan, and so does
/// every change the Finder makes, seen through `ForkMeetingFolderWatch`
/// while the window is open, and only then: closed, nothing watches and
/// nothing scans, whatever completes after. A change inside one meeting's
/// folder (a note saved, a meeting finishing) reads that folder alone.
///
/// Main thread only.
final class ForkMeetingLibraryModel: ObservableObject {
    @Published private(set) var entries: [ForkMeetingLibraryEntry] = []
    @Published private(set) var probes: [String: ForkMeetingProbeCache.Probe] = [:]
    @Published private(set) var root: URL
    @Published private(set) var rootExists = true
    /// The first scan answered: until then the window shows no empty state.
    @Published private(set) var loaded = false
    @Published var query = ""
    @Published var selection: String? {
        didSet { if selection != oldValue { note = nil } }
    }
    /// One line under the detail's buttons: what an action could not do,
    /// or did ("Path copied").
    @Published var note: String?
    /// The meeting whose move to the Trash waits for a confirmation.
    @Published var trashAsked: String?
    /// Folders a rename or a copy works on: their actions wait, and a title
    /// committed meanwhile is renamed once they are done (`deferredTitles`).
    /// The fields stay editable: what is typed during a rename follows it.
    @Published private(set) var working: Set<String> = []
    /// Asks the search field to take the keyboard (⌘F).
    @Published private(set) var searchFocus = 0
    /// Asks the title field to take the keyboard (⋯ › Rename).
    @Published private(set) var titleFocus = 0

    let store: ForkMeetingStore
    /// The window's language when it is not the app's (the recipe's sheets).
    let language: AppLanguage?
    let now: () -> Date
    let calendar: Calendar
    /// What this app records or finishes now, by standardized path.
    private let writing: () -> Set<String>
    private var edits = ForkMeetingEditCoalescer()
    private var editTimer: DispatchSourceTimer?
    private var watch: ForkMeetingFolderWatch?
    /// Between `start` and `stop`: the window is open.
    private(set) var isOpen = false
    private var scanning = false
    /// Asked while a scan ran: one more, of everything or of some folders.
    private var scanAgain: ForkMeetingLibrary.Rescan?
    /// Scans of every folder since the window opened, for the recipe
    /// harness.
    private(set) var fullScans = 0
    /// Renames done since the last scan, old name to new, so the selection
    /// follows them.
    private var renamed: [String: String] = [:]
    /// A title committed while its folder was busy, by folder.
    private var deferredTitles: [String: String] = [:]
    /// Counts the changes this window made to the folders and already
    /// shows (a rename): a scan begun before one reads the disk as it was,
    /// and is read again rather than shown.
    private var changes = 0
    private var noteExpiry: DispatchWorkItem?

    init(store: ForkMeetingStore = .shared, language: AppLanguage? = nil, now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current, writing: @escaping () -> Set<String> = { ForkMeetingService.shared.writingFolders }) {
        self.store = store
        self.language = language
        self.now = now
        self.calendar = calendar
        self.writing = writing
        root = store.root()
    }

    /// Rows given as they are, for the recipe's sheets: no disk, no scan.
    init(preview entries: [ForkMeetingLibraryEntry], probes: [String: ForkMeetingProbeCache.Probe] = [:],
         root: URL, language: AppLanguage, now: Date, calendar: Calendar) {
        store = .shared
        self.language = language
        self.now = { now }
        self.calendar = calendar
        writing = { [] }
        self.root = root
        self.entries = entries
        self.probes = probes
        loaded = true
    }

    var strings: ForkMeetingStrings { ForkMeetingStrings.strings(currentLanguage) }
    var currentLanguage: AppLanguage { language ?? L10n.shared.language }

    // MARK: - What the list shows

    var filtered: [ForkMeetingLibraryEntry] {
        ForkMeetingLibrary.filtered(entries, query: query, strings: strings,
                                    providerName: ForkMeetingLibraryText.providerName)
    }

    var groups: [ForkMeetingLibrary.Group] {
        ForkMeetingLibrary.groups(filtered, now: now(), calendar: calendar)
    }

    /// The selected meeting, as long as the search keeps it in the list.
    var selectedEntry: ForkMeetingLibraryEntry? {
        guard let selection else { return nil }
        return filtered.first { $0.folderName == selection }
    }

    func folderURL(_ entry: ForkMeetingLibraryEntry) -> URL {
        root.appendingPathComponent(entry.folderName, isDirectory: true)
    }

    func playableURL(_ entry: ForkMeetingLibraryEntry) -> URL? {
        entry.playable.map { folderURL(entry).appendingPathComponent($0) }
    }

    func isLive(_ entry: ForkMeetingLibraryEntry) -> Bool {
        entry.status.isInProgress || working.contains(entry.folderName)
    }

    /// The title and the notes can be typed: never in a meeting being
    /// written or a record this version may not rewrite; during a rename or
    /// a copy, yes, and what is typed follows.
    func isEditable(_ entry: ForkMeetingLibraryEntry) -> Bool {
        !entry.isReadOnly && !entry.status.isInProgress
    }

    /// The folder's name lags behind the title saved in `meeting.json` (a
    /// title typed, then the window closed by a quit): committing the
    /// field renames it even with nothing typed.
    func folderLagsTitle(_ entry: ForkMeetingLibraryEntry) -> Bool {
        ForkMeetingRename.folderLags(folderName: entry.folderName, startedAt: entry.startedAt, title: entry.title,
                                     calendar: calendar)
    }

    // MARK: - Opening and closing

    /// The window opened: a scan now, then one after every change of the
    /// folder. `focus` selects that meeting once it is listed.
    func start(focus: URL? = nil) {
        isOpen = true
        root = store.root()
        if let focus { selection = focus.standardizedFileURL.lastPathComponent }
        rewatch()
        refresh()
    }

    /// The window closed: what was typed is written, nothing watches, and
    /// nothing scans again until it opens.
    func stop() {
        flushEdits()
        isOpen = false
        scanAgain = nil
        watch?.stop()
        watch = nil
    }

    func focusSearch() { searchFocus += 1 }
    func focusTitle() { titleFocus += 1 }

    private func rewatch() {
        guard isOpen else { return }
        let path = root.path
        guard watch?.path != path else { return }
        watch?.stop()
        watch = ForkMeetingFolderWatch(path: path) { [weak self] rescan in self?.refresh(rescan) }
        watch?.start()
    }

    /// A scan, one at a time: a change during a scan asks for one more.
    /// Only while the window is open.
    func refresh(_ rescan: ForkMeetingLibrary.Rescan = .all) {
        guard isOpen else { return }
        guard !scanning else {
            scanAgain = scanAgain?.merged(with: rescan) ?? rescan
            return
        }
        // Some folders are read alone only once the list holds the rest.
        var only: Set<String>?
        if case let .folders(names) = rescan, loaded { only = names }
        if only == nil { fullScans += 1 }
        scanning = true
        root = store.root()
        let before = ForkMeetingLibrary.order(groups)
        let generation = changes
        store.scanLibrary(writing: writing(), only: only) { [weak self] scan in
            guard let self else { return }
            self.scanning = false
            guard self.isOpen else { return }
            guard generation == self.changes, scan.root == self.root else {
                // A rename landed meanwhile, or the folder moved: this read
                // is older than what the window shows.
                self.refresh(.all)
                return
            }
            self.root = scan.root
            self.rootExists = scan.rootExists
            if let only = scan.only {
                self.entries = ForkMeetingLibrary.merged(self.entries, scanned: only, with: scan.entries)
                var probes = self.probes.filter { !only.contains($0.key) }
                probes.merge(scan.probes) { _, new in new }
                self.probes = probes
            } else {
                self.entries = scan.entries
                self.probes = scan.probes
            }
            self.loaded = true
            let after = ForkMeetingLibrary.order(self.groups)
            self.selection = ForkMeetingLibrary.keptSelection(self.selection, renamed: self.renamed,
                                                              before: before, after: after)
                ?? after.first
            self.renamed = [:]
            if scan.rootExists { self.rewatch() }
            if let again = self.scanAgain {
                self.scanAgain = nil
                self.refresh(again)
            }
        }
    }

    // MARK: - Title and notes

    /// Typed in the title field: saved in `meeting.json` within half a
    /// second, the folder renamed only at the commit.
    func typedTitle(_ title: String, in folder: String) {
        noteEdit(ForkMeetingSidecarEdit(title: ForkMeetingRename.cleaned(title)), in: folder)
    }

    func typedNotes(_ notes: String, in folder: String) {
        noteEdit(ForkMeetingSidecarEdit(notes: notes), in: folder)
    }

    private func noteEdit(_ edit: ForkMeetingSidecarEdit, in folder: String) {
        edits.note(edit, in: folder, at: now())
        scheduleEdits()
    }

    private func scheduleEdits() {
        editTimer?.cancel()
        editTimer = nil
        guard let deadline = edits.nextDeadline else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSince(now())), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.write(self.edits.takeDue(at: self.now()))
            self.scheduleEdits()
        }
        editTimer = timer
        timer.resume()
    }

    /// Before a rename, a move to the Trash, the window's closing.
    func flushEdits(_ folder: String? = nil) {
        write(edits.flush(folder))
        scheduleEdits()
    }

    /// Addressed to the folder's name as the window knows it: one renamed
    /// meanwhile is found by the store (`ForkMeetingRenameTable`).
    private func write(_ due: [(folder: String, edit: ForkMeetingSidecarEdit)]) {
        for (folder, edit) in due {
            store.applyEdit(edit, in: root.appendingPathComponent(folder, isDirectory: true)) { [weak self] result in
                guard let self, case .failure(.meetingInProgress) = result else { return }
                self.say(self.strings.refusedWhileRecording)
            }
        }
    }

    /// Return, or the field left: the folder and its media take the title.
    /// While a rename or a copy works on the folder, the title waits for it
    /// rather than be dropped.
    func commitTitle(_ title: String, of entry: ForkMeetingLibraryEntry) {
        let folder = entry.folderName
        guard !entry.isReadOnly else { return }
        let wanted = ForkMeetingRename.cleaned(title)
        guard !working.contains(folder) else {
            deferredTitles[folder] = wanted
            return
        }
        flushEdits(folder)
        working.insert(folder)
        store.renameMeeting(folder, title: wanted, live: writing().contains(folderURL(entry).standardizedFileURL.path)) {
            [weak self] result in
            guard let self else { return }
            var now = folder
            switch result {
            case let .success(done):
                now = done.folderName
                self.follow(done, from: folder)
                if !done.titleSaved {
                    self.say(done.folderName != folder ? self.strings.renameTitleNotSaved : self.strings.renameUnreadable)
                } else if done.folderMoveFailed || !done.mediaKept.isEmpty {
                    self.say(done.folderMoveFailed ? self.strings.renameFailed : self.strings.renameMediaKept)
                } else if let line = ForkMeetingLibraryText.renameNote(done.plan, strings: self.strings) {
                    self.say(line)
                }
            case let .failure(.renameRefused(refusal)):
                self.say(ForkMeetingLibraryText.refusal(refusal, strings: self.strings))
            case .failure(.meetingInProgress):
                self.say(self.strings.refusedWhileRecording)
            case .failure:
                self.say(self.strings.renameFailed)
            }
            self.finishWork(folder, now: now)
            self.refresh()
        }
    }

    /// A rename done: the row, its selection, its measures and what is
    /// still being typed take the new name at once, before any scan; the
    /// detail, kept by the meeting's id, keeps its fields, its focus and its
    /// player.
    private func follow(_ done: ForkMeetingStore.RenameResult, from folder: String) {
        changes += 1
        let title = done.titleSaved ? done.plan.edit?.title : nil
        if let index = entries.firstIndex(where: { $0.folderName == folder }) {
            entries[index] = entries[index].renamed(to: done.folderName, media: done.mediaMoved, title: title)
        }
        guard done.folderName != folder else { return }
        renamed[folder] = done.folderName
        edits.move(from: folder, to: done.folderName)
        if let probe = probes.removeValue(forKey: folder) { probes[done.folderName] = probe }
        if selection == folder { selection = done.folderName }
        if trashAsked == folder { trashAsked = done.folderName }
        // Everything sent to the old name is ahead of this on the store's
        // queue: from here on, the window writes to the new one.
        store.forgetRename(of: root.appendingPathComponent(folder, isDirectory: true))
    }

    /// The folder is free again: a title committed meanwhile is renamed now.
    private func finishWork(_ folder: String, now: String? = nil) {
        working.remove(folder)
        guard let title = deferredTitles.removeValue(forKey: folder),
              let entry = entries.first(where: { $0.folderName == (now ?? folder) }) else { return }
        commitTitle(title, of: entry)
    }

    // MARK: - Actions

    /// ⌘⌫ or ⋯ › Move to Trash: asks first.
    func askTrash(_ entry: ForkMeetingLibraryEntry?) {
        guard let entry else { return }
        guard !isLive(entry) else {
            say(strings.refusedWhileRecording)
            return
        }
        trashAsked = entry.folderName
    }

    func trash(_ folder: String) {
        trashAsked = nil
        edits.forget(folder)
        let order = ForkMeetingLibrary.order(groups)
        let path = root.appendingPathComponent(folder, isDirectory: true).standardizedFileURL.path
        store.trashMeeting(folder, live: writing().contains(path)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if self.selection == folder {
                    self.selection = ForkMeetingLibrary.neighbour(of: folder, in: order)
                }
                Self.announce(self.strings.voiceTrashed)
            case .failure(.meetingInProgress):
                self.say(self.strings.refusedWhileRecording)
            case .failure:
                self.say(self.strings.trashFailed)
            }
            self.refresh()
        }
    }

    func showInFinder(_ entry: ForkMeetingLibraryEntry) {
        let folder = folderURL(entry)
        let target = playableURL(entry).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? folder
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func copyPath(_ entry: ForkMeetingLibraryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(folderURL(entry).path, forType: .string)
        say(strings.noticePathCopied)
    }

    /// A copy in the official editor; the meeting stays as it is.
    func trim(_ entry: ForkMeetingLibraryEntry) {
        let folder = entry.folderName
        guard !working.contains(folder) else { return }
        working.insert(folder)
        let live = writing().contains(folderURL(entry).standardizedFileURL.path)
        store.makeEditorTake(for: entry, probe: probes[folder], editorAvailable: AppFeature.screenRecorder.isAvailable,
                             live: live) { [weak self] result in
            guard let self else { return }
            self.finishWork(folder)
            switch result {
            case let .success(take):
                if !ScreenRecorderService.shared.openEditor(with: take, owner: .screenRecorder) {
                    RecorderTakeStore.shared.delete(take)
                    self.say(self.strings.trimNeedsEditor)
                }
            case let .failure(.editorCopyRefused(refusal)):
                switch refusal {
                case .meetingInProgress: self.say(self.strings.refusedWhileRecording)
                case .noVideo: self.say(self.strings.trimNoVideo)
                case .editorUnavailable: self.say(self.strings.trimNeedsEditor)
                }
            case .failure:
                self.say(self.strings.trimFailed)
            }
        }
    }

    /// "Export Audio (M4A)…": where to, then the copy.
    func exportAudio(_ entry: ForkMeetingLibraryEntry, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.mpeg4Audio]
        panel.nameFieldStringValue = ForkMeetingAudioExport.suggestedName(entry)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.exportAudio(entry, to: url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: run)
        } else {
            run(panel.runModal())
        }
    }

    func exportAudio(_ entry: ForkMeetingLibraryEntry, to url: URL) {
        let folder = entry.folderName
        working.insert(folder)
        let live = writing().contains(folderURL(entry).standardizedFileURL.path)
        store.exportAudio(of: entry, probe: probes[folder], live: live, to: url) { [weak self] result in
            guard let self else { return }
            self.finishWork(folder)
            switch result {
            case .success: NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(.exportRefused(.meetingInProgress)): self.say(self.strings.refusedWhileRecording)
            case .failure: self.say(self.strings.exportFailed)
            }
        }
    }

    /// The line under the buttons, for a few seconds, and said to VoiceOver.
    func say(_ line: String) {
        Self.announce(line)
        note = line
        noteExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in
            if self?.note == line { self?.note = nil }
        }
        noteExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: expiry)
    }

    static func announce(_ message: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

// MARK: - Watching the folder

/// The meetings folder, watched through FSEvents while the window is open:
/// a folder renamed, added or sent to the Trash in the Finder, a note
/// written, a meeting finishing. Changes are gathered for a quarter of a
/// second before the window scans again, so a burst of writes (a final
/// pass, a rename moving three files) costs one scan; what changed is said
/// (`ForkMeetingLibrary.rescan`), so a note saved reads its folder alone.
final class ForkMeetingFolderWatch {
    let path: String
    private let onChange: (ForkMeetingLibrary.Rescan) -> Void
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    /// Gathered during the quarter of a second.
    private var gathered: ForkMeetingLibrary.Rescan?
    /// FSEvents names the real path: a meetings folder reached through a
    /// symbolic link (`/tmp`) is compared as it resolves.
    private let realPath: String
    static let debounce: TimeInterval = 0.25

    init(path: String, onChange: @escaping (ForkMeetingLibrary.Rescan) -> Void) {
        self.path = path
        self.onChange = onChange
        realPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    deinit { stop() }

    /// Main thread. A folder that does not exist yet is not watched: the
    /// window scans again once a meeting made it.
    func start() {
        guard stream == nil, FileManager.default.fileExists(atPath: path) else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var changed: [String] = []
            var everything = false
            // Events dropped, or a folder to read through: all of it.
            let whole = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            for index in 0..<count {
                changed.append(String(cString: names[index]))
                if flags[index] & whole != 0 { everything = true }
            }
            Unmanaged<ForkMeetingFolderWatch>.fromOpaque(info).takeUnretainedValue()
                .changed(everything ? .all : nil, paths: changed)
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    func stop() {
        pending?.cancel()
        pending = nil
        gathered = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Main queue (the stream's).
    private func changed(_ forced: ForkMeetingLibrary.Rescan?, paths: [String]) {
        let rescan = forced ?? ForkMeetingLibrary.rescan(paths: paths, root: realPath)
        gathered = gathered?.merged(with: rescan) ?? rescan
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let rescan = self.gathered else { return }
            self.gathered = nil
            self.onChange(rescan)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }
}

// MARK: - The automatic bin

/// `fork.meetings.retentionDays` at work: a sweep at the launch with the
/// feature on, then once a day while the app runs (`ForkMeetingRetention`).
/// Off, or set to Never, nothing runs. A sweep that would take too many at
/// once waits in `held`, which the Meetings page asks about.
///
/// Main thread only.
final class ForkMeetingRetentionSweep: ObservableObject {
    static let shared = ForkMeetingRetentionSweep()

    /// A sweep that took nothing because it would have taken too much: how
    /// many meetings, older than how many days.
    struct Held: Equatable {
        let count: Int
        let days: Int
    }

    @Published private(set) var held: Held?

    /// After the recovery at launch (5 s), so a meeting it finishes is
    /// judged as it ends up.
    static let launchDelay: TimeInterval = 20
    private let store: ForkMeetingStore
    private let defaults: UserDefaults
    private var timer: Timer?
    private var lastSweep: Date?
    private var first: DispatchWorkItem?

    init(store: ForkMeetingStore = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    var days: Int { ForkMeetingRetention.sanitized(defaults.integer(forKey: ForkDefaultsKey.meetingsRetentionDays)) }

    /// Every switch of the feature, and a change of the setting.
    func sync(enabled: Bool) {
        guard enabled, days > 0 else {
            timer?.invalidate()
            timer = nil
            first?.cancel()
            first = nil
            held = nil
            return
        }
        guard timer == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.sweepIfDue() }
        first = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay, execute: work)
        // Looked at every hour, swept once a day: a Mac asleep for a night
        // sweeps soon after it wakes.
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.sweepIfDue() }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sweepIfDue() {
        let now = Date()
        guard days > 0, ForkMeetingRetention.isSweepDue(lastSweep: lastSweep, now: now) else { return }
        sweep(now: now)
    }

    /// Now, whatever the last sweep: the setting was just changed, or the
    /// person agreed to `confirmed` meetings going.
    func sweep(now: Date = Date(), confirmed: Int? = nil,
               completion: ((ForkMeetingRetention.Sweep) -> Void)? = nil) {
        lastSweep = now
        let days = self.days
        store.sweepRetention(days: days, now: now, writing: ForkMeetingService.shared.writingFolders,
                             confirmed: confirmed) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case let .held(count): self.held = Held(count: count, days: days)
            case .nothing, .trash: self.held = nil
            }
            completion?(outcome)
        }
    }

    /// The page's "Move to Trash" under a held sweep.
    func confirmHeld() {
        guard let held, held.days == days else { return }
        sweep(confirmed: held.count)
    }
}

extension ForkMeetingService {
    /// The folders this app is recording or finishing now, standardized:
    /// the library touches none of them.
    var writingFolders: Set<String> {
        // `folders` keeps every session's folder: only those whose file is
        // still open, or whose session is the machine's now, are written.
        var tokens = Set(recorders.keys)
        if let session = machine.activeSession { tokens.insert(session.token) }
        var paths = Set(tokens.compactMap { folders[$0]?.standardizedFileURL.path })
        paths.formUnion(finalizing.map { $0.standardizedFileURL.path })
        return paths
    }
}
