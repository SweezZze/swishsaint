// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What a meeting from a provider does without asking: offer it, start it
/// ("Always", chosen by the person) or never offer it.
enum ForkMeetingPolicy: String, CaseIterable, Equatable {
    case ask
    case always
    case never
}

/// One meeting service the detection knows: where its meetings show, how
/// they are named, what is recorded by default. A provider of a later
/// version is one more entry of the table, with its own title rules.
struct ForkMeetingProvider: Equatable {
    enum Kind: Equatable {
        /// Lives in a browser: only a window title makes a meeting; the
        /// browser's microphone confirms it and keeps it alive, never makes
        /// one (a browser uses the microphone for many other things).
        case web
        /// An app of its own: its microphone alone makes a meeting, its
        /// windows too when the provider has title rules.
        case app
    }

    /// How a meeting of this provider is told from another.
    enum IdentityScheme: Equatable {
        /// `<id>:<code>` when the title shows a code, else
        /// `<id>:<pid>:<title>`, the title as read (Chrome's cut kept).
        case codeOrWindow
        /// `<id>:<pid>#<birth>`: one meeting at a time per app process,
        /// each one after the other numbered (`zoom:500#2`); `<id>#<birth>`
        /// for a provider of two apps (`webex#1`).
        case appProcess
    }

    let id: String
    /// Never translated: "Google Meet", "Zoom".
    let name: String
    /// For the offer's menu: "Always for Meet".
    let shortName: String
    let kind: Kind
    /// The apps whose windows and microphone count, exactly.
    let bundles: Set<String>
    /// Web apps' bundle prefixes, each with the browser hosting them: the
    /// window belongs to the web app, the microphone and the sound to the
    /// browser (`com.google.Chrome.app.<id>` → `com.google.Chrome`).
    let webAppHosts: [String: String]
    /// System processes no app owns that carry this provider's calls.
    let processBundles: Set<String>
    let titles: ForkMeetingTitleRuleSet?
    let identity: IdentityScheme
    let defaultSound: ForkMeetingSystemAudio
    let defaultPolicy: ForkMeetingPolicy
    /// Whether its titles make a meeting on their own ("Zoom Meeting"), or
    /// only name it and point at its window once its microphone made it
    /// (Slack's "Huddle", which a channel may be called).
    var titlesMakeMeetings = true
    /// The link a calendar event holds for one of its meetings (Zoom's
    /// `zoom.us/j/`…): with "Name with the calendar", the event going on
    /// that holds one names the meeting. Google Meet goes by its code.
    var calendarLink: ForkMeetingCalendarLink? = nil
    /// Of its apps, the one whose icon the page shows first (the new Teams).
    var iconBundle: String? = nil

    /// What lets "Always" start one of its meetings on its own, once its
    /// microphone has been open for a second on a screen not locked.
    enum AlwaysProof: Equatable {
        /// Google Meet: its code in the title. A page may call itself
        /// "Meet – x"; the code is Meet's own.
        case meetCode
        /// An app whose meetings have a window of their own (Zoom's meeting
        /// window, Slack's huddle): that window, which testing the
        /// microphone in its settings never opens.
        case meetingWindow
        /// An app without one (Teams, Webex, Discord): its microphone open
        /// for `ForkMeetingCandidate.alwaysMicrophone`, longer than a test.
        case longMicrophone
        /// FaceTime, whose system process carries an iPhone call relayed
        /// too, and the other web calls, plain words any page may use with
        /// no code to check. "Always" is not offered for them: they are
        /// offered.
        case none
    }

    var alwaysProof: AlwaysProof {
        switch kind {
        case .app:
            guard processBundles.isEmpty else { return .none }
            return titles != nil ? .meetingWindow : .longMicrophone
        case .web:
            return titles == .googleMeet ? .meetCode : .none
        }
    }

    /// Whether the window of `bundle` is one of this provider's.
    func owns(windowBundle bundle: String) -> Bool {
        bundles.contains(bundle) || webAppHosts.keys.contains(where: bundle.hasPrefix)
    }

