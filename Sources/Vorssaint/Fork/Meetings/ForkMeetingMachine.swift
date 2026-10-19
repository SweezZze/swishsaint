// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// One capture session's number. Every asynchronous answer (the capture
/// started, failed, the file closed) carries it, and one that does not match
/// the session in the machine is dropped: a late answer never touches the
/// next meeting.
struct ForkMeetingToken: Hashable {
    let value: Int
}

/// What the person chose on the Meetings page, read when a meeting starts.
struct ForkMeetingCaptureSettings: Equatable {
    /// The microphone setting that records none.
    static let microphoneOff = "off"

    var target: ForkMeetingCaptureTarget
    var systemAudio: ForkMeetingSystemAudio
    /// "meeting", "system", "builtin", a capture device's unique ID, or "off".
    var microphone: String
    var quality: ForkMeetingQuality
}

/// What the service knows about the Mac when a start is asked. The machine
/// decides from it whether the meeting may start.
struct ForkMeetingStartFacts: Equatable {
    /// Free space on the meetings' volume; `nil` when it could not be read,
    /// which never counts as enough.
    var freeBytes: Int64?
    var screenRecordingAllowed: Bool
    var microphoneAllowed: Bool
    /// The official screen recorder is running.
    var officialRecorderBusy: Bool
    /// The detected meetings whose app has used a microphone for a second
    /// at least (`ForkMeetingResolution.onMicrophone`): "Always" starts only
    /// those on its own, when they prove who they are (Meet's code in the
    /// title, an app's own call); a title alone, which any page can copy, is
    /// offered.
    var meetingsOnMicrophone: Set<ForkMeetingIdentity> = []
}

struct ForkMeetingStartRequest: Equatable {
    var settings: ForkMeetingCaptureSettings
    var facts: ForkMeetingStartFacts
    /// A name known at the start; `nil` gives the default one.
    var title: String?
}

/// Everything the service needs to start a capture and write the meeting's
/// first `meeting.json`.
struct ForkMeetingCaptureConfig: Equatable {
    var origin: ForkMeetingOrigin
    var title: String?
    var settings: ForkMeetingCaptureSettings
    /// Off by choice, or not allowed: then the meeting records without it.
    var recordsMicrophone: Bool
    /// The microphone was wanted but is not allowed: said when it starts.
    var microphoneDenied: Bool
    /// The detected meeting being recorded: its window, its app, its name.
    /// `nil` for a recording started by hand with no meeting around.
    var meeting: ForkMeetingCandidate? = nil
}

enum ForkMeetingWriterResult: Equatable {
    /// The file closed properly. `recordedSeconds` as the writer counted
    /// them, when it knows.
    case finished(recordedSeconds: TimeInterval?)
    case failed(ForkMeetingFailure)
}

enum ForkMeetingPermission: Equatable {
    case screenRecording
    case microphone
    case systemAudio
}

/// The time shown by the pill: recorded seconds before `runningSince`, plus
/// the time since, when it runs. Pauses and sleep are not counted.
struct ForkMeetingClock: Equatable {
    var recordedBefore: TimeInterval
    var runningSince: Date?

    func elapsed(at now: Date) -> TimeInterval {
        recordedBefore + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
}

/// What the recording pill shows.
enum ForkMeetingPillState: Equatable {
    case hidden
    /// `diskMinutesLeft` once the disk runs low.
    case recording(ForkMeetingClock, diskMinutesLeft: Int?)
    case paused(ForkMeetingClock, ForkMeetingPauseReason, diskMinutesLeft: Int?)
    case stopping
    /// The final pass runs; the finalizer hides the pill when it is done.
    case finalizing
}

/// A short notice for the island (or the bubble), and for a system
/// notification when the app is in the background.
enum ForkMeetingNotice: Equatable {
    case started
    case resumed
    case saved
    case recovered
    case microphone(String)
    case microphoneSilent
    case diskLow(minutesLeft: Int)
    case displayChanged
    /// The filmed window's app quit: the picture holds its last frame, the
    /// sound goes on.
    case sourceGone
    case failure(ForkMeetingFailure)
    /// The meeting app's sound was lost for the rest of the recording.
    case soundLost
    /// "Never for Meet" was chosen; the provider's short name.
    case neverOffered(String)
    /// "Never for other web calls" was chosen: one choice for them all.
    case neverOfferedWebCalls
    /// "Always for Meet" was chosen; the provider's short name.
    case alwaysChosen(String)
    /// After "Cancel", once the folder is gone (or not).
    case discarded(ForkMeetingDiscardOutcome)
    /// "Copy Announcement": it is in the pasteboard.
    case announcementCopied
    /// "Cancel" took back the "Always" just chosen by hand, before anything
    /// was recorded; the provider's short name.
    case askedAgain(String)

    /// 28 characters at most.
    func title(_ s: ForkMeetingStrings) -> String {
        switch self {
        case .started: return s.noticeStarted
        case .resumed: return s.noticeResumed
        case .saved: return s.noticeSaved
        case .recovered: return s.noticeRecovered
        case .microphone: return s.noticeMicrophone
        case .microphoneSilent: return s.noticeMicrophoneSilent
        case .diskLow: return s.noticeDiskLow
        case .displayChanged: return s.noticeDisplayChanged
        case .sourceGone: return s.noticeSourceGone
        case let .failure(failure): return failure.summary(s)
        case .soundLost: return s.noticeSoundLost
        case let .neverOffered(provider): return s.noticeNever(provider)
        case .neverOfferedWebCalls: return s.noticeNeverWebCalls
        case let .alwaysChosen(provider): return s.offerAlways(provider)
        case .discarded(.trashed): return s.noticeDiscardedTrash
        case .discarded(.deleted): return s.noticeDiscardedDeleted
        case .discarded(.kept): return s.noticeDiscardKept
        case .announcementCopied: return s.noticeAnnouncementCopied
        case let .askedAgain(provider): return s.noticeAskAgain(provider)
        }
    }

    /// The second line, when the notice has one. The finalizer adds its
    /// own (length and size) to the saved and recovered notices.
    func detail(_ s: ForkMeetingStrings) -> String? {
        switch self {
        case let .microphone(name): return name
        case let .diskLow(minutes): return s.diskMinutes(minutes)
        case .neverOffered, .neverOfferedWebCalls, .alwaysChosen, .askedAgain: return s.noticeNeverDetail
        case .discarded(.kept): return s.noticeDiscardKeptDetail
        case .announcementCopied: return s.noticeAnnouncementCopiedDetail
        case .started, .resumed, .saved, .recovered, .microphoneSilent, .displayChanged, .sourceGone, .failure,
             .soundLost, .discarded:
            return nil
        }
    }
}

/// What VoiceOver says at each transition.
enum ForkMeetingAnnouncement: Equatable {
    case started
    case paused
    case resumed
    case stopped
    case microphone(String)
    case microphoneSilent
    case diskLow(minutesLeft: Int)
    case displayChanged
    case sourceGone
    case failure(ForkMeetingFailure)
    /// The start, said with the microphone left out because it is not
    /// allowed: one sentence, not two that would cut each other off.
    case startedWithoutMicrophone
    case soundLost
    /// A meeting is offered; its name.
    case offered(String)
    /// "Always" started it; `seconds` left to cancel it. Without the
    /// microphone, because it is not allowed, it says so in the same breath.
    case autoStarted(seconds: Int, withoutMicrophone: Bool = false)
    case endingSoon(seconds: Int)
    case continued
    /// "Cancel": the recording is cancelled. Where its folder went is said
    /// once it is gone (`ForkMeetingDiscardOutcome.spokenAfterCancel`).
    case discarded
    case neverOffered(String)
    /// "Never for other web calls".
    case neverOfferedWebCalls
    /// The meeting came back during the countdown: it goes on, so does
    /// the recording.
    case meetingBack
    /// "Cancel" took back the "Always" chosen by hand; the provider's
    /// short name.
    case askedAgain(String)

