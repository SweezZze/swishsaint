// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The detection's fixes after the second review of PR 2 (J): each probe
/// of the review played as the person would meet it, through the resolver
/// and the machine wired as the service wires them, then the words.
enum ForkMeetingFixesJTests {
    typealias Machine = ForkMeetingMachine
    typealias Effect = ForkMeetingMachine.Effect
    typealias Window = ForkMeetingWindowSignal
    typealias Microphone = ForkMeetingMicSignal
    typealias Support = ForkMeetingDetectionSupport
    typealias Patch = ForkMeetingSidecarPatch
    typealias Plan = ForkMeetingRecoveryPlan

    static func run(_ suite: TestSuite) {
        alwaysNeedsACode(suite)
        anotherTitleNeverTakesTheCall(suite)
        anotherTitleIsNotTheMeeting(suite)
        endPagesWithTheMicrophoneOpen(suite)
        meetTitlesOnly(suite)
        cancelledNeverRecovered(suite)
        cancelSaidOnce(suite)
        alwaysChosenByHand(suite)
        sharedIslandNamesNoDevice(suite)
        words(suite)
    }

    // MARK: - Fixtures

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let folder = URL(fileURLWithPath: "/tmp/Meetings/2026-10-19 10h00", isDirectory: true)
    private static let settings = ForkMeetingCaptureSettings(target: .window, systemAudio: .app, microphone: "meeting",
                                                             quality: .standard)
    private static let ready = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                     microphoneAllowed: true, officialRecorderBusy: false)
    private static let token1 = ForkMeetingToken(value: 1)
    private static let ownPID: Int32 = 999
    private static let chromePID: Int32 = 100
    private static let codeA = "abc-defg-hij"
    private static let codeB = "xyz-qrst-uvw"
    private static let meetA = ForkMeetingIdentity("meet:abc-defg-hij")
    private static let always = #"{"meet":"always"}"#
    private static let video = "Meet - Glass Animals (Official Video) - YouTube"
    private static let chromeMicrophone = Microphone(appBundle: "com.google.Chrome", appPID: chromePID, pid: 101,
                                                     processBundle: "com.google.Chrome.helper",
                                                     inputDevice: "BuiltInMicrophoneDevice")

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func request() -> ForkMeetingStartRequest {
        ForkMeetingStartRequest(settings: settings, facts: ready)
    }

    private static func chrome(_ title: String, window: UInt32 = 7) -> Window {
        Window(bundle: "com.google.Chrome", pid: chromePID, title: title, onScreen: true, windowID: window)
    }

    private static func verdict(_ title: String) -> ForkMeetingTitleVerdict {
        ForkMeetingTitleRules.verdict(title, rules: .googleMeet)
    }

    /// The service's loop, pure: each end, the meetings on with what a
    /// start would be asked with, then the time; `silence` and `setPolicy`
    /// fed back.
    private struct Live {
        var resolver: ForkMeetingResolver
        var machine = Machine()
        var apps: ForkMeetingPolicies
        private var log: [Effect] = []
        private var lastTick: TimeInterval = -.infinity
        /// The last resolution's meetings, for what the page would show.
        private(set) var candidates: [ForkMeetingCandidate] = []

        init(apps json: String = ForkMeetingPolicies.defaultJSON) {
            apps = ForkMeetingPolicies(json: json)
            resolver = ForkMeetingResolver(ownPID: ForkMeetingFixesJTests.ownPID, policies: apps)
        }

        mutating func read(_ seconds: TimeInterval, windows: [Window]? = nil, microphones: [Microphone]? = nil) {
            clock(until: seconds)
            let now = ForkMeetingFixesJTests.at(seconds)
            resolver.policies = apps
            let resolution = resolver.resolve(ForkMeetingReading(at: now, windows: windows, microphones: microphones))
            candidates = resolution.candidates
            for identity in resolution.ended { run(.endProbable(identity, countdown: 15), now) }
            var asked = ForkMeetingFixesJTests.ready
            asked.meetingsOnMicrophone = resolution.onMicrophone
            run(.candidates(resolution.candidates, ForkMeetingStartRequest(settings: settings, facts: asked)), now)
            run(.tick, now)
        }

        mutating func readEvery3s(from start: TimeInterval, to end: TimeInterval, windows: [Window]) {
            for seconds in stride(from: start, through: end, by: 3) { read(seconds, windows: windows) }
        }

        mutating func send(_ event: Machine.Event, _ seconds: TimeInterval) {
            clock(until: seconds)
            run(event, ForkMeetingFixesJTests.at(seconds))
        }

        mutating func clock(until seconds: TimeInterval) {
            var next = lastTick.isFinite ? lastTick + 1 : seconds.rounded(.down)
            while next <= seconds {
                if Support.clockRuns(phase: machine.phase) { run(.tick, ForkMeetingFixesJTests.at(next)) }
                lastTick = next
                next += 1
            }
        }

        private mutating func run(_ event: Machine.Event, _ now: Date) {
            let effects = machine.handle(event, now: now)
            for effect in effects {
                switch effect {
                case let .silence(identity): resolver.silence(identity, at: now)
                case let .setPolicy(policy, provider):
                    apps.set(policy, for: provider)
                    resolver.policies = apps
                default: break
                }
            }
            log += effects
        }

        mutating func take() -> [Effect] {
            defer { log = [] }
            return log
        }
    }

    private static func offers(_ effects: [Effect]) -> [ForkMeetingOffer] {
        effects.compactMap {
            if case let .showOffer(offer) = $0 { return offer }
            return nil
        }
    }

    private static func starts(_ effects: [Effect]) -> [ForkMeetingCaptureConfig] {
        effects.compactMap {
            if case let .startCapture(config, _) = $0 { return config }
            return nil
        }
    }

    private static func stops(_ effects: [Effect]) -> Bool {
        effects.contains {
            if case .stopCapture = $0 { return true }
            return false
        }
    }

    private static func countdowns(_ effects: [Effect]) -> [Date] {
        effects.compactMap {
            if case let .showEndingSoon(until) = $0 { return until }
            return nil
        }
    }

    private static func announcements(_ effects: [Effect]) -> [ForkMeetingAnnouncement] {
        effects.compactMap {
            if case let .announce(announcement) = $0 { return announcement }
            return nil
        }
    }

    /// Meet A recorded from its offer, Chrome's microphone open since -5 s
    /// and never closed (its call goes on), its tab in front until 30 s.
    private static func recordingA() -> Live {
        var live = Live()
        live.read(-5, microphones: [chromeMicrophone])
        live.read(0, windows: [chrome("Meet – " + codeA)])
        live.send(.accept(request()), 2)
        live.send(.captureStarted(token1, folder: folder), 3)
        live.readEvery3s(from: 6, to: 30, windows: [chrome("Meet – " + codeA)])
        _ = live.take()
        return live
    }

    // MARK: - J.B1 (probe P1)

    /// "Always" starts on its own only a meeting whose title shows its Meet
    /// code: a page called "Meet - …" while the microphone runs for another
    /// call is offered, never recorded.
    private static func alwaysNeedsACode(_ suite: TestSuite) {
        var page = Live(apps: always)
        page.read(-5, microphones: [chromeMicrophone])
        page.readEvery3s(from: 0, to: 60, windows: [chrome(video)])
        let effects = page.take()
        suite.expect(starts(effects).isEmpty && offers(effects).map(\.candidate.name) == ["Glass Animals (Official Video) - YouTube"],
                     "P1: « \(video) », Chrome's microphone held by another call, Always: offered, never started")

        var call = Live(apps: always)
        call.read(-5, microphones: [chromeMicrophone])
        call.read(0, windows: [chrome("Meet – Point hebdo – " + codeA)])
        let started = call.take()
        suite.expect(starts(started).map(\.origin) == [.always] && offers(started).isEmpty,
                     "Meet's own title with its code, the microphone open a second: Always still starts it on its own")

        var named = Live(apps: always)
        named.read(-5, microphones: [chromeMicrophone])
        named.readEvery3s(from: 0, to: 30, windows: [chrome("Meet – Point hebdo")])
        let offered = named.take()
        suite.expect(starts(offered).isEmpty && offers(offered).count == 1,
                     "« Meet – Point hebdo » without its code is only offered")
    }

    // MARK: - J.I1 (probes P2b, P4)

    /// A recording goes on while another tab of the browser is in front: a
    /// title without a code, or another Meet's waiting room on the same
    /// microphone, never takes the call's microphone.
    private static func anotherTitleNeverTakesTheCall(_ suite: TestSuite) {
        var named = recordingA()
        named.readEvery3s(from: 33, to: 120, windows: [chrome("Meet – Point hebdo", window: 8)])
        let namedEffects = named.take()
        suite.expect(countdowns(namedEffects).isEmpty && !stops(namedEffects) && named.machine.activeSession != nil,
                     "P2b: « Meet – Point hebdo » in front for 90 s, the call's microphone open: no countdown, no stop")

        var waiting = recordingA()
        waiting.readEvery3s(from: 33, to: 120, windows: [chrome("Meet – " + codeB, window: 8)])
        let waitingEffects = waiting.take()
        suite.expect(countdowns(waitingEffects).isEmpty && !stops(waitingEffects),
                     "P4: another Meet's waiting room in front, the same microphone run: the call goes on being recorded")

        // ⌘W: the call's tab gone, its microphone with it; the next Meet
        // opens it again.
        var next = recordingA()
        next.read(31, microphones: [])
        next.read(32, microphones: [chromeMicrophone])
        next.readEvery3s(from: 33, to: 60, windows: [chrome("Meet – " + codeB, window: 8)])
        suite.expect(countdowns(next.take()) == [at(69)],
                     "the microphone opened again for a Meet with its code: that one has it, the first ends 20 s later")
    }

    // MARK: - J.I4 (probe P2c)

    /// Another title in the meeting's window (the tab changed) neither
    /// renames the meeting nor keeps it alive.
    private static func anotherTitleIsNotTheMeeting(_ suite: TestSuite) {
        var live = Live()
        live.read(-5, microphones: [chromeMicrophone])
        live.read(0, windows: [chrome("Meet – " + codeA)])
        live.readEvery3s(from: 3, to: 30, windows: [chrome(video)])
        // The video, the microphone open, may be offered as a page of its
        // own (the page's lookalike warning): never as that meeting.
        let names = offers(live.take()).filter { $0.candidate.identity == meetA }.map(\.candidate.name)
        suite.expect(!names.isEmpty && names.allSatisfy { $0 == "Google Meet · " + codeA },
                     "P2c: the meeting's offer keeps its name when the tab shows a video called « Meet - … »: \(names)")
        suite.expect(live.candidates.first(where: { $0.identity == meetA })?.titleName == nil,
                     "and the meeting is not renamed after it")

        var closed = recordingA()
        closed.read(31, microphones: [])
        closed.readEvery3s(from: 33, to: 60, windows: [chrome(video)])
        suite.expect(countdowns(closed.take()) == [at(69)],
                     "⌘W then the video in that window: the meeting is not kept alive by it, it ends 20 s later")

        var resolver = ForkMeetingResolver(ownPID: ownPID)
        _ = resolver.resolve(ForkMeetingReading(at: at(-5), microphones: [chromeMicrophone]))
        _ = resolver.resolve(ForkMeetingReading(at: at(0), windows: [chrome("Meet – Point hebdo – " + codeA)]))
        let same = resolver.resolve(ForkMeetingReading(at: at(3), windows: [chrome("Meet – Point hebdo")]))
        suite.expect(same.candidates.map(\.identity) == [meetA],
                     "its code gone, the same name in the same window: still that meeting")
    }

    // MARK: - J.I2 (probes P3, P6)

    private static func endPagesWithTheMicrophoneOpen(_ suite: TestSuite) {
        var open = recordingA()
        open.read(33, windows: [chrome("Vous avez quitté la réunion")])
        open.readEvery3s(from: 36, to: 120, windows: [chrome("Vous avez quitté la réunion")])
        let openEffects = open.take()
        suite.expect(countdowns(openEffects).isEmpty && open.machine.activeSession != nil,
                     "P3: an end page in front, the microphone still open (another tab's call): nothing ends, the 20 s decide")

        var gmail = recordingA()
        gmail.read(33, windows: [chrome("Re: the meeting has ended - alice@gmail.com - Gmail")])
        suite.expect(countdowns(gmail.take()).isEmpty,
                     "P6: an e-mail called « Re: the meeting has ended » ends nothing")
        suite.expect(verdict("Re: the meeting has ended - alice@gmail.com - Gmail") == .none
                        && verdict("Compte rendu : la réunion est terminée - Gmail") == .none,
                     "an end sentence is read only in a Meet title, or as the whole title")
        suite.expect(verdict("Meet – Vous avez quitté la réunion") == .exit && verdict("You left the meeting") == .exit
                        && verdict("You left the meeting – " + codeA) == .exit,
                     "Meet's own end pages still end the meeting")

        var left = recordingA()
        left.read(32.5, microphones: [])
        left.read(33, windows: [chrome("Vous avez quitté la réunion")])
        suite.expect(countdowns(left.take()) == [at(48)], "the call left, its microphone closed: the countdown starts at once")
    }

    // MARK: - J.M1 (probe P5)

    private static func meetTitlesOnly(_ suite: TestSuite) {
        let expected: [(String, ForkMeetingTitleVerdict)] = [
            ("Meet the team – Acme", .none),
            ("Meet-up Paris – Eventbrite", .none),
            ("Meetup - Paris JS", .none),
            ("meet.google.com - Google Search", .none),
            ("meet.google.com/abc-defg-hij - Google Search", .none),
            ("abc-defg-hij - Recherche Google", .none),
            ("Meet - abc-defg-hij", .meeting(code: codeA, name: nil)),
            ("Meet: abc-defg-hij", .meeting(code: codeA, name: nil)),
            ("Meet - Bad Bunny - YouTube", .meeting(code: nil, name: "Bad Bunny - YouTube")),
            ("Meet: The Parents (2000) - IMDb", .none),
            ("Meet – fix-auth-bug – GitHub", .meeting(code: nil, name: "fix-auth-bug – GitHub")),
            ("Zoom vs Google Meet", .none),
            ("one-time-pad", .none),
            ("abc-defg-hij", .none),
            ("Meet-the-Press - NBC", .none),
            ("Meet—Point hebdo", .none),
            ("Re: the meeting has ended - alice@gmail.com - Gmail", .none),
            ("MEET – Point hebdo", .meeting(code: nil, name: "Point hebdo")),
            ("Meet – Point hebdo – abc-defg-hij", .meeting(code: codeA, name: "Point hebdo")),
            ("Point hebdo – abc-defg-hij – Google Meet", .meeting(code: codeA, name: "Point hebdo")),
            ("Point hebdo–Google Meet", .none),
        ]
        let wrong = expected.filter { verdict($0.0) != $0.1 }.map { "\($0.0) → \(verdict($0.0))" }
        suite.expect(wrong.isEmpty, "Meet's format only: a space, a dash, a space, its code as the last part: \(wrong)")

        var eventbrite = Live()
        eventbrite.read(-5, microphones: [chromeMicrophone])
        eventbrite.readEvery3s(from: 0, to: 60, windows: [chrome("Meet-up Paris – Eventbrite")])
        suite.expect(offers(eventbrite.take()).isEmpty,
                     "P5: « Meet-up Paris – Eventbrite », the microphone open: never offered as « up Paris – Eventbrite »")
    }

    // MARK: - J.M2

    /// "Cancel" is in `meeting.json` at the click: a quit before the folder
    /// went never has it recovered; the next launch throws it away.
    private static func cancelledNeverRecovered(_ suite: TestSuite) {
        var live = Live(apps: always)
        live.read(-5, microphones: [chromeMicrophone])
        live.read(0, windows: [chrome("Meet – " + codeA)])
        live.send(.captureStarted(token1, folder: folder), 1)
        _ = live.take()
        live.send(.cancelAutoStart, 2)
        let cancelled = live.take()
        let mark = Patch(state: .interrupted, stopReason: .cancelled)
        suite.expect(cancelled.first(where: {
                        if case .writeSidecar = $0 { return true }
                        return false
                     }) == .writeSidecar(folder, mark)
                        && cancelled.firstIndex(of: .writeSidecar(folder, mark)) ?? 99 < cancelled.firstIndex(of: .stopCapture(token1)) ?? 0,
                     "at the click, before the stop: interrupted and cancelled in meeting.json")
        live.send(.appWillTerminate, 2.1)
        suite.expect(live.take() == [.discard(folder)], "⌘Q right after: its folder is given to the Trash once, within the quit's bound")

        var written = ForkMeetingSidecar()
        written.schema = 1
        written.state = .recording
        let sidecar = mark.applied(to: written)
        suite.expect(sidecar.state == .interrupted && sidecar.stopReason == .cancelled, "the mark reads back")
        let nothingLeft = ForkMeetingFolder.contents(of: [ForkMeetingFolder.sidecarName], folderName: "x")
        suite.expect(Plan.needsInspection(.success(sidecar), contents: nothingLeft),
                     "the next launch looks at a cancelled folder, even with nothing else in it")
        let facts = Plan.Facts(sidecar: .success(sidecar), master: Plan.Media(duration: 120), final: nil, hasDrafts: true)
        suite.expect(Plan.plan(facts) == .discard && Plan.patch(for: .discard, facts: facts) == nil,
                     "and sends it to the Trash, its master unread: never recovered, never finalized")
        suite.expect(ForkMeetingStopReason(rawValue: "cancelled") == .cancelled
                        && ForkMeetingStopReason(rawValue: "quit") == .quit,
                     "the reason is added, the others keep their names")
    }

    // MARK: - J.M3

    /// The click says "Recording cancelled" only; where the folder went is
    /// said once after, without that sentence again.
    private static func cancelSaidOnce(_ suite: TestSuite) {
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(ForkMeetingAnnouncement.discarded.text(french) == "Enregistrement annulé.",
                     "at the click: « Enregistrement annulé. »")
        suite.expect(ForkMeetingDiscardOutcome.trashed.spokenAfterCancel(askedAgain: nil, strings: french)
                        == "Il a été mis à la Corbeille.",
                     "then, the folder gone: « Il a été mis à la Corbeille. », once")
        let languages = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        let outcomes: [ForkMeetingDiscardOutcome] = [.trashed, .deleted, .kept]
        suite.expect(languages.allSatisfy { s in
                        outcomes.allSatisfy { outcome in
                            let after = outcome.spokenAfterCancel(askedAgain: nil, strings: s)
                            return !after.isEmpty && after != s.voiceCancelled
                                && (after == outcome.spoken(s) || !after.hasPrefix(s.voiceCancelled))
                        }
                     },
                     "in every language, the outcome said after says something new")
        suite.expect(languages.filter { s in s.voiceDiscarded.hasPrefix(s.voiceCancelled) }.count >= 12,
                     "most languages drop the sentence said at the click")

        var live = Live(apps: always)
        live.read(-5, microphones: [chromeMicrophone])
        live.read(0, windows: [chrome("Meet – " + codeA)])
        live.send(.captureStarted(token1, folder: folder), 1)
        _ = live.take()
        live.send(.cancelAutoStart, 2)
        live.send(.writerFinished(token1, .finished(recordedSeconds: 1)), 2.5)
        let effects = live.take()
        suite.expect(announcements(effects) == [.discarded] && effects.contains(.discard(folder)),
                     "the machine says the cancel once; the service says the outcome once the folder is gone")
    }

    // MARK: - J.I5

    private static func alwaysChosenByHand(_ suite: TestSuite) {
        func chosen() -> Live {
            var live = Live()
            live.read(-5, microphones: [chromeMicrophone])
            live.read(0, windows: [chrome("Meet – " + codeA)])
            _ = live.take()
            live.send(.always(request()), 2)
            return live
        }
        var live = chosen()
        let choice = live.take()
        suite.expect(!choice.contains(.notice(.alwaysChosen("Meet"))) && starts(choice).map(\.origin) == [.always],
                     "Always chosen in the menu: no notice of its own, the Cancel card says it")
        live.send(.captureStarted(token1, folder: folder), 3)
        let started = live.take()
        suite.expect(announcements(started) == [.started] && started.contains(.showUndo(until: at(8))),
                     "VoiceOver hears a plain start (the person pressed it), Cancel stays 5 s")
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(ForkMeetingOfferText.undoLine(provider: "Meet", choseAlways: true, strings: french)
                        == "Toujours pour Meet · Réglable dans Réunions"
                        && ForkMeetingOfferText.undoLine(provider: "Meet", choseAlways: false, strings: french)
                        == "Auto · Toujours pour Meet"
                        && ForkMeetingOfferText.undoLine(provider: nil, choseAlways: true, strings: french) == nil,
                     "the card: « Toujours pour Meet · Réglable dans Réunions », not « started on its own »")
        let long = AppLanguage.allCases.filter { language in
            let line = ForkMeetingOfferText.undoLine(provider: "Meet", choseAlways: false, strings: .strings(language)) ?? ""
            return line.count > 28 || !line.contains("Meet")
        }
        suite.expect(long.isEmpty, "a real start on its own keeps its line, 28 characters at most in every language: \(long)")

        // The pill's stop during Cancel, after the choice by hand: the
        // recording to the Trash, "Ask" back, and said.
        live.send(.cancelAutoStart, 4)
        let cancelled = live.take()
        suite.expect(cancelled.contains(.setPolicy(.ask, provider: "meet")) && live.apps.policy(for: .googleMeet) == .ask,
                     "Cancel, or the pill's stop, takes the choice back")
        live.send(.writerFinished(token1, .finished(recordedSeconds: 1)), 4.5)
        suite.expect(live.take().contains(.discard(folder, askedAgain: "Meet")),
                     "and the folder's outcome comes with it, to be said")
        let english = ForkMeetingStrings.strings(.enUS)
        suite.expect(ForkMeetingDiscardOutcome.trashed.detail(askedAgain: "Meet", strings: french) == "Retour à Proposer pour Meet"
                        && ForkMeetingDiscardOutcome.trashed.spokenAfterCancel(askedAgain: "Meet", strings: english)
                        == "It is in the Trash. Meetings from Meet will be offered again."
                        && ForkMeetingDiscardOutcome.kept.detail(askedAgain: "Meet", strings: french) == french.noticeDiscardKeptDetail,
                     "never silently: « Annulé · mis à la Corbeille · Retour à Proposer pour Meet », and to VoiceOver")

        var early = chosen()
        _ = early.take()
        early.send(.cancelAutoStart, 2.5)
        let before = early.take()
        suite.expect(before.contains(.setPolicy(.ask, provider: "meet")) && before.contains(.notice(.askedAgain("Meet")))
                        && announcements(before) == [.askedAgain("Meet")],
                     "cancelled before anything recorded: the choice taken back is said at once")

        var automatic = Live(apps: always)
        automatic.read(-5, microphones: [chromeMicrophone])
        automatic.read(0, windows: [chrome("Meet – " + codeA)])
        automatic.send(.captureStarted(token1, folder: folder), 1)
        automatic.send(.cancelAutoStart, 2)
        automatic.send(.writerFinished(token1, .finished(recordedSeconds: 1)), 2.5)
        let auto = automatic.take()
        suite.expect(auto.contains(.discard(folder)) && !auto.contains(.discard(folder, askedAgain: "Meet"))
                        && automatic.apps.policy(for: .googleMeet) == .always,
                     "a start Always made on its own, cancelled: the choice stays, nothing said of it")
    }

    // MARK: - J.I3, J.I6

    private static func sharedIslandNamesNoDevice(_ suite: TestSuite) {
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(ForkMeetingSharedText.pillName(title: "Entretien Alice", providerName: "Google Meet", seenInShares: true,
                                                    strings: french) == "Google Meet"
                        && ForkMeetingSharedText.pillName(title: "Entretien Alice", providerName: "Google Meet",
                                                          seenInShares: false, strings: french) == "Entretien Alice"
                        && ForkMeetingSharedText.pillName(title: "Entretien Alice", providerName: nil, seenInShares: true,
                                                          strings: french) == french.untitledMeeting,
                     "J.I3: under the pointer, the pill names the service while shares see it, the meeting otherwise")
        let shared = [
            ForkMeetingSharedText.microphone(.meetingApp("uid"), builtIn: false, strings: french),
            ForkMeetingSharedText.microphone(.chosen("uid"), builtIn: false, strings: french),
            ForkMeetingSharedText.microphone(.system, builtIn: true, strings: french),
        ]
        suite.expect(shared == ["Automatique", "Micro externe", "Micro interne"],
                     "J.I6: the offer's microphone, seen in shares, by kind: \(shared)")
        let notice = ForkMeetingNotice.microphone("AirPods d’Alice")
        let details = [true, false].compactMap { ForkMeetingSharedText.detail(notice, microphoneBuiltIn: $0, strings: french) }
        suite.expect(details == ["Micro interne", "Micro externe"] && !details.contains { $0.contains("Alice") },
                     "and « Micro changé » names no device: \(details)")
        suite.expect(ForkMeetingSharedText.detail(.diskLow(minutesLeft: 12), microphoneBuiltIn: true, strings: french)
                        == ForkMeetingNotice.diskLow(minutesLeft: 12).detail(french),
                     "any other notice keeps its line")
        let all = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(all.allSatisfy { !$0.microphoneExternal.isEmpty && $0.microphoneExternal != $0.microphoneBuiltIn
                                        && $0.microphoneExternal.count <= 28 },
                     "« external microphone » in every language, short")
    }

    // MARK: - The texts

    private static func words(_ suite: TestSuite) {
        let s = { ForkMeetingStrings.strings($0) }
        suite.expect(s(.fr).voiceDiscarded == "Enregistrement annulé. Il a été mis à la Corbeille."
                        && s(.enUS).voiceDiscarded == "Recording cancelled. It is in the Trash."
                        && s(.zhTW).voiceDiscarded.hasSuffix("已丟到垃圾桶。") && s(.zhHK).voiceDiscarded.hasSuffix("已移至垃圾桶。"),
                     "the Trash said once the folder is there, in the past")
        suite.expect(s(.de).noticeDiscardKeptDetail == "Bei deinen Besprechungen"
                        && s(.de).voiceDiscardKept.hasSuffix("Er bleibt bei deinen Besprechungen.")
                        && s(.de).voiceDiscardedDeleted.contains("Ihr Ordner ließ sich nicht in den Papierkorb legen: "),
                     "German says « du » throughout")
        suite.expect(s(.fr).noticeDiscardKept == "Annulé · dossier toujours là" && s(.ja).noticeDiscardKept == "取り消し · フォルダはそのまま"
                        && s(.enUS).offerNameHidden == "Name hidden in screen shares"
                        && s(.ru).offerNameHidden == "Название скрыто при показе",
                     "the reviewed short notices")
        suite.expect(s(.zhTW).pillStopCancels.contains("丟到垃圾桶") && s(.zhTW).policyAlwaysCaption.contains("丟到垃圾桶")
                        && s(.zhTW).voiceAutoStartedFormat.contains("丟到垃圾桶")
                        && [s(.zhHK).pillStopCancels, s(.zhHK).noticeDiscardedTrash, s(.zhHK).voiceDiscardedDeleted,
                            s(.zhHK).voiceDiscardKept].allSatisfy { $0.contains("移至垃圾桶") },
                     "Taiwan throws into the Trash, Hong Kong moves to it")
        suite.expect(s(.ptBR).voiceDiscarded.contains("Lixo") && s(.ptBR).pillStopCancels.contains("Lixo"),
                     "Brazil keeps macOS's « Lixo »")
        let all = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(all.allSatisfy { $0.noticeAskAgain("Meet").count <= 28 && $0.noticeAskAgain("Meet").contains("Meet")
                                        && $0.voiceAskAgain("Meet").contains("Meet") && !$0.voiceCancelled.isEmpty },
                     "the choice taken back fits the island and names the provider in every language")
        suite.expect(s(.fr).consentIntroFrontWindow.contains("Pour proposer d’enregistrer un Google Meet, elle lit les titres des fenêtres et repère les apps qui utilisent le micro.")
                        && s(.ja).consentIntroFrontWindow.contains("Google Meet の録画を提案するために")
                        && s(.de).consentIntroFrontWindow.contains("Um die Aufnahme eines Google Meet anzubieten,"),
                     "the first-use reminder offers to record, not to offer a Meet")
        suite.expect(all.allSatisfy { !$0.detectionLookalike.contains("offered") }
                        && s(.enUS).detectionLookalike.hasSuffix("could be taken for a meeting."),
                     "the lookalike warning says a page could be taken for a meeting")
    }
}
