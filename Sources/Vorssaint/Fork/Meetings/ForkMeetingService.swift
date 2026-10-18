// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import Combine
import os

/// Meetings: records a call's window, its sound and the microphone, one
/// folder per meeting.
///
/// The service decides nothing itself: `ForkMeetingMachine` decides, and the
/// service runs the effects it returns, the way `ForkDictationService` runs
/// dictation's:
/// - the capture, one `ForkMeetingRecorder` per session made with the
///   session's token, and every answer of the engine (`+Session`);
/// - the final pass through `ForkMeetingFinalizer`, which outlives the
///   session, the saved notice, and the recovery at launch (`+Finalize`);
/// - the Mac's sleep, lock, displays, disk and quit (`+System`);
/// - here, the feature's switch, its first-use sheet, its shortcut, and the
///   failures the Meetings page shows.
///
/// Every asynchronous answer (the folder made, the capture started, the file
/// closed, an engine's event) carries its session's token; the machine drops
/// one that does not match, and so does the service before acting on it.
///
/// Main thread only.
final class ForkMeetingService: ObservableObject {
    static let shared = ForkMeetingService()

    /// A lasting failure (`ForkMeetingFailure.isLasting`), or a final pass
    /// that failed, for the settings page's banner. Cleared as soon as its
    /// cause is gone. Written by the service only (its files share the
    /// setters of these).
    @Published var lastFailure: ForkMeetingFailure?
    /// A meeting is being recorded, paused or not.
    @Published var isRecording = false
    @Published var isPaused = false
    /// Recording, or still finishing a recording's file: neither the app's
    /// update nor a second start may come in between.
    @Published var isBusy = false
    /// macOS refused the shortcut: another app holds the combination.
    @Published private(set) var shortcutRefused = false
    /// The last meeting saved, or recovered at launch.
    @Published var lastSaved: ForkMeetingSaved?
    /// A meeting may be asked to start now, from the page, the shortcut or
    /// later the offer: none is starting or recording. A meeting still being
    /// finalized does not count (`ForkMeetingServiceSupport.canStart`).
    @Published var canStart = false
    /// A start is under way, before its first frame: it can be cancelled.
    @Published var isStarting = false
    /// The last start refused or failed, for the page's banner while the
    /// page stays open, or until the next start.
    @Published var lastRefusal: ForkMeetingFailure?

    // Shared with the service's other files (+Session, +Finalize, +System),
    // hence not private. Nothing outside the service touches them.
    let log = Logger(subsystem: "fork.meetings", category: "service")
    let defaults: UserDefaults
    let store: ForkMeetingStore
    let finalizer: ForkMeetingFinalizer
    let presenter: ForkMeetingPresenter
    /// The free space of a folder's volume, read off the main thread.
    let freeBytes: (URL) -> Int64?
    /// The official screen recorder runs: a meeting does not start on top.
    let officialRecorderBusy: () -> Bool
    /// How long after the launch the meetings left unfinished are looked at:
    /// once the launch is done, as dictation warms Parakeet up.
    let recoveryDelay: TimeInterval
    lazy var systemEvents = ForkMeetingSystemEvents(freeBytes: freeBytes) { [weak self] event in
        self?.systemEvent(event)
    }

    var machine = ForkMeetingMachine()
    var queue: [ForkMeetingMachine.Event] = []
    var isDraining = false
    /// The engine of every session whose file is not closed yet, by token: a
    /// stop may still be closing one while the machine moved on.
    var recorders: [ForkMeetingToken: ForkMeetingRecorder] = [:]
    /// Each session's folder, once made.
    var folders: [ForkMeetingToken: URL] = [:]
    /// What the pill knows beyond the machine's state.
    var context = ForkMeetingLiveContext()
    /// The window the session films, or whose display it films.
    var filmedWindow: CGWindowID?
    /// The free space is being read for a start.
    var preparingStart = false
    var presenterReady = false
    /// The session whose disk the system events watch.
    var watchedToken: ForkMeetingToken?
    /// The folders a session handed to the finalizer, until their outcome.
    var finalizing: [URL] = []
    var recoveryAsked = false
    /// The app is quitting: every write waits, every stop is bounded.
    var terminating = false
    var quitDeadline = Date.distantFuture
    /// The last notice the machine or the finalizer gave, for the recipe
    /// harness and the logs.
    var lastNotice: ForkMeetingNotice?
    /// The start was cancelled while its facts were being gathered: their
    /// answer starts nothing.
    var cancelRequested = false
    /// The display the session films, or whose window it follows: a change
    /// of displays is said only when this one changed.
    var filmedDisplay: UInt32?
    /// The effects of `captureStarted` are being run: the notice is the
    /// start's, with what is filmed and the consent reminder.
    var runsStart = false
    /// The video of the last meeting whose final pass failed, for its
    /// "Show in Finder".
    var lastFailedVideo: URL?

