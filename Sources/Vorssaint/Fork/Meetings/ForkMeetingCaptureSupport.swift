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
}

/// Where the meeting track's sound comes from for a whole recording.
enum ForkMeetingSoundSource: Equatable {
    /// A process tap on the meeting app (and its helpers).
    case appTap(pid: Int32)
    /// The screen stream's own sound: every app but this one.
    case stream
    /// None: the meeting track stays, filled with silence, so every file has
    /// the same tracks in the same order.
    case none

    /// `tapAvailable` is false before macOS 14.4. A window of this app, or
    /// no window, has no app to hear: the whole Mac then.
    static func choose(_ setting: ForkMeetingSystemAudio, appPID: Int32?, ownPID: Int32,
                       tapAvailable: Bool) -> ForkMeetingSoundSource {
        switch setting {
        case .off: return .none
        case .all: return .stream
        case .app:
            guard tapAvailable, let appPID, appPID > 0, appPID != ownPID else { return .stream }
            return .appTap(pid: appPID)
        }
    }

    /// Whether the screen stream captures sound: to write it, or to check
    /// that a tap hears what it should.
    var streamListens: Bool { self != .none }
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
/// A tap that loses its reader (a device change) keeps the track too: it
/// comes back when the tap rebuilds, and the writer fills the hole with
/// silence meanwhile.
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
    private var hasWitness: Bool
    private var unheard: Double = 0

    /// `hasTap`: the app's tap exists. `hasWitness`: a witness listens.
    init(hasTap: Bool, hasWitness: Bool) {
        self.hasTap = hasTap
        self.hasWitness = hasTap && hasWitness
        writesTap = hasTap
    }

    var writesStream: Bool { !writesTap }

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
        return true
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

    /// True once, when a silence begins; again only after sound came back.
    mutating func check(at time: TimeInterval) -> Bool {
        let noSample = time - (lastSample ?? armedAt) >= Self.noSampleDeadline
        let zeros = time - (lastSound ?? armedAt) >= Self.silentDeadline
        let silent = noSample || zeros
        defer { isSilent = silent }
        return silent && !isSilent
    }
}

/// One audio track's timeline in the file, in samples at the file's rate.
/// Sources jitter, restart and overlap; the file's tracks must not. A buffer
/// that starts within `tolerance` of where the track ends is joined to it, a
/// later one leaves a gap the writer fills with silence, an earlier one loses
/// the part already written.
struct ForkMeetingTrackTimeline: Equatable {
    /// 20 ms at 48 kHz: the jitter of a host clock conversion, never a gap.
    static let tolerance: Int64 = 960

    /// Where the next sample goes.
    private(set) var end: Int64 = 0

    struct Placement: Equatable {
        /// Silence to write first, in samples.
        var silence: Int64
        /// Samples of the buffer to skip, already covered.
        var skip: Int64
        /// Where the kept samples start.
        var start: Int64
    }

    /// Where `count` samples that say they start at `start` go, or `nil` when
    /// all of them are already covered.
    mutating func place(start: Int64, count: Int64) -> Placement? {
        guard count > 0 else { return nil }
        if abs(start - end) <= Self.tolerance {
            defer { end += count }
            return Placement(silence: 0, skip: 0, start: end)
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