    func text(_ s: ForkMeetingStrings) -> String {
        switch self {
        case .started: return s.voiceStarted
        case .paused: return s.voicePaused
        case .resumed: return s.voiceResumed
        case .stopped: return s.voiceStopped
        case let .microphone(name): return s.voiceMicrophone(name)
        case .microphoneSilent: return s.voiceMicrophoneSilent
        case let .diskLow(minutes): return s.voiceDiskLow(minutes)
        case .displayChanged: return s.voiceFilmedDisplayChanged
        case .sourceGone: return s.voiceSourceGone
        case let .failure(failure): return ForkMeetingLiveText.sentences(failure.summary(s), failure.remedy(s))
        case .startedWithoutMicrophone: return s.voiceStartedWithoutMicrophone
        case .soundLost: return s.voiceSoundLost
        case let .offered(name): return s.voiceOffer(name)
        case let .autoStarted(seconds, withoutMicrophone):
            let started = s.voiceAutoStarted(seconds: seconds)
            guard withoutMicrophone else { return started }
            let denied = ForkMeetingFailure.microphoneDenied
            return ForkMeetingLiveText.sentences(started, ForkMeetingLiveText.sentences(denied.summary(s),
                                                                                        denied.remedy(s)))
        case let .endingSoon(seconds): return s.voiceEndingSoon(seconds: seconds)
        case .continued: return s.voiceContinued
        case .discarded: return s.voiceCancelled
        case let .neverOffered(provider): return s.voiceNever(provider)
        case .neverOfferedWebCalls: return s.voiceNeverWebCalls
        case .meetingBack: return s.voiceMeetingBack
        case let .askedAgain(provider): return s.voiceAskAgain(provider)
        }
    }
}

/// A detected meeting offered in the island or the bubble.
struct ForkMeetingOffer: Equatable {
    var candidate: ForkMeetingCandidate
    /// When the offer folds into its small reminder, unanswered.
    var collapsesAt: Date
    var collapsed = false
    /// Why it cannot be recorded now (the official recorder runs, Screen
    /// Recording is off, the disk is full): the offer shows it, greyed out.
    var blocked: ForkMeetingFailure?
    /// "Always" waited 15 s for the call to prove itself, then offered it:
    /// a proof that comes while it is unanswered (Zoom's meeting window
    /// after its microphone) starts it, as "Always" would have.
    var awaitedProof = false
}

/// "Not now" sets this meeting aside; "Never" the provider.
enum ForkMeetingDismissal: Equatable {
    case thisTime
    case never
}

/// The only place where a meeting recording decides anything.
///
/// Like the dictation's machine it does nothing itself: it never touches
/// the stream, the writer, the disk or the screen. It takes an event, with
/// the time it happened, and returns the effects the service runs, which is
/// what makes every path testable. An event that makes no sense in the
/// current phase returns nothing and changes nothing.
///
/// ```
///  idle ──manualStart──► starting ──captureStarted──► recording ◄──────resume / wake────────┐
///   ▲  (refused: idle)      │ failed, stop             │      └───────pause / willSleep──────► paused
///   │                       ▼                          │ stop, disk, permission, quit,          │
///   ├──────────────────── idle                         ▼ feature off, capture failed            │
///   └──writerFinished + beginFinalize (once)──── stopping ◄─────────────────────────────────────┘
/// ```
///
/// Invariants, each tested:
/// - every way out of `recording` and `paused` goes through `stopping`;
/// - an answer carrying an old token is ignored;
/// - `beginFinalize` is asked once per session, never after a failure;
/// - `endedAt` is never written after a failure;
/// - quitting while recording writes `interrupted` first, then stops;
/// - turning the feature off stops the meeting and keeps its file;
/// - a meeting started by hand is never ended by the detection
///   (`Session.endsWithMeeting`), and resumes after a sleep;
/// - a locked screen pauses nothing: the sound goes on, the picture
///   freezes, and the lock is noted in `meeting.json` as a gap;
/// - the filmed app quitting ends nothing either: the sound goes on.
///
/// The detection adds an offer before, and a countdown at the end:
/// ```
///  idle ──candidates──► offering ──accept / always──► starting …
///   ▲   (Always: starting)   │ dismiss, gone, feature off
///   └────────────────────────┘
///  recording ──endProbable(its meeting)──► endingSoon ──countdown over──► stopping
///      ▲                                       │
///      └──── continue, its meeting back ───────┘ (pause, stop, sleep… leave it as from recording)
/// ```
/// - a stop from the detection acts only on a recording the detection
///   started (`origin != .manual`), and only for its own meeting;
/// - a second meeting during a recording ends nothing and is offered only
///   once the recording is over;
/// - an offer is greyed out, never started, while the official recorder
///   runs (or anything else would refuse the start);
/// - a recording "Always" started can be cancelled for 5 s: its folder goes
///   to the Trash, never finalized, and `meeting.json` says so at once, so
///   a quit meanwhile never has it recovered; cancelled right after
///   "Always" was chosen in the offer, the provider is offered again
///   ("ask"), and that is said;
/// - "Always" starts on its own only a meeting that proves who it is (its
///   Meet code in the title, an app's meeting window, an app's microphone
///   open for 15 s; FaceTime and the other web calls never) whose app has
///   used the microphone for a second, on a screen not locked: otherwise,
///   and once an offer was shown, it waits for a click. An app's call that
///   may still prove itself is waited for, not offered; offered after the
///   15 s, it still starts on its own if its proof comes before an answer.
struct ForkMeetingMachine {
    /// An unanswered offer folds after this long.
    static let offerCollapse: TimeInterval = 20
    /// How long "Cancel" can still send a recording "Always" started to the
    /// Trash.
    static let undoWindow: TimeInterval = 5
    /// With VoiceOver: time to hear the start said, then reach "Cancel".
    static let undoWindowVoiceOver: TimeInterval = 15

    static func undoWindow(voiceOver: Bool) -> TimeInterval { voiceOver ? undoWindowVoiceOver : undoWindow }

    /// A start asked, the capture not running yet.
    struct Pending: Equatable {
        let token: ForkMeetingToken
        let config: ForkMeetingCaptureConfig
        /// Its meeting ended meanwhile, and the countdown it was given: it
        /// starts once the capture runs.
        var meetingGone = false
        var endCountdown: TimeInterval?
        /// "Always" was chosen in the offer this start came from.
        var choseAlways = false

