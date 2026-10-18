// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation
import CoreMedia

/// What a recording that started is made of, for `meeting.json` and the pill.
struct ForkMeetingRecorderStart: Equatable {
    /// What the picture follows, which may differ from the setting: a
    /// "window" recording with no window to film films the main display.
    var target: ForkMeetingCaptureTarget
    /// The window filmed, or whose display is filmed; `nil` for the main
    /// display alone.
    var window: CGWindowID?
    var sound: ForkMeetingSoundSource
    /// The microphone's name, `nil` when none records.
    var microphone: String?
    var outputSize: ForkMeetingPixelSize
    /// "hvc1" or "avc1".
    var codec: String
}

/// One meeting's capture engine: the screen stream, the meeting app's sound
/// (its tap, or the stream's), the microphone, and the writer they all feed.
/// The service drives it; it decides nothing about the meeting itself.
///
/// **One recorder per session**, made with the session's token. Every event
/// it sends carries that token, so an answer that arrives after the session
/// ended is dropped by the machine.
///
/// **Threads.** Every method may be called from the main thread and returns
/// at once: nothing here blocks it. The work happens on the recorder's
/// queues (the writer's serial queue, the stream's capture queue, the
/// microphone's session queue, the tap's own). Every completion and every
/// event is delivered on the main thread.
///
/// **Calls.**
/// - `start` once. Its completion runs exactly once: `.success` once the
///   stream runs and the writer took its zero, or a `ForkMeetingFailure`.
/// - `pause` / `resume`, `switchTarget`, `restartStream` at any time between
///   them; before `start` succeeded or after `stop` they do nothing.
/// - `stop` at any time, even during `start` (which then gives up and
///   leaves no file behind). Its completion runs exactly once, after the
///   file is closed: `.finished` with the seconds recorded, or `.failed`.
///   A second `stop` gets the same answer.
/// - `stopBlocking` instead, when the app quits: the same stop, waited for
///   on the calling thread, within a bound.
///
/// **Stopping** follows the official order: the stream, the microphone and
/// the tap stop and drain first, then the writer's queue, then the file is
/// finished, so no sample can arrive after it.
final class ForkMeetingRecorder: @unchecked Sendable {
    let token: ForkMeetingToken

    // MARK: Events (main thread; set them before `start`)

    /// The recording cannot go on: the stream was stopped by macOS or the
    /// person (`.streamStopped`), Screen Recording was taken back
    /// (`.screenRecordingRevoked`), the file failed (`.writerFailed`,
    /// `.diskFull`). The file written so far is kept; the service sends
    /// `captureFailed(token, failure)`.
    var onFailure: ((ForkMeetingToken, ForkMeetingFailure) -> Void)?
    /// The filmed window's app quit (window mode): the picture freezes on
    /// its last frame, the sound goes on. Whether the meeting ended is the
    /// service's call.
    var onSourceGone: ((ForkMeetingToken) -> Void)?
    /// The picture froze (true: window minimized or hidden, display asleep)
    /// or came back (false). The sound goes on meanwhile.
    var onPictureFrozen: ((ForkMeetingToken, Bool) -> Void)?
    /// Another microphone took over, after `gap` seconds without it:
    /// `microphoneChanged(name:gap:)`.
    var onMicrophoneSwitch: ((ForkMeetingToken, String, TimeInterval) -> Void)?
    /// The microphone sends nothing, or only zeros: `microphoneSilent`.
    var onMicrophoneSilent: ((ForkMeetingToken) -> Void)?
    /// The app's tap stays silent while the Mac plays: the meeting track went
    /// back to the whole Mac's sound, `permissionLost(.systemAudio)`.
    var onSystemAudioUnavailable: ((ForkMeetingToken) -> Void)?

    // MARK: State

