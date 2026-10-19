// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The events whose word the Meetings page can silence, one switch each. A
/// switch covers the notice in the island or the bubble and the system
/// notification alike; VoiceOver still hears every step, and the pill still
/// shows what a recording does.
///
/// A failure is never one of them: each one stops a recording, refuses one
/// that was asked for (by a click, a shortcut or "Always"), or records it
/// without a part of it, and being told is the only way not to lose a
/// meeting without knowing. Nor is the meeting's sound lost for the rest of
/// a recording, nor the word that answers a click (Never, Always, Cancel,
/// the announcement copied): that one is the click's, not an event's.
enum ForkMeetingNotifyEvent: CaseIterable, Equatable {
    /// The offer when a call is detected, and its grey reminder.
    case offers
    /// "Recording started", and "Recording resumed" after a pause.
    case start
    /// The saved meeting, and the one recovered after the app quit.
    case saved
    /// The warnings during a recording: the disk getting full, the
    /// microphone silent or changed, the window closed, the display changed.
    case warnings
    /// A transcript ready or failed, an automatic export that failed.
    case results

    var key: String {
        switch self {
        case .offers: return ForkDefaultsKey.meetingsNotifyOffers
        case .start: return ForkDefaultsKey.meetingsNotifyStart
        case .saved: return ForkDefaultsKey.meetingsNotifySaved
        case .warnings: return ForkDefaultsKey.meetingsNotifyWarnings
        case .results: return ForkDefaultsKey.meetingsNotifyResults
        }
    }

    /// The event a notice belongs to; `nil` for one always shown.
    static func event(of notice: ForkMeetingNotice) -> ForkMeetingNotifyEvent? {
        switch notice {
        case .started, .resumed: return .start
        case .saved, .recovered: return .saved
        case .microphone, .microphoneSilent, .diskLow, .displayChanged, .sourceGone: return .warnings
        case .failure, .soundLost, .neverOffered, .neverOfferedWebCalls, .alwaysChosen, .discarded,
             .announcementCopied, .askedAgain:
            return nil
        }
    }

    /// On unless the person turned it off: a setting never written (a
    /// harness's own defaults) leaves every word on.
    static func isOn(_ event: ForkMeetingNotifyEvent, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: event.key) as? Bool ?? true
    }

    static func shows(_ notice: ForkMeetingNotice,
                      isOn: (ForkMeetingNotifyEvent) -> Bool = { ForkMeetingNotifyEvent.isOn($0) }) -> Bool {
        event(of: notice).map(isOn) ?? true
    }

    /// The start's card also carries the reminder to tell the participants
    /// (a setting of its own) and the warning that no app's sound is heard,
    /// a meeting recorded without its other voices: either keeps the card
    /// when the start's own word is off.
    static func showsStart(_ notice: ForkMeetingNotice, remindsConsent: Bool, noAppSound: Bool,
                           isOn: (ForkMeetingNotifyEvent) -> Bool = { ForkMeetingNotifyEvent.isOn($0) }) -> Bool {
        remindsConsent || noAppSound || shows(notice, isOn: isOn)
    }
}
