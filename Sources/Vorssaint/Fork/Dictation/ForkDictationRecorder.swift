// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import AVFoundation
import Speech

/// One dictation: the microphone into Apple's speech recognizer, on this Mac
/// when the language is installed for it, else through Apple's dictation
/// servers, as macOS's own dictation does. Nothing is recorded to disk.
///
/// Driven from the main thread; its handlers are called there too.
final class ForkDictationRecorder {
    /// The input level, between 0 and 1, a few dozen times a second.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var finished = false
    private var completion: ((String) -> Void)?
    private var finishTimeout: DispatchWorkItem?
    private let levelLock = NSLock()
    private var lastLevelTime: TimeInterval = 0

    private(set) var isRunning = false

    /// Whether `localeID` is recognized without leaving this Mac.
    static func runsOnDevice(localeID: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeID))?.supportsOnDeviceRecognition ?? false
    }

    /// Opens the microphone and starts recognizing. False when the
    /// recognizer or the microphone is not available.
    func start(localeID: String, vocabulary: [String] = []) -> Bool {
        guard !isRunning,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              recognizer.isAvailable
        else { return false }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = vocabulary
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            self?.report(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }

        transcript = ""
        finished = false
        self.request = request
        isRunning = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            DispatchQueue.main.async {
                guard let self, self.request === request else { return }
                if let text { self.transcript = text }
                if isFinal || error != nil { self.deliver() }
            }
        }
        return true
    }

    /// Stops listening and hands over everything understood, once the
    /// recognizer has settled or after a short wait.
    func finish(_ completion: @escaping (String) -> Void) {
        guard isRunning else {
            completion("")
            return
        }
        self.completion = completion
        stopAudio()
        request?.endAudio()
        let timeout = DispatchWorkItem { [weak self] in self?.deliver() }
        finishTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + ForkDictationSupport.finishTimeout, execute: timeout)
    }

    /// Stops listening and forgets what was said.
    func cancel() {
        completion = nil
        task?.cancel()
        stopAudio()
        tearDown()
    }

    private func deliver() {
        guard isRunning, !finished else { return }
        finished = true
        let completion = completion
        let text = transcript
        stopAudio()
        task?.finish()
        tearDown()
        completion?(text)
    }

    private func tearDown() {
        finishTimeout?.cancel()
        finishTimeout = nil
        completion = nil
        task = nil
        request = nil
        transcript = ""
        isRunning = false
    }

    private func stopAudio() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// On the audio thread: the buffer's level, at most 30 times a second.
    private func report(_ buffer: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let due = levelLock.withLock { () -> Bool in
            guard now - lastLevelTime >= 1.0 / 30 else { return false }
            lastLevelTime = now
            return true
        }
        guard due, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            sum += samples[index] * samples[index]
        }
        let level = ForkDictationSupport.level(rms: (sum / Float(buffer.frameLength)).squareRoot())
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.onLevel?(level)
        }
    }
}
