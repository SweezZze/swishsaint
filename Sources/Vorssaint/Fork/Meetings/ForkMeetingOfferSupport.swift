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

/// Which of the detection's cards the island holds: the offer, "Recording
/// started · Cancel (5 s)", "Meeting over? Stopping in 12 s".
enum ForkMeetingIslandCard: Equatable {
    case offer
    case undo
    case endingSoon

    /// What becomes of a card the island closed over (a click on the
    /// island, a lock, the official capture controls).
    enum AfterClose: Equatable {
        /// The offer folds into its reminder: not a "Not Now".
        case fold
        /// "Cancel" goes on in the bubble while its seconds run.
        case bubble
        /// Nothing to keep: the pill holds the countdown, and "Cancel" is
        /// over.
        case gone
    }

    func afterClose(undoUntil: Date?, now: Date) -> AfterClose {
        switch self {
        case .offer: return .fold
        case .undo: return undoUntil.map { now < $0 } == true ? .bubble : .gone
        case .endingSoon: return .gone
        }
    }

    /// Our card already up in the island is changed there, in place. The
    /// island is open on it, so it is not "available" (free to be opened
    /// for a card) any more.
    static func islandTakes(available: Bool, showingThisCard: Bool) -> Bool {
        available || showingThisCard
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

    /// The pill's stop cancels, as "Cancel" does, while "Cancel" runs.
    static func pillStopCancels(undoUntil: Date?, now: Date) -> Bool {
        undoUntil.map { now < $0 } == true
    }

    /// A start for a once-a-second timeline whose ticks fall when the
    /// number of seconds left changes, not up to a second after it: in the
    /// past, a whole number of seconds before `until`.
    static func tickStart(until: Date, now: Date) -> Date {
        until.addingTimeInterval(-Double(secondsLeft(until: until, now: now) + 1))
    }
}

/// What became of a cancelled recording's folder, as its notice and
/// VoiceOver say it: never "deleted" when it was not.
enum ForkMeetingDiscardOutcome: Equatable {
    case trashed
    /// It could not go to the Trash (a volume without one): deleted.
    case deleted
    /// Neither: it stays in the meetings' folder.
    case kept

    /// To the Trash, else deleted, else kept.
    static func discard(trash: () throws -> Void, remove: () throws -> Void) -> ForkMeetingDiscardOutcome {
        do {
            try trash()
            return .trashed
        } catch {
            do {
                try remove()
                return .deleted
            } catch {
                return .kept
            }
        }
    }

    func spoken(_ s: ForkMeetingStrings) -> String {
        switch self {
        case .trashed: return s.voiceDiscarded
        case .deleted: return s.voiceDiscardedDeleted
        case .kept: return s.voiceDiscardKept
        }
    }

    // MARK: Fixes J

    /// Said once the folder is gone, "Recording cancelled." having been said
    /// at the click: the outcome without that first sentence when it starts
    /// with it, then, when "Cancel" took back the "Always" chosen for
    /// `askedAgain` (its short name), that its meetings are offered again.
    func spokenAfterCancel(askedAgain: String?, strings s: ForkMeetingStrings) -> String {
        let full = spoken(s)
        var outcome = full
        if full.hasPrefix(s.voiceCancelled) {
            let rest = full.dropFirst(s.voiceCancelled.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { outcome = rest }
        }
        guard let askedAgain else { return outcome }
        return ForkMeetingLiveText.sentences(outcome, s.voiceAskAgain(askedAgain))
    }

    /// The notice's second line: the folder still there comes first, else
    /// the provider offered again, else none.
    func detail(askedAgain: String?, strings s: ForkMeetingStrings) -> String? {
        if self == .kept { return s.noticeDiscardKeptDetail }
        return askedAgain.map(s.noticeAskAgain)
    }
}

/// VoiceOver's last sentence: the same one twice in a row is said once.
/// It is forgotten when what it spoke of goes away (the offer, the
/// countdown, the recording's pill), so the next offer or countdown is said
/// in full, even in the same words.
struct ForkMeetingSpoken: Equatable {
    private(set) var last: String?

    /// Whether `message` is to be said now; it becomes the last one.
    mutating func says(_ message: String) -> Bool {
        guard !message.isEmpty, message != last else { return false }
        last = message
        return true
    }

    mutating func forget() {
        last = nil
    }

