// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// A window as the window list describes it: enough to choose the one a
/// meeting recording films when nothing names it.
struct ForkMeetingWindowCandidate: Equatable {
    var id: UInt32
    var pid: Int32
    /// 0 for ordinary windows; menus, the Dock and overlays sit above.
    var layer: Int
    var alpha: Double
    /// In points, top-left origin, as the window list gives it.
    var bounds: CGRect
    var ownerIsRegularApp: Bool
    /// On screen now; else minimized, hidden, on another Space, or never
    /// shown (an app's spare windows).
    var onScreen = true
    /// It has a title (Screen Recording allowed): one never shown has none.
    var titled = true
}

/// A display and its frame, in the same space as `ForkMeetingWindowCandidate.bounds`.
struct ForkMeetingDisplayFrame: Equatable {
    var id: UInt32
    var frame: CGRect
}

/// The decisions of the capture engine that need no stream, no writer and no
/// device, so they can be tested on their own.
enum ForkMeetingCaptureSupport {
    // MARK: - What is filmed

    /// Smaller than this, a window is a palette, a tooltip or a badge, never
    /// a meeting.
    static let minimumWindowSide: CGFloat = 160

    /// The window a recording started by hand films: the frontmost ordinary
    /// window of another app. Front to back, the order the window list
    /// gives. This app's own windows never count (the pill, the settings),
    /// nor do the ones in `excluded`.
    static func frontWindow(_ candidates: [ForkMeetingWindowCandidate], ownPID: Int32,
                            excluded: Set<UInt32> = []) -> ForkMeetingWindowCandidate? {
        candidates.first { window in
            window.pid != ownPID && window.pid > 0 && window.layer == 0 && window.alpha > 0.05
                && window.ownerIsRegularApp && !excluded.contains(window.id)
                && window.bounds.width >= minimumWindowSide && window.bounds.height >= minimumWindowSide
        }
    }

    /// The display a window is on: the one holding most of it. A window on
    /// none of them (moved off screen, its display just unplugged) falls back
    /// to `main`, as does no window at all.
    static func display(holding window: CGRect?, displays: [ForkMeetingDisplayFrame], main: UInt32) -> UInt32 {
        guard let window, !window.isEmpty else { return main }
        var best: (id: UInt32, area: CGFloat)?
        for display in displays {
            let shared = display.frame.intersection(window)
            guard !shared.isNull, !shared.isEmpty else { continue }
            let area = shared.width * shared.height
            if area > (best?.area ?? 0) { best = (display.id, area) }
        }
        return best?.id ?? main
    }

    // MARK: - Where the picture goes

    /// Where a picture `aspect` wide for one high goes in an output of
    /// `output` pixels: as large as it fits, centred, on even pixels. A window
    /// in a fixed output is otherwise drawn in its top-left corner (measured).
    static func centeredRect(aspect: Double, in output: ForkMeetingPixelSize) -> CGRect {
        let width = Double(max(2, output.width))
        let height = Double(max(2, output.height))
        guard aspect.isFinite, aspect > 0 else { return CGRect(x: 0, y: 0, width: width, height: height) }
        let fitted: (width: Double, height: Double) = aspect >= width / height
            ? (width, width / aspect)
            : (height * aspect, height)
        let w = even(fitted.width), h = even(fitted.height)
        return CGRect(x: even((width - w) / 2), y: even((height - h) / 2), width: w, height: h)
    }

    /// A change of the window's shape smaller than this keeps the picture
    /// where it is: each update costs the stream about 60 ms (measured).
    static let recenterTolerance = 0.02

    /// Whether the picture must be placed again: the window's shape changed
    /// by more than `recenterTolerance` since `applied`, or never was placed.
    static func needsRecentering(applied: Double?, observed: Double) -> Bool {
        guard observed.isFinite, observed > 0 else { return false }
        guard let applied, applied > 0 else { return true }
        return abs(observed / applied - 1) > recenterTolerance
    }

    private static func even(_ value: Double) -> Double {
        let whole = max(0, Int(value.rounded(.down)))
        return Double(whole - whole % 2)
    }

    // MARK: - Stream