        var origin: ForkMeetingOrigin { config.origin }
    }

    struct Session: Equatable {
        let token: ForkMeetingToken
        let config: ForkMeetingCaptureConfig
        let folder: URL
        let startedAt: Date
        /// What the picture follows now: the setting, unless the capture had
        /// to film the display (no window to film), or ⧉ switched it.
        var target: ForkMeetingCaptureTarget = .window
        /// Seconds recorded before `runningSince`.
        var recordedBefore: TimeInterval = 0
        /// `nil` while paused or stopped.
        var runningSince: Date?
        var pausedSince: Date?
        /// Why the current pause began, for `meeting.json`.
        var pauseReason: ForkMeetingPauseReason?
        /// The stream died or was stopped (a sleep): a new one is needed
        /// before recording again.
        var streamNeedsRestart = false
        var diskMinutesLeft: Int?
        var microphoneSilenceSaid = false
        /// Seconds recorded when the screen locked, while it stays locked.
        var lockedAt: TimeInterval?
        var stoppedAt: Date?
        /// Until when "Cancel" sends a recording "Always" started to the Trash.
        var undoUntil: Date?
        /// Cancelled: its folder goes once the file is closed.
        var discarded = false
        /// Its folder was given to `.discard` already (the app quitting).
        var discardSaid = false
        /// "Always" was chosen in the offer it came from: "Cancel" offers
        /// the provider again.
        var choseAlways = false
        /// "Cancel" offered the provider again: its short name, said with
        /// where the folder went.
        var askedAgain: String?
        /// The detection said its meeting ended, and the countdown it gave:
        /// a pause or a sleep interrupts the countdown, the resume starts it
        /// again, so a meeting over during a sleep still stops.
        var meetingGone = false
        var endCountdown: TimeInterval?

        var origin: ForkMeetingOrigin { config.origin }

        /// Whether a meeting that ends may end the recording: never one
        /// started by hand.
        var endsWithMeeting: Bool { origin != .manual }

        /// The detected meeting this recording belongs to.
        var meeting: ForkMeetingIdentity? { config.meeting?.identity }

        var clock: ForkMeetingClock { ForkMeetingClock(recordedBefore: recordedBefore, runningSince: runningSince) }

        func recorded(at now: Date) -> TimeInterval { clock.elapsed(at: now) }

        mutating func beginPause(at now: Date, reason: ForkMeetingPauseReason) {
            guard runningSince != nil else { return }
            recordedBefore = recorded(at: now)
            runningSince = nil
            pausedSince = now
            pauseReason = reason
        }

        /// Ends the pause in progress and starts the clock again; the pause
        /// as `meeting.json` keeps it.
        mutating func endPause(at now: Date) -> ForkMeetingSidecar.Pause? {
            guard let since = pausedSince else { return nil }
            let pause = ForkMeetingSidecar.Pause(at: recordedBefore, seconds: max(0, now.timeIntervalSince(since)),
                                                 reason: pauseReason)
            pausedSince = nil
            pauseReason = nil
            runningSince = now
            return pause
        }

        /// Ends the screen lock in progress, as a gap of `meeting.json`: from
        /// the lock to now, in seconds of recording. None when nothing was
        /// recorded meanwhile (a pause covered it).
        mutating func endLock(at now: Date) -> ForkMeetingSidecar.Gap? {
            guard let start = lockedAt else { return nil }
            lockedAt = nil
            let seconds = recorded(at: now) - start
            return seconds > 0 ? ForkMeetingSidecar.Gap(at: start, seconds: seconds, kind: .screenLocked) : nil
        }
    }

    enum Phase: Equatable {
        case idle
        /// A detected meeting is offered, open or folded.
        case offering(ForkMeetingOffer)
        case starting(Pending)
        case recording(Session)
        case paused(Session, ForkMeetingPauseReason)
        /// The capture is stopping and the file closing; the session waits
        /// for `writerFinished`.
        case stopping(Session, ForkMeetingStopReason)
        /// Still recording, but its meeting probably ended: it stops at
        /// `until` unless the person continues.
        case endingSoon(Session, until: Date)
    }

    enum Event: Equatable {
        case manualStart(ForkMeetingStartRequest)
        case pause
        case resume
        case stop
        /// The stream runs and the writer took the first samples, in `folder`.
        /// `target` is what the picture really follows, `microphone` the
        /// name of the one recording, `systemAudio` what the meeting track
        /// hears, when the engine knows them. `startedAt` is the file's zero,
        /// which came before this answer: every time noted counts from it.
        case captureStarted(ForkMeetingToken, folder: URL, target: ForkMeetingCaptureTarget? = nil,
                            microphone: String? = nil, systemAudio: ForkMeetingSystemAudio? = nil,
                            startedAt: Date? = nil)
        case captureFailed(ForkMeetingToken, ForkMeetingFailure)
        /// Exactly once after `stopCapture`: the file is closed, or not.
        case writerFinished(ForkMeetingToken, ForkMeetingWriterResult)
        case willSleep
        case didWake
        case locked
        case unlocked
        /// A reading of the free space under the warning floor, or back above
        /// it after one was (the pill's minutes then go).
        case diskLow(freeBytes: Int64)
        case diskCritical
        case permissionLost(ForkMeetingPermission)
        case displayChanged
        /// The microphone changed; `gap` seconds were lost rebuilding it.
        case microphoneChanged(name: String, gap: TimeInterval)
        case microphoneSilent
        /// The microphone's silence is over: the next one is said again.
        case microphoneSoundBack
        /// The meeting track heard more than `meeting.json` says (the whole
        /// Mac after the app alone): its widest so far.
        case soundHeard(ForkMeetingToken, ForkMeetingSystemAudio)
        /// ⧉: the picture switches between the window and the display.
        case toggleTarget
        /// The engine films something else now: ⧉ took, or the window went
        /// and its display is filmed. A switch that did not take sends none.
        case targetSwitched(ForkMeetingToken, ForkMeetingCaptureTarget)
        /// The filmed window's app quit; its last frame stays.
        case sourceGone(ForkMeetingToken)
        case appWillTerminate
        case featureDisabled
        /// The meeting app's sound was lost for the rest of the recording
        /// (its tap lost its reader on a display): said, and noted as a gap.
        case soundLost(ForkMeetingToken)
        /// The meetings the resolver sees, the most recent first, and what a
        /// start would be asked with now.
        case candidates([ForkMeetingCandidate], ForkMeetingStartRequest)
        /// Time passes: an offer folds, a countdown ends, "Cancel" expires.
        case tick
        /// "Record" in the offer.
        case accept(ForkMeetingStartRequest)
        case dismiss(ForkMeetingDismissal)
        /// "Always for Meet" in the offer: it records now, and on its own
        /// from then on.
        case always(ForkMeetingStartRequest)
        /// "Cancel" within 5 s of a start "Always" made.
        case cancelAutoStart
        /// "Continue" during the countdown.
        case continueRecording
        /// The resolver says this meeting probably ended. `countdown` is
        /// the delay before stopping; `nil` (auto stop off): never.
        case endProbable(ForkMeetingIdentity, countdown: TimeInterval?)
    }

