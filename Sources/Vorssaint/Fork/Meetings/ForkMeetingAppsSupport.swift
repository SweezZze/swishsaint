// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What a detected meeting of an app (Zoom, Teams, FaceTime…) is filmed and
/// heard with, kept apart so each choice is tested.
enum ForkMeetingAppsSupport {
    /// The window a detected meeting is filmed in: the one its title points
    /// at; else the largest ordinary window of its app (a meeting app found
    /// by its microphone alone); `nil` films its display. Never another
    /// app's window in front: that one is no part of the meeting.
    static func window(for meeting: ForkMeetingCandidate, in windows: [ForkMeetingWindowCandidate], ownPID: Int32,
                       excluded: Set<UInt32> = []) -> UInt32? {
        if let windowID = meeting.windowID { return windowID }
        let side = ForkMeetingCaptureSupport.minimumWindowSide
        let own = windows.filter { window in
            window.pid == meeting.pid && window.pid != ownPID && window.layer == 0 && window.alpha > 0.05
                && !excluded.contains(window.id) && window.bounds.width >= side && window.bounds.height >= side
        }
        // The first of two equal ones: the window list goes front to back.
        var best: ForkMeetingWindowCandidate?
        for window in own where window.bounds.width * window.bounds.height
            > (best.map { $0.bounds.width * $0.bounds.height } ?? 0) {
            best = window
        }
        return best?.id
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
}
