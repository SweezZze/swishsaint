// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AVFoundation
import CoreAudio
import Foundation

/// The microphone of a meeting: an `AVCaptureSession` on the chosen input,
/// rebuilt on the input that should be used whenever it changes, and watched
/// for silence all along.
///
/// - `AVCaptureSession`, never `AVAudioEngine`: the engine's output node
///   makes CoreAudio build an aggregate device that forces AirPods into call
///   mode and records silence. A second session on the same
///   device, the dictation's, is allowed and loses nothing (spike S5).
/// - **Followed**: the system's default input, the device list, a device that
///   disconnects, a session error or interruption all lead to `rebuild`,
///   debounced, done in well under two seconds; `switched` then says the
///   new device's name and how long the track went without sound.
/// - **Silence**: no sample for 1.2 s, or nothing but zeros for 3 s, is said
///   once (`silent`), and its end too (`soundBack`), so the next one is said
///   again.
/// - Samples keep the device's own format: the writer converts every source
///   to its format, so a device that changes rate mid-meeting is harmless.
///
/// The session is built, started and stopped on `sessionQueue` (all three
/// block); samples arrive on `captureQueue`. Nothing here waits on the main
/// thread. Asked only when the permission is granted: the service knows a
/// denied microphone before the meeting starts.
final class ForkMeetingMicrophone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Callbacks {
        /// Capture queue: a buffer, on the host clock.
        var samples: (CMSampleBuffer) -> Void
        /// Session queue: another device took over, after `gap` seconds
        /// without sound.
        var switched: (_ name: String, _ gap: TimeInterval) -> Void
        /// Session queue: the microphone sends nothing, or only zeros.
        var silent: () -> Void
        /// Session queue: sound came back after a silence that was said.
        var soundBack: () -> Void
    }

    /// The meeting app's input when known (a CoreAudio device UID, the same
    /// as the capture device's unique ID). Until the detection knows it, a
    /// "meeting" choice uses the system's input.
    let meetingDevice: String?
    private let choice: ForkMeetingMicrophoneChoice
    private let callbacks: Callbacks

    private let sessionQueue = DispatchQueue(label: "fork.meetings.microphone.session", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "fork.meetings.microphone.capture", qos: .userInitiated)
    /// Device changes come in bursts: one rebuild once they settle.
    static let settleDelay: TimeInterval = 0.3

    // Session queue only.
    private var session: AVCaptureSession?
    private var deviceID: String?
    private var running = false
    private var pendingRebuild: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
    /// The device list's notifications, for the whole recording.
    private var followObservers: [NSObjectProtocol] = []
    /// The current session's own, for as long as it lives.
    private var sessionObservers: [NSObjectProtocol] = []
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// When the last device stopped, for the gap of the next one.
    private var lostAt: Double?
    /// Watchdog ticks since the device was lost, to try again every two
    /// seconds while none runs.
    private var retryTicks = 0

    private let lock = NSLock()
    // Under `lock`: what the capture queue shares.
    private var acceptedSession: AVCaptureSession?
    private var name: String?
    private var silence = ForkMeetingSilenceWatch(at: 0)
    private var firstSampleAfterSwitch: (() -> Void)?

    init(choice: ForkMeetingMicrophoneChoice, meetingDevice: String? = nil, callbacks: Callbacks) {
        self.choice = choice
        self.meetingDevice = meetingDevice
        self.callbacks = callbacks
    }

    /// The device's name, once it runs. Any thread.
    var deviceName: String? { lock.withLock { name } }

    // MARK: - Lifecycle

    /// Opens the device and starts following changes. Answers on the session
    /// queue whether a device runs.
    func start(completion: @escaping (Bool) -> Void) {
        sessionQueue.async { [self] in
            guard !running else { return completion(session != nil) }
            running = true
            follow()
            let opened = open()
            armWatchdog()
            completion(opened)
        }
    }

    /// Stops the device and every listener; no sample arrives once
    /// `completion` runs (on the capture queue).
    func stop(completion: @escaping () -> Void) {
        sessionQueue.async { [self] in
            running = false
            pendingRebuild?.cancel()
            pendingRebuild = nil
            watchdog?.cancel()
            watchdog = nil
            unfollow()
            close()
            captureQueue.async { completion() }
        }
    }

    // MARK: - Device

    /// The capture device this choice means now.
    private func resolveDevice() -> AVCaptureDevice? {
        switch choice {
        case .off:
            return nil
        case .meeting:
            if let meetingDevice, let device = AVCaptureDevice(uniqueID: meetingDevice), device.isConnected {
                return device
            }
            return ForkDictationAudioDevices.captureDevice(for: ForkDictationAudioDevices.systemChoice)
        case .system:
            return ForkDictationAudioDevices.captureDevice(for: ForkDictationAudioDevices.systemChoice)
        case .builtIn:
            return ForkDictationAudioDevices.captureDevice(for: ForkDictationAudioDevices.builtInChoice)
        case let .device(uid):
            // A chosen device that is gone falls back to the built-in one,
            // never to the system's input (the dictation's rule): with a
            // headset on, that is the one most likely to drop to call mode.
            return ForkDictationAudioDevices.captureDevice(for: uid)
        }
    }

    /// Session queue. Builds and starts a session on the device the choice
    /// means now.
    @discardableResult
    private func open() -> Bool {
        guard running, let device = resolveDevice(),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.commitConfiguration()
        lock.withLock { acceptedSession = session }
        session.startRunning()
        guard session.isRunning else {
            lock.withLock { acceptedSession = nil }
            return false
        }
        self.session = session
        deviceID = device.uniqueID
        lock.withLock { name = device.localizedName }
        observe(session)
        return true
    }

    /// Session queue.
    private func close() {
        lock.withLock { acceptedSession = nil }
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers = []
        guard let session else { return }
        self.session = nil
        session.stopRunning()
    }

    /// Session queue: the device to use may have changed. Rebuilds only when
    /// it did, or when the session died.
    private func rebuildIfNeeded(force: Bool) {
        guard running else { return }
        let wanted = resolveDevice()
        guard force || session == nil || wanted?.uniqueID != deviceID || session?.isRunning != true else { return }
        let previous = deviceID
        lostAt = lostAt ?? ForkMeetingWriter.hostSeconds()
        close()
        guard open(), let name = deviceName else { return }
        retryTicks = 0
        let gapStart = lostAt ?? ForkMeetingWriter.hostSeconds()
        let changed = previous != deviceID
        // Said once the new device really delivers, with the time it took.
        lock.withLock {
            silence.rearm(at: ForkMeetingWriter.hostSeconds())
            firstSampleAfterSwitch = { [weak self] in
                guard let self else { return }
                let gap = max(0, ForkMeetingWriter.hostSeconds() - gapStart)
                self.sessionQueue.async {
                    self.lostAt = nil
                    if changed || gap > 0.5 { self.callbacks.switched(name, gap) }
                }
            }
        }
    }

    private func scheduleRebuild(force: Bool) {
        sessionQueue.async { [self] in
            guard running else { return }
            if force { lostAt = lostAt ?? ForkMeetingWriter.hostSeconds() }
            pendingRebuild?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rebuildIfNeeded(force: force) }
            pendingRebuild = work
            sessionQueue.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
        }
    }

    // MARK: - Following

    /// Session queue.
    private func follow() {
        var selectors = [kAudioHardwarePropertyDevices]
        if choice.followsSystemInput { selectors.append(kAudioHardwarePropertyDefaultInputDevice) }
        for selector in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleRebuild(force: false)
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   sessionQueue, block) == noErr {
                listeners.append((address, block))
            }
        }
        let center = NotificationCenter.default
        followObservers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil,
                                                  queue: nil) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice else { return }
            self?.deviceDisconnected(device.uniqueID)
        })
        followObservers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil,
                                                  queue: nil) { [weak self] _ in
            self?.scheduleRebuild(force: false)
        })
    }

    private func deviceDisconnected(_ uid: String) {
        sessionQueue.async { [self] in
            guard uid == deviceID else { return }
            scheduleRebuild(force: true)
        }
    }

    /// Session queue.
    private func unfollow() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   sessionQueue, block)
        }
        listeners = []
        followObservers.forEach(NotificationCenter.default.removeObserver)
        followObservers = []
    }

    /// Session queue. A session that fails or is interrupted is built again.
    private func observe(_ session: AVCaptureSession) {
        let center = NotificationCenter.default
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            sessionObservers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.scheduleRebuild(force: true)
            })
        }
    }

    // MARK: - Silence

    /// Session queue: checks the silence rules every half second.
    private func armWatchdog() {
        lock.withLock { silence.rearm(at: ForkMeetingWriter.hostSeconds()) }
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if self.session?.isRunning != true {
                self.retryTicks += 1
                if self.retryTicks % 4 == 0 { self.rebuildIfNeeded(force: true) }
            }
            let now = ForkMeetingWriter.hostSeconds()
            switch self.lock.withLock({ self.silence.update(at: now) }) {
            case .began?: self.callbacks.silent()
            case .ended?: self.callbacks.soundBack()
            case nil: break
            }
        }
        timer.resume()
        watchdog = timer
    }

    // MARK: - Capture queue

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let session = lock.withLock({ acceptedSession }), session.outputs.contains(output),
              CMSampleBufferIsValid(sampleBuffer),
              let clock = session.synchronizationClock,
              let synchronized = RecorderSampleTiming.converted(sampleBuffer, from: clock,
                                                                to: CMClockGetHostTimeClock()) else { return }
        let peak = Self.peak(of: sampleBuffer)
        let announce = lock.withLock { () -> (() -> Void)? in
            silence.observe(peak: peak, at: ForkMeetingWriter.hostSeconds())
            defer { firstSampleAfterSwitch = nil }
            return firstSampleAfterSwitch
        }
        announce?()
        callbacks.samples(synchronized)
    }

    /// The loudest sample of a PCM buffer, in any of the formats a capture
    /// device delivers (float or integer). 0 for digital silence.
    private static func peak(of sample: CMSampleBuffer) -> Float {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              stream.mFormatID == kAudioFormatLinearPCM else { return 0 }
        let isFloat = stream.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = stream.mBitsPerChannel
        var peak: Float = 0
        _ = try? sample.withAudioBufferList(blockBufferMemoryAllocator: nil, flags: []) { list, _ in
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let bytes = Int(buffer.mDataByteSize)
                if isFloat, bits == 32 {
                    let values = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: bytes / 4)
                    for value in values { peak = max(peak, abs(value)) }
                } else if !isFloat, bits == 16 {
                    let values = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: bytes / 2)
                    for value in values { peak = max(peak, Float(abs(Int32(value))) / 32_768) }
                } else if !isFloat, bits == 32 {
                    let values = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: bytes / 4)
                    for value in values { peak = max(peak, Float(abs(Int64(value))) / 2_147_483_648) }
                } else {
                    // An unusual layout: any non-zero byte is sound.
                    let raw = UnsafeRawBufferPointer(start: data, count: bytes)
                    if raw.contains(where: { $0 != 0 }) { peak = max(peak, 1e-6) }
                }
            }
        }
        return peak
    }
}
