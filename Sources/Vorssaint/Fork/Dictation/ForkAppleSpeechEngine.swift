// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AVFoundation
import Foundation
import os
import Speech

/// Apple's speech recognition as a dictation engine: on this Mac when the
/// language is installed for it, else through Apple's servers, as macOS's
/// own dictation does. It is fed by the shared microphone and recognizes
/// while the person speaks.
///
/// A recognition request can end on its own while the person still talks
/// (Apple's servers stop after about a minute, a long pause ends it too):
/// what it understood is kept and a new request takes over, so nothing said
/// before is lost.
///
/// Main thread, except `append` (the microphone's queue).
final class ForkAppleSpeechEngine: ForkDictationEngine {
    let kind = ForkDictationEngineKind.apple
    var onFailure: ((ForkDictationFailure) -> Void)?

    /// How long the recognizer may take to settle once the person stops.
    static let finishTimeout: TimeInterval = 4
    /// Requests reopened in one dictation before giving up on the rest: a
    /// recognizer that fails at once would otherwise loop.
    static let maximumRestarts = 30

    private let log = Logger(subsystem: "fork.dictation", category: "apple")
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)

    /// The request the microphone writes into, from its queue.
    private let requestLock = NSLock()
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?

    private var recognizer: SFSpeechRecognizer?
    private var vocabulary: [String] = []
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    /// The text of the requests that already ended, in order.
    private var settled: [String] = []
    /// The best guess of the request under way.
    private var current = ""
    private var restarts = 0
    /// An error that was not just silence: reported when nothing at all was
    /// understood.
    private var failedForReal = false
    private var completion: ((Result<String, ForkDictationFailure>) -> Void)?
    private var finishTimeout: DispatchWorkItem?
    private var isFinishing = false
    private var isActive = false

    // MARK: Availability

    /// Release builds of the fork carry the speech recognition purpose
    /// string (fork/build-release.sh). Without it, macOS ends the app the
    /// moment it asks, so a build without it never asks.
    static var canAskForSpeechRecognition: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    static var authorization: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Asks once; `completion` runs on the main thread with the answer.
    static func requestAuthorization(_ completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        guard canAskForSpeechRecognition else {
            completion(authorization)
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status) }
        }
    }

    /// The languages Apple recognizes (BCP 47), read once: the list is long
    /// and does not change while the app runs.
    static let supportedLanguages: [String] = SFSpeechRecognizer.supportedLocales()
        .map { ForkDictationSupport.normalized($0.identifier) }
        .sorted()

    /// The language actually recognized for `language`: itself when Apple
    /// knows it, else the person's own languages, region first.
    static func resolvedLanguage(_ language: String) -> String? {
        ForkDictationSupport.localeIdentifier(chosen: language, supported: supportedLanguages,
                                              preferred: Locale.preferredLanguages)
    }

    static func isAvailable(language: String) -> Bool {
        guard let identifier = resolvedLanguage(language) else { return false }
        return SFSpeechRecognizer(locale: Locale(identifier: identifier))?.isAvailable ?? false
    }

    /// Whether `language` is recognized without leaving this Mac.
    static func supportsOnDevice(language: String) -> Bool {
        guard let identifier = resolvedLanguage(language) else { return false }
        return SFSpeechRecognizer(locale: Locale(identifier: identifier))?.supportsOnDeviceRecognition ?? false
    }

    // MARK: ForkDictationEngine

    func prepare() {}

    func begin(language: String, vocabulary: [String]) -> ForkDictationFailure? {
        cancel()
        guard Self.canAskForSpeechRecognition else { return .speechUnavailableInBuild }
        guard Self.authorization == .authorized else { return .speechDenied }
        guard let identifier = Self.resolvedLanguage(language),
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
              recognizer.isAvailable
        else { return .languageUnavailable }
        self.recognizer = recognizer
        self.vocabulary = Array(vocabulary.prefix(ForkDictationSupport.vocabularyLimit))
        settled = []
        current = ""
        restarts = 0
        failedForReal = false
        isFinishing = false
        isActive = true
        openRequest()
        return nil
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        guard samples.count > 0, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0],
              let base = samples.baseAddress
        else { return }
        channel.update(from: base, count: samples.count)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        requestLock.withLock { liveRequest }?.append(buffer)
    }

    func finish(samples: [Float], completion: @escaping (Result<String, ForkDictationFailure>) -> Void) {
        guard isActive else {
            completion(.success(""))
            return
        }
        self.completion = completion
        isFinishing = true
        guard request != nil else {
            // The last request ended on its own and none followed.
            deliver()
            return
        }
        setLiveRequest(nil)
        request?.endAudio()
        let timeout = DispatchWorkItem { [weak self] in self?.deliver() }
        finishTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishTimeout, execute: timeout)
    }

    func cancel() {
        guard isActive else { return }
        completion = nil
        task?.cancel()
        tearDown()
    }

    // MARK: Requests

    private func openRequest() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = vocabulary
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        current = ""
        setLiveRequest(request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let realError = error.map { !Self.isSilence($0) } ?? false
            DispatchQueue.main.async {
                guard let self, self.request === request else { return }
                if let text { self.current = text }
                if realError { self.failedForReal = true }
                if isFinal || error != nil { self.requestEnded(error: error, isReal: realError) }
            }
        }
    }

    /// The request in front ended: at the end of the dictation, it is the
    /// answer; before, the person is still talking and a new one follows.
    private func requestEnded(error: Error?, isReal: Bool) {
        let understoodSomething = !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        settle()
        task = nil
        request = nil
        setLiveRequest(nil)
        if isFinishing {
            deliver()
            return
        }
        if let error {
            log.debug("recognition ended early: \(String(describing: error), privacy: .public)")
        }
        // A request that failed without understanding anything (no network,
        // recognizer gone) would fail again at once. With nothing kept so far,
        // the person hears it now instead of after minutes of talking.
        guard restarts < Self.maximumRestarts, understoodSomething || !isReal else {
            if isReal, settled.isEmpty { reportFailure(.transcriptionFailed) }
            return
        }
        restarts += 1
        openRequest()
    }

    private func settle() {
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { settled.append(text) }
        current = ""
    }

    private func deliver() {
        guard isActive, let completion else { return }
        settle()
        task?.finish()
        let text = ForkDictationSupport.joined(settled)
        let failed = failedForReal
        tearDown()
        if text.isEmpty, failed {
            completion(.failure(.transcriptionFailed))
        } else {
            completion(.success(text))
        }
    }

    private func reportFailure(_ failure: ForkDictationFailure) {
        let handler = onFailure
        tearDown()
        handler?(failure)
    }

    private func tearDown() {
        finishTimeout?.cancel()
        finishTimeout = nil
        completion = nil
        task = nil
        request = nil
        setLiveRequest(nil)
        recognizer = nil
        settled = []
        current = ""
        isFinishing = false
        isActive = false
    }

    private func setLiveRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        requestLock.withLock { liveRequest = request }
    }

    /// "No speech detected" and a cancelled request are not failures: the
    /// person said nothing, or the request was ended on purpose.
    private static func isSilence(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case "kAFAssistantErrorDomain":
            // 1110: no speech detected; 216, 203, 301: request cancelled or ended.
            return [1110, 216, 203, 301].contains(error.code)
        case "kLSRErrorDomain":
            // On-device recognition: 301, the request was cancelled.
            return error.code == 301
        default:
            return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
        }
    }
}
