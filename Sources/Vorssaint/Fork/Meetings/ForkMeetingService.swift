// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import Combine

/// Meetings: records a call's window, its sound and the microphone, one
/// folder per meeting.
///
/// What is here registers the feature: its switch, the first-use sheet, the
/// shortcut, and the buttons of the failures. The recording itself (capture,
/// writer, pill, finishing) is the session's work: `ForkMeetingMachine`
/// decides, and this service will run the effects it returns, the way
/// `ForkDictationService` runs dictation's.
///
/// Main thread only.
final class ForkMeetingService: ObservableObject {
    static let shared = ForkMeetingService()

    /// A lasting failure (`ForkMeetingFailure.isLasting`), for the settings
    /// page's banner. Cleared as soon as its cause is gone.
    @Published private(set) var lastFailure: ForkMeetingFailure?
    /// A meeting is being recorded, paused or not.
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    /// Recording, or still finishing a recording's file: neither the app's
    /// update nor a second start may come in between.
    @Published private(set) var isBusy = false
    /// macOS refused the shortcut: another app holds the combination.
    @Published private(set) var shortcutRefused = false

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

    private init() {}

    // MARK: - Lifecycle

    static var isWanted: Bool {
        UserDefaults.standard.bool(forKey: ForkDefaultsKey.meetingsEnabled)
    }

    var isWanted: Bool { Self.isWanted }

    /// The first-use sheet was confirmed on this Mac. Machine state: a
    /// backup restored on another Mac asks again.
    static var consentAcknowledged: Bool {
        UserDefaults.standard.bool(forKey: ForkDefaultsKey.meetingsConsentAcknowledged)
    }

    /// At launch: syncs now, then whenever a permission or the app's
    /// activation changes.
    static func startFollowingPermissions() {
        shared.followPermissions()
        shared.sync()
        if NSApp.isActive { shared.watchShortcutCapture(true) }
    }

    static func sync() {
        shared.sync()
    }

    /// Every switch of the feature lands here, from its page or from Extras.
    /// Turned on without the first-use sheet confirmed on this Mac, the sheet
    /// comes first; cancelled, the feature turns back off.
    func sync() {
        let wanted = isWanted
        if wanted, wasWanted == false, !Self.consentAcknowledged {
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
        // Filled by the session work: turned off while recording, the
        // recording stops and its file is kept (§3.2 n° 48).
    }

    private func followPermissions() {
        guard !followsPermissions else { return }
        followsPermissions = true
        let permissions = Permissions.shared
        permissions.$screenRecording.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.revalidateFailure() }
            .store(in: &observers)
        permissions.$microphone.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.revalidateFailure() }
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

    // MARK: - Recording

    /// From the page's button and the shortcut. Never before the first-use
    /// sheet: it is asked for instead.
    func startManually() {
        guard isWanted, !isBusy else { return }
        guard Self.consentAcknowledged else {
            presentConsent()
            return
        }
        // Filled by the session work.
    }

    func stop() {
        // Filled by the session work.
    }

    func togglePause() {
        // Filled by the session work.
    }

    /// The shortcut: starts a recording, or stops the one running.
    func toggleRecording() {
        if isRecording {
            stop()
        } else {
            startManually()
        }
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
        let defaults = UserDefaults.standard
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
        guard !ShortcutCapture.isCapturing, !recordsShortcutInPage else { return }
        toggleRecording()
    }

    /// Installed while the feature is on with a usable combination, and no
    /// shortcut field is listening.
    func syncHotKey() {
        let wanted = isWanted && !shortcutStepsAside && !recordsShortcutInPage
        let shortcut = wanted ? ForkMeetingShortcut.load().flatMap { shortcut in
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
        guard on else { return }
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
    private func revalidateFailure() {
        guard let failure = lastFailure else { return }
        let stillTrue: Bool
        switch failure {
        case .screenRecordingDenied, .screenRecordingRevoked:
            stillTrue = !Permissions.shared.screenRecording
        case .microphoneDenied:
            stillTrue = Permissions.shared.microphone != .granted
        case .folderUnavailable:
            stillTrue = !Self.folderIsWritable
        case .localBuild:
            stillTrue = !Self.hasForkPermissionTexts
        case .systemAudioUnavailable:
            // macOS offers no way to read it: it stays until the next
            // recording says otherwise, or the person dismisses it.
            stillTrue = true
        case .diskFullAtStart, .diskFull, .streamStopped, .officialRecorderBusy, .captureFailed,
             .writerFailed, .finalPassFailed:
            stillTrue = false
        }
        if !stillTrue { lastFailure = nil }
    }

    func clearFailure() {
        lastFailure = nil
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
            openFolder()
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

    static var folderIsWritable: Bool {
        let path = root.url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            // Not made yet: its parent decides.
            return FileManager.default.isWritableFile(atPath: root.url.deletingLastPathComponent().path)
        }
        return isDirectory.boolValue && FileManager.default.isWritableFile(atPath: path)
    }

    /// Shows the meetings folder in the Finder, made first when no meeting
    /// was recorded yet. Its path is saved then, like at a first recording:
    /// the folder the person has seen must not move with the language.
    func openFolder() {
        let root = Self.root
        do {
            try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        } catch {
            lastFailure = .folderUnavailable
            return
        }
        if root.needsStoring {
            UserDefaults.standard.set(root.url.path, forKey: ForkDefaultsKey.meetingsFolder)
        }
        NSWorkspace.shared.open(root.url)
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