    /// The app behind a window: a web app's browser, else the app itself.
    func family(of bundle: String) -> String {
        if bundles.contains(bundle) { return bundle }
        for (prefix, host) in webAppHosts where bundle.hasPrefix(prefix) { return host }
        return bundle
    }

    /// Whether a microphone reading belongs to this provider: its app owns
    /// the process. A system process of its own (`processBundles`) counts
    /// once `ForkMeetingProviderTable.attributing` gave it to the app, which
    /// it does only while the app runs.
    func owns(_ microphone: ForkMeetingMicSignal) -> Bool {
        guard let app = microphone.appBundle else { return false }
        return bundles.contains(app)
    }
}

extension ForkMeetingProvider {
    /// The browsers Google Meet runs in (§6.2 of the plan), their test and
    /// beta channels included. Firefox and Safari are not Chromium: their
    /// web apps are not listed, the tab is.
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser", "com.brave.Browser.beta",
        "com.brave.Browser.nightly", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.kagi.kagimacOS",
    ]

    /// Chromium's installed web apps: a bundle of their own per app, the
    /// browser's audio process for their microphone.
    static let webAppHosts: [String: String] = [
        "com.google.Chrome.app.": "com.google.Chrome",
        "com.google.Chrome.beta.app.": "com.google.Chrome.beta",
        "com.google.Chrome.canary.app.": "com.google.Chrome.canary",
        "org.chromium.Chromium.app.": "org.chromium.Chromium",
        "com.microsoft.edgemac.app.": "com.microsoft.edgemac",
        "com.brave.Browser.app.": "com.brave.Browser",
        "com.vivaldi.Vivaldi.app.": "com.vivaldi.Vivaldi",
    ]

    static let googleMeet = ForkMeetingProvider(
        id: "meet", name: "Google Meet", shortName: "Meet", kind: .web, bundles: browsers, webAppHosts: webAppHosts,
        processBundles: [], titles: .googleMeet, identity: .codeOrWindow, defaultSound: .app, defaultPolicy: .ask)

    // MARK: Apps

    /// Zoom's app: its meeting window ("Zoom Meeting", "Réunion Zoom"…, as
    /// Zoom 6.6 translates it), or its microphone. The helpers that share a
    /// screen or run AirPlay are Zoom's own processes: their microphone and
    /// their sound are Zoom's (S3).
    static let zoom = ForkMeetingProvider(
        id: "zoom", name: "Zoom", shortName: "Zoom", kind: .app, bundles: ["us.zoom.xos"], webAppHosts: [:],
        processBundles: [], titles: .zoomApp, identity: .appProcess, defaultSound: .app, defaultPolicy: .ask,
        calendarLink: .zoom)

    /// The new Teams and the classic one: its microphone. Its titles say
    /// as much in a chat as in a call, so they are not read.
    static let teams = ForkMeetingProvider(
        id: "teams", name: "Microsoft Teams", shortName: "Teams", kind: .app,
        bundles: ["com.microsoft.teams2", "com.microsoft.teams"], webAppHosts: [:], processBundles: [], titles: nil,
        identity: .appProcess, defaultSound: .app, defaultPolicy: .ask, calendarLink: .teams,
        iconBundle: "com.microsoft.teams2")

    /// A huddle: Slack's microphone (its audio helper is Slack's); a
    /// "Huddle" window names it and is the one filmed, never makes it.
    static let slack = ForkMeetingProvider(
        id: "slack", name: "Slack", shortName: "Slack", kind: .app, bundles: ["com.tinyspeck.slackmacgap"],
        webAppHosts: [:], processBundles: [], titles: .slackHuddle, identity: .appProcess, defaultSound: .app,
        defaultPolicy: .ask, titlesMakeMeetings: false)

    /// A call runs in `avconferenced` (and `callservicesd`), system
    /// processes no app owns: theirs counts as FaceTime's only while
    /// FaceTime is open. Their sound is no app's: the whole Mac is recorded.
    /// An iPhone call relayed runs there too: offered, never "Always".
    static let faceTime = ForkMeetingProvider(
        id: "facetime", name: "FaceTime", shortName: "FaceTime", kind: .app, bundles: ["com.apple.FaceTime"],
        webAppHosts: [:], processBundles: ["com.apple.avconferenced", "com.apple.TelephonyUtilities"], titles: nil,
        identity: .appProcess, defaultSound: .all, defaultPolicy: .ask)

    /// Webex and the older Webex Meetings, two apps of their own.
    static let webex = ForkMeetingProvider(
        id: "webex", name: "Webex", shortName: "Webex", kind: .app,
        bundles: ["Cisco-Systems.Spark", "com.webex.meetingmanager"], webAppHosts: [:], processBundles: [],
        titles: nil, identity: .appProcess, defaultSound: .app, defaultPolicy: .ask, calendarLink: .webex)

    /// Off by default: much of its voice chat is leisure.
    static let discord = ForkMeetingProvider(
        id: "discord", name: "Discord", shortName: "Discord", kind: .app, bundles: ["com.hnc.Discord"],
        webAppHosts: [:], processBundles: [], titles: nil, identity: .appProcess, defaultSound: .app,
        defaultPolicy: .never)

    /// The other calls in a browser, one choice for all of them (`web`):
    /// Zoom's web client, Whereby, Jitsi Meet, Teams on the web. Their
    /// titles are plain words an article may use too, so a title only ever
    /// makes a meeting with the browser's microphone in use.
    static let otherWebCalls: [ForkMeetingProvider] = [
        web("Zoom", .zoomWeb, link: .zoom), web("Whereby", .whereby, link: .whereby),
        web("Jitsi Meet", .jitsiMeet, link: .jitsi), web("Microsoft Teams", .teamsWeb, shortName: "Teams", link: .teams),
    ]

    private static func web(_ name: String, _ titles: ForkMeetingTitleRuleSet, shortName: String? = nil,
                            link: ForkMeetingCalendarLink) -> ForkMeetingProvider {
        ForkMeetingProvider(id: "web", name: name, shortName: shortName ?? name, kind: .web, bundles: browsers,
                            webAppHosts: webAppHosts, processBundles: [], titles: titles, identity: .codeOrWindow,
                            defaultSound: .app, defaultPolicy: .ask, titlesMakeMeetings: false, calendarLink: link)
    }
}