    enum Effect: Equatable {
        case startCapture(ForkMeetingCaptureConfig, ForkMeetingToken)
        /// The writer stops taking samples; for a sleep the stream stops too.
        case pauseCapture(ForkMeetingPauseReason)
        case resumeCapture
        /// A new stream, for the same writer.
        case restartStream
        /// The picture follows this target: the window, or the display that
        /// holds it now. The engine answers with `targetSwitched` when what
        /// it films changed.
        case switchTarget(ForkMeetingCaptureTarget)
        /// Stops everything the token started. A start that never ran
        /// leaves nothing behind; a recording closes its file and answers
        /// with `writerFinished`.
        case stopCapture(ForkMeetingToken)
        case showPill(ForkMeetingPillState)
        case notice(ForkMeetingNotice)
        case announce(ForkMeetingAnnouncement)
        /// A system notification, posted only when the app is not in front.
        case notify(ForkMeetingNotice)
        case writeSidecar(URL, ForkMeetingSidecarPatch)
        /// Hands the closed recording to the finalizer, which lives outside
        /// the machine: the next meeting may start meanwhile.
        case beginFinalize(URL)
        /// Opens the offer, or shows it again changed (greyed, folded).
        case showOffer(ForkMeetingOffer)
        /// Folds it into its reminder.
        case collapseOffer
        case hideOffer
        /// No new offer opens for this meeting until it has been over for
        /// 10 minutes (`ForkMeetingResolver.silence`).
        case silence(ForkMeetingIdentity)
        /// Writes the provider's choice into `fork.meetings.apps`.
        case setPolicy(ForkMeetingPolicy, provider: String)
        /// "Recording started · Cancel (5 s)".
        case showUndo(until: Date)
        case hideUndo
        /// "Meeting over? Stopping in 15 s [Continue]".
        case showEndingSoon(until: Date)
        case hideEndingSoon
        /// Sends a cancelled recording's folder to the Trash, once its file is
        /// closed. `askedAgain`: "Cancel" also took back the "Always" chosen
        /// by hand for this provider (its short name), said with the outcome.
        case discard(URL, askedAgain: String? = nil)
    }

    private(set) var phase: Phase = .idle
    private var lastToken = 0
    /// A fact that outlives a phase: a meeting may start on a locked screen.
    private var locked = false
    /// The app is quitting: nothing starts any more, nothing is finalized.
    private var terminating = false
    /// When the screen was last unlocked: a stream stopped by the lock is
    /// reported `externalStopGrace` late, possibly after the unlock.
    private var unlockedAt: Date?
    /// The most recent meeting the detection sees, set aside or not: a
    /// start by hand records it.
    private var detected: ForkMeetingCandidate?
    /// VoiceOver runs, as the service read it before the start's answer:
    /// "Cancel" stays `undoWindowVoiceOver`.
    var voiceOver = false

    /// A meeting is starting, recording or closing; an offer is not.
    var isBusy: Bool {
        switch phase {
        case .idle, .offering: return false
        case .starting, .recording, .paused, .stopping, .endingSoon: return true
        }
    }

    /// The session recording or paused, if any.
    var activeSession: Session? {
        switch phase {
        case let .recording(session), let .paused(session, _), let .endingSoon(session, _): return session
        case .idle, .offering, .starting, .stopping: return nil
        }
    }

    @discardableResult
    mutating func handle(_ event: Event, now: Date) -> [Effect] {
        switch event {
        case let .candidates(candidates, _): detected = candidates.first
        case .featureDisabled: detected = nil
        default: break
        }
        switch phase {
        case let .offering(offer): return whileOffering(event, offer: offer, now: now)
        case let .endingSoon(session, until): return whileEndingSoon(event, session: session, until: until, now: now)
        case .idle, .starting, .recording, .paused, .stopping: return handleSession(event, now: now)
        }
    }

