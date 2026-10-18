// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation
import Combine
import os
import Speech

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

    /// The last failure shown, for the settings page's banner. Cleared by the
    /// next dictation that writes something.
    @Published private(set) var lastFailure: ForkDictationFailure?
    @Published private(set) var speechAuthorization = SFSpeechRecognizer.authorizationStatus()
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
    private static let soundVolume: Float = 0.2

    private let log = Logger(subsystem: "fork.dictation", category: "service")
    private lazy var tap = ForkDictationKeyTap { [weak self] event in self?.handle(key: event) }
    private let microphone = ForkDictationMicrophone()
    private let presenter = ForkDictationPresenter.shared
    private let paster = ForkDictationPaster.shared
    private let engines = ForkDictationEngines.shared
    private let voice = VoiceClock()

    private var machine = ForkDictationMachine()
    private var table = ForkDictationShortcutTable([])
    /// The shortcut that opened the session, its gesture, and whether its
    /// key is down. The other shortcuts are ignored until it is let go.
    private var owner: ForkDictationShortcut?
    private var gesture = ForkDictationGesture()
    private var ownerIsDown = false

    private var token = UUID()
    private var engine: ForkDictationEngine?
    private var language = ""
    private var target: NSRunningApplication?
    /// Found at the press, said only once the hold proves the intent: a ⌘C
    /// never beeps.
    private var pendingFailure: ForkDictationFailure?
    /// Kept in memory only, for the Paste last shortcut.
    private var lastDelivered: String?

    private var armWork: DispatchWorkItem?
    private var timers: [Timer] = []
    private var queue: [ForkDictationMachine.Event] = []
    private var isDraining = false

    private var accessibilityObserver: AnyCancellable?
    private var followsSession = false
    private lazy var sounds: [ForkDictationSound: NSSound] = Self.loadSounds()

    private init() {}

    // MARK: - Lifecycle

    static var isWanted: Bool {
        UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationEnabled)
    }

    /// At launch: syncs now, then whenever Accessibility or the session
    /// changes. Parakeet is warmed up a little later, once the launch is done.
    static func startFollowingPermissions() {
        shared.followPermissions()
        shared.sync()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
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
        refreshAuthorization()
        let canRun = SessionActivitySupport.tapShouldRun(featureWanted: Self.isWanted,
                                                         accessibilityGranted: AXIsProcessTrusted(),
                                                         sessionIsActive: SessionActivity.shared.isActive)
        canRun ? start() : stop()
    }

    private func followPermissions() {
        guard accessibilityObserver == nil else { return }
        accessibilityObserver = Permissions.shared.$accessibility
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in ForkDictationService.sync() }
        guard !followsSession else { return }
        followsSession = true
        SessionActivity.shared.onChange { _ in
            DispatchQueue.main.async { ForkDictationService.sync() }
        }
    }

    private func start() {
        table = ForkDictationShortcutTable(ForkDictationShortcuts.load())
        if let owner, table.shortcut(owner.id) == nil { reset() }
        if tap.isRunning {
            tap.update(table: table)
        } else if tap.start(table: table) {
            engines.warmUpIfWanted()
        } else {
            log.error("the key tap could not start")
        }
        updateTapFlags()
        if isRunning != tap.isRunning { isRunning = tap.isRunning }
    }

    private func stop() {
        reset()
        tap.stop()
        engines.suspend()
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
        queue.removeAll()
        presenter.hideNow()
        updateTapFlags()
    }

    // MARK: - Settings page

    /// Release builds of the fork carry the speech recognition purpose
    /// string (fork/build-release.sh); a build without it never asks.
    static var canAskForSpeechRecognition: Bool { ForkAppleSpeechEngine.canAskForSpeechRecognition }

    /// The language Apple's engine would recognize: the one chosen in the
    /// settings, else the person's own.
    static var localeID: String? {
        ForkAppleSpeechEngine.resolvedLanguage(
            UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationLocale) ?? "")
    }

    func refreshAuthorization() {
        let status = ForkAppleSpeechEngine.authorization
        if speechAuthorization != status { speechAuthorization = status }
    }

    func requestSpeechRecognition() {
        guard Self.canAskForSpeechRecognition else { return }
        ForkAppleSpeechEngine.requestAuthorization { [weak self] status in
            self?.speechAuthorization = status
        }
    }

    func clearFailure() {
        lastFailure = nil
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
            ForkParakeetModelStore.shared.delete()
            ForkParakeetModelStore.shared.install()
        case .openSettingsPage:
            SettingsRouter.shared.page = .extras
            (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
        }
        if lastFailure?.action == action { lastFailure = nil }
    }

    // MARK: - Keys

    private func handle(key event: ForkDictationKeyEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case let .down(id):
            guard !ShortcutCapture.isCapturing, let shortcut = table.shortcut(id) else { return }
            press(shortcut, at: now)
        case let .up(id):
            guard let owner, owner.id == id else { return }
            ownerIsDown = false
            send(.gesture(gesture.triggerUp(at: now), owner, handsFree: gesture.isHandsFree))
        case .otherKey:
            guard let owner else { return }
            send(.gesture(gesture.otherKey(), owner, handsFree: gesture.isHandsFree))
        case .escape:
            _ = gesture.escape()
            send(.escape)
        }
    }

    private func press(_ shortcut: ForkDictationShortcut, at now: TimeInterval) {
        if let owner {
            // Only the key that opened the session drives it.
            guard owner.id == shortcut.id else { return }
            ownerIsDown = true
            send(.gesture(gesture.triggerDown(at: now), owner, handsFree: gesture.isHandsFree))
            return
        }
        // Paste last, or a press while the last dictation is being written:
        // no gesture to follow.
        guard shortcut.action != .pasteLast, machine.phase == .idle else {
            send(.gesture(.start, shortcut, handsFree: false))
            return
        }
        owner = shortcut
        ownerIsDown = true
        gesture = ForkDictationGesture(mode: shortcut.mode)
        let command = gesture.triggerDown(at: now)
        if command == .start { prepareSession(for: shortcut) }
        send(.gesture(command, shortcut, handsFree: gesture.isHandsFree))
    }

    /// At the press, before anything shows: where the text goes, which
    /// engine, and whether something already stands in the way.
    private func prepareSession(for shortcut: ForkDictationShortcut) {
        invalidateSession()
        target = paster.captureTarget()
        language = shortcut.language
            ?? UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationLocale) ?? ""
        engine = nil
        pendingFailure = guardFailure()
        guard pendingFailure == nil else { return }
        switch engines.engine(language: language) {
        case let .success(chosen): engine = chosen
        case let .failure(failure): pendingFailure = failure
        }
    }

    private func guardFailure() -> ForkDictationFailure? {
        if !AXIsProcessTrusted() { return .accessibilityMissing }
        if MicMuteService.shared.isMuted { return .microphoneMutedInVorssaint }
        if ForkDictationPaster.isSecureInputActive {
            return .secureInput(app: ForkDictationPaster.secureInputHolderName())
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return .microphoneDenied
        default: return nil
        }
    }

    // MARK: - Machine

    /// Events raised while effects run are queued, so the machine never
    /// handles one inside another.
    private func send(_ event: ForkDictationMachine.Event) {
        queue.append(event)
        guard !isDraining else { return }
        isDraining = true
        while !queue.isEmpty {
            let next = queue.removeFirst()
            for effect in machine.handle(next) { run(effect) }
            settleGesture()
        }
        isDraining = false
        updateTapFlags()
    }

    /// Once the machine is back at rest, the gesture follows: a key still
    /// held is waited for, so its release is not a new press.
    private func settleGesture() {
        guard machine.phase == .idle, owner != nil else { return }
        if gesture.isListening { gesture.end(triggerHeld: ownerIsDown) }
        if gesture.state == .idle { owner = nil }
    }

    private func updateTapFlags() {
        tap.swallowsEscape = machine.isCancellable
        if case .holding = gesture.state, owner != nil {
            tap.reportsOtherKeys = true
        } else {
            tap.reportsOtherKeys = false
        }
    }

    private func run(_ effect: ForkDictationMachine.Effect) {
        switch effect {
        case let .scheduleArm(delay):
            scheduleArm(after: delay)
        case .prepareEngine:
            engine?.prepare()
        case .startCapture:
            startCapture()
        case .finishCaptureAndTranscribe:
            finishCapture()
        case .discardCapture:
            discardCapture()
        case let .deliver(text, action):
            deliver(text, action: action)
        case .pasteLast:
            pasteLast()
        case let .present(presentation):
            present(presentation)
        case let .play(sound):
            play(sound)
        case .announceBusy:
            break // The machine presents `.busy` right after.
        }
    }

    private func invalidateSession() {
        token = UUID()
        armWork?.cancel()
        armWork = nil
        timers.forEach { $0.invalidate() }
        timers.removeAll()
    }

    /// Runs `work` on the main thread if the session is still `session`.
    private func ifCurrent(_ session: UUID, _ work: @escaping () -> Void) {
        let run = { [weak self] in
            guard let self, self.token == session else { return }
            work()
        }
        Thread.isMainThread ? run() : DispatchQueue.main.async(execute: run)
    }

    // MARK: - Effects

    private func scheduleArm(after delay: TimeInterval) {
        let session = token
        let work = DispatchWorkItem { [weak self] in
            self?.ifCurrent(session) { self?.send(.armElapsed) }
        }
        armWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startCapture() {
        if let failure = pendingFailure {
            pendingFailure = nil
            send(.failed(failure))
            return
        }
        guard let engine else {
            send(.failed(.transcriptionFailed))
            return
        }
        // Apple's recognizer asks once; the dictation goes on if it is allowed.
        if engine.kind == .apple, ForkAppleSpeechEngine.canAskForSpeechRecognition,
           ForkAppleSpeechEngine.authorization == .notDetermined {
            let session = token
            ForkAppleSpeechEngine.requestAuthorization { [weak self] status in
                self?.ifCurrent(session) {
                    self?.speechAuthorization = status
                    if status == .authorized {
                        self?.openMicrophone(for: engine)
                    } else {
                        self?.send(.failed(.speechDenied))
                    }
                }
            }
            return
        }
        openMicrophone(for: engine)
    }

    private func openMicrophone(for engine: ForkDictationEngine) {
        let vocabulary = ForkDictationSupport.vocabulary(
            from: UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationVocabulary) ?? "")
        if let failure = engine.begin(language: language, vocabulary: vocabulary) {
            send(.failed(failure))
            return
        }
        let session = token
        let presenter = presenter
        let voice = voice
        voice.reset()
        let device = UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationMicrophone)
            ?? ForkDictationAudioDevices.builtInChoice
        microphone.start(device: device, callbacks: ForkDictationMicrophone.Callbacks(
            started: { [weak self] in
                self?.ifCurrent(session) {
                    self?.startTimers()
                    self?.send(.captureStarted)
                }
            },
            level: { level in
                presenter.push(level: level)
                if level > Self.voiceLevel { voice.heard() }
            },
            samples: { samples in engine.append(samples) },
            failed: { [weak self] failure in
                self?.ifCurrent(session) { self?.send(.failed(failure)) }
            }))
    }

    private func startTimers() {
        let session = token
        let limit = ForkDictationSupport.maximumDuration
        schedule(after: limit - Self.nearLimitLead, session) { $0.send(.timeLimitNear) }
        schedule(after: limit, session) { $0.send(.timeLimitReached) }
        guard UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationStopsOnSilence) else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.token == session,
                  case .listening(_, handsFree: true) = self.machine.phase,
                  self.voice.silence > Self.silenceLimit
            else { return }
            self.send(.silenceLimitReached)
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func schedule(after delay: TimeInterval, _ session: UUID,
                          _ action: @escaping (ForkDictationService) -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.token == session else { return }
            action(self)
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func finishCapture() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        let capture = microphone.stop()
        guard let engine, capture.duration >= Self.shortestCapture, capture.peak > Self.quietPeak else {
            self.engine?.cancel()
            send(.transcribedNothing)
            return
        }
        let session = token
        engine.finish(samples: capture.samples) { [weak self] result in
            self?.ifCurrent(session) { self?.transcribed(result) }
        }
    }

    private func transcribed(_ result: Result<String, ForkDictationFailure>) {
        switch result {
        case let .success(raw):
            let rules = ForkDictationSupport.replacements(
                from: UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationReplacements) ?? "")
            let text = ForkDictationReplacements.apply(rules, to: raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            send(text.isEmpty ? .transcribedNothing : .transcribed(text))
        case let .failure(failure):
            send(.failed(failure))
        }
    }

    /// Stops the microphone and drops any result still on its way: the
    /// token changes, so late answers find no session.
    private func discardCapture() {
        invalidateSession()
        microphone.cancel()
        engine?.cancel()
    }

    private func deliver(_ text: String, action: ForkDictationShortcut.Action) {
        lastDelivered = text
        let session = token
        paster.deliver(text, action: action, target: target, addsToHistory: addsToHistory) { [weak self] outcome in
            self?.ifCurrent(session) {
                self?.lastFailure = nil
                self?.send(.delivered(outcome))
            }
        }
    }

    /// Writes the last dictation again, where the person is now. Outside any
    /// session: the machine stays at rest.
    private func pasteLast() {
        guard let text = lastDelivered else {
            present(.nothingHeard(afterSilence: false))
            return
        }
        let excerpt = ForkDictationPresentation.excerpt(text)
        paster.deliver(text, action: .paste, target: paster.captureTarget(), addsToHistory: false) { [weak self] outcome in
            switch outcome {
            case .pasted: self?.present(.pasted(excerpt: excerpt))
            case .copied: self?.present(.copied(excerpt: excerpt))
            case .keptInClipboard: self?.present(.keptInClipboard)
            }
        }
    }

    private var addsToHistory: Bool {
        UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationAddsToHistory)
    }

    private func present(_ presentation: ForkDictationPresentation) {
        if case let .failure(failure) = presentation { lastFailure = failure }
        presenter.show(presentation)
    }

    // MARK: - Sounds

    private func play(_ sound: ForkDictationSound) {
        guard UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationSounds) else { return }
        guard let player = sounds[sound] else {
            NSSound.beep()
            return
        }
        player.stop()
        player.play()
    }

    /// Loaded once, quiet: the dictation's sounds sit under the person's
    /// voice, not over it. A failure uses the system alert, at its own volume.
    private static func loadSounds() -> [ForkDictationSound: NSSound] {
        let names: [ForkDictationSound: String] = [.start: "Tink", .stop: "Pop", .cancel: "Basso"]
        var sounds: [ForkDictationSound: NSSound] = [:]
        for (sound, name) in names {
            guard let player = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { continue }
            player.volume = soundVolume
            sounds[sound] = player
        }
        return sounds
    }
}

/// When a voice was last heard, written on the audio thread and read on
/// the main thread.
private final class VoiceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ProcessInfo.processInfo.systemUptime

    func reset() { heard() }

    func heard() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { last = now }
    }

    /// Seconds since a voice was last heard.
    var silence: TimeInterval {
        ProcessInfo.processInfo.systemUptime - lock.withLock { last }
    }
}
