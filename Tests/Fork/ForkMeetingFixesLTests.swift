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
}
