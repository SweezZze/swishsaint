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
/// The session is built ahead of time (`prepare`) and only started when a
/// dictation begins: building it takes most of the ~0.3 s a cold start
/// costs, the first word of a hold-to-talk sentence. A stopped session is
/// kept for the next dictation, rebuilt only when the device changes.
/// Building, starting and stopping all happen on the session queue, since
/// they block; the main thread never waits for them.
final class ForkDictationMicrophone: NSObject, @unchecked Sendable {
    struct Callbacks {
        /// Main thread: the microphone really delivers.
        var started: () -> Void
        /// Audio queue, about 20 times a second, 0…1.
        var level: (Float) -> Void
        /// Audio queue, 16 kHz mono. Never called once `stop` or `cancel`
        /// has returned.
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
    static let levelInterval = Int(sampleRate / 20)

    /// What the capture queue and the main thread share. `generation` names
    /// the dictation allowed to fill the buffer: frames from a session still
    /// stopping, or from the previous dictation, are dropped.
    fileprivate final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var generation = 0
        var samples: [Float] = []
        var peak: Float = 0
        var received = 0
        var levelSum: Float = 0
        var levelCount = 0
        var callbacks: Callbacks?
    }

    /// A built session, kept between dictations. Session queue only.
    private struct Prepared {
        let deviceID: String
        let session: AVCaptureSession
        let sink: CaptureSink
    }

    private let shared = Shared()
    /// Serial: frames arrive in order, each sink's converter is only touched here.
    private let captureQueue = DispatchQueue(label: "fork.dictation.microphone.capture", qos: .userInteractive)
    /// Where the session is built, started and stopped: all three block.
    private let sessionQueue = DispatchQueue(label: "fork.dictation.microphone.session", qos: .userInitiated)
    /// Session queue only.
    private var prepared: Prepared?

    /// Main thread state.
    private var running: AVCaptureSession?
    private var generation = 0
    private var watchdogs: [DispatchWorkItem] = []
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    /// Builds the session for `device` ahead of the next dictation, without
    /// starting it: no microphone indicator, nothing recorded. Cheap when it
    /// is already built for that device.
    func prepare(device: String) {
        precondition(Thread.isMainThread)
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = ForkDictationAudioDevices.captureDevice(for: device) else { return }
        sessionQueue.async { [weak self] in
            _ = self?.preparedSession(for: device)
        }
    }

