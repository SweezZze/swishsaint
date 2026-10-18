// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AVFoundation
import Foundation
import os

/// The microphone for dictation: 16 kHz mono Float32, the format both
/// engines take.
///
/// `AVCaptureSession`, not `AVAudioEngine`. On macOS the engine always
/// starts an output node too, so CoreAudio builds an aggregate device for a
/// capture that plays nothing; with AirPods connected that aggregate forces
/// the headset into call mode and, measured in bran, records digital silence
/// one session in twelve. A capture session has no output, so no aggregate.
///
/// One session per dictation: a session holds a device that may be gone by
/// the next one. `start` and `stop` run on the main thread; the session
/// itself starts and stops on its own queue, since `startRunning` blocks.
final class ForkDictationMicrophone: NSObject, @unchecked Sendable {
    struct Callbacks {
        /// Main thread: the microphone really delivers.
        var started: () -> Void
        /// Audio queue, about 20 times a second, 0…1.
        var level: (Float) -> Void
        /// Audio queue, 16 kHz mono.
        var samples: (UnsafeBufferPointer<Float>) -> Void
        /// Main thread: `.microphoneDenied`, `.captureFailed` or `.microphoneSilent`.
        var failed: (ForkDictationFailure) -> Void
    }

    static let sampleRate: Double = 16_000
    /// No sample at all after this long: the stream never ran.
    static let noSampleDeadline: TimeInterval = 1.2
    /// Samples, but all exactly zero after this long: digital silence, the
    /// mark of a muted device or a stale permission.
    static let silentDeadline: TimeInterval = 3

    private static let logger = Logger(subsystem: "fork.dictation", category: "microphone")
    private static let levelInterval = Int(sampleRate / 20)

    /// What the capture queue and the main thread share.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var samples: [Float] = []
        var peak: Float = 0
        var received = 0
        var levelSum: Float = 0
        var levelCount = 0
        var callbacks: Callbacks?
    }

    private let shared = Shared()
    /// Serial: frames arrive in order, and `converter` is only touched here.
    private let captureQueue = DispatchQueue(label: "fork.dictation.microphone.capture", qos: .userInteractive)
    /// Where the session starts and stops: both block.
    private let sessionQueue = DispatchQueue(label: "fork.dictation.microphone.session", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Main thread state.
    private var session: AVCaptureSession?
    private var generation = 0
    private var startedAt: Date?
    private var watchdogs: [DispatchWorkItem] = []
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    /// Opens the microphone. Asks for permission the first time, then goes on
    /// with this same capture once it is granted.
    func start(device: String, callbacks: Callbacks) {
        precondition(Thread.isMainThread)
        cancel()
        generation &+= 1
        let generation = generation
        isRunning = true
        shared.lock.withLock {
            shared.samples = []
            shared.samples.reserveCapacity(Int(Self.sampleRate * ForkDictationSupport.maximumDuration))
            shared.peak = 0
            shared.received = 0
            shared.levelSum = 0
            shared.levelCount = 0
            shared.callbacks = callbacks
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            open(device: device, generation: generation)
        case .notDetermined:
            Permissions.shared.requestMicrophone { [weak self] granted in
                guard let self, self.generation == generation, self.isRunning else { return }
                if granted {
                    self.open(device: device, generation: generation)
                } else {
                    self.fail(.microphoneDenied, generation: generation)
                }
            }
        default:
            fail(.microphoneDenied, generation: generation)
        }
    }

    /// Stops and hands back everything heard, with the loudest RMS seen.
    func stop() -> (samples: [Float], peak: Float, duration: TimeInterval) {
        precondition(Thread.isMainThread)
        guard isRunning else { return ([], 0, 0) }
        tearDown()
        let (samples, peak) = shared.lock.withLock { () -> ([Float], Float) in
            let result = (shared.samples, shared.peak)
            // The reserved five minutes go back now, not at the next dictation.
            shared.samples = []
            shared.callbacks = nil
            return result
        }
        return (samples, peak, Double(samples.count) / Self.sampleRate)
    }

    /// Stops and throws away what was heard.
    func cancel() {
        precondition(Thread.isMainThread)
        guard isRunning else { return }
        tearDown()
        shared.lock.withLock {
            shared.samples = []
            shared.callbacks = nil
        }
    }

    // MARK: - Session

    private func open(device choice: String, generation: Int) {
        guard let device = ForkDictationAudioDevices.captureDevice(for: choice) else {
            fail(.captureFailed, generation: generation)
            return
        }
        Self.logger.info("microphone: \(device.localizedName, privacy: .private)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let session = AVCaptureSession()
            let output = AVCaptureAudioDataOutput()
            guard let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                DispatchQueue.main.async { self.fail(.captureFailed, generation: generation) }
                return
            }
            session.addInput(input)
            output.setSampleBufferDelegate(self, queue: self.captureQueue)
            guard session.canAddOutput(output) else {
                DispatchQueue.main.async { self.fail(.captureFailed, generation: generation) }
                return
            }
            session.addOutput(output)
            self.captureQueue.sync { self.converter = nil }
            session.startRunning()
            let running = session.isRunning
            DispatchQueue.main.async {
                guard self.generation == generation, self.isRunning else {
                    // Given up while it was starting.
                    self.sessionQueue.async { session.stopRunning() }
                    return
                }
                guard running else {
                    self.fail(.captureFailed, generation: generation)
                    return
                }
                self.session = session
                self.startedAt = Date()
                self.observe(session, generation: generation)
                self.armWatchdogs(generation: generation)
                self.shared.lock.withLock { self.shared.callbacks }?.started()
            }
        }
    }

    private func observe(_ session: AVCaptureSession, generation: Int) {
        let center = NotificationCenter.default
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: .main) { [weak self] _ in
                self?.fail(.captureFailed, generation: generation)
            })
        }
    }

    private func armWatchdogs(generation: Int) {
        let noSample = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, self.isRunning else { return }
            if self.shared.lock.withLock({ self.shared.received }) == 0 {
                self.fail(.microphoneSilent, generation: generation)
            }
        }
        let silent = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, self.isRunning else { return }
            if self.shared.lock.withLock({ self.shared.peak }) == 0 {
                self.fail(.microphoneSilent, generation: generation)
            }
        }
        watchdogs = [noSample, silent]
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noSampleDeadline, execute: noSample)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silentDeadline, execute: silent)
    }

    private func fail(_ failure: ForkDictationFailure, generation: Int) {
        guard self.generation == generation, isRunning else { return }
        let callbacks = shared.lock.withLock { shared.callbacks }
        cancel()
        callbacks?.failed(failure)
    }

    private func tearDown() {
        generation &+= 1
        isRunning = false
        startedAt = nil
        watchdogs.forEach { $0.cancel() }
        watchdogs = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let session else { return }
        self.session = nil
        // `stopRunning` returns once the stream has stopped, so once both
        // queues have drained nothing more reaches the buffer.
        sessionQueue.sync { session.stopRunning() }
        captureQueue.sync { converter = nil }
    }
}