    private let gate = RecorderStartGate()
    private let pauseClock = RecorderPauseClock()
    private let lock = NSLock()
    // Under `lock`.
    private var writer: ForkMeetingWriter?
    private var stream: ForkMeetingCaptureStream?
    private var tap: RecorderSystemAudioTap?
    private var microphone: ForkMeetingMicrophone?
    private var arbiter = ForkMeetingSoundArbiter(hasTap: false, trusted: false)
    private var window: CGWindowID?
    private var aim: ForkMeetingCaptureStream.Aim?
    private var running = false
    private var restarting = false
    private var stopResult: ForkMeetingWriterResult?
    private var stopWaiters: [(ForkMeetingWriterResult) -> Void] = []
    private var stopRequested = false

    init(token: ForkMeetingToken) {
        self.token = token
    }

    // MARK: - Start

    /// Starts recording into `folder/.recording.mp4`.
    ///
    /// - `meetingWindow`: the window to film; `nil` (PR 1, a recording
    ///   started by hand) films the frontmost ordinary window of another app,
    ///   or the main display when there is none.
    /// - `meetingMicrophone`: the meeting app's input, for the "meeting"
    ///   microphone choice; `nil` uses the system's input.
    /// - `excludingWindows`: windows never chosen as the one to film. In
    ///   display mode every window of this app is left out anyway, those
    ///   opened later included.
    func start(config: ForkMeetingCaptureConfig, folder: URL, meetingWindow: CGWindowID? = nil,
               meetingMicrophone: String? = nil, excludingWindows: [CGWindowID] = [],
               completion: @escaping (Result<ForkMeetingRecorderStart, ForkMeetingFailure>) -> Void) {
        let request = Request(config: config, folder: folder, window: meetingWindow,
                              microphone: meetingMicrophone, excluded: Set(excludingWindows))
        let finish = MainOnce(completion)
        Task { [self] in
            let result = await launch(request)
            finish.call(result)
        }
    }

    private struct Request {
        let config: ForkMeetingCaptureConfig
        let folder: URL
        let window: CGWindowID?
        let microphone: String?
        let excluded: Set<CGWindowID>
    }

