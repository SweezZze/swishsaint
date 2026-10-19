// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The meeting apps (PR 3): Zoom, Teams, Slack, FaceTime, Webex, Discord and
/// the other calls in a browser, each rule as the person would notice it,
/// played through the real provider table, the resolver and the machine
/// wired as the service wires them.
enum ForkMeetingAppsTests {
    typealias Machine = ForkMeetingMachine
    typealias Effect = ForkMeetingMachine.Effect
    typealias Window = ForkMeetingWindowSignal
    typealias Microphone = ForkMeetingMicSignal
    typealias Rules = ForkMeetingTitleRules

    static func run(_ suite: TestSuite) {
        table(suite)
        policies(suite)
        zoomTitles(suite)
        slackTitles(suite)
        webTitles(suite)
        microphoneAlone(suite)
        zoomByItsWindow(suite)
        slackHuddle(suite)
        discordNever(suite)
        faceTime(suite)
        ownProcess(suite)
        otherWebCalls(suite)
        endings(suite)
        alwaysForAnApp(suite)
        alwaysNeedsProof(suite)
        filmedAndHeard(suite)
        faceTimeSound(suite)
        tapRepair(suite)
        page(suite)
    }

    // MARK: - Fixtures

    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let ownPID: Int32 = 999
    private static let chromePID: Int32 = 100
    private static let zoomPID: Int32 = 500
    private static let faceTimePID: Int32 = 600
    private static let current = ForkMeetingProviderTable.current
    private static let settings = ForkMeetingCaptureSettings(target: .window, systemAudio: .app, microphone: "meeting",
                                                             quality: .standard)
    private static let ready = ForkMeetingStartFacts(freeBytes: 50_000_000_000, screenRecordingAllowed: true,
                                                     microphoneAllowed: true, officialRecorderBusy: false)
    private static let chromeMicrophone = Microphone(appBundle: "com.google.Chrome", appPID: chromePID, pid: 101,
                                                     processBundle: "com.google.Chrome.helper")
    private static let zoomMicrophone = Microphone(appBundle: "us.zoom.xos", appPID: zoomPID, pid: zoomPID,
                                                   processBundle: "us.zoom.xos")
    private static let callDaemon = Microphone(appBundle: nil, pid: 77, processBundle: "com.apple.avconferenced",
                                               inputDevice: "BuiltInMicrophoneDevice")

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func resolver(_ json: String = ForkMeetingPolicies.defaultJSON) -> ForkMeetingResolver {
        ForkMeetingResolver(ownPID: ownPID, policies: ForkMeetingPolicies(json: json))
    }

    @discardableResult
    private static func read(_ resolver: inout ForkMeetingResolver, _ seconds: TimeInterval, windows: [Window]? = nil,
                             microphones: [Microphone]? = nil) -> ForkMeetingResolution {
        resolver.resolve(ForkMeetingReading(at: at(seconds), windows: windows, microphones: microphones))
    }

    private static func ids(_ resolution: ForkMeetingResolution) -> [String] {
        resolution.candidates.map(\.identity.value)
    }

    private static func window(_ title: String, bundle: String = "us.zoom.xos", pid: Int32 = zoomPID,
                               id: UInt32 = 1) -> Window {
        Window(bundle: bundle, pid: pid, title: title, onScreen: true, windowID: id)
    }

    private static func chrome(_ title: String, id: UInt32 = 7) -> Window {
        Window(bundle: "com.google.Chrome", pid: chromePID, title: title, onScreen: true, windowID: id)
    }

    private static func microphone(_ bundle: String, pid: Int32) -> Microphone {
        Microphone(appBundle: bundle, appPID: pid, pid: pid + 1, processBundle: bundle + ".helper")
    }

    private static func verdict(_ title: String, _ rules: ForkMeetingTitleRuleSet) -> ForkMeetingTitleVerdict {
        Rules.verdict(title, rules: rules)
    }

    private static let meeting = ForkMeetingTitleVerdict.meeting(code: nil, name: nil)

    // MARK: - The table

