// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import Speech

/// Dictation anywhere: hold the chosen key, speak, release, and the words
/// are pasted where the text cursor is (`ForkDictationGesture` for the
/// key's rules).
///
/// The key is watched by a listen-only event tap, which needs Accessibility,
/// like the paste. The microphone is opened only while dictating.
final class ForkDictationService: ObservableObject {
    static let shared = ForkDictationService()

    @Published private(set) var speechAuthorization = SFSpeechRecognizer.authorizationStatus()

    private let tapStateLock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Read on the tap's thread, written on the main thread.
    private var triggerKey = ForkDictationTrigger.fallback

    private var gesture = ForkDictationGesture()
    private let recorder = ForkDictationRecorder()
    private var session = 0
    private var limitWork: DispatchWorkItem?
    private var triggerHeld = false

    private init() {
        recorder.onLevel = { level in ForkDictationHUD.shared.push(level: level) }
    }

    /// Release builds of the fork carry the speech recognition purpose
    /// string (fork/build-release.sh). Without it, macOS ends the app the
    /// moment it asks, so a build without it never asks.
    static var canAskForSpeechRecognition: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    static var isWanted: Bool {
        UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationEnabled)
    }

    /// The language dictated: the one chosen in the settings, else the
    /// person's own.
    static var localeID: String? {
        ForkDictationSupport.localeIdentifier(
            chosen: UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationLocale) ?? "",
            supported: SFSpeechRecognizer.supportedLocales().map(\.identifier),
            preferred: Locale.preferredLanguages)
    }

    // MARK: - Lifecycle

    static func sync() {
        shared.sync()
    }

    private var accessibilityObserver: AnyCancellable?

    /// At launch: syncs now, then again whenever Accessibility is granted
    /// or revoked.
    static func startFollowingPermissions() {
        shared.sync()
        shared.accessibilityObserver = Permissions.shared.$accessibility
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in ForkDictationService.sync() }
    }

    func sync() {
        refreshAuthorization()
        let canRun = SessionActivitySupport.tapShouldRun(featureWanted: Self.isWanted,
                                                         accessibilityGranted: AXIsProcessTrusted(),
                                                         sessionIsActive: SessionActivity.shared.isActive)
        if canRun {
            start()
        } else {
            stop()
        }
    }

    /// Before Accessibility is revoked or the app quits: the tap goes, and
    /// a dictation under way is given up.
    static func suspend() {
        shared.stop()
    }

    func refreshAuthorization() {
        let status = SFSpeechRecognizer.authorizationStatus()
        if speechAuthorization != status { speechAuthorization = status }
    }

    func requestSpeechRecognition() {
        guard Self.canAskForSpeechRecognition else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async { self?.speechAuthorization = status }
        }
    }

    private func start() {
        let key = ForkDictationTrigger.current
        tapStateLock.withLock { triggerKey = key }
        if let port = tapStateLock.withLock({ tap }) {
            CGEvent.tapEnable(tap: port, enable: true)
            return
        }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<ForkDictationService>.fromOpaque(userInfo).takeUnretainedValue()
                        .observe(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapStateLock.withLock {
            self.tap = tap
            runLoopSource = source
        }
        if let source { PointerTapRunLoop.add(source) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        let (port, source) = tapStateLock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
            let current = (tap, runLoopSource)
            tap = nil
            runLoopSource = nil
            return current
        }
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { PointerTapRunLoop.remove(source, invalidating: port) }
        if gesture.isListening { cancel() }
        gesture = ForkDictationGesture()
        triggerHeld = false
    }

    // MARK: - Tap thread

    private enum Input {
        case trigger(down: Bool, time: TimeInterval)
        case otherKey
        case escape
    }

    /// Decodes and hands over to the main thread.
    private func observe(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if SessionActivity.shared.isActive, let port = tapStateLock.withLock({ tap }) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let input: Input
        if type == .flagsChanged {
            let key = tapStateLock.withLock { triggerKey }
            if let down = key.isDown(keyCode: keyCode, flags: event.flags.rawValue) {
                let time = Double(EventTimestamp.nanoseconds(of: event)) / 1_000_000_000
                input = .trigger(down: down, time: time)
            } else {
                input = .otherKey
            }
        } else if type == .keyDown {
            input = keyCode == Int64(kVK_Escape) ? .escape : .otherKey
        } else {
            return
        }
        DispatchQueue.main.async { [weak self] in self?.handle(input) }
    }

    // MARK: - Main thread

    private func handle(_ input: Input) {
        let command: ForkDictationGesture.Command
        switch input {
        case let .trigger(down, time):
            // A repeated flag change for a key already down is not a press.
            guard down != triggerHeld else { return }
            triggerHeld = down
            command = down ? gesture.triggerDown(at: time) : gesture.triggerUp(at: time)
            if !down, gesture.state == .handsFree {
                ForkDictationHUD.shared.show(.handsFree)
            }
        case .otherKey:
            command = gesture.otherKey()
        case .escape:
            command = gesture.escape()
        }
        switch command {
        case .none: break
        case .start: begin()
        case .finish: finish()
        case .cancel: cancel()
        }
    }

    private func begin() {
        let text = ForkDictationStrings.strings(L10n.shared.language)
        guard let problem = problemBeforeStarting(text) else {
            let vocabulary = ForkDictationSupport.vocabulary(
                from: UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationVocabulary) ?? "")
            guard let localeID = Self.localeID, recorder.start(localeID: localeID, vocabulary: vocabulary) else {
                fail(text.problemUnavailable)
                return
            }
            session += 1
            let current = session
            ForkDictationHUD.shared.show(.listening)
            playSound("Tink")
            let limit = DispatchWorkItem { [weak self] in
                guard let self, self.session == current, self.recorder.isRunning else { return }
                self.gesture.end(triggerHeld: self.triggerHeld)
                self.finish()
            }
            limitWork = limit
            DispatchQueue.main.asyncAfter(deadline: .now() + ForkDictationSupport.maximumDuration, execute: limit)
            return
        }
        fail(problem)
    }

    /// What keeps a dictation from starting, said in a few words.
    private func problemBeforeStarting(_ text: ForkDictationStrings) -> String? {
        if !AXIsProcessTrusted() { return text.problemAccessibility }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            Permissions.shared.requestMicrophone()
            return text.problemMicrophone
        default:
            return text.problemMicrophone
        }
        refreshAuthorization()
        switch speechAuthorization {
        case .authorized: return nil
        case .notDetermined:
            if Self.canAskForSpeechRecognition {
                requestSpeechRecognition()
                return text.problemSpeech
            }
            return text.problemBuild
        default:
            return text.problemSpeech
        }
    }

    private func fail(_ message: String) {
        gesture.end(triggerHeld: triggerHeld)
        ForkDictationHUD.shared.show(.problem(message))
        NSSound.beep()
    }

    private func finish() {
        limitWork?.cancel()
        limitWork = nil
        guard recorder.isRunning else {
            ForkDictationHUD.shared.hide()
            return
        }
        ForkDictationHUD.shared.show(.writing)
        playSound("Pop")
        let current = session
        recorder.finish { [weak self] transcript in
            guard let self, self.session == current else { return }
            ForkDictationHUD.shared.hide()
            let replacements = ForkDictationSupport.replacements(
                from: UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationReplacements) ?? "")
            guard let text = ForkDictationSupport.insertion(
                ForkDictationSupport.applying(replacements, to: transcript)) else { return }
            TransientPaste.shared.paste(text)
        }
    }

    private func cancel() {
        limitWork?.cancel()
        limitWork = nil
        session += 1
        recorder.cancel()
        ForkDictationHUD.shared.hide()
    }

    private func playSound(_ name: String) {
        guard UserDefaults.standard.bool(forKey: ForkDefaultsKey.dictationSounds) else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