    private func launch(_ request: Request) async -> Result<ForkMeetingRecorderStart, ForkMeetingFailure> {
        guard gate.begin() else { return .failure(.captureFailed) }
        defer { gate.finish() }
        let settings = request.config.settings

        // What to film.
        let window = request.window ?? Self.frontWindow(excluding: request.excluded)
        var aim = Self.aim(for: settings.target, window: window)
        var resolved = await Self.resolve(aim)
        if case .failure(.sourceGone) = resolved, case .window = aim {
            // The window went in the meantime: its display, or the main one.
            aim = .displayOf(nil)
            resolved = await Self.resolve(aim)
        }
        let target: ForkMeetingCaptureStream.Resolved
        switch resolved {
        case let .success(value): target = value
        case let .failure(stop):
            _ = gate.claimStartFailure()
            return .failure(ForkMeetingCaptureSupport.startFailure(stop))
        }
        guard gate.isAuthorized else { return cancelled() }

        // The file.
        let outputSize = settings.quality.outputSize(source: target.displayPixels)
        let url = request.folder.appendingPathComponent(ForkMeetingFolder.masterName)
        // A master already there belongs to another recording: it is never
        // written over (each meeting has a folder of its own).
        guard (try? FileManager.default.createDirectory(at: request.folder, withIntermediateDirectories: true)) != nil,
              FileManager.default.isWritableFile(atPath: request.folder.path),
              !FileManager.default.fileExists(atPath: url.path) else {
            _ = gate.claimStartFailure()
            return .failure(.folderUnavailable)
        }
        guard let writer = await Self.prepareWriter(url: url, size: outputSize, quality: settings.quality,
                                                    clock: pauseClock), writer.start() else {
            _ = gate.claimStartFailure()
            return .failure(.writerFailed)
        }
        writer.onFailure = { [weak self] failure in self?.send { $0.onFailure?($0.token, failure) } }
        lock.withLock {
            self.writer = writer
            self.window = window
            self.aim = aim
        }
        guard gate.isAuthorized else { return cancelled() }

        // The meeting's sound.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var tapAvailable = false
        if #available(macOS 14.4, *) { tapAvailable = true }
        let sound = ForkMeetingSoundSource.choose(settings.systemAudio, appPID: target.ownerPID, ownPID: ownPID,
                                                  tapAvailable: tapAvailable)
        var tap: RecorderSystemAudioTap?
        if case let .appTap(pid) = sound { tap = await RecorderSystemAudioTap.make(hearing: pid) }
        let trusted = UserDefaults.standard.bool(forKey: DefaultsKey.recorderSystemAudioTapVerified)
        lock.withLock {
            self.tap = tap
            arbiter = ForkMeetingSoundArbiter(hasTap: tap != nil, trusted: trusted)
        }
        tap?.onSample = { [weak self] sample in self?.tapSample(sample) }
        tap?.onReaderLost = { [weak self] in self?.lock.withLock { self?.arbiter.tapReaderLost() } }

        // The picture, and the stream's sound.
        let stream = ForkMeetingCaptureStream(outputSize: outputSize, capturesAudio: sound.streamListens,
                                              callbacks: streamCallbacks())
        lock.withLock { self.stream = stream }
        let failure = await withCheckedContinuation { (continuation: CheckedContinuation<ForkMeetingCaptureSupport.StreamStop?, Never>) in
            stream.start(target, aim: aim, willStart: { time in writer.beginSession(atHostTime: time) }) {
                continuation.resume(returning: $0)
            }
        }
        if let failure {
            if gate.claimStartFailure() { writer.cancel() }
            await tap?.stop()
            return .failure(ForkMeetingCaptureSupport.startFailure(failure))
        }
        guard gate.isAuthorized else { return cancelled() }

        // The tap starts before the microphone: the Mac's sound comes up
        // first, as in the official recorder.
        if let tap, await tap.start(synchronizingTo: CMClockGetHostTimeClock()) == false {
            lock.withLock { arbiter.tapReaderLost() }
        }
        guard gate.isAuthorized else { return cancelled() }

        var microphoneName: String?
        if request.config.recordsMicrophone {
            let microphone = ForkMeetingMicrophone(choice: ForkMeetingMicrophoneChoice(stored: settings.microphone),
                                                   meetingDevice: request.microphone,
                                                   callbacks: microphoneCallbacks(writer: writer))
            lock.withLock { self.microphone = microphone }
            if await withCheckedContinuation({ continuation in
                microphone.start { continuation.resume(returning: $0) }
            }) {
                microphoneName = microphone.deviceName
            }
        }

        guard gate.isAuthorized else { return cancelled() }
        lock.withLock { running = true }
        let codec = writer.codec == .hevc ? "hvc1" : "avc1"
        let filmed: ForkMeetingCaptureTarget
        if case .window = aim { filmed = .window } else { filmed = .display }
        return .success(ForkMeetingRecorderStart(target: filmed, window: window, sound: sound,
                                                 microphone: microphoneName, outputSize: outputSize, codec: codec))
    }

    /// `stop` came during the start: it owns the teardown, and the start's
    /// answer means nothing to a machine that already moved on.
    private func cancelled() -> Result<ForkMeetingRecorderStart, ForkMeetingFailure> {
        .failure(.captureFailed)
    }

    // MARK: - Controls

    /// Stops writing; the sources keep running and their samples are
    /// dropped, so the resume is instant. For a sleep, `stoppingStream` also
    /// ends the stream; `restartStream` builds the next one.
    func pause(stoppingStream: Bool = false) {
        let now = ForkMeetingWriter.hostSeconds()
        guard lock.withLock({ running }) else { return }
        pauseClock.pause(at: now)
        if stoppingStream { lock.withLock { stream }?.suspend() }
    }

