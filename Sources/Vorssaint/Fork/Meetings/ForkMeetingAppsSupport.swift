// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What a detected meeting of an app (Zoom, Teams, FaceTime…) is filmed and
/// heard with, kept apart so each choice is tested.
enum ForkMeetingAppsSupport {
    /// The window a detected meeting is filmed in: the one its title points
    /// at; else its app's ordinary window most in front (a meeting app found
    /// by its microphone alone), in the window scanner's list (`windows`,
    /// `.optionAll`: on screen front to back, then minimized or on another
    /// Space, which only counts with a title: an app's spare windows never
    /// shown have none); `nil` films its display, and the offer says "Whole
    /// screen". Never another app's window in front: that one is no part of
    /// the meeting.
    static func window(for meeting: ForkMeetingCandidate, in windows: [ForkMeetingWindowCandidate], ownPID: Int32,
                       excluded: Set<UInt32> = []) -> UInt32? {
        if let windowID = meeting.windowID { return windowID }
        let side = ForkMeetingCaptureSupport.minimumWindowSide
        return windows.first { window in
            window.pid == meeting.pid && window.pid != ownPID && window.layer == 0 && window.alpha > 0.05
                && (window.onScreen || window.titled) && !excluded.contains(window.id)
                && window.bounds.width >= side && window.bounds.height >= side
        }?.id
    }

    /// The process whose sound is the meeting's: its app's. A web app's
    /// window belongs to a small process of its own while the browser plays
    /// its sound (`com.google.Chrome.app.<id>` and Chrome): the browser then,
    /// when one copy of it runs (`running`: its pids); `nil` leaves it to the
    /// filmed window's app.
    static func soundPID(for meeting: ForkMeetingCandidate, running: [Int32]) -> Int32? {
        guard let windowBundle = meeting.windowBundle, windowBundle != meeting.appBundle else { return meeting.pid }
        return running.count == 1 ? running[0] : nil
    }

    /// FaceTime's calls play in a system process: only the whole Mac hears
    /// them, and a window's sound never stands in for them.
    static func soundOutsideApp(_ meeting: ForkMeetingCandidate) -> Bool {
        meeting.defaultSound == .all
    }

    // MARK: Fixes K

    /// The name a meeting app goes by in the offer and the pill: its brand
    /// ("Zoom"), never its process's ("zoom.us"); `nil` for a meeting in a
    /// browser, which goes by the browser's. `meeting.json` keeps the bundle.
    static func appName(for meeting: ForkMeetingCandidate?,
                        table: ForkMeetingProviderTable = .current) -> String? {
        guard let meeting, table.provider(id: meeting.provider)?.kind == .app else { return nil }
        return meeting.providerName
    }
}
