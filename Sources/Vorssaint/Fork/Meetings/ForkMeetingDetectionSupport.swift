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
        case .offering, .endingSoon: return true
        case let .recording(session), let .paused(session, _): return session.undoUntil != nil
        case .idle, .starting, .stopping: return false
        }
    }

    /// Where the name a recording starts with came from: the meeting's
    /// window title, its calendar event, or its provider and code ("Google
    /// Meet · abc-defg-hij"); a name given otherwise is the person's.
    static func titleSource(title: String?, meeting: ForkMeetingCandidate?) -> ForkMeetingSidecar.TitleSource? {
        guard let title else { return nil }
        guard let meeting, title == meeting.name else { return .user }
        if let name = meeting.titleName, !name.isEmpty { return .window }
        if let name = meeting.calendarTitle, !name.isEmpty { return .calendar }
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

    /// What the offer records, "Chrome window · Chrome sound · AirPods mic":
    /// the sound's app, or the whole Mac; a sound or a microphone turned off
    /// leaves its part out. The three parts are always apart with " · ".
    static func offerCapture(window: String, sound: String?, microphone: String?,
                             strings: ForkMeetingStrings) -> String {
        let parts = strings.offerCapture(window: window, sound: sound ?? "", microphone: microphone ?? "")
            .components(separatedBy: " · ")
        guard parts.count == 3 else { return parts.joined(separator: " · ") }
        let kept = [parts[0], sound == nil ? nil : parts[1], microphone == nil ? nil : parts[2]]
        return kept.compactMap { $0 }.joined(separator: " · ")
    }

    /// How long a reading of the free space is trusted for an offer: the
    /// disk is watched every 15 s once a meeting records.
    static let freeSpaceLifetime: TimeInterval = 15

    static func freeSpaceIsStale(readAt: Date?, now: Date) -> Bool {
        guard let readAt else { return true }
        return now.timeIntervalSince(readAt) >= freeSpaceLifetime || now < readAt
    }
}