/// The providers the detection looks for, in the order a window is tried
/// against them.
struct ForkMeetingProviderTable: Equatable {
    let providers: [ForkMeetingProvider]

    /// This version (§6.2 of the plan): Google Meet first, so a browser's
    /// window is read with its rules before the other calls'.
    static let current = ForkMeetingProviderTable(
        providers: [.googleMeet, .zoom, .teams, .slack, .faceTime, .webex, .discord] + ForkMeetingProvider.otherWebCalls)

    func provider(id: String) -> ForkMeetingProvider? {
        providers.first { $0.id == id }
    }

    /// Every bundle whose windows the scanner should report.
    var windowBundles: Set<String> {
        providers.reduce(into: Set<String>()) { $0.formUnion($1.bundles) }
    }

    /// Whether the scanner should report a window of `bundle`, a web app's
    /// included.
    func watchesWindows(of bundle: String) -> Bool {
        providers.contains { $0.owns(windowBundle: bundle) }
    }

    // MARK: Apps

    /// The system processes some provider's calls run in.
    var systemProcessBundles: Set<String> {
        providers.reduce(into: Set<String>()) { $0.formUnion($1.processBundles) }
    }

    /// The apps whose running makes their system processes theirs.
    var systemProcessHosts: Set<String> {
        providers.filter { !$0.processBundles.isEmpty }.reduce(into: Set<String>()) { $0.formUnion($1.bundles) }
    }