    /// What a frame's status says about the picture. Raw values of
    /// `SCFrameStatus`, so this file needs no ScreenCaptureKit.
    enum FrameKind: Equatable {
        /// A new picture to write.
        case picture
        /// Nothing changed since the last one.
        case idle
        /// The source shows nothing any more: a window minimized, hidden or
        /// closed, a display gone blank or asleep. The writer keeps the last
        /// picture; the sound goes on.
        case frozen
    }

    static func frameKind(status: Int) -> FrameKind {
        switch status {
        case 0, 4: return .picture // complete, started
        case 2, 3, 5: return .frozen // blank, suspended, stopped
        default: return .idle
        }
    }

    /// Why a stream ended, from its error. Raw codes of `SCStreamError`, so
    /// that macOS 14 (which lacks some cases) reads them the same way.
    enum StreamStop: Error, Equatable {
        /// The person (the system's recording indicator) or macOS stopped
        /// it: the file is kept (-3817, -3821).
        case external
        /// What was filmed is gone: its app quit, or its display (-3815).
        case sourceGone
        /// Screen Recording was taken back (-3801).
        case permission
        /// Stopping a stream that already stopped: nothing to report (-3808).
        case ignored
        case failed
    }

    static let screenCaptureErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"

    static func streamStop(domain: String, code: Int) -> StreamStop {
        guard domain == screenCaptureErrorDomain else { return .failed }
        switch code {
        case -3817, -3821: return .external
        case -3815: return .sourceGone
        case -3801: return .permission
        case -3808: return .ignored
        default: return .failed
        }
    }

    /// The failure a stream that would not start leaves.
    static func startFailure(_ stop: StreamStop) -> ForkMeetingFailure {
        switch stop {
        case .permission: return .screenRecordingDenied
        case .external, .sourceGone, .ignored, .failed: return .captureFailed
        }
    }

    /// The failure a stream that stopped during a recording leaves, `nil`
    /// when the recording goes on (a window's app that quit freezes the
    /// picture; the service decides whether the meeting ended).
    static func runningFailure(_ stop: StreamStop) -> ForkMeetingFailure? {
        switch stop {
        case .external, .failed: return .streamStopped
        case .permission: return .screenRecordingRevoked
        case .sourceGone, .ignored: return nil
        }
    }

    /// A stream rebuilt after a sleep or a lost display may fail while the
    /// displays come back: it is tried again after each of these delays.
    static let restartDelays: [TimeInterval] = [0, 0.5, 1, 2, 4]

    /// A stream stopped "by the system" (-3821) may be the screen locking,
    /// whose notification can come after it: the stop is reported this much
    /// later, so the machine knows of the lock by then and waits for the
    /// unlock instead of ending the meeting.
    static let externalStopGrace: TimeInterval = 2

    /// How long a running stream's stop waits before it is reported.
    static func reportDelay(_ stop: StreamStop) -> TimeInterval {
        stop == .external ? externalStopGrace : 0
    }

    /// A start that has not answered by then fails (`captureFailed`): never
    /// a "starting" that lasts. Measured starts take 0.3 to 1.4 s.
    static let startTimeout: TimeInterval = 15
    /// A stop that has not closed the file by then answers `writerFailed`:
    /// the fragments written are the next launch's to recover. Measured
    /// stops take under 50 ms.
    static let stopTimeout: TimeInterval = 10

    /// What a stream about to be built does when its aim did not resolve.
    enum Unresolved: Equatable {
        /// The window is gone (its app quit, it closed): the display that
        /// held it is filmed instead, at once. A recording never ends
        /// because a window went.
        case filmDisplay
        /// The displays may be coming back (a wake): later, again.
        case retry
        /// Waiting will not change it.
        case giveUp
    }

    static func unresolved(_ stop: StreamStop, aimsAtWindow: Bool) -> Unresolved {
        switch stop {
        case .sourceGone: return aimsAtWindow ? .filmDisplay : .retry
        case .permission: return .giveUp
        case .external, .failed, .ignored: return .retry
        }
    }
}