    /// The events of a recording, from idle to the closed file.
    private mutating func handleSession(_ event: Event, now: Date) -> [Effect] {
        switch event {
        case let .manualStart(request):
            guard phase == .idle, !terminating else { return [] }
            // A meeting going on ("Not now", or its offer gone): recorded by
            // hand, with its name, its window and its app's microphone,
            // and never stopped by the detection.
            let effects = start(origin: .manual, request: request, meeting: detected)
            guard case .starting = phase, let detected, !detected.silenced else { return effects }
            return [.silence(detected.identity)] + effects

        case let .captureStarted(token, folder, target, microphone, systemAudio, startedAt):
            guard case let .starting(pending) = phase, pending.token == token else { return [] }
            let setting = pending.config.settings.target
            let zero = min(startedAt ?? now, now)
            var session = Session(token: token, config: pending.config, folder: folder, startedAt: zero,
                                  target: target ?? setting, runningSince: zero)
            if locked, session.target.filmsPicture { session.lockedAt = 0 }
            session.choseAlways = pending.choseAlways
            session.meetingGone = pending.meetingGone
            session.endCountdown = pending.endCountdown
            let denied = pending.config.microphoneDenied
            var effects: [Effect] = [.showPill(pill(session, paused: nil))]
            if pending.origin == .always {
                // "Recording started · Cancel (5 s)" stands in for the start
                // notice. Started on its own, VoiceOver says so; "Always"
                // chosen by hand, the person pressed it: a plain start.
                let window = Self.undoWindow(voiceOver: voiceOver)
                session.undoUntil = now.addingTimeInterval(window)
                if denied { effects.append(.notice(.failure(.microphoneDenied))) }
                let said: ForkMeetingAnnouncement = pending.choseAlways
                    ? (denied ? .startedWithoutMicrophone : .started)
                    : .autoStarted(seconds: Int(window), withoutMicrophone: denied)
                effects += [.showUndo(until: now.addingTimeInterval(window)), .announce(said)]
            } else {
                effects += [.notice(denied ? .failure(.microphoneDenied) : .started),
                            .announce(denied ? .startedWithoutMicrophone : .started)]
            }
            phase = .recording(session)
            // The first `meeting.json` has the setting; it now says what
            // really records.
            var patch = ForkMeetingSidecarPatch(microphone: microphone)
            if session.target != setting { patch.target = session.target }
            if let systemAudio, systemAudio != pending.config.settings.systemAudio { patch.systemAudio = systemAudio }
            if patch != ForkMeetingSidecarPatch() { effects.insert(.writeSidecar(folder, patch), at: 0) }
            // Its meeting ended while the capture came up: no reading will
            // say so again, the countdown starts now.
            if session.meetingGone, let countdown = session.endCountdown {
                effects += beginCountdown(session, countdown: countdown, now: now)
            }
            return effects

        case let .captureFailed(token, failure):
            if case let .starting(pending) = phase, pending.token == token {
                phase = .idle
                return [.stopCapture(token), .notice(.failure(failure)), .announce(.failure(failure))]
            }
            guard var session = activeSession, session.token == token else { return [] }
            // A stream that dies during a sleep or a lock is expected: a new
            // one starts at the wake or the unlock.
            let asleep: Bool = {
                if case .paused(_, .sleep) = phase { return true }
                return false
            }()
            if failure == .streamStopped, asleep || session.lockedAt != nil {
                session.streamNeedsRestart = true
                replace(session)
                return []
            }
            // Locked and unlocked again while the stop's report waited: the
            // unlock came and went without a stream to restart, so it is
            // restarted now (or at the resume, when paused).
            if failure == .streamStopped, let unlockedAt,
               now.timeIntervalSince(unlockedAt) < ForkMeetingCaptureSupport.externalStopGrace {
                guard case .recording = phase else {
                    session.streamNeedsRestart = true
                    replace(session)
                    return []
                }
                return [.restartStream]
            }
            return stopForFailure(session, failure == .screenRecordingDenied ? .screenRecordingRevoked : failure, now: now)

        case let .writerFinished(token, result):
            guard case let .stopping(session, _) = phase, session.token == token else { return [] }
            return finish(session, result: result)

        case .pause:
            guard case var .recording(session) = phase else { return [] }
            session.beginPause(at: now, reason: .user)
            phase = .paused(session, .user)
            return [.pauseCapture(.user), .showPill(pill(session, paused: .user)), .announce(.paused)]

        case .resume:
            guard case let .paused(session, _) = phase else { return [] }
            return resume(session, now: now, automatic: false)

        case .stop:
            if case let .starting(pending) = phase { return cancel(pending) }
            guard let session = activeSession else { return [] }
            return stop(session, reason: .user, now: now)

        case .willSleep:
            switch phase {
            case let .starting(pending):
                return cancel(pending)
            case var .recording(session):
                session.beginPause(at: now, reason: .sleep)
                session.streamNeedsRestart = true
                phase = .paused(session, .sleep)
                return [.pauseCapture(.sleep), .showPill(pill(session, paused: .sleep)), .announce(.paused)]
            case .paused(var session, let reason):
                // A pause chosen by the person stays theirs: the wake will
                // not end it.
                session.streamNeedsRestart = true
                phase = .paused(session, reason)
                return [.pauseCapture(.sleep)]
            case .idle, .offering, .stopping, .endingSoon:
                return []
            }

        case .didWake:
            guard case let .paused(session, .sleep) = phase else { return [] }
            // Started by hand: it resumes, on a new stream, even on the lock
            // screen (the picture stays frozen until the unlock). An offered
            // meeting that ended during the sleep will stop here instead,
            // with the detection.
            return resume(session, now: now, automatic: true)

        case .locked:
            locked = true
            // Nothing pauses: the sound goes on, the picture freezes. The
            // lock becomes a gap once its length is known; without picture
            // nothing froze, nothing is noted.
            guard var session = activeSession, session.lockedAt == nil, session.target.filmsPicture else { return [] }
            session.lockedAt = session.recorded(at: now)
            replace(session)
            return []

        case .unlocked:
            locked = false
            unlockedAt = now
            guard var session = activeSession else { return [] }
            var effects: [Effect] = []
            if case .recording = phase, session.streamNeedsRestart {
                session.streamNeedsRestart = false
                effects.append(.restartStream)
            }
            if let gap = session.endLock(at: now) {
                effects.append(.writeSidecar(session.folder, ForkMeetingSidecarPatch(gap: gap)))
            }
            replace(session)
            return effects

        case let .diskLow(freeBytes):
            guard var session = activeSession else { return [] }
            switch ForkMeetingDisk.level(freeBytes: freeBytes, settings: session.config.settings) {
            case .critical:
                return stopForFailure(session, .diskFull, now: now)
            case .enough:
                guard session.diskMinutesLeft != nil else { return [] }
                session.diskMinutesLeft = nil
                return update(session)
            case let .low(minutes):
                let first = session.diskMinutesLeft == nil
                guard session.diskMinutesLeft != minutes else { return [] }
                session.diskMinutesLeft = minutes
                let warned: [Effect] = first ? [.notice(.diskLow(minutesLeft: minutes)),
                                                .announce(.diskLow(minutesLeft: minutes))] : []
                return update(session) + warned
            }

        case .diskCritical:
            guard let session = activeSession else { return [] }
            return stopForFailure(session, .diskFull, now: now)

        case let .permissionLost(permission):
            guard let session = activeSession else { return [] }
            switch permission {
            case .screenRecording:
                // Nothing filmed, nothing taken away.
                guard session.target.filmsPicture else { return [] }
                return stopForFailure(session, .screenRecordingRevoked, now: now)
            case .microphone:
                let patch = ForkMeetingSidecarPatch(microphone: ForkMeetingSidecar.Capture.microphoneDenied)
                return [.writeSidecar(session.folder, patch), .notice(.failure(.microphoneDenied)),
                        .announce(.failure(.microphoneDenied))]
            case .systemAudio:
                // What the track hears now is the engine's word (`soundHeard`).
                return [.notice(.failure(.systemAudioUnavailable)), .announce(.failure(.systemAudioUnavailable))]
            }

        case .displayChanged:
            guard let session = activeSession, session.target == .display else { return [] }
            return [.switchTarget(.display), .notice(.displayChanged), .announce(.displayChanged)]

        case .toggleTarget:
            // Asked only: the engine says what it films once it does, and
            // only then is the switch noted (a window that went cannot be
            // filmed again). Without picture there is nothing to switch.
            guard let session = activeSession, session.target.filmsPicture else { return [] }
            return [.switchTarget(session.target == .window ? .display : .window)]

        case let .targetSwitched(token, target):
            guard var session = activeSession, session.token == token, session.target != target else { return [] }
            session.target = target
            replace(session)
            // Nothing is lost: the switch is noted where the picture changes.
            let gap = ForkMeetingSidecar.Gap(at: session.recorded(at: now), seconds: 0, kind: .targetSwitch)
            return [.writeSidecar(session.folder, ForkMeetingSidecarPatch(gap: gap))]

        case let .sourceGone(token):
            // Started by hand, the recording goes on with the sound: only the
            // person ends it. (A detected meeting's end is the detection's.)
            guard let session = activeSession, session.token == token else { return [] }
            return [.notice(.sourceGone), .announce(.sourceGone)]

        case let .microphoneChanged(name, gap):
            guard var session = activeSession else { return [] }
            session.microphoneSilenceSaid = false
            var patch = ForkMeetingSidecarPatch(microphone: name)
            if gap > 0 {
                let at = max(0, session.recorded(at: now) - gap)
                patch.gap = ForkMeetingSidecar.Gap(at: at, seconds: gap, kind: .microphoneSwitch)
            }
            replace(session)
            return [.writeSidecar(session.folder, patch), .notice(.microphone(name)), .announce(.microphone(name))]

        case .microphoneSilent:
            guard var session = activeSession, !session.microphoneSilenceSaid else { return [] }
            session.microphoneSilenceSaid = true
            replace(session)
            return [.notice(.microphoneSilent), .announce(.microphoneSilent)]

        case let .soundHeard(token, heard):
            // Stopping too: the track heard it just before the Stop, and the
            // file holds it.
            let session: Session?
            if case let .stopping(stopping, _) = phase { session = stopping } else { session = activeSession }
            guard let session, session.token == token else { return [] }
            return [.writeSidecar(session.folder, ForkMeetingSidecarPatch(systemAudio: heard))]

        case .microphoneSoundBack:
            guard var session = activeSession, session.microphoneSilenceSaid else { return [] }
            session.microphoneSilenceSaid = false
            replace(session)
            return []

        case .appWillTerminate:
            terminating = true
            switch phase {
            case .idle:
                return []
            case let .starting(pending):
                return cancel(pending)
            case .recording, .paused:
                guard var session = activeSession else { return [] }
                var patch = ForkMeetingSidecarPatch(state: .interrupted, stopReason: .quit)
                patch.pause = session.endPause(at: now)
                patch.gap = session.endLock(at: now)
                session.recordedBefore = session.recorded(at: now)
                session.runningSince = nil
                session.stoppedAt = now
                phase = .stopping(session, .quit)
                // The sidecar first: the app may be gone before the file
                // closes, and the next launch then knows what happened.
                return [.writeSidecar(session.folder, patch), .stopCapture(session.token)]
            case .stopping(var session, let reason):
                // A cancelled recording is not to be recovered at the next
                // launch; its folder is given once, even if the file closes
                // before the app ends.
                guard !session.discarded else {
                    guard !session.discardSaid else { return [] }
                    session.discardSaid = true
                    phase = .stopping(session, reason)
                    return [.discard(session.folder, askedAgain: session.askedAgain)]
                }
                return [.writeSidecar(session.folder, ForkMeetingSidecarPatch(state: .interrupted))]
            case .offering, .endingSoon:
                return []
            }

        case .featureDisabled:
            if case let .starting(pending) = phase { return cancel(pending) }
            guard let session = activeSession else { return [] }
            return stop(session, reason: .featureDisabled, now: now)

        case let .soundLost(token):
            guard let session = activeSession, session.token == token else { return [] }
            let gap = ForkMeetingSidecar.Gap(at: session.recorded(at: now), seconds: 0, kind: .soundLost)
            return [.writeSidecar(session.folder, ForkMeetingSidecarPatch(gap: gap)), .notice(.soundLost),
                    .announce(.soundLost)]

        case let .candidates(candidates, request):
            if phase == .idle { return offerOrStart(candidates, request: request, now: now) }
            if case var .starting(pending) = phase {
                // Its meeting back before the capture runs: no countdown.
                guard pending.meetingGone, let meeting = pending.config.meeting?.identity,
                      candidates.contains(where: { $0.identity == meeting }) else { return [] }
                pending.meetingGone = false
                phase = .starting(pending)
                return []
            }
            // During a recording a second meeting waits for its end; its own
            // meeting may come back.
            guard var session = activeSession, session.meetingGone,
                  candidates.contains(where: { $0.identity == session.meeting }) else { return [] }
            session.meetingGone = false
            replace(session)
            return []

        case .tick:
            guard var session = activeSession, let until = session.undoUntil, now >= until else { return [] }
            session.undoUntil = nil
            replace(session)
            return [.hideUndo]

        case .cancelAutoStart:
            if case let .starting(pending) = phase, pending.origin == .always {
                // Nothing recorded, no folder to say where it went: the
                // choice taken back is said now.
                let askedAgain = Self.askAgain(pending.choseAlways, pending.config.meeting)
                guard !askedAgain.isEmpty, let meeting = pending.config.meeting else { return cancel(pending) }
                let provider = ForkMeetingOfferText.reminderTitle(meeting)
                return cancel(pending) + askedAgain + [.notice(.askedAgain(provider)), .announce(.askedAgain(provider))]
            }
            guard let session = activeSession, let until = session.undoUntil, now < until else { return [] }
            return discard(session, now: now)

        case let .endProbable(identity, countdown):
            // While the capture starts, the end waits for it to run.
            if case var .starting(pending) = phase {
                guard pending.origin != .manual, pending.config.meeting?.identity == identity, let countdown else {
                    return []
                }
                pending.meetingGone = true
                pending.endCountdown = countdown
                phase = .starting(pending)
                return []
            }
            // A meeting started by hand, or another meeting, never stops
            // this one. A pause holds the countdown until the resume.
            guard var session = activeSession, session.endsWithMeeting, session.meeting == identity,
                  let countdown else { return [] }
            session.meetingGone = true
            session.endCountdown = countdown
            replace(session)
            guard case .recording = phase else { return [] }
            return beginCountdown(session, countdown: countdown, now: now)

        case .accept, .dismiss, .always, .continueRecording:
            return []
        }
    }

