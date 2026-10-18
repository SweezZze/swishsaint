// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkMeetingCaptureTests {
    static func run(_ suite: TestSuite) {
        target(suite)
        placement(suite)
        stream(suite)
        sound(suite)
        microphone(suite)
        silence(suite)
        timeline(suite)
    }

    private static func window(_ id: UInt32, pid: Int32 = 200, layer: Int = 0, alpha: Double = 1,
                               size: CGFloat = 800, regular: Bool = true) -> ForkMeetingWindowCandidate {
        ForkMeetingWindowCandidate(id: id, pid: pid, layer: layer, alpha: alpha,
                                   bounds: CGRect(x: 0, y: 0, width: size, height: size), ownerIsRegularApp: regular)
    }

    private static func target(_ suite: TestSuite) {
        let own: Int32 = 100
        let list = [window(1, pid: own), window(2, layer: 25), window(3, alpha: 0), window(4, size: 40),
                    window(5, regular: false), window(6), window(7)]
        suite.expect(ForkMeetingCaptureSupport.frontWindow(list, ownPID: own)?.id == 6,
                     "a recording started by hand films the frontmost ordinary window of another app, not ours, "
                        + "not a menu, an invisible window, a badge or a background agent's window")
        suite.expect(ForkMeetingCaptureSupport.frontWindow(list, ownPID: own, excluded: [6])?.id == 7,
                     "a window the service leaves out is never the one filmed")
        suite.expect(ForkMeetingCaptureSupport.frontWindow([window(1, pid: own)], ownPID: own) == nil,
                     "with only our own windows there is no window to film: the display then")

        let left = ForkMeetingDisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117))
        let right = ForkMeetingDisplayFrame(id: 2, frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440))
        let across = CGRect(x: 1500, y: 100, width: 1000, height: 600)
        suite.expect(ForkMeetingCaptureSupport.display(holding: across, displays: [left, right], main: 1) == 2,
                     "a window across two displays belongs to the one holding most of it")
        suite.expect(ForkMeetingCaptureSupport.display(holding: CGRect(x: 9000, y: 0, width: 10, height: 10),
                                                       displays: [left, right], main: 1) == 1
                        && ForkMeetingCaptureSupport.display(holding: nil, displays: [left, right], main: 2) == 2,
                     "a window on no display, or no window, gives the main display")
    }

    private static func placement(_ suite: TestSuite) {
        let output = ForkMeetingPixelSize(width: 1670, height: 1080)
        let wide = ForkMeetingCaptureSupport.centeredRect(aspect: 16.0 / 9, in: output)
        suite.expect(wide.width == 1670 && wide.minX == 0 && abs(wide.midY - 540) <= 1,
                     "a wider window fills the width and is centred vertically")
        let tall = ForkMeetingCaptureSupport.centeredRect(aspect: 4.0 / 3, in: output)
        suite.expect(tall.height == 1080 && abs(tall.midX - 835) <= 1 && tall.width == 1440,
                     "a narrower window fills the height and is centred horizontally")
        let rects = [wide, tall, ForkMeetingCaptureSupport.centeredRect(aspect: 1.37, in: output)]
        suite.expect(rects.allSatisfy { [$0.minX, $0.minY, $0.width, $0.height].allSatisfy { Int($0) % 2 == 0 } }
                        && rects.allSatisfy { $0.maxX <= 1670 && $0.maxY <= 1080 },
                     "the picture lands on even pixels, inside the output")
        suite.expect(ForkMeetingCaptureSupport.centeredRect(aspect: .nan, in: output)
                        == CGRect(x: 0, y: 0, width: 1670, height: 1080),
                     "an unknown shape fills the output")
        suite.expect(ForkMeetingCaptureSupport.needsRecentering(applied: nil, observed: 1.6)
                        && ForkMeetingCaptureSupport.needsRecentering(applied: 1.6, observed: 1.3)
                        && !ForkMeetingCaptureSupport.needsRecentering(applied: 1.6, observed: 1.61)
                        && !ForkMeetingCaptureSupport.needsRecentering(applied: 1.6, observed: 0),
                     "the picture is placed again only when the window's shape changes by more than 2 %")
    }

    private static func stream(_ suite: TestSuite) {
        let domain = ForkMeetingCaptureSupport.screenCaptureErrorDomain
        typealias Stop = ForkMeetingCaptureSupport.StreamStop
        suite.expect(ForkMeetingCaptureSupport.streamStop(domain: domain, code: -3817) == .external
                        && ForkMeetingCaptureSupport.streamStop(domain: domain, code: -3821) == .external,
                     "a stream stopped by the person or by macOS is an external stop")
        suite.expect(ForkMeetingCaptureSupport.streamStop(domain: domain, code: -3815) == .sourceGone
                        && ForkMeetingCaptureSupport.streamStop(domain: domain, code: -3801) == .permission
                        && ForkMeetingCaptureSupport.streamStop(domain: domain, code: -3808) == .ignored
                        && ForkMeetingCaptureSupport.streamStop(domain: domain, code: -3811) == .failed
                        && ForkMeetingCaptureSupport.streamStop(domain: "NSOSStatusErrorDomain", code: -3817) == .failed,
                     "a lost source, a refused permission, a stop of a stopped stream and the rest are told apart")
        suite.expect(ForkMeetingCaptureSupport.runningFailure(Stop.external) == .streamStopped
                        && ForkMeetingCaptureSupport.runningFailure(Stop.failed) == .streamStopped
                        && ForkMeetingCaptureSupport.runningFailure(Stop.permission) == .screenRecordingRevoked,
                     "a stream that stops during a meeting stops it, its file kept")
        suite.expect(ForkMeetingCaptureSupport.runningFailure(Stop.sourceGone) == nil
                        && ForkMeetingCaptureSupport.runningFailure(Stop.ignored) == nil,
                     "a window whose app quit only freezes the picture; the service decides if the meeting ended")
        suite.expect(ForkMeetingCaptureSupport.startFailure(Stop.permission) == .screenRecordingDenied
                        && ForkMeetingCaptureSupport.startFailure(Stop.external) == .captureFailed,
                     "a stream that will not start says why")
        suite.expect(ForkMeetingCaptureSupport.frameKind(status: 0) == .picture
                        && ForkMeetingCaptureSupport.frameKind(status: 4) == .picture
                        && ForkMeetingCaptureSupport.frameKind(status: 1) == .idle
                        && [2, 3, 5].allSatisfy { ForkMeetingCaptureSupport.frameKind(status: $0) == .frozen },
                     "a minimized, hidden or blank source freezes the picture; an unchanged one does not")
        suite.expect(ForkMeetingCaptureSupport.restartDelays.first == 0
                        && ForkMeetingCaptureSupport.restartDelays.reduce(0, +) <= 10,
                     "a stream rebuilt after a sleep is tried at once, then again for at most ten seconds")
        suite.expect(ForkMeetingCaptureSupport.unresolved(.sourceGone, aimsAtWindow: true) == .filmDisplay,
                     "⧉ or a wake towards a window that went films its display at once, never ends the recording")
        suite.expect(ForkMeetingCaptureSupport.unresolved(.sourceGone, aimsAtWindow: false) == .retry
                        && ForkMeetingCaptureSupport.unresolved(.failed, aimsAtWindow: true) == .retry
                        && ForkMeetingCaptureSupport.unresolved(.external, aimsAtWindow: false) == .retry,
                     "a display not back yet after a wake, or a passing failure: tried again later")
        suite.expect(ForkMeetingCaptureSupport.unresolved(.permission, aimsAtWindow: true) == .giveUp,
                     "Screen Recording taken back: waiting will not bring it back")
    }

    private static func sound(_ suite: TestSuite) {
        let own: Int32 = 100
        suite.expect(ForkMeetingSoundSource.choose(.app, appPID: 200, ownPID: own, tapAvailable: true) == .appTap(pid: 200),
                     "the meeting app's own sound, from its tap")
        suite.expect(ForkMeetingSoundSource.choose(.app, appPID: 200, ownPID: own, tapAvailable: false) == .stream
                        && ForkMeetingSoundSource.choose(.app, appPID: nil, ownPID: own, tapAvailable: true) == .stream
                        && ForkMeetingSoundSource.choose(.app, appPID: own, ownPID: own, tapAvailable: true) == .stream,
                     "before macOS 14.4, without a window, or for a window of ours: the whole Mac")
        suite.expect(ForkMeetingSoundSource.choose(.all, appPID: 200, ownPID: own, tapAvailable: true) == .stream
                        && ForkMeetingSoundSource.choose(.off, appPID: 200, ownPID: own, tapAvailable: true) == .none,
                     "all the Mac from the stream, or none")
        suite.expect(!ForkMeetingSoundSource.none.streamListens && ForkMeetingSoundSource.appTap(pid: 1).streamListens,
                     "the stream listens whenever there is sound, to check the tap; never when it is off")

        arbiter(suite)
    }

    /// What one 10 ms tick of a recording carries: what the meeting app
    /// plays (its tap), what every other app plays, and whether system audio
    /// recording is allowed (without it, both taps hear silence).
    private struct Tick {
        var meeting: Bool
        var others: Bool
        var allowed = true
    }

    /// Plays `ticks` through an arbiter the way the recorder feeds it (the
    /// stream, then the two taps, each tick) and returns what the meeting
    /// track got, tick by tick: "meeting" for the app's tap with sound,
    /// "silence" for the tap without, "mac" for the stream's sound, and how
    /// many times each verdict was said.
    private static func play(_ ticks: [Tick], hasWitness: Bool = true, witnessSettles: Double = 0)
        -> (track: [String], missing: Int, allowed: Int, arbiter: ForkMeetingSoundArbiter) {
        var arbiter = ForkMeetingSoundArbiter(hasTap: true, hasWitness: hasWitness)
        var track: [String] = []
        var missing = 0, allowed = 0
        for (index, tick) in ticks.enumerated() {
            let streamHears = tick.meeting || tick.others
            let counts = Double(index) * 0.01 >= witnessSettles
            if arbiter.streamBuffer(heard: streamHears, counts: counts, seconds: 0.01) { missing += 1 }
            if arbiter.writesStream, streamHears { track.append("mac") }
            if arbiter.tapBuffer(heard: tick.allowed && tick.meeting) { allowed += 1 }
            if arbiter.writesTap { track.append(tick.allowed && tick.meeting ? "meeting" : "silence") }
            if hasWitness, arbiter.needsWitness, arbiter.witnessBuffer(heard: tick.allowed && streamHears) { allowed += 1 }
        }
        return (track, missing, allowed, arbiter)
    }

    private static func ticks(_ seconds: Double, meeting: Bool = false, others: Bool = false,
                              allowed: Bool = true) -> [Tick] {
        Array(repeating: Tick(meeting: meeting, others: others, allowed: allowed), count: Int((seconds * 100).rounded()))
    }

    private static func arbiter(_ suite: TestSuite) {
        let fresh = ForkMeetingSoundArbiter(hasTap: true, hasWitness: true)
        suite.expect(fresh.writesTap && !fresh.writesStream && fresh.needsWitness && fresh.permission == .unknown,
                     "the app's tap writes the meeting track from the very start, before anything is proven")

        let waitingRoom = play(ticks(30, others: true))
        suite.expect(waitingRoom.track.allSatisfy { $0 == "silence" } && waitingRoom.missing == 0
                        && waitingRoom.allowed == 1 && waitingRoom.arbiter.permission == .allowed,
                     "a silent waiting room while Spotify plays for 30 s: the track is silence, Spotify is never written")
        suite.expect(!waitingRoom.arbiter.needsWitness, "the witness heard Spotify: the permission is proven, it can go")

        let spotifyThenMeeting = play(ticks(4, others: true) + ticks(10, meeting: true) + ticks(5, meeting: true, others: true))
        suite.expect(!spotifyThenMeeting.track.contains("mac") && spotifyThenMeeting.track.contains("meeting")
                        && spotifyThenMeeting.missing == 0,
                     "Spotify 4 s, then the meeting speaks: the track holds the meeting only, never the Mac")

        let tapFirst = play(ticks(1, meeting: true) + ticks(10, others: true))
        suite.expect(tapFirst.allowed == 1 && tapFirst.arbiter.permission == .allowed && !tapFirst.track.contains("mac"),
                     "the app's tap hearing its app proves the permission as well, once")

        let denied = play(ticks(2, others: true, allowed: false) + ticks(10, meeting: true, others: true, allowed: false))
        let firstMac = denied.track.firstIndex(of: "mac")
        let beforeMac = firstMac.map { denied.track[..<$0] } ?? denied.track[...]
        suite.expect(denied.missing == 1 && denied.arbiter.permission == .missing && denied.arbiter.writesStream
                        && !denied.arbiter.needsWitness,
                     "both taps deaf while the stream hears 3 s: the permission is missing, said once")
        suite.expect(abs(beforeMac.count - 300) <= 1 && beforeMac.allSatisfy { $0 == "silence" }
                        && denied.track[(firstMac ?? 0)...].allSatisfy { $0 == "mac" },
                     "the track is the app's silence for those 3 s, then the whole Mac for the rest of the recording")

        let settling = play(ticks(2.9, others: true, allowed: false) + ticks(0.5), witnessSettles: 2.5)
        suite.expect(settling.missing == 0 && settling.arbiter.writesTap,
                     "the stream's sound from before the witness settled counts for nothing")

        let quietMac = play(ticks(60, allowed: false))
        suite.expect(quietMac.missing == 0 && quietMac.arbiter.permission == .unknown && quietMac.arbiter.writesTap,
                     "a Mac that plays nothing proves nothing either way: the tap keeps the track")

        let blind = play(ticks(60, others: true, allowed: false), hasWitness: false)
        suite.expect(blind.missing == 0 && !blind.track.contains("mac") && !blind.arbiter.needsWitness,
                     "without a witness nothing is judged: the tap keeps the track, the Mac is never written")
        var lost = ForkMeetingSoundArbiter(hasTap: true, hasWitness: true)
        lost.witnessUnavailable()
        suite.expect(!lost.streamBuffer(heard: true, counts: true, seconds: 10) && lost.writesTap,
                     "a witness that lost its reader judges nothing more")

        var once = ForkMeetingSoundArbiter(hasTap: true, hasWitness: true)
        _ = once.streamBuffer(heard: true, counts: true, seconds: 3)
        suite.expect(!once.tapBuffer(heard: true) && !once.witnessBuffer(heard: true) && once.writesStream,
                     "a verdict is final for the recording")

        let none = ForkMeetingSoundArbiter(hasTap: false, hasWitness: true)
        suite.expect(none.writesStream && !none.needsWitness, "the whole Mac's sound, by choice or without a tap: the stream")
    }

    private static func microphone(_ suite: TestSuite) {
        suite.expect(ForkMeetingMicrophoneChoice(stored: "meeting") == .meeting
                        && ForkMeetingMicrophoneChoice(stored: "") == .meeting
                        && ForkMeetingMicrophoneChoice(stored: "system") == .system
                        && ForkMeetingMicrophoneChoice(stored: "builtin") == .builtIn
                        && ForkMeetingMicrophoneChoice(stored: "off") == .off
                        && ForkMeetingMicrophoneChoice(stored: "AppleUSBAudioEngine:1") == .device("AppleUSBAudioEngine:1"),
                     "the microphone setting reads as the meeting's, the system's, the built-in one, a device, or none")
        suite.expect(ForkMeetingMicrophoneChoice.meeting.followsSystemInput
                        && ForkMeetingMicrophoneChoice.system.followsSystemInput
                        && !ForkMeetingMicrophoneChoice.builtIn.followsSystemInput
                        && !ForkMeetingMicrophoneChoice.device("x").followsSystemInput,
                     "only the system's input follows AirPods that arrive; a chosen device stays")
    }

    private static func silence(_ suite: TestSuite) {
        var watch = ForkMeetingSilenceWatch(at: 0)
        suite.expect(!watch.check(at: 1.1) && watch.check(at: 1.2),
                     "no sample at all for 1.2 s is a silent microphone")
        suite.expect(!watch.check(at: 1.7), "said once, not every check")

        var zeros = ForkMeetingSilenceWatch(at: 0)
        for t in stride(from: 0.1, through: 2.9, by: 0.1) { zeros.observe(peak: 0, at: t) }
        suite.expect(!zeros.check(at: 2.9), "zeros for under three seconds are a quiet room")
        zeros.observe(peak: 0, at: 3.0)
        suite.expect(zeros.check(at: 3.0), "nothing but zeros for three seconds is a muted device")
        zeros.observe(peak: 0.2, at: 3.5)
        suite.expect(!zeros.check(at: 3.5) && !zeros.isSilent, "sound coming back ends the silence")
        for t in stride(from: 3.6, through: 6.6, by: 0.1) { zeros.observe(peak: 0, at: t) }
        suite.expect(zeros.check(at: 6.6), "a new silence is said again")

        var quiet = ForkMeetingSilenceWatch(at: 0)
        for t in stride(from: 0.1, through: 30, by: 0.1) { quiet.observe(peak: 0.001, at: t) }
        suite.expect(!quiet.check(at: 30), "a faint but real signal is never silence")
        quiet.rearm(at: 30)
        suite.expect(!quiet.check(at: 31) && quiet.check(at: 31.3),
                     "a new device is judged from when it took over")
    }

    private static func timeline(_ suite: TestSuite) {
        typealias Placement = ForkMeetingTrackTimeline.Placement
        var track = ForkMeetingTrackTimeline()
        suite.expect(track.place(start: 0, count: 480) == Placement(silence: 0, skip: 0, start: 0)
                        && track.place(start: 500, count: 480) == Placement(silence: 0, skip: 0, start: 480),
                     "a buffer within the clock's jitter joins the track without a gap")
        suite.expect(track.place(start: 48_960, count: 480) == Placement(silence: 48_000, skip: 0, start: 48_960)
                        && track.end == 49_440,
                     "a buffer a second late leaves a second of silence before it")
        suite.expect(track.place(start: 47_440, count: 4_800) == Placement(silence: 0, skip: 2_000, start: 49_440),
                     "a buffer that overlaps what was written loses only the overlap")
        suite.expect(track.place(start: 0, count: 480) == nil && track.end == 52_240,
                     "a buffer already covered is dropped")
        suite.expect(track.pad(to: 60_000) == 7_760 && track.end == 60_000 && track.pad(to: 50_000) == 0,
                     "a silent source is filled up to the clock, never backwards")
    }
}