/// Where the meeting track's sound comes from for a whole recording.
enum ForkMeetingSoundSource: Equatable {
    /// A process tap on the meeting app (and its helpers).
    case appTap(pid: Int32)
    /// A process tap on every app but this one: the whole Mac, whatever the
    /// picture follows.
    case macTap
    /// The screen stream's own sound. Measured: a window's stream carries
    /// only that window's app (`f1h sckaudio window`: nothing of another app
    /// playing), a display's every app but this one.
    case stream
    /// None: the meeting track stays, filled with silence, so every file has
    /// the same tracks in the same order.
    case none

    /// `tapAvailable` is false before macOS 14.4. The app's sound asked for
    /// is never the whole Mac in its place: without its tap, the stream only
    /// when it carries that app alone (a window of another app filmed);
    /// otherwise nothing (no window, a display filmed before 14.4, a window
    /// of this app), and the meeting track stays silent, as said at the start.
    static func choose(_ setting: ForkMeetingSystemAudio, appPID: Int32?, ownPID: Int32, filmsWindow: Bool,
                       tapAvailable: Bool) -> ForkMeetingSoundSource {
        switch setting {
        case .off: return .none
        case .all: return tapAvailable ? .macTap : .stream
        case .app:
            if tapAvailable, let appPID, appPID > 0, appPID != ownPID { return .appTap(pid: appPID) }
            return filmsWindow && appPID != ownPID ? .stream : .none
        }
    }

    /// What `self` becomes when the audio system refused its tap: the same
    /// rule, the Mac's tap giving way to the stream (the whole Mac too), the
    /// app's only to a stream that carries that app alone.
    func refused(filmsWindow: Bool) -> ForkMeetingSoundSource {
        switch self {
        case .appTap: return filmsWindow ? .stream : .none
        case .macTap: return .stream
        case .stream, .none: return self
        }
    }

    /// Whether the screen stream captures sound: to write it, or to check
    /// that a tap hears what it should.
    var streamListens: Bool { self != .none }

    /// What the meeting track hears from this source, the picture following
    /// a window (`filmsWindow`) or a display.
    func heard(filmsWindow: Bool) -> ForkMeetingSystemAudio {
        switch self {
        case .appTap: return .app
        case .macTap: return .all
        case .none: return .off
        case .stream: return filmsWindow ? .app : .all
        }
    }
}

extension ForkMeetingSystemAudio {
    /// What a track heard over time, said as its widest: a meeting that heard
    /// the whole Mac for a moment is a meeting that heard the whole Mac.
    func widened(by other: ForkMeetingSystemAudio) -> ForkMeetingSystemAudio {
        func rank(_ value: ForkMeetingSystemAudio) -> Int {
            switch value {
            case .off: return 0
            case .app: return 1
            case .all: return 2
            }
        }
        return rank(other) > rank(self) ? other : self
    }
}

/// Decides, buffer by buffer, whether the meeting track takes the app's tap
/// or the stream's sound (every app but this one).
///
/// **The app's tap always writes the track** when there is one: silence when
/// the app is silent, never the stream's sound "meanwhile" — another app
/// playing while the meeting is quiet is no business of the recording.
///
/// A tap without its permission delivers silence, never an error, and macOS
/// has no call that reads that permission. A **witness** settles it: a tap of
/// the whole Mac but this app, which hears exactly what the stream hears.
/// - the app's tap or the witness hears anything: the permission is there,
///   and the witness is no longer needed;
/// - the witness stays silent while the stream hears `proofSeconds` of sound
///   it should have heard: the permission is missing, the track goes to the
///   stream (the whole Mac) for the rest of the recording, said once;
/// - no witness could be made: nothing can be judged, the tap keeps the track.
///
/// A tap that loses its reader (a device change it could not follow) hears
/// nothing more for the rest of the recording: the Mac's gives the track to
/// the stream, the whole Mac too; the app's gives it to the stream only
/// while that carries the app alone (a window filmed), and leaves it silent
/// on a display, said once (`tapReaderLost`). The writer fills the silence.
///
/// **The whole Mac's tap** (`tapFirst` false) judges itself: the stream,
/// which hears the whole Mac or the filmed app, writes the track until the
/// tap heard something, then the tap takes it; deaf to 3 s the stream
/// heard, it never does. Nothing private is at stake there, and no sound is
/// lost while it is proved.
struct ForkMeetingSoundArbiter: Equatable {
    /// Sound heard by the stream, and not by the witness, before the
    /// permission is judged missing.
    static let proofSeconds: Double = 3

