// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The detection's fixes after the PR 2 reviews (H1): each rule as the
/// person would notice it, played through the resolver and the machine
/// wired as the service wires them.
enum ForkMeetingFixesH1Tests {
    typealias Machine = ForkMeetingMachine
    typealias Effect = ForkMeetingMachine.Effect
    typealias Window = ForkMeetingWindowSignal
    typealias Microphone = ForkMeetingMicSignal
    typealias Support = ForkMeetingDetectionSupport

    static func run(_ suite: TestSuite) {
        codesOnlyInMeetTitles(suite)
        namedTitlesNeedTheMicrophone(suite)
        alwaysNeedsAMicrophoneAndAnUnlockedScreen(suite)
        greyedAlwaysWaitsForAClick(suite)
        twoMeetInARow(suite)
        endPageOfAnotherTab(suite)
        setAsideAfterAGlimpse(suite)
        codeAppearing(suite)
        endWhileStarting(suite)
        byHandAfterNotNow(suite)
        alwaysChosenThenCancelled(suite)
        cancelledThenQuit(suite)
        foldedOfferStopsTheClock(suite)
        staleFreeSpace(suite)
        cleanNames(suite)
        titlesGone(suite)
        pageText(suite)
    }

    // MARK: - Fixtures

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let folder = URL(fileURLWithPath: "/tmp/Meetings/2026-10-19 10h00", isDirectory: true)
    private static let second = URL(fileURLWithPath: "/tmp/Meetings/2026-10-19 11h00", isDirectory: true)
    private static let settings = ForkMeetingCaptureSettings(target: .window, systemAudio: .app, microphone: "meeting",
                                                             quality: .standard)
    private static let ready = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                     microphoneAllowed: true, officialRecorderBusy: false)
    private static let recorderBusy = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                            microphoneAllowed: true, officialRecorderBusy: true)
    private static let token1 = ForkMeetingToken(value: 1)
    private static let token2 = ForkMeetingToken(value: 2)
    private static let ownPID: Int32 = 999
    private static let chromePID: Int32 = 100
    private static let codeA = "abc-defg-hij"
    private static let codeB = "xyz-qrst-uvw"
    private static let meetA = ForkMeetingIdentity("meet:abc-defg-hij")
    private static let meetB = ForkMeetingIdentity("meet:xyz-qrst-uvw")
    private static let chromeMicrophone = Microphone(appBundle: "com.google.Chrome", appPID: chromePID, pid: 101,
                                                     processBundle: "com.google.Chrome.helper",
                                                     inputDevice: "BuiltInMicrophoneDevice")

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func request(_ facts: ForkMeetingStartFacts = ready) -> ForkMeetingStartRequest {
        ForkMeetingStartRequest(settings: settings, facts: facts)
    }

    private static func chrome(_ title: String, window: UInt32 = 7) -> Window {
        Window(bundle: "com.google.Chrome", pid: chromePID, title: title, onScreen: true, windowID: window)
    }

    private static func verdict(_ title: String) -> ForkMeetingTitleVerdict {
        ForkMeetingTitleRules.verdict(title, rules: .googleMeet)
    }

    /// The service's loop, pure (as `ForkMeetingDetectionBehaviorTests`
    /// plays it): each end, the meetings on with what a start would be
    /// asked with, then the time; `silence` and `setPolicy` fed back.
    private struct Live {
        var resolver: ForkMeetingResolver
        var machine = Machine()
        var apps: ForkMeetingPolicies
        var facts = ForkMeetingFixesH1Tests.ready
        private var log: [Effect] = []
        private var lastTick: TimeInterval = -.infinity

        init(apps json: String = ForkMeetingPolicies.defaultJSON) {
            apps = ForkMeetingPolicies(json: json)
            resolver = ForkMeetingResolver(ownPID: ForkMeetingFixesH1Tests.ownPID, policies: apps)
        }

        mutating func read(_ seconds: TimeInterval, windows: [Window]? = nil, microphones: [Microphone]? = nil,
                           titlesUnreadable: Bool = false) {
            let now = ForkMeetingFixesH1Tests.at(seconds)
            resolver.policies = apps
            let resolution = resolver.resolve(ForkMeetingReading(at: now, windows: windows, microphones: microphones,
                                                                 titlesUnreadable: titlesUnreadable))
            for identity in resolution.ended { run(.endProbable(identity, countdown: 15), now) }
            var asked = facts
            asked.meetingsOnMicrophone = resolution.onMicrophone
            run(.candidates(resolution.candidates, ForkMeetingStartRequest(settings: settings, facts: asked)), now)
            run(.tick, now)
        }

        mutating func readEvery3s(from start: TimeInterval, to end: TimeInterval, windows: [Window]) {
            for seconds in stride(from: start, through: end, by: 3) {
                clock(until: seconds)
                read(seconds, windows: windows)
            }
        }

        mutating func send(_ event: Machine.Event, _ seconds: TimeInterval) {
            clock(until: seconds)
            run(event, ForkMeetingFixesH1Tests.at(seconds))
        }

        mutating func clock(until seconds: TimeInterval) {
            var next = lastTick.isFinite ? lastTick + 1 : seconds.rounded(.down)
            while next <= seconds {
                if Support.clockRuns(phase: machine.phase) { run(.tick, ForkMeetingFixesH1Tests.at(next)) }
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

    // MARK: - H1.1

    /// A code counts only in a title Google Meet writes; three, four and
    /// three letters elsewhere are words.
    private static func codesOnlyInMeetTitles(_ suite: TestSuite) {
        let pages = ["Bitcoin hits all-time-low – Le Monde", "Fix the-null-ptr bug · Pull Request",
                     "Comparing main...fix-auth-bug · octo/app · GitHub", "branch fix-auth-bug",
                     "The one-time-pad, explained - YouTube", "Notes: abc-defg-hij"]
        let read = pages.filter { verdict($0) != .none }
        suite.expect(read.isEmpty, "a 3-4-3 word outside a Meet title is not a code: \(read)")
        suite.expect(verdict("Meet – Point hebdo – abc-defg-hij") == .meeting(code: codeA, name: "Point hebdo")
                        && verdict("Meet - abc-defg-hij") == .meeting(code: codeA, name: nil)
                        && verdict("Meet: abc-defg-hij") == .meeting(code: codeA, name: nil)
                        && verdict("abc-defg-hij – Google Meet") == .meeting(code: codeA, name: nil)
                        && verdict("Point hebdo – abc-defg-hij – Google Meet") == .meeting(code: codeA, name: "Point hebdo")
                        && verdict("abc-defg-hij") == .meeting(code: codeA, name: nil),
                     "Meet's own titles keep their code: « Meet – x – code », « Meet - code », « Meet: code », « code – Google Meet »")
        suite.expect(verdict("Meet – Bitcoin hits all-time-low") == .meeting(code: nil, name: "Bitcoin hits all-time-low"),
                     "in a Meet title, a word inside the name is not its code either")
        suite.expect(verdict("Meet - Glass Animals (Official Video) - YouTube")
                        == .meeting(code: nil, name: "Glass Animals (Official Video) - YouTube"),
                     "« Meet - Glass Animals (Official Video) - YouTube » is a name without a code")
    }

    private static func namedTitlesNeedTheMicrophone(_ suite: TestSuite) {
        var github = Live()
        github.read(-5, microphones: [chromeMicrophone])
        github.readEvery3s(from: 0, to: 60, windows: [chrome("Comparing main...fix-auth-bug · octo/app · GitHub"),
                                                      chrome("Fix the-null-ptr bug · Pull Request", window: 8),
                                                      chrome("Bitcoin hits all-time-low – Le Monde", window: 9)])
        suite.expect(github.take().isEmpty, "a branch, a pull request and an article, the microphone open: nothing offered")

        var video = Live()
        video.readEvery3s(from: 0, to: 120, windows: [chrome("Meet - Glass Animals (Official Video) - YouTube")])
        suite.expect(video.take().isEmpty, "a video called « Meet - … » without the microphone: nothing, however long")

        var probe = Live()
        probe.read(0, windows: [chrome("Meet – Point hebdo")], microphones: [chromeMicrophone])
        probe.read(0.4, microphones: [])
        probe.readEvery3s(from: 3, to: 60, windows: [chrome("Meet – Point hebdo")])
        suite.expect(probe.take().isEmpty, "nor with a microphone opened 400 ms and closed")

        var call = Live()
        call.read(-5, microphones: [chromeMicrophone])
        call.read(0, windows: [chrome("Meet – Point hebdo – " + codeA)])
        suite.expect(offers(call.take()).map(\.candidate.name) == ["Point hebdo"],
                     "« Meet – Point hebdo – abc-defg-hij », Chrome's microphone open: offered at once")

        var named = Live()
        named.read(-5, microphones: [chromeMicrophone])
        named.readEvery3s(from: 0, to: 3, windows: [chrome("Meet – Point hebdo")])
        suite.expect(offers(named.take()).map(\.candidate.name) == ["Point hebdo"],
                     "« Meet – Point hebdo », the microphone open: offered at the second reading")

        // The page says it: a page copying a Meet title and using the
        // microphone could be offered.
        var copy = Live()
        copy.read(-5, microphones: [chromeMicrophone])
        copy.readEvery3s(from: 0, to: 3, windows: [chrome("Meet - Glass Animals (Official Video) - YouTube")])
        suite.expect(offers(copy.take()).count == 1,
                     "a page imitating a Meet title while the microphone runs is offered, never recorded on its own")
    }

    private static func alwaysNeedsAMicrophoneAndAnUnlockedScreen(_ suite: TestSuite) {
        let always = #"{"meet":"always"}"#
        var silent = Live(apps: always)
        silent.readEvery3s(from: 0, to: 3, windows: [chrome("Meet – " + codeA)])
        let silentEffects = silent.take()
        suite.expect(starts(silentEffects).isEmpty && offers(silentEffects).map(\.candidate.identity) == [meetA],
                     "Always without the microphone: offered, not started")

        var justOpened = Live(apps: always)
        justOpened.read(0, windows: [chrome("Meet – " + codeA)])
        justOpened.read(2.5, microphones: [chromeMicrophone])
        justOpened.read(3, windows: [chrome("Meet – " + codeA)])
        let justEffects = justOpened.take()
        suite.expect(starts(justEffects).isEmpty && offers(justEffects).count == 1,
                     "nor with a microphone open for half a second")

        var locked = Live(apps: always)
        locked.send(.locked, -10)
        locked.read(-5, microphones: [chromeMicrophone])
        locked.read(0, windows: [chrome("Meet – " + codeA)])
        let lockedEffects = locked.take()
        suite.expect(starts(lockedEffects).isEmpty && offers(lockedEffects).count == 1,
                     "a locked screen: offered, nobody being there to cancel")

        var unlocked = Live(apps: always)
        unlocked.send(.locked, -10)
        unlocked.send(.unlocked, -8)
        unlocked.read(-5, microphones: [chromeMicrophone])
        unlocked.read(0, windows: [chrome("Meet – " + codeA)])
        let unlockedEffects = unlocked.take()
        suite.expect(starts(unlockedEffects).map(\.origin) == [.always] && offers(unlockedEffects).isEmpty,
                     "the microphone open for a second and the screen unlocked: Always starts it on its own")
    }

    /// H1.11: an offer greyed at its birth (or offered for want of the
    /// microphone) is seen by the person: freed, it waits for a click.
    private static func greyedAlwaysWaitsForAClick(_ suite: TestSuite) {
        var greyed = Live(apps: #"{"meet":"always"}"#)
        greyed.facts = recorderBusy
        greyed.read(-5, microphones: [chromeMicrophone])
        greyed.read(0, windows: [chrome("Meet – " + codeA)])
        greyed.readEvery3s(from: 3, to: 9, windows: [chrome("Meet – " + codeA)])
        greyed.facts = ready
        greyed.readEvery3s(from: 12, to: 60, windows: [chrome("Meet – " + codeA)])
        let effects = greyed.take()
        suite.expect(starts(effects).isEmpty && offers(effects).last?.blocked == nil
                        && offers(effects).first?.blocked == .officialRecorderBusy,
                     "Always greyed by the official recorder, then freed: the offer lights up and waits")

        var late = Live(apps: #"{"meet":"always"}"#)
        late.readEvery3s(from: 0, to: 3, windows: [chrome("Meet – " + codeA)])
        late.read(4, microphones: [chromeMicrophone])
        late.readEvery3s(from: 6, to: 30, windows: [chrome("Meet – " + codeA)])
        suite.expect(starts(late.take()).isEmpty, "offered for want of the microphone, it is not started when it opens")
        late.send(.accept(request()), 31)
        suite.expect(starts(late.take()).map(\.origin) == [.offered], "Record still records it")
    }

    // MARK: - H1.2, H1.3

    /// One Meet closed with ⌘W, the next one opened in the same browser: the
    /// browser's microphone is the new meeting's.
    private static func twoMeetInARow(_ suite: TestSuite) {
        var live = Live()
        live.read(-5, microphones: [chromeMicrophone])
        live.read(0, windows: [chrome("Meet – " + codeA)])
        live.send(.accept(request()), 2)
        live.send(.captureStarted(token1, folder: folder), 3)
        live.readEvery3s(from: 6, to: 99, windows: [chrome("Meet – " + codeA)])
        _ = live.take()
        // ⌘W: the tab goes, the next Meet opens in another one.
        live.readEvery3s(from: 102, to: 117, windows: [chrome("Meet – " + codeB, window: 8)])
        suite.expect(countdowns(live.take()).isEmpty, "the first meeting has its 20 s")
        live.readEvery3s(from: 120, to: 123, windows: [chrome("Meet – " + codeB, window: 8)])
        suite.expect(countdowns(live.take()) == [at(138)],
                     "then it ends, the microphone being the second meeting's: the countdown starts")
        live.readEvery3s(from: 126, to: 138, windows: [chrome("Meet – " + codeB, window: 8)])
        suite.expect(stops(live.take()), "and its recording stops 15 s later")
        live.send(.writerFinished(token1, .finished(recordedSeconds: nil)), 139)
        live.read(141, windows: [chrome("Meet – " + codeB, window: 8)])
        suite.expect(offers(live.take()).map(\.candidate.identity) == [meetB], "the second Meet is offered")
        live.send(.accept(request()), 142)
        live.send(.captureStarted(token2, folder: second), 143)
        suite.expect(live.machine.activeSession?.meeting == meetB, "and recorded")

        var notNow = Live()
        notNow.read(-5, microphones: [chromeMicrophone])
        notNow.read(0, windows: [chrome("Meet – " + codeA)])
        notNow.send(.dismiss(.thisTime), 2)
        notNow.readEvery3s(from: 3, to: 30, windows: [chrome("Meet – " + codeA)])
        _ = notNow.take()
        notNow.read(33, windows: [chrome("Meet – " + codeB)])
        suite.expect(offers(notNow.take()).map(\.candidate.identity) == [meetB],
                     "the first set aside with Not now: the second Meet in the same tab is offered at once")
    }

    private static func endPageOfAnotherTab(_ suite: TestSuite) {
        var resolver = ForkMeetingResolver(ownPID: ownPID)
        _ = resolver.resolve(ForkMeetingReading(at: at(-5), microphones: [chromeMicrophone]))
        _ = resolver.resolve(ForkMeetingReading(at: at(0), windows: [chrome("Meet – " + codeA)]))
        _ = resolver.resolve(ForkMeetingReading(at: at(3), windows: [chrome("Meet – " + codeB)]))
        let left = resolver.resolve(ForkMeetingReading(at: at(6), windows: [chrome("Vous avez quitté la réunion")]))
        suite.expect(left.ended == [meetB] && left.candidates.map(\.identity) == [meetA],
                     "two calls in two tabs of a window: the end page ends the one it showed, not the other")
        let still = resolver.resolve(ForkMeetingReading(at: at(9), windows: [chrome("Vous avez quitté la réunion")]))
        suite.expect(still.ended.isEmpty, "a page that stays ends nothing more")

        var freed = ForkMeetingResolver(ownPID: ownPID)
        _ = freed.resolve(ForkMeetingReading(at: at(-5), microphones: [chromeMicrophone]))
        _ = freed.resolve(ForkMeetingReading(at: at(0), windows: [chrome("Meet – " + codeA)]))
        _ = freed.resolve(ForkMeetingReading(at: at(3), windows: [chrome("Meet – " + codeB)]))
        _ = freed.resolve(ForkMeetingReading(at: at(5), microphones: []))
        let both = freed.resolve(ForkMeetingReading(at: at(6), windows: [chrome("You left the meeting")]))
        suite.expect(both.ended == [meetA, meetB], "the microphone free as well: both end")

        var alone = ForkMeetingResolver(ownPID: ownPID)
        _ = alone.resolve(ForkMeetingReading(at: at(-5), microphones: [chromeMicrophone]))
        _ = alone.resolve(ForkMeetingReading(at: at(0), windows: [chrome("Meet – " + codeA)]))
        _ = alone.resolve(ForkMeetingReading(at: at(3), windows: [chrome("Gmail")]))
        let back = alone.resolve(ForkMeetingReading(at: at(6), windows: [chrome("Vous avez quitté la réunion")]))
        suite.expect(back.ended == [meetA], "a window's only meeting ends with its end page, whatever tab was in front")
    }

    // MARK: - H1.4, H1.5, H1.6, H1.7

    private static func setAsideAfterAGlimpse(_ suite: TestSuite) {
        var resolver = ForkMeetingResolver(ownPID: ownPID)
        _ = resolver.resolve(ForkMeetingReading(at: at(-5), microphones: [chromeMicrophone]))
        _ = resolver.resolve(ForkMeetingReading(at: at(0), windows: [chrome("Meet – " + codeA)]))
        resolver.silence(meetA, at: at(1))
        _ = resolver.resolve(ForkMeetingReading(at: at(9), microphones: []))
        _ = resolver.resolve(ForkMeetingReading(at: at(10), windows: [chrome("Vous avez quitté la réunion")]))
        // Its link opened for one reading, the microphone shut: never born.
        _ = resolver.resolve(ForkMeetingReading(at: at(300), windows: [chrome("Meet – " + codeA)]))
        _ = resolver.resolve(ForkMeetingReading(at: at(303), windows: []))
        _ = resolver.resolve(ForkMeetingReading(at: at(609)))
        suite.expect(resolver.isSilenced(meetA), "9 min 59 s after its end, still aside")
        _ = resolver.resolve(ForkMeetingReading(at: at(611)))
        suite.expect(!resolver.isSilenced(meetA),
                     "a glimpse of its link, never a meeting, does not keep its set-aside alive: forgotten 10 min after its end")
    }

    private static func codeAppearing(_ suite: TestSuite) {
        var resolver = ForkMeetingResolver(ownPID: ownPID)
        _ = resolver.resolve(ForkMeetingReading(at: at(-5), microphones: [chromeMicrophone]))
        _ = resolver.resolve(ForkMeetingReading(at: at(0), windows: [chrome("Meet – Point hebdo")]))
        let born = resolver.resolve(ForkMeetingReading(at: at(3), windows: [chrome("Meet – Point hebdo")]))
        let coded = resolver.resolve(ForkMeetingReading(at: at(6), windows: [chrome("Meet – Point hebdo – " + codeA)]))
        let bare = resolver.resolve(ForkMeetingReading(at: at(9), windows: [chrome("Meet – " + codeA)]))
        suite.expect(born.candidates.count == 1 && coded.candidates == born.candidates && bare.candidates == born.candidates,
                     "« Meet – Point hebdo », then its code in the title, then the code alone: one meeting, unchanged")
        let elsewhere = resolver.resolve(ForkMeetingReading(at: at(12), windows: [chrome("Meet – " + codeA),
                                                                                  chrome("Meet – " + codeB, window: 8)]))
        suite.expect(elsewhere.candidates.count == 2, "another window's code is another meeting")
    }

    private static func endWhileStarting(_ suite: TestSuite) {
        var machine = Machine()
        let candidate = ForkMeetingCandidate(identity: meetA, provider: "meet", providerName: "Google Meet",
                                             providerShortName: "Meet", titleName: nil, meetCode: codeA,
                                             calendarTitle: nil, appBundle: "com.google.Chrome", pid: chromePID,
                                             windowID: 7, windowBundle: "com.google.Chrome", defaultSound: .app,
                                             policy: .ask, silenced: false, bornAt: at(0))
        machine.handle(.candidates([candidate], request()), now: at(0))
        machine.handle(.accept(request()), now: at(1))
        machine.handle(.endProbable(meetA, countdown: 15), now: at(1.5))
        machine.handle(.candidates([candidate], request()), now: at(2))
        let started = machine.handle(.captureStarted(token1, folder: folder), now: at(3))
        suite.expect(countdowns(started).isEmpty, "its meeting back before the capture runs: no countdown")

        var gone = Machine()
        gone.handle(.candidates([candidate], request()), now: at(0))
        gone.handle(.accept(request()), now: at(1))
        gone.handle(.endProbable(meetA, countdown: 15), now: at(1.5))
        let late = gone.handle(.captureStarted(token1, folder: folder), now: at(3))
        suite.expect(countdowns(late) == [at(18)], "gone for good: the countdown starts with the capture")

        var manual = Machine()
        manual.handle(.manualStart(request()), now: at(0))
        manual.handle(.endProbable(meetA, countdown: 15), now: at(1))
        suite.expect(countdowns(manual.handle(.captureStarted(token1, folder: folder), now: at(2))).isEmpty,
                     "a start by hand keeps no end")
    }

    private static func byHandAfterNotNow(_ suite: TestSuite) {
        var live = Live()
        live.read(-5, microphones: [chromeMicrophone])
        live.read(0, windows: [chrome("Meet – Point hebdo – " + codeA, window: 42)])
        live.send(.dismiss(.thisTime), 3)
        live.readEvery3s(from: 6, to: 30, windows: [chrome("Meet – Point hebdo – " + codeA, window: 42)])
        _ = live.take()
        live.send(.manualStart(request()), 31)
        let config = starts(live.take()).first
        suite.expect(config?.origin == .manual && config?.title == "Point hebdo" && config?.meeting?.windowID == 42
                        && config?.meeting?.appBundle == "com.google.Chrome",
                     "Record after Not now records the meeting going on, by hand: its name, its window, its app")
        live.send(.captureStarted(token1, folder: folder), 32)
        live.read(60, windows: [chrome("Vous avez quitté la réunion", window: 42)])
        live.read(61, microphones: [])
        live.readEvery3s(from: 63, to: 300, windows: [])
        suite.expect(countdowns(live.take()).isEmpty && live.machine.activeSession != nil,
                     "and only the person stops it")

        var nothing = Machine()
        nothing.handle(.manualStart(request()), now: at(0))
        if case let .starting(pending) = nothing.phase {
            suite.expect(pending.config.meeting == nil && pending.config.title == nil,
                         "with no meeting around, a start by hand names none")
        } else {
            suite.expect(false, "a start by hand starts")
        }
    }

    // MARK: - H1.8, H1.9, H1.10

    private static func alwaysChosenThenCancelled(_ suite: TestSuite) {
        func offered() -> Live {
            var live = Live()
            live.read(-5, microphones: [chromeMicrophone])
            live.read(0, windows: [chrome("Meet – " + codeA)])
            _ = live.take()
            return live
        }
        var chosen = offered()
        chosen.send(.always(request()), 2)
        let started = chosen.take()
        suite.expect(started.last == .notice(.alwaysChosen("Meet")), "choosing Always says it")
        let french = ForkMeetingStrings.strings(.fr)
        suite.expect(ForkMeetingNotice.alwaysChosen("Meet").title(french) == "Toujours pour Meet"
                        && ForkMeetingNotice.alwaysChosen("Meet").detail(french) == "Réglable dans Réunions",
                     "« Toujours pour Meet · Réglable dans Réunions »")
        let long = AppLanguage.allCases.filter { ForkMeetingNotice.alwaysChosen("FaceTime").title(.strings($0)).count > 28 }
        suite.expect(long.isEmpty, "28 characters at most in every language: \(long)")
        chosen.send(.captureStarted(token1, folder: folder), 3)
        chosen.send(.cancelAutoStart, 5)
        suite.expect(chosen.take().contains(.setPolicy(.ask, provider: "meet")) && chosen.apps.policy(for: .googleMeet) == .ask,
                     "Cancel right after choosing Always takes the choice back")

        var early = offered()
        early.send(.always(request()), 2)
        early.send(.cancelAutoStart, 2.5)
        suite.expect(early.take().contains(.setPolicy(.ask, provider: "meet")), "before the capture runs, too")

        var automatic = Live(apps: #"{"meet":"always"}"#)
        automatic.read(-5, microphones: [chromeMicrophone])
        automatic.read(0, windows: [chrome("Meet – " + codeA)])
        automatic.send(.captureStarted(token1, folder: folder), 1)
        automatic.send(.cancelAutoStart, 3)
        let cancelled = automatic.take()
        suite.expect(stops(cancelled) && !cancelled.contains(.setPolicy(.ask, provider: "meet"))
                        && automatic.apps.policy(for: .googleMeet) == .always,
                     "a start Always made on its own, cancelled: this meeting only, the choice stays")
    }

    private static func cancelledThenQuit(_ suite: TestSuite) {
        var live = Live(apps: #"{"meet":"always"}"#)
        live.read(-5, microphones: [chromeMicrophone])
        live.read(0, windows: [chrome("Meet – " + codeA)])
        live.send(.captureStarted(token1, folder: folder), 1)
        live.send(.cancelAutoStart, 2)
        live.send(.appWillTerminate, 2.1)
        live.send(.appWillTerminate, 2.2)
        live.send(.writerFinished(token1, .finished(recordedSeconds: 1)), 2.3)
        let discards = live.take().filter { $0 == .discard(folder) }
        suite.expect(discards.count == 1, "Cancel then ⌘Q: its folder is thrown away once, not twice")
    }

    private static func foldedOfferStopsTheClock(_ suite: TestSuite) {
        var live = Live()
        live.read(-5, microphones: [chromeMicrophone])
        live.read(0, windows: [chrome("Meet – " + codeA)])
        suite.expect(Support.clockRuns(phase: live.machine.phase), "an open offer: the clock ticks, to fold it")
        live.clock(until: 20)
        suite.expect(live.take().last == .collapseOffer && !Support.clockRuns(phase: live.machine.phase),
                     "folded, it waits for the person only: no clock")
    }

    // MARK: - H1.12

    private static func staleFreeSpace(_ suite: TestSuite) {
        suite.expect(Support.freeSpace(1_000, readAt: at(0), now: at(14)) == 1_000
                        && Support.freeSpace(1_000, readAt: at(0), now: at(15)) == nil
                        && Support.freeSpace(1_000, readAt: nil, now: at(0)) == nil,
                     "a free space read more than 15 s ago is not used")
        suite.expect(ForkMeetingMachine.refusal(ForkMeetingStartRequest(
                        settings: settings, facts: ForkMeetingStartFacts(freeBytes: nil, screenRecordingAllowed: true,
                                                                         microphoneAllowed: true, officialRecorderBusy: false)))
                        == .folderUnavailable,
                     "without it, the offer greys out as the folder unavailable")
        suite.expect(!Support.freeSpaceNeedsReading(readAt: at(0), askedAt: nil, now: at(9))
                        && Support.freeSpaceNeedsReading(readAt: at(0), askedAt: nil, now: at(10))
                        && Support.freeSpaceNeedsReading(readAt: nil, askedAt: nil, now: at(0)),
                     "it is read again after 10 s, before it is too old")
        suite.expect(!Support.freeSpaceNeedsReading(readAt: at(0), askedAt: at(10), now: at(24))
                        && Support.freeSpaceNeedsReading(readAt: at(0), askedAt: at(10), now: at(25)),
                     "a reading that hangs is waited for 15 s, then given up and asked again")
    }

    // MARK: - H1.14

    private static func cleanNames(_ suite: TestSuite) {
        let name = ForkMeetingTitleRules.displayName
        suite.expect(name("Point\u{202E}ofni\u{202C} hebdo") == "Pointofni hebdo"
                        && name("\u{2066}Revue\u{2069}") == "Revue",
                     "bidi controls go: a name cannot turn its text around")
        suite.expect(name("Point\nhebdo\t\r\n  équipe\u{0007}") == "Point hebdo équipe"
                        && name("  \u{0000}\u{001B}  ").isEmpty,
                     "control characters go, line breaks and runs of spaces are one space")
        let long = String(repeating: "Comité de pilotage ", count: 12)
        let cut = name(long)
        suite.expect(cut.count <= ForkMeetingTitleRules.nameLimit + 1 && cut.hasSuffix("…") && cut.hasPrefix("Comité de pilotage")
                        && !cut.contains("  "),
                     "a long name is cut near 100 characters, at a word, with « … »")
        suite.expect(name("Point d’équipe — Q4") == "Point d’équipe — Q4", "an ordinary name is kept as it is")

        var meeting = ForkMeetingCandidate(identity: meetA, provider: "meet", providerName: "Google Meet",
                                           providerShortName: "Meet", titleName: nil, meetCode: codeA,
                                           calendarTitle: "Point\u{202E} hebdo\n", appBundle: "com.google.Chrome",
                                           pid: chromePID, windowID: 7, windowBundle: "com.google.Chrome",
                                           defaultSound: .app, policy: .ask, silenced: false, bornAt: at(0))
        suite.expect(meeting.name == "Point hebdo", "the calendar's title is cleaned once, in the meeting's name")
        meeting.calendarTitle = "\u{202E}\n"
        suite.expect(meeting.name == "Google Meet · abc-defg-hij", "a title with nothing left names nothing")
        suite.expect(ForkMeetingDetectionSupport.titleSource(title: meeting.name, meeting: meeting) == .provider,
                     "and its source says so")
        suite.expect(verdict("\u{202E}Meet – Point hebdo") == .meeting(code: nil, name: "Point hebdo"),
                     "a title read past its bidi controls")
    }

    // MARK: - H1.15

    private static func titlesGone(_ suite: TestSuite) {
        var live = Live()
        live.read(-5, microphones: [chromeMicrophone])
        live.read(0, windows: [chrome("Meet – " + codeA)])
        _ = live.take()
        live.read(10, windows: [], titlesUnreadable: true)
        suite.expect(live.take().first == .hideOffer, "Screen Recording taken away during an offer: the offer goes")
        live.readEvery3s(from: 13, to: 60, windows: [])
        suite.expect(live.take().isEmpty, "and the browser's microphone alone brings nothing back")
        live.readEvery3s(from: 63, to: 66, windows: [chrome("Meet – " + codeA)])
        suite.expect(offers(live.take()).isEmpty, "allowed again: the same meeting, offered once already, stays aside")
    }

    private static func pageText(_ suite: TestSuite) {
        let all = AppLanguage.allCases.map(ForkMeetingStrings.strings)
        suite.expect(all.allSatisfy { $0.detectionLookalike.contains("Google Meet") }
                        && Set(all.map(\.detectionLookalike)).count >= 14,
                     "every language says a page copying a Meet title could be offered")
        suite.expect(ForkMeetingStrings.strings(.fr).detectionLookalike
                        == "Une page web qui imite exactement un titre Google Meet et utilise le micro pourrait être proposée comme une réunion.",
                     "« Une page web qui imite exactement un titre Google Meet et utilise le micro… »")
    }
}
