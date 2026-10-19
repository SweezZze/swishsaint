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
    /// display alone, and without picture (nothing to switch ⧉ to).
    var window: CGWindowID?
    var sound: ForkMeetingSoundSource
    /// The microphone's name, `nil` when none records.
    var microphone: String?
    /// `nil` without picture.
    var outputSize: ForkMeetingPixelSize?
    /// "hvc1" or "avc1"; `nil` without picture.
    var codec: String?
    /// The file's zero: the instant the writer's session began, before the
    /// stream came up. Every time `meeting.json` keeps counts from here.
    var startedAt: Date
    /// The app of the window filmed, or whose display is filmed, by name:
    /// what the start's notice and the pill say. `nil` without a window.
    var appName: String? = nil

    /// What the meeting track hears at the start (`sound`, and for the
    /// stream what the picture follows): what `meeting.json` must say.
    var heard: ForkMeetingSystemAudio

    // MARK: Fixes G1

    /// The app's sound asked for with no app to hear: what the start says.
    var trackSound: ForkMeetingTrackSound = .heard
}

/// A process tap, as the recorder uses it: the official
/// `RecorderSystemAudioTap`, or a stand-in for a harness that must not raise
/// the system's audio permission prompt.
protocol ForkMeetingAudioTap: AnyObject, Sendable {
    var onSample: ((CMSampleBuffer) -> Void)? { get set }
    var onReaderLost: (() -> Void)? { get set }
    var hearsOneApp: Bool { get }
    var pipelineStart: UInt64 { get }
    func start(synchronizingTo clock: CMClock) async -> Bool
    func stop() async
}