    // MARK: - Detection

    /// From idle: offers the most recent meeting not set aside, or starts it
    /// when its provider is set to "Always" and nothing refuses the start:
    /// it proves who it is (Meet's code in its title, as a page can call
    /// itself "Meet – x"; an app's meeting window, or its microphone open
    /// 15 s, as a test of it in the app's settings is not; FaceTime and the
    /// other web calls never),
    /// its app has used the microphone for a second (a page can copy a
    /// title, not a call) and the screen is not locked (nobody to cancel).
    private mutating func offerOrStart(_ candidates: [ForkMeetingCandidate], request: ForkMeetingStartRequest,
                                       now: Date) -> [Effect] {
        guard !terminating, let candidate = candidates.first(where: { !$0.silenced && $0.policy != .never }) else {
            return []
        }
        let blocked = Self.refusal(request)
        if candidate.policy == .always, blocked == nil, !locked,
           request.facts.meetingsOnMicrophone.contains(candidate.identity) {
            if candidate.provesItself(at: now) {
                return [.silence(candidate.identity)] + start(origin: .always, request: request, meeting: candidate)
            }
            // An app's call not proved yet (Zoom's meeting window not read
            // yet, Teams' microphone open under 15 s): waited for. A
            // microphone test closes it before, and is then only offered.
            if candidate.awaitsProof(at: now) { return [] }
        }
        // Set aside as soon as it is offered: coming back to its tab, or
        // leaving and rejoining within 10 minutes, offers nothing new.
        var offered = candidate
        offered.silenced = true
        var offer = ForkMeetingOffer(candidate: offered, collapsesAt: now.addingTimeInterval(Self.offerCollapse),
                                     blocked: blocked)
        offer.awaitedProof = Self.waitsOnProof(candidate, request: request, locked: locked)
        phase = .offering(offer)
        return [.silence(candidate.identity), .showOffer(offer), .announce(.offered(candidate.name))]
    }

