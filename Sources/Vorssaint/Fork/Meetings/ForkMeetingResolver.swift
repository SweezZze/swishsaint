// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What the resolver concluded from a reading.
struct ForkMeetingResolution: Equatable {
    /// The meetings alive now, the most recent first. A provider set to
    /// "Never" is left out.
    var candidates: [ForkMeetingCandidate] = []
    /// The meetings that probably just ended, each said once.
    var ended: [ForkMeetingIdentity] = []
    /// The meetings whose app has used a microphone for a second at least:
    /// "Always" starts only those on its own (`ForkMeetingStartFacts`).
    var onMicrophone: Set<ForkMeetingIdentity> = []
}

/// From timestamped readings of the windows and the microphones to the
/// meetings going on. Pure: the scanners read the Mac, the machine decides
/// what to do; this only says which meetings exist, since when, and when
/// they end.
///
/// - A meeting is **born** after two readings that agree, at least a second
///   apart: two window readings with its title, or (an app's meeting) two
///   microphone readings. A Google Meet whose title shows its code is born
///   at its first window reading once its browser's microphone has been open
///   for a second: Meet opens the microphone for ~400 ms when its page loads
///   (S2), which never counts. A title without a code ("Meet – x", which
///   any page may be called) needs both: two readings, and the browser's
///   microphone open for a second.
/// - A browser's microphone alone never makes a meeting: a browser uses it
///   for many other things.
/// - A meeting **lives** while one of its windows shows it (hidden,
///   minimized or on another Space) **or** while its app uses a microphone:
///   a Meet tab in the background lives on its browser's microphone, unless
///   another meeting of that browser shows with its code, the microphone
///   opened again since (two Meet in a row: the microphone is the new
///   one's). A title without a code, or another Meet's waiting room on the
///   same microphone, never takes it from a call going on.
/// - It **probably ends** when both have been gone for 20 s, or at once when
///   its window says the call is over and its microphone is free: an end
///   page with the microphone still open leaves it to the 20 s (another tab
///   may still be in its own call).
/// - Without Screen Recording no title can be read: a meeting in a browser
///   ends.
/// - Our own process is never a signal: our dictation and our recording
///   open the microphone too.
/// - A meeting set aside ("Not now", or already offered) stays so until it
///   has been over for 10 minutes: coming back to its tab offers nothing.
/// - Meetings are told apart by identity: one ending never ends another.
struct ForkMeetingResolver {
    struct Tuning: Equatable {
        /// Readings that must agree before a meeting is born…
        var entryReadings = 2
        /// …at least this far apart, so two readings of one moment do not.
        var entrySpan: TimeInterval = 1
        /// A browser's microphone open this long confirms a meeting's code.
        var microphoneSettle: TimeInterval = 1
        /// Both signals gone this long: the meeting probably ended.
        var endAfter: TimeInterval = 20
        /// A meeting set aside stays so this long after its end.
        var silenceAfterEnd: TimeInterval = 600
    }

    let table: ForkMeetingProviderTable
    /// This app's process: never a signal.
    let ownPID: Int32
    let tuning: Tuning
    var policies: ForkMeetingPolicies

    private struct Track {
        let identity: ForkMeetingIdentity
        let provider: ForkMeetingProvider
        /// The app whose microphone keeps it alive and whose sound is recorded.
        var family: String
        var pid: Int32
        var windowID: UInt32?
        var windowBundle: String?
        var titleName: String?
        var meetCode: String?
        /// The last window reading showed it.
        var windowSeen = false
        /// When the browser's microphone run it was last shown with began:
        /// a run begun later is another meeting's.
        var microphoneRun: Date?
        var windowReadings = 0
        var firstWindowAt: Date?
        var microphoneReadings = 0
        var firstMicrophoneAt: Date?
        var bornAt: Date?
        var absentSince: Date?

        init(identity: ForkMeetingIdentity, provider: ForkMeetingProvider, family: String, pid: Int32) {
            self.identity = identity
            self.provider = provider
            self.family = family
            self.pid = pid
        }
    }

    private var tracks: [ForkMeetingIdentity: Track] = [:]
    /// The last microphone reading, our own process left out.
    private var microphones: [ForkMeetingMicSignal] = []
    /// Since when each app's (or system process's) input has been running,
    /// reading after reading.
    private var microphoneSince: [String: Date] = [:]
    private var calendar: [ForkMeetingCalendarHint] = []
    /// Set-aside meetings, with when they ended (`nil` while alive).
    private var silenced: [ForkMeetingIdentity: Date?] = [:]

