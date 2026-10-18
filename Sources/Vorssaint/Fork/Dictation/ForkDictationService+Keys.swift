// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation

/// From the key tap to the machine: who owns the session, the gesture, and
/// the effects the machine returns.
extension ForkDictationService {
    // MARK: Keys

    func handle(key event: ForkDictationKeyEvent) {
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
                    if shortcut.action == .openHistory {
                        toggleHistory()
                    } else {
                        send(.gesture(.start, shortcut, handsFree: false))
                    }
                } else {
                    paster.dropSnapshot()
                }
                return
            }
            guard let owner, owner.id == id else { return }
            ownerIsDown = false
            send(.gesture(gesture.triggerUp(at: now), owner, handsFree: gesture.isHandsFree))
        case .otherKey:
            if pendingPasteLast != nil {
                pendingPasteLast = nil
                paster.dropSnapshot()
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
        if shortcut.action == .openHistory {
            // Like Paste last: a lone modifier opens at its release, if
            // nothing else was pressed with it.
            if case .modifier = shortcut.key {
                pendingPasteLast = (shortcut.id, now)
                updateTapFlags()
            } else {
                toggleHistory()
            }
            return
        }
        if shortcut.action == .pasteLast {
            // The clipboard to give back is read now, outside the paste's
            // deadline. A lone modifier pastes at its release, if nothing
            // else was pressed with it; a combination is already deliberate.
            paster.prepareSnapshot()
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

    // MARK: Machine

    /// Events raised while effects run are queued, so the machine never
    /// handles one inside another.
    func send(_ event: ForkDictationMachine.Event) {
        queue.append(event)
        guard !isDraining else { return }
        isDraining = true
        while !queue.isEmpty {
            let next = queue.removeFirst()
            for effect in machine.handle(next) { run(effect) }
            settleGesture()
        }
        isDraining = false
        if machine.phase == .idle {
            failureAwaitingIntent = nil
            // Ended without a paste (cancelled, nothing heard, failed): the
            // clipboard read for it would be stale for the next one.
            paster.dropSnapshot()
        }
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

    func updateTapFlags() {
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

    func invalidateSession() {
        token = UUID()
        armWork?.cancel()
        armWork = nil
        timers.forEach { $0.invalidate() }
        timers.removeAll()
    }

    /// Runs `work` on the main thread if the session is still `session`.
    func ifCurrent(_ session: UUID, _ work: @escaping () -> Void) {
        let run = { [weak self] in
            guard let self, self.token == session else { return }
            work()
        }
        Thread.isMainThread ? run() : DispatchQueue.main.async(execute: run)
    }
}
