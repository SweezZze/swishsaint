// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AVFoundation
import Foundation

/// The listening part of a session: arming, the microphone and the engine,
/// the time limits, and the transcription.
extension ForkDictationService {

    func scheduleArm(after delay: TimeInterval) {
        let session = token
        let work = DispatchWorkItem { [weak self] in
            self?.ifCurrent(session) { self?.send(.armElapsed) }
        }
        armWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func startCapture() {
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
    func sayFailureIfMeant() {
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
        // The engine stopped hearing but kept what it understood: the
        // dictation ends here and is written, as at the time limit.
        engine.onStopped = { [weak self] in
            self?.ifCurrent(session) { self?.send(.timeLimitReached) }
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

    func finishCapture() {
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
        keptCapture = (capture.samples, capture.duration)
        engine.finish(samples: capture.samples) { [weak self] result in
            self?.ifCurrent(session) { self?.transcribed(result) }
        }
    }

    private func transcribed(_ result: Result<String, ForkDictationFailure>) {
        switch result {
        case let .success(raw):
            let text = Self.corrected(raw)
            if text.isEmpty {
                keptCapture = nil
            } else {
                keptRawText = raw
            }
            send(text.isEmpty ? .transcribedNothing : .transcribed(text))
        case let .failure(failure):
            // Kept with its audio: the history can try again, with the
            // other engine if need be.
            let recordID = keepInHistory(text: "", outcome: .failed, failure: failure)
            send(.failed(failure))
            if let recordID { presenter.attach(recordID: recordID) }
        }
    }

    /// Stops the microphone and drops any result still on its way: the
    /// token changes, so late answers find no session.
    func discardCapture() {
        keptCapture = nil
        keptRawText = nil
        invalidateSession()
        microphone.cancel()
        engine?.cancel()
        prepareMicrophone()
    }

    /// Builds the next capture session ahead of time, so the next press only
    /// has to start it: the first word is not lost to the setup.
    func prepareMicrophone() {
        guard tap.isRunning, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        microphone.prepare(device: microphoneChoice)
    }

    private var microphoneChoice: String {
        UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationMicrophone)
            ?? ForkDictationAudioDevices.builtInChoice
    }
}