    enum Permission: Equatable {
        case unknown
        /// A tap heard something: system audio recording is allowed.
        case allowed
        /// The witness stayed deaf to what the stream heard.
        case missing
    }

    private(set) var writesTap: Bool
    private(set) var permission: Permission = .unknown
    private let hasTap: Bool
    private let tapFirst: Bool
    /// The tap lost its reader: it will not hear again this recording.
    private(set) var readerLost = false
    private var hasWitness: Bool
    private var unheard: Double = 0
    /// The stream stands for the app's sound: it may write the track only
    /// while it carries that app alone (a window filmed), never the whole
    /// Mac of a display.
    private(set) var streamHearsAppOnly: Bool
    /// The meeting's sound is no app's (FaceTime's calls play in a system
    /// process): only a display's stream, the whole Mac, may stand for it,
    /// never a window's, which carries that window's app alone.
    private(set) var streamHearsMacOnly: Bool

    /// `hasTap`: the tap exists. `hasWitness`: something judges it (a
    /// witness, or the tap itself). `tapFirst`: the tap writes the track
    /// before it is proved (the app's tap), or only after (the Mac's).
    /// `appOnly`: the app's sound was asked for and the stream stands for it.
    /// `macOnly`: a call whose sound no app carries (`streamHearsMacOnly`).
    init(hasTap: Bool, hasWitness: Bool, tapFirst: Bool = true, appOnly: Bool = false, macOnly: Bool = false) {
        self.hasTap = hasTap
        self.tapFirst = tapFirst
        self.hasWitness = hasTap && hasWitness
        writesTap = hasTap && tapFirst
        streamHearsAppOnly = appOnly && !macOnly
        streamHearsMacOnly = macOnly
    }

    /// The tap lost its reader. Nothing is judged any more; the stream
    /// takes the track, and for the app's tap only while it carries that
    /// app alone. A tap already let go for a missing permission changes
    /// nothing. True once, when it was the one writing the track.
    mutating func tapReaderLost() -> Bool {
        guard hasTap, !readerLost else { return false }
        readerLost = true
        hasWitness = false
        unheard = 0
        guard writesTap else { return false }
        writesTap = false
        if tapFirst, !streamHearsMacOnly { streamHearsAppOnly = true }
        return true
    }

    var writesStream: Bool { !writesTap }

    /// Whether the stream's sound goes in the track now, the picture
    /// following a window (`filmsWindow`) or a display.
    func streamWrites(filmsWindow: Bool) -> Bool {
        guard !writesTap else { return false }
        return filmsWindow ? !streamHearsMacOnly : !streamHearsAppOnly
    }

    /// Whether the witness still has something to settle; once false it
    /// can be stopped.
    var needsWitness: Bool { hasWitness && permission == .unknown }

    /// A buffer of the app's tap, `heard` when it held more than silence.
    /// True once, when it proves the permission.
    mutating func tapBuffer(heard: Bool) -> Bool {
        guard hasTap, heard else { return false }
        return allow()
    }

    /// A buffer of the witness. True once, when it proves the permission.
    mutating func witnessBuffer(heard: Bool) -> Bool {
        guard hasWitness, heard else { return false }
        return allow()
    }

    /// The witness could not be made, or has no reader: nothing can be
    /// judged any more, and the tap keeps the track.
    mutating func witnessUnavailable() {
        hasWitness = false
        unheard = 0
    }

    /// A stream buffer of `seconds`, `heard` when it held sound, `counts`
    /// when the witness was there to hear it too (its pipeline running and
    /// settled). True once, when the permission is judged missing: the track
    /// goes to the stream from now on.
    mutating func streamBuffer(heard: Bool, counts: Bool, seconds: Double) -> Bool {
        guard needsWitness, heard, counts, seconds > 0 else { return false }
        unheard += seconds
        guard unheard >= Self.proofSeconds else { return false }
        permission = .missing
        writesTap = false
        return true
    }