    init(table: ForkMeetingProviderTable = .current, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
         policies: ForkMeetingPolicies = ForkMeetingPolicies(json: ForkMeetingPolicies.defaultJSON),
         tuning: Tuning = Tuning()) {
        self.table = table
        self.ownPID = ownPID
        self.policies = policies
        self.tuning = tuning
    }

    /// Whether a meeting is set aside now.
    func isSilenced(_ identity: ForkMeetingIdentity) -> Bool { silenced.keys.contains(identity) }

    /// "Not now", an offer shown, or a recording started: no new offer opens
    /// for this meeting until it has been over for 10 minutes.
    mutating func silence(_ identity: ForkMeetingIdentity, at now: Date) {
        silenced[identity] = tracks[identity]?.bornAt == nil ? .some(now) : .some(nil)
    }

    /// The feature was turned off: everything is forgotten.
    mutating func reset() {
        tracks = [:]
        microphones = []
        microphoneSince = [:]
        calendar = []
        silenced = [:]
    }

    /// Takes a reading (a source left `nil` keeps what it said last; none at
    /// all just lets the time pass) and says the meetings alive and the
    /// ones that ended.
    mutating func resolve(_ reading: ForkMeetingReading) -> ForkMeetingResolution {
        let now = reading.at
        if let hints = reading.calendar { calendar = hints }
        if let readMicrophones = reading.microphones { takeMicrophones(readMicrophones, at: now) }
        var ended: [ForkMeetingIdentity] = []
        if reading.titlesUnreadable {
            ended += forgetWebMeetings()
        } else if let windows = reading.windows {
            ended += takeWindows(windows, at: now)
        }
        ended += live(at: now)
        for identity in ended where silenced.keys.contains(identity) { silenced[identity] = .some(now) }
        silenced = silenced.filter { _, endedAt in
            guard let endedAt else { return true }
            return now.timeIntervalSince(endedAt) < tuning.silenceAfterEnd
        }
        return ForkMeetingResolution(candidates: candidates(), ended: ended.sorted { $0.value < $1.value },
                                     onMicrophone: onMicrophone(at: now))
    }

    // MARK: - Readings

    private mutating func takeMicrophones(_ readMicrophones: [ForkMeetingMicSignal], at now: Date) {
        microphones = readMicrophones.filter { $0.pid != ownPID && $0.appPID != ownPID }
        let running = Set(microphones.compactMap { $0.appBundle ?? $0.processBundle })
        microphoneSince = microphoneSince.filter { running.contains($0.key) }
        for key in running where microphoneSince[key] == nil { microphoneSince[key] = now }

        // An app's own meetings come from its microphone.
        var seen = Set<ForkMeetingIdentity>()
        for provider in table.providers where provider.kind == .app {
            for microphone in microphones where provider.owns(microphone) {
                let pid = microphone.appPID ?? microphone.pid
                let identity = ForkMeetingIdentity("\(provider.id):\(pid)")
                guard !seen.contains(identity) else { continue }
                seen.insert(identity)
                var track = tracks[identity] ?? newTrack(identity, provider: provider,
                                                         family: microphone.appBundle ?? microphone.processBundle ?? "",
                                                         pid: pid)
                if track.firstMicrophoneAt == nil { track.firstMicrophoneAt = now }
                track.microphoneReadings += 1
                tracks[identity] = track
            }
        }
        for (identity, var track) in tracks where track.provider.kind == .app && !seen.contains(identity) {
            track.microphoneReadings = 0
            track.firstMicrophoneAt = nil
            tracks[identity] = track
        }
    }