    /// Opens the microphone. Asks for permission the first time, then goes on
    /// with this same capture once it is granted.
    func start(device: String, callbacks: Callbacks) {
        precondition(Thread.isMainThread)
        cancel()
        generation &+= 1
        let generation = generation
        isRunning = true
        shared.lock.withLock {
            shared.generation = generation
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
    /// Returns at once: the session stops on its own queue.
    func stop() -> (samples: [Float], peak: Float, duration: TimeInterval) {
        precondition(Thread.isMainThread)
        guard isRunning else { return ([], 0, 0) }
        let (samples, peak) = detach { () -> ([Float], Float) in
            let result = (shared.samples, shared.peak)
            // The reserved five minutes go back now, not at the next dictation.
            shared.samples = []
            return result
        }
        tearDown()
        return (samples, peak, Double(samples.count) / Self.sampleRate)
    }

    /// Stops and throws away what was heard.
    func cancel() {
        precondition(Thread.isMainThread)
        guard isRunning else { return }
        detach { shared.samples = [] }
        tearDown()
    }

    // MARK: - Session

    /// Lock held while `body` runs: from here on no frame reaches the
    /// buffer or the callbacks.
    @discardableResult
    private func detach<T>(_ body: () -> T) -> T {
        shared.lock.withLock {
            shared.generation = -1
            shared.callbacks = nil
            return body()
        }
    }

    /// Session queue. The session built for `device`, built now if needed.
    private func preparedSession(for device: AVCaptureDevice) -> Prepared? {
        if let prepared, prepared.deviceID == device.uniqueID, device.isConnected { return prepared }
        prepared = nil
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        let sink = CaptureSink(shared: shared)
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        output.setSampleBufferDelegate(sink, queue: captureQueue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        let built = Prepared(deviceID: device.uniqueID, session: session, sink: sink)
        prepared = built
        return built
    }

    private func open(device choice: String, generation: Int) {
        guard let device = ForkDictationAudioDevices.captureDevice(for: choice) else {
            fail(.captureFailed, generation: generation)
            return
        }
        Self.logger.info("microphone: \(device.localizedName, privacy: .private)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let prepared = self.preparedSession(for: device) else {
                DispatchQueue.main.async { self.fail(.captureFailed, generation: generation) }
                return
            }
            let session = prepared.session
            // Given up before the session even started: leave it built.
            guard self.shared.lock.withLock({ self.shared.generation }) == generation else { return }
            // Each dictation converts from scratch: the device format may
            // have changed since the last one.
            self.captureQueue.sync { prepared.sink.resetConverter(generation: generation) }
            session.startRunning()
            let isRunning = session.isRunning
            if !isRunning { self.prepared = nil }
            DispatchQueue.main.async {
                guard self.generation == generation, self.isRunning else {
                    // Given up while it was starting.
                    self.sessionQueue.async { session.stopRunning() }
                    return
                }
                guard isRunning else {
                    self.fail(.captureFailed, generation: generation)
                    return
                }
                self.running = session
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
                self?.forget(session)
                self?.fail(.captureFailed, generation: generation)
            })
        }
    }

    /// A session that failed is not kept for the next dictation.
    private func forget(_ session: AVCaptureSession) {
        sessionQueue.async { [weak self] in
            if self?.prepared?.session === session { self?.prepared = nil }
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

    /// Main thread, after `detach`. Never waits: the session stops on its
    /// queue, and frames still in flight are dropped by the generation.
    private func tearDown() {
        generation &+= 1
        isRunning = false
        watchdogs.forEach { $0.cancel() }
        watchdogs = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let session = running else { return }
        running = nil
        sessionQueue.async { session.stopRunning() }
    }
}

// MARK: - Capture queue

/// The delegate of one session's output, with that session's converter.
private final class CaptureSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let shared: ForkDictationMicrophone.Shared
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: ForkDictationMicrophone.sampleRate, channels: 1,
        interleaved: false)!
    /// Capture queue only.
    private var converter: AVAudioConverter?
    private var generation = 0

    init(shared: ForkDictationMicrophone.Shared) {
        self.shared = shared
    }

    /// Capture queue.
    func resetConverter(generation: Int) {
        converter = nil
        self.generation = generation
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard shared.lock.withLock({ shared.generation }) == generation,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
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

    /// Everything under the lock, callbacks included: once `stop` has
    /// detached the buffer, no chunk can slip in after it.
    private func consume(_ chunk: UnsafeBufferPointer<Float>) {
        var sum: Float = 0
        for value in chunk { sum += value * value }
        let rms = (sum / Float(chunk.count)).squareRoot()
        let limit = Int(ForkDictationMicrophone.sampleRate * ForkDictationSupport.maximumDuration)
        shared.lock.withLock {
            guard shared.generation == generation, let callbacks = shared.callbacks else { return }
            let room = max(0, limit - shared.samples.count)
            if room > 0 { shared.samples.append(contentsOf: chunk.prefix(room)) }
            shared.received += chunk.count
            shared.peak = max(shared.peak, rms)
            shared.levelSum += sum
            shared.levelCount += chunk.count
            callbacks.samples(chunk)
            if shared.levelCount >= ForkDictationMicrophone.levelInterval {
                let level = ForkDictationSupport.level(rms: (shared.levelSum / Float(shared.levelCount)).squareRoot())
                shared.levelSum = 0
                shared.levelCount = 0
                callbacks.level(level)
            }
        }
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
