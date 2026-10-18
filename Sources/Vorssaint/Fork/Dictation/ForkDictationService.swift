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

    /// A lasting failure (`ForkDictationFailure.isLasting`), for the settings
    /// page's banner. Cleared as soon as its cause is gone.
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
    /// Speaking this long into a held shortcut makes another key part of the
    /// dictation rather than a keyboard shortcut.
    static let committedSpeech: TimeInterval = 1
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
    /// Found at the press, said only once the person clearly meant to
    /// dictate: held past a tap, or tapped into hands-free. A ⌘C never beeps.
    private var pendingFailure: ForkDictationFailure?
    private var failureAwaitingIntent: ForkDictationFailure?
    private var pressedAt: TimeInterval = 0
    /// When the microphone really opened, on the uptime clock.
    private var captureStartedAt: TimeInterval?
    /// Kept in memory only, for the Paste last shortcut.
    private var lastDelivered: String?
    /// A Paste last on a lone modifier waits for its release: pressed with
    /// another key, it was a shortcut.
    private var pendingPasteLast: (id: UUID, at: TimeInterval)?
    /// Bumped by each Paste last, so an older one's answer says nothing.
    private var pasteLastGeneration = 0

    private var armWork: DispatchWorkItem?
    private var timers: [Timer] = []
    private var queue: [ForkDictationMachine.Event] = []
    private var isDraining = false

    private var observers: [AnyCancellable] = []
    private var followsSession = false
    /// While the app is in front, recording a shortcut may begin: the tap
    /// then holds nothing back, so the recorder sees every key.
    private var captureWatch: Timer?
    /// The model left the disk (deleted, downloading) since it was found
    /// damaged.
    private var modelReplaced = false
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
        revalidateFailure()
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
                self?.refreshAuthorization()
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
            if let pending = pendingPasteLast, pending.id == id {
                pendingPasteLast = nil
                updateTapFlags()
                if now - pending.at < ForkDictationGesture.tapLimit, let shortcut = table.shortcut(id) {
                    send(.gesture(.start, shortcut, handsFree: false))
                }
                return
            }
            guard let owner, owner.id == id else { return }
            ownerIsDown = false
            send(.gesture(gesture.triggerUp(at: now), owner, handsFree: gesture.isHandsFree))
        case .otherKey:
            if pendingPasteLast != nil {
                pendingPasteLast = nil
                updateTapFlags()
            }
            guard let owner else { return }
            let committed = captureStartedAt.map { now - $0 >= Self.committedSpeech } ?? false
            send(.gesture(gesture.otherKey(keepsListening: committed), owner, handsFree: gesture.isHandsFree))
        case .escape:
            _ = gesture.escape()
            send(.escape)
        }
    }

    private func press(_ shortcut: ForkDictationShortcut, at now: TimeInterval) {
        if shortcut.action == .pasteLast {
            // A lone modifier pastes at its release, if nothing else was
            // pressed with it; a combination is already deliberate.
            if case .modifier = shortcut.key {
                pendingPasteLast = (shortcut.id, now)
                updateTapFlags()
            } else {
                send(.gesture(.start, shortcut, handsFree: false))
            }
            return
        }
        if let owner, owner.id == shortcut.id {
            ownerIsDown = true
            send(.gesture(gesture.triggerDown(at: now), owner, handsFree: gesture.isHandsFree))
            return
        }
        // Another shortcut during a session drives nothing; while the last
        // dictation is being written, the machine answers "busy".
        guard owner == nil, machine.phase == .idle else {
            send(.gesture(.start, shortcut, handsFree: false))
            return
        }
        owner = shortcut
        ownerIsDown = true
        pressedAt = now
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
        captureStartedAt = nil
        failureAwaitingIntent = nil
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
        if machine.phase == .idle { failureAwaitingIntent = nil }
        updateTapFlags()
        if failureAwaitingIntent != nil { sayFailureIfMeant() }
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
            tap.reportsOtherKeys = pendingPasteLast != nil
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
            // Said once the person clearly meant to dictate, never for a
            // shortcut that only lingered on its modifier.
            pendingFailure = nil
            failureAwaitingIntent = failure
            let wait = max(0, pressedAt + ForkDictationGesture.tapLimit - ProcessInfo.processInfo.systemUptime)
            schedule(after: wait, token) { $0.sayFailureIfMeant() }
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

    /// A failure found at the press is said when the shortcut is held past
    /// a tap, or tapped into hands-free; dropped if it was a shortcut.
    private func sayFailureIfMeant() {
        guard let failure = failureAwaitingIntent, case .listening = machine.phase else { return }
        let heldPastTap: Bool
        if case .holding = gesture.state, ownerIsDown {
            heldPastTap = ProcessInfo.processInfo.systemUptime - pressedAt >= ForkDictationGesture.tapLimit
        } else {
            heldPastTap = false
        }
        guard gesture.isHandsFree || heldPastTap else { return }
        failureAwaitingIntent = nil
        send(.failed(failure))
    }

    private func openMicrophone(for engine: ForkDictationEngine) {
        let vocabulary = ForkDictationSupport.vocabulary(
            from: UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationVocabulary) ?? "")
        if let failure = engine.begin(language: language, vocabulary: vocabulary) {
            send(.failed(failure))
            return
        }
        let session = token
        engine.onFailure = { [weak self] failure in
            self?.ifCurrent(session) { self?.send(.failed(failure)) }
        }
        let presenter = presenter
        let voice = voice
        voice.reset()
        microphone.start(device: microphoneChoice, callbacks: ForkDictationMicrophone.Callbacks(
            started: { [weak self] in
                self?.ifCurrent(session) {
                    self?.captureStartedAt = ProcessInfo.processInfo.systemUptime
                    // Read the clipboard to restore while the person speaks, not
                    // inside the paste's 500 ms deadline.
                    self?.paster.prepareSnapshot()
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
        prepareMicrophone()
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
        prepareMicrophone()
    }

    /// Builds the next capture session ahead of time, so the next press only
    /// has to start it: the first word is not lost to the setup.
    private func prepareMicrophone() {
        guard tap.isRunning, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        microphone.prepare(device: microphoneChoice)
    }

    private var microphoneChoice: String {
        UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationMicrophone)
            ?? ForkDictationAudioDevices.builtInChoice
    }

    /// Polls `ShortcutCapture` while the app is in front (the only time a
    /// shortcut can be recorded): the tap then lets every key through.
    private func watchShortcutCapture(_ on: Bool) {
        captureWatch?.invalidate()
        captureWatch = nil
        guard on, tap.isRunning else {
            tap.isSuspended = false
            return
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let capturing = ShortcutCapture.isCapturing
            if self.tap.isSuspended != capturing { self.tap.isSuspended = capturing }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        captureWatch = timer
    }

    private func deliver(_ text: String, action: ForkDictationShortcut.Action) {
        lastDelivered = text
        pasteLastGeneration += 1
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
        pasteLastGeneration += 1
        let generation = pasteLastGeneration
        paster.deliver(text, action: .paste, target: paster.captureTarget(), addsToHistory: false) { [weak self] outcome in
            guard let self, self.pasteLastGeneration == generation else { return }
            switch outcome {
            case .pasted: self.present(.pasted(excerpt: excerpt))
            case .copied: self.present(.copied(excerpt: excerpt))
            case .keptInClipboard: self.present(.keptInClipboard)
            case .inHistoryOnly: self.present(.inHistoryOnly)
            case .superseded: break
            }
        }
    }

    private var addsToHistory: Bool {
        UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationAddsToHistory)
    }

    private func present(_ presentation: ForkDictationPresentation) {
        if case let .failure(failure) = presentation, failure.isLasting {
            if failure == .modelDamaged { modelReplaced = false }
            lastFailure = failure
        }
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