    private mutating func allow() -> Bool {
        guard permission == .unknown else { return false }
        permission = .allowed
        writesTap = hasTap
        return true
    }
}

// MARK: Fixes G1

/// What a stream films, as a switch sees it: a window, followed wherever it
/// goes, or one display. "The display holding the window" is not enough: the
/// window may have moved to another one since.
enum ForkMeetingFilmed: Equatable {
    case window(UInt32)
    case display(UInt32)

    /// A switch to `next` while `current` is filmed leaves the stream as it
    /// is only when it would film the very same thing.
    static func switchChangesNothing(current: ForkMeetingFilmed?, next: ForkMeetingFilmed) -> Bool {
        current == next
    }
}

extension ForkMeetingCaptureSupport {
    /// A display filmed while this app was not listed leaves out only the
    /// windows of ours it knew: it looks again after each of these delays,
    /// growing to `exclusionRetryCap`, for as long as it films that display,
    /// never giving up (a window of ours may come at any time).
    static let exclusionRetryCap: TimeInterval = 10

    static func exclusionRetryDelay(tries: Int) -> TimeInterval {
        min(exclusionRetryCap, 1 + Double(max(0, tries)))
    }
}

/// What the meeting track holds, as the start's notice and the pill say it.
enum ForkMeetingTrackSound: Equatable {
    /// What was asked for (nothing, when the sound is off).
    case heard
    /// The app's sound was asked for and there is no app to hear (no window
    /// in front, a display filmed before macOS 14.4): silence, never the
    /// whole Mac in its place.
    case noApp
    /// The app's tap lost its reader and nothing else hears that app alone:
    /// silence from then on, said once.
    case lost

    static func of(setting: ForkMeetingSystemAudio, sound: ForkMeetingSoundSource,
                   arbiter: ForkMeetingSoundArbiter, filmsWindow: Bool) -> ForkMeetingTrackSound {
        if arbiter.streamHearsMacOnly, sound != .none {
            // A call's sound (FaceTime): nothing hears it any more.
            return arbiter.writesTap || arbiter.streamWrites(filmsWindow: filmsWindow) ? .heard : .lost
        }
        guard setting == .app else { return .heard }
        if sound == .none { return .noApp }
        if arbiter.writesTap || arbiter.streamWrites(filmsWindow: filmsWindow) { return .heard }
        return arbiter.readerLost ? .lost : .noApp
    }
}

// MARK: Apps

/// What a tap that lost its reader gets before the track gives up on it
/// (S3: a device change it could not follow, AirPods coming or going,
/// leaves that tap deaf for good): a new tap of the same sound, a second
/// later, twice at most. One that hears sound again earns its tries back,
/// for the next change, up to `total` new taps for the whole recording: a
/// device that keeps failing is not rebuilt for hours.
struct ForkMeetingTapRepair: Equatable {
    static let attempts = 2
    static let delay: TimeInterval = 1
    /// New taps one recording may try, however often they heard again.
    static let total = 10

    private(set) var used = 0
    private(set) var tried = 0

    /// Whether another new tap may be tried now; counts it.
    mutating func tryAgain() -> Bool {
        guard used < Self.attempts, tried < Self.total else { return false }
        used += 1
        tried += 1
        return true
    }

    /// The tap in place heard sound: it works.
    mutating func heard() {
        used = 0
    }
}

/// Tells a microphone that stopped sending from one that is only quiet: no
/// sample at all for `noSampleDeadline`, or nothing but exact zeros for
/// `silentDeadline` (a muted device, a permission gone stale). Rules of the
/// dictation, applied all along the recording rather than at its start.
struct ForkMeetingSilenceWatch: Equatable {
    static let noSampleDeadline: TimeInterval = 1.2
    static let silentDeadline: TimeInterval = 3

    private var armedAt: TimeInterval
    private var lastSample: TimeInterval?
    private var lastSound: TimeInterval?
    private(set) var isSilent = false

    init(at time: TimeInterval) {
        armedAt = time
    }

    /// A new device: its silence is judged from now.
    mutating func rearm(at time: TimeInterval) {
        self = ForkMeetingSilenceWatch(at: time)
    }