    /// Returns the meetings whose window says they are over.
    private mutating func takeWindows(_ windows: [ForkMeetingWindowSignal], at now: Date) -> [ForkMeetingIdentity] {
        struct Sighting {
            let provider: ForkMeetingProvider
            let window: ForkMeetingWindowSignal
            let code: String?
            let name: String?
        }
        var sightings: [ForkMeetingIdentity: Sighting] = [:]
        var exits = Set<UInt32>()
        for window in windows where window.pid != ownPID {
            for provider in table.providers where provider.owns(windowBundle: window.bundle) {
                guard let rules = provider.titles else { continue }
                switch ForkMeetingTitleRules.verdict(window.title, rules: rules) {
                case .none:
                    continue
                case .exit:
                    exits.insert(window.windowID)
                case let .meeting(code, name):
                    // The same window, its code gone from the title ("Meet –
                    // Point hebdo" after "Meet – Point hebdo – abc-defg-hij"):
                    // still that meeting, never a new one to offer.
                    // Only under the name it had: another title in that
                    // window (another tab, another page) is not that meeting.
                    var identity = Self.identity(provider, window: window, code: code)
                    var adopted = false
                    if code == nil, let name, let same = tracks.values.first(where: {
                        $0.provider == provider && $0.windowID == window.windowID && $0.meetCode != nil
                            && $0.titleName == name
                    }) {
                        identity = same.identity
                    } else if code != nil, tracks[identity] == nil, let same = tracks.values.first(where: {
                        $0.provider == provider && $0.windowID == window.windowID && $0.meetCode == nil && $0.bornAt != nil
                    }) {
                        // And the other way: "Meet – Point hebdo – abc-defg-hij"
                        // after "Meet – Point hebdo", the meeting already
                        // born, is that meeting, its code left aside.
                        identity = same.identity
                        adopted = true
                    }
                    // Two windows of one meeting: the one on screen, else the
                    // one already followed.
                    if let other = sightings[identity] {
                        let followed = tracks[identity]?.windowID
                        let better = (window.onScreen && !other.window.onScreen)
                            || (window.onScreen == other.window.onScreen && window.windowID == followed)
                        guard better else { continue }
                    }
                    sightings[identity] = Sighting(provider: provider, window: window, code: adopted ? nil : code,
                                                   name: name)
                }
                break
            }
        }

        for (identity, sighting) in sightings {
            var track = tracks[identity] ?? newTrack(identity, provider: sighting.provider,
                                                     family: sighting.provider.family(of: sighting.window.bundle),
                                                     pid: sighting.window.pid)
            if !track.windowSeen || track.firstWindowAt == nil {
                track.windowReadings = 0
                track.firstWindowAt = now
            }
            track.windowReadings += 1
            track.windowSeen = true
            track.pid = track.provider.kind == .web ? sighting.window.pid : track.pid
            track.windowID = sighting.window.windowID
            track.windowBundle = sighting.window.bundle
            track.titleName = sighting.name ?? track.titleName
            track.meetCode = sighting.code ?? track.meetCode
            // The browser's microphone run it is seen with now.
            if track.provider.kind == .web, let run = microphoneSince[track.family] { track.microphoneRun = run }
            tracks[identity] = track
        }

        var ended: [ForkMeetingIdentity] = []
        for (identity, var track) in tracks where sightings[identity] == nil {
            // Its window says the call is over and its microphone is free:
            // it ends now, or at the first reading the page still shows once
            // the microphone is. With the microphone still open (another tab
            // may be in its own call), the 20 s decide, as for any meeting
            // out of sight.
            track.windowSeen = false
            if let windowID = track.windowID, exits.contains(windowID), !microphoneOpen(track) {
                tracks[identity] = nil
                if track.bornAt != nil { ended.append(identity) }
                continue
            }
            // Not born yet, and its title is gone: the agreement starts over.
            if track.bornAt == nil, track.provider.kind == .web {
                tracks[identity] = nil
                continue
            }
            tracks[identity] = track
        }
        return ended
    }

    private func newTrack(_ identity: ForkMeetingIdentity, provider: ForkMeetingProvider, family: String,
                          pid: Int32) -> Track {
        Track(identity: identity, provider: provider, family: family, pid: pid)
    }

    /// Screen Recording went away: every meeting in a browser goes, those
    /// born said as ended.
    private mutating func forgetWebMeetings() -> [ForkMeetingIdentity] {
        var ended: [ForkMeetingIdentity] = []
        for (identity, track) in tracks where track.provider.kind == .web {
            tracks[identity] = nil
            if track.bornAt != nil { ended.append(identity) }
        }
        return ended
    }

    static func identity(_ provider: ForkMeetingProvider, window: ForkMeetingWindowSignal,
                         code: String?) -> ForkMeetingIdentity {
        switch provider.identity {
        case .codeOrWindow:
            if let code { return ForkMeetingIdentity("\(provider.id):\(code)") }
            return ForkMeetingIdentity("\(provider.id):\(window.pid):\(ForkMeetingTitleRules.cleaned(window.title))")
        case .appProcess:
            return ForkMeetingIdentity("\(provider.id):\(window.pid)")
        }
    }

    // MARK: - Life

