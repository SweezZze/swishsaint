// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The machine's side of the detection: the offer, "Always", "Never", and
/// the countdown when a meeting probably ended.
enum ForkMeetingDetectionTests {
    typealias Machine = ForkMeetingMachine
    typealias Patch = ForkMeetingSidecarPatch

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let folder = URL(fileURLWithPath: "/tmp/Meetings/2026-10-18 10h02 — Point hebdo", isDirectory: true)
    private static let settings = ForkMeetingCaptureSettings(target: .window, systemAudio: .app, microphone: "meeting",
                                                             quality: .standard)
    private static let ready = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                     microphoneAllowed: true, officialRecorderBusy: false)
    private static let busy = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                    microphoneAllowed: true, officialRecorderBusy: true)
    private static let token1 = ForkMeetingToken(value: 1)
    private static let token2 = ForkMeetingToken(value: 2)
    private static let meetA = ForkMeetingIdentity("meet:abc-defg-hij")
    private static let meetB = ForkMeetingIdentity("meet:xyz-qrst-uvw")

    static func run(_ suite: TestSuite) {
        offering(suite)
        folding(suite)
        answers(suite)
        refusedOffers(suite)
        alwaysAndUndo(suite)
        endingSoon(suite)
        endingSoonInterrupted(suite)
        onlyItsOwnMeeting(suite)
        secondMeeting(suite)
        offerEnds(suite)
        invariants(suite)
        pipeline(suite)
        texts(suite)
    }

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func request(_ facts: ForkMeetingStartFacts = ready) -> ForkMeetingStartRequest {
        ForkMeetingStartRequest(settings: settings, facts: facts)
    }

    private static func candidate(_ identity: ForkMeetingIdentity = meetA, name: String? = "Point hebdo",
                                  policy: ForkMeetingPolicy = .ask, silenced: Bool = false,
                                  bornAt: TimeInterval = 0) -> ForkMeetingCandidate {
        ForkMeetingCandidate(identity: identity, provider: "meet", providerName: "Google Meet", providerShortName: "Meet",
                             titleName: name, meetCode: String(identity.value.dropFirst(5)), calendarTitle: nil,
                             windowTitle: "Meet – Point hebdo", appBundle: "com.google.Chrome", pid: 100, windowID: 1,
                             windowBundle: "com.google.Chrome", defaultSound: .app, policy: policy, silenced: silenced,
                             bornAt: at(bornAt))
    }

    /// The offer of `candidate`, set aside from the moment it shows.
    private static func offer(_ candidate: ForkMeetingCandidate, at seconds: TimeInterval = 0,
                              blocked: ForkMeetingFailure? = nil) -> ForkMeetingOffer {
        var offered = candidate
        offered.silenced = true
        return ForkMeetingOffer(candidate: offered, collapsesAt: at(seconds + 20), blocked: blocked)
    }

    private static func config(_ origin: ForkMeetingOrigin, _ meeting: ForkMeetingCandidate?) -> ForkMeetingCaptureConfig {
        var recorded = meeting
        recorded?.silenced = true
        return ForkMeetingCaptureConfig(origin: origin, title: meeting?.name, settings: settings, recordsMicrophone: true,
                                        microphoneDenied: false, meeting: recorded)
    }

    private static func offered(_ meeting: ForkMeetingCandidate = candidate()) -> Machine {
        var machine = Machine()
        machine.handle(.candidates([meeting], request()), now: t0)
        return machine
    }

    /// A machine recording `meeting` since `t0`, as the offer's Record (or
    /// "Always") started it, with token 1.
    private static func recording(_ origin: ForkMeetingOrigin = .offered,
                                  _ meeting: ForkMeetingCandidate = candidate()) -> Machine {
        var machine = offered(meeting)
        switch origin {
        case .offered: machine.handle(.accept(request()), now: t0)
        case .always: machine.handle(.always(request()), now: t0)
        case .manual: machine.handle(.manualStart(request()), now: t0)
        }
        machine.handle(.captureStarted(token1, folder: folder), now: t0)
        return machine
    }

    private static func isOffering(_ machine: Machine) -> Bool {
        if case .offering = machine.phase { return true }
        return false
    }

    private static func isEndingSoon(_ machine: Machine) -> Bool {
        if case .endingSoon = machine.phase { return true }
        return false
    }

    private static func isRecording(_ machine: Machine) -> Bool {
        if case .recording = machine.phase { return true }
        return false
    }

    private static func finalizes(_ effects: [Machine.Effect]) -> Bool {
        effects.contains { if case .beginFinalize = $0 { return true }; return false }
    }

    private static func patches(_ effects: [Machine.Effect]) -> [Patch] {
        effects.compactMap {
            if case let .writeSidecar(_, patch) = $0 { return patch }
            return nil
        }
    }

    private static func offering(_ suite: TestSuite) {
        var machine = Machine()
        let meeting = candidate()
        let effects = machine.handle(.candidates([meeting], request()), now: t0)
        suite.expect(effects == [.silence(meetA), .showOffer(offer(meeting)), .announce(.offered("Point hebdo"))]
                        && machine.phase == .offering(offer(meeting)),
                     "a meeting is offered, set aside at once so it is never offered twice, and said to VoiceOver")
        suite.expect(!machine.isBusy && machine.activeSession == nil,
                     "an offer holds nothing: updates may install, nothing records")
        suite.expect(machine.handle(.candidates([candidate(silenced: true)], request()), now: at(3)).isEmpty
                        && machine.handle(.candidates([meeting], request()), now: at(4)).isEmpty,
                     "the same meeting read again, set aside or not yet, changes nothing")

        var aside = Machine()
        suite.expect(aside.handle(.candidates([candidate(silenced: true)], request()), now: t0).isEmpty
                        && aside.phase == .idle,
                     "a meeting set aside (\"Not now\", already offered) is not offered")
        var never = Machine()
        suite.expect(never.handle(.candidates([candidate(policy: .never)], request()), now: t0).isEmpty,
                     "nor one whose app is set to Never")
        var two = Machine()
        let older = candidate(meetA, bornAt: 0)
        let newer = candidate(meetB, name: "Revue", bornAt: 5)
        two.handle(.candidates([newer, older], request()), now: at(6))
        suite.expect(two.phase == .offering(offer(newer, at: 6)), "of two meetings, the most recent is offered")
        var skipping = Machine()
        skipping.handle(.candidates([candidate(meetB, silenced: true, bornAt: 5), older], request()), now: at(6))
        suite.expect(skipping.phase == .offering(offer(older, at: 6)),
                     "the most recent one not set aside")
    }

    private static func folding(_ suite: TestSuite) {
        var machine = offered()
        suite.expect(machine.handle(.tick, now: at(19)).isEmpty, "an unanswered offer stays open 20 s")
        suite.expect(machine.handle(.tick, now: at(20)) == [.collapseOffer], "then folds into its reminder")
        var folded = offer(candidate())
        folded.collapsed = true
        suite.expect(machine.phase == .offering(folded) && machine.handle(.tick, now: at(40)).isEmpty,
                     "and stays folded, quietly, while the meeting goes on")
        let accepted = machine.handle(.accept(request()), now: at(300))
        suite.expect(accepted == [.hideOffer, .startCapture(config(.offered, candidate()), token1)],
                     "the folded reminder still records the meeting")
    }

    private static func answers(_ suite: TestSuite) {
        var accept = offered()
        suite.expect(accept.handle(.accept(request()), now: at(2))
                        == [.hideOffer, .startCapture(config(.offered, candidate()), token1)],
                     "Record starts the offered meeting, named, with its window and app")
        suite.expect(accept.handle(.captureStarted(token1, folder: folder), now: at(3)).contains(.notice(.started))
                        && accept.activeSession?.origin == .offered && accept.activeSession?.meeting == meetA,
                     "and records it as offered")

        var notNow = offered()
        suite.expect(notNow.handle(.dismiss(.thisTime), now: at(2)) == [.hideOffer, .silence(meetA)]
                        && notNow.phase == .idle,
                     "Not now closes the offer and sets this meeting aside")
        suite.expect(notNow.handle(.candidates([candidate(silenced: true)], request()), now: at(5)).isEmpty,
                     "so the same meeting, read again, is not offered again")

        var never = offered()
        suite.expect(never.handle(.dismiss(.never), now: at(2))
                        == [.hideOffer, .setPolicy(.never, provider: "meet"), .notice(.neverOffered("Meet")),
                            .announce(.neverOffered("Meet"))]
                        && never.phase == .idle,
                     "Never for Meet writes the choice and says where to change it")

        var manual = offered()
        suite.expect(manual.handle(.manualStart(request()), now: at(2))
                        == [.hideOffer, .startCapture(config(.manual, candidate()), token1)],
                     "the Record button or the shortcut while an offer shows records this meeting, by hand")
    }

    private static func refusedOffers(_ suite: TestSuite) {
        var machine = Machine()
        let meeting = candidate()
        suite.expect(machine.handle(.candidates([meeting], request(busy)), now: t0)
                        == [.silence(meetA), .showOffer(offer(meeting, blocked: .officialRecorderBusy)),
                            .announce(.offered("Point hebdo"))],
                     "with the official recorder running, the offer shows greyed out, with why")
        suite.expect(machine.handle(.accept(request(busy)), now: at(1))
                        == [.notice(.failure(.officialRecorderBusy)), .announce(.failure(.officialRecorderBusy))]
                        && isOffering(machine),
                     "Record then refuses and says why; the offer stays")
        suite.expect(machine.handle(.candidates([meeting], request()), now: at(5)) == [.showOffer(offer(meeting))],
                     "once the recorder stops, the offer can record again")
        suite.expect(machine.handle(.accept(request()), now: at(6)).first == .hideOffer, "and does")

        var always = Machine()
        let automatic = candidate(policy: .always)
        suite.expect(always.handle(.candidates([automatic], request(busy)), now: t0)
                        == [.silence(meetA), .showOffer(offer(automatic, blocked: .officialRecorderBusy)),
                            .announce(.offered("Point hebdo"))],
                     "Always never starts over the official recorder: it offers, greyed out")

        var screen = Machine()
        let noScreen = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: false,
                                             microphoneAllowed: true, officialRecorderBusy: false)
        screen.handle(.candidates([meeting], request(noScreen)), now: t0)
        suite.expect(screen.phase == .offering(offer(meeting, blocked: .screenRecordingDenied)),
                     "nor without Screen Recording: the offer asks for it instead")
    }

    private static func alwaysAndUndo(_ suite: TestSuite) {
        var machine = Machine()
        let automatic = candidate(policy: .always)
        suite.expect(machine.handle(.candidates([automatic], request()), now: t0)
                        == [.silence(meetA), .startCapture(config(.always, automatic), token1)],
                     "an app set to Always starts its meeting on its own")
        suite.expect(machine.handle(.captureStarted(token1, folder: folder), now: at(1))
                        == [.showPill(.recording(.init(recordedBefore: 0, runningSince: at(1)), diskMinutesLeft: nil)),
                            .showUndo(until: at(6)), .announce(.autoStarted(seconds: 5))],
                     "with \"Recording started · Cancel (5 s)\" instead of the plain notice")
        let cancelled = machine.handle(.cancelAutoStart, now: at(4))
        suite.expect(cancelled == [.hideUndo, .stopCapture(token1), .showPill(.stopping), .announce(.discarded)]
                        && patches(cancelled).isEmpty,
                     "Cancel within 5 s stops it")
        let closed = machine.handle(.writerFinished(token1, .finished(recordedSeconds: 3)), now: at(5))
        suite.expect(closed == [.discard(folder), .showPill(.hidden)] && !finalizes(closed) && machine.phase == .idle,
                     "and deletes its folder once the file is closed: nothing is finalized or kept")

        var late = recording(.always, candidate(policy: .always))
        suite.expect(late.handle(.tick, now: at(4)).isEmpty && late.handle(.tick, now: at(5)) == [.hideUndo],
                     "Cancel goes away after 5 s")
        suite.expect(late.handle(.cancelAutoStart, now: at(6)).isEmpty && isRecording(late),
                     "and does nothing after")

        var chosen = offered()
        suite.expect(chosen.handle(.always(request()), now: at(2))
                        == [.setPolicy(.always, provider: "meet"), .hideOffer,
                            .startCapture(config(.always, candidate()), token1)],
                     "Always for Meet from the offer writes the choice and records now")
        chosen.handle(.captureStarted(token1, folder: folder), now: at(3))
        suite.expect(chosen.activeSession?.undoUntil == at(8), "with the same 5 s to cancel")

        var starting = Machine()
        starting.handle(.candidates([automatic], request()), now: t0)
        suite.expect(starting.handle(.cancelAutoStart, now: at(1)) == [.stopCapture(token1), .showPill(.hidden)]
                        && starting.phase == .idle,
                     "Cancel before the capture runs leaves nothing behind")

        var quitting = recording(.always, candidate(policy: .always))
        quitting.handle(.cancelAutoStart, now: at(2))
        suite.expect(quitting.handle(.appWillTerminate, now: at(3)) == [.discard(folder)],
                     "a cancelled recording is deleted even when the app quits, never recovered at the next launch")

        var manual = recording(.offered)
        suite.expect(manual.handle(.cancelAutoStart, now: at(1)).isEmpty,
                     "a recording the person started has no Cancel")
    }

    private static func endingSoon(_ suite: TestSuite) {
        var machine = recording()
        let countdown = machine.handle(.endProbable(meetA, countdown: 15), now: at(600))
        suite.expect(countdown == [.showEndingSoon(until: at(615)), .announce(.endingSoon(seconds: 15))]
                        && isEndingSoon(machine) && machine.isBusy && machine.activeSession != nil,
                     "its meeting probably ended: \"Meeting over? Stopping in 15 s [Continue]\", still recording")
        suite.expect(machine.handle(.tick, now: at(614)).isEmpty, "the countdown runs")
        let stopped = machine.handle(.tick, now: at(615))
        suite.expect(stopped.first == .hideEndingSoon && stopped.contains(.stopCapture(token1))
                        && patches(stopped) == [Patch(stopReason: .meetingEnded)],
                     "then the recording stops, as ended with its meeting")
        suite.expect(finalizes(machine.handle(.writerFinished(token1, .finished(recordedSeconds: 615)), now: at(616))),
                     "and is finalized like any other")

        var kept = recording()
        kept.handle(.endProbable(meetA, countdown: 15), now: at(600))
        suite.expect(kept.handle(.continueRecording, now: at(605)) == [.hideEndingSoon, .announce(.continued)]
                        && isRecording(kept),
                     "Continue keeps recording")
        suite.expect(kept.handle(.tick, now: at(700)).isEmpty && isRecording(kept), "with no countdown left")

        var back = recording()
        back.handle(.endProbable(meetA, countdown: 15), now: at(600))
        suite.expect(back.handle(.candidates([candidate(silenced: true)], request()), now: at(605)) == [.hideEndingSoon]
                        && isRecording(back),
                     "its meeting back (the microphone, the tab) takes the countdown away")

        var off = recording()
        suite.expect(off.handle(.endProbable(meetA, countdown: nil), now: at(600)).isEmpty && isRecording(off),
                     "with auto stop off, the recording goes on")

        var stoppedByHand = recording()
        stoppedByHand.handle(.endProbable(meetA, countdown: 15), now: at(600))
        let byHand = stoppedByHand.handle(.stop, now: at(603))
        suite.expect(byHand.first == .hideEndingSoon && patches(byHand) == [Patch(stopReason: .user)],
                     "Stop during the countdown stops at once, as the person's")

        var always = recording(.always, candidate(policy: .always))
        always.handle(.tick, now: at(5))
        suite.expect(always.handle(.endProbable(meetA, countdown: 15), now: at(600)).first == .showEndingSoon(until: at(615)),
                     "a recording Always started ends with its meeting too")
    }

    private static func endingSoonInterrupted(_ suite: TestSuite) {
        var paused = recording()
        paused.handle(.endProbable(meetA, countdown: 15), now: at(600))
        let pause = paused.handle(.pause, now: at(605))
        suite.expect(pause.first == .hideEndingSoon && pause.contains(.pauseCapture(.user)),
                     "a pause holds the countdown")
        suite.expect(paused.handle(.tick, now: at(700)).isEmpty, "nothing stops while paused")
        let resumed = paused.handle(.resume, now: at(800))
        suite.expect(resumed.contains(.resumeCapture) && resumed.contains(.showEndingSoon(until: at(815)))
                        && isEndingSoon(paused),
                     "the resume starts it again: the meeting is still over")

        var asleep = recording()
        asleep.handle(.willSleep, now: at(100))
        suite.expect(asleep.handle(.endProbable(meetA, countdown: 15), now: at(130)).isEmpty,
                     "a meeting ending during a sleep starts no countdown while asleep")
        let woke = asleep.handle(.didWake, now: at(900))
        suite.expect(woke.contains(.restartStream) && woke.contains(.showEndingSoon(until: at(915))),
                     "at the wake, the recording resumes and its countdown starts: it stops 15 s later")

        var slept = recording()
        slept.handle(.endProbable(meetA, countdown: 15), now: at(600))
        let sleep = slept.handle(.willSleep, now: at(603))
        suite.expect(sleep.first == .hideEndingSoon && sleep.contains(.pauseCapture(.sleep)),
                     "a sleep during the countdown pauses like any recording")

        var gone = recording()
        gone.handle(.endProbable(meetA, countdown: 15), now: at(600))
        let disk = gone.handle(.diskCritical, now: at(601))
        suite.expect(disk.first == .hideEndingSoon && patches(disk) == [Patch(stopReason: .disk)],
                     "the disk filling during the countdown stops for the disk")

        var microphone = recording()
        microphone.handle(.endProbable(meetA, countdown: 15), now: at(600))
        suite.expect(microphone.handle(.microphoneSilent, now: at(601)) == [.notice(.microphoneSilent), .announce(.microphoneSilent)]
                        && isEndingSoon(microphone),
                     "what changes nothing to the recording leaves the countdown running")
        suite.expect(!finalizes(microphone.handle(.tick, now: at(616))) && microphone.activeSession == nil,
                     "and it still ends it on time")
    }

    /// A stop from the detection acts only on a recording the detection
    /// started, and only for its own meeting.
    private static func onlyItsOwnMeeting(_ suite: TestSuite) {
        var manual = recording(.manual)
        suite.expect(manual.activeSession?.meeting == meetA && !(manual.activeSession?.endsWithMeeting ?? true),
                     "a recording by hand during an offer knows its meeting, but is not tied to it")
        suite.expect(manual.handle(.endProbable(meetA, countdown: 15), now: at(600)).isEmpty
                        && manual.handle(.tick, now: at(10_000)).isEmpty && isRecording(manual),
                     "and is never stopped by the detection")

        var plain = Machine()
        plain.handle(.manualStart(request()), now: t0)
        plain.handle(.captureStarted(token1, folder: folder), now: t0)
        suite.expect(plain.handle(.endProbable(meetA, countdown: 15), now: at(600)).isEmpty && isRecording(plain),
                     "nor one started with no meeting around")

        var other = recording()
        suite.expect(other.handle(.endProbable(meetB, countdown: 15), now: at(600)).isEmpty && isRecording(other),
                     "another meeting ending never stops this one")
    }

    private static func secondMeeting(_ suite: TestSuite) {
        var machine = recording()
        let second = candidate(meetB, name: "Revue", bornAt: 300)
        suite.expect(machine.handle(.candidates([second, candidate(silenced: true)], request()), now: at(300)).isEmpty
                        && isRecording(machine),
                     "a second meeting during a recording stops nothing and is not offered")
        machine.handle(.stop, now: at(600))
        suite.expect(machine.handle(.candidates([second], request()), now: at(601)).isEmpty,
                     "nor while the file closes")
        machine.handle(.writerFinished(token1, .finished(recordedSeconds: 600)), now: at(602))
        suite.expect(machine.handle(.candidates([second, candidate(silenced: true)], request()), now: at(603))
                        == [.silence(meetB), .showOffer(offer(second, at: 603)), .announce(.offered("Revue"))],
                     "once the recording is over, the second meeting is offered")
        machine.handle(.accept(request()), now: at(604))
        suite.expect(machine.handle(.captureStarted(token2, folder: folder), now: at(605)).contains(.notice(.started)),
                     "and recorded on its own token")
    }

    private static func offerEnds(_ suite: TestSuite) {
        var gone = offered()
        suite.expect(gone.handle(.candidates([], request()), now: at(30)) == [.hideOffer] && gone.phase == .idle,
                     "the meeting gone, its offer goes")
        var ended = offered()
        suite.expect(ended.handle(.endProbable(meetA, countdown: 15), now: at(30)) == [.hideOffer],
                     "its end takes the offer away")
        var unrelated = offered()
        suite.expect(unrelated.handle(.endProbable(meetB, countdown: 15), now: at(30)).isEmpty && isOffering(unrelated),
                     "another meeting's end does not")
        var replaced = offered()
        let newer = candidate(meetB, name: "Revue", bornAt: 30)
        suite.expect(replaced.handle(.candidates([newer, candidate(silenced: true)], request()), now: at(31))
                        == [.hideOffer, .silence(meetB), .showOffer(offer(newer, at: 31)), .announce(.offered("Revue"))],
                     "a newer meeting takes the place of the offer: one offer at a time, for the most recent")
        var renamed = offered()
        var titled = candidate(silenced: true)
        titled.calendarTitle = "Point Opah"
        suite.expect(renamed.handle(.candidates([titled], request()), now: at(3)).first?.isShowOffer == true,
                     "an offer whose meeting changed shows again")
        var off = offered()
        suite.expect(off.handle(.featureDisabled, now: at(3)) == [.hideOffer] && off.phase == .idle,
                     "turning Meetings off takes the offer away")
        var quit = offered()
        suite.expect(quit.handle(.appWillTerminate, now: at(3)) == [.hideOffer]
                        && quit.handle(.candidates([candidate()], request()), now: at(4)).isEmpty,
                     "quitting takes it away, and nothing is offered after")
        var asleep = offered()
        suite.expect(asleep.handle(.pause, now: at(3)).isEmpty && asleep.handle(.stop, now: at(3)).isEmpty
                        && asleep.handle(.willSleep, now: at(3)).isEmpty && isOffering(asleep),
                     "an offer has nothing to pause or stop")
    }

    /// Every event, from a countdown: whatever leaves it goes through the
    /// recording's own ways out, and takes the countdown away.
    private static func invariants(_ suite: TestSuite) {
        let events: [Machine.Event] = [
            .manualStart(request()), .pause, .resume, .stop, .captureStarted(token1, folder: folder),
            .captureFailed(token1, .streamStopped), .writerFinished(token1, .finished(recordedSeconds: 1)), .willSleep,
            .didWake, .locked, .unlocked, .diskLow(freeBytes: 1_000_000_000), .diskCritical,
            .permissionLost(.screenRecording), .permissionLost(.microphone), .displayChanged,
            .microphoneChanged(name: "X", gap: 1), .microphoneSilent, .appWillTerminate, .featureDisabled,
            .candidates([], request()), .candidates([candidate(meetB)], request()), .tick, .accept(request()),
            .dismiss(.thisTime), .dismiss(.never), .always(request()), .cancelAutoStart, .continueRecording,
            .endProbable(meetA, countdown: 15), .endProbable(meetB, countdown: 15),
        ]
        var throughStopping = true
        var countdownKept = true
        for event in events {
            var machine = recording()
            machine.handle(.endProbable(meetA, countdown: 15), now: at(600))
            let effects = machine.handle(event, now: at(605))
            switch machine.phase {
            case .recording, .paused, .stopping, .endingSoon: break
            case .idle, .offering, .starting: throughStopping = false
            }
            if !isEndingSoon(machine), !effects.contains(.hideEndingSoon) { countdownKept = false }
        }
        suite.expect(throughStopping, "from a countdown, every event leads to recording, paused, stopping or the countdown")
        suite.expect(countdownKept, "and any way out of the countdown takes it off the screen")

        var finalizeCount = 0
        var manualStopped = false
        for first in events {
            for second in events {
                var machine = recording()
                var all = machine.handle(.endProbable(meetA, countdown: 15), now: at(600))
                all += machine.handle(first, now: at(605))
                all += machine.handle(second, now: at(610))
                all += machine.handle(.tick, now: at(700))
                all += machine.handle(.writerFinished(token1, .finished(recordedSeconds: 20)), now: at(710))
                all += machine.handle(.writerFinished(token1, .finished(recordedSeconds: 20)), now: at(711))
                finalizeCount = max(finalizeCount, all.filter { if case .beginFinalize = $0 { return true }; return false }.count)

                var manual = recording(.manual)
                manual.handle(.endProbable(meetA, countdown: 15), now: at(600))
                if [first, second].allSatisfy(isDetectionEvent) {
                    manual.handle(first, now: at(605))
                    manual.handle(second, now: at(610))
                    manual.handle(.tick, now: at(10_000))
                    if !isRecording(manual) { manualStopped = true }
                }
            }
        }
        suite.expect(finalizeCount == 1, "with a countdown too, a session is handed to the finalizer once and only once")
        suite.expect(!manualStopped, "no detection event, in any order, ever stops a recording started by hand")
    }

    /// The resolver and the machine together, as the service will wire
    /// them: the set-asides go back to the resolver, the ends to the machine.
    private struct Pipeline {
        var resolver = ForkMeetingResolver(ownPID: 999)
        var machine = Machine()
        var effects: [Machine.Effect] = []

        mutating func read(_ seconds: TimeInterval, windows: [ForkMeetingWindowSignal]? = nil,
                           microphones: [ForkMeetingMicSignal]? = nil) {
            let now = t0.addingTimeInterval(seconds)
            let resolution = resolver.resolve(ForkMeetingReading(at: now, windows: windows, microphones: microphones))
            for identity in resolution.ended { apply(machine.handle(.endProbable(identity, countdown: 15), now: now), now) }
            apply(machine.handle(.candidates(resolution.candidates, request()), now: now), now)
            apply(machine.handle(.tick, now: now), now)
        }

        mutating func send(_ event: Machine.Event, _ seconds: TimeInterval) {
            let now = t0.addingTimeInterval(seconds)
            apply(machine.handle(event, now: now), now)
        }

        private mutating func apply(_ new: [Machine.Effect], _ now: Date) {
            for case let .silence(identity) in new { resolver.silence(identity, at: now) }
            effects += new
        }

        mutating func take() -> [Machine.Effect] {
            defer { effects = [] }
            return effects
        }
    }

    private static func pipeline(_ suite: TestSuite) {
        let tab = ForkMeetingWindowSignal(bundle: "com.google.Chrome", pid: 100, title: "Meet – Point hebdo – abc-defg-hij",
                                          onScreen: true, windowID: 1)
        let other = ForkMeetingWindowSignal(bundle: "com.google.Chrome", pid: 100, title: "Gmail", onScreen: true, windowID: 1)
        let left = ForkMeetingWindowSignal(bundle: "com.google.Chrome", pid: 100, title: "Vous avez quitté la réunion",
                                           onScreen: true, windowID: 1)
        let microphone = ForkMeetingMicSignal(appBundle: "com.google.Chrome", appPID: 100, pid: 101)
        func shows(_ effects: [Machine.Effect]) -> Bool { effects.contains { $0.isShowOffer } }

        var p = Pipeline()
        p.read(-5, microphones: [microphone])
        p.read(0, windows: [tab])
        let first = p.take()
        suite.expect(shows(first) && first.contains(.announce(.offered("Point hebdo"))),
                     "Google Meet in Chrome, its microphone open: offered at the first reading")
        p.read(3, windows: [tab])
        p.read(20, windows: [tab])
        suite.expect(p.take() == [.collapseOffer], "read again it changes nothing, and folds after 20 s")
        p.send(.dismiss(.thisTime), 25)
        p.read(28, windows: [other])
        p.read(31, windows: [tab])
        p.read(34, windows: [tab])
        suite.expect(!shows(p.take()), "Not now, then away to another tab and back: nothing is offered again")
        p.read(40, windows: [left])
        p.read(43, microphones: [])
        p.read(100, windows: [tab], microphones: [microphone])
        p.read(103, windows: [tab])
        suite.expect(!shows(p.take()), "left, then rejoined within 10 minutes: still nothing")
        p.read(110, windows: [left], microphones: [])
        p.read(705, microphones: [microphone])
        p.read(711, windows: [left])
        p.read(712, windows: [tab])
        suite.expect(shows(p.take()), "10 minutes after its end, the same meeting is offered again")

        p.send(.accept(request()), 713)
        p.send(.captureStarted(token1, folder: folder), 714)
        p.read(800, windows: [other])
        suite.expect(!p.take().contains(.hideEndingSoon) && p.machine.activeSession != nil,
                     "recording: another tab in front changes nothing, the microphone keeps the meeting alive")
        p.read(900, windows: [left])
        suite.expect(p.take().contains(.showEndingSoon(until: at(915))), "the end page starts the countdown at once")
        p.read(915)
        let stopped = p.take()
        suite.expect(stopped.contains(.stopCapture(token1)) && patches(stopped) == [Patch(stopReason: .meetingEnded)],
                     "and 15 s later the recording stops")
    }

    private static func isDetectionEvent(_ event: Machine.Event) -> Bool {
        switch event {
        case .candidates, .tick, .endProbable, .accept, .dismiss, .always, .cancelAutoStart, .continueRecording: return true
        default: return false
        }
    }

    private static func texts(_ suite: TestSuite) {
        let languages = AppLanguage.allCases
        var tooLong: [String] = []
        for language in languages {
            let s = ForkMeetingStrings.strings(language)
            let short = [s.offerRecord, s.offerNotNow, s.offerAlways("FaceTime"), s.offerNever("FaceTime"), s.offerMore,
                         s.endingSoonTitle, s.endingSoon(seconds: 120), s.endingSoonContinue, s.undo(seconds: 5),
                         ForkMeetingNotice.neverOffered("FaceTime").title(s), s.noticeNeverDetail]
            tooLong += short.filter { $0.count > 28 }.map { "\(language.rawValue): \($0)" }
        }
        suite.expect(tooLong.isEmpty, "the offer's buttons, the countdown and the notices fit in 28 characters: \(tooLong)")
        suite.expect(languages.map(ForkMeetingStrings.strings).allSatisfy { s in
                        s.offerAlways("Meet").contains("Meet") && s.offerNever("Meet").contains("Meet")
                            && s.endingSoon(seconds: 15).contains("15") && s.undo(seconds: 5).contains("5")
                            && s.voiceEndingSoon(seconds: 15).contains("15") && s.voiceAutoStarted(seconds: 5).contains("5")
                            && s.voiceOffer("Point hebdo").contains("Point hebdo") && s.voiceNever("Meet").contains("Meet")
                            && s.offerReminder("Point hebdo").contains("Point hebdo")
                            && ["Chrome", "Safari", "AirPods"].allSatisfy(
                                s.offerCapture(window: "Chrome", sound: "Safari", microphone: "AirPods").contains)
                     },
                     "every language names the app, the meeting, the microphone and the seconds")
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(french.offerRecord == "Enregistrer" && french.offerNotNow == "Pas cette fois"
                        && french.offerAlways("Meet") == "Toujours pour Meet"
                        && french.offerCapture(window: "Chrome", sound: "Chrome", microphone: "AirPods")
                            == "Fenêtre de Chrome · son de Chrome · micro AirPods"
                        && french.endingSoonTitle + " " + french.endingSoon(seconds: 15) == "Réunion terminée\u{00A0}? Arrêt dans 15 s",
                     "the French offer reads as the plan writes it")
        let announcements: [ForkMeetingAnnouncement] = [.offered("X"), .autoStarted(seconds: 5), .endingSoon(seconds: 15),
                                                        .continued, .discarded, .neverOffered("Meet"), .started, .stopped]
        suite.expect(languages.map(ForkMeetingStrings.strings).allSatisfy { s in
                        let said = announcements.map { $0.text(s) }
                        return Set(said).count == said.count && said.allSatisfy { !$0.isEmpty }
                     },
                     "VoiceOver has its own sentence for the offer, Always, the countdown and Cancel, in every language")
        suite.expect(ForkMeetingNotice.neverOffered("Meet").detail(french) == "Réglable dans Réunions"
                        && ForkMeetingNotice.neverOffered("Meet").title(french) == "Plus proposé pour Meet",
                     "after Never, the notice says where to change it")
    }
}

private extension ForkMeetingMachine.Effect {
    var isShowOffer: Bool {
        if case .showOffer = self { return true }
        return false
    }
}