    /// The microphones with a system process that carries a provider's calls
    /// given to that provider's app, when it runs (`running`: bundle →
    /// pid): `avconferenced` recording while FaceTime is open is FaceTime's
    /// call. With FaceTime closed it is nobody's (an iPhone call relayed, a
    /// Continuity camera), and makes nothing.
    func attributing(_ microphones: [ForkMeetingMicSignal], running: [String: Int32]) -> [ForkMeetingMicSignal] {
        microphones.map { microphone in
            guard microphone.appBundle == nil, let process = microphone.processBundle else { return microphone }
            for provider in providers where provider.processBundles.contains(process) {
                guard let (bundle, pid) = provider.bundles.sorted().lazy
                    .compactMap({ bundle in running[bundle].map { (bundle, $0) } }).first else { continue }
                var owned = microphone
                owned.appBundle = bundle
                owned.appPID = pid
                return owned
            }
            return microphone
        }
    }

    /// The page's rows, one per choice in `fork.meetings.apps`, in the
    /// table's order: the other web calls share one.
    var policyRows: [ForkMeetingPolicyRow] {
        var rows: [ForkMeetingPolicyRow] = []
        for provider in providers {
            if let index = rows.firstIndex(where: { $0.id == provider.id }) {
                rows[index].providers.append(provider)
            } else {
                rows.append(ForkMeetingPolicyRow(id: provider.id, providers: [provider]))
            }
        }
        return rows
    }
}

/// One choice of the page's Detection section: a provider, or the other
/// web calls together.
struct ForkMeetingPolicyRow: Equatable {
    let id: String
    var providers: [ForkMeetingProvider]

    /// The brand, never translated; `nil` for the other web calls, which
    /// the page names in the person's language.
    var name: String? {
        id == "web" ? nil : providers.first?.name
    }

    /// The apps whose icon stands for the row, the first installed one
    /// shown (the new Teams before the classic one); none for the browsers'
    /// rows.
    var appBundles: [String] {
        guard providers.first?.kind == .app else { return [] }
        return providers.flatMap { provider in
            provider.bundles.sorted { first, second in
                let preferred = (first == provider.iconBundle, second == provider.iconBundle)
                return preferred.0 != preferred.1 ? preferred.0 : first < second
            }
        }
    }

    /// Whether its meetings are recognized on a Mac that cannot say which
    /// app records (before macOS 14.4): only by a title that makes a meeting
    /// on its own (Google Meet's code, Zoom's meeting window).
    func recognized(microphoneSignal: Bool) -> Bool {
        microphoneSignal || providers.contains { $0.titles != nil && $0.titlesMakeMeetings }
    }

    /// Whether "Always" is one of its choices: not for the other web calls,
    /// which nothing can tell from a page that copies their title, nor for
    /// FaceTime, which an iPhone call relayed looks like.
    var allowsAlways: Bool {
        providers.allSatisfy { $0.alwaysProof != .none }
    }

    /// FaceTime's calls record the whole Mac: the page says so.
    var recordsWholeMac: Bool {
        providers.contains { $0.defaultSound == .all }
    }

    /// FaceTime's system process carries an iPhone call relayed too: the
    /// page says it may be offered.
    var offersRelayedCalls: Bool {
        providers.contains { !$0.processBundles.isEmpty }
    }

    // MARK: Fixes K

    /// Whether the page shows "Always": not on a Mac that cannot say which
    /// app uses the microphone (before macOS 14.4), where it never starts
    /// anything (it needs the microphone), Meet and Zoom included.
    func showsAlways(microphoneSignal: Bool) -> Bool {
        allowsAlways && microphoneSignal
    }

    /// The choice the row shows: an "Always" it does not show reads as
    /// "Offer", as it acts.
    func shown(_ policy: ForkMeetingPolicy, microphoneSignal: Bool) -> ForkMeetingPolicy {
        policy == .always && !showsAlways(microphoneSignal: microphoneSignal) ? .ask : policy
    }

    /// FaceTime's warning that the whole Mac is recorded: while its calls
    /// may be offered, with the meeting app's sound chosen (the whole Mac
    /// for FaceTime). "Whole Mac" chosen says it already; no sound records
    /// none of it.
    func warnsWholeMac(_ policy: ForkMeetingPolicy, sound: ForkMeetingSystemAudio) -> Bool {
        recordsWholeMac && policy != .never && sound == .app
    }