extension RecorderSystemAudioTap: ForkMeetingAudioTap {}

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
    /// What the picture follows changed: ⧉ took, or the window went and its
    /// display is filmed instead. Never sent for a switch that did not take.
    var onTargetChanged: ((ForkMeetingToken, ForkMeetingCaptureTarget) -> Void)?
    /// Another microphone took over, after `gap` seconds without it:
    /// `microphoneChanged(name:gap:)`.
    var onMicrophoneSwitch: ((ForkMeetingToken, String, TimeInterval) -> Void)?
    /// The microphone sends nothing, or only zeros: `microphoneSilent`.
    var onMicrophoneSilent: ((ForkMeetingToken) -> Void)?
    /// The microphone's silence is over: `microphoneSoundBack`.
    var onMicrophoneSound: ((ForkMeetingToken) -> Void)?
    /// The witness stayed silent while the Mac played: system audio
    /// recording is not allowed, and the meeting track went to the stream's
    /// sound, `permissionLost(.systemAudio)`.
    var onSystemAudioUnavailable: ((ForkMeetingToken) -> Void)?
    /// A tap heard sound: system audio recording is allowed (the page's
    /// warning may go). Also kept in `fork.meetings.systemAudioVerified`.
    var onSystemAudioAllowed: ((ForkMeetingToken) -> Void)?
    /// The meeting track heard more than said so far (the whole Mac after
    /// the app alone): its widest, for `meeting.json`. Never narrows, and
    /// sent even once a stop is asked: what the file holds must be said.
    var onSoundHeard: ((ForkMeetingToken, ForkMeetingSystemAudio) -> Void)?
    /// What the meeting track holds changed (`ForkMeetingTrackSound`): the
    /// app's sound has no app to hear any more, or again.
    var onTrackSound: ((ForkMeetingToken, ForkMeetingTrackSound) -> Void)?

    // MARK: State

    private let gate = RecorderStartGate()
    private let pauseClock = RecorderPauseClock()
    private let lock = NSLock()
    // Under `lock`.
    private var writer: ForkMeetingWriter?
    private var stream: ForkMeetingCaptureStream?
    private var tap: ForkMeetingAudioTap?
    /// A tap of the whole Mac but this app, only to learn whether system
    /// audio recording is allowed; never written. Gone once it settled it.
    private var witness: ForkMeetingAudioTap?
    /// What tells whether the permission is there: the witness, or the
    /// Mac's tap itself. Gone once it is known.
    private var judge: ForkMeetingAudioTap?
    private var sound: ForkMeetingSoundSource = .none
    /// The widest the meeting track heard so far.
    private var heard: ForkMeetingSystemAudio = .off
    /// The sound asked for, and what the track holds as last said.
    private var setting: ForkMeetingSystemAudio = .off
    private var trackSound: ForkMeetingTrackSound = .heard
    private var microphone: ForkMeetingMicrophone?
    private var arbiter = ForkMeetingSoundArbiter(hasTap: false, hasWitness: false)
    private var window: CGWindowID?
    /// What the stream films (or filmed last, while none runs).
    private var aim: ForkMeetingCaptureStream.Aim?
    /// Recorded without picture: no stream ever runs, so none stands in
    /// for a tap.
    private var soundOnly = false
    /// ⧉ during a sleep: the restart at the wake takes it.
    private var pendingAim: ForkMeetingCaptureStream.Aim?
    private var running = false
    private var restarting = false
    /// The stream was stopped for a sleep: only `restartStream` builds the
    /// next one.
    private var suspended = false
    private var stopResult: ForkMeetingWriterResult?
    private var stopWaiters: [(ForkMeetingWriterResult) -> Void] = []
    private var stopRequested = false
    /// What the tap hears (an app's pid, or `nil` for the whole Mac), for a
    /// new one when it loses its reader, and how many were tried.
    private var tapHears: pid_t?
    private var tapRepair = ForkMeetingTapRepair()

    /// Makes a tap of one app (a pid) or of the whole Mac but this app
    /// (`nil`); `nil` when the audio system refuses.
    typealias TapMaker = @Sendable (pid_t?) async -> ForkMeetingAudioTap?

    private let makeTap: TapMaker
    private let defaults: UserDefaults

    init(token: ForkMeetingToken, defaults: UserDefaults = .standard,
         makeTap: @escaping TapMaker = { await RecorderSystemAudioTap.make(hearing: $0) }) {
        self.token = token
        self.defaults = defaults
        self.makeTap = makeTap
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
    /// - `titles`: the master's two sound tracks are named with them, in the
    ///   person's language.
    /// - `meetingSound`: a detected meeting's app, whose sound is heard
    ///   whatever is filmed, and whether its call's sound is no app's
    ///   (FaceTime); `nil` hears the filmed window's app. With it and no
    ///   window, the display is filmed, never another app's window in front.
    func start(config: ForkMeetingCaptureConfig, folder: URL, meetingWindow: CGWindowID? = nil,
               meetingMicrophone: String? = nil, excludingWindows: [CGWindowID] = [],
               titles: ForkMeetingFinalizer.TrackTitles = .standard, meetingSound: MeetingSound? = nil,
               completion: @escaping (Result<ForkMeetingRecorderStart, ForkMeetingFailure>) -> Void) {
        let request = Request(config: config, folder: folder, window: meetingWindow,
                              microphone: meetingMicrophone, excluded: Set(excludingWindows), titles: titles,
                              meeting: meetingSound)
        let finish = MainOnce(completion)
        Task { [self] in
            let result = await launch(request)
            finish.call(result)
        }
        // Never a start that does not answer: the machine would wait in
        // "starting" for good. Its `stop` then cleans up what came up.
        DispatchQueue.main.asyncAfter(deadline: .now() + ForkMeetingCaptureSupport.startTimeout) {
            finish.call(.failure(.captureFailed))
        }
    }

    private struct Request {
        let config: ForkMeetingCaptureConfig
        let folder: URL
        let window: CGWindowID?
        let microphone: String?
        let excluded: Set<CGWindowID>
        let titles: ForkMeetingFinalizer.TrackTitles
        let meeting: MeetingSound?
    }

    // MARK: Apps

    /// A detected meeting's sound: its app's process, and whether its call
    /// plays in a system process instead (FaceTime's `avconferenced`), which
    /// only the whole Mac hears.
    struct MeetingSound: Equatable {
        var appPID: pid_t?
        var outsideApp: Bool
    }

    private func launch(_ request: Request) async -> Result<ForkMeetingRecorderStart, ForkMeetingFailure> {
        guard gate.begin() else { return .failure(.captureFailed) }
        defer { gate.finish() }
        let settings = request.config.settings
        // Without picture nothing is filmed: no stream, and no Screen
        // Recording to ask for.
        let soundOnly = !settings.target.filmsPicture

        // What to film: a detected meeting's window, else its display; a
        // start by hand, the window in front. Without picture, that window
        // only names the app whose sound is heard.
        let window = request.window ?? (request.meeting == nil ? Self.frontWindow(excluding: request.excluded) : nil)
        var aim: ForkMeetingCaptureStream.Aim?
        var target: ForkMeetingCaptureStream.Resolved?
        if !soundOnly {
            var wanted = Self.aim(for: settings.target, window: window)
            var resolved = await Self.resolve(wanted, excluding: request.excluded)
            if case .failure(.sourceGone) = resolved, case .window = wanted {
                // The window went in the meantime: its display, or the main one.
                wanted = .displayOf(nil)
                resolved = await Self.resolve(wanted, excluding: request.excluded)
            }
            switch resolved {
            case let .success(value): target = value
            case let .failure(stop):
                _ = gate.claimStartFailure()
                return .failure(ForkMeetingCaptureSupport.startFailure(stop))
            }
            aim = wanted
        }
        guard gate.isAuthorized else { return cancelled() }

        // The file.
        let outputSize = target.map { settings.quality.outputSize(source: $0.displayPixels) }
        let url = request.folder.appendingPathComponent(ForkMeetingFolder.masterName)
        // A master already there belongs to another recording: it is never
        // written over (each meeting has a folder of its own).
        guard (try? FileManager.default.createDirectory(at: request.folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: ForkMeetingStore.folderPermissions])) != nil,
              FileManager.default.isWritableFile(atPath: request.folder.path),
              !FileManager.default.fileExists(atPath: url.path) else {
            _ = gate.claimStartFailure()
            return .failure(.folderUnavailable)
        }
        guard let writer = await Self.prepareWriter(url: url, size: outputSize, quality: settings.quality,
                                                    clock: pauseClock, titles: request.titles), writer.start() else {
            _ = gate.claimStartFailure()
            return .failure(.writerFailed)
        }
        writer.onFailure = { [weak self] failure in self?.send { $0.onFailure?($0.token, failure) } }
        lock.withLock {
            self.writer = writer
            self.window = soundOnly ? nil : window
            self.aim = aim
            self.soundOnly = soundOnly
        }
        guard gate.isAuthorized else { return cancelled() }

        // The meeting's sound: the app's tap with a witness that tells a
        // silent app from a missing permission, or the Mac's tap, its own
        // judge. Without picture, a tap or nothing: no stream stands in.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var tapAvailable = false
        if #available(macOS 14.4, *) { tapAvailable = true }
        let appPID = request.meeting?.appPID ?? (soundOnly ? Self.ownerPID(of: window) : target?.ownerPID)
        let filmsWindow = target?.isWindow ?? false
        var sound = ForkMeetingSoundSource.choose(settings.systemAudio, appPID: appPID, ownPID: ownPID,
                                                  filmsWindow: filmsWindow, tapAvailable: tapAvailable)
        if soundOnly { sound = ForkMeetingAudioOnly.sound(sound) }
        var tap: ForkMeetingAudioTap?
        var witness: ForkMeetingAudioTap?
        var hears: pid_t?
        switch sound {
        case let .appTap(pid):
            tap = await makeTap(pid)
            hears = pid
            if tap != nil { witness = await makeTap(nil) }
        case .macTap:
            tap = await makeTap(nil)
        case .stream, .none:
            break
        }
        // Refused by the audio system: the stream's sound, as `meeting.json`
        // will say, unless it would be the whole Mac for the app's own.
        if tap == nil {
            sound = sound.refused(filmsWindow: filmsWindow)
            if soundOnly { sound = ForkMeetingAudioOnly.sound(sound) }
        }
        let macTap = sound == .macTap
        let appOnly = settings.systemAudio == .app && sound == .stream
        // A call no app plays (FaceTime): the Mac's tap writes it from the
        // start, and a window's stream, which lacks it, never stands in.
        let callOutsideApp = request.meeting?.outsideApp == true && settings.systemAudio == .all
        lock.withLock {
            self.tap = tap
            self.witness = witness
            self.sound = sound
            tapHears = hears
            setting = settings.systemAudio
            judge = macTap ? tap : witness
            // Without picture the Mac's tap writes from the start too: no
            // stream writes the track while it proves itself.
            arbiter = ForkMeetingSoundArbiter(hasTap: tap != nil, hasWitness: macTap || witness != nil,
                                              tapFirst: !macTap || callOutsideApp || soundOnly, appOnly: appOnly,
                                              macOnly: callOutsideApp)
        }
        tap?.onSample = { [weak self] sample in self?.tapSample(sample) }
        tap?.onReaderLost = { [weak self] in self?.tapGone() }
        witness?.onSample = { [weak self] sample in self?.witnessSample(sample) }
        witness?.onReaderLost = { [weak self] in self?.witnessGone() }

        // The picture, and the stream's sound; without picture, the file's
        // zero is now.
        let zero = ZeroBox()
        if let target, let aim {
            let stream = ForkMeetingCaptureStream(outputSize: outputSize ?? target.displayPixels,
                                                  capturesAudio: sound.streamListens,
                                                  excludedWindows: request.excluded,
                                                  callbacks: streamCallbacks())
            lock.withLock { self.stream = stream }
            let failure = await withCheckedContinuation { (continuation: CheckedContinuation<ForkMeetingCaptureSupport.StreamStop?, Never>) in
                stream.start(target, aim: aim, willStart: { time in
                    zero.set(time)
                    writer.beginSession(atHostTime: time)
                }) {
                    continuation.resume(returning: $0)
                }
            }
            if let failure {
                if gate.claimStartFailure() { writer.cancel() }
                await tap?.stop()
                await witness?.stop()
                return .failure(ForkMeetingCaptureSupport.startFailure(failure))
            }
        } else {
            let time = ForkMeetingWriter.hostSeconds()
            zero.set(time)
            writer.beginSession(atHostTime: time)
        }
        guard gate.isAuthorized else { return cancelled() }

        // The taps start before the microphone: the Mac's sound comes up
        // first, as in the official recorder. A tap without a reader is
        // one that lost it (`tapGone`).
        if let tap, await tap.start(synchronizingTo: CMClockGetHostTimeClock()) == false { tapGone() }
        if let witness, await witness.start(synchronizingTo: CMClockGetHostTimeClock()) == false {
            witnessGone()
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
        let codec = writer.codec.map { $0 == .hevc ? "hvc1" : "avc1" }
        let (heardNow, trackNow) = lock.withLock { () -> (ForkMeetingSystemAudio, ForkMeetingTrackSound) in
            heard = currentHeard()
            trackSound = currentTrackSound()
            return (heard, trackSound)
        }
        let startedAt = Date(timeIntervalSinceNow: min(0, (zero.value ?? ForkMeetingWriter.hostSeconds())
                                                          - ForkMeetingWriter.hostSeconds()))
        return .success(ForkMeetingRecorderStart(target: aim.map(Self.target(of:)) ?? .audioOnly,
                                                 window: soundOnly ? nil : window, sound: sound,
                                                 microphone: microphoneName, outputSize: outputSize, codec: codec,
                                                 startedAt: startedAt, appName: Self.appName(of: window),
                                                 heard: heardNow, trackSound: trackNow))
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
        if stoppingStream {
            lock.withLock {
                suspended = true
                return stream
            }?.suspend()
        }
    }

    func resume() {
        let now = ForkMeetingWriter.hostSeconds()
        guard lock.withLock({ running }) else { return }
        pauseClock.resume(at: now)
    }

    /// A new stream on the same writer, aimed where the current one was (a
    /// window, or the display that holds it now), or where ⧉ asked during a
    /// sleep. A window that went gives way to its display. Tried again for a
    /// few seconds while the displays come back; `onFailure(.streamStopped)`
    /// if it never runs.
    func restartStream() {
        restart(to: nil)
    }

    private func restart(to requested: ForkMeetingCaptureStream.Aim?) {
        let job = lock.withLock { () -> (ForkMeetingCaptureStream, ForkMeetingCaptureStream.Aim)? in
            guard running, !restarting, let stream, let aim else { return nil }
            restarting = true
            suspended = false
            defer { pendingAim = nil }
            return (stream, Self.refreshed(requested ?? pendingAim ?? aim, window: window))
        }
        guard let (stream, next) = job else { return }
        stream.restart(next) { [weak self] stop, used in
            guard let self else { return }
            self.lock.withLock { self.restarting = false }
            guard let stop else { return self.adopt(used) }
            guard stop != .ignored else { return }
            let failure = ForkMeetingCaptureSupport.runningFailure(stop) ?? .streamStopped
            self.send { $0.onFailure?($0.token, failure) }
        }
    }

    /// Films the window, or the display that holds it now (again: a display
    /// unplugged). Without a window to film, or once it went, the display.
    /// The output keeps its size; if the running stream refuses the change,
    /// a new one is built, and if none runs (the filmed app quit) one is
    /// started. What is filmed afterwards is said by `onTargetChanged`, only
    /// when it changed.
    func switchTarget(_ target: ForkMeetingCaptureTarget) {
        let job = lock.withLock { () -> (ForkMeetingCaptureStream, ForkMeetingCaptureStream.Aim, Bool)? in
            guard running, let stream else { return nil }
            let wanted = Self.aim(for: target, window: window)
            if suspended { pendingAim = wanted }
            return (stream, wanted, suspended)
        }
        guard let (stream, wanted, asleep) = job, !asleep else { return }
        guard stream.isRunning else { return restart(to: wanted) }
        stream.switchTo(wanted) { [weak self] used in
            guard let self else { return }
            if let used { self.adopt(used) } else { self.restart(to: wanted) }
        }
    }

    /// Any thread: the stream films `used` now; said when what the picture
    /// follows changed.
    private func adopt(_ used: ForkMeetingCaptureStream.Aim) {
        let changed = lock.withLock { () -> Bool in
            defer { aim = used }
            return aim.map(Self.target(of:)) != Self.target(of: used)
        }
        let target = Self.target(of: used)
        if changed {
            send { $0.onTargetChanged?($0.token, target) }
            noteHeard()
            noteTrackSound()
        }
    }

    /// Under `lock`: the picture follows a window.
    private var filmsWindow: Bool {
        if case .window = aim { return true }
        return false
    }

    /// Under `lock`: what the meeting track hears now.
    private func currentHeard() -> ForkMeetingSystemAudio {
        guard sound != .none else { return .off }
        if arbiter.writesTap { return sound.heard(filmsWindow: filmsWindow) }
        guard !soundOnly, arbiter.streamWrites(filmsWindow: filmsWindow) else { return .off }
        return ForkMeetingSoundSource.stream.heard(filmsWindow: filmsWindow)
    }

    /// Under `lock`: what the meeting track holds now, as the pill says it.
    private func currentTrackSound() -> ForkMeetingTrackSound {
        ForkMeetingTrackSound.of(setting: setting, sound: sound, arbiter: arbiter, filmsWindow: filmsWindow,
                                 hasStream: !soundOnly)
    }

    /// Any thread: says it when what the track holds changed.
    private func noteTrackSound() {
        let changed = lock.withLock { () -> ForkMeetingTrackSound? in
            guard running else { return nil }
            let now = currentTrackSound()
            guard now != trackSound else { return nil }
            trackSound = now
            return now
        }
        if let changed { send { $0.onTrackSound?($0.token, changed) } }
    }

    /// Any thread: says it when the track heard more than before.
    private func noteHeard() {
        let widened = lock.withLock { () -> ForkMeetingSystemAudio? in
            guard running else { return nil }
            let next = heard.widened(by: currentHeard())
            guard next != heard else { return nil }
            heard = next
            return next
        }
        if let widened { send(evenAfterStop: true) { $0.onSoundHeard?($0.token, widened) } }
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

    /// Answers `.failed(.writerFailed)` if the file did not close within
    /// `stopTimeout`: the machine never waits in "stopping" for good.
    func stop(completion: @escaping (ForkMeetingWriterResult) -> Void) {
        let answer = MainOnce(completion)
        stop(delivering: { answer.call($0) })
        DispatchQueue.main.asyncAfter(deadline: .now() + ForkMeetingCaptureSupport.stopTimeout) {
            answer.call(.failed(.writerFailed))
        }
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
        let (wasRunning, writer, stream, microphone, tap, witness) = lock.withLock {
            () -> (Bool, ForkMeetingWriter?, ForkMeetingCaptureStream?, ForkMeetingMicrophone?, ForkMeetingAudioTap?,
                   ForkMeetingAudioTap?) in
            defer {
                running = false
                self.witness = nil
            }
            return (running, self.writer, self.stream, self.microphone, self.tap, self.witness)
        }
        // Sources first, each drained.
        if let stream { await withCheckedContinuation { continuation in stream.stop { continuation.resume() } } }
        if let microphone { await withCheckedContinuation { continuation in microphone.stop { continuation.resume() } } }
        await tap?.stop()
        await witness?.stop()
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
            },
            soundBack: { [weak self] in
                self?.send { $0.onMicrophoneSound?($0.token) }
            })
    }

    /// Capture queue. The stream's sound is written only when the meeting
    /// track takes it, and never a display's whole Mac in place of the app's
    /// sound; while the witness listens, it is weighed against what the
    /// witness heard.
    private func streamSound(_ sample: CMSampleBuffer) {
        let (writer, judge, needsWitness) = lock.withLock { (self.writer, self.judge, arbiter.needsWitness) }
        var missing = false
        if needsWitness, let judge, RecorderAudioProbe.containsSound(sample) {
            // Only sound from after the witness's pipeline settled counts:
            // the official rule for an app's tap, hence `hearsOneApp`.
            let counts = RecorderSupport.streamSoundCountsAgainstTap(
                at: CMSampleBufferGetPresentationTimeStamp(sample), hearsOneApp: true,
                pipelineStart: judge.pipelineStart)
            let seconds = Double(CMSampleBufferGetNumSamples(sample)) / ForkMeetingWriter.sampleRate
            missing = lock.withLock { arbiter.streamBuffer(heard: true, counts: counts, seconds: seconds) }
        }
        if missing { settled(allowed: false) }
        if lock.withLock({ arbiter.streamWrites(filmsWindow: filmsWindow) }) { writer?.appendAudio(sample, to: .meeting) }
    }

    /// The app's tap's audio thread: always written while it has the track,
    /// silence included.
    private func tapSample(_ sample: CMSampleBuffer) {
        let heard = RecorderAudioProbe.containsSound(sample)
        let (writer, writes, proved) = lock.withLock { () -> (ForkMeetingWriter?, Bool, Bool) in
            if heard { tapRepair.heard() }
            let proved = arbiter.tapBuffer(heard: heard)
            return (self.writer, arbiter.writesTap, proved)
        }
        if proved { settled(allowed: true) }
        if writes { writer?.appendAudio(sample, to: .meeting) }
    }

    /// The witness's audio thread: listened to, never written.
    private func witnessSample(_ sample: CMSampleBuffer) {
        let heard = RecorderAudioProbe.containsSound(sample)
        if lock.withLock({ arbiter.witnessBuffer(heard: heard) }) { settled(allowed: true) }
    }

    /// The tap's own queue: it lost its reader for good (a device change it
    /// could not follow). A new tap of the same sound is tried first, a
    /// second later, twice at most (S3); the track keeps its silence
    /// meanwhile. Only then the track gives up on it (`tapLost`).
    private func tapGone() {
        let attempt = lock.withLock { () -> (ForkMeetingAudioTap, pid_t?)? in
            guard !stopRequested, let tap, tapRepair.tryAgain() else { return nil }
            return (tap, tapHears)
        }
        guard let (old, hears) = attempt else { return tapLost() }
        Task { [self] in
            await old.stop()
            try? await Task.sleep(nanoseconds: UInt64(ForkMeetingTapRepair.delay * 1_000_000_000))
            guard !lock.withLock({ stopRequested }) else { return }
            guard let fresh = await makeTap(hears) else { return tapGone() }
            fresh.onSample = { [weak self] sample in self?.tapSample(sample) }
            fresh.onReaderLost = { [weak self] in self?.tapGone() }
            // Let go meanwhile (stopped, or a missing permission): not put back.
            let installed = lock.withLock { () -> Bool in
                guard !stopRequested, tap === old else { return false }
                tap = fresh
                if judge === old { judge = fresh }
                return true
            }
            guard installed else { return await fresh.stop() }
            if await fresh.start(synchronizingTo: CMClockGetHostTimeClock()) == false { tapGone() }
        }
    }

    /// No new tap could take over: the stream takes the track if it may
    /// (the whole Mac asked for, or a window filmed, never a window's for a
    /// call no app plays); otherwise silence, said once.
    private func tapLost() {
        let (changed, witness) = lock.withLock { () -> (Bool, ForkMeetingAudioTap?) in
            let changed = arbiter.tapReaderLost()
            judge = nil
            defer { self.witness = nil }
            return (changed, self.witness)
        }
        if let witness { Task { await witness.stop() } }
        guard changed else { return }
        noteHeard()
        noteTrackSound()
    }

    /// The witness has no reader: nothing can be judged any more.
    private func witnessGone() {
        lock.withLock { arbiter.witnessUnavailable() }
        dismissWitness()
    }

    /// Any thread, once: the permission is known. Kept on this Mac, said to
    /// the service, and the witness goes. Missing, the meeting track now
    /// takes the stream's sound (the filmed app's for a window, the whole
    /// Mac's for a display), and the tap is let go.
    private func settled(allowed: Bool) {
        defaults.set(allowed, forKey: ForkDefaultsKey.meetingsSystemAudioVerified)
        lock.withLock { judge = nil }
        dismissWitness()
        noteHeard()
        noteTrackSound()
        if allowed {
            send { $0.onSystemAudioAllowed?($0.token) }
        } else {
            let tap = lock.withLock { () -> ForkMeetingAudioTap? in
                defer { self.tap = nil }
                return self.tap
            }
            if let tap { Task { await tap.stop() } }
            send { $0.onSystemAudioUnavailable?($0.token) }
        }
    }

    private func dismissWitness() {
        let witness = lock.withLock { () -> ForkMeetingAudioTap? in
            defer { self.witness = nil }
            return self.witness
        }
        if let witness { Task { await witness.stop() } }
    }

    /// Capture queue: the stream ended on its own.
    private func streamStopped(_ stop: ForkMeetingCaptureSupport.StreamStop) {
        let aim = lock.withLock { running ? self.aim : nil }
        guard let aim else { return }
        if stop == .sourceGone {
            switch aim {
            case .window:
                // Its app quit: the last frame stays, the sound goes on. Said
                // as such, never as a window minimized.
                send { $0.onSourceGone?($0.token) }
            case .displayOf:
                // The display went: the one holding the window now.
                restartStream()
            }
            return
        }
        guard let failure = ForkMeetingCaptureSupport.runningFailure(stop) else { return }
        send(after: ForkMeetingCaptureSupport.reportDelay(stop)) { $0.onFailure?($0.token, failure) }
    }

    /// On the main thread, unless a stop was asked meanwhile (and the event
    /// is not one the file needs said, `evenAfterStop`).
    private func send(after delay: TimeInterval = 0, evenAfterStop: Bool = false,
                      _ event: @escaping (ForkMeetingRecorder) -> Void) {
        let deliver = { [self] in
            guard evenAfterStop || !lock.withLock({ stopRequested }) else { return }
            event(self)
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: deliver)
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    // MARK: - Helpers

    /// The window when one is to be filmed and known, else its display.
    private static func aim(for target: ForkMeetingCaptureTarget, window: CGWindowID?) -> ForkMeetingCaptureStream.Aim {
        if target == .window, let window { return .window(window) }
        return .displayOf(window)
    }

    private static func target(of aim: ForkMeetingCaptureStream.Aim) -> ForkMeetingCaptureTarget {
        if case .window = aim { return .window }
        return .display
    }

    /// A display aim follows the window to the display it is on now.
    private static func refreshed(_ aim: ForkMeetingCaptureStream.Aim, window: CGWindowID?) -> ForkMeetingCaptureStream.Aim {
        if case .displayOf = aim { return .displayOf(window) }
        return aim
    }

    private static func resolve(_ aim: ForkMeetingCaptureStream.Aim, excluding: Set<CGWindowID>) async
        -> Result<ForkMeetingCaptureStream.Resolved, ForkMeetingCaptureSupport.StreamStop> {
        await withCheckedContinuation { continuation in
            ForkMeetingCaptureStream.resolve(aim, excluding: excluding) { continuation.resume(returning: $0) }
        }
    }

    private static func prepareWriter(url: URL, size: ForkMeetingPixelSize?, quality: ForkMeetingQuality,
                                      clock: RecorderPauseClock,
                                      titles: ForkMeetingFinalizer.TrackTitles) async -> ForkMeetingWriter? {
        let queue = DispatchQueue(label: "fork.meetings.recorder.prepared")
        return await withCheckedContinuation { continuation in
            ForkMeetingWriter.prepare(url: url, outputSize: size, quality: quality, pauseClock: clock, titles: titles,
                                      completionQueue: queue) { continuation.resume(returning: $0) }
        }
    }

    /// The app that owns `window`: whose sound a meeting without picture
    /// hears, when no detected meeting names it.
    static func ownerPID(of window: CGWindowID?) -> pid_t? {
        guard let window,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first
        else { return nil }
        return info[kCGWindowOwnerPID as String] as? pid_t
    }

    /// The name of the app that owns `window`, as the Dock shows it.
    static func appName(of window: CGWindowID?) -> String? {
        guard let window,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? info[kCGWindowOwnerName as String] as? String
    }

    /// The frontmost ordinary window of another regular app, front to back
    /// as the window server orders them.
    static func frontWindow(excluding excluded: Set<CGWindowID>) -> CGWindowID? {
        ForkMeetingCaptureSupport.frontWindow(onScreenWindows(), ownPID: ProcessInfo.processInfo.processIdentifier,
                                              excluded: excluded)?.id
    }

    /// The windows on screen, front to back as the window server orders
    /// them.
    static func onScreenWindows() -> [ForkMeetingWindowCandidate] {
        windows([.optionOnScreenOnly, .excludeDesktopElements])
    }

    /// Every window, as the window scanner lists them (`.optionAll`): those
    /// on screen first, front to back, then the minimized ones and those on
    /// another Space, which a detected app's meeting is filmed in too (the
    /// stream follows a window wherever it is).
    static func meetingWindows() -> [ForkMeetingWindowCandidate] {
        windows([.optionAll, .excludeDesktopElements])
    }

    private static func windows(_ options: CGWindowListOption) -> [ForkMeetingWindowCandidate] {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var regular: [pid_t: Bool] = [:]
        return list.compactMap { info -> ForkMeetingWindowCandidate? in
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return nil }
            if regular[pid] == nil {
                regular[pid] = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
            }
            let title = info[kCGWindowName as String] as? String
            return ForkMeetingWindowCandidate(id: id, pid: pid, layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                              alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                                              bounds: bounds, ownerIsRegularApp: regular[pid] ?? false,
                                              onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                                              titled: title.map { !$0.isEmpty } ?? false)
        }
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

    /// The writer's zero, in host seconds, set from the stream's queue.
    private final class ZeroBox: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Double?

        func set(_ value: Double) { lock.withLock { time = value } }
        var value: Double? { lock.withLock { time } }
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
