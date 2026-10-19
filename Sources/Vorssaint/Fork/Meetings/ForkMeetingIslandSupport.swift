// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What says that a meeting is being recorded, as `fork.meetings.indicator`
/// keeps it: the island's closed strip, the pill, or both.
///
/// The Meetings page shows it as "Show in the closed island" (`showsStrip`)
/// and, while that is on, whether the pill stays (`both`) or steps aside
/// while the island shows the recording (`auto`).
enum ForkMeetingIndicator: String, CaseIterable {
    /// The strip in the closed island; the pill only where the island does
    /// not show it: another display, hidden, in full screen, another
    /// activity chosen.
    case auto
    /// The pill alone: the closed island shows no strip.
    case pill
    /// The strip and the pill, always.
    case both

    static let fallback = ForkMeetingIndicator.auto

    /// Anything unknown reads as the default.
    init(stored: String?) {
        self = stored.flatMap(ForkMeetingIndicator.init(rawValue:)) ?? .fallback
    }

    /// "Show in the closed island".
    var showsStrip: Bool { self != .pill }
}

/// A recording as the island draws it, read from the pill's state: what
/// stands left of the camera, and how the time right of it reads.
enum ForkMeetingIslandPhase: Equatable {
    case recording(diskLow: Bool)
    case paused(diskLow: Bool)
    /// The file is closing.
    case stopping
    /// The final pass runs: its share done, when known.
    case finalizing(progress: Double?)

    /// What stands left of the camera. The strip swaps one for the next
    /// through a blur, so it changes only with the meaning, never with a
    /// gauge's progress.
    enum Mark: Equatable {
        /// The red dot, breathing unless motion is reduced.
        case dot
        /// The orange pause bars.
        case pause
        /// The disk running low, in orange: the recording goes on.
        case disk
        /// A small gauge: the file closing, then the final pass.
        case gauge
    }

    /// Nil while there is no recording to show.
    init?(state: ForkMeetingPillState, progress: Double?) {
        switch state {
        case .hidden: return nil
        case let .recording(_, diskMinutesLeft): self = .recording(diskLow: diskMinutesLeft != nil)
        case let .paused(_, _, diskMinutesLeft): self = .paused(diskLow: diskMinutesLeft != nil)
        case .stopping: self = .stopping
        case .finalizing: self = .finalizing(progress: progress.map { $0.isFinite ? min(1, max(0, $0)) : 0 })
        }
    }

    var mark: Mark {
        switch self {
        case .recording(diskLow: false): return .dot
        case .recording(diskLow: true): return .disk
        case .paused: return .pause
        case .stopping, .finalizing: return .gauge
        }
    }

    /// The time moves only while recording; paused, it stands still in
    /// orange, and once stopped it keeps the length recorded.
    var clockRuns: Bool {
        if case .recording = self { return true }
        return false
    }

    /// Orange: paused, or short of disk.
    var clockIsAlert: Bool {
        switch self {
        case let .recording(diskLow): return diskLow
        case .paused: return true
        case .stopping, .finalizing: return false
        }
    }

    /// The two meters follow the voices only while they are recorded.
    var showsLevels: Bool { clockRuns }

    /// Pause or resume, mark and stop: none once the recording stops.
    var acceptsControls: Bool {
        switch self {
        case .recording, .paused: return true
        case .stopping, .finalizing: return false
        }
    }

    /// A moment can be marked while the meeting is recorded, not paused.
    var canMark: Bool { clockRuns }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    /// The gauge's share, `nil` while unknown or not finishing.
    var progress: Double? {
        if case let .finalizing(progress) = self { return progress }
        return nil
    }
}

/// The island's rules for a recording, kept apart from the views so each
/// is tested.
enum ForkMeetingIslandRules {
    /// The closed island lists the recording among its live activities:
    /// the feature on, the strip wanted, and a recording to show, from its
    /// start until its file is finished.
    static func showsStrip(enabled: Bool, indicator: ForkMeetingIndicator, state: ForkMeetingPillState) -> Bool {
        enabled && indicator.showsStrip && state != .hidden
    }

    /// The pill steps aside only with `auto`, while the island shows the
    /// recording where it is filmed, and only for what the strip says too:
    /// the countdown of a meeting that seems over, the minutes of disk left,
    /// a frozen picture or a filmed app gone are the pill's words alone, so
    /// it comes back for them.
    static func hidesPill(indicator: ForkMeetingIndicator, islandShowsRecording: Bool,
                          look: ForkMeetingPillLook?) -> Bool {
        guard indicator == .auto, islandShowsRecording, let look else { return false }
        switch look.status {
        case .meters, .paused, .stopping, .finalizing: return true
        case .diskLow, .pictureFrozen, .sourceGone, .endingSoon: return false
        }
    }

    /// The time right of the camera, as the pill reads it: "12:03",
    /// "1:02:03". Only the part above the seconds rolls in the closed
    /// island (`NotchRollingDigits`).
    static func clock(_ elapsed: TimeInterval) -> String {
        ForkMeetingPillLayout.clock(elapsed)
    }

    /// "12 min, 3 sec", "12 min 3 s": the time recorded as VoiceOver says
    /// it, in the app's language. Under a minute, the seconds alone; from
    /// the hour, hours and minutes.
    static func spokenDuration(_ elapsed: TimeInterval, language: AppLanguage) -> String {
        let seconds = elapsed.isFinite ? max(0, Int(elapsed)) : 0
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.formattingLocale()
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        formatter.zeroFormattingBehavior = .dropAll
        let spoken = formatter.string(from: TimeInterval(seconds)) ?? ""
        return spoken.isEmpty ? (formatter.string(from: 0) ?? "0") : spoken
    }

    /// What VoiceOver says of the strip after its name: "12 min, 3 sec",
    /// "12 min, 3 sec, paused", "Finishing… 42%".
    static func value(phase: ForkMeetingIslandPhase, elapsed: TimeInterval, language: AppLanguage,
                      strings: ForkMeetingStrings) -> String {
        let time = spokenDuration(elapsed, language: language)
        switch phase {
        case .recording: return time
        case .paused: return strings.islandValuePaused(time)
        case .stopping: return strings.pillStopping
        case let .finalizing(progress):
            guard let progress else { return strings.pillFinalizing }
            return strings.pillFinalizing + " " + percent(progress, language: language)
        }
    }

    /// "42%", "42 %": in the app's language.
    static func percent(_ share: Double, language: AppLanguage) -> String {
        let share = share.isFinite ? min(1, max(0, share)) : 0
        return share.formatted(.percent.precision(.fractionLength(0)).locale(language.formattingLocale()))
    }

    /// How long a "Marked" stays on the card's button after a click.
    static let markedHold: TimeInterval = 1.6
    /// How long the live card stays once the pointer leaves it.
    static let cardHold: TimeInterval = 4
}
