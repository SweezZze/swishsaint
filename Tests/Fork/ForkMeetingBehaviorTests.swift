// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Behaviour written from the plan (§3.2, §5.2, §5.5, §5.6, §12.1) and the
/// decisions taken on the way, independently of the tests each part came
/// with: long realistic sessions, events in an unlucky order, hostile titles
/// and files, and the recovery's table played launch after launch.
enum ForkMeetingBehaviorTests {
    typealias Machine = ForkMeetingMachine
    typealias Patch = ForkMeetingSidecarPatch
    typealias Plan = ForkMeetingRecoveryPlan
    typealias Media = ForkMeetingRecoveryPlan.Media

    static func run(_ suite: TestSuite) {
        longSession(suite)
        longSessionOnItsOwn(suite)
        userPauseIsTheUsers(suite)
        oneStopCapture(suite)
        lateWriterAnswers(suite)
        noFinalizeAfterFailure(suite)
        featureOffInEveryPhase(suite)
        quitWhilePaused(suite)
        hostileTitles(suite)
        collisions(suite)
        damagedSidecars(suite)
        unknownKeysSurvive(suite)
        recoveryTable(suite)
        failedPassesLaunchAfterLaunch(suite)
        largeNumbers(suite)
        updatesWaitForMeetings(suite)
        seams(suite)
    }

