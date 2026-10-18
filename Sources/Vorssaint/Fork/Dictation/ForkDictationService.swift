// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation
import Combine
import os

/// Dictation anywhere: press one of the dictation shortcuts, speak, and the
/// words are written where the person was typing.
///
/// The service decides nothing itself: `ForkDictationGesture` reads the
/// shortcut, `ForkDictationMachine` decides, and the service runs the
/// effects it returns (key tap, microphone, engine, paste, presentation,
/// sounds). Every asynchronous answer carries the session token it was
/// asked under, and is dropped when the session has moved on.
///
/// Main thread only, apart from the microphone's audio callbacks.
final class ForkDictationService: ObservableObject {
    static let shared = ForkDictationService()

    /// A lasting failure (`ForkDictationFailure.isLasting`), for the settings
    /// page's banner. Cleared as soon as its cause is gone. Written by the
    /// service only (its files share the setter).
    @Published var lastFailure: ForkDictationFailure?
    /// Whether the shortcuts are being watched.
    @Published private(set) var isRunning = false

    /// A hands-free dictation stops after this long without a voice.
    static let silenceLimit: TimeInterval = 60
    /// Thirty seconds before the time limit, the clock turns orange.
    static let nearLimitLead: TimeInterval = 30
    /// Shorter than this, or never louder than `quietPeak` (RMS), a capture
    /// is nothing heard: no engine is asked to guess words in silence.
    static let shortestCapture: TimeInterval = 0.35
    static let quietPeak: Float = 0.004
    /// A level (0…1, `ForkDictationSupport.level`) above this is a voice for
    /// the hands-free silence limit: about -38 dB.
    static let voiceLevel: Float = 0.3
    /// Speaking this long into a held shortcut makes another key part of the
    /// dictation rather than a keyboard shortcut.
    static let committedSpeech: TimeInterval = 1
    static let soundVolume: Float = 0.2

    // Shared with the service's other files (+Keys, +Capture, +Delivery),
    // hence not private. Nothing outside the service touches them.
    let log = Logger(subsystem: "fork.dictation", category: "service")
    lazy var tap = ForkDictationKeyTap { [weak self] event in self?.handle(key: event) }
    let microphone = ForkDictationMicrophone()
    let presenter = ForkDictationPresenter.shared
    let paster = ForkDictationPaster.shared
    let engines = ForkDictationEngines.shared
    let voice = ForkDictationVoiceClock()

    var machine = ForkDictationMachine()
    var table = ForkDictationShortcutTable([])
    /// The shortcut that opened the session, its gesture, and whether its
    /// key is down. The other shortcuts are ignored until it is let go.
    var owner: ForkDictationShortcut?
    var gesture = ForkDictationGesture()
    var ownerIsDown = false

    var token = UUID()
    var engine: ForkDictationEngine?
    var language = ""
    var target: NSRunningApplication?
    /// Found at the press, said only once the person clearly meant to
    /// dictate: held past a tap, or tapped into hands-free. A ⌘C never beeps.
    var pendingFailure: ForkDictationFailure?
    var failureAwaitingIntent: ForkDictationFailure?
    var pressedAt: TimeInterval = 0
    /// When the microphone really opened, on the uptime clock.
    var captureStartedAt: TimeInterval?
    /// Kept in memory only, for the Paste last shortcut.
    var lastDelivered: String?
    /// A Paste last or Open history on a lone modifier waits for its
    /// release: pressed with another key, it was a shortcut.
    var pendingPasteLast: (id: UUID, at: TimeInterval)?
    /// Bumped by each Paste last, so an older one's answer says nothing.
    var pasteLastGeneration = 0
    /// The session's audio and raw text, for the dictation history: kept
    /// from the end of the capture until the record is written.
    var keptCapture: (samples: [Float], duration: TimeInterval)?
    var keptRawText: String?

    var armWork: DispatchWorkItem?
    var timers: [Timer] = []
    var queue: [ForkDictationMachine.Event] = []
    var isDraining = false

    var observers: [AnyCancellable] = []
    var followsSession = false
    /// While the app is in front, recording a shortcut may begin: the tap
    /// then holds nothing back, so the recorder sees every key.
    var captureWatch: Timer?
    /// The dictation page is recording a combination right now.
    var recordsShortcutInPage = false
    /// The model left the disk (deleted, downloading) since it was found
    /// damaged.
    var modelReplaced = false
    /// Whether dictation was wanted at the last sync: turning it on offers
    /// Parakeet (`+ParakeetOffer`). Nil until the first sync.
    var wasWanted: Bool?
    var parakeetOfferAlert: NonModalAlert?
    var launchOfferAttempts = 0
    lazy var sounds: [ForkDictationSound: NSSound] = Self.loadSounds()

    private init() {}

    // MARK: - Lifecycle

    /// A session is under way (arming, listening, transcribing, pasting):
    /// the engines are busy, the history waits to transcribe again.
    var isDictating: Bool {
        machine.phase != .idle
    }

    /// The text written for a raw transcription: replacements applied, the
    /// edges trimmed.
    static func corrected(_ raw: String) -> String {
        let rules = ForkDictationSupport.replacements(
            from: UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationReplacements) ?? "")
        return ForkDictationReplacements.apply(rules, to: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var isWanted: Bool {
        UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationEnabled)
    }

