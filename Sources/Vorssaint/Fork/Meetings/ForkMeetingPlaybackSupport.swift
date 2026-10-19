// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The detail's review of a meeting, as Loom and Tella do it: the transcript
/// beside the player, its line under way lit and kept in sight while the
/// video plays, a click on a line plays from there, the marked moments
/// among the lines, and the speed.
///
/// The lines are the `.srt`'s cues: each at most 6 s and two lines of a
/// player (`ForkMeetingTranscriptFormat.cues`), short enough to follow the
/// voice, with the speaker's label they were written with.
enum ForkMeetingPlayback {
    /// The speeds offered, the first the normal one.
    static let speeds: [Float] = [1, 1.5, 2]

    /// "1×", "1.5×", "1,5×": the speed as the language writes its numbers.
    static func speedLabel(_ speed: Float, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return (formatter.string(from: NSNumber(value: speed)) ?? "\(speed)") + "×"
    }

    /// The next speed of the button, around the list.
    static func nextSpeed(after speed: Float) -> Float {
        guard let index = speeds.firstIndex(where: { abs($0 - speed) < 0.01 }) else { return speeds[0] }
        return speeds[(index + 1) % speeds.count]
    }

    struct Cue: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    /// The cues of a SubRip file, sorted by start. A block that does not
    /// read (no time line, times backwards) is skipped, never guessed;
    /// Windows line ends and a byte-order mark are fine.
    static func cues(srt: String) -> [Cue] {
        let normalized = srt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let sides = lines[timing].components(separatedBy: "-->")
            guard sides.count == 2, let start = seconds(sides[0]), let end = seconds(sides[1]), end >= start else { continue }
            let text = lines[(timing + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: text))
        }
        return cues.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    /// `00:01:05,250` (or with a dot) in seconds.
    static func seconds(_ stamp: String) -> TimeInterval? {
        let trimmed = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]),
              let secs = Double(parts[2]), hours >= 0, minutes >= 0, secs >= 0 else { return nil }
        return hours * 3600 + minutes * 60 + secs
    }

    /// One row of the review: a line of the transcript, or a marked moment.
    enum Row: Equatable {
        case cue(Cue)
        case marker(Double)

        var time: TimeInterval {
            switch self {
            case let .cue(cue): return cue.start
            case let .marker(time): return time
            }
        }
    }

    /// The lines and the markers, by time; a marker before the line that
    /// starts with it.
    static func rows(cues: [Cue], markers: [Double]) -> [Row] {
        let all = cues.map { Row.cue($0) } + markers.map { Row.marker($0) }
        return all.enumerated().sorted { one, other in
            if one.element.time != other.element.time { return one.element.time < other.element.time }
            if case .marker = one.element, case .cue = other.element { return true }
            if case .cue = one.element, case .marker = other.element { return false }
            return one.offset < other.offset
        }.map(\.element)
    }

    /// The row lit at `time`: the last line that started, while it is said
    /// or for `hold` seconds after (a pause between two lines keeps the last
    /// one lit); `nil` before the first line, or in a long silence. Rows
    /// sorted by time.
    static func current(_ rows: [Row], at time: TimeInterval, hold: TimeInterval = 3) -> Int? {
        var low = 0, high = rows.count
        // The first row starting after `time`.
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        while index >= 0 {
            if case let .cue(cue) = rows[index] {
                return time <= max(cue.end, cue.start) + hold ? index : nil
            }
            index -= 1
        }
        return nil
    }

    /// The transcript as copied: the `.txt` as it is, which keeps the
    /// speakers, the times and the `★` lines.
    static func copiedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