    // MARK: - Fixtures

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let folder = URL(fileURLWithPath: "/tmp/Meetings/2026-10-18 10h02", isDirectory: true)
    private static let second = URL(fileURLWithPath: "/tmp/Meetings/2026-10-18 11h00", isDirectory: true)
    private static let settings = ForkMeetingCaptureSettings(target: .window, systemAudio: .app, microphone: "meeting",
                                                             quality: .standard)
    private static let ready = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                     microphoneAllowed: true, officialRecorderBusy: false)
    private static let token1 = ForkMeetingToken(value: 1)
    private static let token2 = ForkMeetingToken(value: 2)

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static var start: Machine.Event {
        .manualStart(ForkMeetingStartRequest(settings: settings, facts: ready))
    }

    private static func recording(at seconds: TimeInterval = 0) -> Machine {
        var machine = Machine()
        machine.handle(start, now: at(seconds))
        machine.handle(.captureStarted(token1, folder: folder), now: at(seconds))
        return machine
    }

    private static func count(_ effects: [Machine.Effect], _ match: (Machine.Effect) -> Bool) -> Int {
        effects.filter(match).count
    }

    private static func isStopCapture(_ effect: Machine.Effect) -> Bool {
        if case .stopCapture = effect { return true }
        return false
    }

    private static func isFinalize(_ effect: Machine.Effect) -> Bool {
        if case .beginFinalize = effect { return true }
        return false
    }

    private static func patches(_ effects: [Machine.Effect]) -> [Patch] {
        effects.compactMap {
            if case let .writeSidecar(_, patch) = $0 { return patch }
            return nil
        }
    }

    private static func phaseName(_ machine: Machine) -> String {
        switch machine.phase {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case let .paused(_, reason): return "paused(\(reason))"
        case let .stopping(_, reason): return "stopping(\(reason))"
        }
    }

    private static func firstSidecar() -> ForkMeetingSidecar {
        ForkMeetingSidecar.started(id: UUID(), startedAt: at(1), origin: .manual, title: nil, titleSource: nil,
                                   capture: .init(target: .window, systemAudio: .app, microphone: "MacBook Pro",
                                                  quality: .standard))
    }

    // MARK: - Machine

    /// Start, pause, sleep, wake, lock, unlock, microphone, disk, stop, file
    /// closed: every effect, in its order, and the meeting.json they build.
    private static func longSession(_ suite: TestSuite) {
        var machine = Machine()
        var written = firstSidecar()
        func run(_ event: Machine.Event, _ seconds: TimeInterval) -> [Machine.Effect] {
            let effects = machine.handle(event, now: at(seconds))
            for patch in patches(effects) { written = patch.applied(to: written) }
            return effects
        }
        let config = ForkMeetingCaptureConfig(origin: .manual, title: nil, settings: settings, recordsMicrophone: true,
                                              microphoneDenied: false)
        var steps: [(String, Bool)] = []
        func step(_ name: String, _ ok: Bool) { steps.append((name, ok)) }

        step("start", run(start, 0) == [.startCapture(config, token1)])
        step("captureStarted", run(.captureStarted(token1, folder: folder, target: .window, microphone: "MacBook Pro"), 1)
                == [.writeSidecar(folder, Patch(microphone: "MacBook Pro")),
                    .showPill(.recording(.init(recordedBefore: 0, runningSince: at(1)), diskMinutesLeft: nil)),
                    .notice(.started), .announce(.started)])
        step("pause", run(.pause, 601)
                == [.pauseCapture(.user), .showPill(.paused(.init(recordedBefore: 600, runningSince: nil), .user,
                                                            diskMinutesLeft: nil)),
                    .announce(.paused)])
        step("willSleep", run(.willSleep, 661) == [.pauseCapture(.sleep)])
        step("didWake", run(.didWake, 3661).isEmpty)
        step("locked", run(.locked, 3662).isEmpty)
        step("unlocked", run(.unlocked, 3700).isEmpty)
        step("resume", run(.resume, 3710)
                == [.restartStream, .resumeCapture,
                    .writeSidecar(folder, Patch(pause: .init(at: 600, seconds: 3109, reason: .user))),
                    .showPill(.recording(.init(recordedBefore: 600, runningSince: at(3710)), diskMinutesLeft: nil)),
                    .announce(.resumed)])
        let airpods = "AirPods d’Alice"
        step("microphoneChanged", run(.microphoneChanged(name: airpods, gap: 1.5), 3770)
                == [.writeSidecar(folder, Patch(gap: .init(at: 658.5, seconds: 1.5, kind: .microphoneSwitch),
                                                microphone: airpods)),
                    .notice(.microphone(airpods)), .announce(.microphone(airpods))])
        let minutes = ForkMeetingDisk.minutesLeft(freeBytes: 1_500_000_000, quality: .standard)
        step("diskLow", run(.diskLow(freeBytes: 1_500_000_000), 3800)
                == [.showPill(.recording(.init(recordedBefore: 600, runningSince: at(3710)), diskMinutesLeft: minutes)),
                    .notice(.diskLow(minutesLeft: minutes)), .announce(.diskLow(minutesLeft: minutes))])
        step("stop", run(.stop, 3900)
                == [.stopCapture(token1), .writeSidecar(folder, Patch(stopReason: .user)), .showPill(.stopping),
                    .announce(.stopped)])
        step("writerFinished", run(.writerFinished(token1, .finished(recordedSeconds: nil)), 3901)
                == [.writeSidecar(folder, Patch(state: .finalizing, endedAt: at(3900), recordedSeconds: 790)),
                    .beginFinalize(folder), .showPill(.finalizing)])
        let failed = steps.filter { !$0.1 }.map(\.0)
        suite.expect(failed.isEmpty, "a long meeting by hand gives exactly the effects of the plan, in order; wrong at: \(failed)")
        suite.expect(machine.phase == .idle, "and once its file is closed the machine is free")

        suite.expect(written.state == .finalizing && written.stopReason == .user && written.endedAt == at(3900)
                        && written.recordedSeconds == 790
                        && written.pauses == [.init(at: 600, seconds: 3109, reason: .user)]
                        && written.gaps == [.init(at: 658.5, seconds: 1.5, kind: .microphoneSwitch)]
                        && written.capture?.microphone == airpods && written.capture?.target == .window
                        && written.recovered == false,
                     "meeting.json then tells the whole story: one pause of the person's, the sleep inside it, one microphone gap, the stop")
        suite.expect(machine.handle(start, now: at(3902)).first.map { if case .startCapture(_, token2) = $0 { return true }; return false } == true,
                     "the next meeting may start while this one is finalized")
    }

    /// The same Mac events without the person's pause: the sleep pauses on its
    /// own, the wake resumes and says so, the lock is a gap.
    private static func longSessionOnItsOwn(_ suite: TestSuite) {
        var machine = recording()
        var written = firstSidecar()
        func run(_ event: Machine.Event, _ seconds: TimeInterval) -> [Machine.Effect] {
            let effects = machine.handle(event, now: at(seconds))
            for patch in patches(effects) { written = patch.applied(to: written) }
            return effects
        }
        let sleep = run(.willSleep, 100)
        suite.expect(sleep == [.pauseCapture(.sleep),
                               .showPill(.paused(.init(recordedBefore: 100, runningSince: nil), .sleep, diskMinutesLeft: nil)),
                               .announce(.paused)],
                     "the Mac going to sleep pauses the recording")
        let wake = run(.didWake, 700)
        suite.expect(wake == [.restartStream, .resumeCapture,
                              .writeSidecar(folder, Patch(pause: .init(at: 100, seconds: 600, reason: .sleep))),
                              .showPill(.recording(.init(recordedBefore: 100, runningSince: at(700)), diskMinutesLeft: nil)),
                              .notice(.resumed), .announce(.resumed)],
                     "the wake resumes a meeting started by hand, on a new stream, and says « Recording resumed »")
        suite.expect(run(.locked, 760).isEmpty && run(.unlocked, 790)
                        == [.writeSidecar(folder, Patch(gap: .init(at: 160, seconds: 30, kind: .screenLocked)))],
                     "a lock afterwards pauses nothing and is noted as a gap")
        _ = run(.microphoneChanged(name: "MacBook Pro", gap: 0), 800)
        _ = run(.diskLow(freeBytes: 1_200_000_000), 810)
        let critical = run(.diskLow(freeBytes: 300_000_000), 825)
        suite.expect(count(critical, isStopCapture) == 1 && patches(critical) == [Patch(stopReason: .disk)]
                        && critical.contains(.notice(.failure(.diskFull))) && !critical.contains(.announce(.stopped)),
                     "under 500 MB it stops by itself, says why, file kept")
        let closed = run(.writerFinished(token1, .finished(recordedSeconds: 225)), 826)
        suite.expect(count(closed, isFinalize) == 1 && written.state == .finalizing && written.stopReason == .disk
                        && written.endedAt == at(825) && written.recordedSeconds == 225
                        && written.pauses == [.init(at: 100, seconds: 600, reason: .sleep)]
                        && written.gaps == [.init(at: 160, seconds: 30, kind: .screenLocked)]
                        && written.capture?.microphone == "MacBook Pro",
                     "and its meeting.json has the sleep as a pause, the lock as a gap, the disk as the reason")
    }

    /// A pause the person chose is theirs: no wake, no unlock, nothing the Mac
    /// does ends it.
    private static func userPauseIsTheUsers(_ suite: TestSuite) {
        let macEvents: [Machine.Event] = [.willSleep, .didWake, .locked, .unlocked, .displayChanged,
                                          .microphoneChanged(name: "X", gap: 0.5), .microphoneSilent,
                                          .diskLow(freeBytes: 1_500_000_000), .diskLow(freeBytes: 5_000_000_000),
                                          .permissionLost(.microphone), .permissionLost(.systemAudio),
                                          .sourceGone(token1), .captureStarted(token1, folder: folder)]
        var resumed: [String] = []
        // Every order of up to three of them, after the pause.
        for a in macEvents {
            for b in macEvents {
                for c in [Machine.Event.didWake, .unlocked] {
                    var machine = recording()
                    machine.handle(.pause, now: at(10))
                    var effects = machine.handle(a, now: at(20))
                    effects += machine.handle(b, now: at(30))
                    effects += machine.handle(c, now: at(40))
                    let stillPaused: Bool = { if case .paused(_, .user) = machine.phase { return true }; return false }()
                    if !stillPaused || effects.contains(.resumeCapture) { resumed.append("\(a) → \(b) → \(c)") }
                }
            }
        }
        suite.expect(resumed.isEmpty, "after the person's pause, no sleep, wake, lock or unlock resumes it: \(resumed.prefix(3))")

        var machine = recording()
        machine.handle(.pause, now: at(10))
        machine.handle(.willSleep, now: at(20))
        machine.handle(.didWake, now: at(80))
        machine.handle(.locked, now: at(81))
        machine.handle(.unlocked, now: at(90))
        let resume = machine.handle(.resume, now: at(100))
        suite.expect(resume.prefix(2) == [.restartStream, .resumeCapture]
                        && patches(resume) == [Patch(pause: .init(at: 10, seconds: 90, reason: .user))]
                        && !resume.contains(.notice(.resumed)),
                     "only the person resumes it, on a new stream; the pause is written as theirs, with the sleep inside")
    }

    /// Two ways of stopping, one after the other: the capture is stopped once.
    private static func oneStopCapture(_ suite: TestSuite) {
        let stops: [Machine.Event] = [.stop, .featureDisabled, .diskCritical, .diskLow(freeBytes: 1),
                                      .permissionLost(.screenRecording), .captureFailed(token1, .streamStopped),
                                      .captureFailed(token1, .screenRecordingDenied), .appWillTerminate]
        var twice: [String] = []
        for from in ["recording", "paused", "asleep"] {
            for first in stops {
                for again in stops {
                    var machine = recording()
                    if from == "paused" { machine.handle(.pause, now: at(5)) }
                    if from == "asleep" { machine.handle(.willSleep, now: at(5)) }
                    var effects = machine.handle(first, now: at(10))
                    effects += machine.handle(again, now: at(11))
                    effects += machine.handle(.stop, now: at(12))
                    if count(effects, isStopCapture) != 1 { twice.append("\(from): \(first) then \(again)") }
                }
            }
        }
        suite.expect(twice.isEmpty, "two stops, of any kind, stop the capture exactly once: \(twice.prefix(3))")

        var starting = Machine()
        starting.handle(start, now: t0)
        var effects = starting.handle(.stop, now: at(1))
        effects += starting.handle(.stop, now: at(2))
        effects += starting.handle(.featureDisabled, now: at(3))
        suite.expect(count(effects, isStopCapture) == 1 && starting.phase == .idle,
                     "a start cancelled twice is stopped once")
    }

    /// The writer of a meeting answering late, once the next one has started.
    private static func lateWriterAnswers(_ suite: TestSuite) {
        var machine = recording()
        machine.handle(.stop, now: at(10))
        machine.handle(.writerFinished(token1, .finished(recordedSeconds: 10)), now: at(11))
        machine.handle(start, now: at(12))
        suite.expect(machine.handle(.writerFinished(token1, .finished(recordedSeconds: 10)), now: at(13)).isEmpty
                        && machine.handle(.writerFinished(token1, .failed(.writerFailed)), now: at(13)).isEmpty
                        && phaseName(machine) == "starting",
                     "a second answer of the first writer during the next start does nothing")
        machine.handle(.captureStarted(token2, folder: second), now: at(14))
        let late = machine.handle(.writerFinished(token1, .finished(recordedSeconds: 10)), now: at(15))
        suite.expect(late.isEmpty && machine.activeSession?.folder == second && phaseName(machine) == "recording",
                     "nor during the next recording: it neither stops it nor finalizes anything")
        machine.handle(.stop, now: at(20))
        let done = machine.handle(.writerFinished(token2, .finished(recordedSeconds: 6)), now: at(21))
        suite.expect(done.contains(.beginFinalize(second)) && !done.contains(.beginFinalize(folder)),
                     "the second meeting is finalized in its own folder")

        // A start cancelled before it ran, whose engine still answers.
        var cancelled = Machine()
        cancelled.handle(start, now: t0)
        cancelled.handle(.stop, now: at(1))
        cancelled.handle(start, now: at(2))
        let stale = cancelled.handle(.writerFinished(token1, .finished(recordedSeconds: 1)), now: at(3))
            + cancelled.handle(.captureStarted(token1, folder: folder), now: at(3))
            + cancelled.handle(.captureFailed(token1, .captureFailed), now: at(3))
        suite.expect(stale.isEmpty && phaseName(cancelled) == "starting",
                     "the answers of a cancelled start never touch the start that followed it")
        cancelled.handle(.captureStarted(token2, folder: second), now: at(4))
        suite.expect(cancelled.activeSession?.token == token2 && cancelled.activeSession?.folder == second,
                     "which records under its own token")
    }

    /// A file that did not close: never handed to the final pass, never an end.
    private static func noFinalizeAfterFailure(_ suite: TestSuite) {
        let routes: [Machine.Event] = [.stop, .featureDisabled, .diskCritical, .permissionLost(.screenRecording),
                                       .captureFailed(token1, .streamStopped), .appWillTerminate]
        var wrong: [String] = []
        for from in ["recording", "paused", "asleep", "locked"] {
            for route in routes {
                var machine = recording()
                if from == "paused" { machine.handle(.pause, now: at(5)) }
                if from == "asleep" { machine.handle(.willSleep, now: at(5)) }
                if from == "locked" { machine.handle(.locked, now: at(5)) }
                var effects = machine.handle(route, now: at(10))
                if case .stopping = machine.phase {} else { machine.handle(.stop, now: at(11)) }
                effects += machine.handle(.writerFinished(token1, .failed(.writerFailed)), now: at(12))
                let ended = patches(effects).contains { $0.endedAt != nil }
                let interrupted = patches(effects).last?.state == .interrupted
                if count(effects, isFinalize) > 0 || ended || !interrupted || machine.phase != .idle {
                    wrong.append("\(from) · \(route)")
                }
            }
        }
        suite.expect(wrong.isEmpty,
                     "whatever stopped it, a file that failed to close is marked interrupted, without an end, never finalized: \(wrong)")

        var machine = recording()
        var all = machine.handle(.pause, now: at(5))
        all += machine.handle(.resume, now: at(6))
        all += machine.handle(.locked, now: at(7))
        all += machine.handle(.unlocked, now: at(8))
        all += machine.handle(.stop, now: at(9))
        suite.expect(patches(all).allSatisfy { $0.endedAt == nil },
                     "no end time is written before the file is closed")
        machine.handle(.writerFinished(token1, .failed(.writerFailed)), now: at(10))
        suite.expect(machine.handle(start, now: at(11)).first.map { if case .startCapture = $0 { return true }; return false } == true,
                     "after a failed file, the next meeting may start")
    }

    /// Turning Meetings off in every phase: whatever was recorded is kept.
    private static func featureOffInEveryPhase(_ suite: TestSuite) {
        var starting = Machine()
        starting.handle(start, now: t0)
        suite.expect(starting.handle(.featureDisabled, now: at(1)) == [.stopCapture(token1), .showPill(.hidden)]
                        && starting.phase == .idle,
                     "off during a start: cancelled, nothing was recorded")

        for reason in [ForkMeetingPauseReason.user, .sleep] {
            var paused = recording()
            paused.handle(reason == .user ? .pause : .willSleep, now: at(30))
            let off = paused.handle(.featureDisabled, now: at(50))
            suite.expect(off.first == .stopCapture(token1)
                            && patches(off) == [Patch(stopReason: .featureDisabled, pause: .init(at: 30, seconds: 20, reason: reason))]
                            && phaseName(paused) == "stopping(featureDisabled)",
                         "off during a pause (\(reason)): stopped, the pause written, file kept")
            let closed = paused.handle(.writerFinished(token1, .finished(recordedSeconds: 30)), now: at(51))
            suite.expect(closed.contains(.beginFinalize(folder)) && paused.handle(.didWake, now: at(52)).isEmpty,
                         "and finalized; a wake afterwards resumes nothing")
        }

        var stopping = recording()
        stopping.handle(.stop, now: at(10))
        let off = stopping.handle(.featureDisabled, now: at(11))
        suite.expect(off.isEmpty && phaseName(stopping) == "stopping(user)",
                     "off while the file closes: nothing more to stop, the reason stays the person's")
        suite.expect(count(stopping.handle(.writerFinished(token1, .finished(recordedSeconds: 10)), now: at(12)), isFinalize) == 1,
                     "and the file is still finalized, once")
    }

    /// ⌘Q during a pause, the person's or the sleep's.
    private static func quitWhilePaused(_ suite: TestSuite) {
        for reason in [ForkMeetingPauseReason.user, .sleep] {
            var machine = recording()
            machine.handle(reason == .user ? .pause : .willSleep, now: at(100))
            let quit = machine.handle(.appWillTerminate, now: at(160))
            suite.expect(quit == [.writeSidecar(folder, Patch(state: .interrupted, stopReason: .quit,
                                                              pause: .init(at: 100, seconds: 60, reason: reason))),
                                  .stopCapture(token1)],
                         "⌘Q during a pause (\(reason)): interrupted, quit and the pause written first, then the capture stopped")
            let after = machine.handle(.didWake, now: at(161)) + machine.handle(.resume, now: at(161))
                + machine.handle(start, now: at(161)) + machine.handle(.appWillTerminate, now: at(161))
            suite.expect(!after.contains(.resumeCapture) && count(after, isStopCapture) == 0
                            && !after.contains { if case .startCapture = $0 { return true }; return false },
                         "then nothing resumes, nothing starts, nothing is stopped twice")
            let closed = machine.handle(.writerFinished(token1, .finished(recordedSeconds: 100)), now: at(162))
            suite.expect(closed == [.writeSidecar(folder, Patch(endedAt: at(160), recordedSeconds: 100)), .showPill(.hidden)],
                         "a file closed in time gets its end and length, and waits for the next launch's final pass")
        }
        var failing = recording()
        failing.handle(.pause, now: at(10))
        failing.handle(.appWillTerminate, now: at(20))
        let failed = failing.handle(.writerFinished(token1, .failed(.writerFailed)), now: at(21))
        suite.expect(patches(failed) == [Patch(state: .interrupted)] && count(failed, isFinalize) == 0,
                     "⌘Q during a pause with a file that fails to close: interrupted, no end")
    }

    // MARK: - Folder

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return Calendar(identifier: .gregorian).date(from: parts) ?? t0
    }

    private static func createsOnDisk(_ name: String) -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForkMeetingBehaviorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("\(name) (50)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: target.appendingPathComponent("\(name) (50).mp4"))
            try Data("x".utf8).write(to: target.appendingPathComponent("\(name) (50).m4a"))
            return true
        } catch {
            return false
        }
    }

    private static func hostileTitles(_ suite: TestSuite) {
        let started = date(2026, 10, 18, 10, 2)
        let stamp = ForkMeetingFolder.stamp(started)
        let forbidden = ["/", ":", "/:/:/:", "\u{0}\u{1}\u{1B}\u{7F}", " / : / ", "\n\r\t", "\u{2028}\u{2029}",
                         "/.:.", "— — —", "...---", "\u{3000}\u{3000}"]
        suite.expect(forbidden.allSatisfy { ForkMeetingFolder.sanitized($0) == nil
                        && ForkMeetingFolder.name(startedAt: started, title: $0) == stamp },
                     "a title made only of forbidden characters, blanks or dashes gives the stamp alone")
        suite.expect(ForkMeetingFolder.renamedFolder(current: stamp, startedAt: started, title: "/::/") == nil,
                     "and never renames a folder to it")
        let mixed = ForkMeetingFolder.name(startedAt: started, title: "\u{7}Point\u{0}hebdo/Acme:\u{1B}Q4")
        suite.expect(mixed == "\(stamp) — Point hebdo Acme Q4" && !mixed.unicodeScalars.contains { $0.value < 0x20 },
                     "control characters inside a title become spaces, never part of a file name")

        let emoji = "Lancement 🚀 v2 🇫🇷 ❤️ 👍🏽"
        suite.expect(ForkMeetingFolder.name(startedAt: started, title: emoji) == "\(stamp) — \(emoji)",
                     "emoji, flags, variation selectors and skin tones stay as written")
        // The zero-width joiner is a format character (Cf), not a control
        // one (Cc): only the latter is refused.
        let joined = "Équipe 👨‍👩‍👧‍👦 🏳️‍🌈"
        suite.expect(ForkMeetingFolder.name(startedAt: started, title: joined) == "\(stamp) — \(joined)",
                     "emoji joined by a zero-width joiner stay whole")
        let formats = "co\u{00AD}op می\u{200C}خواهم"
        suite.expect(ForkMeetingFolder.sanitized(formats) == formats,
                     "a soft hyphen or a zero-width non-joiner stays where the person wrote it")
        let families = String(repeating: "👨‍👩‍👧‍👦", count: 70)
        let familyName = ForkMeetingFolder.name(startedAt: started, title: families)
        suite.expect(familyName.hasPrefix(stamp)
                        && ForkMeetingFolder.units(familyName) <= ForkMeetingFolder.componentLimit - ForkMeetingFolder.reservedUnits
                        && createsOnDisk(familyName),
                     "seventy emoji families give a name under the file system's limit, created with its media")
        let familyTitle = familyName.components(separatedBy: " — ").dropFirst().first ?? ""
        suite.expect(!familyTitle.isEmpty && familyTitle.allSatisfy { $0 == "👨‍👩‍👧‍👦" },
                     "seventy emoji families are cut between families, never inside one")

        let japanese = String(String(repeating: "週次定例ミーティング・プロジェクトがぎぐげご", count: 20).prefix(300))
        let japaneseName = ForkMeetingFolder.name(startedAt: started, title: japanese)
        suite.expect(japanese.count == 300 && japaneseName.hasPrefix(stamp + " — ")
                        && japanese.hasPrefix(japaneseName.components(separatedBy: " — ").last ?? "-")
                        && ForkMeetingFolder.units(japaneseName) <= ForkMeetingFolder.componentLimit - ForkMeetingFolder.reservedUnits
                        && createsOnDisk(japaneseName),
                     "a 300-character Japanese title is cut on whole characters, voiced kana kept whole, and the folder, its video and its audio are created")
        let voiced = String(repeating: "が", count: 300)
        let voicedName = ForkMeetingFolder.name(startedAt: started, title: voiced)
        suite.expect(ForkMeetingFolder.units(voicedName) <= ForkMeetingFolder.componentLimit - ForkMeetingFolder.reservedUnits
                        && voicedName.hasSuffix("が") && createsOnDisk(voicedName),
                     "kana that decompose to two units are counted as two: the name stays under 255 decomposed units")
        let ideographicSpaces = ForkMeetingFolder.sanitized("定例\u{3000}会議")
        suite.expect(ideographicSpaces == "定例 会議", "an ideographic space is a space")
    }

    private static func collisions(_ suite: TestSuite) {
        let base = "2026-10-18 10h02 — Point hebdo"
        var asked: [String] = []
        let last = ForkMeetingFolder.reserve(base: base) { name in
            asked.append(name)
            return name == "\(base) (50)" ? .free : .taken
        }
        suite.expect(last == .create("\(base) (50)"), "the fiftieth name is still offered")
        asked = []
        let none = ForkMeetingFolder.reserve(base: base) { name in
            asked.append(name)
            return .taken
        }
        suite.expect(none == .exhausted && asked.count == 50 && !asked.contains("\(base) (51)")
                        && Set(asked).count == 50,
                     "past (50) it stops and says so: fifty names looked at once each, never a fifty-first")
        suite.expect(ForkMeetingFolder.reserve(base: base, forRename: true) {
                        $0 == "\(base) (50)" ? .folderWithoutSidecar : .taken
                     } == .exhausted,
                     "a rename never merges into a folder, even the last one")
        suite.expect(ForkMeetingFolder.reserve(base: base) { $0 == "\(base) (50)" ? .sameMeeting : .taken } == .adopt("\(base) (50)"),
                     "a meeting that already owns (50) takes it back")
    }

    // MARK: - Sidecar

    private static func damagedSidecars(_ suite: TestSuite) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForkMeetingBehaviorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(ForkMeetingFolder.sidecarName)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: url)
            let empty = ForkMeetingSidecar.read(at: url)
            let isCorrupt: Bool = { if case .failure(.corrupt) = empty { return true }; return false }()
            suite.expect(isCorrupt && ForkMeetingSidecar.rewriting(empty, with: Patch(state: .complete)) == nil,
                         "an empty meeting.json on the disk is corrupt, not absent, and never rewritten")
        } catch {
            suite.expect(false, "temporary sidecar: \(error)")
        }

        var full = firstSidecar()
        full = Patch(state: .finalizing, stopReason: .user, endedAt: at(600), recordedSeconds: 599,
                     pause: .init(at: 10, seconds: 5, reason: .user),
                     gap: .init(at: 20, seconds: 1, kind: .microphoneSwitch)).applied(to: full)
        full.title = "Point hebdo « Acme »"
        let bytes = (try? full.encoded()) ?? Data()
        var decodedPrefixes: [Int] = []
        for length in 0..<bytes.count {
            if case .success = ForkMeetingSidecar.decode(bytes.prefix(length)) { decodedPrefixes.append(length) }
        }
        suite.expect(bytes.count > 200 && decodedPrefixes.isEmpty,
                     "a meeting.json cut at any of its \(bytes.count) bytes (a disk full mid-write) never reads as a sidecar: \(decodedPrefixes.prefix(3))")
        for text in ["null", "true", "42", "{\"state\": ", "{\"state\": \"recording\"", "\u{FEFF}"] {
            let result = ForkMeetingSidecar.decode(Data(text.utf8))
            suite.expect(ForkMeetingSidecar.rewriting(result, with: Patch(state: .interrupted)) == nil,
                         "\(text) is never rewritten")
        }
    }

    /// Keys from a later version, at the top and inside the objects, survive
    /// a patch of this one and a rewrite.
    private static func unknownKeysSurvive(_ suite: TestSuite) {
        let json = """
        {"schema": 1, "id": "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8", "state": "recording", "origin": "manual",
         "startedAt": "2026-10-18T08:02:11Z", "recordedSeconds": 0, "pauses": [], "gaps": [],
         "capture": {"target": "window", "systemAudio": "app", "microphone": "MacBook Pro", "quality": "standard"},
         "x-other": {"job": "t-42", "steps": [1, 2, {"done": true}]}, "futureFlag": false, "labels": ["a", "b"]}
        """
        guard case let .success(read) = ForkMeetingSidecar.decode(Data(json.utf8)) else {
            suite.expect(false, "a sidecar with a later version's keys reads")
            return
        }
        let patch = Patch(state: .finalizing, stopReason: .user, endedAt: at(60), recordedSeconds: 60,
                          pause: .init(at: 1, seconds: 2, reason: .user), gap: .init(at: 3, seconds: 0, kind: .targetSwitch),
                          microphone: "AirPods")
        guard let next = ForkMeetingSidecar.rewriting(.success(read), with: patch),
              let bytes = try? next.encoded(),
              case let .success(back) = ForkMeetingSidecar.decode(bytes) else {
            suite.expect(false, "a sidecar of this version takes a patch")
            return
        }
        suite.expect(back.preserved["x-other"] == read.preserved["x-other"] && back.preserved["futureFlag"] == .bool(false)
                        && back.preserved["labels"] == .array([.string("a"), .string("b")]) && back.preserved.count == 3,
                     "unknown top-level keys are written back as they were after a patch")
        suite.expect(back.state == .finalizing && back.pauses?.count == 1 && back.gaps?.count == 1
                        && back.capture?.microphone == "AirPods" && back.capture?.quality == .standard,
                     "and the patch itself applies")

        let nested = """
        {"schema": 1, "state": "recording",
         "capture": {"target": "window", "quality": "standard", "fps": 30},
         "pauses": [{"at": 1, "seconds": 2, "reason": "user", "by": "pill"}],
         "gaps": [{"at": 3, "seconds": 1, "kind": "microphoneSwitch", "device": "uid-1"}],
         "exports": [{"exporter": "dropFolder", "status": "done", "path": "/Volumes/NAS"}]}
        """
        var kept: [String] = []
        if case let .success(inner) = ForkMeetingSidecar.decode(Data(nested.utf8)),
           let rewritten = ForkMeetingSidecar.rewriting(.success(inner), with: Patch(state: .interrupted)),
           let text = (try? rewritten.encoded()).map({ String(decoding: $0, as: UTF8.self) }) {
            kept = ["\"fps\"", "\"by\"", "\"device\"", "\"path\""].filter { text.contains($0) }
        }
        suite.expect(kept.count == 4,
                     "unknown keys inside the capture, a pause, a gap or an export survive a rewrite: kept \(kept)")
    }

    // MARK: - Recovery

    private static func sidecar(_ state: ForkMeetingSidecar.State, stopReason: ForkMeetingStopReason? = nil,
                                recordedSeconds: Double = 0, finalPass: ForkMeetingSidecar.FinalPass? = nil,
                                recovered: Bool? = false) -> ForkMeetingSidecar {
        var meeting = firstSidecar()
        meeting.state = state
        meeting.stopReason = stopReason
        meeting.recordedSeconds = recordedSeconds
        meeting.finalPass = finalPass
        meeting.recovered = recovered
        return meeting
    }

    /// One launch: what the plan decides, and the sidecar once its patch is
    /// written.
    private static func launch(_ meeting: ForkMeetingSidecar, master: Media?, final: Media? = nil,
                               drafts: Bool = false) -> (Plan.Action, ForkMeetingSidecar) {
        let facts = Plan.Facts(sidecar: .success(meeting), master: master, final: final, hasDrafts: drafts)
        let action = Plan.plan(facts)
        let next = Plan.patch(for: action, facts: facts).map { $0.applied(to: meeting) } ?? meeting
        return (action, next)
    }

    private static func contents(master: Bool = false, final: Bool = false, drafts: Bool = false) -> ForkMeetingFolder.Contents {
        ForkMeetingFolder.Contents(video: final ? "m.mp4" : nil, audio: nil, hasSidecar: true, hasMaster: master,
                                   hasVideoDraft: drafts, hasAudioDraft: false)
    }

    /// The final pass's own writes: complete when it succeeds, the failure
    /// noted otherwise.
    private static let passDone = Patch(state: .complete, finalPass: .done)
    private static let passFailed = Patch(finalPass: .failed)

    private static func recoveryTable(_ suite: TestSuite) {
        // Row 1: recording, readable master of a second or more.
        let crashed = sidecar(.recording, recordedSeconds: 0)
        suite.expect(Plan.needsInspection(.success(crashed), contents: contents(master: true)),
                     "a meeting left recording is inspected at the launch")
        let (crashAction, crashNext) = launch(crashed, master: Media(duration: 2220))
        let crashDone = passDone.applied(to: crashNext)
        suite.expect(crashAction == .finalize(stopReason: .crash, recovered: true, discardDrafts: false)
                        && crashDone.state == .complete && crashDone.recovered == true && crashDone.stopReason == .crash
                        && crashDone.recordedSeconds == 2220 && crashDone.endedAt == nil && crashDone.finalPass == .done,
                     "§5.6 row 1: recording + readable master → final pass, complete, recovered, stopped by a crash, its length the master's, no invented end")
        suite.expect(!Plan.needsInspection(.success(crashDone), contents: contents(final: true)),
                     "once complete, the meeting is not looked at again")

        // Row 1, quit already noted: the machine's own ⌘Q patches.
        var machine = recording()
        var quitSidecar = firstSidecar()
        for patch in patches(machine.handle(.appWillTerminate, now: at(300))) { quitSidecar = patch.applied(to: quitSidecar) }
        for patch in patches(machine.handle(.writerFinished(token1, .finished(recordedSeconds: 299)), now: at(301))) {
            quitSidecar = patch.applied(to: quitSidecar)
        }
        let (quitAction, quitNext) = launch(quitSidecar, master: Media(duration: 299.5))
        suite.expect(quitSidecar.state == .interrupted
                        && Plan.needsInspection(.success(quitSidecar), contents: contents(master: true))
                        && quitAction == .finalize(stopReason: .quit, recovered: true, discardDrafts: false)
                        && passDone.applied(to: quitNext).state == .complete
                        && passDone.applied(to: quitNext).stopReason == .quit,
                     "a ⌘Q while recording, as the machine writes it, is finalized at the next launch, quit kept as the reason")

        // Row 2: recording, master unreadable or gone.
        for master in [Media(duration: nil), nil, Media(duration: 0.3)] as [Media?] {
            let (action, next) = launch(crashed, master: master)
            let again = launch(next, master: master)
            suite.expect(action == .markInterrupted(stopReason: .crash) && next.state == .interrupted
                            && next.endedAt == nil && again.0 == .leave && again.1 == next,
                         "§5.6 row 2: recording without a readable master (\(String(describing: master?.duration))) → interrupted, kept, then left alone")
        }

        // Row 3: finalizing with a draft.
        let cut = sidecar(.finalizing, stopReason: .user, recordedSeconds: 3000)
        let (cutAction, cutNext) = launch(cut, master: Media(duration: 3000), drafts: true)
        suite.expect(cutAction == .finalize(stopReason: .user, recovered: false, discardDrafts: true)
                        && cutNext.recovered == false && cutNext.state == .finalizing,
                     "§5.6 row 3: finalizing + draft → draft dropped, final pass again, not called a recovery")

        // Row 4: a final file and its master.
        let both = sidecar(.finalizing, stopReason: .user, recordedSeconds: 3000)
        let cases: [(Media?, Media?, Plan.Action)] = [
            (Media(duration: 3000), Media(duration: 2970), .complete(removeMaster: true, discardDrafts: false)),
            (Media(duration: 3000), Media(duration: 2969), .finalize(stopReason: .user, recovered: false, discardDrafts: false)),
            (Media(duration: 3000), Media(duration: nil), .finalize(stopReason: .user, recovered: false, discardDrafts: false)),
            (Media(duration: 3000), Media(duration: 0), .finalize(stopReason: .user, recovered: false, discardDrafts: false)),
            (Media(duration: nil), Media(duration: 3000), .complete(removeMaster: false, discardDrafts: false)),
        ]
        for (master, final, expected) in cases {
            suite.expect(launch(both, master: master, final: final).0 == expected,
                         "§5.6 row 4: master \(String(describing: master?.duration)) s, final \(String(describing: final?.duration)) s → \(expected)")
        }

        // Interrupted by a writer that failed to close, as the machine writes it.
        var broken = recording()
        var brokenSidecar = firstSidecar()
        for patch in patches(broken.handle(.stop, now: at(120)) + broken.handle(.writerFinished(token1, .failed(.writerFailed)), now: at(121))) {
            brokenSidecar = patch.applied(to: brokenSidecar)
        }
        let (brokenAction, _) = launch(brokenSidecar, master: Media(duration: 118))
        suite.expect(brokenSidecar.state == .interrupted && brokenSidecar.endedAt == nil
                        && Plan.needsInspection(.success(brokenSidecar), contents: contents(master: true))
                        && brokenAction == .finalize(stopReason: .user, recovered: true, discardDrafts: false),
                     "a file the writer could not close is recovered from its master at the next launch")
        suite.expect(launch(brokenSidecar, master: nil).0 == .leave,
                     "and with nothing readable it stays interrupted, kept")

        // Nothing is ever removed by a markInterrupted or a leave, whatever
        // the folder holds.
        let actions = [ForkMeetingSidecar.State.recording, .finalizing, .complete, .interrupted].flatMap { state in
            [Media(duration: nil), Media(duration: 0.2), nil].map { launch(sidecar(state), master: $0, final: nil, drafts: true).0 }
        }
        suite.expect(actions.allSatisfy {
                        switch $0 {
                        case .leave, .markInterrupted: return true
                        case let .complete(removeMaster, discardDrafts): return !removeMaster && !discardDrafts
                        case let .finalize(_, _, discardDrafts): return !discardDrafts
                        }
                     },
                     "without a readable master or a whole final file, nothing in the folder is removed, drafts included")
    }

    /// A final pass that fails: retried once at the next launch, never at
    /// every one.
    private static func failedPassesLaunchAfterLaunch(_ suite: TestSuite) {
        func attempts(from start: ForkMeetingSidecar, failing: Int) -> (tries: Int, last: ForkMeetingSidecar) {
            var meeting = start
            var tries = 0
            for _ in 0..<6 {
                let (action, next) = launch(meeting, master: Media(duration: 3000))
                meeting = next
                guard case .finalize = action else { continue }
                tries += 1
                meeting = (tries <= failing ? passFailed : passDone).applied(to: meeting)
            }
            return (tries, meeting)
        }
        // The session's own pass failed: `finalizing` + `failed`.
        let session = passFailed.applied(to: sidecar(.finalizing, stopReason: .user, recordedSeconds: 3000))
        let sessionTwice = attempts(from: session, failing: 5)
        suite.expect(sessionTwice.tries == 1 && sessionTwice.last.state == .interrupted
                        && sessionTwice.last.finalPass == .failed,
                     "a pass failed during the session is tried at one launch only; failing again, it stays interrupted")
        let sessionOnce = attempts(from: session, failing: 0)
        suite.expect(sessionOnce.tries == 1 && sessionOnce.last.state == .complete && sessionOnce.last.finalPass == .done,
                     "succeeding at that launch, it is complete")

        // A crash: the launch's first pass, then one retry.
        let crash = sidecar(.recording)
        let crashFailing = attempts(from: crash, failing: 5)
        suite.expect(crashFailing.tries == 2 && crashFailing.last.state == .interrupted
                        && crashFailing.last.recovered == true,
                     "a crashed meeting gets its pass at the next launch and one retry, then is left interrupted, still marked recovered")
        let crashSecond = attempts(from: crash, failing: 1)
        suite.expect(crashSecond.tries == 2 && crashSecond.last.state == .complete && crashSecond.last.recovered == true
                        && crashSecond.last.stopReason == .crash,
                     "failing once then succeeding, it is complete and recovered")

        // The library still sees the master of a meeting left after its last try.
        suite.expect(Plan.needsInspection(.success(crashFailing.last), contents: contents(master: true))
                        && launch(crashFailing.last, master: Media(duration: 3000)).0 == .leave,
                     "after the last try the folder is looked at but nothing is attempted, the master kept")
    }

    // MARK: - Texts

    private static func largeNumbers(_ suite: TestSuite) {
        let languages = AppLanguage.allCases
        let maxMinutes = ForkMeetingQuality.allCases.map {
            ForkMeetingDisk.minutesLeft(freeBytes: ForkMeetingDisk.warningFreeBytes - 1, quality: $0)
        }.max() ?? 0
        let maxGigabytes = ForkMeetingQuality.allCases.map {
            ForkMeetingFailure.gigabytes(ForkMeetingDisk.requiredToStart($0))
        }.max() ?? 0
        var tooLong: [String] = []
        for language in languages {
            let s = ForkMeetingStrings.strings(language)
            for minutes in [0, 1, 59, maxMinutes, 999, 9999] {
                let notice = ForkMeetingNotice.diskLow(minutesLeft: minutes)
                for text in [notice.title(s), notice.detail(s) ?? ""] where text.count > 28 {
                    tooLong.append("\(language.rawValue): \(text)")
                }
                if !s.diskMinutes(minutes).contains("\(minutes)") { tooLong.append("\(language.rawValue): no \(minutes)") }
            }
            for gigabytes in [1, maxGigabytes, 10, 99] {
                let text = ForkMeetingFailure.diskFullAtStart(requiredBytes: Int64(gigabytes) * 1_000_000_000).summary(s)
                if text.count > 28 || !text.contains("\(gigabytes)") { tooLong.append("\(language.rawValue): \(text)") }
            }
            for failure in ForkMeetingFailure.all {
                for text in [failure.summary(s), ForkMeetingNotice.failure(failure).title(s)] where text.count > 28 {
                    tooLong.append("\(language.rawValue): \(text)")
                }
            }
            for (seconds, bytes) in [(10 * 3600 + 59 * 60, Int64(9_990_000_000)), (23 * 3600 + 59 * 60, Int64(99_990_000_000))] {
                let detail = ForkMeetingLiveText.savedDetail(seconds: TimeInterval(seconds), bytes: bytes, language: language)
                if detail.count > 28 { tooLong.append("\(language.rawValue): \(detail)") }
            }
            let clock = ForkMeetingPillLayout.clock(99 * 3600 + 59 * 60 + 59)
            if clock != "99:59:59" { tooLong.append("clock: \(clock)") }
        }
        suite.expect(maxMinutes > 100 && maxGigabytes >= 2, "the largest numbers the disk can give are known")
        suite.expect(tooLong.isEmpty,
                     "every summary and notice, numbers filled in (minutes up to four digits, gigabytes up to two) and day-long meetings, fits in 28 characters in all fifteen languages: \(tooLong)")
    }

    // MARK: - Updates

    /// §3.2 n° 42 and n° 44: the updater waits while a meeting records or a
    /// final pass runs, and hears once when both are over.
    private static func updatesWaitForMeetings(_ suite: TestSuite) {
        let before = ForkMeetingActivity.tally
        guard !before.isBusy else {
            suite.expect(false, "the activity starts idle")
            return
        }
        // An idle posted by an earlier suite is delivered first, unheard.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        var heard = 0
        let observer = NotificationCenter.default.addObserver(forName: ForkMeetingActivity.didBecomeIdle, object: nil,
                                                              queue: nil) { _ in heard += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        // As the service runs it: the final pass is queued while the effects
        // of `writerFinished` run, the recording cleared after them.
        ForkMeetingActivity.setRecording(true)
        ForkMeetingActivity.beginFinalizing()
        ForkMeetingActivity.setRecording(false)
        settle()
        let afterFirst = heard
        // The next meeting starts while the first one is finalized.
        ForkMeetingActivity.setRecording(true)
        ForkMeetingActivity.endFinalizing()
        settle()
        let duringSecond = heard
        ForkMeetingActivity.setRecording(false)
        settle()
        suite.expect(afterFirst == 0 && duringSecond == 0 && heard == 1 && !ForkMeetingActivity.isBusy,
                     "the updater hears « idle » once, when the second meeting ends after the first one's final pass, never in between: \(afterFirst), \(duringSecond), \(heard)")
        ForkMeetingActivity.setRecording(false)
        ForkMeetingActivity.endFinalizing()
        settle()
        suite.expect(heard == 1 && ForkMeetingActivity.tally == before, "an idle app saying idle again posts nothing more")
    }

    // MARK: - Seams

    private static func seams(_ suite: TestSuite) {
        let directory = ForkMeetingFinalizeTests.source("Sources/Vorssaint/UI/Settings/SettingsDirectory.swift")
        let screenshot = directory.range(of: "SettingsDirectoryItem(page: .screenshot,")
        let meetings = directory.range(of: "ForkSettingsPages.item(.meetings, language: language), // FORK(settings4)")
        let next = directory.range(of: "SettingsDirectoryItem(page: .urlCleaner,")
        suite.expect(screenshot != nil && meetings != nil && next != nil
                        && screenshot!.upperBound < meetings!.lowerBound && meetings!.upperBound < next!.lowerBound
                        && directory.components(separatedBy: "ForkSettingsPages.item(.meetings,").count == 2,
                     "the Meetings row sits right after Screen Capture in the Settings sidebar, once")
    }
}
