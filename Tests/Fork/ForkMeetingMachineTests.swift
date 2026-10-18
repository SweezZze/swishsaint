// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkMeetingMachineTests {
    typealias Machine = ForkMeetingMachine
    typealias Patch = ForkMeetingSidecarPatch

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let folder = URL(fileURLWithPath: "/tmp/Meetings/2026-10-18 10h02 — Meeting", isDirectory: true)
    private static let settings = ForkMeetingCaptureSettings(target: .window, systemAudio: .app, microphone: "meeting",
                                                             quality: .standard)
    private static let ready = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                     microphoneAllowed: true, officialRecorderBusy: false)

    static func run(_ suite: TestSuite) {
        starting(suite)
        refusals(suite)
        startFailures(suite)
        pausing(suite)
        stopping(suite)
        tokens(suite)
        sleepAndLock(suite)
        disk(suite)
        permissionsAndDevices(suite)
        quitting(suite)
        featureOff(suite)
        invariants(suite)
    }

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func request(_ settings: ForkMeetingCaptureSettings = settings,
                                facts: ForkMeetingStartFacts = ready) -> Machine.Event {
        .manualStart(ForkMeetingStartRequest(settings: settings, facts: facts))
    }

    private static let token1 = ForkMeetingToken(value: 1)

    /// A machine recording since `t0`, with session token 1.
    private static func recording(_ settings: ForkMeetingCaptureSettings = settings) -> Machine {
        var machine = Machine()
        machine.handle(request(settings), now: t0)
        machine.handle(.captureStarted(token1, folder: folder), now: t0)
        return machine
    }

    private static func isRecording(_ machine: Machine) -> Bool {
        if case .recording = machine.phase { return true }
        return false
    }

    private static func isPaused(_ machine: Machine, _ reason: ForkMeetingPauseReason) -> Bool {
        if case .paused(_, reason) = machine.phase { return true }
        return false
    }

    private static func isStopping(_ machine: Machine, _ reason: ForkMeetingStopReason) -> Bool {
        if case .stopping(_, reason) = machine.phase { return true }
        return false
    }

    private static func stoppedFile(_ effects: [Machine.Effect]) -> Bool {
        effects.contains(.stopCapture(token1))
    }

    private static func patches(_ effects: [Machine.Effect]) -> [Patch] {
        effects.compactMap {
            if case let .writeSidecar(_, patch) = $0 { return patch }
            return nil
        }
    }

    private static func finalizes(_ effects: [Machine.Effect]) -> Bool {
        effects.contains(.beginFinalize(folder))
    }

    private static func starting(_ suite: TestSuite) {
        var machine = Machine()
        let config = ForkMeetingCaptureConfig(origin: .manual, title: nil, settings: settings, recordsMicrophone: true,
                                              microphoneDenied: false)
        suite.expect(machine.handle(request(), now: t0) == [.startCapture(config, token1)]
                        && machine.phase == .starting(.init(token: token1, config: config)) && machine.isBusy,
                     "a manual start asks for a capture, with the settings, the origin and a new token")
        suite.expect(machine.handle(request(), now: t0).isEmpty, "a second start while starting does nothing")
        suite.expect(machine.handle(.captureStarted(token1, folder: folder), now: at(1))
                        == [.showPill(.recording(.init(recordedBefore: 0, runningSince: at(1)), diskMinutesLeft: nil)),
                            .notice(.started), .announce(.started)],
                     "once the capture runs: the pill with its clock, the island notice and VoiceOver")
        suite.expect(machine.activeSession?.folder == folder && machine.activeSession?.origin == .manual,
                     "the session records in the folder the service made")
        suite.expect(machine.activeSession?.endsWithMeeting == false,
                     "a meeting recorded by hand is never ended by the detection")
        suite.expect(machine.handle(request(), now: at(2)).isEmpty, "the start shortcut during a recording starts nothing")
        suite.expect(machine.handle(.captureStarted(token1, folder: folder), now: at(3)).isEmpty,
                     "a second report of the same start does nothing")

        var muted = Machine()
        muted.handle(request(facts: ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                          microphoneAllowed: false, officialRecorderBusy: false)), now: t0)
        if case let .starting(pending) = muted.phase {
            suite.expect(!pending.config.recordsMicrophone && pending.config.microphoneDenied,
                         "a microphone not allowed does not stop the meeting: it records without it")
        } else {
            suite.expect(false, "a meeting starts without its microphone")
        }
        suite.expect(muted.handle(.captureStarted(token1, folder: folder), now: t0).contains(.notice(.failure(.microphoneDenied))),
                     "and the start says the microphone is missing")

        var off = Machine()
        var noMicrophone = settings
        noMicrophone.microphone = ForkMeetingCaptureSettings.microphoneOff
        off.handle(request(noMicrophone, facts: ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                                      microphoneAllowed: false, officialRecorderBusy: false)),
                   now: t0)
        if case let .starting(pending) = off.phase {
            suite.expect(!pending.config.recordsMicrophone && !pending.config.microphoneDenied,
                         "a microphone turned off is not reported as refused")
        } else {
            suite.expect(false, "a meeting starts with the microphone off")
        }
    }

    private static func refusals(_ suite: TestSuite) {
        func refused(_ facts: ForkMeetingStartFacts) -> (Machine, [Machine.Effect]) {
            var machine = Machine()
            let effects = machine.handle(request(facts: facts), now: t0)
            return (machine, effects)
        }
        let busy = refused(.init(freeBytes: 50_000_000_000, screenRecordingAllowed: true, microphoneAllowed: true,
                                 officialRecorderBusy: true))
        suite.expect(busy.1 == [.notice(.failure(.officialRecorderBusy)), .announce(.failure(.officialRecorderBusy))]
                        && busy.0.phase == .idle,
                     "with the official recorder running, a meeting does not start, and says why")
        let screen = refused(.init(freeBytes: 50_000_000_000, screenRecordingAllowed: false, microphoneAllowed: true,
                                   officialRecorderBusy: true))
        suite.expect(screen.1.first == .notice(.failure(.screenRecordingDenied)) && screen.0.phase == .idle,
                     "without Screen Recording nothing can be filmed: that is said first")
        let full = refused(.init(freeBytes: 1_500_000_000, screenRecordingAllowed: true, microphoneAllowed: true,
                                 officialRecorderBusy: false))
        suite.expect(full.1.first == .notice(.failure(.diskFullAtStart(requiredBytes: 2_000_000_000))) && full.0.phase == .idle,
                     "under two gigabytes free, a meeting does not start")
        let unknown = refused(.init(freeBytes: nil, screenRecordingAllowed: true, microphoneAllowed: true,
                                    officialRecorderBusy: false))
        suite.expect(unknown.1.first == .notice(.failure(.folderUnavailable)),
                     "free space that cannot be read means the folder is out of reach, never that there is room")
        suite.expect([busy, screen, full, unknown].allSatisfy { !$0.1.contains { if case .startCapture = $0 { return true }; return false } },
                     "a refused start never opens a capture")
    }

    private static func startFailures(_ suite: TestSuite) {
        var failed = Machine()
        failed.handle(request(), now: t0)
        let effects = failed.handle(.captureFailed(token1, .captureFailed), now: at(1))
        suite.expect(effects == [.stopCapture(token1), .notice(.failure(.captureFailed)), .announce(.failure(.captureFailed))]
                        && failed.phase == .idle,
                     "a capture that fails to start leaves nothing behind and says so")
        suite.expect(failed.handle(.writerFinished(token1, .finished(recordedSeconds: 0)), now: at(2)).isEmpty,
                     "nothing is finalized for a meeting that never started")

        var cancelled = Machine()
        cancelled.handle(request(), now: t0)
        suite.expect(cancelled.handle(.stop, now: at(1)) == [.stopCapture(token1), .showPill(.hidden)]
                        && cancelled.phase == .idle,
                     "Stop before the capture runs cancels the start: nothing was recorded")
        suite.expect(cancelled.handle(.captureStarted(token1, folder: folder), now: at(2)).isEmpty && cancelled.phase == .idle,
                     "a capture that starts after its cancel is not taken for a recording")
    }

    private static func pausing(_ suite: TestSuite) {
        var machine = recording()
        let pause = machine.handle(.pause, now: at(60))
        suite.expect(pause == [.pauseCapture(.user),
                               .showPill(.paused(.init(recordedBefore: 60, runningSince: nil), .user, diskMinutesLeft: nil)),
                               .announce(.paused)]
                        && isPaused(machine, .user),
                     "a pause stops the clock at the minute reached, in the file and on the pill")
        suite.expect(machine.handle(.pause, now: at(70)).isEmpty, "a second pause does nothing")
        let resume = machine.handle(.resume, now: at(90))
        suite.expect(resume == [.resumeCapture, .writeSidecar(folder, Patch(pause: .init(at: 60, seconds: 30, reason: .user))),
                                .showPill(.recording(.init(recordedBefore: 60, runningSince: at(90)), diskMinutesLeft: nil)),
                                .announce(.resumed)],
                     "a resume writes the pause into meeting.json and the clock runs on from where it stopped")
        suite.expect(machine.handle(.resume, now: at(95)).isEmpty, "a resume while recording does nothing")
    }

    private static func stopping(_ suite: TestSuite) {
        var machine = recording()
        machine.handle(.pause, now: at(60))
        machine.handle(.resume, now: at(90))
        let stop = machine.handle(.stop, now: at(120))
        suite.expect(stop == [.stopCapture(token1), .writeSidecar(folder, Patch(stopReason: .user)), .showPill(.stopping),
                              .announce(.stopped)],
                     "Stop closes the capture and notes who stopped it")
        if case let .stopping(session, .user) = machine.phase {
            suite.expect(session.recordedBefore == 90 && session.stoppedAt == at(120),
                         "the meeting lasted ninety seconds of recording, pause excluded")
        } else {
            suite.expect(false, "a stop goes through stopping")
        }
        suite.expect(machine.handle(.stop, now: at(121)).isEmpty && machine.handle(.pause, now: at(121)).isEmpty,
                     "Stop or Pause again while stopping do nothing")
        let done = machine.handle(.writerFinished(token1, .finished(recordedSeconds: 89.5)), now: at(122))
        suite.expect(done == [.writeSidecar(folder, Patch(state: .finalizing, endedAt: at(120), recordedSeconds: 89.5)),
                              .beginFinalize(folder), .showPill(.finalizing)]
                        && machine.phase == .idle && !machine.isBusy,
                     "once the file is closed: its end and length are written, and the finalizer takes it")
        suite.expect(machine.handle(.writerFinished(token1, .finished(recordedSeconds: 89.5)), now: at(123)).isEmpty,
                     "a second report never finalizes twice")

        var paused = recording()
        paused.handle(.pause, now: at(30))
        let stopPaused = paused.handle(.stop, now: at(50))
        suite.expect(patches(stopPaused) == [Patch(stopReason: .user, pause: .init(at: 30, seconds: 20, reason: .user))],
                     "stopping during a pause writes that pause too")
        suite.expect(patches(paused.handle(.writerFinished(token1, .finished(recordedSeconds: nil)), now: at(51)))
                        == [Patch(state: .finalizing, endedAt: at(50), recordedSeconds: 30)],
                     "without the writer's count, the machine's own is written")

        var broken = recording()
        broken.handle(.stop, now: at(10))
        let failed = broken.handle(.writerFinished(token1, .failed(.writerFailed)), now: at(11))
        suite.expect(patches(failed) == [Patch(state: .interrupted)] && !finalizes(failed)
                        && failed.contains(.notice(.failure(.writerFailed))) && failed.contains(.notify(.failure(.writerFailed)))
                        && broken.phase == .idle,
                     "a file that does not close is marked interrupted, without an end, never finalized, and said")
        suite.expect(patches(failed).allSatisfy { $0.endedAt == nil }, "a failure never writes an end time")

        var early = recording()
        suite.expect(early.handle(.writerFinished(token1, .finished(recordedSeconds: 3)), now: at(5)).isEmpty
                        && isRecording(early),
                     "a writer report while recording is not an end: the capture reports failures itself")
    }

    private static func tokens(_ suite: TestSuite) {
        var machine = recording()
        machine.handle(.stop, now: at(10))
        machine.handle(.writerFinished(token1, .finished(recordedSeconds: 10)), now: at(11))
        let effects = machine.handle(request(), now: at(12))
        let token2 = ForkMeetingToken(value: 2)
        suite.expect(effects.count == 1 && effects.first.map { if case .startCapture(_, token2) = $0 { return true }; return false } == true,
                     "the next meeting gets a new token, while the first one is finalized")
        suite.expect(machine.handle(.captureStarted(token1, folder: folder), now: at(13)).isEmpty
                        && machine.handle(.captureFailed(token1, .streamStopped), now: at(13)).isEmpty,
                     "an answer for the first meeting does not touch the second one's start")
        let second = folder.deletingLastPathComponent().appendingPathComponent("2026-10-18 11h00 — Meeting")
        machine.handle(.captureStarted(token2, folder: second), now: at(14))
        suite.expect(machine.handle(.captureFailed(token1, .streamStopped), now: at(15)).isEmpty
                        && machine.handle(.writerFinished(token1, .failed(.writerFailed)), now: at(15)).isEmpty
                        && machine.activeSession?.token == token2 && machine.activeSession?.folder == second,
                     "a late failure of the first meeting never stops the second")
    }

    private static func sleepAndLock(_ suite: TestSuite) {
        var machine = recording()
        let sleep = machine.handle(.willSleep, now: at(100))
        suite.expect(sleep.first == .pauseCapture(.sleep) && sleep.contains(.announce(.paused))
                        && isPaused(machine, .sleep),
                     "the Mac going to sleep pauses the recording and stops the stream")
        let wake = machine.handle(.didWake, now: at(400))
        suite.expect(wake == [.restartStream, .resumeCapture,
                              .writeSidecar(folder, Patch(pause: .init(at: 100, seconds: 300, reason: .sleep))),
                              .showPill(.recording(.init(recordedBefore: 100, runningSince: at(400)), diskMinutesLeft: nil)),
                              .notice(.resumed), .announce(.resumed)],
                     "at the wake a meeting recorded by hand resumes on a new stream, and says so; the sleep is not counted")

        var userPaused = recording()
        userPaused.handle(.pause, now: at(10))
        suite.expect(userPaused.handle(.willSleep, now: at(20)) == [.pauseCapture(.sleep)]
                        && userPaused.handle(.didWake, now: at(80)).isEmpty
                        && isPaused(userPaused, .user),
                     "a pause chosen by the person survives a sleep: the wake does not resume it")
        suite.expect(userPaused.handle(.resume, now: at(90)).prefix(2) == [.restartStream, .resumeCapture],
                     "and its resume starts a new stream, the old one died with the sleep")

        var locked = recording()
        suite.expect(locked.handle(.locked, now: at(50)).isEmpty && isRecording(locked),
                     "a locked screen pauses nothing: the sound goes on, the picture freezes")
        suite.expect(locked.handle(.locked, now: at(55)).isEmpty, "a second lock report changes nothing")
        suite.expect(locked.handle(.unlocked, now: at(70))
                        == [.writeSidecar(folder, Patch(gap: .init(at: 50, seconds: 20, kind: .screenLocked)))]
                        && isRecording(locked),
                     "the unlock notes the lock in meeting.json as a gap, from the lock to the unlock")
        suite.expect(locked.handle(.unlocked, now: at(80)).isEmpty, "an unlock without a lock notes nothing")

        var lidClosed = recording()
        lidClosed.handle(.locked, now: at(10))
        lidClosed.handle(.willSleep, now: at(11))
        let wakeLocked = lidClosed.handle(.didWake, now: at(100))
        suite.expect(wakeLocked.prefix(2) == [.restartStream, .resumeCapture] && wakeLocked.contains(.notice(.resumed))
                        && patches(wakeLocked) == [Patch(pause: .init(at: 11, seconds: 89, reason: .sleep))]
                        && isRecording(lidClosed),
                     "waking on the lock screen resumes at once on a new stream; the picture stays frozen until the unlock")
        suite.expect(lidClosed.handle(.unlocked, now: at(130))
                        == [.writeSidecar(folder, Patch(gap: .init(at: 10, seconds: 31, kind: .screenLocked)))],
                     "the lock's gap counts recorded seconds only: the sleep inside it is a pause, not counted twice")

        var dead = recording()
        dead.handle(.locked, now: at(10))
        suite.expect(dead.handle(.captureFailed(token1, .streamStopped), now: at(20)).isEmpty && isRecording(dead),
                     "a stream that dies during the lock is expected, not a failure: the sound goes on")
        suite.expect(dead.handle(.unlocked, now: at(40))
                        == [.restartStream, .writeSidecar(folder, Patch(gap: .init(at: 10, seconds: 30, kind: .screenLocked)))],
                     "the unlock starts a new stream for the picture")
        suite.expect(stoppedFile(dead.handle(.captureFailed(token1, .streamStopped), now: at(50))),
                     "unlocked again, a stream that dies is a real stop")

        var stoppedLocked = recording()
        stoppedLocked.handle(.locked, now: at(10))
        suite.expect(patches(stoppedLocked.handle(.stop, now: at(25)))
                        == [Patch(stopReason: .user, gap: .init(at: 10, seconds: 15, kind: .screenLocked))],
                     "a meeting stopped during the lock closes its gap at the stop")
        var quitLocked = recording()
        quitLocked.handle(.locked, now: at(10))
        suite.expect(quitLocked.handle(.appWillTerminate, now: at(30)).first
                        == .writeSidecar(folder, Patch(state: .interrupted, stopReason: .quit,
                                                       gap: .init(at: 10, seconds: 20, kind: .screenLocked))),
                     "quitting during the lock closes its gap too")

        var pausedThrough = recording()
        pausedThrough.handle(.pause, now: at(10))
        pausedThrough.handle(.locked, now: at(20))
        suite.expect(pausedThrough.handle(.unlocked, now: at(30)).isEmpty && isPaused(pausedThrough, .user),
                     "a lock inside a pause records no gap, and never resumes the pause")
        pausedThrough.handle(.locked, now: at(40))
        pausedThrough.handle(.resume, now: at(45))
        suite.expect(pausedThrough.handle(.unlocked, now: at(55))
                        == [.writeSidecar(folder, Patch(gap: .init(at: 10, seconds: 10, kind: .screenLocked)))],
                     "a lock that outlasts the pause counts only the seconds recorded behind it")

        var startedLocked = Machine()
        startedLocked.handle(.locked, now: t0)
        startedLocked.handle(request(), now: t0)
        startedLocked.handle(.captureStarted(token1, folder: folder), now: at(1))
        suite.expect(startedLocked.handle(.unlocked, now: at(6))
                        == [.writeSidecar(folder, Patch(gap: .init(at: 0, seconds: 5, kind: .screenLocked)))],
                     "a meeting started on a locked screen notes the lock from its first second")

        var startingAsleep = Machine()
        startingAsleep.handle(request(), now: t0)
        suite.expect(startingAsleep.handle(.willSleep, now: at(1)) == [.stopCapture(token1), .showPill(.hidden)]
                        && startingAsleep.phase == .idle,
                     "a start under way when the Mac sleeps is cancelled: nothing was recorded")
    }

    private static func disk(_ suite: TestSuite) {
        var machine = recording()
        let minutes = ForkMeetingDisk.minutesLeft(freeBytes: 1_500_000_000, quality: .standard)
        let low = machine.handle(.diskLow(freeBytes: 1_500_000_000), now: at(10))
        suite.expect(low == [.showPill(.recording(.init(recordedBefore: 0, runningSince: t0), diskMinutesLeft: minutes)),
                             .notice(.diskLow(minutesLeft: minutes)), .announce(.diskLow(minutesLeft: minutes))],
                     "under two gigabytes the pill shows the minutes left, and the island says it once")
        let lower = ForkMeetingDisk.minutesLeft(freeBytes: 1_400_000_000, quality: .standard)
        suite.expect(machine.handle(.diskLow(freeBytes: 1_400_000_000), now: at(25))
                        == [.showPill(.recording(.init(recordedBefore: 0, runningSince: t0), diskMinutesLeft: lower))],
                     "later readings only update the pill")
        suite.expect(machine.handle(.diskLow(freeBytes: 1_400_000_000), now: at(40)).isEmpty, "the same reading changes nothing")
        suite.expect(machine.handle(.diskLow(freeBytes: 5_000_000_000), now: at(55))
                        == [.showPill(.recording(.init(recordedBefore: 0, runningSince: t0), diskMinutesLeft: nil))],
                     "room made again clears the warning")
        let critical = machine.handle(.diskLow(freeBytes: 400_000_000), now: at(70))
        suite.expect(stoppedFile(critical) && patches(critical) == [Patch(stopReason: .disk)]
                        && critical.contains(.notice(.failure(.diskFull))) && critical.contains(.notify(.failure(.diskFull))),
                     "under 500 MB the meeting stops cleanly, says why, and a notification tells it if the app is behind")
        suite.expect(finalizes(machine.handle(.writerFinished(token1, .finished(recordedSeconds: 70)), now: at(71))),
                     "a meeting stopped by the disk keeps its file and is finalized")

        var direct = recording()
        let stop = direct.handle(.diskCritical, now: at(5))
        suite.expect(stoppedFile(stop) && patches(stop) == [Patch(stopReason: .disk)] && !stop.contains(.announce(.stopped))
                        && stop.contains(.announce(.failure(.diskFull))),
                     "a critical disk stops the meeting, and VoiceOver hears why rather than a plain stop")
        var idle = Machine()
        suite.expect(idle.handle(.diskCritical, now: t0).isEmpty && idle.handle(.diskLow(freeBytes: 1), now: t0).isEmpty,
                     "disk readings without a meeting do nothing")
    }

    private static func permissionsAndDevices(_ suite: TestSuite) {
        var screen = recording()
        let lost = screen.handle(.permissionLost(.screenRecording), now: at(30))
        suite.expect(stoppedFile(lost) && patches(lost) == [Patch(stopReason: .permission)]
                        && lost.contains(.notice(.failure(.screenRecordingRevoked))),
                     "Screen Recording taken back stops the meeting, file kept, reason noted")
        suite.expect(finalizes(screen.handle(.writerFinished(token1, .finished(recordedSeconds: 30)), now: at(31))),
                     "and what was recorded is finalized")

        var denied = recording()
        let failed = denied.handle(.captureFailed(token1, .screenRecordingDenied), now: at(5))
        suite.expect(failed.contains(.notice(.failure(.screenRecordingRevoked))) && patches(failed) == [Patch(stopReason: .permission)],
                     "a stream stopped for the permission during a meeting reads as a permission taken back")

        var stream = recording()
        let stopped = stream.handle(.captureFailed(token1, .streamStopped), now: at(5))
        suite.expect(stoppedFile(stopped) && patches(stopped) == [Patch(stopReason: .captureStopped)]
                        && stopped.contains(.notify(.failure(.streamStopped))),
                     "a stream macOS stops ends the meeting, with its file kept")

        var microphone = recording()
        let gone = microphone.handle(.permissionLost(.microphone), now: at(5))
        suite.expect(!stoppedFile(gone) && patches(gone) == [Patch(microphone: "denied")]
                        && gone.contains(.notice(.failure(.microphoneDenied))) && microphone.activeSession != nil,
                     "the microphone taken back: the meeting goes on without it, and meeting.json says so")
        let audio = microphone.handle(.permissionLost(.systemAudio), now: at(6))
        suite.expect(audio == [.notice(.failure(.systemAudioUnavailable)), .announce(.failure(.systemAudioUnavailable))],
                     "the app's sound unavailable: said, the meeting goes on with the Mac's sound")

        var window = recording()
        suite.expect(window.handle(.displayChanged, now: at(5)).isEmpty,
                     "filming the window, a display change needs nothing: the window is followed")
        var displaySettings = settings
        displaySettings.target = .display
        var display = recording(displaySettings)
        suite.expect(display.handle(.displayChanged, now: at(5)) == [.switchTarget, .notice(.displayChanged), .announce(.displayChanged)],
                     "filming the display, a display change moves to the meeting window's display")

        var devices = recording()
        let changed = devices.handle(.microphoneChanged(name: "AirPods de Martial", gap: 1.5), now: at(100))
        suite.expect(changed == [.writeSidecar(folder, Patch(gap: .init(at: 98.5, seconds: 1.5, kind: .microphoneSwitch),
                                                             microphone: "AirPods de Martial")),
                                 .notice(.microphone("AirPods de Martial")), .announce(.microphone("AirPods de Martial"))],
                     "a new microphone is named, and the moment lost switching is noted in meeting.json")
        suite.expect(patches(devices.handle(.microphoneChanged(name: "MacBook Pro", gap: 0), now: at(200)))
                        == [Patch(microphone: "MacBook Pro")],
                     "a switch without a gap notes no gap")
        suite.expect(devices.handle(.microphoneSilent, now: at(210)) == [.notice(.microphoneSilent), .announce(.microphoneSilent)]
                        && devices.handle(.microphoneSilent, now: at(220)).isEmpty,
                     "a silent microphone is said once")
        devices.handle(.microphoneChanged(name: "Studio", gap: 0), now: at(230))
        suite.expect(!devices.handle(.microphoneSilent, now: at(240)).isEmpty,
                     "and again for the next microphone")
    }

    private static func quitting(_ suite: TestSuite) {
        var machine = recording()
        let quit = machine.handle(.appWillTerminate, now: at(600))
        suite.expect(quit == [.writeSidecar(folder, Patch(state: .interrupted, stopReason: .quit)), .stopCapture(token1)],
                     "quitting while recording writes interrupted first, then stops the capture")
        suite.expect(isStopping(machine, .quit), "quitting goes through stopping too")
        let closed = machine.handle(.writerFinished(token1, .finished(recordedSeconds: 600)), now: at(601))
        suite.expect(closed == [.writeSidecar(folder, Patch(endedAt: at(600), recordedSeconds: 600)), .showPill(.hidden)]
                        && !finalizes(closed),
                     "a file closed in time gets its end, but no final pass while the app quits: the next launch does it")
        suite.expect(machine.handle(request(), now: at(602)).isEmpty, "nothing starts while the app quits")

        var paused = recording()
        paused.handle(.pause, now: at(100))
        suite.expect(paused.handle(.appWillTerminate, now: at(160)).first
                        == .writeSidecar(folder, Patch(state: .interrupted, stopReason: .quit,
                                                       pause: .init(at: 100, seconds: 60, reason: .user))),
                     "quitting during a pause writes the pause with it")

        var closing = recording()
        closing.handle(.stop, now: at(50))
        suite.expect(closing.handle(.appWillTerminate, now: at(51)) == [.writeSidecar(folder, Patch(state: .interrupted))],
                     "quitting while the file closes marks it for the next launch")
        suite.expect(!finalizes(closing.handle(.writerFinished(token1, .finished(recordedSeconds: 50)), now: at(52))),
                     "and leaves the final pass to it")

        var starting = Machine()
        starting.handle(request(), now: t0)
        suite.expect(starting.handle(.appWillTerminate, now: at(1)) == [.stopCapture(token1), .showPill(.hidden)]
                        && starting.phase == .idle,
                     "quitting during a start cancels it")
        var idle = Machine()
        suite.expect(idle.handle(.appWillTerminate, now: t0).isEmpty, "quitting with no meeting does nothing")
    }

    private static func featureOff(_ suite: TestSuite) {
        var machine = recording()
        let off = machine.handle(.featureDisabled, now: at(42))
        suite.expect(stoppedFile(off) && patches(off) == [Patch(stopReason: .featureDisabled)],
                     "turning Meetings off stops the recording")
        suite.expect(finalizes(machine.handle(.writerFinished(token1, .finished(recordedSeconds: 42)), now: at(43))),
                     "and keeps its file: it is finalized like any other")
        var starting = Machine()
        starting.handle(request(), now: t0)
        suite.expect(starting.handle(.featureDisabled, now: at(1)) == [.stopCapture(token1), .showPill(.hidden)],
                     "turning Meetings off during a start cancels it")
        var idle = Machine()
        suite.expect(idle.handle(.featureDisabled, now: t0).isEmpty, "turning it off with no meeting does nothing")
    }

    /// Every event, from a recording and from a pause: whatever leaves them
    /// goes through stopping, and nothing ever finalizes twice.
    private static func invariants(_ suite: TestSuite) {
        let events: [Machine.Event] = [
            request(), .pause, .resume, .stop, .captureStarted(token1, folder: folder),
            .captureFailed(token1, .streamStopped), .captureFailed(token1, .writerFailed),
            .captureFailed(ForkMeetingToken(value: 9), .streamStopped),
            .writerFinished(token1, .finished(recordedSeconds: 1)), .writerFinished(token1, .failed(.writerFailed)),
            .willSleep, .didWake, .locked, .unlocked, .diskLow(freeBytes: 1_000_000_000), .diskLow(freeBytes: 1),
            .diskCritical, .permissionLost(.screenRecording), .permissionLost(.microphone), .permissionLost(.systemAudio),
            .displayChanged, .microphoneChanged(name: "X", gap: 1), .microphoneSilent, .appWillTerminate, .featureDisabled,
        ]
        var throughStopping = true
        for start in ["recording", "paused", "sleeping"] {
            for event in events {
                var machine = recording()
                if start == "paused" { machine.handle(.pause, now: at(5)) }
                if start == "sleeping" { machine.handle(.willSleep, now: at(5)) }
                machine.handle(event, now: at(10))
                switch machine.phase {
                case .recording, .paused, .stopping, .endingSoon: break
                case .idle, .offering, .starting: throughStopping = false
                }
            }
        }
        suite.expect(throughStopping, "from a recording or a pause, every event leads to recording, paused or stopping, never straight to idle")

        var finalizeCount = 0
        var endedAfterFailure = false
        for first in events {
            for second in events {
                var machine = recording()
                var all = machine.handle(first, now: at(10))
                all += machine.handle(second, now: at(20))
                all += machine.handle(.writerFinished(token1, .finished(recordedSeconds: 20)), now: at(30))
                all += machine.handle(.writerFinished(token1, .finished(recordedSeconds: 20)), now: at(31))
                finalizeCount = max(finalizeCount, all.filter { if case .beginFinalize = $0 { return true }; return false }.count)
                var failing = recording()
                var failed = failing.handle(first, now: at(10))
                failed += failing.handle(.stop, now: at(15))
                failed += failing.handle(.writerFinished(token1, .failed(.writerFailed)), now: at(20))
                if patches(failed).contains(where: { $0.endedAt != nil }) { endedAfterFailure = true }
            }
        }
        suite.expect(finalizeCount == 1, "whatever happens, a session is handed to the finalizer once and only once")
        suite.expect(!endedAfterFailure, "a session whose file failed to close never gets an end time")
    }
}
