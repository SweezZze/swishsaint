// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// "Mark This Moment": the pill's ★, the island's live card and the
/// shortcut all come here. The time is the file's own (the engine's pause
/// clock, pauses left out), so the marker points at the same instant of the
/// video; it goes into `meeting.json` at once, like a gap, so a crash keeps
/// it with the meeting it recovers.
extension ForkMeetingService {
    /// Main thread. `false` when nothing records (nothing to mark), or when
    /// the press is the same moment as the last one (`mergeWindow`): that
    /// one is shown again, nothing new is written.
    @discardableResult
    func addMarker() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isWanted, let session = machine.activeSession else { return false }
        let recorded = activeRecorder?.recordedSeconds ?? session.recorded(at: Date())
        let time = ForkMeetingMarkers.time(recorded: recorded)
        let book = ForkMeetingMarkerBook.shared
        let added = book.mark(time, in: session.token)
        if added {
            store.update(session.folder, with: ForkMeetingSidecarPatch(marker: ForkMeetingSidecar.Marker(at: time)))
            log.notice("moment marked at \(time, privacy: .public) s")
        }
        let shown = added ? time : (book.nearest(to: time, in: session.token) ?? time)
        let clock = ForkMeetingMarkers.clock(shown)
        presenter.notice(.marked, detail: clock)
        presenter.say(ForkMeetingStrings.current.voiceMarked(clock))
        return added
    }
}

/// The moments marked in the recording under way, for the merge of a
/// double press. Only the current session's: a new one starts empty. Main
/// thread only.
final class ForkMeetingMarkerBook {
    static let shared = ForkMeetingMarkerBook()

    private var token: ForkMeetingToken?
    private var times: [Double] = []

    /// Notes `time` for `token`, unless it is the same moment as one already
    /// marked there.
    func mark(_ time: Double, in token: ForkMeetingToken) -> Bool {
        if self.token != token {
            self.token = token
            times = []
        }
        guard ForkMeetingMarkers.isNew(time, after: times) else { return false }
        times.append(time)
        return true
    }

    func nearest(to time: Double, in token: ForkMeetingToken) -> Double? {
        guard self.token == token else { return nil }
        return times.min { abs($0 - time) < abs($1 - time) }
    }
}
