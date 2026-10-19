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
        theAppsOwnWindow(suite)
        neverForTheOtherWebCalls(suite)
        anAppByItsName(suite)
        noAlwaysBeforeMacOS14_4(suite)
        namedByTheCalendar(suite)
        oneWebexCall(suite)
        tenNewTapsAtMost(suite)
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

    // MARK: - K.I5, K.I6: the app's own window, wherever it is

    private static func theAppsOwnWindow(_ suite: TestSuite) {
        func window(_ id: UInt32, pid: Int32, _ width: CGFloat, _ height: CGFloat, onScreen: Bool = true,
                    titled: Bool = true) -> ForkMeetingWindowCandidate {
            ForkMeetingWindowCandidate(id: id, pid: pid, layer: 0, alpha: 1,
                                       bounds: CGRect(x: 0, y: 0, width: width, height: height), ownerIsRegularApp: true,
                                       onScreen: onScreen, titled: titled)
        }
        // Probe P2's windows: Slack's small preferences in front of its main window.
        var test = Live(#"{"slack":"ask"}"#)
        test.read(0, windows: [slackWindow("Alice (DM) - Acme - Slack", id: 9)], microphones: [slackMicrophone])
        test.read(2, microphones: [slackMicrophone])
        guard let slack = test.lastResolution.candidates.first else { return suite.expect(false, "Slack's call is seen") }
        let list = [window(1, pid: 42, 1600, 1000), window(10, pid: slackPID, 600, 500), window(9, pid: slackPID, 1400, 900)]
        suite.expect(ForkMeetingAppsSupport.window(for: slack, in: list, ownPID: ownPID) == 10,
                     "a call found by its microphone is filmed in its app's window most in front, not its largest")
        let away = [window(1, pid: 42, 1600, 1000), window(20, pid: slackPID, 1400, 900, onScreen: false, titled: false),
                    window(21, pid: slackPID, 1400, 900, onScreen: false)]
        suite.expect(ForkMeetingAppsSupport.window(for: slack, in: away, ownPID: ownPID) == 21,
                     "minimized or on another Space, its titled window is filmed; a spare one never shown is not")
        suite.expect(ForkMeetingAppsSupport.window(for: slack, in: [window(1, pid: 42, 1600, 1000)], ownPID: ownPID) == nil,
                     "no window of its own: the display is filmed, never the other app's window in front")
        let french = ForkMeetingStrings.strings(.fr)
        let line = ForkMeetingOfferText.capture(target: .window, windowApp: "Slack", hasWindow: false, sound: .app,
                                                soundApp: "Slack", microphone: .named("AirPods"), strings: french)
        suite.expect(line.hasPrefix("Écran entier"), "and its offer says so: « \(line) »")
    }

    // MARK: - K.I7: one "Never" for the other web calls, said so

    /// Probe P4: "Never" from a Jitsi Meet offer covers every web call.
    private static func neverForTheOtherWebCalls(_ suite: TestSuite) {
        var jitsi = Live()
        let tab = chrome("Point hebdo | Jitsi Meet")
        jitsi.read(-5, microphones: [chromeMicrophone])
        jitsi.read(0, windows: [tab], microphones: [chromeMicrophone])
        jitsi.read(3, windows: [tab], microphones: [chromeMicrophone])
        guard let offer = jitsi.offers.first else { return suite.expect(false, "the Jitsi room is offered") }
        let english = ForkMeetingStrings.strings(.enUS)
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(ForkMeetingOfferText.neverTitle(offer.candidate, strings: english) == "Never for other web calls"
                        && ForkMeetingOfferText.neverTitle(offer.candidate, strings: french)
                            == "Jamais pour les autres visios web",
                     "its menu says « Jamais pour les autres visios web », not « Jamais pour Jitsi Meet »")
        jitsi.effects = []
        jitsi.send(.dismiss(.never), 4)
        let policy = jitsi.effects.compactMap { effect -> String? in
            if case let .setPolicy(policy, provider) = effect { return "\(provider):\(policy.rawValue)" }
            return nil
        }
        let notices = jitsi.effects.compactMap { effect -> ForkMeetingNotice? in
            if case let .notice(notice) = effect { return notice }
            return nil
        }
        suite.expect(policy == ["web:never"] && notices == [.neverOfferedWebCalls] && jitsi.said == [.neverOfferedWebCalls]
                        && ForkMeetingNotice.neverOfferedWebCalls.title(french) == "Autres visios web\u{00A0}: Jamais"
                        && ForkMeetingNotice.neverOfferedWebCalls.detail(french) == french.noticeNeverDetail
                        && ForkMeetingAnnouncement.neverOfferedWebCalls.text(english)
                            == "Calls in a browser other than Google Meet will no longer be offered.",
                     "Never stores web:never, and says it for every web call: « Autres visios web : Jamais »")
        let row = ForkMeetingProviderTable.current.policyRows.last
        suite.expect(row?.id == "web" && row?.name == nil && french.detectionOtherWebCalls == "Autres visios web",
                     "the page's row is « Autres visios web »")

        var zoom = Live()
        zoom.read(0, microphones: [zoomMicrophone])
        zoom.read(2, microphones: [zoomMicrophone])
        zoom.effects = []
        zoom.send(.dismiss(.never), 3)
        suite.expect(zoom.said == [.neverOffered("Zoom")]
                        && zoom.offers.isEmpty
                        && ForkMeetingOfferText.neverTitle(ForkMeetingCandidate(
                            identity: identity("zoom:500#1"), provider: "zoom", providerName: "Zoom",
                            providerShortName: "Zoom", appBundle: "us.zoom.xos", pid: zoomPID, defaultSound: .app,
                            policy: .ask, silenced: false, bornAt: t0), strings: english) == "Never for Zoom",
                     "an app's Never stays its own: « Never for Zoom »")
        let long = AppLanguage.allCases.filter { ForkMeetingStrings.strings($0).noticeNeverWebCalls.count > 28 }
        suite.expect(long.isEmpty, "the notice fits the island in every language: \(long)")
    }

    // MARK: - K.I8: an app by its brand

    private static func anAppByItsName(_ suite: TestSuite) {
        var zoom = Live()
        zoom.read(0, microphones: [zoomMicrophone])
        zoom.read(2, microphones: [zoomMicrophone])
        var web = Live()
        web.read(-5, microphones: [chromeMicrophone])
        web.read(0, windows: [chrome("Whereby")], microphones: [chromeMicrophone])
        web.read(3, windows: [chrome("Whereby")], microphones: [chromeMicrophone])
        guard let app = zoom.offers.first?.candidate, let page = web.offers.first?.candidate else {
            return suite.expect(false, "Zoom and Whereby are offered")
        }
        suite.expect(ForkMeetingAppsSupport.appName(for: app) == "Zoom" && ForkMeetingAppsSupport.appName(for: page) == nil
                        && ForkMeetingAppsSupport.appName(for: nil) == nil && app.appBundle == "us.zoom.xos",
                     "Zoom's app is « Zoom » in the offer and the pill, not « zoom.us »; a web call keeps its browser's name")
        let english = ForkMeetingStrings.strings(.enUS)
        let line = ForkMeetingOfferText.capture(target: .window, windowApp: ForkMeetingAppsSupport.appName(for: app),
                                                hasWindow: true, sound: .app,
                                                soundApp: ForkMeetingAppsSupport.appName(for: app),
                                                microphone: .named("AirPods"), strings: english)
        suite.expect(line == "Window:\u{00A0}Zoom · sound:\u{00A0}Zoom · mic:\u{00A0}AirPods", "« \(line) »")
        let filmed = ForkMeetingServiceSupport.filmed(target: .window, appName: ForkMeetingAppsSupport.appName(for: app),
                                                      noWindowToFilm: false, strings: english)
        suite.expect(filmed.contains("Zoom") && !filmed.contains("zoom.us"), "the pill too: « \(filmed) »")
    }

    // MARK: - K.I9: no "Always" before macOS 14.4

    private static func noAlwaysBeforeMacOS14_4(_ suite: TestSuite) {
        let rows = ForkMeetingProviderTable.current.policyRows
        suite.expect(rows.filter { $0.showsAlways(microphoneSignal: true) }.map(\.id)
                        == ["meet", "zoom", "teams", "slack", "webex", "discord"]
                        && rows.allSatisfy { !$0.showsAlways(microphoneSignal: false) },
                     "Always on every row but FaceTime and the web calls; before macOS 14.4 on none, Meet and Zoom included")
        let meet = rows.first { $0.id == "meet" }
        suite.expect(meet?.shown(.always, microphoneSignal: false) == .ask && meet?.shown(.always, microphoneSignal: true) == .always
                        && meet?.shown(.never, microphoneSignal: false) == .never,
                     "an Always stored shows as Offer there, as it acts: it never starts without the microphone")
        var noSignal = Live(#"{"zoom":"always"}"#)
        noSignal.read(0, windows: [zoomWindow("Zoom Meeting")])
        noSignal.read(3, windows: [zoomWindow("Zoom Meeting")])
        noSignal.read(30, windows: [zoomWindow("Zoom Meeting")])
        suite.expect(noSignal.starts.isEmpty && noSignal.offers.count == 1,
                     "a Zoom meeting window with no microphone signal: offered, never started")
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(french.detectionAlwaysUnavailable.hasPrefix("«\u{00A0}Toujours\u{00A0}» n’est pas disponible")
                        && AppLanguage.allCases.allSatisfy { !ForkMeetingStrings.strings($0).detectionAlwaysUnavailable.isEmpty },
                     "and the page says so, in every language")
    }

    // MARK: - K.I10: an app's meeting named by the calendar

    private static func namedByTheCalendar(_ suite: TestSuite) {
        typealias Link = ForkMeetingCalendarLink
        suite.expect(Link.found(in: "Join: https://us02web.zoom.us/j/81234567890?pwd=abc") == [.zoom]
                        && Link.found(in: "<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0>")
                            == [.teams]
                        && Link.found(in: "https://acme.webex.com/acme/j.php?MTID=m123") == [.webex]
                        && Link.found(in: "https://acme.webex.com/meet/alice") == [.webex]
                        && Link.found(in: "Salle : https://whereby.com/point-hebdo") == [.whereby]
                        && Link.found(in: "https://meet.jit.si/PointHebdo\nhttps://zoom.us/j/123") == [.jitsi, .zoom],
                     "an event's Zoom, Teams, Webex, Whereby or Jitsi Meet link is told by its kind")
        suite.expect(Link.found(in: "Notes about zoom.us pricing; https://teams.microsoft.com/v2/; webex.com; whereby")
                        .isEmpty && Link.found(in: "").isEmpty,
                     "a page of Zoom, Teams' own site or a word is no meeting link")

        func event(_ title: String, _ link: Link?, from start: TimeInterval, to end: TimeInterval) -> ForkMeetingCalendarHint {
            ForkMeetingCalendarHint(title: title, meetCode: nil, startsAt: at(start), endsAt: at(end),
                                    links: link.map { [$0] } ?? [])
        }
        let weekly = event("Point hebdo", .zoom, from: -300, to: 1500)
        var zoom = Live()
        zoom.read(-1, calendar: [weekly, event("Déjeuner", nil, from: -300, to: 1500)])
        zoom.read(0, microphones: [zoomMicrophone])
        let named = zoom.read(2, microphones: [zoomMicrophone]).candidates.first
        suite.expect(named?.calendarTitle == "Point hebdo" && named?.name == "Point hebdo",
                     "a Zoom call while the only event going on holds a Zoom link: named after it")

        var early = Live()
        early.read(-1, calendar: [event("Point hebdo", .zoom, from: 500, to: 2000)])
        early.read(0, microphones: [zoomMicrophone])
        suite.expect(early.read(2, microphones: [zoomMicrophone]).candidates.first?.calendarTitle == "Point hebdo",
                     "starting within 10 minutes counts as going on")
        var later = Live()
        later.read(-1, calendar: [event("Point hebdo", .zoom, from: 900, to: 2000),
                                  event("Hier", .zoom, from: -4000, to: -720)])
        later.read(0, microphones: [zoomMicrophone])
        suite.expect(later.read(2, microphones: [zoomMicrophone]).candidates.first?.calendarTitle == nil,
                     "one in 15 minutes, or over 12 minutes ago, names nothing")
        var two = Live()
        two.read(-1, calendar: [weekly, event("Revue client", .zoom, from: 0, to: 1800)])
        two.read(0, microphones: [zoomMicrophone])
        suite.expect(two.read(2, microphones: [zoomMicrophone]).candidates.first?.name == "Zoom",
                     "two events going on with a Zoom link: neither names it")
        var teams = Live()
        teams.read(-1, calendar: [weekly])
        let teamsMicrophone = Microphone(appBundle: "com.microsoft.teams2", appPID: 700, pid: 701)
        teams.read(0, microphones: [teamsMicrophone])
        suite.expect(teams.read(2, microphones: [teamsMicrophone]).candidates.first?.name == "Microsoft Teams",
                     "a Zoom event never names a Teams call")

        var whereby = Live()
        whereby.read(-6, microphones: [chromeMicrophone], calendar: [event("Atelier", .whereby, from: -60, to: 3600)])
        whereby.read(0, windows: [chrome("Whereby")], microphones: [chromeMicrophone])
        suite.expect(whereby.read(3, windows: [chrome("Whereby")], microphones: [chromeMicrophone]).candidates.first?.name
                        == "Atelier",
                     "a Whereby call in a browser too")
    }

    // MARK: - K.m: one Webex call in its two apps

    /// Probe P6: one Webex call whose two apps both hold the microphone.
    private static func oneWebexCall(_ suite: TestSuite) {
        let spark = Microphone(appBundle: "Cisco-Systems.Spark", appPID: 300, pid: 301, processBundle: "Cisco-Systems.Spark")
        let manager = Microphone(appBundle: "com.webex.meetingmanager", appPID: 310, pid: 311,
                                 processBundle: "com.webex.meetingmanager")
        var webex = Live()
        webex.read(0, microphones: [spark, manager])
        webex.read(2, microphones: [spark, manager])
        webex.send(.dismiss(.thisTime), 3)
        webex.read(4, microphones: [spark, manager])
        webex.read(6, microphones: [manager])
        let call = webex.read(8, microphones: [manager]).candidates
        suite.expect(webex.offers.count == 1 && webex.offers.first?.candidate.identity == identity("webex#1")
                        && call.map(\.identity) == [identity("webex#1")],
                     "one Webex call in its two apps is one meeting, offered once")
        suite.expect(call.first?.pid == 310 && call.first?.appBundle == "com.webex.meetingmanager",
                     "the app still on the microphone is the one heard and filmed")
        var ended: [ForkMeetingIdentity] = []
        for second in stride(from: 10.0, through: 40, by: 2) { ended += webex.read(second, microphones: []).ended }
        suite.expect(ended == [identity("webex#1")], "and it ends once neither uses the microphone")
    }

    // MARK: - K.m: ten new taps at most per recording

    private static func tenNewTapsAtMost(_ suite: TestSuite) {
        var repair = ForkMeetingTapRepair()
        var tried = 0
        for _ in 0..<50 {
            if repair.tryAgain() { tried += 1 }
            repair.heard()
        }
        suite.expect(tried == 10 && ForkMeetingTapRepair.total == 10 && !repair.tryAgain(),
                     "a tap that keeps losing its reader and hearing again gets 10 new ones in all, then the track gives up")
        var fresh = ForkMeetingTapRepair()
        suite.expect(fresh.tryAgain() && fresh.tryAgain() && !fresh.tryAgain(),
                     "still two in a row at most without hearing anything")
    }
}
