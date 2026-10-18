// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The service's own small decisions, kept apart from it so each is tested:
/// when a meeting may start, what the shortcut does, what the pill keeps
/// showing, where a notice may go, when the filmed display really changed,
/// how awake the Mac stays, and how the picture is named.
enum ForkMeetingServiceSupport {
    // MARK: Starting

    /// A meeting may start whenever none is starting or recording. The final
    /// pass of the one before, or a meeting recovered at launch, never stands
    /// in the way (§3.2 n° 44): they live outside the session. The fork's
    /// updater waits on more (`ForkMeetingActivity`), the finalizer included.
    static func canStart(wanted: Bool, machineBusy: Bool, preparingStart: Bool, terminating: Bool) -> Bool {
        wanted && !machineBusy && !preparingStart && !terminating
    }

    /// What one press of the shortcut does.
    enum Press: Equatable {
        case start
        case stop
        /// Pressed again while the start is under way: nothing is recorded,
        /// no folder stays.
        case cancelStart
        case ignore
    }

    static func press(phase: ForkMeetingMachine.Phase, preparingStart: Bool, canStart: Bool) -> Press {
        if preparingStart { return .cancelStart }
        switch phase {
        case .starting: return .cancelStart
        case .recording, .paused: return .stop
        // The file is closing: a second stop has nothing to stop, and a
        // start waits for the machine to be free.
        case .stopping: return .ignore
        case .idle: return canStart ? .start : .ignore
        }
    }

    // MARK: The pill

    /// The pill the machine asks for, unless it asks to hide it while a
    /// session's final pass still runs: the gauge stays until that meeting
    /// is saved.
    static func pill(_ asked: ForkMeetingPillState, finalizing: Bool) -> ForkMeetingPillState {
        asked == .hidden && finalizing ? .finalizing : asked
    }

    /// Whether the pill on its gauge may go: no final pass of a session left,
    /// and no session starting, recording or closing its file.
    static func hidesFinishedPill(machineIdle: Bool, finalizingCount: Int, pill: ForkMeetingPillState) -> Bool {
        machineIdle && finalizingCount == 0 && pill == .finalizing
    }

    // MARK: Words

    /// A system notification only when nothing on the screen could say it:
    /// the island refused, and the bubble had no display to show on (the
    /// session locked, the displays asleep). Like the official watch notice.
    static func notifies(shownInIsland: Bool, shownInBubble: Bool, canNotify: Bool) -> Bool {
        canNotify && !shownInIsland && !shownInBubble
    }

    /// What the picture is, in a few words: the start's second line, the
    /// pill under the pointer, VoiceOver. A window asked for and none to
    /// film says so.
    static func filmed(target: ForkMeetingCaptureTarget, appName: String?, noWindowToFilm: Bool,
                       strings: ForkMeetingStrings) -> String {
        switch target {
        case .window:
            guard let appName = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty else {
                return strings.filmedWindowUnnamed
            }
            return strings.filmedWindow(appName)
        case .display:
            return noWindowToFilm ? strings.filmedNoWindow : strings.filmedDisplay
        }
    }

    // MARK: The Mac

    /// Whether the display being filmed went away, or the window it follows
    /// now lies on another one: only then is "Display changed" said. A
    /// display plugged in or out elsewhere changes nothing in the picture.
    ///
    /// - Parameters:
    ///   - filmed: the display filmed so far; `nil` when unknown, which says
    ///     nothing.
    ///   - holdingNow: the display the filmed window is on now, `nil` without
    ///     a window.
    ///   - active: the displays there are now.
    static func filmedDisplayChanged(filmed: UInt32?, holdingNow: UInt32?, active: [UInt32]) -> Bool {
        guard let filmed else { return false }
        if !active.contains(filmed) { return true }
        if let holdingNow { return holdingNow != filmed }
        return false
    }

    /// How awake the Mac is kept.
    enum Awake: Equatable {
        /// Nothing held.
        case free
        /// The app stays awake, the Mac may still dim, lock and sleep.
        case app
        /// The display stays on: a meeting listened to without touching the
        /// Mac must not lock it (decision "locked screen").
        case display
    }

    /// Only a running recording keeps the display on. Paused by the person,
    /// the Mac may turn its display off and lock, however long the pause; a
    /// start or a stop under way keeps the app from dozing off.
    static func awake(phase: ForkMeetingMachine.Phase) -> Awake {
        switch phase {
        case .idle: return .free
        case .recording: return .display
        case .starting, .paused, .stopping: return .app
        }
    }

    // MARK: Fixes G1

    /// What the Meetings page says of the permission to record other apps'
    /// sound, which macOS has no call to read: what the last recording
    /// found (`fork.meetings.systemAudioVerified`, absent until one judged),
    /// or the banner of a recording that found it missing.
    enum SystemAudioPermission: Equatable {
        case allowed
        case missing
        case unknown
    }

    static func systemAudioPermission(verified: Bool?, failing: Bool) -> SystemAudioPermission {
        if failing || verified == false { return .missing }
        return verified == true ? .allowed : .unknown
    }
}

/// The engine's verdicts on the system audio permission that arrive while
/// their session is still starting (the witness may settle before the
/// microphone is up): held by token, and said once the machine records it,
/// never dropped, never said for a start that failed.
struct ForkMeetingPendingVerdicts: Equatable {
    enum Verdict: Equatable {
        case allowed
        case missing
    }

    /// Where a verdict goes, from the phase of the machine.
    enum Route: Equatable {
        case now
        case hold
        case drop
    }

    static func route(_ token: ForkMeetingToken, phase: ForkMeetingMachine.Phase) -> Route {
        switch phase {
        case let .starting(pending): return pending.token == token ? .hold : .drop
        case let .recording(session), let .paused(session, _): return session.token == token ? .now : .drop
        case .idle, .stopping: return .drop
        }
    }

    private var held: [ForkMeetingToken: Verdict] = [:]

    /// A verdict is final for its recording: the first one stays.
    mutating func hold(_ verdict: Verdict, for token: ForkMeetingToken) {
        if held[token] == nil { held[token] = verdict }
    }

    /// The verdict to say now that the session records, once.
    mutating func take(_ token: ForkMeetingToken) -> Verdict? {
        held.removeValue(forKey: token)
    }
}