    /// Births, lives and probable ends, at `now`. The births first, so a
    /// meeting born now already takes its browser's microphone from an
    /// older one.
    private mutating func live(at now: Date) -> [ForkMeetingIdentity] {
        for (identity, var track) in tracks where track.bornAt == nil {
            guard track.windowSeen || microphoneOpen(track) else {
                // Never born: its set-aside, if any, runs on from its last end.
                tracks[identity] = nil
                continue
            }
            guard isBorn(track, at: now) else { continue }
            track.bornAt = now
            // Back before its set-aside ran out: it stays aside, until its next end.
            if silenced.keys.contains(identity) { silenced[identity] = .some(nil) }
            tracks[identity] = track
        }
        var ended: [ForkMeetingIdentity] = []
        for (identity, var track) in tracks where track.bornAt != nil {
            let alive = track.windowSeen || keepsAlive(track)
            if alive {
                track.absentSince = nil
            } else {
                let since = track.absentSince ?? now
                track.absentSince = since
                if now.timeIntervalSince(since) >= tuning.endAfter {
                    tracks[identity] = nil
                    ended.append(identity)
                    continue
                }
            }
            tracks[identity] = track
        }
        return ended
    }

    private func isBorn(_ track: Track, at now: Date) -> Bool {
        func agreed(_ readings: Int, since first: Date?) -> Bool {
            guard readings >= tuning.entryReadings, let first else { return false }
            return now.timeIntervalSince(first) >= tuning.entrySpan
        }
        let titlesAgree = agreed(track.windowReadings, since: track.firstWindowAt)
        switch track.provider.kind {
        case .web:
            let settled = microphoneSettled(track, at: now)
            // "Meet – x" without a code: any page may be called so.
            guard track.meetCode != nil else { return titlesAgree && settled }
            return titlesAgree || (track.windowSeen && settled)
        case .app:
            return titlesAgree || agreed(track.microphoneReadings, since: track.firstMicrophoneAt)
        }
    }

    /// A web meeting's browser, or an app meeting's own process, records
    /// from a microphone now.
    private func microphoneOpen(_ track: Track) -> Bool {
        switch track.provider.kind {
        case .web:
            return microphoneSince[track.family] != nil
        case .app:
            return microphones.contains { track.provider.owns($0) && ($0.appPID ?? $0.pid) == track.pid }
        }
    }

    /// …and has for a second at least.
    private func microphoneSettled(_ track: Track, at now: Date) -> Bool {
        let since: Date?
        switch track.provider.kind {
        case .web: since = microphoneSince[track.family]
        case .app: since = microphoneOpen(track) ? track.firstMicrophoneAt : nil
        }
        guard let since else { return false }
        return now.timeIntervalSince(since) >= tuning.microphoneSettle
    }

    /// A web meeting out of sight lives on its browser's microphone, unless
    /// another meeting of that browser shows with its code and the
    /// microphone opened again since this one was last shown with it: the
    /// run is the newer call's. A title without a code, which any page may
    /// carry, or another Meet's waiting room on the same run never takes it.
    /// An app's lives on its own process's.
    private func keepsAlive(_ track: Track) -> Bool {
        guard microphoneOpen(track) else { return false }
        guard track.provider.kind == .web, let run = microphoneSince[track.family] else { return true }
        if let held = track.microphoneRun, run <= held { return true }
        return !tracks.values.contains {
            $0.identity != track.identity && $0.family == track.family && $0.bornAt != nil && $0.windowSeen
                && $0.meetCode != nil
        }
    }

    private func onMicrophone(at now: Date) -> Set<ForkMeetingIdentity> {
        Set(tracks.values.filter { $0.bornAt != nil && microphoneSettled($0, at: now) }.map(\.identity))
    }

    // MARK: - Candidates

    private func candidates() -> [ForkMeetingCandidate] {
        let born = tracks.values.compactMap { track -> ForkMeetingCandidate? in
            guard let bornAt = track.bornAt else { return nil }
            let policy = policies.policy(for: track.provider)
            guard policy != .never else { return nil }
            let hint = track.meetCode.flatMap { code in calendar.first { $0.meetCode == code } }
            return ForkMeetingCandidate(
                identity: track.identity, provider: track.provider.id, providerName: track.provider.name,
                providerShortName: track.provider.shortName, titleName: track.titleName, meetCode: track.meetCode,
                calendarTitle: hint?.title, appBundle: track.family, pid: track.pid,
                windowID: track.windowID, windowBundle: track.windowBundle, defaultSound: track.provider.defaultSound,
                policy: policy, silenced: silenced.keys.contains(track.identity), bornAt: bornAt)
        }
        return born.sorted { $0.bornAt != $1.bornAt ? $0.bornAt > $1.bornAt : $0.identity.value < $1.identity.value }
    }
}