// MARK: - Capture queue

extension ForkDictationMicrophone: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        // Built from the first frame: the input format is not known before,
        // and a wrong guess here gives white noise rather than an error.
        if converter == nil || converter?.inputFormat != format {
            converter = AVAudioConverter(from: format, to: targetFormat)
        }
        guard let converter else { return }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        source.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: source.mutableAudioBufferList) == noErr else { return }

        let capacity = AVAudioFrameCount(Double(frames) * targetFormat.sampleRate / format.sampleRate) + 64
        guard let target = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        // The converter asks for its input by callback and takes it once.
        let handedOver = Latch()
        var error: NSError?
        converter.convert(to: target, error: &error) { _, status in
            guard handedOver.close() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return source
        }
        guard error == nil, let channel = target.floatChannelData?[0], target.frameLength > 0 else { return }
        consume(UnsafeBufferPointer(start: channel, count: Int(target.frameLength)))
    }

    private func consume(_ chunk: UnsafeBufferPointer<Float>) {
        var sum: Float = 0
        for value in chunk { sum += value * value }
        let rms = (sum / Float(chunk.count)).squareRoot()

        let limit = Int(Self.sampleRate * ForkDictationSupport.maximumDuration)
        var level: Float?
        let callbacks = shared.lock.withLock { () -> Callbacks? in
            guard let callbacks = shared.callbacks else { return nil }
            let room = max(0, limit - shared.samples.count)
            if room > 0 { shared.samples.append(contentsOf: chunk.prefix(room)) }
            shared.received += chunk.count
            shared.peak = max(shared.peak, rms)
            shared.levelSum += sum
            shared.levelCount += chunk.count
            if shared.levelCount >= Self.levelInterval {
                level = ForkDictationSupport.level(rms: (shared.levelSum / Float(shared.levelCount)).squareRoot())
                shared.levelSum = 0
                shared.levelCount = 0
            }
            return callbacks
        }
        guard let callbacks else { return }
        callbacks.samples(chunk)
        if let level { callbacks.level(level) }
    }

    /// Single use: the first `close` returns true, the next ones false.
    private final class Latch: @unchecked Sendable {
        private var isOpen = true
        func close() -> Bool {
            defer { isOpen = false }
            return isOpen
        }
    }
}
