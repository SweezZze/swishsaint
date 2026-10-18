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
        }
    }

    /// The second line, when the notice has one. The finalizer adds its
    /// own (length and size) to the saved and recovered notices.
    func detail(_ s: ForkMeetingStrings) -> String? {
        switch self {
        case let .microphone(name): return name
        case let .diskLow(minutes): return s.diskMinutes(minutes)
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
        }
    }
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
struct ForkMeetingMachine {
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

        var origin: ForkMeetingOrigin { config.origin }

        /// Whether a meeting that ends may end the recording: never one
        /// started by hand.
        var endsWithMeeting: Bool { origin != .manual }

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
        case starting(Pending)
        case recording(Session)
        case paused(Session, ForkMeetingPauseReason)
        /// The capture is stopping and the file closing; the session waits
        /// for `writerFinished`.
        case stopping(Session, ForkMeetingStopReason)
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

    var isBusy: Bool { phase != .idle }

    /// The session recording or paused, if any.
    var activeSession: Session? {
        switch phase {
        case let .recording(session), let .paused(session, _): return session
        case .idle, .starting, .stopping: return nil
        }
    }

    @discardableResult
    mutating func handle(_ event: Event, now: Date) -> [Effect] {
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
            phase = .recording(session)
            let denied = pending.config.microphoneDenied
            let notice: ForkMeetingNotice = denied ? .failure(.microphoneDenied) : .started
            var effects: [Effect] = [.showPill(pill(session, paused: nil)), .notice(notice),
                                     .announce(denied ? .startedWithoutMicrophone : .started)]
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
            case .idle, .stopping:
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
            guard let session = activeSession, session.token == token else { return [] }
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
                return [.writeSidecar(session.folder, ForkMeetingSidecarPatch(state: .interrupted))]
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
        }
    }

    // MARK: - Transitions

    private mutating func start(origin: ForkMeetingOrigin, request: ForkMeetingStartRequest) -> [Effect] {
        if let refusal = Self.refusal(request) {
            return [.notice(.failure(refusal)), .announce(.failure(refusal))]
        }
        let wantsMicrophone = request.settings.microphone != ForkMeetingCaptureSettings.microphoneOff
        let config = ForkMeetingCaptureConfig(origin: origin, title: request.title, settings: request.settings,
                                              recordsMicrophone: wantsMicrophone && request.facts.microphoneAllowed,
                                              microphoneDenied: wantsMicrophone && !request.facts.microphoneAllowed)
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
        case .recording: return [.showPill(pill(session, paused: nil))]
        case let .paused(_, reason): return [.showPill(pill(session, paused: reason))]
        case .idle, .starting, .stopping: return []
        }
    }

    private mutating func replace(_ session: Session) {
        switch phase {
        case .recording: phase = .recording(session)
        case let .paused(_, reason): phase = .paused(session, reason)
        case .idle, .starting, .stopping: break
        }
    }

    private func pill(_ session: Session, paused: ForkMeetingPauseReason?) -> ForkMeetingPillState {
        guard let paused else { return .recording(session.clock, diskMinutesLeft: session.diskMinutesLeft) }
        return .paused(session.clock, paused, diskMinutesLeft: session.diskMinutesLeft)
    }
}
