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
        /// `<id>:<pid>`: one meeting at a time per app process.
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
    /// the process, or the process is one of its system ones.
    func owns(_ microphone: ForkMeetingMicSignal) -> Bool {
        if let app = microphone.appBundle, bundles.contains(app) { return true }
        if let process = microphone.processBundle, processBundles.contains(process) { return true }
        return false
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
}

/// The providers the detection looks for, in the order a window is tried
/// against them.
struct ForkMeetingProviderTable: Equatable {
    let providers: [ForkMeetingProvider]

    /// This version: Google Meet, in the browsers and as a web app.
    static let current = ForkMeetingProviderTable(providers: [.googleMeet])

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

    func policy(for provider: ForkMeetingProvider) -> ForkMeetingPolicy {
        stored[provider.id].flatMap(ForkMeetingPolicy.init(rawValue:)) ?? provider.defaultPolicy
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
        enabled ? TimeInterval(min(max(seconds, Self.secondsRange.lowerBound), Self.secondsRange.upperBound)) : nil
    }

    static func load(_ defaults: UserDefaults = .standard) -> ForkMeetingAutoStop {
        let stored = defaults.object(forKey: ForkDefaultsKey.meetingsAutoStopSeconds) as? Int
        return ForkMeetingAutoStop(enabled: defaults.object(forKey: ForkDefaultsKey.meetingsAutoStop) as? Bool ?? true,
                                   seconds: stored ?? defaultSeconds)
    }
}
