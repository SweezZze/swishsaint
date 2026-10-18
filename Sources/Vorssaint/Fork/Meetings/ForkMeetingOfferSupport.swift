// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Where an offer shows: open in the island or the bubble, or folded into
/// its small grey reminder, which stays while the meeting lives.
enum ForkMeetingOfferSurface: Equatable {
    case island
    case bubble
    case reminder

    /// Folded, it is the reminder. Open, the island when it is free and has
    /// not turned this offer away yet (refused, taken back, collapsed by a
    /// click): once it has, the bubble keeps the offer, no back and forth.
    static func choose(folded: Bool, islandAvailable: Bool, islandTurnedAway: Bool) -> ForkMeetingOfferSurface {
        if folded { return .reminder }
        return islandAvailable && !islandTurnedAway ? .island : .bubble
    }
}

/// When an open offer folds. The machine folds it 20 s after it opened;
/// the pointer resting on it holds the fold until it leaves, then a short
/// grace lets a click that was on its way land. An offer opened again from
/// its reminder folds on its own 20 s later, that time counted again in
/// full once the pointer leaves, as the bubble's cards do.
struct ForkMeetingOfferFold: Equatable {
    /// After the pointer leaves an offer the machine already folded.
    static let grace: TimeInterval = 2
    /// An offer opened again from its reminder stays this long.
    static let reopenedHold: TimeInterval = ForkMeetingMachine.offerCollapse

    /// When the offer folds; `nil` while nothing is due (the machine has
    /// not folded it yet, or the pointer rests on it).
    private(set) var due: Date?
    private(set) var hovering = false
    /// The machine folded it while the pointer was on it.
    private(set) var asked = false
    /// Opened again from its reminder: it folds on its own.
    private(set) var reopened = false

    /// The machine opened it: the machine says when it folds.
    static func opened() -> ForkMeetingOfferFold { ForkMeetingOfferFold() }

    /// The person clicked its reminder.
    static func reopened(at now: Date) -> ForkMeetingOfferFold {
        var fold = ForkMeetingOfferFold()
        fold.reopened = true
        fold.due = now.addingTimeInterval(reopenedHold)
        return fold
    }

    /// The machine's `collapseOffer`: now, unless the pointer is on it.
    mutating func ask(at now: Date) {
        asked = true
        due = hovering ? nil : now
    }

    mutating func hover(_ inside: Bool, at now: Date) {
        guard inside != hovering else { return }
        hovering = inside
        if inside {
            due = nil
        } else if asked {
            due = now.addingTimeInterval(Self.grace)
        } else if reopened {
            due = now.addingTimeInterval(Self.reopenedHold)
        }
    }

    func isDue(at now: Date) -> Bool {
        guard let due, !hovering else { return false }
        return now >= due
    }
}

/// Countdowns the offer's surfaces show: "Cancel (4 s)", "Stopping in 12 s".
enum ForkMeetingOfferTiming {
    /// Whole seconds left before `until`, rounded up: 12.2 s left reads 13,
    /// so a countdown never says 0 while there is still time to act, and
    /// reads 0 once it is over.
    static func secondsLeft(until: Date, now: Date) -> Int {
        let left = until.timeIntervalSince(now)
        guard left.isFinite, left > 0 else { return 0 }
        return Int(left.rounded(.up))
    }

    /// A start for a once-a-second timeline whose ticks fall when the
    /// number of seconds left changes, not up to a second after it: in the
    /// past, a whole number of seconds before `until`.
    static func tickStart(until: Date, now: Date) -> Date {
        until.addingTimeInterval(-Double(secondsLeft(until: until, now: now) + 1))
    }
}

/// What the microphone line of an offer says.
enum ForkMeetingOfferMicrophone: Equatable {
    case named(String)
    /// Off on the Meetings page.
    case off
    /// macOS does not allow it: the meeting would record without it.
    case denied
}

/// The offer's words, put together from the meeting and the settings.
enum ForkMeetingOfferText {
    /// The sound a start of this meeting records: a provider whose calls
    /// play from a system process (FaceTime) is heard from the whole Mac
    /// when the app's sound is asked, as its start does.
    static func sound(setting: ForkMeetingSystemAudio, providerDefault: ForkMeetingSystemAudio) -> ForkMeetingSystemAudio {
        setting == .app && providerDefault == .all ? .all : setting
    }