    /// "A phone call relayed from your iPhone may be offered too", while
    /// FaceTime's calls may be.
    func notesRelayedCalls(_ policy: ForkMeetingPolicy) -> Bool {
        offersRelayedCalls && policy != .never
    }
}

/// The person's choice per provider, kept in `fork.meetings.apps` as a JSON
/// object (`{"meet":"ask","discord":"never",…}`). Read leniently: unreadable
/// JSON, an unknown value or a missing provider fall back to the defaults;
/// a provider this version does not know is kept as it was.
struct ForkMeetingPolicies: Equatable {
    /// The stored default: every provider of the plan, Discord off (much of
    /// its voice chat is leisure).
    static let defaultJSON =
        #"{"discord":"never","facetime":"ask","meet":"ask","slack":"ask","teams":"ask","web":"ask","webex":"ask","zoom":"ask"}"#

    private(set) var stored: [String: String]

    init(json: String) {
        let object = json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        stored = (object ?? [:]).compactMapValues { $0 as? String }
    }

    /// "Always" for a provider that cannot have it (written by hand, or by
    /// an earlier version) reads as "Offer".
    func policy(for provider: ForkMeetingProvider) -> ForkMeetingPolicy {
        let policy = stored[provider.id].flatMap(ForkMeetingPolicy.init(rawValue:)) ?? provider.defaultPolicy
        return policy == .always && provider.alwaysProof == .none ? .ask : policy
    }

    mutating func set(_ policy: ForkMeetingPolicy, for providerID: String) {
        stored[providerID] = policy.rawValue
    }

    /// Sorted keys, so the same choices always write the same text.
    var json: String {
        guard let data = try? JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys]) else {
            return Self.defaultJSON
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func load(_ defaults: UserDefaults = .standard) -> ForkMeetingPolicies {
        ForkMeetingPolicies(json: defaults.string(forKey: ForkDefaultsKey.meetingsApps) ?? defaultJSON)
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(json, forKey: ForkDefaultsKey.meetingsApps)
    }
}

// MARK: Fixes K

/// The meeting links a calendar event may hold, other than Google Meet's
/// (which gives a code): an app's or a web call's. Only the kind of link
/// leaves the calendar's queue, never the link.
enum ForkMeetingCalendarLink: String, CaseIterable, Equatable {
    case zoom, teams, webex, whereby, jitsi

    /// The links found in an event's link, place or notes: `zoom.us/j/`,
    /// `zoom.us/my/`, `zoomgov.com/j/`, `teams.microsoft.com/l/meetup-join`,
    /// `teams.microsoft.com/meet/`, `teams.live.com/meet/`, `webex.com/meet`
    /// or a `<site>.webex.com/…/j.php`, `whereby.com/`, `meet.jit.si/`; an
    /// Outlook safe link read as the link it wraps.
    static func found(in text: String) -> Set<ForkMeetingCalendarLink> {
        Set(addresses(in: text).map(\.link))
    }

    /// A print of each meeting link of the text, its address without its
    /// query: the same event in two calendars (one of them wrapping it in a
    /// safe link) has the same. Kept in memory for this run only.
    static func prints(in text: String) -> Set<Int> {
        Set(addresses(in: text).map(\.address.hashValue))
    }

    /// The text with each Outlook safe link's own link after it, decoded
    /// (`…safelinks.protection.outlook.com/?url=https%3A%2F%2Fzoom.us…`):
    /// what the event really links to, for its Meet code too.
    static func unwrapped(_ text: String) -> String {
        let wrapped = words(text).compactMap { word -> String? in
            guard word.lowercased().contains("safelinks.protection.outlook.com") else { return nil }
            return safeLinkTarget(String(word))
        }
        return wrapped.isEmpty ? text : ([text] + wrapped).joined(separator: "\n")
    }

    private static func words(_ text: String) -> [Substring] {
        text.split { $0.isWhitespace || "<>\"'()[]".contains($0) }
    }