    func resume() {
        let now = ForkMeetingWriter.hostSeconds()
        guard lock.withLock({ running }) else { return }
        pauseClock.resume(at: now)
    }

    /// A new stream on the same writer, aimed where the current one was (a
    /// window, or the display that holds it now). Tried again for a few
    /// seconds while the displays come back; `onFailure(.streamStopped)` if
    /// it never runs.
    func restartStream() {
        let job = lock.withLock { () -> (ForkMeetingCaptureStream, ForkMeetingCaptureStream.Aim)? in
            guard running, !restarting, let stream, let aim else { return nil }
            restarting = true
            return (stream, Self.refreshed(aim, window: window))
        }
        guard let (stream, aim) = job else { return }
        stream.restart(aim) { [weak self] stop in
            guard let self else { return }
            self.lock.withLock { self.restarting = false }
            guard let stop, stop != .ignored else { return }
            let failure = ForkMeetingCaptureSupport.runningFailure(stop) ?? .streamStopped
            self.send { $0.onFailure?($0.token, failure) }
        }
    }

    /// Films the window, or the display that holds it now (again: a display
    /// unplugged). Without a window to film, the display. The output keeps
    /// its size; if the running stream refuses the change, a new one is
    /// built.
    func switchTarget(_ target: ForkMeetingCaptureTarget) {
        let job = lock.withLock { () -> (ForkMeetingCaptureStream, ForkMeetingCaptureStream.Aim)? in
            guard running, let stream else { return nil }
            let next = Self.aim(for: target, window: window)
            aim = next
            return (stream, next)
        }
        guard let (stream, next) = job else { return }
        guard stream.isRunning else { return } // the next restart takes the new aim
        stream.switchTo(next) { [weak self] switched in
            if !switched { self?.restartStream() }
        }
    }

    /// The pill's meters. Any thread.
    var levels: ForkMeetingLevels {
        lock.withLock { writer }?.levels ?? .silent
    }

    /// Seconds recorded so far, pauses left out. Any thread.
    var recordedSeconds: TimeInterval {
        pauseClock.elapsed(at: ForkMeetingWriter.hostSeconds())
    }

    var isPictureFrozen: Bool {
        lock.withLock { stream }?.pictureIsFrozen ?? false
    }

    // MARK: - Stop

    func stop(completion: @escaping (ForkMeetingWriterResult) -> Void) {
        let answer = MainOnce(completion)
        stop(delivering: { answer.call($0) })
    }

    /// The same stop, for the app's last moments (`willTerminate`): waited
    /// for on the calling thread, the main one, up to `timeout`. Nothing it
    /// waits for needs that thread: the result is taken where the teardown
    /// ends, never on the main queue. `nil` when the file did not close in
    /// time; the fragments written so far stay for the next launch. A stop
    /// already under way is waited for, not started again.
    func stopBlocking(timeout: TimeInterval) -> ForkMeetingWriterResult? {
        let box = ResultBox()
        let closed = ForkMeetingBoundedWait.run(timeout: timeout) { done in
            stop(delivering: { result in
                box.set(result)
                done()
            })
        }
        return closed ? box.value : nil
    }

    /// `deliver` runs once, on whatever thread the teardown ends.
    private func stop(delivering deliver: @escaping (ForkMeetingWriterResult) -> Void) {
        let end = ForkMeetingWriter.hostSeconds()
        let (known, first) = lock.withLock { () -> (ForkMeetingWriterResult?, Bool) in
            if let stopResult { return (stopResult, false) }
            stopWaiters.append(deliver)
            defer { stopRequested = true }
            return (nil, !stopRequested)
        }
        if let known { return deliver(known) }
        guard first else { return }
        Task { [self] in
            let result = await tearDown(end: end)
            let waiters = lock.withLock { () -> [(ForkMeetingWriterResult) -> Void] in
                stopResult = result
                defer { stopWaiters = [] }
                return stopWaiters
            }
            waiters.forEach { $0(result) }
        }
    }