    private static func table(_ suite: TestSuite) {
        func provider(_ id: String) -> ForkMeetingProvider? { current.provider(id: id) }
        suite.expect(provider("zoom")?.bundles == ["us.zoom.xos"]
                        && provider("teams")?.bundles == ["com.microsoft.teams2", "com.microsoft.teams"]
                        && provider("slack")?.bundles == ["com.tinyspeck.slackmacgap"]
                        && provider("facetime")?.bundles == ["com.apple.FaceTime"]
                        && provider("webex")?.bundles == ["Cisco-Systems.Spark", "com.webex.meetingmanager"]
                        && provider("discord")?.bundles == ["com.hnc.Discord"],
                     "each meeting app is known by its bundle, the new Teams and the classic one, both Webex apps")
        let apps = ["zoom", "teams", "slack", "facetime", "webex", "discord"].compactMap(provider)
        suite.expect(apps.count == 6 && apps.allSatisfy { $0.kind == .app && $0.identity == .appProcess },
                     "a meeting app's microphone alone makes its meeting, one per app process")
        suite.expect(provider("facetime")?.processBundles == ["com.apple.avconferenced", "com.apple.TelephonyUtilities"]
                        && apps.filter { !$0.processBundles.isEmpty }.map(\.id) == ["facetime"],
                     "only FaceTime's calls run in system processes (avconferenced, callservicesd)")
        suite.expect(apps.filter { $0.defaultSound == .all }.map(\.id) == ["facetime"]
                        && ForkMeetingProvider.googleMeet.defaultSound == .app,
                     "every app records its own sound by default, FaceTime the whole Mac")
        suite.expect(apps.filter { $0.defaultPolicy == .never }.map(\.id) == ["discord"],
                     "every app is offered by default, Discord never")
        let web = ForkMeetingProvider.otherWebCalls
        suite.expect(web.map(\.name) == ["Zoom", "Whereby", "Jitsi Meet", "Microsoft Teams"]
                        && web.allSatisfy { $0.id == "web" && $0.kind == .web && !$0.titlesMakeMeetings
                            && $0.bundles == ForkMeetingProvider.browsers },
                     "the other web calls share one choice, in every browser, and a title never makes them alone")
        suite.expect(current.providers.first == .googleMeet, "a browser's window is read with Google Meet's rules first")
        suite.expect(["us.zoom.xos", "com.tinyspeck.slackmacgap", "com.apple.FaceTime", "com.hnc.Discord",
                      "com.google.Chrome"].allSatisfy(current.watchesWindows(of:))
                        && !current.watchesWindows(of: "com.apple.Notes"),
                     "the scanner reports the apps' windows too, and nothing else")
    }

