// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The detection's small decisions in the service, kept apart so each is
/// tested: when it runs, when its clock ticks, which input is the meeting's
/// microphone, when the free space is read again.
enum ForkMeetingDetectionSupport {
    /// The windows and the microphones are read only while the feature is
    /// on and its first-use sheet confirmed: nothing runs before, nothing
    /// after it is turned off, nothing while the app quits.
    static func runs(wanted: Bool, consentAcknowledged: Bool, terminating: Bool) -> Bool {
        wanted && consentAcknowledged && !terminating
    }

    /// The one-second clock runs only while time decides something: an offer
    /// folds, a countdown ends, or "Cancel" of a start "Always" made expires.
    static func clockRuns(phase: ForkMeetingMachine.Phase) -> Bool {
        switch phase {
        // A folded offer waits for nothing but the person.
        case let .offering(offer): return !offer.collapsed
        case .endingSoon: return true
        case let .recording(session), let .paused(session, _): return session.undoUntil != nil
        case .idle, .starting, .stopping: return false
        }
    }

    /// The page's choices for this meeting: "the meeting app's sound" means
    /// the whole Mac for a provider whose calls no app's sound carries
    /// (`defaultSound == .all`, FaceTime). Anything else as chosen.
    static func settings(_ settings: ForkMeetingCaptureSettings,
                         for meeting: ForkMeetingCandidate?) -> ForkMeetingCaptureSettings {
        guard settings.systemAudio == .app, meeting?.defaultSound == .all else { return settings }
        var adjusted = settings
        adjusted.systemAudio = .all
        return adjusted
    }

    /// Where the name a recording starts with came from: the meeting's
    /// window title, its calendar event, or its provider and code ("Google
    /// Meet · abc-defg-hij"); a name given otherwise is the person's.
    static func titleSource(title: String?, meeting: ForkMeetingCandidate?) -> ForkMeetingSidecar.TitleSource? {
        guard let title else { return nil }
        guard let meeting, title == meeting.name else { return .user }
        if let name = meeting.titleName, !ForkMeetingTitleRules.displayName(name).isEmpty { return .window }
        if let name = meeting.calendarTitle, !ForkMeetingTitleRules.displayName(name).isEmpty { return .calendar }
        return .provider
    }

    /// "Meeting microphone (auto)": the input the meeting's app records
    /// from, its audio helper's included (Chrome's microphone is its
    /// AudioService's), the app itself first; `nil` when it records none, and
    /// the system's input is used.
    static func meetingInput(for meeting: ForkMeetingCandidate?, in microphones: [ForkMeetingMicSignal]) -> String? {
        guard let meeting else { return nil }
        let own = microphones.filter { $0.appBundle == meeting.appBundle && $0.inputDevice != nil }
        let best = own.first { $0.appPID == meeting.pid || $0.pid == meeting.pid } ?? own.first
        return best?.inputDevice
    }

    /// How long a reading of the free space is trusted for an offer: the
    /// disk is watched every 15 s once a meeting records.
    static let freeSpaceLifetime: TimeInterval = 15

    static func freeSpaceIsStale(readAt: Date?, now: Date) -> Bool {
        guard let readAt else { return true }
        return now.timeIntervalSince(readAt) >= freeSpaceLifetime || now < readAt
    }

    // MARK: Fixes H1

    /// The free space is read again this long after the last reading, so a
    /// new one is in before the old one is too old to use.
    static let freeSpaceRefresh: TimeInterval = 10
    /// A reading that has not come back after this long is given up (a
    /// volume that hangs), and another one asked.
    static let freeSpaceTimeout: TimeInterval = 15

    /// The free space an offer or "Always" is asked with: `nil`, which greys
    /// the offer ("folder unavailable"), once the last reading is too old.
    static func freeSpace(_ bytes: Int64?, readAt: Date?, now: Date) -> Int64? {
        freeSpaceIsStale(readAt: readAt, now: now) ? nil : bytes
    }

    /// Whether to ask a new reading now: none under way and the last one is
    /// 10 s old, or the one under way has hung for 15 s.
    static func freeSpaceNeedsReading(readAt: Date?, askedAt: Date?, now: Date) -> Bool {
        if let askedAt {
            return now.timeIntervalSince(askedAt) >= freeSpaceTimeout || now < askedAt
        }
        guard let readAt else { return true }
        return now.timeIntervalSince(readAt) >= freeSpaceRefresh || now < readAt
    }

    // MARK: Fixes J

    /// The page warns that a page copying a Meet title could be taken for a
    /// meeting only while Meet's meetings may be offered or recorded.
    static func warnsOfLookalikes(_ policy: ForkMeetingPolicy) -> Bool {
        policy != .never
    }
}
