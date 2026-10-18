// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation

/// A meeting being recorded: the gestures, the machine's loop, and the
/// engine each session drives.
///
/// ```
/// gesture, engine, Mac ──► send(event) ──► machine.handle ──► [effects] ──► run, in order
///                                                              │ startCapture: folder made, then the engine
///                                                              │ stopCapture: the engine stops, writerFinished
///                                                              │ writeSidecar, beginFinalize, pill and notices
/// ```
extension ForkMeetingService {
    // MARK: - Gestures

    /// From the page's button and the shortcut. Never before the first-use
    /// sheet: it is asked for instead. What the machine needs to decide is
    /// gathered first, the free space off the main thread.
    func startManually() {
        guard isWanted, !isBusy, !terminating else { return }
        guard consentAcknowledged else {
            presentConsent()
            return
        }
        prepareSurfaces()
        preparingStart = true
        refreshState()
        let settings = captureSettings()
        let root = store.root()
        let freeBytes = self.freeBytes
        Self.microphoneAnswer { [weak self] microphoneAllowed in
            DispatchQueue.global(qos: .userInitiated).async {
                let free = freeBytes(root)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.preparingStart = false
                    guard self.isWanted, !self.terminating else { return self.refreshState() }
                    let facts = ForkMeetingStartFacts(freeBytes: free,
                                                      screenRecordingAllowed: CGPreflightScreenCaptureAccess(),
                                                      microphoneAllowed: microphoneAllowed,
                                                      officialRecorderBusy: self.officialRecorderBusy())
                    self.send(.manualStart(ForkMeetingStartRequest(settings: settings, facts: facts, title: nil)))
                }
            }
        }
    }

    func stop() {
        send(.stop)
    }

    func togglePause() {
        send(isPaused ? .resume : .pause)
    }

    /// The shortcut: starts a recording, or stops the one running.
    func toggleRecording() {
        if isRecording {
            stop()
        } else {
            startManually()
        }
    }

    /// ⧉: the window, or the display that holds it. Not without a window to
    /// film: the pill then offers no ⧉.
    func toggleTarget() {
        guard context.canSwitchTarget else { return }
        send(.toggleTarget)
    }

    /// The Meetings page's choices, as they are now.
    func captureSettings() -> ForkMeetingCaptureSettings {
        ForkMeetingCaptureSettings(
            target: ForkMeetingCaptureTarget(stored: defaults.string(forKey: ForkDefaultsKey.meetingsCaptureTarget)),
            systemAudio: ForkMeetingSystemAudio(stored: defaults.string(forKey: ForkDefaultsKey.meetingsSystemAudio)),
            microphone: ForkMeetingMicrophoneChoice(stored: defaults.string(forKey: ForkDefaultsKey.meetingsMicrophone))
                .storageValue,
            quality: ForkMeetingQuality(stored: defaults.string(forKey: ForkDefaultsKey.meetingsQuality)))
    }

    /// Whether the microphone may record. Never asked yet, macOS asks now:
    /// the person just chose to record. Main thread.
    private static func microphoneAnswer(_ answer: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            answer(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { answer(granted) }
            }
        case .denied, .restricted:
            answer(false)
        @unknown default:
            answer(false)
        }
    }

    // MARK: - The machine

    /// The one way into the machine. An event sent while the effects of
    /// another run is queued behind them: effects always run in the order
    /// the machine gave them.
    func send(_ event: ForkMeetingMachine.Event) {
        dispatchPrecondition(condition: .onQueue(.main))
        queue.append(event)
        guard !isDraining else { return }
        isDraining = true
        while !queue.isEmpty {
            let next = queue.removeFirst()
            for effect in machine.handle(next, now: Date()) {
                run(effect)
            }
        }
        isDraining = false
        refreshState()
    }

    private func run(_ effect: ForkMeetingMachine.Effect) {
        switch effect {
        case let .startCapture(config, token):
            startCapture(config, token: token)
        case let .pauseCapture(reason):
            activeRecorder?.pause(stoppingStream: reason == .sleep)
        case .resumeCapture:
            activeRecorder?.resume()
        case .restartStream:
            activeRecorder?.restartStream()
        case let .switchTarget(target):
            guard let session = machine.activeSession else { return }
            recorders[session.token]?.switchTarget(target)
        case let .stopCapture(token):
            stopCapture(token)
        case let .writeSidecar(folder, patch):
            // Quitting, the write must be on the disk before the app ends.
            if terminating {
                store.write(patch, in: folder)
            } else {
                store.update(folder, with: patch)
            }
        case let .beginFinalize(folder):
            beginFinalize(folder)
        case let .notice(notice):
            lastNotice = notice
            if case let .failure(failure) = notice { remember(failure) }
            presenter.apply(effect, context: context)
        case .showPill, .announce, .notify:
            presenter.apply(effect, context: context)
        }
    }

    /// The published state, the updater's guard and the Mac's watch, after
    /// every run of the machine.
    func refreshState() {
        let session = machine.activeSession
        let paused: Bool
        if case .paused = machine.phase { paused = true } else { paused = false }
        if isRecording != (session != nil) { isRecording = session != nil }
        if isPaused != paused { isPaused = paused }
        let busy = machine.isBusy || preparingStart || !finalizing.isEmpty || finalizer.isBusy
        if isBusy != busy { isBusy = busy }
        ForkMeetingActivity.setRecording(machine.isBusy || preparingStart)
        if let session, watchedToken != session.token {
            watchedToken = session.token
            systemEvents.beginRecording(folder: session.folder, quality: session.config.settings.quality)
        } else if session == nil, watchedToken != nil {
            watchedToken = nil
            systemEvents.endRecording()
        }
        syncSystemEvents()
    }

    /// The engine of the session recording or paused.
    var activeRecorder: ForkMeetingRecorder? {
        machine.activeSession.flatMap { recorders[$0.token] }
    }

    private func isStarting(_ token: ForkMeetingToken) -> Bool {
        if case let .starting(pending) = machine.phase { return pending.token == token }
        return false
    }

    /// The machine holds this session in `stopping`: its file is closing.
    func isStopping(_ token: ForkMeetingToken) -> Bool {
        if case let .stopping(session, _) = machine.phase { return session.token == token }
        return false
    }

    /// An engine's word about the session recording or paused, not a late
    /// one about a session gone.
    private func isCurrent(_ token: ForkMeetingToken) -> Bool {
        machine.activeSession?.token == token
    }

    // MARK: - Starting

    /// The folder first, with its `meeting.json` saying `recording`, then the
    /// engine: from the first frame on, a crash leaves a meeting to recover.
    private func startCapture(_ config: ForkMeetingCaptureConfig, token: ForkMeetingToken) {
        let recorder = ForkMeetingRecorder(token: token)
        listen(to: recorder)
        recorders[token] = recorder
        context = ForkMeetingLiveContext(title: config.title, target: config.settings.target,
                                         recordsMicrophone: config.recordsMicrophone)
        let microphone: String?
        if config.recordsMicrophone {
            microphone = nil // named once it records
        } else {
            microphone = config.microphoneDenied ? ForkMeetingSidecar.Capture.microphoneDenied
                : ForkMeetingCaptureSettings.microphoneOff
        }
        let capture = ForkMeetingSidecar.Capture(target: config.settings.target, systemAudio: config.settings.systemAudio,
                                                 microphone: microphone, quality: config.settings.quality)
        store.createMeeting(id: UUID(), startedAt: Date(), origin: config.origin, title: config.title,
                            titleSource: config.title == nil ? nil : .user, capture: capture) { [weak self] result in
            self?.folderMade(result, config: config, token: token)
        }
    }

    private func folderMade(_ result: Result<URL, ForkMeetingStore.Failure>, config: ForkMeetingCaptureConfig,
                            token: ForkMeetingToken) {
        guard let recorder = recorders[token], isStarting(token) else {
            // Given up meanwhile: the folder never held a meeting.
            if case let .success(folder) = result { discardUnstarted(folder) }
            return
        }
        switch result {
        case let .failure(failure):
            log.error("no folder for the meeting: \(String(describing: failure), privacy: .public)")
            send(.captureFailed(token, .folderUnavailable))
        case let .success(folder):
            folders[token] = folder
            // Never one of ours to film; in display mode the whole app is
            // left out anyway.
            let excluded = presenter.windowNumbers.compactMap { CGWindowID(exactly: $0) }
            recorder.start(config: config, folder: folder, excludingWindows: excluded) { [weak self] result in
                self?.captureAnswered(result, folder: folder, token: token)
            }
        }
    }

    private func captureAnswered(_ result: Result<ForkMeetingRecorderStart, ForkMeetingFailure>, folder: URL,
                                 token: ForkMeetingToken) {
        switch result {
        case let .success(start):
            // Stopped meanwhile: the stop cleans up.
            guard isStarting(token) else { return }
            log.notice("recording \(start.target.rawValue, privacy: .public), \(start.codec, privacy: .public) \(start.outputSize.width)×\(start.outputSize.height), microphone \(start.microphone == nil ? "none" : "on", privacy: .public)")
            context.target = start.target
            context.canSwitchTarget = start.window != nil
            context.recordsMicrophone = start.microphone != nil
            filmedWindow = start.window
            context.displayID = Self.displayID(of: start.window)
            send(.captureStarted(token, folder: folder, target: start.target, microphone: start.microphone,
                                 systemAudio: start.hearsWholeMac ? .all : nil))
        case let .failure(failure):
            log.error("the capture did not start: \(String(describing: failure), privacy: .public)")
            send(.captureFailed(token, failure))
        }
    }

    /// The engine's words, each about its own session: a late one from an
    /// engine stopped since says nothing.
    private func listen(to recorder: ForkMeetingRecorder) {
        recorder.onFailure = { [weak self] token, failure in
            self?.send(.captureFailed(token, failure))
        }
        recorder.onSourceGone = { [weak self] token in
            self?.send(.sourceGone(token))
        }
        recorder.onTargetChanged = { [weak self] token, target in
            guard let self, self.isCurrent(token) else { return }
            self.context.target = target
            self.presenter.update(self.context)
            self.send(.targetSwitched(token, target))
        }
        recorder.onPictureFrozen = { [weak self] token, frozen in
            guard let self, self.isCurrent(token), self.context.pictureFrozen != frozen else { return }
            self.context.pictureFrozen = frozen
            self.presenter.update(self.context)
        }
        recorder.onMicrophoneSwitch = { [weak self] token, name, gap in
            guard let self, self.isCurrent(token) else { return }
            self.context.microphoneSilent = false
            self.context.recordsMicrophone = true
            self.presenter.update(self.context)
            self.send(.microphoneChanged(name: name, gap: gap))
        }
        recorder.onMicrophoneSilent = { [weak self] token in
            guard let self, self.isCurrent(token) else { return }
            self.context.microphoneSilent = true
            self.presenter.update(self.context)
            self.send(.microphoneSilent)
        }
        recorder.onMicrophoneSound = { [weak self] token in
            guard let self, self.isCurrent(token) else { return }
            self.context.microphoneSilent = false
            self.presenter.update(self.context)
            self.send(.microphoneSoundBack)
        }
        recorder.onSystemAudioUnavailable = { [weak self] token in
            guard let self, self.isCurrent(token) else { return }
            self.send(.permissionLost(.systemAudio))
        }
    }

    // MARK: - Stopping

    /// A recording closes its file and answers `writerFinished`; a start
    /// given up leaves nothing behind. Quitting, the stop is waited for, up
    /// to the quit's bound.
    private func stopCapture(_ token: ForkMeetingToken) {
        guard let recorder = recorders[token] else { return }
        let recorded = isStopping(token)
        if terminating {
            if let result = recorder.stopBlocking(timeout: max(0, quitDeadline.timeIntervalSinceNow)) {
                stopped(token, result: result, recorded: recorded)
            }
            return
        }
        recorder.stop { [weak self] result in
            self?.stopped(token, result: result, recorded: recorded)
        }
    }

    /// Once per session, however many answers come.
    func stopped(_ token: ForkMeetingToken, result: ForkMeetingWriterResult, recorded: Bool) {
        guard recorders.removeValue(forKey: token) != nil else { return }
        let folder = folders.removeValue(forKey: token)
        guard recorded else {
            if let folder { discardUnstarted(folder) }
            return
        }
        if case let .failed(failure) = result {
            log.error("the file did not close: \(String(describing: failure), privacy: .public)")
            // Not finalized: what the fragments hold waits for the next
            // launch, which needs the folder free.
            if let folder { store.release(folder) }
        }
        send(.writerFinished(token, result))
    }

    /// A start given up before anything was recorded: its folder goes, unless
    /// something else came into it.
    private func discardUnstarted(_ folder: URL) {
        store.release(folder)
        let manager = FileManager.default
        for name in [ForkMeetingFolder.sidecarName, ForkMeetingStore.sidecarDraftName, ForkMeetingFolder.masterName] {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
        if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? manager.removeItem(at: folder)
        }
    }

    // MARK: - Helpers

    /// The display that holds most of the window's middle, for the pill and
    /// the bubble; `nil` without a window.
    static func displayID(of window: CGWindowID?) -> UInt32? {
        guard let window,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first,
              let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: bounds.midX, y: bounds.midY), 1, &display, &count) == .success,
              count > 0 else { return nil }
        return display
    }
}
