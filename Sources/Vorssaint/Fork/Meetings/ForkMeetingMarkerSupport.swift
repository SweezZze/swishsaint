// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The moments marked while recording ("Mark This Moment"): one press, one
/// time in `meeting.json`'s `markers`, in seconds of recording with the
/// pauses left out, so a marker points at the same instant of the video
/// whatever was paused before it.
///
/// They come back after the meeting, where a review needs them: on the
/// player's strip and in the detail's list (a click plays from there), in
/// the transcript (`★ [00:12:03]`), and in what an export sends.
enum ForkMeetingMarkers {
    /// A second press this close to the last one marks nothing new: a
    /// double click, or a shortcut held, is one moment.
    static let mergeWindow: TimeInterval = 2
    /// Marked a little before what made the person press: the strip and the
    /// list play from this much earlier, so the moment is heard whole.
    static let lead: TimeInterval = 3

    /// The time written for a press: tenths of a second, never negative.
    static func time(recorded: TimeInterval) -> Double {
        guard recorded.isFinite else { return 0 }
        return (max(0, recorded) * 10).rounded() / 10
    }

    /// Whether a marker gets its notice in the island (or the bubble). Not
    /// while the live card is up there: its button says "Marked" itself,
    /// and a notice would push the card aside.
    static func showsNotice(liveCardShown: Bool) -> Bool { !liveCardShown }

    /// Whether a press at `time` is a new moment after the ones already
    /// marked in this recording.
    static func isNew(_ time: Double, after marked: [Double]) -> Bool {
        !marked.contains { abs($0 - time) < mergeWindow }
    }

    /// The times a meeting's markers hold, sorted: one whose time cannot be
    /// read (missing, negative, not a number) is left out, never guessed;
    /// two within `mergeWindow` are one.
    static func times(_ markers: [ForkMeetingSidecar.Marker]?) -> [Double] {
        let read = (markers ?? []).compactMap(\.at).filter { $0.isFinite && $0 >= 0 }.sorted()
        var kept: [Double] = []
        for time in read where kept.last.map({ time - $0 >= mergeWindow }) ?? true {
            kept.append(time)
        }
        return kept
    }

    /// Where the player starts for a marker: `lead` before it.
    static func playFrom(_ time: Double) -> Double { max(0, time - lead) }

    /// `00:12:03`, as the transcript's paragraphs write their times.
    static func clock(_ time: Double) -> String {
        ForkMeetingTranscriptFormat.timestamp(time, milliseconds: false)
    }

    /// The transcript's line for a marker: a star and its time, the same in
    /// every language, so a search or a script finds it.
    static func transcriptLine(_ time: Double) -> String { "★ [\(clock(time))]" }

    /// A marker's place on the player's strip, 0…1; `nil` without a length
    /// to place it on.
    static func fraction(_ time: Double, duration: Double?) -> Double? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return min(1, max(0, time / duration))
    }
}
