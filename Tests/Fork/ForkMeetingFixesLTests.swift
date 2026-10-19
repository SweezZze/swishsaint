// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The meeting apps' fixes after the second review of PR 3 (L): each probe
/// of that review (R1 to R8) played as the person would meet it, through
/// the real provider table, the resolver and the machine wired as the
/// service wires them, then the page and the words.
enum ForkMeetingFixesLTests {
    typealias Machine = ForkMeetingMachine
    typealias Effect = ForkMeetingMachine.Effect
    typealias Window = ForkMeetingWindowSignal
    typealias Microphone = ForkMeetingMicSignal

    static func run(_ suite: TestSuite) {
        aTeamsChatBesideAMeetCall(suite)
        teamsOnTheWebOnlyOnACall(suite)
        theSameAppMeetingBack(suite)
        notNowHoldsAfterAGap(suite)
        backToBackMeetings(suite)
        theWindowOnScreen(suite)
        aHuddleTitledWithAHyphen(suite)
        theProofDuringTheOffer(suite)
        alwaysInTheMenuOnlyWithTheMicrophone(suite)
        moreCalendarLinks(suite)
        theWords(suite)
    }

    // MARK: - Fixtures

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let folder = URL(fileURLWithPath: "/tmp/Meetings/2026-10-19 10h00", isDirectory: true)
    private static let ownPID: Int32 = 999
    private static let settings = ForkMeetingCaptureSettings(target: .window, systemAudio: .app, microphone: "meeting",
                                                             quality: .standard)
    private static let ready = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                     microphoneAllowed: true, officialRecorderBusy: false)
    private static let teamsMicrophone = Microphone(appBundle: "com.microsoft.teams2", appPID: 700, pid: 701,
                                                    processBundle: "com.microsoft.teams2.helper")
    private static let zoomMicrophone = Microphone(appBundle: "us.zoom.xos", appPID: 500, pid: 500,
                                                   processBundle: "us.zoom.xos")
    private static let chromeMicrophone = Microphone(appBundle: "com.google.Chrome", appPID: 100, pid: 101,
                                                     processBundle: "com.google.Chrome.helper")

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func identity(_ value: String) -> ForkMeetingIdentity { ForkMeetingIdentity(value) }

    private static func zoomWindow(_ title: String, id: UInt32 = 1) -> Window {
        Window(bundle: "us.zoom.xos", pid: 500, title: title, onScreen: true, windowID: id)
    }

    private static func chrome(_ title: String, id: UInt32) -> Window {
        Window(bundle: "com.google.Chrome", pid: 100, title: title, onScreen: true, windowID: id)
    }

    /// The service's loop, pure: each end (a countdown of 15 s), the
    /// meetings on with what a start would be asked with, then the time.
    private struct Live {
        var resolver: ForkMeetingResolver
        var machine = Machine()
        var effects: [Effect] = []
        var last = ForkMeetingResolution()

        init(_ json: String) {
            resolver = ForkMeetingResolver(ownPID: ForkMeetingFixesLTests.ownPID, policies: ForkMeetingPolicies(json: json))
        }

        @discardableResult
        mutating func read(_ seconds: TimeInterval, windows: [Window]? = nil, microphones: [Microphone]? = nil,
                           calendar: [ForkMeetingCalendarHint]? = nil) -> ForkMeetingResolution {
            let now = ForkMeetingFixesLTests.at(seconds)
            let resolution = resolver.resolve(ForkMeetingReading(at: now, windows: windows, microphones: microphones,
                                                                 calendar: calendar))
            last = resolution
            for identity in resolution.ended { run(.endProbable(identity, countdown: 15), now) }
            var facts = ForkMeetingFixesLTests.ready
            facts.meetingsOnMicrophone = resolution.onMicrophone
            run(.candidates(resolution.candidates, ForkMeetingStartRequest(settings: ForkMeetingFixesLTests.settings,
                                                                           facts: facts)), now)
            run(.tick, now)
            return resolution
        }

        mutating func send(_ event: Machine.Event, _ seconds: TimeInterval) { run(event, ForkMeetingFixesLTests.at(seconds)) }

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

        var isRecording: Bool {
            if case .recording = machine.phase { return true }
            return false
        }
    }

    // MARK: - L.B1: a page without a code never takes a call's microphone

    /// Probe R8: a Google Meet call in one Chrome window, Teams on the web
    /// open on its chat in another.
    private static func aTeamsChatBesideAMeetCall(_ suite: TestSuite) {
        let meet = chrome("Meet – abc-defg-hij", id: 7)
        let chat = chrome("Chat | Microsoft Teams", id: 8)
        var live = Live(#"{"meet":"ask"}"#)
        live.read(-5, microphones: [chromeMicrophone])
        for second in stride(from: 0.0, through: 10, by: 2) {
            live.read(second, windows: [meet, chat], microphones: [chromeMicrophone])
        }
        suite.expect(live.last.candidates.map(\.identity) == [identity("meet:abc-defg-hij")]
                        && live.offers.map(\.candidate.identity) == [identity("meet:abc-defg-hij")],
                     "a Meet call beside Teams' chat in the same browser: the Meet call alone, offered once")
        live.send(.dismiss(.thisTime), 11)
        live.effects = []
        for second in stride(from: 12.0, through: 40, by: 2) {
            live.read(second, windows: [meet, chat], microphones: [chromeMicrophone])
        }
        suite.expect(live.offers.isEmpty && live.last.candidates.map(\.identity) == [identity("meet:abc-defg-hij")],
                     "Not now on the Meet call: nothing else is offered, the chat never becomes a call")

        // Even a web call's own title waits while the Meet call holds the
        // browser's microphone: it is that call's.
        var zoom = Live(#"{"meet":"ask","web":"ask"}"#)
        zoom.read(-5, microphones: [chromeMicrophone])
        zoom.read(0, windows: [meet], microphones: [chromeMicrophone])
        zoom.read(2, windows: [meet], microphones: [chromeMicrophone])
        for second in stride(from: 4.0, through: 20, by: 2) {
            zoom.read(second, windows: [meet, chrome("Zoom", id: 9)], microphones: [chromeMicrophone])
        }
        suite.expect(zoom.last.candidates.map(\.identity) == [identity("meet:abc-defg-hij")],
                     "a « Zoom » tab while a Meet call holds the microphone is not born")
    }

    private static func teamsOnTheWebOnlyOnACall(_ suite: TestSuite) {
        let rules = ForkMeetingTitleRuleSet.teamsWeb
        let calls = ["Réunion | Microsoft Teams", "Meeting with Alice | Microsoft Teams", "Meeting | Microsoft Teams",
                     "Call with Bob | Microsoft Teams", "Appel avec Alice | Microsoft Teams",
                     "Meet now | Microsoft Teams", "Meeting: Point hebdo | Microsoft Teams",
                     "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0", "https://teams.live.com/meet/9876543210"]
        let pages = ["Chat | Microsoft Teams", "Calendar | Microsoft Teams", "Calls | Microsoft Teams",
                     "Meetings | Microsoft Teams", "Appels | Microsoft Teams", "Activity | Microsoft Teams",
                     "Point hebdo | Microsoft Teams", "https://teams.microsoft.com/v2/", "Microsoft Teams",
                     " | Microsoft Teams", "Teams tips | Microsoft Teams Blog"]
        let wrong = calls.filter { ForkMeetingTitleRules.verdict($0, rules: rules) != .meeting(code: nil, name: nil) }
            + pages.filter { ForkMeetingTitleRules.verdict($0, rules: rules) != .none }
        suite.expect(wrong.isEmpty,
                     "« … | Microsoft Teams » is a call only when its page says one, never its chat: \(wrong)")
        var chat = Live(#"{"web":"ask"}"#)
        chat.read(-5, microphones: [chromeMicrophone])
        for second in stride(from: 0.0, through: 12, by: 3) {
            chat.read(second, windows: [chrome("Chat | Microsoft Teams", id: 8)], microphones: [chromeMicrophone])
        }
        suite.expect(chat.offers.isEmpty, "Teams' chat with the browser's microphone in use: nothing")
    }

    // MARK: - L.I1: an app's meeting back soon after its end

    /// Probe R1: Teams recording on "Always", its microphone gone 22 s
    /// (muted, a device change), back during the countdown.
    private static func theSameAppMeetingBack(_ suite: TestSuite) {
        var teams = Live(#"{"teams":"always"}"#)
        for second in stride(from: 0.0, through: 16, by: 2) { teams.read(second, microphones: [teamsMicrophone]) }
        guard let token = teams.starts.first?.token else { return suite.expect(false, "Always starts the Teams call") }
        teams.send(.captureStarted(token, folder: folder), 17)
        for second in stride(from: 18.0, through: 40, by: 2) { teams.read(second, microphones: []) }
        guard case .endingSoon = teams.machine.phase else {
            return suite.expect(false, "its microphone gone 20 s: the countdown runs")
        }
        teams.effects = []
        for second in stride(from: 42.0, through: 70, by: 2) { teams.read(second, microphones: [teamsMicrophone]) }
        suite.expect(teams.said == [.meetingBack] && teams.isRecording && teams.starts.isEmpty
                        && teams.last.candidates.map(\.identity) == [identity("teams#1")],
                     "its microphone back during the countdown: the same call back, the recording goes on")

        // Past 60 s, a new call.
        var later = Live(#"{"teams":"ask"}"#)
        later.read(0, microphones: [teamsMicrophone])
        later.read(2, microphones: [teamsMicrophone])
        later.send(.dismiss(.thisTime), 3)
        var ended: [ForkMeetingIdentity] = []
        for second in stride(from: 4.0, through: 30, by: 2) { ended += later.read(second, microphones: []).ended }
        later.effects = []
        later.read(100, microphones: [teamsMicrophone])
        later.read(102, microphones: [teamsMicrophone])
        suite.expect(ended == [identity("teams#1")] && later.offers.map(\.candidate.identity) == [identity("teams#2")],
                     "back 76 s after its end: another call, offered")

        // A countdown longer than 60 s keeps it the same meeting while it runs.
        var long = ForkMeetingResolver(ownPID: ownPID, policies: ForkMeetingPolicies(json: #"{"teams":"ask"}"#))
        long.endCountdown = 120
        _ = long.resolve(ForkMeetingReading(at: at(0), microphones: [teamsMicrophone]))
        _ = long.resolve(ForkMeetingReading(at: at(2), microphones: [teamsMicrophone]))
        var gone: [ForkMeetingIdentity] = []
        for second in stride(from: 4.0, through: 30, by: 2) {
            gone += long.resolve(ForkMeetingReading(at: at(second), microphones: [])).ended
        }
        _ = long.resolve(ForkMeetingReading(at: at(110), microphones: [teamsMicrophone]))
        let back = long.resolve(ForkMeetingReading(at: at(112), microphones: [teamsMicrophone]))
        suite.expect(gone == [identity("teams#1")] && back.candidates.map(\.identity) == [identity("teams#1")],
                     "with a 120 s countdown, back 86 s after its end: still the same call")

        // Zoom's meeting window gone, then its microphone again: a new
        // meeting, as before.
        var zoom = Live(#"{"zoom":"ask"}"#)
        zoom.read(0, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        zoom.read(2, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        for second in stride(from: 4.0, through: 30, by: 2) {
            zoom.read(second, windows: [zoomWindow("Zoom Workplace", id: 9)], microphones: [])
        }
        zoom.read(32, microphones: [zoomMicrophone])
        let next = zoom.read(34, microphones: [zoomMicrophone])
        suite.expect(next.candidates.map(\.identity) == [identity("zoom:500#2")],
                     "Zoom's meeting window gone, its microphone again: a new meeting")
        zoom.read(36, windows: [zoomWindow("Zoom Workplace", id: 9)], microphones: [])
        var same = Live(#"{"zoom":"ask"}"#)
        same.read(0, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        same.read(2, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        same.send(.dismiss(.thisTime), 3)
        for second in stride(from: 4.0, through: 30, by: 2) {
            same.read(second, windows: [zoomWindow("Zoom Workplace", id: 9)], microphones: [])
        }
        same.effects = []
        same.read(40, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        let window = same.read(42, windows: [zoomWindow("Zoom Meeting")], microphones: [zoomMicrophone])
        suite.expect(window.candidates.map(\.identity) == [identity("zoom:500#1")] && same.offers.isEmpty,
                     "its very meeting window back within 60 s: the same meeting, still set aside")
    }

    /// Probe R1b: Teams on "Offer", "Not now", its microphone gone 25 s
    /// and back.
    private static func notNowHoldsAfterAGap(_ suite: TestSuite) {
        var teams = Live(#"{"teams":"ask"}"#)
        teams.read(0, microphones: [teamsMicrophone])
        teams.read(2, microphones: [teamsMicrophone])
        teams.send(.dismiss(.thisTime), 3)
        var ended: [ForkMeetingIdentity] = []
        for second in stride(from: 4.0, through: 30, by: 2) { ended += teams.read(second, microphones: []).ended }
        teams.effects = []
        for second in stride(from: 32.0, through: 40, by: 2) { teams.read(second, microphones: [teamsMicrophone]) }
        suite.expect(ended == [identity("teams#1")] && teams.offers.isEmpty
                        && teams.last.candidates.map(\.identity) == [identity("teams#1")]
                        && teams.last.candidates.first?.silenced == true,
                     "Not now, then its microphone gone 25 s and back: the same call, still set aside, not offered")
    }

    // MARK: - L.I2: two meetings back to back

    /// Probe R4: the first Zoom meeting's window closes, the second's opens
    /// 8 s later.
    private static func backToBackMeetings(_ suite: TestSuite) {
        var zoom = Live(#"{"zoom":"ask"}"#)
        zoom.read(0, windows: [zoomWindow("Zoom Meeting", id: 1)], microphones: [zoomMicrophone])
        zoom.read(2, windows: [zoomWindow("Zoom Meeting", id: 1)], microphones: [zoomMicrophone])
        zoom.send(.dismiss(.thisTime), 3)
        zoom.read(4, windows: [zoomWindow("Zoom Workplace", id: 9)], microphones: [])
        zoom.effects = []
        var ended: [ForkMeetingIdentity] = []
        for second in stride(from: 12.0, through: 30, by: 2) {
            ended += zoom.read(second, windows: [zoomWindow("Zoom Meeting", id: 2)], microphones: [zoomMicrophone]).ended
        }
        suite.expect(ended == [identity("zoom:500#1")] && zoom.last.candidates.map(\.identity) == [identity("zoom:500#2")]
                        && zoom.offers.map(\.candidate.identity) == [identity("zoom:500#2")]
                        && zoom.offers.first?.candidate.windowID == 2,
                     "another meeting window once the first's is gone: the first is over, the next one offered")

        // A meeting window redrawn while its microphone runs (a share) is
        // the same meeting.
        var share = Live(#"{"zoom":"ask"}"#)
        share.read(0, windows: [zoomWindow("Zoom Meeting", id: 1)], microphones: [zoomMicrophone])
        share.read(2, windows: [zoomWindow("Zoom Meeting", id: 1)], microphones: [zoomMicrophone])
        share.read(4, windows: [zoomWindow("Zoom Workplace", id: 9)], microphones: [zoomMicrophone])
        share.effects = []
        var shareEnded: [ForkMeetingIdentity] = []
        for second in stride(from: 6.0, through: 20, by: 2) {
            shareEnded += share.read(second, windows: [zoomWindow("Zoom Meeting", id: 3)],
                                     microphones: [zoomMicrophone]).ended
        }
        suite.expect(shareEnded.isEmpty && share.last.candidates.map(\.identity) == [identity("zoom:500#1")]
                        && share.offers.allSatisfy { $0.candidate.identity == identity("zoom:500#1") },
                     "its window redrawn with the microphone on: the same meeting, followed in its new window")
    }

    // MARK: - L.I3: the app's window on screen, or the whole screen

    private static func theWindowOnScreen(_ suite: TestSuite) {
        func window(_ id: UInt32, onScreen: Bool, titled: Bool = true) -> ForkMeetingWindowCandidate {
            ForkMeetingWindowCandidate(id: id, pid: 700, layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 900, height: 900),
                                       ownerIsRegularApp: true, onScreen: onScreen, titled: titled)
        }
        let teams = ForkMeetingCandidate(identity: identity("teams#1"), provider: "teams", providerName: "Microsoft Teams",
                                         providerShortName: "Teams", appBundle: "com.microsoft.teams2", pid: 700,
                                         defaultSound: .app, policy: .ask, silenced: false, bornAt: t0)
        // Probe R3, as `.optionAll` really lists them: a closed window still
        // titled before the one on screen.
        let chosen = ForkMeetingAppsSupport.window(for: teams, in: [window(44, onScreen: false), window(60, onScreen: true)],
                                                   ownPID: ownPID)
        suite.expect(chosen == 60, "the app's window on screen is filmed, never one off screen listed before it")
        let away = ForkMeetingAppsSupport.window(for: teams, in: [window(44, onScreen: false), window(45, onScreen: false)],
                                                 ownPID: ownPID)
        suite.expect(away == nil, "none on screen: the whole screen is filmed")
        suite.expect(ForkMeetingAppsSupport.filmsMainWindow(teams, found: 60)
                        && !ForkMeetingAppsSupport.filmsMainWindow(teams, found: nil),
                     "a call found by its microphone is filmed in its app's main window")
        var huddle = teams
        huddle.windowID = 12
        suite.expect(ForkMeetingAppsSupport.window(for: huddle, in: [], ownPID: ownPID) == 12
                        && !ForkMeetingAppsSupport.filmsMainWindow(huddle, found: 12),
                     "a meeting window of its own is filmed as it is")

        let french = ForkMeetingStrings.strings(.fr)
        let english = ForkMeetingStrings.strings(.enUS)
        let main = ForkMeetingOfferText.capture(target: .window, windowApp: "Teams", hasWindow: true, mainWindow: true,
                                                sound: .app, soundApp: "Teams", microphone: .named("AirPods"),
                                                strings: french)
        suite.expect(main.hasPrefix("Fenêtre\u{00A0}:\u{00A0}Teams (fenêtre principale) · son"),
                     "the offer says « Fenêtre : Teams (fenêtre principale) »: \(main)")
        let whole = ForkMeetingOfferText.capture(target: .window, windowApp: "Teams", hasWindow: false, mainWindow: false,
                                                 sound: .app, soundApp: "Teams", microphone: .named("AirPods"),
                                                 strings: english)
        suite.expect(whole.hasPrefix("Whole screen"), "and « Whole screen » without one: \(whole)")
        let missing = AppLanguage.allCases.filter {
            let text = ForkMeetingStrings.strings($0).offerMainWindow("Teams")
            return !text.hasPrefix("Teams") || text == "Teams" || text.contains("%")
        }
        suite.expect(missing.isEmpty, "every language says it is the app's main window: \(missing)")
    }

    // MARK: - L.I4: Slack's huddle window with a hyphen

    /// Probe R2: Slack titles its windows with " - ".
    private static func aHuddleTitledWithAHyphen(_ suite: TestSuite) {
        let rules = ForkMeetingTitleRuleSet.slackHuddle
        let huddles = ["Huddle - Acme - Slack", "Huddle with Alice - Acme - Slack", "Huddle: design - Acme - Slack",
                       "Huddle – Acme – Slack", "Huddle"]
        let others = ["huddle-notes (Channel) - Acme - Slack", "huddle (Channel) - Acme - Slack", "Slack | Huddle",
                      "Alice (DM) - Acme - Slack", "huddles - Acme - Slack"]
        let wrong = huddles.filter { ForkMeetingTitleRules.verdict($0, rules: rules) != .meeting(code: nil, name: nil) }
            + others.filter { ForkMeetingTitleRules.verdict($0, rules: rules) != .none }
        suite.expect(wrong.isEmpty, "« Huddle - Acme - Slack » is a huddle window, « huddle-notes » no huddle: \(wrong)")
    }

    // MARK: - L.I5: the proof during the offer made at 15 s

    /// Probe R6: "Always" for Zoom, its microphone 15 s before its meeting
    /// window (the audio preview, the waiting room).
    private static func theProofDuringTheOffer(_ suite: TestSuite) {
        var zoom = Live(#"{"zoom":"always"}"#)
        for second in stride(from: 0.0, through: 16, by: 2) {
            zoom.read(second, windows: [zoomWindow("Zoom Workplace", id: 9)], microphones: [zoomMicrophone])
        }
        suite.expect(zoom.starts.isEmpty && zoom.offers.count == 1 && zoom.offers.first?.awaitedProof == true,
                     "15 s without its meeting window: offered")
        zoom.read(18, windows: [zoomWindow("Zoom Meeting", id: 1)], microphones: [zoomMicrophone])
        suite.expect(zoom.starts.map(\.config.origin) == [.always] && zoom.starts.first?.config.meeting?.windowID == 1
                        && zoom.effects.contains(.hideOffer),
                     "its meeting window while the offer waits for an answer: it starts on its own, in that window")
        if let token = zoom.starts.first?.token {
            zoom.effects = []
            zoom.send(.captureStarted(token, folder: folder), 19)
            suite.expect(zoom.effects.contains { if case .showUndo = $0 { return true } else { return false } }
                            && zoom.said == [.autoStarted(seconds: 5)],
                         "with « Cancel » at hand, as Always")
        }

        var answered = Live(#"{"zoom":"always"}"#)
        for second in stride(from: 0.0, through: 16, by: 2) {
            answered.read(second, windows: [zoomWindow("Zoom Workplace", id: 9)], microphones: [zoomMicrophone])
        }
        answered.send(.dismiss(.thisTime), 17)
        answered.read(18, windows: [zoomWindow("Zoom Meeting", id: 1)], microphones: [zoomMicrophone])
        suite.expect(answered.starts.isEmpty, "Not now answered first: nothing starts")

        var asked = Live(#"{"zoom":"ask"}"#)
        asked.read(0, microphones: [zoomMicrophone])
        asked.read(2, microphones: [zoomMicrophone])
        asked.read(4, windows: [zoomWindow("Zoom Meeting", id: 1)], microphones: [zoomMicrophone])
        suite.expect(asked.starts.isEmpty && asked.offers.first?.awaitedProof == false,
                     "on Offer, its meeting window starts nothing")

        let rows = ForkMeetingProviderTable.current.policyRows
        let says = { (json: String, signal: Bool) in
            ForkMeetingDetectionSupport.saysAlwaysDelay(ForkMeetingPolicies(json: json), microphoneSignal: signal, rows: rows)
        }
        suite.expect(says(#"{"teams":"always"}"#, true) && says(#"{"zoom":"always"}"#, true)
                        && !says(#"{"meet":"always"}"#, true) && !says(ForkMeetingPolicies.defaultJSON, true)
                        && !says(#"{"teams":"always"}"#, false) && !says(#"{"facetime":"always"}"#, true),
                     "the page says what Always waits for while an app's row shows Always")
        suite.expect(ForkMeetingStrings.strings(.enUS).detectionAlwaysDelay
                        == "Teams, Webex and Discord: recorded on their own 15 s into the call. Zoom and Slack: once their meeting window opens, otherwise offered."
                        && ForkMeetingStrings.strings(.fr).detectionAlwaysDelay
                            == "Teams, Webex et Discord\u{00A0}: enregistrés seuls 15\u{00A0}s après le début de l’appel. Zoom et Slack\u{00A0}: dès que leur fenêtre de réunion s’ouvre, sinon proposés."
                        && AppLanguage.allCases.allSatisfy { language in
                            let text = ForkMeetingStrings.strings(language).detectionAlwaysDelay
                            return ["Teams", "Webex", "Discord", "Zoom", "Slack", "15"].allSatisfy(text.contains)
                        },
                     "in every language")
    }

    // MARK: - L.I6: "Always" in the offer's menu only with the microphone

    private static func alwaysInTheMenuOnlyWithTheMicrophone(_ suite: TestSuite) {
        var zoom = Live(#"{"zoom":"ask"}"#)
        zoom.read(0, windows: [zoomWindow("Zoom Meeting")])
        zoom.read(3, windows: [zoomWindow("Zoom Meeting")])
        guard let offer = zoom.offers.first else { return suite.expect(false, "a Zoom meeting window is offered") }
        suite.expect(ForkMeetingOfferText.showsAlways(offer, microphoneSignal: true)
                        && !ForkMeetingOfferText.showsAlways(offer, microphoneSignal: false),
                     "« Always for Zoom » in the menu only on a Mac that can say which app uses the microphone")
    }

    // MARK: - L.m: the calendar's other links

    /// Probe R5.
    private static func moreCalendarLinks(_ suite: TestSuite) {
        typealias Link = ForkMeetingCalendarLink
        let found: [(String, Set<Link>)] = [
            ("https://teams.microsoft.com/meet/26372771178?p=abcDEF", [.teams]),
            ("https://teams.live.com/meet/9876543210", [.teams]),
            ("https://zoom.us/my/alice", [.zoom]),
            ("https://acme.zoomgov.com/j/1612345678", [.zoom]),
            ("https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19&data=x",
             [.teams]),
            ("<https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fus02web.zoom.us%2Fj%2F812%3Fpwd%3Dx&reserved=0>",
             [.zoom]),
            ("https://acme.webex.com/acme/j.php?MTID=m1", [.webex]),
            ("https://safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com", []),
        ]
        let wrong = found.filter { Link.found(in: $0.0) != $0.1 }.map(\.0)
        suite.expect(wrong.isEmpty, "Teams' and Zoom's other links, and Outlook's safe links, are read: \(wrong)")
        let safeMeet = "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fmeet.google.com%2Fabc-defg-hij&data=1"
        suite.expect(ForkMeetingTitleRules.meetCode(inLink: Link.unwrapped(safeMeet)) == "abc-defg-hij",
                     "a Meet link in a safe link gives its code")
        let plain = "https://us02web.zoom.us/j/812?pwd=x"
        let wrapped = "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fus02web.zoom.us%2Fj%2F812%3Fpwd%3Dx"
        suite.expect(!Link.prints(in: plain).isEmpty && Link.prints(in: plain) == Link.prints(in: wrapped)
                        && Link.prints(in: plain).isDisjoint(with: Link.prints(in: "https://zoom.us/j/999")),
                     "one link, wrapped or not, has one print; another link another")

        func event(_ title: String, _ text: String, from start: TimeInterval, to end: TimeInterval) -> ForkMeetingCalendarHint {
            ForkMeetingCalendarHint(title: title, meetCode: nil, startsAt: at(start), endsAt: at(end),
                                    links: Link.found(in: text), linkPrints: Link.prints(in: text))
        }
        let work = event("Point hebdo", wrapped, from: -300, to: 1500)
        let home = event("Point hebdo", plain, from: -300, to: 1500)
        suite.expect(Link.event(.zoom, at: at(0), in: [work, home])?.title == "Point hebdo",
                     "one event in two calendars (the same link, the same times) is one: it names the call")
        suite.expect(Link.event(.zoom, at: at(0), in: [work, event("Revue", "https://zoom.us/j/999", from: -300, to: 1500)])
                        == nil,
                     "two events at the same times with two links name nothing")
        var zoom = Live(#"{"zoom":"ask"}"#)
        zoom.read(-1, calendar: [work, home])
        zoom.read(0, microphones: [zoomMicrophone])
        suite.expect(zoom.read(2, microphones: [zoomMicrophone]).candidates.first?.name == "Point hebdo",
                     "the Zoom call is named after it")
    }

    // MARK: - L: the words

    private static func theWords(_ suite: TestSuite) {
        let s = { ForkMeetingStrings.strings($0) }
        suite.expect(s(.fr).policyNeverCaption == "Un service réglé sur Jamais n’est jamais proposé. Vous pouvez quand même enregistrer à la main."
                        && s(.fr).voiceNeverWebCalls == "Les visios dans un navigateur, sauf Google Meet, ne seront plus proposées."
                        && s(.tr).detectionUnavailable == "Bu Mac’te tanınmıyor",
                     "« Vous pouvez quand même enregistrer à la main », « sauf Google Meet », « tanınmıyor »")
        suite.expect(s(.enUS).detectionCaption
                        == "Recognizes your calls in the Zoom, Teams, Slack, FaceTime, Webex and Discord apps, and in a browser in Google Meet, Zoom, Teams, Whereby and Jitsi Meet, even behind other windows or on another desktop, and offers to record them."
                        && s(.fr).detectionCaption
                            == "Reconnaît vos appels dans les apps Zoom, Teams, Slack, FaceTime, Webex et Discord, et dans un navigateur sur Google Meet, Zoom, Teams, Whereby et Jitsi Meet, même derrière d’autres fenêtres ou sur un autre bureau, et propose de les enregistrer.",
                     "the page says which apps, and which calls in a browser, are recognized")
        let names = ["Zoom", "Teams", "Slack", "FaceTime", "Webex", "Discord", "Google Meet", "Whereby", "Jitsi Meet"]
        let short = AppLanguage.allCases.filter { language in
            let caption = s(language).detectionCaption
            return !names.allSatisfy(caption.contains) || caption.components(separatedBy: "Zoom").count != 3
                || caption.components(separatedBy: "Teams").count != 3
        }
        suite.expect(short.isEmpty, "in every language, Zoom and Teams named once as apps, once in a browser: \(short)")
    }
}