    private static func policies(_ suite: TestSuite) {
        let defaults = ForkMeetingPolicies(json: ForkMeetingPolicies.defaultJSON)
        suite.expect(Set(current.policyRows.map(\.id)) == Set(defaults.stored.keys),
                     "the stored default has one choice per row of the page, no more, no less")
        suite.expect(current.providers.allSatisfy { defaults.policy(for: $0) == $0.defaultPolicy }
                        && defaults.policy(for: .discord) == .never && defaults.policy(for: .zoom) == .ask,
                     "the stored default says what each provider does by default")
        var chosen = defaults
        chosen.set(.always, for: "zoom")
        chosen.set(.never, for: "web")
        suite.expect(chosen.policy(for: .zoom) == .always && chosen.policy(for: .teams) == .ask
                        && ForkMeetingProvider.otherWebCalls.allSatisfy { chosen.policy(for: $0) == .never }
                        && chosen.policy(for: .googleMeet) == .ask,
                     "a choice is per app; the other web calls go together; Meet stays apart")
        suite.expect(ForkMeetingPolicies(json: #"{"meet":"ask"}"#).policy(for: .discord) == .never,
                     "an older setting without Discord keeps it off")
    }

    // MARK: - Titles

    private static func zoomTitles(_ suite: TestSuite) {
        let meetings = ["Zoom Meeting", "Zoom Webinar", "Zoom-Webinar", "Réunion Zoom", "Webinaire Zoom",
                        "Reunión de Zoom", "Riunione Zoom", "Reunião Zoom", "Zoom-vergadering", "Spotkanie Zoom",
                        "Конференция Zoom", "Zoom-möte", "Zoom Toplantısı", "Zoom ミーティング", "Zoom 회의",
                        "Cuộc họp Zoom", "Zoom会议", "Zoom會議", "  zoom\u{00A0}meeting ", "ZOOM MEETING"]
        suite.expect(meetings.allSatisfy { verdict($0, .zoomApp) == meeting },
                     "Zoom's meeting window is read in every language Zoom translates it to, case and spaces aside")
        let others = ["Zoom", "Zoom Workplace", "Meeting", "Réunion", "Zoom Meeting notes", "Settings", "",
                      "Zoom Meetings", "Chat"]
        suite.expect(others.allSatisfy { verdict($0, .zoomApp) == .none },
                     "Zoom's other windows are no meeting, nor are words around one")
    }

    private static func slackTitles(_ suite: TestSuite) {
        let huddles = ["Huddle", "Huddle: #design", "Slack | Huddle with Alice", "Acme – Huddle", "huddle"]
        suite.expect(huddles.allSatisfy { verdict($0, .slackHuddle) == meeting }, "a huddle's window is told")
        let channels = ["Slack | #meeting | Acme", "#meeting (Channel) - Acme - Slack", "#huddle-notes - Acme - Slack",
                        "Huddles - Acme - Slack", "Meeting notes – Slack", "Slack"]
        suite.expect(channels.allSatisfy { verdict($0, .slackHuddle) == .none },
                     "a channel called #meeting or #huddle-notes, or the huddles list, is no huddle")
    }

    private static func webTitles(_ suite: TestSuite) {
        suite.expect(verdict("Zoom", .zoomWeb) == meeting && verdict("Zoom Meeting", .zoomWeb) == meeting
                        && verdict("Whereby", .whereby) == meeting && verdict("Jitsi Meet", .jitsiMeet) == meeting
                        && verdict("https://teams.microsoft.com/v2/", .teamsWeb) == meeting,
                     "Zoom's web client, Whereby, Jitsi Meet and Teams on the web are read")
        suite.expect(verdict("Point hebdo | Jitsi Meet", .jitsiMeet) == .meeting(code: nil, name: "Point hebdo"),
                     "a Jitsi room is the meeting's name")
        let articles: [(String, ForkMeetingTitleRuleSet)] = [
            ("Zoom review: the best video app | The Verge", .zoomWeb), ("How to use Zoom - Wikipedia", .zoomWeb),
            ("Zoom Video Communications – Wikipédia", .zoomWeb), ("Zoom in on the map", .zoomWeb),
            ("Whereby vs Zoom | Blog", .whereby), ("Jitsi Meet review", .jitsiMeet), (" | Jitsi Meet", .jitsiMeet),
            ("Microsoft Teams review", .teamsWeb), ("Chat | Microsoft Teams", .teamsWeb),
        ]
        suite.expect(articles.allSatisfy { verdict($0.0, $0.1) == .none },
                     "an article about Zoom, Whereby, Jitsi or Teams is no call")
    }

    // MARK: - The resolver, with the real table

    private static func microphoneAlone(_ suite: TestSuite) {
        var zoom = resolver()
        suite.expect(ids(read(&zoom, 0, microphones: [zoomMicrophone])).isEmpty
                        && ids(read(&zoom, 0.4, microphones: [zoomMicrophone])).isEmpty,
                     "Zoom's microphone needs two readings a second apart")
        let born = read(&zoom, 2, microphones: [zoomMicrophone])
        suite.expect(ids(born) == ["zoom:500"] && born.candidates.first?.windowID == nil
                        && born.candidates.first?.name == "Zoom" && born.candidates.first?.defaultSound == .app
                        && born.candidates.first?.policy == .ask,
                     "then Zoom's microphone alone makes its meeting, named Zoom, offered, its sound Zoom's")

        for (bundle, id) in [("com.microsoft.teams2", "teams"), ("com.microsoft.teams", "teams"),
                             ("com.tinyspeck.slackmacgap", "slack"), ("Cisco-Systems.Spark", "webex"),
                             ("com.webex.meetingmanager", "webex")] {
            var app = resolver()
            let signal = microphone(bundle, pid: 300)
            read(&app, 0, microphones: [signal])
            suite.expect(ids(read(&app, 2, microphones: [signal])) == ["\(id):300"],
                         "the microphone of \(bundle) makes a \(id) meeting")
        }

        var helper = resolver()
        let sharing = Microphone(appBundle: "us.zoom.xos", appPID: zoomPID, pid: 510, processBundle: "us.zoom.CptHost")
        read(&helper, 0, microphones: [sharing, zoomMicrophone])
        suite.expect(ids(read(&helper, 2, microphones: [sharing, zoomMicrophone])) == ["zoom:500"],
                     "Zoom's helpers are Zoom's: one meeting for the app")

        var strangers = resolver()
        let others = [microphone("com.apple.VoiceMemos", pid: 40), microphone("com.apple.logic10", pid: 41),
                      Microphone(appBundle: nil, pid: 42, processBundle: "com.apple.corespeechd")]
        read(&strangers, 0, microphones: others)
        suite.expect(ids(read(&strangers, 5, microphones: others)).isEmpty,
                     "Voice Memos, Logic or Siri using the microphone make nothing")
    }

    private static func zoomByItsWindow(_ suite: TestSuite) {
        var titled = resolver()
        read(&titled, 0, windows: [window("Réunion Zoom", id: 4)])
        let born = read(&titled, 3, windows: [window("Réunion Zoom", id: 4)])
        suite.expect(ids(born) == ["zoom:500"] && born.candidates.first?.windowID == 4 && born.onMicrophone.isEmpty,
                     "Zoom's meeting window alone makes its meeting, filmed in that window, not on the microphone yet")
        let both = read(&titled, 4, microphones: [zoomMicrophone])
        suite.expect(ids(both) == ["zoom:500"] && both.candidates.first?.windowID == 4,
                     "its microphone then is the same meeting")
        suite.expect(read(&titled, 5.5, microphones: [zoomMicrophone]).onMicrophone == [ForkMeetingIdentity("zoom:500")],
                     "and counts as on the microphone once open for a second")

        var main = resolver()
        for second in stride(from: 0.0, through: 30, by: 3) {
            read(&main, second, windows: [window("Zoom Workplace"), window("Zoom", id: 2)])
        }
        suite.expect(ids(read(&main, 33, windows: [window("Zoom Workplace")])).isEmpty,
                     "Zoom's main window, open all day, is no meeting")

        var muted = resolver()
        read(&muted, 0, windows: [window("Zoom Meeting")], microphones: [zoomMicrophone])
        read(&muted, 3, windows: [window("Zoom Meeting")], microphones: [zoomMicrophone])
        var alive = true
        for second in stride(from: 6.0, through: 60, by: 3) {
            alive = alive && ids(read(&muted, second, windows: [window("Zoom Meeting")], microphones: [])) == ["zoom:500"]
        }
        suite.expect(alive, "a meeting whose microphone Zoom let go (muted) lives on its window")
    }

    private static func slackHuddle(_ suite: TestSuite) {
        var title = resolver()
        for second in stride(from: 0.0, through: 30, by: 3) {
            read(&title, second, windows: [window("Huddle: #design", bundle: "com.tinyspeck.slackmacgap", pid: 300)])
        }
        suite.expect(ids(read(&title, 33, windows: [window("Huddle", bundle: "com.tinyspeck.slackmacgap", pid: 300)]))
                        .isEmpty,
                     "a \"Huddle\" title alone makes nothing: a channel may be called so")

        var huddle = resolver()
        let slack = microphone("com.tinyspeck.slackmacgap", pid: 300)
        let windows = [window("Acme - Slack", bundle: "com.tinyspeck.slackmacgap", pid: 300, id: 1),
                       window("Huddle: #design", bundle: "com.tinyspeck.slackmacgap", pid: 300, id: 2)]
        read(&huddle, 0, windows: windows, microphones: [slack])
        let born = read(&huddle, 2, microphones: [slack])
        suite.expect(ids(born) == ["slack:300"] && born.candidates.first?.windowID == 2,
                     "Slack's microphone makes the huddle, filmed in its huddle window")

        var channel = resolver()
        let named = [window("Slack | #meeting | Acme", bundle: "com.tinyspeck.slackmacgap", pid: 300)]
        read(&channel, 0, windows: named, microphones: [slack])
        let call = read(&channel, 2, microphones: [slack])
        suite.expect(ids(call) == ["slack:300"] && call.candidates.first?.windowID == nil,
                     "a channel called #meeting is no huddle window: the call is Slack's, its window chosen later")
    }

    private static func discordNever(_ suite: TestSuite) {
        let discord = microphone("com.hnc.Discord", pid: 400)
        var off = resolver()
        for second in stride(from: 0.0, through: 30, by: 2) { read(&off, second, microphones: [discord]) }
        suite.expect(ids(read(&off, 32, microphones: [discord])).isEmpty, "Discord's voice chat is never offered by default")
        var on = resolver(ForkMeetingPolicies.defaultJSON.replacingOccurrences(of: #""discord":"never""#,
                                                                               with: #""discord":"ask""#))
        read(&on, 0, microphones: [discord])
        suite.expect(ids(read(&on, 2, microphones: [discord])) == ["discord:400"], "set to Offer, it is")
    }

    private static func faceTime(_ suite: TestSuite) {
        let closed = current.attributing([callDaemon], running: [:])
        suite.expect(closed == [callDaemon], "with FaceTime closed, avconferenced stays nobody's")
        var relayed = resolver()
        for second in stride(from: 0.0, through: 20, by: 2) { read(&relayed, second, microphones: closed) }
        suite.expect(ids(read(&relayed, 22, microphones: closed)).isEmpty,
                     "so a call FaceTime does not show (an iPhone call relayed, Continuity) makes nothing")

        let open = current.attributing([callDaemon], running: ["com.apple.FaceTime": faceTimePID])
        suite.expect(open.first?.appBundle == "com.apple.FaceTime" && open.first?.appPID == faceTimePID
                        && open.first?.pid == 77 && open.first?.inputDevice == "BuiltInMicrophoneDevice",
                     "with FaceTime open, avconferenced's microphone is FaceTime's")
        var call = resolver()
        read(&call, 0, microphones: open)
        let born = read(&call, 2, microphones: open)
        suite.expect(ids(born) == ["facetime:600"] && born.candidates.first?.defaultSound == .all
                        && born.candidates.first?.appBundle == "com.apple.FaceTime",
                     "a FaceTime call is named by FaceTime's process, and records the whole Mac")

        let signalling = Microphone(appBundle: nil, pid: 78, processBundle: "com.apple.TelephonyUtilities")
        let app = Microphone(appBundle: "com.apple.FaceTime", appPID: faceTimePID, pid: faceTimePID)
        let all = current.attributing([callDaemon, signalling, app], running: ["com.apple.FaceTime": faceTimePID])
        var together = resolver()
        read(&together, 0, microphones: all)
        suite.expect(ids(read(&together, 2, microphones: all)) == ["facetime:600"],
                     "FaceTime, avconferenced and callservicesd together are one call")

        let unrelated = Microphone(appBundle: nil, pid: 79, processBundle: "com.apple.corespeechd")
        suite.expect(current.attributing([unrelated, zoomMicrophone], running: ["com.apple.FaceTime": faceTimePID])
                        == [unrelated, zoomMicrophone],
                     "only a call's own system processes are given to FaceTime, never Siri's or an app's")
        suite.expect(current.systemProcessHosts == ["com.apple.FaceTime"]
                        && current.systemProcessBundles == ["com.apple.avconferenced", "com.apple.TelephonyUtilities"],
                     "the service asks which apps run only for FaceTime, when one of its processes records")
    }

    private static func ownProcess(_ suite: TestSuite) {
        var r = resolver()
        let ours = [Microphone(appBundle: "us.zoom.xos", appPID: ownPID, pid: ownPID),
                    Microphone(appBundle: "com.apple.FaceTime", appPID: ownPID, pid: 77)]
        read(&r, 0, microphones: ours)
        suite.expect(ids(read(&r, 5, microphones: ours)).isEmpty, "our own process is never a meeting app's microphone")
        var windowed = resolver()
        read(&windowed, 0, windows: [window("Zoom Meeting", pid: ownPID)])
        suite.expect(ids(read(&windowed, 3, windows: [window("Zoom Meeting", pid: ownPID)])).isEmpty,
                     "nor our own windows")
    }

    private static func otherWebCalls(_ suite: TestSuite) {
        var silent = resolver()
        var offered = false
        for second in stride(from: 0.0, through: 60, by: 3) {
            offered = offered || !read(&silent, second, windows: [chrome("Point hebdo | Jitsi Meet")]).candidates.isEmpty
            offered = offered || !read(&silent, second + 1, windows: [chrome("Zoom"), chrome("Whereby", id: 8)])
                .candidates.isEmpty
        }
        suite.expect(!offered, "a web call's title without the browser's microphone makes nothing, however long")

        var jitsi = resolver()
        read(&jitsi, -5, microphones: [chromeMicrophone])
        read(&jitsi, 0, windows: [chrome("Point hebdo | Jitsi Meet")])
        let born = read(&jitsi, 3, windows: [chrome("Point hebdo | Jitsi Meet")])
        let candidate = born.candidates.first
        suite.expect(ids(born) == ["web:100:Point hebdo | Jitsi Meet"] && candidate?.name == "Point hebdo"
                        && candidate?.providerName == "Jitsi Meet" && candidate?.provider == "web"
                        && candidate?.windowID == 7 && candidate?.appBundle == "com.google.Chrome",
                     "with the browser's microphone, a Jitsi room is offered, named, in its window")

        var zoomWeb = resolver()
        read(&zoomWeb, -5, microphones: [chromeMicrophone])
        read(&zoomWeb, 0, windows: [chrome("Zoom")])
        suite.expect(read(&zoomWeb, 3, windows: [chrome("Zoom")]).candidates.map(\.name) == ["Zoom"],
                     "Zoom's web client too")

        var article = resolver()
        read(&article, -5, microphones: [chromeMicrophone])
        for second in stride(from: 0.0, through: 30, by: 3) {
            read(&article, second, windows: [chrome("Zoom review: the best video app | The Verge")])
        }
        suite.expect(ids(read(&article, 33, windows: [chrome("Zoom review: the best video app | The Verge")])).isEmpty,
                     "an article about Zoom is no call, even with the microphone in use")

        var never = resolver(ForkMeetingPolicies.defaultJSON.replacingOccurrences(of: #""web":"ask""#,
                                                                                  with: #""web":"never""#))
        read(&never, -5, microphones: [chromeMicrophone])
        read(&never, 0, windows: [chrome("Whereby")])
        suite.expect(ids(read(&never, 3, windows: [chrome("Whereby")])).isEmpty, "set to Never, the web calls are not offered")

        var meet = resolver()
        read(&meet, -5, microphones: [chromeMicrophone])
        read(&meet, 0, windows: [chrome("Meet – abc-defg-hij")])
        suite.expect(ids(read(&meet, 3, windows: [chrome("Meet – abc-defg-hij")])) == ["meet:abc-defg-hij"],
                     "a Google Meet stays a Google Meet")
    }

    private static func endings(_ suite: TestSuite) {
        var zoom = resolver()
        read(&zoom, 0, windows: [window("Zoom Meeting")], microphones: [zoomMicrophone])
        read(&zoom, 3, windows: [window("Zoom Meeting")], microphones: [zoomMicrophone])
        read(&zoom, 6, windows: [window("Zoom Workplace")], microphones: [])
        var ended: [ForkMeetingIdentity] = []
        for second in stride(from: 9.0, through: 24, by: 3) {
            ended += read(&zoom, second, windows: [window("Zoom Workplace")]).ended
        }
        suite.expect(ended.isEmpty, "its window and its microphone gone, a Zoom meeting lives on 20 s")
        suite.expect(read(&zoom, 27, windows: [window("Zoom Workplace")]).ended == [ForkMeetingIdentity("zoom:500")],
                     "then it probably ended")

        var two = resolver()
        let teams = microphone("com.microsoft.teams2", pid: 300)
        read(&two, 0, microphones: [zoomMicrophone, teams])
        read(&two, 2, microphones: [zoomMicrophone, teams])
        var survived = true
        for second in stride(from: 4.0, through: 40, by: 2) {
            let resolution = read(&two, second, microphones: [teams])
            survived = survived && resolution.candidates.map(\.identity.value).contains("teams:300")
                && !resolution.ended.contains(ForkMeetingIdentity("teams:300"))
        }
        suite.expect(survived, "two apps, two meetings: Zoom ending never ends Teams")
    }

    // MARK: - "Always", through the machine

    /// The service's loop, pure: each end, the meetings on with what a start
    /// would be asked with, then the time.
    private struct Live {
        var resolver: ForkMeetingResolver
        var machine = Machine()
        var effects: [Effect] = []

        init(apps json: String) {
            resolver = ForkMeetingResolver(ownPID: ForkMeetingAppsTests.ownPID, policies: ForkMeetingPolicies(json: json))
        }

        mutating func read(_ seconds: TimeInterval, windows: [Window]? = nil, microphones: [Microphone]? = nil) {
            let now = ForkMeetingAppsTests.at(seconds)
            let resolution = resolver.resolve(ForkMeetingReading(at: now, windows: windows, microphones: microphones))
            var facts = ForkMeetingAppsTests.ready
            facts.meetingsOnMicrophone = resolution.onMicrophone
            run(.candidates(resolution.candidates, ForkMeetingStartRequest(settings: ForkMeetingAppsTests.settings,
                                                                           facts: facts)), now)
            run(.tick, now)
        }

        mutating func send(_ event: Machine.Event, _ seconds: TimeInterval) {
            run(event, ForkMeetingAppsTests.at(seconds))
        }

        private mutating func run(_ event: Machine.Event, _ now: Date) {
            let produced = machine.handle(event, now: now)
            for case let .silence(identity) in produced { resolver.silence(identity, at: now) }
            effects += produced
        }

        var starts: [ForkMeetingCaptureConfig] {
            effects.compactMap {
                if case let .startCapture(config, _) = $0 { return config }
                return nil
            }
        }

        var offers: [ForkMeetingOffer] {
            effects.compactMap {
                if case let .showOffer(offer) = $0 { return offer }
                return nil
            }
        }
    }

    private static func alwaysForAnApp(_ suite: TestSuite) {
        let always = #"{"zoom":"always"}"#
        var titleOnly = Live(apps: always)
        titleOnly.read(0, windows: [window("Zoom Meeting")])
        titleOnly.read(3, windows: [window("Zoom Meeting")])
        suite.expect(titleOnly.starts.isEmpty && titleOnly.offers.map(\.candidate.identity.value) == ["zoom:500"],
                     "Always for Zoom without its microphone: offered, not started")

        var justOpened = Live(apps: always)
        justOpened.read(0, windows: [window("Zoom Meeting")])
        justOpened.read(2.5, microphones: [zoomMicrophone])
        justOpened.read(3, windows: [window("Zoom Meeting")])
        suite.expect(justOpened.starts.isEmpty && justOpened.offers.count == 1,
                     "nor with its microphone open for half a second")

        var locked = Live(apps: always)
        locked.send(.locked, -10)
        locked.read(-5, microphones: [zoomMicrophone])
        locked.read(0, windows: [window("Zoom Meeting")], microphones: [zoomMicrophone])
        locked.read(3, windows: [window("Zoom Meeting")], microphones: [zoomMicrophone])
        suite.expect(locked.starts.isEmpty && locked.offers.count == 1, "a locked screen: offered, nobody to cancel")

        var unlocked = Live(apps: always)
        unlocked.read(-5, microphones: [zoomMicrophone])
        unlocked.read(-3, microphones: [zoomMicrophone])
        unlocked.read(0, windows: [window("Zoom Meeting")], microphones: [zoomMicrophone])
        suite.expect(unlocked.starts.map(\.origin) == [.always] && unlocked.offers.isEmpty
                        && unlocked.starts.first?.meeting?.identity.value == "zoom:500",
                     "Zoom's microphone open for a second, the screen unlocked: Always starts it on its own")

        var faceTime = Live(apps: #"{"facetime":"always"}"#)
        let call = current.attributing([callDaemon], running: ["com.apple.FaceTime": faceTimePID])
        faceTime.read(-5, microphones: call)
        faceTime.read(-3, microphones: call)
        suite.expect(faceTime.starts.map(\.origin) == [.always]
                        && faceTime.starts.first.map { ForkMeetingDetectionSupport.settings($0.settings, for: $0.meeting) }?
                            .systemAudio == .all,
                     "Always for FaceTime starts its call, with the whole Mac's sound")
    }

    /// "Always" starts on its own only a meeting that proves who it is:
    /// Google Meet's code, or an app's own call (its process, its
    /// microphone: no page can be either). The other web calls have plain
    /// words for titles and no code to check: "Always" is not theirs, and a
    /// stored one reads as "Offer".
    private static func alwaysNeedsProof(_ suite: TestSuite) {
        let proofs = Dictionary(current.providers.map { ($0.name + "/" + $0.id, $0.alwaysProof) },
                                uniquingKeysWith: { first, _ in first })
        suite.expect(proofs["Google Meet/meet"] == .meetCode
                        && current.providers.filter { $0.kind == .app }.allSatisfy { $0.alwaysProof == .ownApp }
                        && ForkMeetingProvider.otherWebCalls.allSatisfy { $0.alwaysProof == .none },
                     "Meet proves itself by its code, an app by being itself, the other web calls never")
        suite.expect(current.policyRows.filter { !$0.allowsAlways }.map(\.id) == ["web"],
                     "the page offers Always for every row but the other web calls")
        let stored = ForkMeetingPolicies(json: #"{"web":"always","zoom":"always"}"#)
        suite.expect(ForkMeetingProvider.otherWebCalls.allSatisfy { stored.policy(for: $0) == .ask }
                        && stored.policy(for: .zoom) == .always && stored.stored["web"] == "always",
                     "an Always stored for the other web calls reads as Offer, the text kept as it was")

        // A page titled as Zoom's meeting window, or a Whereby room, the
        // browser's microphone open long before: offered, never started,
        // even with Always chosen for Zoom's app.
        for title in ["Zoom Meeting", "Whereby"] {
            var page = Live(apps: #"{"web":"always","zoom":"always"}"#)
            page.read(-5, microphones: [chromeMicrophone])
            page.read(0, windows: [chrome(title)], microphones: [chromeMicrophone])
            page.read(3, windows: [chrome(title)], microphones: [chromeMicrophone])
            page.read(6, windows: [chrome(title)], microphones: [chromeMicrophone])
            let offer = page.offers.first
            suite.expect(page.starts.isEmpty && page.offers.count == 1
                            && offer?.candidate.identity.value.hasPrefix("web:") == true
                            && offer.map(ForkMeetingOfferText.showsAlways) == false,
                         "« \(title) » in Chrome, its microphone open, Always: offered without « Always for », never started")
            guard offer != nil else { continue }
            page.effects = []
            page.send(.always(ForkMeetingStartRequest(settings: settings, facts: ready)), 7)
            suite.expect(page.starts.map(\.origin) == [.offered]
                            && !page.effects.contains { if case .setPolicy = $0 { return true } else { return false } },
                         "an « Always » that reaches such an offer only records it, and stores nothing")
        }
    }

    // MARK: - What is filmed and heard

    private static func candidate(_ identity: String, pid: Int32, appBundle: String, windowID: UInt32? = nil,
                                  windowBundle: String? = nil, sound: ForkMeetingSystemAudio = .app) -> ForkMeetingCandidate {
        ForkMeetingCandidate(identity: ForkMeetingIdentity(identity), provider: "zoom", providerName: "Zoom",
                             providerShortName: "Zoom", titleName: nil, meetCode: nil, calendarTitle: nil,
                             appBundle: appBundle, pid: pid, windowID: windowID, windowBundle: windowBundle,
                             defaultSound: sound, policy: .ask, silenced: false, bornAt: t0, alwaysProof: .ownApp)
    }

    private static func filmedAndHeard(_ suite: TestSuite) {
        typealias Support = ForkMeetingAppsSupport
        func shown(_ id: UInt32, pid: Int32, _ width: CGFloat, _ height: CGFloat, layer: Int = 0,
                   alpha: Double = 1) -> ForkMeetingWindowCandidate {
            ForkMeetingWindowCandidate(id: id, pid: pid, layer: layer, alpha: alpha,
                                       bounds: CGRect(x: 0, y: 0, width: width, height: height), ownerIsRegularApp: true)
        }
        let windows = [shown(1, pid: 42, 1600, 1000), shown(2, pid: zoomPID, 400, 300),
                       shown(3, pid: zoomPID, 1200, 800), shown(4, pid: zoomPID, 2000, 100),
                       shown(5, pid: zoomPID, 1900, 1200, layer: 3), shown(6, pid: zoomPID, 1900, 1200, alpha: 0)]
        let zoom = candidate("zoom:500", pid: zoomPID, appBundle: "us.zoom.xos")
        suite.expect(Support.window(for: zoom, in: windows, ownPID: ownPID) == 3,
                     "an app found by its microphone is filmed in its largest ordinary window, never another app's")
        suite.expect(Support.window(for: zoom, in: windows, ownPID: ownPID, excluded: [3]) == 2,
                     "a window left out is never filmed")
        var titled = zoom
        titled.windowID = 9
        suite.expect(Support.window(for: titled, in: windows, ownPID: ownPID) == 9,
                     "the window a title points at comes first")
        suite.expect(Support.window(for: zoom, in: [shown(1, pid: 42, 1600, 1000)], ownPID: ownPID) == nil,
                     "an app with no window on screen: its display is filmed, not the window in front")

        suite.expect(Support.soundPID(for: zoom, running: [700, 701]) == zoomPID,
                     "an app's meeting is heard from that app")
        let tab = candidate("meet:abc-defg-hij", pid: chromePID, appBundle: "com.google.Chrome", windowID: 7,
                            windowBundle: "com.google.Chrome")
        suite.expect(Support.soundPID(for: tab, running: [chromePID]) == chromePID, "a tab is heard from its browser")
        let webApp = candidate("meet:abc-defg-hij", pid: 120, appBundle: "com.google.Chrome", windowID: 7,
                               windowBundle: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan")
        suite.expect(Support.soundPID(for: webApp, running: [chromePID]) == chromePID
                        && Support.soundPID(for: webApp, running: [chromePID, 130]) == nil,
                     "a web app is heard from its browser when one copy runs, else from what is filmed")

        let call = candidate("facetime:600", pid: faceTimePID, appBundle: "com.apple.FaceTime", sound: .all)
        suite.expect(Support.soundOutsideApp(call) && !Support.soundOutsideApp(zoom),
                     "only FaceTime's call sound is no app's")
        let appSound = ForkMeetingDetectionSupport.settings(settings, for: call)
        var off = settings
        off.systemAudio = .off
        suite.expect(appSound.systemAudio == .all
                        && ForkMeetingDetectionSupport.settings(off, for: call).systemAudio == .off
                        && ForkMeetingDetectionSupport.settings(settings, for: zoom).systemAudio == .app,
                     "the meeting app's sound means the whole Mac for FaceTime; sound off stays off; Zoom keeps its own")
        suite.expect(ForkMeetingSoundSource.choose(.app, appPID: zoomPID, ownPID: ownPID, filmsWindow: false,
                                                   tapAvailable: true) == .appTap(pid: zoomPID),
                     "an app's meeting filmed on its display still hears that app alone")
    }

    private static func faceTimeSound(_ suite: TestSuite) {
        typealias Arbiter = ForkMeetingSoundArbiter
        var call = Arbiter(hasTap: true, hasWitness: true, tapFirst: true, macOnly: true)
        suite.expect(call.writesTap && !call.streamWrites(filmsWindow: true),
                     "FaceTime: the whole Mac's tap writes the call from the start")
        suite.expect(ForkMeetingTrackSound.of(setting: .all, sound: .macTap, arbiter: call, filmsWindow: true) == .heard,
                     "and the call is heard")
        _ = call.tapReaderLost()
        suite.expect(!call.streamWrites(filmsWindow: true) && call.streamWrites(filmsWindow: false),
                     "its tap lost, a window's sound (FaceTime.app alone) never stands in; a display's, the whole Mac, may")
        suite.expect(ForkMeetingTrackSound.of(setting: .all, sound: .macTap, arbiter: call, filmsWindow: true) == .lost
                        && ForkMeetingTrackSound.of(setting: .all, sound: .macTap, arbiter: call, filmsWindow: false)
                            == .heard,
                     "said lost while a window is filmed, heard again once its display is")

        var missing = Arbiter(hasTap: true, hasWitness: true, tapFirst: true, macOnly: true)
        _ = missing.streamBuffer(heard: true, counts: true, seconds: 3.5)
        suite.expect(missing.permission == .missing && !missing.streamWrites(filmsWindow: true),
                     "without the system audio permission, a window's sound never stands in for the call either")

        var mac = Arbiter(hasTap: true, hasWitness: true, tapFirst: false)
        suite.expect(!mac.writesTap && mac.streamWrites(filmsWindow: true) && mac.tapReaderLost() == false
                        && mac.streamWrites(filmsWindow: true),
                     "the whole Mac chosen for another meeting keeps its rule: the stream until the tap is proved")
        var app = Arbiter(hasTap: true, hasWitness: true, appOnly: false)
        _ = app.tapReaderLost()
        suite.expect(app.streamWrites(filmsWindow: true) && !app.streamWrites(filmsWindow: false),
                     "an app's tap lost still gives way to a window's sound alone")
    }

    private static func tapRepair(_ suite: TestSuite) {
        var repair = ForkMeetingTapRepair()
        suite.expect(repair.tryAgain() && repair.tryAgain() && !repair.tryAgain(),
                     "a tap that lost its reader gets two new ones, then the track gives up on it")
        repair.heard()
        suite.expect(repair.tryAgain(), "one that heard sound again earns its tries back, for the next device change")
        suite.expect(ForkMeetingTapRepair.attempts == 2 && ForkMeetingTapRepair.delay == 1,
                     "a second between tries, as the S3 spike asks")
    }

    // MARK: - The page

    private static func page(_ suite: TestSuite) {
        let rows = current.policyRows
        suite.expect(rows.map(\.id) == ["meet", "zoom", "teams", "slack", "facetime", "webex", "discord", "web"]
                        && rows.map(\.name) == ["Google Meet", "Zoom", "Microsoft Teams", "Slack", "FaceTime", "Webex",
                                                "Discord", nil]
                        && rows.last?.providers.count == 4,
                     "one row per provider, the other web calls together, named in the person's language")
        suite.expect(rows.first { $0.id == "webex" }?.appBundles == ["Cisco-Systems.Spark", "com.webex.meetingmanager"]
                        && rows.first?.appBundles.isEmpty == true && rows.last?.appBundles.isEmpty == true,
                     "an app's row shows its icon, a browser's none")
        suite.expect(rows.filter { $0.recognized(microphoneSignal: false) }.map(\.id) == ["meet", "zoom"]
                        && rows.allSatisfy { $0.recognized(microphoneSignal: true) },
                     "before macOS 14.4 only Google Meet and Zoom are recognized, by their titles")
        suite.expect(rows.filter(\.recordsWholeMac).map(\.id) == ["facetime"], "FaceTime's row says the whole Mac is recorded")
        var tooLong: [String] = []
        for language in AppLanguage.allCases {
            let strings = ForkMeetingStrings.strings(language)
            if strings.detectionUnavailable.count > 28 { tooLong.append(language.rawValue) }
        }
        suite.expect(tooLong.isEmpty, "a row's \"not on this Mac\" fits in 28 characters: \(tooLong)")
        let english = ForkMeetingStrings.strings(.enUS)
        suite.expect(["Zoom", "Teams", "Slack", "FaceTime", "Webex", "Discord"].allSatisfy(english.detectionCaption.contains)
                        && english.detectionTitlesOnly.contains("Zoom") && english.detectionFaceTimeWholeMac.contains("FaceTime"),
                     "the page names the apps it recognizes, and what macOS 14.0 to 14.3 allows")
    }
}
