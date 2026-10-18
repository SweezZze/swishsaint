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
        }
    }

    /// The second line, when the notice has one. The finalizer adds its
    /// own (length and size) to the saved and recovered notices.
    func detail(_ s: ForkMeetingStrings) -> String? {
        switch self {
        case let .microphone(name): return name
        case let .diskLow(minutes): return s.diskMinutes(minutes)
        case .neverOffered: return s.noticeNeverDetail
        case .started, .resumed, .saved, .recovered, .microphoneSilent, .displayChanged, .sourceGone, .failure,
             .soundLost:
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
    /// "Always" started it; `seconds` left to cancel it.
    case autoStarted(seconds: Int)
    case endingSoon(seconds: Int)
    case continued
    case discarded
    case neverOffered(String)

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
        case let .autoStarted(seconds): return s.voiceAutoStarted(seconds: seconds)
        case let .endingSoon(seconds): return s.voiceEndingSoon(seconds: seconds)
        case .continued: return s.voiceContinued
        case .discarded: return s.voiceDiscarded
        case let .neverOffered(provider): return s.voiceNever(provider)
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
/// - a recording "Always" started can be cancelled for 5 s: its folder is
///   deleted, never finalized.
struct ForkMeetingMachine {
    /// An unanswered offer folds after this long.
    static let offerCollapse: TimeInterval = 20
    /// How long "Cancel" deletes a recording "Always" started.
    static let undoWindow: TimeInterval = 5

    /// A start asked, the capture not running yet.
    struct Pending: Equatable {
        let token: ForkMeetingToken
        let config: ForkMeetingCaptureConfig

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
        /// Until when "Cancel" deletes a recording "Always" started.
        var undoUntil: Date?
        /// Cancelled: its folder goes once the file is closed.
        var discarded = false
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
        /// Deletes a cancelled recording's folder, once its file is closed.
        case discard(URL)
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
            return start(origin: .manual, request: request)

        case let .captureStarted(token, folder, target, microphone, systemAudio, startedAt):
            guard case let .starting(pending) = phase, pending.token == token else { return [] }
            let setting = pending.config.settings.target
            let zero = min(startedAt ?? now, now)
            var session = Session(token: token, config: pending.config, folder: folder, startedAt: zero,
                                  target: target ?? setting, runningSince: zero)
            if locked { session.lockedAt = 0 }
            let denied = pending.config.microphoneDenied
            var effects: [Effect] = [.showPill(pill(session, paused: nil))]
            if pending.origin == .always {
                // Started on its own: "Recording started · Cancel (5 s)"
                // stands in for the start notice.
                session.undoUntil = now.addingTimeInterval(Self.undoWindow)
                if denied { effects.append(.notice(.failure(.microphoneDenied))) }
                effects += [.showUndo(until: now.addingTimeInterval(Self.undoWindow)),
                            .announce(.autoStarted(seconds: Int(Self.undoWindow)))]
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
            // lock becomes a gap once its length is known.
            guard var session = activeSession, session.lockedAt == nil else { return [] }
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
            switch ForkMeetingDisk.level(freeBytes: freeBytes, quality: session.config.settings.quality) {
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
            // filmed again).
            guard let session = activeSession else { return [] }
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
            case let .stopping(session, _):
                // A cancelled recording is not to be recovered at the next launch.
                guard !session.discarded else { return [.discard(session.folder)] }
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
            if case let .starting(pending) = phase, pending.origin == .always { return cancel(pending) }
            guard let session = activeSession, let until = session.undoUntil, now < until else { return [] }
            return discard(session, now: now)

        case let .endProbable(identity, countdown):
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
    /// when its provider is set to "Always" and nothing refuses the start.
    private mutating func offerOrStart(_ candidates: [ForkMeetingCandidate], request: ForkMeetingStartRequest,
                                       now: Date) -> [Effect] {
        guard !terminating, let candidate = candidates.first(where: { !$0.silenced && $0.policy != .never }) else {
            return []
        }
        let blocked = Self.refusal(request)
        if candidate.policy == .always, blocked == nil {
            return [.silence(candidate.identity)] + start(origin: .always, request: request, meeting: candidate)
        }
        // Set aside as soon as it is offered: coming back to its tab, or
        // leaving and rejoining within 10 minutes, offers nothing new.
        var offered = candidate
        offered.silenced = true
        let offer = ForkMeetingOffer(candidate: offered, collapsesAt: now.addingTimeInterval(Self.offerCollapse),
                                     blocked: blocked)
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
            var updated = offer
            updated.candidate = current
            // The set-aside it asked for, read back or not yet.
            updated.candidate.silenced = true
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
            return [.setPolicy(.always, provider: candidate.provider)]
                + startOffered(.always, request: request, offer: offer)

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
                return [.hideOffer, .setPolicy(.never, provider: candidate.provider),
                        .notice(.neverOffered(candidate.providerShortName)),
                        .announce(.neverOffered(candidate.providerShortName))]
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
            locked = false
            return []

        // Nothing records: the session's events have nothing to act on.
        case .pause, .resume, .stop, .captureStarted, .captureFailed, .writerFinished, .willSleep, .didWake,
             .diskLow, .diskCritical, .permissionLost, .displayChanged, .microphoneChanged, .microphoneSilent,
             .microphoneSoundBack, .soundHeard, .toggleTarget, .targetSwitched, .sourceGone, .soundLost,
             .cancelAutoStart, .continueRecording:
            return []
        }
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
            return [.hideEndingSoon]
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
    /// folder goes. Nothing is finalized, nothing kept.
    private mutating func discard(_ session: Session, now: Date) -> [Effect] {
        var session = session
        session.discarded = true
        session.undoUntil = nil
        session.recordedBefore = session.recorded(at: now)
        session.runningSince = nil
        session.stoppedAt = now
        phase = .stopping(session, .user)
        return [.hideUndo, .stopCapture(session.token), .showPill(.stopping), .announce(.discarded)]
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
    /// filmed, the official recorder holds the screen, no room.
    static func refusal(_ request: ForkMeetingStartRequest) -> ForkMeetingFailure? {
        let facts = request.facts
        if !facts.screenRecordingAllowed { return .screenRecordingDenied }
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
        // Cancelled: closed or not, the folder goes.
        guard !session.discarded else { return [.discard(session.folder), .showPill(.hidden)] }
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