    /// "Window: Chrome · sound: Chrome · mic: AirPods", label then value, so
    /// no language has to put an article or a case before a name it does
    /// not know ("Fenêtre de Arc"). A meeting without a window to film, or
    /// with the display chosen, films the whole screen.
    static func capture(target: ForkMeetingCaptureTarget, windowApp: String?, hasWindow: Bool,
                        sound: ForkMeetingSystemAudio, soundApp: String?, microphone: ForkMeetingOfferMicrophone,
                        strings s: ForkMeetingStrings) -> String {
        let soundValue: String
        switch sound {
        case .app: soundValue = named(soundApp) ?? named(windowApp) ?? s.offerNone
        case .all: soundValue = s.offerWholeMac
        case .off: soundValue = s.offerNone
        }
        let micValue: String
        switch microphone {
        case let .named(name): micValue = named(name) ?? s.offerNone
        case .off: micValue = s.offerNone
        case .denied: micValue = s.offerMicrophoneDenied
        }
        let line: String
        if target == .window, hasWindow, let window = named(windowApp) {
            line = s.offerCapture(window: unbroken(window), sound: unbroken(soundValue), microphone: unbroken(micValue))
        } else {
            line = s.offerCaptureDisplay(sound: unbroken(soundValue), microphone: unbroken(micValue))
        }
        // A label stays with its value: the line wraps between its parts.
        // Chinese and Japanese break between any two characters, so their
        // labels are joined up to the value too.
        return line.replacingOccurrences(of: ": ", with: ":\u{00A0}")
            .components(separatedBy: " · ").map(joinedLabel).joined(separator: " · ")
    }

    /// "マイク：AirPods" with word joiners through "マイク：", where a line
    /// could otherwise break.
    private static func joinedLabel(_ part: String) -> String {
        guard let colon = part.firstIndex(of: "：") else { return part }
        let label = part[...colon].map(String.init).joined(separator: "\u{2060}")
        return label + "\u{2060}" + part[part.index(after: colon)...]
    }

    /// A short name kept on one line ("AirPods de Martial"); a long one may
    /// still wrap rather than overflow.
    private static func unbroken(_ value: String) -> String {
        value.count <= 24 ? value.replacingOccurrences(of: " ", with: "\u{00A0}") : value
    }

    /// The line under the name: the service and the meeting's code
    /// ("Google Meet · abc-defg-hij"). Nothing when the name says them
    /// already: a meeting named after its service and code, or its service
    /// alone.
    static func subtitle(_ candidate: ForkMeetingCandidate) -> String? {
        let name = candidate.name
        var parts: [String] = []
        if !name.contains(candidate.providerName) { parts.append(candidate.providerName) }
        if let code = candidate.meetCode, !code.isEmpty, !name.contains(code) {
            if parts.isEmpty { parts.append(candidate.providerName) }
            parts.append(code)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Why a greyed offer cannot record now, in a few words.
    static func blocked(_ failure: ForkMeetingFailure, strings s: ForkMeetingStrings) -> String {
        failure == .officialRecorderBusy ? s.offerRecorderBusy : failure.summary(s)
    }

    /// The folded offer's words: the provider's short name ("Meet").
    static func reminderTitle(_ candidate: ForkMeetingCandidate) -> String {
        candidate.providerShortName.isEmpty ? candidate.providerName : candidate.providerShortName
    }

    /// "Meeting over? Stopping in 12 s", as the pill shows it.
    static func endingSoon(until: Date, now: Date, strings s: ForkMeetingStrings) -> String {
        s.endingSoonTitle + " " + s.endingSoon(seconds: ForkMeetingOfferTiming.secondsLeft(until: until, now: now))
    }

    /// "Cancel (4 s)".
    static func undo(until: Date, now: Date, strings s: ForkMeetingStrings) -> String {
        s.undo(seconds: ForkMeetingOfferTiming.secondsLeft(until: until, now: now))
    }

    private static func named(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