    // MARK: Fixes G1

    /// The system audio verdicts of sessions still starting.
    var pendingVerdicts = ForkMeetingPendingVerdicts()

    private lazy var hotKey = ForkMeetingHotKey { [weak self] in self?.shortcutPressed() }
    private var observers: [AnyCancellable] = []
    private var followsPermissions = false
    /// Whether the feature was wanted at the last sync: turning it on asks
    /// for the first-use sheet. Nil until the first sync, at launch.
    private var wasWanted: Bool?
    private var consentSheet: ForkMeetingConsentSheet?
    /// While the app is in front, a shortcut field may start listening: the
    /// hotkey then steps aside, so the combination reaches the field.
    private var captureWatch: Timer?
    private var shortcutStepsAside = false
    /// The Meetings page is recording a combination right now.
    private var recordsShortcutInPage = false

    /// The app's service uses the app's settings and singletons; a recipe
    /// harness gives its own, so that nothing of the installed app is
    /// touched.
    init(defaults: UserDefaults = .standard,
         store: ForkMeetingStore = .shared,
         finalizer: ForkMeetingFinalizer = .shared,
         presenter: ForkMeetingPresenter = .shared,
         freeBytes: @escaping (URL) -> Int64? = ForkMeetingStore.freeBytes(at:),
         officialRecorderBusy: @escaping () -> Bool = { ScreenRecorderService.shared.hasActiveCapture },
         recoveryDelay: TimeInterval = 5) {
        self.defaults = defaults
        self.store = store
        self.finalizer = finalizer
        self.presenter = presenter
        self.freeBytes = freeBytes
        self.officialRecorderBusy = officialRecorderBusy
        self.recoveryDelay = recoveryDelay
        finalizer.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in self?.finalizerProgressed(progress) }
            .store(in: &observers)
    }

    // MARK: - Lifecycle

    static var isWanted: Bool {
        UserDefaults.standard.bool(forKey: ForkDefaultsKey.meetingsEnabled)
    }

    var isWanted: Bool { defaults.bool(forKey: ForkDefaultsKey.meetingsEnabled) }

    /// The first-use sheet was confirmed on this Mac. Machine state: a
    /// backup restored on another Mac asks again.
    static var consentAcknowledged: Bool {
        UserDefaults.standard.bool(forKey: ForkDefaultsKey.meetingsConsentAcknowledged)
    }

    var consentAcknowledged: Bool { defaults.bool(forKey: ForkDefaultsKey.meetingsConsentAcknowledged) }

    /// At launch: syncs now, then whenever a permission or the app's
    /// activation changes. The meetings the last run left unfinished are
    /// recovered a little later, once the launch is done.
    static func startFollowingPermissions() {
        shared.startFollowingPermissions()
    }

    /// Once; a second call only syncs.
    func startFollowingPermissions() {
        followPermissions()
        sync()
        if NSApp.isActive { watchShortcutCapture(true) }
        guard !recoveryAsked else { return }
        recoveryAsked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + recoveryDelay) { [weak self] in
            self?.recoverAtLaunch()
        }
    }

    static func sync() {
        shared.sync()
    }

    /// Every switch of the feature lands here, from its page or from Extras.
    /// Turned on without the first-use sheet confirmed on this Mac, the sheet
    /// comes first; cancelled, the feature turns back off. Turned off while
    /// recording, the recording stops and its file is kept (§3.2 n° 48).
    func sync() {
        let wanted = isWanted
        if wanted, wasWanted == false, !consentAcknowledged {
            presentConsent()
        } else if !wanted {
            // Turned off elsewhere while the sheet was open: it has nothing
            // left to ask.
            consentSheet?.dismiss()
            consentSheet = nil
        }
        wasWanted = wanted
        revalidateFailure()
        syncHotKey()
        // Off, nothing polls; on, the watch starts with the app in front.
        if !wanted {
            watchShortcutCapture(false)
        } else if captureWatch == nil, NSApp.isActive {
            watchShortcutCapture(true)
        }
        if wanted {
            prepareSurfaces()
        } else if machine.isBusy {
            send(.featureDisabled)
        }
        syncSystemEvents()
        // Off and idle: nothing shows, nothing is held. A meeting still
        // finishing keeps its pill until its saved notice.
        if !wanted, !isBusy, presenterReady {
            presenter.reset()
            presenterReady = false
        }
        refreshState()
    }

    private func followPermissions() {
        guard !followsPermissions else { return }
        followsPermissions = true
        let permissions = Permissions.shared
        permissions.$screenRecording.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in
                self?.revalidateFailure()
                if !granted { self?.send(.permissionLost(.screenRecording)) }
            }
            .store(in: &observers)
        permissions.$microphone.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.revalidateFailure()
                if state == .denied, self.machine.activeSession?.config.recordsMicrophone == true {
                    self.send(.permissionLost(.microphone))
                }
            }
            .store(in: &observers)
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.revalidateFailure()
                self?.watchShortcutCapture(true)
            }
            .store(in: &observers)
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.watchShortcutCapture(false) }
            .store(in: &observers)
    }

    /// The pill, the island and the bubble get their buttons once the feature
    /// is on.
    func prepareSurfaces() {
        guard !presenterReady else { return }
        presenterReady = true
        presenter.configure(levels: { [weak self] in self?.activeRecorder?.levels ?? .silent },
                            onPause: { [weak self] in self?.send(.pause) },
                            onResume: { [weak self] in self?.send(.resume) },
                            onStop: { [weak self] in self?.stop() },
                            onToggleTarget: { [weak self] in self?.toggleTarget() },
                            onFailureAction: { [weak self] action in self?.perform(action) })
    }

    // MARK: - First use

    /// The first-use sheet, once at a time: on the window in front (the
    /// Settings, where the switch was turned on), or on its own.
    func presentConsent() {
        if let consentSheet {
            consentSheet.bringForward()
            return
        }
        let sheet = ForkMeetingConsentSheet { [weak self] confirmed in
            self?.consentAnswered(confirmed)
        }
        consentSheet = sheet
        sheet.present()
    }

    private func consentAnswered(_ confirmed: Bool) {
        consentSheet = nil
        if confirmed {
            defaults.set(true, forKey: ForkDefaultsKey.meetingsConsentAcknowledged)
        } else {
            defaults.set(false, forKey: ForkDefaultsKey.meetingsEnabled)
        }
        sync()
    }

    // MARK: - Shortcut

    private func shortcutPressed() {
        // A field elsewhere in the app is listening: the press is for it.
        guard !ShortcutCapture.isCapturing, !recordsShortcutInPage, isWanted else { return }
        toggleRecording()
    }

    /// Installed while the feature is on with a usable combination, and no
    /// shortcut field is listening.
    func syncHotKey() {
        let wanted = isWanted && !shortcutStepsAside && !recordsShortcutInPage
        let shortcut = wanted ? ForkMeetingShortcut.load(defaults).flatMap { shortcut in
            ForkMeetingShortcut.problem(of: shortcut) == nil ? shortcut : nil
        } : nil
        hotKey.sync(shortcut)
        if shortcutRefused != hotKey.isRefused { shortcutRefused = hotKey.isRefused }
    }

    /// The Meetings page's own recorder, at once: a combination already
    /// bound to meetings must reach it.
    func setShortcutRecording(_ isRecording: Bool) {
        recordsShortcutInPage = isRecording
        syncHotKey()
    }

    /// Polls `ShortcutCapture` while the app is in front (the only time a
    /// shortcut can be recorded), like dictation's key tap does.
    private func watchShortcutCapture(_ on: Bool) {
        captureWatch?.invalidate()
        captureWatch = nil
        if shortcutStepsAside {
            shortcutStepsAside = false
            syncHotKey()
        }
        // The feature off has no shortcut to step aside.
        guard on, isWanted else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.shortcutStepsAside != ShortcutCapture.isCapturing else { return }
            self.shortcutStepsAside = ShortcutCapture.isCapturing
            self.syncHotKey()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        captureWatch = timer
    }

    // MARK: - Failures

    /// A lasting failure clears itself once its cause is gone; one that
    /// belongs to a single meeting does not stay on the page.
    func revalidateFailure() {
        guard let failure = lastFailure else { return }
        let stillTrue: Bool
        switch failure {
        case .screenRecordingDenied, .screenRecordingRevoked:
            stillTrue = !Permissions.shared.screenRecording
        case .microphoneDenied:
            stillTrue = Permissions.shared.microphone != .granted
        case .folderUnavailable:
            stillTrue = !folderIsWritable
        case .localBuild:
            stillTrue = !Self.hasForkPermissionTexts
        case .systemAudioUnavailable:
            // macOS offers no way to read it: it stays until a tap proves
            // it (`systemAudioProven`), or the person dismisses it.
            stillTrue = true
        case .diskFullAtStart, .diskFull, .streamStopped, .officialRecorderBusy, .captureFailed,
             .writerFailed, .finalPassFailed, .masterHidden:
            stillTrue = false
        }
        if !stillTrue { lastFailure = nil }
    }

    /// Kept for the page: a failure that lasts, or a final pass that failed.
    /// One that passes with its meeting is only said, in the island.
    func remember(_ failure: ForkMeetingFailure) {
        guard failure.isLasting || failure == .finalPassFailed || failure == .masterHidden else { return }
        lastFailure = failure
    }

    func clearFailure() {
        lastFailure = nil
    }

    /// The page closed: a start refused no longer needs saying there.
    func clearRefusal() {
        lastRefusal = nil
    }

    /// The other apps' sound was heard through a tap: the permission is
    /// there, the banner that said otherwise goes.
    func systemAudioProven() {
        if lastFailure == .systemAudioUnavailable { lastFailure = nil }
    }

    /// What a failure's button does.
    func perform(_ action: ForkMeetingFailureAction) {
        switch action {
        case .openScreenRecordingPrivacy:
            Permissions.shared.openScreenRecordingSettings()
        case .openMicrophonePrivacy:
            Permissions.shared.openMicrophoneSettings()
        case .openStorageSettings:
            Self.openStorageSettings()
        case .openMeetingsPage:
            ForkSettingsPages.open(.meetings)
            (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
        case .openMeetingsFolder:
            // A final pass that failed shows its own video, else the folder.
            if let video = lastFailedVideo, FileManager.default.fileExists(atPath: video.path) {
                NSWorkspace.shared.activateFileViewerSelecting([video])
            } else {
                openFolder()
            }
        }
        if lastFailure?.action == action { lastFailure = nil }
    }

    /// System Settings › General › Storage, or the general pane when a
    /// later macOS stops knowing that address.
    private static func openStorageSettings() {
        let workspace = NSWorkspace.shared
        if let storage = URL(string: "x-apple.systempreferences:com.apple.settings.Storage"), workspace.open(storage) {
            return
        }
        if let general = URL(string: "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings") {
            workspace.open(general)
        }
    }

    // MARK: - Folder

    /// Where the meetings go, as `ForkMeetingFolder.root` resolves the
    /// setting.
    static var root: ForkMeetingFolder.Root {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies", isDirectory: true)
        return ForkMeetingFolder.root(stored: UserDefaults.standard.string(forKey: ForkDefaultsKey.meetingsFolder) ?? "",
                                      movies: movies, strings: .current)
    }

    var folderIsWritable: Bool {
        let root = store.root()
        let path = root.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            // Not made yet: its parent decides.
            return FileManager.default.isWritableFile(atPath: root.deletingLastPathComponent().path)
        }
        return isDirectory.boolValue && FileManager.default.isWritableFile(atPath: path)
    }

    /// Shows the meetings folder in the Finder, made first when no meeting
    /// was recorded yet. Its path is saved then, like at a first recording:
    /// the folder the person has seen must not move with the language.
    func openFolder() {
        let root = store.root()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: ForkMeetingStore.folderPermissions])
        } catch {
            lastFailure = .folderUnavailable
            return
        }
        _ = store.root(storing: true)
        NSWorkspace.shared.open(root)
    }

    // MARK: - Build

    /// Release builds of the fork carry its permission texts
    /// (fork/build-release.sh writes them all from fork/usage-descriptions.tsv
    /// in one pass). A local build has the official ones, which say nothing
    /// of meetings; the speech recognition text, the fork's alone, tells the
    /// two apart, as for dictation.
    static var hasForkPermissionTexts: Bool {
        ForkAppleSpeechEngine.canAskForSpeechRecognition
    }
}
