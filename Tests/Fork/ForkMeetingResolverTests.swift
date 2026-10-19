// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkMeetingResolverTests {
    typealias Resolver = ForkMeetingResolver

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let ownPID: Int32 = 999
    private static let chromePID: Int32 = 100
    private static let code = "abc-defg-hij"
    private static let meetA = ForkMeetingIdentity("meet:abc-defg-hij")
    private static let meetB = ForkMeetingIdentity("meet:xyz-qrst-uvw")

    static func run(_ suite: TestSuite) {
        providers(suite)
        policies(suite)
        entry(suite)
        codeAndMicrophone(suite)
        microphoneProbe(suite)
        microphoneAlone(suite)
        ownProcess(suite)
        life(suite)
        exits(suite)
        severalMeetings(suite)
        silences(suite)
        policyChoices(suite)
        webApps(suite)
        naming(suite)
        resetting(suite)
    }

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func resolver(_ table: ForkMeetingProviderTable = .current,
                                 policies: String = ForkMeetingPolicies.defaultJSON) -> Resolver {
        Resolver(table: table, ownPID: ownPID, policies: ForkMeetingPolicies(json: policies))
    }

    private static func chrome(_ title: String, id: UInt32 = 1, onScreen: Bool = true,
                               bundle: String = "com.google.Chrome", pid: Int32 = chromePID) -> ForkMeetingWindowSignal {
        ForkMeetingWindowSignal(bundle: bundle, pid: pid, title: title, onScreen: onScreen, windowID: id)
    }

    /// Chrome's audio helper, owned by Chrome, with its input running.
    private static let chromeMicrophone = ForkMeetingMicSignal(appBundle: "com.google.Chrome", appPID: chromePID, pid: 101,
                                                               processBundle: "com.google.Chrome.helper")

    @discardableResult
    private static func windows(_ resolver: inout Resolver, _ seconds: TimeInterval,
                                _ list: [ForkMeetingWindowSignal]) -> ForkMeetingResolution {
        resolver.resolve(ForkMeetingReading(at: at(seconds), windows: list))
    }

    @discardableResult
    private static func microphones(_ resolver: inout Resolver, _ seconds: TimeInterval,
                                    _ list: [ForkMeetingMicSignal]) -> ForkMeetingResolution {
        resolver.resolve(ForkMeetingReading(at: at(seconds), microphones: list))
    }

    @discardableResult
    private static func tick(_ resolver: inout Resolver, _ seconds: TimeInterval) -> ForkMeetingResolution {
        resolver.resolve(ForkMeetingReading(at: at(seconds)))
    }

    private static func ids(_ resolution: ForkMeetingResolution) -> [ForkMeetingIdentity] {
        resolution.candidates.map(\.identity)
    }

    /// A meeting app of a later version, to test what the table allows
    /// without turning it on here.
    private static let appProvider = ForkMeetingProvider(
        id: "zoom", name: "Zoom", shortName: "Zoom", kind: .app, bundles: ["us.zoom.xos"], webAppHosts: [:],
        processBundles: [], titles: nil, identity: .appProcess, defaultSound: .app, defaultPolicy: .ask)
    private static let systemProvider = ForkMeetingProvider(
        id: "facetime", name: "FaceTime", shortName: "FaceTime", kind: .app, bundles: ["com.apple.FaceTime"],
        webAppHosts: [:], processBundles: ["com.apple.avconferenced"], titles: nil, identity: .appProcess,
        defaultSound: .all, defaultPolicy: .ask)
    private static let withApps = ForkMeetingProviderTable(providers: [.googleMeet, appProvider, systemProvider])

    private static func providers(_ suite: TestSuite) {
        let meet = ForkMeetingProvider.googleMeet
        suite.expect(ForkMeetingProviderTable.current.providers.map(\.id)
                        == ["meet", "zoom", "teams", "slack", "facetime", "webex", "discord", "web", "web", "web", "web"],
                     "Google Meet first, then the meeting apps and the other web calls, entries of the same table")
        suite.expect(["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
                      "com.brave.Browser", "org.mozilla.firefox", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
                      "company.thebrowser.dia", "com.kagi.kagimacOS", "com.google.Chrome.canary"]
                        .allSatisfy { meet.owns(windowBundle: $0) },
                     "Google Meet is read in every browser of the plan")
        suite.expect(meet.owns(windowBundle: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan")
                        && meet.family(of: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan") == "com.google.Chrome"
                        && meet.family(of: "com.microsoft.edgemac.app.abc") == "com.microsoft.edgemac"
                        && meet.family(of: "com.google.Chrome.canary.app.abc") == "com.google.Chrome.canary"
                        && meet.family(of: "com.apple.Safari") == "com.apple.Safari",
                     "a web app's window counts, and leads to its browser's microphone and sound")
        suite.expect(!["com.tinyspeck.slackmacgap", "notion.id", "us.zoom.xos", "com.apple.mail", "com.google.Chrome.helper"]
                        .contains(where: meet.owns(windowBundle:)),
                     "an app that is not a browser is never read with the Google Meet rules")
        suite.expect(meet.defaultSound == .app && meet.defaultPolicy == .ask && meet.name == "Google Meet"
                        && meet.shortName == "Meet",
                     "Google Meet records its browser's sound and is offered by default")
        suite.expect(ForkMeetingProviderTable.current.watchesWindows(of: "com.google.Chrome.app.x")
                        && !ForkMeetingProviderTable.current.watchesWindows(of: "com.apple.Notes"),
                     "the scanner is told which windows to report")
    }

    private static func policies(_ suite: TestSuite) {
        let meet = ForkMeetingProvider.googleMeet
        let defaults = ForkMeetingPolicies(json: ForkMeetingPolicies.defaultJSON)
        suite.expect(defaults.policy(for: meet) == .ask && defaults.stored["discord"] == "never"
                        && defaults.stored.count == 8,
                     "by default every app is offered, Discord never")
        suite.expect(ForkMeetingPolicies(json: #"{"meet":"never"}"#).policy(for: meet) == .never
                        && ForkMeetingPolicies(json: #"{"meet":"always"}"#).policy(for: meet) == .always,
                     "the person's choice is read")
        suite.expect(["", "{", "[1,2]", "null", #"{"meet":"maybe"}"#, #"{"meet":3}"#]
                        .allSatisfy { ForkMeetingPolicies(json: $0).policy(for: meet) == .ask },
                     "unreadable settings fall back to the defaults instead of failing")
        var chosen = ForkMeetingPolicies(json: #"{"later":"never","meet":"ask"}"#)
        chosen.set(.always, for: "meet")
        suite.expect(chosen.json == #"{"later":"never","meet":"always"}"#
                        && ForkMeetingPolicies(json: chosen.json) == chosen,
                     "a choice is written back, sorted, keeping a provider this version does not know")

        let name = "vorss.tests.fork.meetings.detect"
        if let stored = UserDefaults(suiteName: name) {
            stored.removePersistentDomain(forName: name)
            suite.expect(ForkMeetingPolicies.load(stored) == defaults
                            && ForkMeetingAutoStop.load(stored) == ForkMeetingAutoStop(enabled: true, seconds: 15),
                         "with nothing stored: offer, and stop 15 s after a meeting ends")
            chosen.save(stored)
            stored.set(false, forKey: ForkDefaultsKey.meetingsAutoStop)
            stored.set(30, forKey: ForkDefaultsKey.meetingsAutoStopSeconds)
            suite.expect(ForkMeetingPolicies.load(stored) == chosen
                            && ForkMeetingAutoStop.load(stored) == ForkMeetingAutoStop(enabled: false, seconds: 30),
                         "the choices are read back from the settings")
            stored.removePersistentDomain(forName: name)
        } else {
            suite.expect(false, "a settings suite for the test")
        }
        suite.expect(ForkMeetingAutoStop(enabled: true, seconds: 15).countdown == 15
                        && ForkMeetingAutoStop(enabled: false, seconds: 15).countdown == nil
                        && ForkMeetingAutoStop(enabled: true, seconds: 0).countdown == 5
                        && ForkMeetingAutoStop(enabled: true, seconds: 10_000).countdown == 120,
                     "the countdown is the setting's, kept within 5 s and 2 min, none when auto stop is off")
    }

    /// Two readings that agree, at least a second apart (a title without a
    /// code, with its browser's microphone in use: see `ForkMeetingFixesH1Tests`).
    private static func entry(_ suite: TestSuite) {
        var r = resolver()
        microphones(&r, -5, [chromeMicrophone])
        let named = chrome("Meet – Point hebdo")
        suite.expect(windows(&r, 0, [named]).candidates.isEmpty, "one reading offers nothing yet")
        suite.expect(windows(&r, 0.2, [named]).candidates.isEmpty, "nor two readings of the same moment")
        let born = windows(&r, 3, [named])
        suite.expect(ids(born) == [ForkMeetingIdentity("meet:100:Meet – Point hebdo")] && born.candidates.first?.bornAt == at(3),
                     "the second reading 3 s later makes the meeting, named by its browser's process and its title")

        var broken = resolver()
        microphones(&broken, -5, [chromeMicrophone])
        windows(&broken, 0, [named])
        windows(&broken, 3, [chrome("Gmail")])
        suite.expect(windows(&broken, 6, [named]).candidates.isEmpty,
                     "a title gone in between starts the agreement over")
        suite.expect(windows(&broken, 9, [named]).candidates.count == 1, "and two readings in a row make it")
    }

    private static func codeAndMicrophone(_ suite: TestSuite) {
        var r = resolver()
        microphones(&r, -5, [chromeMicrophone])
        let born = windows(&r, 0, [chrome("Meet – \(code)")])
        suite.expect(ids(born) == [meetA],
                     "a code in the title, with the browser's microphone already open, makes the meeting at the first reading")

        var later = resolver()
        windows(&later, 0, [chrome("Meet – \(code)")])
        suite.expect(microphones(&later, 0.5, [chromeMicrophone]).candidates.isEmpty,
                     "a microphone just opened confirms nothing yet")
        suite.expect(ids(microphones(&later, 1.6, [chromeMicrophone])) == [meetA],
                     "once open for a second, it confirms the code")

        var silent = resolver()
        suite.expect(windows(&silent, 0, [chrome("Meet – \(code)")]).candidates.isEmpty
                        && ids(windows(&silent, 3, [chrome("Meet – \(code)")])) == [meetA],
                     "without a microphone signal (macOS 14.0 to 14.3), a code takes two readings like any title")
    }

    /// S2: loading meet.google.com opens the microphone for ~400 ms.
    private static func microphoneProbe(_ suite: TestSuite) {
        var r = resolver()
        var offered = false
        offered = offered || !windows(&r, 0, [chrome("Meet")]).candidates.isEmpty
        offered = offered || !microphones(&r, 0.0, [chromeMicrophone]).candidates.isEmpty
        offered = offered || !microphones(&r, 0.4, []).candidates.isEmpty
        for second in stride(from: 3.0, through: 60, by: 3) {
            offered = offered || !windows(&r, second, [chrome("Meet")]).candidates.isEmpty
        }
        suite.expect(!offered, "Meet's page probing the microphone while it loads offers nothing")

        var coded = resolver()
        var early = false
        early = early || !microphones(&coded, 0.1, [chromeMicrophone]).candidates.isEmpty
        early = early || !windows(&coded, 0.2, [chrome("Meet – \(code)")]).candidates.isEmpty
        early = early || !microphones(&coded, 0.5, []).candidates.isEmpty
        early = early || !tick(&coded, 2).candidates.isEmpty
        suite.expect(!early && ids(windows(&coded, 3, [chrome("Meet – \(code)")])) == [meetA],
                     "nor does it hasten a code in the title: that one waits for its second reading")
    }

    private static func microphoneAlone(_ suite: TestSuite) {
        var browser = resolver(withApps)
        var offered = false
        for second in stride(from: 0.0, through: 60, by: 2) {
            offered = offered || !microphones(&browser, second, [chromeMicrophone]).candidates.isEmpty
            offered = offered || !windows(&browser, second + 1, [chrome("Google Docs"), chrome("Sans titre", id: 2)]).candidates.isEmpty
        }
        suite.expect(!offered, "a browser using the microphone without a meeting title makes nothing")

        var app = resolver(withApps)
        let zoom = ForkMeetingMicSignal(appBundle: "us.zoom.xos", appPID: 500, pid: 500)
        suite.expect(microphones(&app, 0, [zoom]).candidates.isEmpty && microphones(&app, 0.3, [zoom]).candidates.isEmpty,
                     "a meeting app's microphone needs two readings a second apart")
        let born = microphones(&app, 2, [zoom])
        suite.expect(ids(born) == [ForkMeetingIdentity("zoom:500#1")] && born.candidates.first?.windowID == nil
                        && born.candidates.first?.appBundle == "us.zoom.xos",
                     "then the app's microphone alone makes its meeting, named by its process")

        var blip = resolver(withApps)
        microphones(&blip, 0, [zoom])
        microphones(&blip, 0.4, [])
        suite.expect(microphones(&blip, 2, [zoom]).candidates.isEmpty, "a microphone closed in between starts over")

        var daemon = resolver(withApps)
        let call = withApps.attributing([ForkMeetingMicSignal(appBundle: nil, pid: 77, processBundle: "com.apple.avconferenced")],
                                        running: ["com.apple.FaceTime": 78])
        microphones(&daemon, 0, call)
        let facetime = microphones(&daemon, 2, call)
        suite.expect(ids(facetime) == [ForkMeetingIdentity("facetime:78#1")] && facetime.candidates.first?.defaultSound == .all,
                     "a system process no app owns can carry a provider's calls, given to its app, with the whole Mac's sound")

        var others = resolver(withApps)
        let strangers = [ForkMeetingMicSignal(appBundle: "com.apple.VoiceMemos", appPID: 40, pid: 40),
                         ForkMeetingMicSignal(appBundle: nil, pid: 41, processBundle: "com.apple.corespeechd")]
        microphones(&others, 0, strangers)
        suite.expect(microphones(&others, 5, strangers).candidates.isEmpty,
                     "an app or a system process outside the table makes nothing")
    }

    private static func ownProcess(_ suite: TestSuite) {
        var r = resolver(withApps)
        let ours = [ForkMeetingMicSignal(appBundle: "us.zoom.xos", appPID: ownPID, pid: ownPID),
                    ForkMeetingMicSignal(appBundle: nil, pid: ownPID, processBundle: "com.apple.avconferenced")]
        microphones(&r, 0, ours)
        suite.expect(microphones(&r, 5, ours).candidates.isEmpty, "our own microphone (dictation, recording) is never a signal")
        var windowed = resolver()
        let own = chrome("Meet – \(code)", pid: ownPID)
        windows(&windowed, 0, [own])
        suite.expect(windows(&windowed, 3, [own]).candidates.isEmpty, "nor our own windows")
    }

    private static func life(_ suite: TestSuite) {
        var r = resolver()
        microphones(&r, -5, [chromeMicrophone])
        windows(&r, 0, [chrome("Meet – \(code)")])
        suite.expect(ids(windows(&r, 3, [chrome("Meet – \(code)", onScreen: false)])) == [meetA],
                     "a meeting window on another Space or minimized still lives")
        var alive = true
        for second in stride(from: 6.0, through: 60, by: 3) {
            alive = alive && ids(windows(&r, second, [chrome("Gmail")])) == [meetA]
        }
        suite.expect(alive, "a Meet tab in the background lives on its browser's microphone: no end")
        microphones(&r, 61, [])
        suite.expect(ids(tick(&r, 80)) == [meetA] && tick(&r, 80.9).ended.isEmpty,
                     "both signals gone: the meeting lives on for 20 s")
        let ended = tick(&r, 81)
        suite.expect(ended.ended == [meetA] && ended.candidates.isEmpty, "then it probably ended")
        suite.expect(tick(&r, 90).ended.isEmpty && windows(&r, 93, [chrome("Gmail")]).ended.isEmpty,
                     "an end is said once")

        // Without a microphone signal only a code makes a meeting.
        var titles = resolver()
        windows(&titles, 0, [chrome("Meet – xyz-qrst-uvw")])
        windows(&titles, 3, [chrome("Meet – xyz-qrst-uvw")])
        windows(&titles, 6, [])
        suite.expect(windows(&titles, 18, []).ended.isEmpty && windows(&titles, 21, [chrome("Meet – xyz-qrst-uvw")]).ended.isEmpty,
                     "without a microphone signal, a window back within 20 s keeps the meeting")
        windows(&titles, 24, [])
        suite.expect(windows(&titles, 42, []).ended.isEmpty && windows(&titles, 45, []).ended == [meetB],
                     "and a window gone for 20 s ends it")
    }

    private static func exits(_ suite: TestSuite) {
        var r = resolver()
        microphones(&r, -5, [chromeMicrophone])
        windows(&r, 0, [chrome("Meet – \(code)")])
        let left = windows(&r, 30, [chrome("Vous avez quitté la réunion")])
        suite.expect(left.ended.isEmpty && left.candidates.map(\.identity) == [meetA],
                     "the page saying the call is over, the microphone still open: nothing ends yet, the 20 s decide (J.I2)")
        microphones(&r, 31, [])
        let over = windows(&r, 33, [chrome("Vous avez quitté la réunion")])
        suite.expect(over.ended == [meetA] && over.candidates.isEmpty,
                     "the microphone free, the page still there: the meeting ends at that reading")
        suite.expect(windows(&r, 36, [chrome("Vous avez quitté la réunion")]).candidates.isEmpty
                        && tick(&r, 60).ended.isEmpty,
                     "and nothing comes back while the page stays")

        var other = resolver()
        microphones(&other, -5, [chromeMicrophone])
        windows(&other, 0, [chrome("Meet – \(code)", id: 1)])
        suite.expect(windows(&other, 3, [chrome("Meet – \(code)", id: 1), chrome("You left the meeting", id: 2)]).ended.isEmpty,
                     "the end page of another window ends nothing here")
    }

    private static func severalMeetings(_ suite: TestSuite) {
        var r = resolver()
        let first = chrome("Meet – \(code)", id: 1)
        let second = chrome("Meet – xyz-qrst-uvw", id: 2)
        windows(&r, 0, [first])
        windows(&r, 3, [first])
        windows(&r, 6, [first, second])
        let both = windows(&r, 9, [first, second])
        suite.expect(ids(both) == [meetB, meetA], "two meetings are two identities, the most recent first")
        windows(&r, 12, [second])
        suite.expect(windows(&r, 30, [second]).ended.isEmpty, "one closing has 20 s like any other")
        let one = windows(&r, 33, [second])
        suite.expect(one.ended == [meetA] && ids(one) == [meetB], "and its end ends only itself")
        let leaving = windows(&r, 36, [chrome("You left the meeting", id: 2)])
        suite.expect(leaving.ended == [meetB] && leaving.candidates.isEmpty, "each meeting ends on its own signals")

        var profiles = resolver()
        let front = chrome("Meet – \(code)", id: 7, onScreen: true, pid: 100)
        let back = chrome("Meet – \(code)", id: 8, onScreen: false, pid: 200)
        windows(&profiles, 0, [back, front])
        let same = windows(&profiles, 3, [back, front])
        suite.expect(ids(same) == [meetA] && same.candidates.first?.windowID == 7,
                     "two profiles on the same meeting give one meeting, filmed in the window on screen")
    }

    private static func silences(_ suite: TestSuite) {
        var r = resolver()
        microphones(&r, -5, [chromeMicrophone])
        windows(&r, 0, [chrome("Meet – \(code)")])
        r.silence(meetA, at: at(1))
        suite.expect(windows(&r, 3, [chrome("Meet – \(code)")]).candidates.first?.silenced == true,
                     "\"Not now\" sets the meeting aside, still listed")
        windows(&r, 6, [chrome("Gmail")])
        suite.expect(windows(&r, 9, [chrome("Meet – \(code)")]).candidates.first?.silenced == true,
                     "coming back to its tab offers nothing new")

        // Its tab closed, the microphone free: over at 44 s.
        microphones(&r, 12, [])
        windows(&r, 24, [])
        suite.expect(windows(&r, 44, []).ended == [meetA], "it ends")
        windows(&r, 100, [chrome("Meet – \(code)")])
        suite.expect(windows(&r, 103, [chrome("Meet – \(code)")]).candidates.first?.silenced == true,
                     "rejoined within 10 minutes, it is still aside")
        windows(&r, 106, [])
        suite.expect(windows(&r, 126, []).ended == [meetA] && r.isSilenced(meetA), "it ends again")
        tick(&r, 725)
        suite.expect(r.isSilenced(meetA), "the 10 minutes count from its last end")
        tick(&r, 726)
        suite.expect(!r.isSilenced(meetA), "and 10 minutes after it, the set-aside is forgotten")
        windows(&r, 730, [chrome("Meet – \(code)")])
        suite.expect(windows(&r, 733, [chrome("Meet – \(code)")]).candidates.first?.silenced == false,
                     "so the same meeting another day is offered again")

        var never = resolver()
        never.silence(meetB, at: at(0))
        tick(&never, 599)
        suite.expect(never.isSilenced(meetB), "a meeting set aside while not seen counts its 10 minutes from then")
        tick(&never, 600)
        suite.expect(!never.isSilenced(meetB), "and forgets it after them")
    }

    private static func policyChoices(_ suite: TestSuite) {
        var never = resolver(policies: #"{"meet":"never"}"#)
        microphones(&never, -5, [chromeMicrophone])
        suite.expect(windows(&never, 0, [chrome("Meet – \(code)")]).candidates.isEmpty
                        && windows(&never, 3, [chrome("Meet – \(code)")]).candidates.isEmpty,
                     "\"Never for Meet\": its meetings are not offered")
        never.policies.set(.ask, for: "meet")
        suite.expect(ids(windows(&never, 6, [chrome("Meet – \(code)")])) == [meetA],
                     "set back to ask, the meeting going on shows at once")

        var always = resolver(policies: #"{"meet":"always"}"#)
        microphones(&always, -5, [chromeMicrophone])
        suite.expect(windows(&always, 0, [chrome("Meet – \(code)")]).candidates.first?.policy == .always,
                     "\"Always for Meet\" is carried by its meetings, for the machine to start them")
    }

    private static func webApps(_ suite: TestSuite) {
        var r = resolver()
        let pwa = chrome("Meet – \(code)", id: 9, bundle: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", pid: 300)
        microphones(&r, -5, [chromeMicrophone])
        let born = windows(&r, 0, [pwa])
        suite.expect(ids(born) == [meetA] && born.candidates.first?.appBundle == "com.google.Chrome"
                        && born.candidates.first?.windowBundle == pwa.bundle && born.candidates.first?.windowID == 9,
                     "Meet's web app is confirmed by Chrome's microphone, records Chrome's sound and films its own window")
        let both = windows(&r, 3, [pwa, chrome("Meet – \(code)", id: 1)])
        suite.expect(ids(both) == [meetA], "the web app and a tab on the same meeting are one meeting")

        var foreign = resolver()
        let elsewhere = [ForkMeetingWindowSignal(bundle: "com.tinyspeck.slackmacgap", pid: 50, title: "Meet – \(code)",
                                                 onScreen: true, windowID: 3),
                         ForkMeetingWindowSignal(bundle: "notion.id", pid: 51, title: "Meet – Point hebdo", onScreen: true,
                                                 windowID: 4)]
        windows(&foreign, 0, elsewhere)
        suite.expect(windows(&foreign, 3, elsewhere).candidates.isEmpty,
                     "a Meet-looking title in an app that is not a browser is nothing")
    }

    private static func naming(_ suite: TestSuite) {
        var r = resolver()
        let hint = ForkMeetingCalendarHint(title: "Point hebdo", meetCode: code, startsAt: at(-60), endsAt: at(3600))
        microphones(&r, -5, [chromeMicrophone])
        let named = r.resolve(ForkMeetingReading(at: at(0), windows: [chrome("Meet – \(code)")], calendar: [hint]))
        suite.expect(named.candidates.first?.name == "Point hebdo" && named.candidates.first?.calendarTitle == "Point hebdo",
                     "a meeting without a name in its title takes its calendar event's")
        let titled = windows(&r, 3, [chrome("Meet – Revue – \(code)")])
        suite.expect(titled.candidates.first?.name == "Revue", "the title's own name comes first")

        var plain = resolver()
        microphones(&plain, -5, [chromeMicrophone])
        let coded = windows(&plain, 0, [chrome("Meet – \(code)")])
        suite.expect(coded.candidates.first?.name == "Google Meet · abc-defg-hij",
                     "otherwise it is named after Google Meet and its code")
    }

    private static func resetting(_ suite: TestSuite) {
        var r = resolver()
        microphones(&r, -5, [chromeMicrophone])
        windows(&r, 0, [chrome("Meet – \(code)")])
        r.silence(meetA, at: at(1))
        r.reset()
        suite.expect(tick(&r, 2).candidates.isEmpty && !r.isSilenced(meetA),
                     "turning the feature off forgets every meeting and every set-aside")
    }
}
