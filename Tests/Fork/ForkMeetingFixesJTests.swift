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
}