    /// The `url=` a safe link wraps, decoded.
    private static func safeLinkTarget(_ word: String) -> String? {
        if let items = URLComponents(string: word)?.queryItems,
           let target = items.first(where: { $0.name.lowercased() == "url" })?.value, !target.isEmpty {
            return target
        }
        guard let start = word.range(of: "url=", options: .caseInsensitive) else { return nil }
        let value = word[start.upperBound...].prefix { $0 != "&" }
        return String(value).removingPercentEncoding
    }

    private static func addresses(in text: String) -> [(link: ForkMeetingCalendarLink, address: String)] {
        var found: [(link: ForkMeetingCalendarLink, address: String)] = []
        for word in words(unwrapped(text)).map({ $0.lowercased() }) {
            let address = String(word.prefix { $0 != "?" && $0 != "#" })
                .trimmingCharacters(in: CharacterSet(charactersIn: "/.,;:"))
            for link in kinds(of: word) { found.append((link, address)) }
        }
        return found
    }

    private static func kinds(of word: String) -> [ForkMeetingCalendarLink] {
        var links: [ForkMeetingCalendarLink] = []
        if ["zoom.us/j/", "zoom.us/my/", "zoomgov.com/j/", "zoomgov.com/my/"].contains(where: word.contains) {
            links.append(.zoom)
        }
        if ["teams.microsoft.com/l/meetup-join", "teams.microsoft.com/meet/", "teams.live.com/meet/"]
            .contains(where: word.contains) {
            links.append(.teams)
        }
        if word.contains("webex.com/meet") || (word.contains(".webex.com/") && word.contains("/j.php")) {
            links.append(.webex)
        }
        if word.contains("whereby.com/") { links.append(.whereby) }
        if word.contains("meet.jit.si/") { links.append(.jitsi) }
        return links
    }

    /// The event going on (10 minutes either way) that holds this link,
    /// when it is the only one; two of them, or none, name nothing. One
    /// event in two calendars (the same times, the same link) is one.
    static func event(_ link: ForkMeetingCalendarLink, at now: Date,
                      in hints: [ForkMeetingCalendarHint]) -> ForkMeetingCalendarHint? {
        let margin: TimeInterval = 10 * 60
        var going: [ForkMeetingCalendarHint] = []
        for hint in hints where hint.links.contains(link) && hint.startsAt.addingTimeInterval(-margin) <= now
            && now <= hint.endsAt.addingTimeInterval(margin) {
            let copy = going.contains { other in
                let sameLink = (other.linkPrints.isEmpty && hint.linkPrints.isEmpty)
                    || !other.linkPrints.isDisjoint(with: hint.linkPrints)
                return other.startsAt == hint.startsAt && other.endsAt == hint.endsAt && sameLink
            }
            if !copy { going.append(hint) }
        }
        return going.count == 1 ? going[0] : nil
    }
}

/// When a meeting the detection started ends: after a countdown, or never.
struct ForkMeetingAutoStop: Equatable {
    static let defaultSeconds = 15
    /// A countdown too short to reach "Continue", or one that hides a meeting
    /// long over, is brought back within these bounds.
    static let secondsRange = 5...120

    var enabled: Bool
    var seconds: Int

    /// The countdown to give the machine: `nil` when the recording never
    /// stops on its own.
    var countdown: TimeInterval? {
        enabled ? TimeInterval(Self.bounded(seconds)) : nil
    }

    /// A stored delay as the countdown really runs it, and as the page
    /// shows it.
    static func bounded(_ seconds: Int) -> Int {
        min(max(seconds, secondsRange.lowerBound), secondsRange.upperBound)
    }

    static func load(_ defaults: UserDefaults = .standard) -> ForkMeetingAutoStop {
        let stored = defaults.object(forKey: ForkDefaultsKey.meetingsAutoStopSeconds) as? Int
        return ForkMeetingAutoStop(enabled: defaults.object(forKey: ForkDefaultsKey.meetingsAutoStop) as? Bool ?? true,
                                   seconds: stored ?? defaultSeconds)
    }
}