    mutating func observe(peak: Float, at time: TimeInterval) {
        lastSample = time
        if peak > 0 { lastSound = time }
    }

    enum Change: Equatable {
        /// A silence begins: said once.
        case began
        /// Sound came back after a silence that was said.
        case ended
    }

    /// What changed since the last check, if anything.
    mutating func update(at time: TimeInterval) -> Change? {
        let noSample = time - (lastSample ?? armedAt) >= Self.noSampleDeadline
        let zeros = time - (lastSound ?? armedAt) >= Self.silentDeadline
        let silent = noSample || zeros
        defer { isSilent = silent }
        guard silent != isSilent else { return nil }
        return silent ? .began : .ended
    }

    /// True once, when a silence begins; again only after sound came back.
    mutating func check(at time: TimeInterval) -> Bool {
        update(at: time) == .began
    }
}

/// One audio track's timeline in the file, in samples at the file's rate.
/// Sources jitter, drift, restart and overlap; the file's tracks must not.
///
/// - A buffer that starts within `tolerance` of where the track ends is
///   joined to it. A device's clock drifts from the host's by some parts per
///   million (20 ppm is 72 ms an hour): that drift is absorbed as it comes,
///   one sample at a time (repeated, or dropped) whenever the track is more
///   than `deadband` away from the source, so the track never jumps.
/// - A later buffer leaves a gap the writer fills with silence (a source
///   that restarted); an earlier one loses the part already written.
/// - A buffer that says it starts well past the clock is aberrant: joined
///   where the track ends, never preceded by a silence as long as its error.
struct ForkMeetingTrackTimeline: Equatable {
    /// 20 ms at 48 kHz: the jitter of a host clock conversion, never a gap.
    static let tolerance: Int64 = 960
    /// 0.5 ms: closer than this, the buffer goes where the track ends as is.
    static let deadband: Int64 = 24
    /// One sample at most is repeated or dropped per this many samples
    /// (10 ms): up to 2 000 ppm, a hundred times a real device's drift, by
    /// steps of a fiftieth of a millisecond.
    static let correctionSpan: Int64 = 480
    /// A buffer cannot start after the clock it was captured by; one that
    /// says it starts more than this past it (1 s) is aberrant.
    static let aheadLimit: Int64 = 48_000

    /// Where the next sample goes.
    private(set) var end: Int64 = 0

    struct Placement: Equatable {
        /// Silence to write first, in samples.
        var silence: Int64
        /// Samples of the buffer to skip, already covered (or one dropped
        /// to absorb a drift).
        var skip: Int64
        /// Where the written samples start.
        var start: Int64
        /// The buffer's first sample written this many more times before
        /// it: a drift absorbed.
        var stretch: Int64 = 0
    }

    /// Where `count` samples that say they start at `start` go, or `nil` when
    /// all of them are already covered. `clock`, the file's time now in
    /// samples, bounds an aberrant start.
    mutating func place(start: Int64, count: Int64, clock: Int64? = nil) -> Placement? {
        guard count > 0 else { return nil }
        var start = start
        if let clock, start > clock + Self.aheadLimit { start = end }
        let offset = start - end
        if abs(offset) <= Self.tolerance {
            let step = max(1, count / Self.correctionSpan)
            let correction = abs(offset) <= Self.deadband ? 0 : max(-step, min(step, offset))
            if correction >= 0 {
                defer { end += correction + count }
                return Placement(silence: 0, skip: 0, start: end, stretch: correction)
            }
            let skip = min(-correction, count - 1)
            defer { end += count - skip }
            return Placement(silence: 0, skip: skip, start: end)
        }
        if start > end {
            let silence = start - end
            end = start + count
            return Placement(silence: silence, skip: 0, start: start)
        }
        let skip = end - start
        guard skip < count else { return nil }
        defer { end += count - skip }
        return Placement(silence: 0, skip: skip, start: end)
    }

    /// Silence that brings the track up to `time`, in samples (0 when it is
    /// already there).
    mutating func pad(to time: Int64) -> Int64 {
        guard time > end else { return 0 }
        defer { end = time }
        return time - end
    }
}
