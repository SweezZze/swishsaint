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
    /// gathered first, the free space off the main thread. A meeting still
    /// being finalized does not stand in the way (§3.2 n° 44).
    func startManually() {
        guard ForkMeetingServiceSupport.canStart(wanted: isWanted, machineBusy: machine.isBusy,
                                                 preparingStart: preparingStart, terminating: terminating) else { return }
        guard consentAcknowledged else {
            presentConsent()
            return
        }
        prepareSurfaces()
        // A new try says every step again, and the last refusal goes.
        presenter.resetAnnouncements()
        clearRefusal()
        let attempt = startAttempt.begin()
        preparingStart = true
        refreshState()
        let settings = captureSettings()
        let root = store.root()
        let freeBytes = self.freeBytes
        // A microphone turned off is never asked for.
        let wantsMicrophone = settings.microphone != ForkMeetingCaptureSettings.microphoneOff
        Self.microphoneAnswer(asking: wantsMicrophone) { [weak self] microphoneAllowed in
            DispatchQueue.global(qos: .userInitiated).async {
                let free = freeBytes(root)
                DispatchQueue.main.async {
                    // Cancelled meanwhile (and maybe started again): this
                    // answer is an older attempt's, it holds nothing.
                    guard let self, self.startAttempt.answers(attempt) else { return }
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

    /// The page's Cancel and the shortcut pressed again while a start is
    /// under way: nothing is recorded, no folder stays, and a new start may
    /// be asked at once, whatever the old one's answers still on their way
    /// (the free space, the microphone, the folder) say when they come.
    func cancelStart() {
        if preparingStart {
            preparingStart = false
            startAttempt.cancel()
        } else if case .starting = machine.phase {
            send(.stop)
        }
        refreshState()
    }

    func togglePause() {
        send(isPaused ? .resume : .pause)
    }

    /// The shortcut: starts a recording, stops the one running, or cancels
    /// the one starting.
    func toggleRecording() {
        switch ForkMeetingServiceSupport.press(phase: machine.phase, preparingStart: preparingStart, canStart: canStartNow) {
        case .start: startManually()
        case .stop: stop()
        case .cancelStart: cancelStart()
        case .ignore: break
        }
    }

    /// `canStart` as it is this instant, not as last published.
    var canStartNow: Bool {
        ForkMeetingServiceSupport.canStart(wanted: isWanted, machineBusy: machine.isBusy,
                                           preparingStart: preparingStart, terminating: terminating)
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
    /// the person just chose to record; unless no microphone is to record,
    /// which never asks. Main thread.
    static func microphoneAnswer(asking: Bool, _ answer: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            answer(true)
        case .notDetermined where !asking:
            answer(false)
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
            // A start refused, or failed before its first frame: its words
            // stay on the page (`lastRefusal`).
            var starts = false
            switch next {
            case .manualStart, .accept, .always: starts = true
            case let .captureFailed(token, _): starts = isStarting(token)
            case .captureStarted:
                runsStart = true
                machine.voiceOver = NSWorkspace.shared.isVoiceOverEnabled
            default: break
            }
            for effect in machine.handle(next, now: Date()) {
                if starts, case let .notice(.failure(failure)) = effect { holdRefusal(failure) }
                run(effect)
            }
            runsStart = false
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
            if runsStart {
                presenter.showStart(notice, context: context)
            } else {
                presenter.apply(effect, context: context)
            }
        case let .showPill(state):
            // A session's final pass still running keeps the pill on its
            // gauge, whatever the next start does.
            let shown = ForkMeetingServiceSupport.pill(state, finalizing: !finalizing.isEmpty)
            presenter.apply(.showPill(shown), context: context)
        case .announce(.discarded):
            // Said once the folder is gone, with what became of it
            // (`discardCancelled`): it may stay, and is never deleted then.
            break
        case let .announce(announcement) where runsStart && context.trackSound == .noApp:
            // One sentence after the other, not two that cut each other off.
            let text = ForkMeetingStrings.current
            presenter.say(ForkMeetingLiveText.sentences(announcement.text(text), text.soundNoAppDetail))
        case .announce, .notify:
            presenter.apply(effect, context: context)
        case .showOffer, .collapseOffer, .hideOffer, .showUndo, .hideUndo, .showEndingSoon, .hideEndingSoon,
             .silence, .setPolicy, .discard:
            runDetection(effect)
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
        let startable = canStartNow
        if canStart != startable { canStart = startable }
        let starting: Bool
        if case .starting = machine.phase { starting = true } else { starting = preparingStart }
        if isStarting != starting { isStarting = starting }
        ForkMeetingActivity.setRecording(machine.isBusy || preparingStart)
        // An offer holds no session: the finished gauge goes under it too.
        if ForkMeetingServiceSupport.hidesFinishedPill(machineIdle: !machine.isBusy,
                                                       finalizingCount: finalizing.count, pill: presenter.pillState) {
            presenter.apply(.showPill(.hidden))
        }
        if let session, watchedToken != session.token {
            watchedToken = session.token
            systemEvents.beginRecording(folder: session.folder, quality: session.config.settings.quality)
        } else if session == nil, watchedToken != nil {
            watchedToken = nil
            systemEvents.endRecording()
        }
        syncSystemEvents()
        systemEvents.hold(ForkMeetingServiceSupport.awake(phase: machine.phase))
        syncDetectionClock()
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
    private func startCapture(_ asked: ForkMeetingCaptureConfig, token: ForkMeetingToken) {
        // A provider whose calls no app's sound carries (FaceTime's run in a
        // system process) records the whole Mac for "the meeting app's sound".
        var config = asked
        config.settings = ForkMeetingDetectionSupport.settings(asked.settings, for: asked.meeting)
        let recorder = ForkMeetingRecorder(token: token, defaults: defaults)
        // "Show in Finder" of an older meeting's failed pass is not this one's.
        lastFailedVideo = nil
        listen(to: recorder)
        recorders[token] = recorder
        context = ForkMeetingLiveContext(title: config.title, target: config.settings.target,
                                         recordsMicrophone: config.recordsMicrophone)
        context.providerName = config.meeting?.providerName
        if defaults.bool(forKey: ForkDefaultsKey.meetingsConsentReminder) {
            context.announcement = ForkMeetingAnnouncementText.text(
                stored: defaults.string(forKey: ForkDefaultsKey.meetingsAnnouncement) ?? "", strings: .current)
        }
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
                            titleSource: ForkMeetingDetectionSupport.titleSource(title: config.title,
                                                                                meeting: config.meeting),
                            capture: capture, meeting: config.meeting) { [weak self] result in
            self?.folderMade(result, config: config, token: token)
        }
        // A folder that takes too long (a volume that hangs) fails the start
        // like a capture that does not answer; the folder, should it come
        // later, is given up (`folderMade`).
        DispatchQueue.main.asyncAfter(deadline: .now() + ForkMeetingCaptureSupport.startTimeout) { [weak self] in
            guard let self, self.isStarting(token), self.folders[token] == nil else { return }
            self.log.error("no folder for the meeting after \(Int(ForkMeetingCaptureSupport.startTimeout)) s")
            self.send(.captureFailed(token, .folderUnavailable))
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
            log.error("no folder for the meeting: \(String(describing: failure), privacy: .private)")
            send(.captureFailed(token, .folderUnavailable))
        case let .success(folder):
            folders[token] = folder
            // Never one of ours to film; in display mode the whole app is
            // left out anyway.
            let excluded = presenter.windowNumbers.compactMap { CGWindowID(exactly: $0) }
            // A detected meeting is filmed in its own window (an app found
            // by its microphone, its own most in front), its app heard, and
            // "Meeting microphone (auto)" records the input its app uses.
            let meeting = config.meeting
            let window = meeting.flatMap {
                ForkMeetingAppsSupport.window(for: $0, in: ForkMeetingRecorder.meetingWindows(),
                                              ownPID: ProcessInfo.processInfo.processIdentifier,
                                              excluded: Set(excluded))
            }
            let sound = meeting.map { meeting in
                ForkMeetingRecorder.MeetingSound(
                    appPID: ForkMeetingAppsSupport.soundPID(
                        for: meeting, running: NSRunningApplication.runningApplications(
                            withBundleIdentifier: meeting.appBundle).map(\.processIdentifier)),
                    outsideApp: ForkMeetingAppsSupport.soundOutsideApp(meeting))
            }
            recorder.start(config: config, folder: folder, meetingWindow: window,
                           meetingMicrophone: meetingMicrophone(for: config.meeting), excludingWindows: excluded,
                           titles: trackTitles, meetingSound: sound) { [weak self] result in
                self?.captureAnswered(result, config: config, folder: folder, token: token)
            }
        }
    }

    private func captureAnswered(_ result: Result<ForkMeetingRecorderStart, ForkMeetingFailure>,
                                 config: ForkMeetingCaptureConfig, folder: URL, token: ForkMeetingToken) {
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
            context.appName = start.appName
            // A window was asked for, none could be filmed: said at the start.
            context.noWindowToFilm = config.settings.target == .window && start.target == .display
            filmedDisplay = context.displayID ?? CGMainDisplayID()
            context.trackSound = start.trackSound
            send(.captureStarted(token, folder: folder, target: start.target, microphone: start.microphone,
                                 systemAudio: start.heard, startedAt: start.startedAt))
            // Lost, or judged, while the capture came up: said once it records.
            if start.trackSound == .lost { send(.soundLost(token)) }
            if let verdict = pendingVerdicts.take(token) { systemAudioJudged(verdict, token: token) }
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
            guard let self else { return }
            if self.isCurrent(token), !self.context.sourceGone {
                self.context.sourceGone = true
                self.presenter.update(self.context)
            }
            self.send(.sourceGone(token))
        }
        recorder.onTargetChanged = { [weak self] token, target in
            guard let self, self.isCurrent(token) else { return }
            self.context.target = target
            self.context.noWindowToFilm = false
            // The display filmed instead of the window that went moves again.
            self.context.sourceGone = false
            self.filmedDisplay = Self.displayID(of: self.filmedWindow) ?? CGMainDisplayID()
            self.presenter.update(self.context)
            self.send(.targetSwitched(token, target))
        }
        recorder.onPictureFrozen = { [weak self] token, frozen in
            guard let self, self.isCurrent(token), self.context.pictureFrozen != frozen else { return }
            self.context.pictureFrozen = frozen
            self.presenter.update(self.context)
            // The pill says it with words VoiceOver cannot see change; a
            // moment later, so a window whose app quit (its last frames say
            // "stopped" first) is said as such, never as minimized.
            guard frozen else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.isCurrent(token), self.context.pictureFrozen, !self.context.sourceGone else { return }
                self.presenter.say(ForkMeetingStrings.current.voicePictureFrozen)
            }
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
        recorder.onSystemAudioAllowed = { [weak self] token in
            self?.systemAudioJudged(.allowed, token: token)
        }
        recorder.onSoundHeard = { [weak self] token, heard in
            guard let self, self.isCurrent(token) || self.isStopping(token) else { return }
            self.send(.soundHeard(token, heard))
        }
        recorder.onTrackSound = { [weak self] token, sound in
            guard let self, self.isCurrent(token), self.context.trackSound != sound else { return }
            self.context.trackSound = sound
            self.presenter.update(self.context)
            if sound == .lost { self.send(.soundLost(token)) }
        }
        recorder.onSystemAudioUnavailable = { [weak self] token in
            self?.systemAudioJudged(.missing, token: token)
        }
    }

    /// A tap proved the permission, or the witness found it missing: said
    /// now, or once the session that judged it records.
    private func systemAudioJudged(_ verdict: ForkMeetingPendingVerdicts.Verdict, token: ForkMeetingToken) {
        switch ForkMeetingPendingVerdicts.route(token, phase: machine.phase) {
        case .now:
            switch verdict {
            case .allowed: systemAudioProven()
            case .missing: send(.permissionLost(.systemAudio))
            }
        case .hold:
            pendingVerdicts.hold(verdict, for: token)
        case .drop:
            break
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
        // Only a tap that heard sound clears the banner (`systemAudioProven`):
        // a silent meeting proves nothing.
        _ = pendingVerdicts.take(token)
        guard recorded else {
            if let folder { discardUnstarted(folder) }
            return
        }
        if case let .failed(failure) = result {
            log.error("the file did not close: \(String(describing: failure), privacy: .public)")
            // Not finalized: what the fragments hold waits for the next
            // launch, which needs the folder free. Quitting, at once.
            if let folder {
                if terminating {
                    store.release(folder)
                } else {
                    DispatchQueue.global(qos: .utility).async { [store] in store.release(folder) }
                }
            }
        }
        send(.writerFinished(token, result))
    }

    /// A start given up before anything was recorded: its folder goes, unless
    /// something else came into it. Off the main thread: the volume may be
    /// slow, or gone.
    private func discardUnstarted(_ folder: URL) {
        DispatchQueue.global(qos: .utility).async { [store] in
            store.release(folder)
            let manager = FileManager.default
            for name in [ForkMeetingFolder.sidecarName, ForkMeetingStore.sidecarDraftName, ForkMeetingFolder.masterName] {
                try? manager.removeItem(at: folder.appendingPathComponent(name))
            }
            if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? manager.removeItem(at: folder)
            }
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
