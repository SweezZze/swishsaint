// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The meeting apps' fixes after the review of PR 3 (K): each probe of the
/// review played as the person would meet it, through the real provider
/// table, the resolver and the machine wired as the service wires them,
/// then the page's choices and the words.
enum ForkMeetingFixesKTests {
    typealias Machine = ForkMeetingMachine
    typealias Effect = ForkMeetingMachine.Effect
    typealias Window = ForkMeetingWindowSignal
    typealias Microphone = ForkMeetingMicSignal

    static func run(_ suite: TestSuite) {
        aSecondMeetingInTheSameApp(suite)
        alwaysAgainForTheNextMeeting(suite)
        aNewMeetingIsNotTheOldOneBack(suite)
        aMicrophoneTestNeverStarts(suite)
        aLongMicrophoneProvesTeams(suite)
        faceTimeIsOnlyOffered(suite)
        aWebCallLivesOnItsMicrophone(suite)
        aChannelCalledHuddle(suite)
    }

    // MARK: - Fixtures

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let folder = URL(fileURLWithPath: "/tmp/Meetings/2026-10-19 10h00", isDirectory: true)
    private static let ownPID: Int32 = 999
    private static let chromePID: Int32 = 100
    private static let zoomPID: Int32 = 500
    private static let slackPID: Int32 = 300
    private static let settings = ForkMeetingCaptureSettings(target: .window, systemAudio: .app, microphone: "meeting",
                                                             quality: .standard)
    private static let ready = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                     microphoneAllowed: true, officialRecorderBusy: false)
    private static let zoomMicrophone = Microphone(appBundle: "us.zoom.xos", appPID: zoomPID, pid: zoomPID,
                                                   processBundle: "us.zoom.xos")
    private static let slackMicrophone = Microphone(appBundle: "com.tinyspeck.slackmacgap", appPID: slackPID, pid: 301,
                                                    processBundle: "com.tinyspeck.slackmacgap.helper")
    private static let chromeMicrophone = Microphone(appBundle: "com.google.Chrome", appPID: chromePID, pid: 101,
                                                     processBundle: "com.google.Chrome.helper")

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func request() -> ForkMeetingStartRequest {
        ForkMeetingStartRequest(settings: settings, facts: ready)
    }

    private static func zoomWindow(_ title: String) -> Window {
        Window(bundle: "us.zoom.xos", pid: zoomPID, title: title, onScreen: true, windowID: 1)
    }

    private static func slackWindow(_ title: String, id: UInt32 = 2) -> Window {
        Window(bundle: "com.tinyspeck.slackmacgap", pid: slackPID, title: title, onScreen: true, windowID: id)
    }

    private static func chrome(_ title: String, id: UInt32 = 7) -> Window {
        Window(bundle: "com.google.Chrome", pid: chromePID, title: title, onScreen: true, windowID: id)
    }

    private static func identity(_ value: String) -> ForkMeetingIdentity { ForkMeetingIdentity(value) }

    /// The service's loop, pure: each end (a countdown of 15 s), the
    /// meetings on with what a start would be asked with, then the time.
    private struct Live {
        var resolver: ForkMeetingResolver
        var machine = Machine()
        var effects: [Effect] = []
        var lastResolution = ForkMeetingResolution()

        init(_ json: String = ForkMeetingPolicies.defaultJSON) {
            resolver = ForkMeetingResolver(ownPID: ForkMeetingFixesKTests.ownPID, policies: ForkMeetingPolicies(json: json))
        }

        @discardableResult
        mutating func read(_ seconds: TimeInterval, windows: [Window]? = nil, microphones: [Microphone]? = nil,
                           calendar: [ForkMeetingCalendarHint]? = nil) -> ForkMeetingResolution {
            let now = ForkMeetingFixesKTests.at(seconds)
            let resolution = resolver.resolve(ForkMeetingReading(at: now, windows: windows, microphones: microphones,
                                                                 calendar: calendar))
            lastResolution = resolution
            for identity in resolution.ended { run(.endProbable(identity, countdown: 15), now) }
            var facts = ForkMeetingFixesKTests.ready
            facts.meetingsOnMicrophone = resolution.onMicrophone
            run(.candidates(resolution.candidates, ForkMeetingStartRequest(settings: ForkMeetingFixesKTests.settings,
                                                                           facts: facts)), now)
            run(.tick, now)
            return resolution
        }

        mutating func send(_ event: Machine.Event, _ seconds: TimeInterval) {
            run(event, ForkMeetingFixesKTests.at(seconds))
        }

        private mutating func run(_ event: Machine.Event, _ now: Date) {
            let produced = machine.handle(event, now: now)
            for case let .silence(identity) in produced { resolver.silence(identity, at: now) }
            effects += produced
        }

        var starts: [(config: ForkMeetingCaptureConfig, token: ForkMeetingToken)] {
            effects.compactMap {
                if case let .startCapture(config, token) = $0 { return (config, token) }
                return nil
            }
        }

        var offers: [ForkMeetingOffer] {
            effects.compactMap {
                if case let .showOffer(offer) = $0 { return offer }
                return nil
            }
        }

        var said: [ForkMeetingAnnouncement] {
            effects.compactMap {
                if case let .announce(announcement) = $0 { return announcement }
                return nil
            }
        }

        /// The capture runs, then is stopped and its file closed: idle again.
        mutating func recordThenStop(_ token: ForkMeetingToken, from seconds: TimeInterval, to end: TimeInterval) {
            send(.captureStarted(token, folder: ForkMeetingFixesKTests.folder), seconds)
            send(.stop, end)
            send(.writerFinished(token, .finished(recordedSeconds: end - seconds)), end)
        }
    }

    // MARK: - K.B1: one meeting after the other in the same app

    /// Probe P1: two Zoom meetings in the same Zoom process, the second
    /// 3 minutes after the first one, set aside with "Not now", ended.
    private static func aSecondMeetingInTheSameApp(_ suite: TestSuite) {
        var zoom = Live()
        zoom.read(0, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        let first = zoom.read(2, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        suite.expect(first.candidates.map(\.identity) == [identity("zoom:500#1")] && zoom.offers.count == 1,
                     "a Zoom meeting is that Zoom's first, offered")
        zoom.send(.dismiss(.thisTime), 3)
        var ended: [ForkMeetingIdentity] = []
        for second in stride(from: 4.0, through: 40, by: 2) {
            ended += zoom.read(second, windows: [zoomWindow("Zoom Workplace")], microphones: []).ended
        }
        suite.expect(ended == [identity("zoom:500#1")] && !zoom.resolver.isSilenced(identity("zoom:500#1")),
                     "set aside with Not now, it ends, and its set-aside goes with it")
        zoom.effects = []
        var second: [ForkMeetingCandidate] = []
        for seconds in stride(from: 220.0, through: 230, by: 2) {
            second = zoom.read(seconds, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone]).candidates
        }
        suite.expect(second.map(\.identity) == [identity("zoom:500#2")] && zoom.offers.count == 1
                        && zoom.offers.first?.candidate.identity == identity("zoom:500#2"),
                     "the next meeting in that Zoom, 3 minutes later, is another one: offered")

        // While it lasts, a meeting keeps its number: Zoom muted, its
        // window still there, then its microphone again.
        var muted = Live()
        muted.read(0, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        muted.read(2, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        muted.read(5, windows: [zoomWindow("Zoom Meeting")], microphones: [])
        let back = muted.read(8, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        suite.expect(back.candidates.map(\.identity) == [identity("zoom:500#1")] && muted.offers.count == 1,
                     "a meeting going on stays the same one, offered once")
    }

    /// Probes P1b and P1c: "Always" for Zoom records each meeting, the
    /// first one's set-aside never reaching the next.
    private static func alwaysAgainForTheNextMeeting(_ suite: TestSuite) {
        var zoom = Live(#"{"zoom":"always"}"#)
        zoom.read(-3, microphones: [zoomMicrophone])
        zoom.read(-1, microphones: [zoomMicrophone])
        zoom.read(0, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        suite.expect(zoom.starts.map(\.config.origin) == [.always]
                        && zoom.starts.first?.config.meeting?.identity == identity("zoom:500#1")
                        && zoom.resolver.isSilenced(identity("zoom:500#1")),
                     "Always records the first meeting, set aside while it lasts")
        guard let first = zoom.starts.first?.token else { return }
        zoom.recordThenStop(first, from: 1, to: 30)
        for second in stride(from: 31.0, through: 60, by: 3) {
            zoom.read(second, windows: [zoomWindow("Zoom Workplace")], microphones: [])
        }
        suite.expect(!zoom.resolver.isSilenced(identity("zoom:500#1")) && zoom.machine.phase == .idle,
                     "over, its set-aside is forgotten")
        zoom.read(180, microphones: [zoomMicrophone])
        zoom.read(182, microphones: [zoomMicrophone])
        zoom.read(183, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        suite.expect(zoom.starts.map(\.config.origin) == [.always, .always]
                        && zoom.starts.last?.config.meeting?.identity == identity("zoom:500#2"),
                     "the next meeting in that Zoom, within 10 minutes, starts on its own too")
    }

    /// A new meeting in the same app during "Meeting over?" is not the old
    /// one coming back: the countdown goes on.
    private static func aNewMeetingIsNotTheOldOneBack(_ suite: TestSuite) {
        var zoom = Live(#"{"zoom":"always"}"#)
        zoom.read(-3, microphones: [zoomMicrophone])
        zoom.read(-1, microphones: [zoomMicrophone])
        zoom.read(0, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        guard let token = zoom.starts.first?.token else { return suite.expect(false, "Always starts Zoom") }
        zoom.send(.captureStarted(token, folder: folder), 1)
        for second in stride(from: 3.0, through: 24, by: 3) {
            zoom.read(second, windows: [zoomWindow("Zoom Workplace")], microphones: [])
        }
        guard case .endingSoon = zoom.machine.phase else {
            return suite.expect(false, "the first meeting over, its countdown runs")
        }
        zoom.effects = []
        zoom.read(25, microphones: [zoomMicrophone])
        zoom.read(27, microphones: [zoomMicrophone])
        let isEnding: Bool = {
            if case .endingSoon = zoom.machine.phase { return true }
            return false
        }()
        suite.expect(isEnding && !zoom.said.contains(.meetingBack)
                        && zoom.lastResolution.candidates.map(\.identity) == [identity("zoom:500#2")],
                     "Zoom's microphone again for a new meeting: the countdown of the first goes on")
    }

    // MARK: - K.I1: what "Always" for an app waits for

    /// Probe P2: Slack's microphone test in its preferences (3 s), Always
    /// for Slack, its main window in front.
    private static func aMicrophoneTestNeverStarts(_ suite: TestSuite) {
        let main = slackWindow("Alice (DM) - Acme - Slack", id: 9)
        var test = Live(#"{"slack":"always"}"#)
        test.read(0, windows: [main], microphones: [slackMicrophone])
        test.read(2, windows: [main], microphones: [slackMicrophone])
        test.read(4, windows: [main], microphones: [slackMicrophone])
        suite.expect(test.starts.isEmpty && test.offers.isEmpty,
                     "a 3 s microphone test with Always for Slack starts nothing, and is not offered while it runs")
        test.read(6, windows: [main], microphones: [])
        suite.expect(test.starts.isEmpty && test.offers.map(\.candidate.identity) == [identity("slack:300#1")],
                     "its microphone closed, it is only offered, as any call")

        var huddle = Live(#"{"slack":"always"}"#)
        huddle.read(0, windows: [main], microphones: [slackMicrophone])
        huddle.read(2, windows: [main], microphones: [slackMicrophone])
        huddle.read(3, windows: [main, slackWindow("Huddle: #design", id: 10)], microphones: [slackMicrophone])
        suite.expect(huddle.starts.map(\.config.origin) == [.always] && huddle.offers.isEmpty
                        && huddle.starts.first?.config.meeting?.windowID == 10,
                     "a huddle window: Always records the huddle, filmed in it")

        var settings = Live(#"{"zoom":"always"}"#)
        for second in stride(from: 0.0, through: 14, by: 2) {
            settings.read(second, windows: [zoomWindow("Settings")], microphones: [zoomMicrophone])
        }
        suite.expect(settings.starts.isEmpty && settings.offers.isEmpty, "Zoom testing its microphone: nothing yet")
        settings.read(16, windows: [zoomWindow("Settings")], microphones: [zoomMicrophone])
        suite.expect(settings.starts.isEmpty && settings.offers.count == 1,
                     "15 s without a meeting window: offered, never started on its own")
    }

    /// Teams, Webex and Discord have no meeting window: their microphone
    /// open 15 s, longer than a test, proves the call.
    private static func aLongMicrophoneProvesTeams(_ suite: TestSuite) {
        let teams = Microphone(appBundle: "com.microsoft.teams2", appPID: 700, pid: 701,
                               processBundle: "com.microsoft.teams2.helper")
        var call = Live(#"{"teams":"always"}"#)
        for second in stride(from: 0.0, through: 14, by: 2) { call.read(second, microphones: [teams]) }
        suite.expect(call.starts.isEmpty && call.offers.isEmpty,
                     "Always for Teams: its microphone open under 15 s, neither started nor offered")
        call.read(16, microphones: [teams])
        suite.expect(call.starts.map(\.config.origin) == [.always] && call.offers.isEmpty,
                     "15 s: the call starts on its own")

        var test = Live(#"{"teams":"always"}"#)
        test.read(0, microphones: [teams])
        test.read(2, microphones: [teams])
        test.read(3, microphones: [])
        test.read(6, microphones: [])
        suite.expect(test.starts.isEmpty && test.offers.count == 1, "a 3 s test in Teams: only offered")

        var locked = Live(#"{"teams":"always"}"#)
        locked.send(.locked, -1)
        locked.read(0, microphones: [teams])
        locked.read(2, microphones: [teams])
        suite.expect(locked.starts.isEmpty && locked.offers.count == 1,
                     "a locked screen offers at once, as before: nobody to cancel")
    }

    // MARK: - K.I2: FaceTime is offered, never "Always"

    private static func faceTimeIsOnlyOffered(_ suite: TestSuite) {
        let table = ForkMeetingProviderTable.current
        let call = table.attributing([Microphone(appBundle: nil, pid: 77, processBundle: "com.apple.avconferenced")],
                                     running: ["com.apple.FaceTime": 600])
        var faceTime = Live(#"{"facetime":"always"}"#)
        for second in stride(from: 0.0, through: 30, by: 2) { faceTime.read(second, microphones: call) }
        let offer = faceTime.offers.first
        suite.expect(faceTime.starts.isEmpty && faceTime.offers.count == 1
                        && offer.map(ForkMeetingOfferText.showsAlways) == false,
                     "a FaceTime call (or an iPhone's relayed) with Always stored: offered, its menu without Always")
        faceTime.effects = []
        faceTime.send(.always(request()), 31)
        suite.expect(faceTime.starts.map(\.config.origin) == [.offered]
                        && !faceTime.effects.contains { if case .setPolicy = $0 { return true } else { return false } },
                     "an Always that reaches its offer only records it, and stores nothing")
        let row = table.policyRows.first { $0.id == "facetime" }
        suite.expect(row?.allowsAlways == false && row?.offersRelayedCalls == true
                        && table.policyRows.filter(\.offersRelayedCalls).map(\.id) == ["facetime"],
                     "FaceTime's row has no Always, and says an iPhone call relayed may be offered")
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(french.detectionFaceTimeRelayed == "Un appel téléphonique relayé par l’iPhone peut aussi être proposé."
                        && AppLanguage.allCases.allSatisfy { !ForkMeetingStrings.strings($0).detectionFaceTimeRelayed.isEmpty },
                     "« Un appel téléphonique relayé par l’iPhone peut aussi être proposé », in every language")
    }

    // MARK: - K.I3: the other web calls live on the microphone

    /// Probe P5: Zoom's web client, the call over and the microphone free,
    /// the tab still titled "Zoom".
    private static func aWebCallLivesOnItsMicrophone(_ suite: TestSuite) {
        let tab = chrome("Zoom")
        var web = Live()
        web.read(-5, microphones: [chromeMicrophone])
        web.read(0, windows: [tab], microphones: [chromeMicrophone])
        let born = web.read(3, windows: [tab], microphones: [chromeMicrophone])
        suite.expect(born.candidates.map(\.identity) == [identity("web:100:Zoom")]
                        && born.candidates.first?.windowID == 7 && born.candidates.first?.name == "Zoom",
                     "Zoom's web client with the browser's microphone: a call, named and filmed by its tab")
        var ended: [ForkMeetingIdentity] = []
        var alive: [TimeInterval] = []
        for second in stride(from: 6.0, through: 60, by: 3) {
            let resolution = web.read(second, windows: [tab], microphones: [])
            ended += resolution.ended
            if !resolution.candidates.isEmpty { alive.append(second) }
        }
        suite.expect(ended == [identity("web:100:Zoom")] && alive.last.map { $0 < 30 } == true,
                     "the microphone free, the tab still titled Zoom: the call ends after 20 s")

        var background = Live()
        background.read(-5, microphones: [chromeMicrophone])
        background.read(0, windows: [chrome("Point hebdo | Jitsi Meet")], microphones: [chromeMicrophone])
        background.read(3, windows: [chrome("Point hebdo | Jitsi Meet")], microphones: [chromeMicrophone])
        var lives = true
        for second in stride(from: 6.0, through: 60, by: 3) {
            let resolution = background.read(second, windows: [chrome("Inbox - Gmail")], microphones: [chromeMicrophone])
            lives = lives && resolution.candidates.map(\.name) == ["Point hebdo"]
        }
        suite.expect(lives, "another tab in front, the browser's microphone open: the Jitsi room goes on, named")
    }

    // MARK: - K.I4: Slack's huddle window, exactly

    /// Probes P3a and P3b: a Slack channel named huddle-notes (Slack writes
    /// its title without the "#").
    private static func aChannelCalledHuddle(_ suite: TestSuite) {
        let rules = ForkMeetingTitleRuleSet.slackHuddle
        suite.expect(ForkMeetingTitleRules.verdict("huddle-notes (Channel) - Acme - Slack", rules: rules) == .none
                        && ForkMeetingTitleRules.verdict("huddle (Channel) - Acme - Slack", rules: rules) == .none
                        && ForkMeetingTitleRules.verdict("Huddle – Acme – Slack", rules: rules)
                            == .meeting(code: nil, name: nil),
                     "« huddle-notes (Channel) - Acme - Slack » is no huddle window, « Huddle – Acme – Slack » is")
        let channel = slackWindow("huddle-notes (Channel) - Acme - Slack")
        var slack = Live()
        slack.read(0, windows: [channel], microphones: [slackMicrophone])
        let born = slack.read(2, windows: [channel], microphones: [slackMicrophone])
        suite.expect(born.candidates.map(\.identity) == [identity("slack:300#1")] && born.candidates.first?.windowID == nil,
                     "a call in Slack with that channel open: Slack's, its window not that channel's")
        var ended: [ForkMeetingIdentity] = []
        for second in stride(from: 4.0, through: 60, by: 2) {
            ended += slack.read(second, windows: [channel], microphones: []).ended
        }
        suite.expect(ended == [identity("slack:300#1")],
                     "its microphone gone, the channel still open: the call ends after 20 s")
    }
}