    static func forgets(after effect: ForkMeetingMachine.Effect) -> Bool {
        switch effect {
        case .hideOffer, .hideEndingSoon, .showPill(.hidden): return true
        default: return false
        }
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

/// The input an offer names for the Meetings page's microphone: the one
/// its start would record.
enum ForkMeetingOfferInput: Equatable {
    case off
    case system
    case builtIn
    /// Chosen on the page, by its unique ID.
    case chosen(String)
    /// "Meeting microphone (auto)": the input the meeting's app records
    /// from, by its unique ID, as the start asks the recorder for it.
    case meetingApp(String)

    /// "Automatic" names the meeting app's own input when the app records
    /// one, else the system's, as its start does.
    static func of(_ choice: ForkMeetingMicrophoneChoice, meetingInput: String?) -> ForkMeetingOfferInput {
        switch choice {
        case .meeting:
            guard let meetingInput, !meetingInput.isEmpty else { return .system }
            return .meetingApp(meetingInput)
        case .system: return .system
        case .builtIn: return .builtIn
        case let .device(uid): return .chosen(uid)
        case .off: return .off
        }
    }
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
    /// with the display chosen, films the whole screen; a call filmed in its
    /// app's main window says so ("Window: Teams (main window)").
    static func capture(target: ForkMeetingCaptureTarget, windowApp: String?, hasWindow: Bool,
                        mainWindow: Bool = false, sound: ForkMeetingSystemAudio, soundApp: String?,
                        microphone: ForkMeetingOfferMicrophone, strings s: ForkMeetingStrings) -> String {
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
        if target == .window, hasWindow, let app = named(windowApp) {
            let window = mainWindow ? s.offerMainWindow(app) : app
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

    /// A short name kept on one line ("AirPods d’Alice"); a long one may
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

    /// The card's title and the line under it. Where someone else's screen
    /// share would see the card (the island, while the official "Show in
    /// screenshots and videos" is on), it names the service alone and says
    /// why: the meeting's name and code stay in the bubble, which no share
    /// shows, and with VoiceOver.
    static func heading(_ candidate: ForkMeetingCandidate, seenInShares: Bool,
                        strings s: ForkMeetingStrings) -> (title: String, subtitle: String?) {
        guard seenInShares else { return (candidate.name, subtitle(candidate)) }
        return (candidate.providerName, s.offerNameHidden)
    }

    /// "Always for Zoom" is in the menu only for a meeting it could start on
    /// its own one day: never for the other web calls (Whereby, Jitsi…),
    /// which nothing tells from a page that copies their title, nor for
    /// FaceTime, which an iPhone call relayed looks like, nor on a Mac that
    /// cannot say which app uses the microphone (before macOS 14.4), where
    /// "Always" never starts anything.
    static func showsAlways(_ offer: ForkMeetingOffer, microphoneSignal: Bool) -> Bool {
        offer.candidate.alwaysProof != .none && microphoneSignal
    }

    /// "Always for Meet" records now: a greyed offer, which cannot, offers
    /// it greyed too. "Never" stays.
    static func allowsAlways(_ offer: ForkMeetingOffer) -> Bool {
        offer.blocked == nil
    }

    /// Why a greyed offer cannot record now, in a few words.
    static func blocked(_ failure: ForkMeetingFailure, strings s: ForkMeetingStrings) -> String {
        failure == .officialRecorderBusy ? s.offerRecorderBusy : failure.summary(s)
    }

    /// The folded offer's words: the provider's short name ("Meet").
    static func reminderTitle(_ candidate: ForkMeetingCandidate) -> String {
        candidate.providerShortName.isEmpty ? candidate.providerName : candidate.providerShortName
    }

    // MARK: Fixes K

    /// A call in a browser other than Google Meet (Zoom's web client,
    /// Whereby, Jitsi Meet, Teams on the web): one choice for all of them.
    static func isOtherWebCall(_ candidate: ForkMeetingCandidate) -> Bool {
        candidate.provider == ForkMeetingProvider.otherWebCalls.first?.id
    }

    /// The menu's "Never": for the provider ("Never for Zoom"), or for the
    /// other web calls together, which that choice covers.
    static func neverTitle(_ candidate: ForkMeetingCandidate, strings s: ForkMeetingStrings) -> String {
        isOtherWebCall(candidate) ? s.offerNeverWebCalls : s.offerNever(reminderTitle(candidate))
    }

    /// "Meeting over? Stopping in 12 s", as the pill shows it.
    static func endingSoon(until: Date, now: Date, strings s: ForkMeetingStrings) -> String {
        s.endingSoonTitle + " " + s.endingSoon(seconds: ForkMeetingOfferTiming.secondsLeft(until: until, now: now))
    }

    /// "Cancel (4 s)".
    static func undo(until: Date, now: Date, strings s: ForkMeetingStrings) -> String {
        s.undo(seconds: ForkMeetingOfferTiming.secondsLeft(until: until, now: now))
    }

    // MARK: Fixes J

    /// The "Cancel" card's line, why it records: started on its own
    /// ("Auto-start · Always for Meet"), or "Always for Meet" just chosen by
    /// hand, with where to change it ("Always for Meet · Change it in
    /// Meetings"). `nil` without a provider.
    static func undoLine(provider: String?, choseAlways: Bool, strings s: ForkMeetingStrings) -> String? {
        guard let provider else { return nil }
        return choseAlways ? s.offerAlways(provider) + " · " + s.noticeNeverDetail : s.undoAutoStarted(provider)
    }

    private static func named(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

// MARK: Fixes J

/// What the island shows when someone else's screen share sees it (the
/// official "Show in screenshots and videos" on), and the pill under the
/// pointer then: the service rather than the meeting's name, a kind of
/// microphone rather than its own name ("AirPods d’Alice"). VoiceOver, which
/// no share hears, keeps the names.
enum ForkMeetingSharedText {
    /// The pill's name under the pointer: the meeting's, or the provider's
    /// when shares see the pill; the default name without either.
    static func pillName(title: String?, providerName: String?, seenInShares: Bool,
                         strings s: ForkMeetingStrings) -> String {
        let name = seenInShares ? providerName : title
        guard let name, !name.isEmpty else { return s.untitledMeeting }
        return name
    }

    /// A microphone, by kind: "Automatic" for the meeting's own input, else
    /// built in or external.
    static func microphone(_ input: ForkMeetingOfferInput, builtIn: Bool, strings s: ForkMeetingStrings) -> String {
        if case .meetingApp = input { return s.microphoneMeeting }
        return builtIn ? s.microphoneBuiltIn : s.microphoneExternal
    }

    /// A notice's second line as the island shows it to shares: the
    /// microphone changed names its kind; any other keeps its own.
    static func detail(_ notice: ForkMeetingNotice, microphoneBuiltIn: Bool, strings s: ForkMeetingStrings) -> String? {
        guard case .microphone = notice else { return notice.detail(s) }
        return microphoneBuiltIn ? s.microphoneBuiltIn : s.microphoneExternal
    }
}