    private mutating func whileOffering(_ event: Event, offer: ForkMeetingOffer, now: Date) -> [Effect] {
        let candidate = offer.candidate
        switch event {
        case let .candidates(candidates, request):
            guard let current = candidates.first(where: { $0.identity == candidate.identity }),
                  !candidates.contains(where: { !$0.silenced && $0.policy != .never && $0.bornAt > current.bornAt })
            else {
                // Gone, or a newer meeting came: one offer at a time, for the
                // most recent.
                phase = .idle
                return [.hideOffer] + offerOrStart(candidates, request: request, now: now)
            }
            // Offered once "Always" had waited 15 s, unanswered: its proof
            // now (Zoom's meeting window, the microphone 15 s without a
            // break) starts it on its own, "Cancel" at hand.
            if offer.awaitedProof, Self.waitsOnProof(current, request: request, locked: locked),
               current.provesItself(at: now) {
                var proved = offer
                proved.candidate = current
                proved.candidate.silenced = true
                return startOffered(.always, request: request, offer: proved)
            }
            var updated = offer
            updated.candidate = current
            // The set-aside it asked for, read back or not yet; and the
            // microphone's run, which only "Always" waits on, never redraws it.
            updated.candidate.silenced = true
            updated.candidate.microphoneSince = offer.candidate.microphoneSince
            updated.blocked = Self.refusal(request)
            guard updated != offer else { return [] }
            phase = .offering(updated)
            return [.showOffer(updated)]

        case .tick:
            guard !offer.collapsed, now >= offer.collapsesAt else { return [] }
            var folded = offer
            folded.collapsed = true
            phase = .offering(folded)
            return [.collapseOffer]

        case let .accept(request):
            return startOffered(.offered, request: request, offer: offer)

        case let .always(request):
            // Not offered for FaceTime and the other web calls: there it only records.
            guard candidate.alwaysProof != .none else { return startOffered(.offered, request: request, offer: offer) }
            let effects: [Effect] = [.setPolicy(.always, provider: candidate.provider)]
                + startOffered(.always, request: request, offer: offer)
            guard case var .starting(pending) = phase else { return effects }
            // The "Cancel" card says where to change it ("Always for Meet ·
            // Change it in Meetings"); "Cancel" within 5 s takes it back.
            pending.choseAlways = true
            phase = .starting(pending)
            return effects

        case let .manualStart(request):
            // The Record button or the shortcut while an offer shows: a
            // recording by hand (never stopped by the detection), of this
            // meeting.
            guard !terminating else { return [] }
            return startOffered(.manual, request: request, offer: offer)

        case let .dismiss(scope):
            phase = .idle
            switch scope {
            case .thisTime:
                return [.hideOffer, .silence(candidate.identity)]
            case .never:
                // The other web calls share one choice: said for them all,
                // never as if it were Jitsi Meet's alone.
                let said: (ForkMeetingNotice, ForkMeetingAnnouncement) = ForkMeetingOfferText.isOtherWebCall(candidate)
                    ? (.neverOfferedWebCalls, .neverOfferedWebCalls)
                    : (.neverOffered(candidate.providerShortName), .neverOffered(candidate.providerShortName))
                return [.hideOffer, .setPolicy(.never, provider: candidate.provider), .notice(said.0), .announce(said.1)]
            }

        case let .endProbable(identity, _):
            guard identity == candidate.identity else { return [] }
            phase = .idle
            return [.hideOffer]

        case .appWillTerminate, .featureDisabled:
            if case .appWillTerminate = event { terminating = true }
            phase = .idle
            return [.hideOffer]

        case .locked:
            // The lock outlives the offer: a meeting may start on it.
            locked = true
            return []

        case .unlocked:
            // A start from the offer may see the stream's late report of
            // that lock.
            locked = false
            unlockedAt = now
            return []

        // Nothing records: the session's events have nothing to act on.
        case .pause, .resume, .stop, .captureStarted, .captureFailed, .writerFinished, .willSleep, .didWake,
             .diskLow, .diskCritical, .permissionLost, .displayChanged, .microphoneChanged, .microphoneSilent,
             .microphoneSoundBack, .soundHeard, .toggleTarget, .targetSwitched, .sourceGone, .soundLost,
             .cancelAutoStart, .continueRecording:
            return []
        }
    }

    /// "Always" would start it on its own but for its proof: set to it,
    /// the start not refused, the screen not locked, its app on the
    /// microphone, and a proof of its own to wait for (a meeting window, or
    /// the microphone for 15 s).
    private static func waitsOnProof(_ candidate: ForkMeetingCandidate, request: ForkMeetingStartRequest,
                                    locked: Bool) -> Bool {
        candidate.policy == .always && refusal(request) == nil && !locked
            && request.facts.meetingsOnMicrophone.contains(candidate.identity)
            && [.meetingWindow, .longMicrophone].contains(candidate.alwaysProof)
    }

    /// Starts the offered meeting; a refused start leaves the offer up,
    /// with the refusal said.
    private mutating func startOffered(_ origin: ForkMeetingOrigin, request: ForkMeetingStartRequest,
                                       offer: ForkMeetingOffer) -> [Effect] {
        let effects = start(origin: origin, request: request, meeting: offer.candidate)
        guard case .starting = phase else { return effects }
        return [.hideOffer] + effects
    }

    /// The countdown runs over a recording: every event acts as it would
    /// on that recording, and one that leaves it takes the countdown away.
    private mutating func whileEndingSoon(_ event: Event, session: Session, until: Date, now: Date) -> [Effect] {
        switch event {
        case .continueRecording:
            var kept = session
            kept.meetingGone = false
            phase = .recording(kept)
            return [.hideEndingSoon, .announce(.continued)]
        case let .candidates(candidates, _):
            // Its meeting is back (the microphone again, the tab again).
            guard candidates.contains(where: { $0.identity == session.meeting }) else { return [] }
            var back = session
            back.meetingGone = false
            phase = .recording(back)
            return [.hideEndingSoon, .announce(.meetingBack)]
        case .endProbable:
            return []
        case .tick where now >= until:
            phase = .recording(session)
            return [.hideEndingSoon] + stop(session, reason: .meetingEnded, now: now)
        default:
            phase = .recording(session)
            let effects = handleSession(event, now: now)
            guard case let .recording(updated) = phase else { return [.hideEndingSoon] + effects }
            phase = .endingSoon(updated, until: until)
            return effects
        }
    }

    private mutating func beginCountdown(_ session: Session, countdown: TimeInterval, now: Date) -> [Effect] {
        let until = now.addingTimeInterval(countdown)
        phase = .endingSoon(session, until: until)
        return [.showEndingSoon(until: until), .announce(.endingSoon(seconds: Int(countdown.rounded())))]
    }

    /// "Cancel" after a start "Always" made: the file closes, then its
    /// folder goes. Nothing is finalized, nothing kept. `meeting.json` says
    /// it first: should the app end before the folder goes, the next launch
    /// throws it away rather than recover it.
    private mutating func discard(_ session: Session, now: Date) -> [Effect] {
        var session = session
        session.discarded = true
        session.undoUntil = nil
        session.recordedBefore = session.recorded(at: now)
        session.runningSince = nil
        session.stoppedAt = now
        let askedAgain = Self.askAgain(session.choseAlways, session.config.meeting)
        if !askedAgain.isEmpty { session.askedAgain = session.config.meeting.map(ForkMeetingOfferText.reminderTitle) }
        phase = .stopping(session, .user)
        let cancelled = ForkMeetingSidecarPatch(state: .interrupted, stopReason: .cancelled)
        return [.hideUndo, .writeSidecar(session.folder, cancelled), .stopCapture(session.token), .showPill(.stopping),
                .announce(.discarded)] + askedAgain
    }