    private func tearDown(end: Double) async -> ForkMeetingWriterResult {
        let ownsFinalization = gate.cancelAndClaimStop()
        await gate.waitUntilFinished()
        let (wasRunning, writer, stream, microphone, tap) = lock.withLock {
            () -> (Bool, ForkMeetingWriter?, ForkMeetingCaptureStream?, ForkMeetingMicrophone?, RecorderSystemAudioTap?) in
            defer { running = false }
            return (running, self.writer, self.stream, self.microphone, self.tap)
        }
        // Sources first, each drained.
        if let stream { await withCheckedContinuation { continuation in stream.stop { continuation.resume() } } }
        if let microphone { await withCheckedContinuation { continuation in microphone.stop { continuation.resume() } } }
        await tap?.stop()
        guard ownsFinalization, let writer else {
            // The start failed and gave the writer up itself.
            return .failed(.captureFailed)
        }
        guard wasRunning else {
            // Stopped before the start finished: nothing was recorded, and
            // nothing stays on the disk.
            await withCheckedContinuation { continuation in writer.cancel { continuation.resume() } }
            return .failed(.captureFailed)
        }
        return await withCheckedContinuation { continuation in
            writer.finish(atHostTime: end) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Sources

    private func streamCallbacks() -> ForkMeetingCaptureStream.Callbacks {
        ForkMeetingCaptureStream.Callbacks(
            video: { [weak self] sample in
                self?.lock.withLock { self?.writer }?.appendVideo(sample)
            },
            audio: { [weak self] sample in self?.streamSound(sample) },
            frozen: { [weak self] frozen in
                self?.send { $0.onPictureFrozen?($0.token, frozen) }
            },
            stopped: { [weak self] stop in self?.streamStopped(stop) })
    }

    private func microphoneCallbacks(writer: ForkMeetingWriter) -> ForkMeetingMicrophone.Callbacks {
        ForkMeetingMicrophone.Callbacks(
            samples: { sample in writer.appendAudio(sample, to: .microphone) },
            switched: { [weak self] name, gap in
                self?.send { $0.onMicrophoneSwitch?($0.token, name, gap) }
            },
            silent: { [weak self] in
                self?.send { $0.onMicrophoneSilent?($0.token) }
            })
    }

    /// Capture queue. The stream's sound is written unless the app's tap
    /// writes the track, and always listened to, to catch a deaf tap.
    private func streamSound(_ sample: CMSampleBuffer) {
        let heard = RecorderAudioProbe.containsSound(sample)
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let seconds = Double(CMSampleBufferGetNumSamples(sample)) / ForkMeetingWriter.sampleRate
        let (writer, tap) = lock.withLock { (self.writer, self.tap) }
        let counts = RecorderSupport.streamSoundCountsAgainstTap(at: time, hearsOneApp: tap?.hearsOneApp == true,
                                                                 pipelineStart: tap?.pipelineStart ?? 0)
        let (deaf, writes) = lock.withLock { () -> (Bool, Bool) in
            let deaf = arbiter.streamBuffer(heard: heard, counts: counts, seconds: seconds)
            return (deaf, arbiter.writesStream)
        }
        if deaf { send { $0.onSystemAudioUnavailable?($0.token) } }
        if writes { writer?.appendAudio(sample, to: .meeting) }
    }

    /// The tap's audio thread.
    private func tapSample(_ sample: CMSampleBuffer) {
        let heard = RecorderAudioProbe.containsSound(sample)
        let (writer, writes) = lock.withLock { () -> (ForkMeetingWriter?, Bool) in
            arbiter.tapBuffer(heard: heard)
            return (self.writer, arbiter.writesTap)
        }
        if writes { writer?.appendAudio(sample, to: .meeting) }
    }

    /// Capture queue: the stream ended on its own.
    private func streamStopped(_ stop: ForkMeetingCaptureSupport.StreamStop) {
        let aim = lock.withLock { running ? self.aim : nil }
        guard let aim else { return }
        if stop == .sourceGone {
            switch aim {
            case .window:
                // Its app quit: the last frame stays, the sound goes on.
                send { $0.onPictureFrozen?($0.token, true); $0.onSourceGone?($0.token) }
            case .displayOf:
                // The display went: the one holding the window now.
                restartStream()
            }
            return
        }
        guard let failure = ForkMeetingCaptureSupport.runningFailure(stop) else { return }
        send { $0.onFailure?($0.token, failure) }
    }

    /// On the main thread, unless a stop was asked meanwhile.
    private func send(_ event: @escaping (ForkMeetingRecorder) -> Void) {
        DispatchQueue.main.async { [self] in
            guard !lock.withLock({ stopRequested }) else { return }
            event(self)
        }
    }

    // MARK: - Helpers

    /// The window when one is to be filmed and known, else its display.
    private static func aim(for target: ForkMeetingCaptureTarget, window: CGWindowID?) -> ForkMeetingCaptureStream.Aim {
        if target == .window, let window { return .window(window) }
        return .displayOf(window)
    }

    /// A display aim follows the window to the display it is on now.
    private static func refreshed(_ aim: ForkMeetingCaptureStream.Aim, window: CGWindowID?) -> ForkMeetingCaptureStream.Aim {
        if case .displayOf = aim { return .displayOf(window) }
        return aim
    }

    private static func resolve(_ aim: ForkMeetingCaptureStream.Aim) async
        -> Result<ForkMeetingCaptureStream.Resolved, ForkMeetingCaptureSupport.StreamStop> {
        await withCheckedContinuation { continuation in
            ForkMeetingCaptureStream.resolve(aim) { continuation.resume(returning: $0) }
        }
    }

    private static func prepareWriter(url: URL, size: ForkMeetingPixelSize, quality: ForkMeetingQuality,
                                      clock: RecorderPauseClock) async -> ForkMeetingWriter? {
        let queue = DispatchQueue(label: "fork.meetings.recorder.prepared")
        return await withCheckedContinuation { continuation in
            ForkMeetingWriter.prepare(url: url, outputSize: size, quality: quality, pauseClock: clock,
                                      completionQueue: queue) { continuation.resume(returning: $0) }
        }
    }

    /// The frontmost ordinary window of another regular app, front to back
    /// as the window server orders them.
    static func frontWindow(excluding excluded: Set<CGWindowID>) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        var regular: [pid_t: Bool] = [:]
        let candidates = list.compactMap { info -> ForkMeetingWindowCandidate? in
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return nil }
            if regular[pid] == nil {
                regular[pid] = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
            }
            return ForkMeetingWindowCandidate(id: id, pid: pid, layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                              alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                                              bounds: bounds, ownerIsRegularApp: regular[pid] ?? false)
        }
        return ForkMeetingCaptureSupport.frontWindow(candidates, ownPID: ProcessInfo.processInfo.processIdentifier,
                                                     excluded: excluded)?.id
    }

    /// A completion called once, on the main thread.
    private final class MainOnce<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var body: ((Value) -> Void)?

        init(_ body: @escaping (Value) -> Void) {
            self.body = body
        }

        func call(_ value: Value) {
            let body = lock.withLock { () -> ((Value) -> Void)? in
                defer { self.body = nil }
                return self.body
            }
            guard let body else { return }
            let box = ValueBox(value)
            if Thread.isMainThread { body(box.value) } else { DispatchQueue.main.async { body(box.value) } }
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: ForkMeetingWriterResult?

        func set(_ value: ForkMeetingWriterResult) { lock.withLock { result = value } }
        var value: ForkMeetingWriterResult? { lock.withLock { result } }
    }

    private struct ValueBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
}