    /// At launch: syncs now, then whenever Accessibility or the session
    /// changes. Parakeet is warmed up a little later, once the launch is done.
    static func startFollowingPermissions() {
        shared.followPermissions()
        shared.sync()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            shared.offerParakeetAtLaunch()
            guard shared.isRunning else { return }
            shared.engines.warmUpIfWanted()
        }
    }

    static func sync() {
        shared.sync()
    }

    /// Before Accessibility is revoked or the app quits: everything stops.
    static func suspend() {
        shared.stop()
    }

    func sync() {
        revalidateFailure()
        let wanted = Self.isWanted
        if wasWanted == false, wanted { offerParakeet(.turnedOn) }
        wasWanted = wanted
        let canRun = SessionActivitySupport.tapShouldRun(featureWanted: Self.isWanted,
                                                         accessibilityGranted: AXIsProcessTrusted(),
                                                         sessionIsActive: SessionActivity.shared.isActive)
        canRun ? start() : stop()
    }

    private func followPermissions() {
        guard observers.isEmpty else { return }
        observers.append(Permissions.shared.$accessibility
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in ForkDictationService.sync() })
        observers.append(MicMuteService.shared.$isMuted
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.revalidateFailure() })
        observers.append(ForkParakeetModelStore.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                // A damaged model is fixed once it has been put back.
                if case .installed = state {} else { self?.modelReplaced = true }
                self?.revalidateFailure()
            })
        let center = NotificationCenter.default
        observers.append(center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.revalidateFailure()
                self?.watchShortcutCapture(true)
            })
        observers.append(center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.watchShortcutCapture(false) })
        guard !followsSession else { return }
        followsSession = true
        SessionActivity.shared.onChange { _ in
            DispatchQueue.main.async { ForkDictationService.sync() }
        }
    }

    private func start() {
        table = ForkDictationShortcutTable(ForkDictationShortcuts.load())
        // A shortcut removed or changed while it drives a session ends it.
        if let owner, table.shortcut(owner.id) != owner { reset() }
        if tap.isRunning {
            tap.update(table: table)
        } else if tap.start(table: table) {
            engines.warmUpIfWanted()
        } else {
            log.error("the key tap could not start")
        }
        updateTapFlags()
        prepareMicrophone()
        if captureWatch == nil, NSApp.isActive { watchShortcutCapture(true) }
        if isRunning != tap.isRunning { isRunning = tap.isRunning }
    }

    private func stop() {
        reset()
        tap.stop()
        watchShortcutCapture(false)
        engines.suspend()
        lastFailure = nil
        if isRunning { isRunning = false }
    }

    /// Drops the session under way, whatever it was doing.
    private func reset() {
        invalidateSession()
        microphone.cancel()
        engine?.cancel()
        engine = nil
        machine = ForkDictationMachine()
        owner = nil
        ownerIsDown = false
        gesture = ForkDictationGesture()
        pendingPasteLast = nil
        keptCapture = nil
        keptRawText = nil
        queue.removeAll()
        presenter.hideNow()
        updateTapFlags()
    }

    // MARK: - Settings page

    func clearFailure() {
        lastFailure = nil
    }

    /// Drops the banner once its cause is gone: Accessibility granted, the
    /// microphone unmuted or allowed, speech recognition allowed, the model
    /// back.
    private func revalidateFailure() {
        guard let failure = lastFailure else { return }
        let stillTrue: Bool
        switch failure {
        case .accessibilityMissing:
            stillTrue = !AXIsProcessTrusted()
        case .microphoneMutedInVorssaint:
            stillTrue = MicMuteService.shared.isMuted
        case .microphoneDenied:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            stillTrue = status == .denied || status == .restricted
        case .speechDenied:
            stillTrue = ForkAppleSpeechEngine.authorization != .authorized
        case .speechUnavailableInBuild:
            stillTrue = !ForkAppleSpeechEngine.canAskForSpeechRecognition
        case .modelMissing:
            stillTrue = !engines.isParakeetInstalled
        case .modelDamaged:
            stillTrue = !(modelReplaced && engines.isParakeetInstalled)
        default:
            stillTrue = false
        }
        if !stillTrue { lastFailure = nil }
    }

    /// What a failure's button does.
    func perform(_ action: ForkDictationFailureAction) {
        switch action {
        case .openAccessibility:
            Permissions.shared.openAccessibilitySettings()
        case .openMicrophonePrivacy:
            Permissions.shared.openMicrophoneSettings()
        case .unmuteMicrophone:
            MicMuteService.shared.setMuted(false)
        case .openSpeechPrivacy:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                NSWorkspace.shared.open(url)
            }
        case .downloadModel:
            ForkParakeetModelStore.shared.install()
        case .redownloadModel:
            ForkParakeetModelStore.shared.reinstall()
        case .openSettingsPage:
            ForkSettingsPages.open(.dictation)
            (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
        }
        if lastFailure?.action == action { lastFailure = nil }
    }

    /// The dictation page's own recorder, at once: a combination already
    /// bound to dictation must reach it, even typed within the poll's 0.2 s.
    func setShortcutRecording(_ isRecording: Bool) {
        recordsShortcutInPage = isRecording
        tap.isSuspended = isRecording || ShortcutCapture.isCapturing
    }

    /// Polls `ShortcutCapture` while the app is in front (the only time a
    /// shortcut can be recorded): the tap then lets every key through.
    func watchShortcutCapture(_ on: Bool) {
        captureWatch?.invalidate()
        captureWatch = nil
        guard on, tap.isRunning else {
            tap.isSuspended = recordsShortcutInPage
            return
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let capturing = ShortcutCapture.isCapturing || self.recordsShortcutInPage
            if self.tap.isSuspended != capturing { self.tap.isSuspended = capturing }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        captureWatch = timer
    }
}