    /// "Cancel" right after "Always" was chosen in the offer: the choice
    /// is taken back, its meetings are offered again.
    private static func askAgain(_ choseAlways: Bool, _ meeting: ForkMeetingCandidate?) -> [Effect] {
        guard choseAlways, let provider = meeting?.provider else { return [] }
        return [.setPolicy(.ask, provider: provider)]
    }

    // MARK: - Transitions

    private mutating func start(origin: ForkMeetingOrigin, request: ForkMeetingStartRequest,
                                meeting: ForkMeetingCandidate? = nil) -> [Effect] {
        if let refusal = Self.refusal(request) {
            return [.notice(.failure(refusal)), .announce(.failure(refusal))]
        }
        let wantsMicrophone = request.settings.microphone != ForkMeetingCaptureSettings.microphoneOff
        // A meeting recorded is set aside: once stopped, it is not offered again.
        var meeting = meeting
        meeting?.silenced = true
        let config = ForkMeetingCaptureConfig(origin: origin, title: request.title ?? meeting?.name,
                                              settings: request.settings,
                                              recordsMicrophone: wantsMicrophone && request.facts.microphoneAllowed,
                                              microphoneDenied: wantsMicrophone && !request.facts.microphoneAllowed,
                                              meeting: meeting)
        lastToken += 1
        let token = ForkMeetingToken(value: lastToken)
        phase = .starting(Pending(token: token, config: config))
        return [.startCapture(config, token)]
    }

    /// Why a meeting may not start, checked in this order: nothing can be
    /// filmed (never asked of a meeting without picture), the official
    /// recorder holds the screen, no room.
    static func refusal(_ request: ForkMeetingStartRequest) -> ForkMeetingFailure? {
        let facts = request.facts
        if request.settings.target.filmsPicture, !facts.screenRecordingAllowed { return .screenRecordingDenied }
        if facts.officialRecorderBusy { return .officialRecorderBusy }
        guard let freeBytes = facts.freeBytes else { return .folderUnavailable }
        let required = ForkMeetingDisk.requiredToStart(request.settings.quality)
        return freeBytes < required ? .diskFullAtStart(requiredBytes: required) : nil
    }

    /// Nothing was recorded yet: nothing to keep, nothing to finalize.
    private mutating func cancel(_ pending: Pending) -> [Effect] {
        phase = .idle
        return [.stopCapture(pending.token), .showPill(.hidden)]
    }

    private mutating func resume(_ session: Session, now: Date, automatic: Bool) -> [Effect] {
        var session = session
        let pause = session.endPause(at: now)
        let restart = session.streamNeedsRestart
        session.streamNeedsRestart = false
        phase = .recording(session)
        var effects: [Effect] = restart ? [.restartStream, .resumeCapture] : [.resumeCapture]
        if let pause { effects.append(.writeSidecar(session.folder, ForkMeetingSidecarPatch(pause: pause))) }
        effects.append(.showPill(pill(session, paused: nil)))
        if automatic { effects.append(.notice(.resumed)) }
        effects.append(.announce(.resumed))
        // Its meeting ended meanwhile: the countdown starts again.
        if session.meetingGone, let countdown = session.endCountdown {
            effects += beginCountdown(session, countdown: countdown, now: now)
        }
        return effects
    }

    private mutating func stop(_ session: Session, reason: ForkMeetingStopReason, now: Date,
                               announcing: Bool = true) -> [Effect] {
        var session = session
        var patch = ForkMeetingSidecarPatch(stopReason: reason)
        patch.pause = session.endPause(at: now)
        patch.gap = session.endLock(at: now)
        session.recordedBefore = session.recorded(at: now)
        session.runningSince = nil
        session.stoppedAt = now
        phase = .stopping(session, reason)
        let effects: [Effect] = [.stopCapture(session.token), .writeSidecar(session.folder, patch), .showPill(.stopping)]
        return announcing ? effects + [.announce(.stopped)] : effects
    }

    /// A stop nobody asked for: said in the island, in a notification when
    /// the app is behind, and to VoiceOver. The file is kept and finalized.
    private mutating func stopForFailure(_ session: Session, _ failure: ForkMeetingFailure, now: Date) -> [Effect] {
        let reason: ForkMeetingStopReason
        switch failure {
        case .screenRecordingRevoked, .screenRecordingDenied: reason = .permission
        case .diskFull: reason = .disk
        default: reason = .captureStopped
        }
        return stop(session, reason: reason, now: now, announcing: false)
            + [.notice(.failure(failure)), .notify(.failure(failure)), .announce(.failure(failure))]
    }

    private mutating func finish(_ session: Session, result: ForkMeetingWriterResult) -> [Effect] {
        phase = .idle
        // Cancelled: closed or not, the folder goes, once.
        guard !session.discarded else {
            guard !session.discardSaid else { return [.showPill(.hidden)] }
            return [.discard(session.folder, askedAgain: session.askedAgain), .showPill(.hidden)]
        }
        switch result {
        case let .finished(recordedSeconds):
            var patch = ForkMeetingSidecarPatch(endedAt: session.stoppedAt,
                                                recordedSeconds: recordedSeconds ?? session.recordedBefore)
            // Quitting: no final pass now, the next launch recovers the
            // meeting from its master, which `interrupted` points it to.
            guard !terminating else { return [.writeSidecar(session.folder, patch), .showPill(.hidden)] }
            patch.state = .finalizing
            return [.writeSidecar(session.folder, patch), .beginFinalize(session.folder), .showPill(.finalizing)]
        case let .failed(failure):
            // No end time: a missing end is how the library knows.
            let patch = ForkMeetingSidecarPatch(state: .interrupted)
            guard !terminating else { return [.writeSidecar(session.folder, patch)] }
            return [.writeSidecar(session.folder, patch), .showPill(.hidden), .notice(.failure(failure)),
                    .notify(.failure(failure)), .announce(.failure(failure))]
        }
    }

    /// Stores a changed session in its phase and shows it.
    private mutating func update(_ session: Session) -> [Effect] {
        replace(session)
        switch phase {
        case .recording, .endingSoon: return [.showPill(pill(session, paused: nil))]
        case let .paused(_, reason): return [.showPill(pill(session, paused: reason))]
        case .idle, .offering, .starting, .stopping: return []
        }
    }

    private mutating func replace(_ session: Session) {
        switch phase {
        case .recording: phase = .recording(session)
        case let .paused(_, reason): phase = .paused(session, reason)
        case let .endingSoon(_, until): phase = .endingSoon(session, until: until)
        case .idle, .offering, .starting, .stopping: break
        }
    }

    private func pill(_ session: Session, paused: ForkMeetingPauseReason?) -> ForkMeetingPillState {
        guard let paused else { return .recording(session.clock, diskMinutesLeft: session.diskMinutesLeft) }
        return .paused(session.clock, paused, diskMinutesLeft: session.diskMinutesLeft)
    }
}
