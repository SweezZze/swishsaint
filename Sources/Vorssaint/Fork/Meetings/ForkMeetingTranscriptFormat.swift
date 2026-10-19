// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Who said a word: the "Microphone" track is the person ("Me"), the
/// "Meeting" track everyone else ("Participants"). Two tracks transcribed
/// apart tell the two sides without any diarization (plan §10).
enum ForkMeetingSpeaker: String, CaseIterable {
    case me
    case participants
}

// MARK: - Energy

/// The energy of a track, 10 ms at a time, built as its samples are read for
/// the transcription (an hour is 360 000 floats, 1.4 MB): what the echo
/// filter compares between the two tracks.
struct ForkMeetingEnvelope: Equatable {
    /// 10 ms of 16 kHz samples.
    static let hop = 160
    static let hopSeconds = 0.01
    private(set) var meanSquares: [Float] = []
    private var sum: Float = 0
    private var filled = 0

    init(meanSquares: [Float] = []) { self.meanSquares = meanSquares }

    mutating func add<Samples: Collection>(_ samples: Samples) where Samples.Element == Float {
        for sample in samples {
            sum += sample * sample
            filled += 1
            if filled == Self.hop {
                meanSquares.append(sum / Float(Self.hop))
                sum = 0
                filled = 0
            }
        }
    }

    /// Mean square over `start..<end` seconds, read `shift` seconds earlier.
    func level(_ start: TimeInterval, _ end: TimeInterval, shift: TimeInterval = 0) -> Float {
        let from = max(0, Int(((start - shift) / Self.hopSeconds).rounded(.down)))
        let to = min(meanSquares.count, max(from + 1, Int(((end - shift) / Self.hopSeconds).rounded(.up))))
        guard from < to else { return 0 }
        var total: Float = 0
        for index in from..<to { total += meanSquares[index] }
        return total / Float(to - from)
    }
}

// MARK: - Echo

/// With the Mac's speakers, the microphone hears the participants again: a
/// transcript of the "Microphone" track alone would put their words in the
/// person's mouth (spike S6: three times as many words, 180 % of errors).
///
/// A microphone word goes only when all of this holds:
/// 1. **An echo path is proven** in its 5 minutes: where the meeting track
///    speaks and the person does not, the microphone hears it through a
///    steady gain, the one the twin words below measured, well above its own
///    noise floor. With headphones it hears its floor alone: nothing goes,
///    whatever the words say.
/// 2. **It is no louder than that echo**, +8.5 dB: a word said over a
///    participant is louder, so it stays, even when it matches ("OK" over
///    "OK").
/// 3. **It is the meeting's**: its text matches a meeting word just before
///    it, or its energy follows the meeting track's, 10 ms at a time, after
///    the speakers' delay (a correlation over 0.7). Parakeet hears the
///    speakers through the room differently from the clean track
///    ("Pifrance" for "Bpifrance"): about one echoed word in ten has no exact
///    twin, but it keeps the meeting's syllables. Such a word must also
///    never rise above the echo the path predicts: more than 6 dB over it
///    on more than one 10 ms in ten, it holds a voice of its own. A word
///    said over a participant mixes in the person's syllables, which do: it
///    stays. Losing a word said costs more than keeping an echo.
///
/// The twin words calibrate the path: fewer than `minimumMatches`, or a gain
/// too high to be an echo (both sides saying "yes" at once), and nothing goes.
/// Measured in S6 on an hour: 92 to 94 % of the echoed words removed, none of
/// the 2 935 words really said (interjections included).
enum ForkMeetingEcho {
    struct Settings: Equatable {
        /// How long before the meeting word a microphone word may start
        /// (times are 80 ms frames).
        var lead: TimeInterval = 0.16
        /// How long after.
        var maxDelay: TimeInterval = 0.40
        /// Normalized edit similarity for words of 4 letters or more; the
        /// shorter ones must be equal.
        var similarity: Double = 0.75
        /// A word judged echo is no louder than the echo path makes the
        /// meeting track, times this (a power ratio: 7.08 = +8.5 dB).
        var margin: Float = 7.08
        /// Fewer text matches than this: no echo path (headphones).
        var minimumMatches = 20
        /// A path louder than this (a power ratio: 0.25 = −6 dB) is made of
        /// coincidences, both sides saying "yes" at once, not of an echo.
        var maximumGain: Float = 0.25
        /// The speaker-to-microphone delay looked for, from 0.
        var maxLag: TimeInterval = 0.5
        /// The path is proven, and its gain measured, this long at a time:
        /// the person may move, or turn the volume up.
        var slice: TimeInterval = 300
        /// A last slice shorter than this joins the one before: a few
        /// seconds past the five minutes prove nothing alone.
        var shortestSlice: TimeInterval = 30
        /// Hops of the meeting speaking alone a slice needs to prove a path
        /// (2 s).
        var minimumHops = 200
        /// A slice's gain within this of the twin words' (a power ratio: 4 =
        /// 6 dB), and the microphone this far above its floor there.
        var tolerance: Float = 4
        /// A word whose energy follows the meeting's this closely (Pearson,
        /// on the log of each 10 ms) is the meeting's.
        var following: Float = 0.7
        /// A word without a twin goes only if no more than `burstShare` of
        /// its 10 ms rise `burst` above the predicted echo (a power ratio:
        /// 4 = +6 dB).
        var burst: Float = 4
        var burstShare: Float = 0.1
    }

    /// The microphone words that start just after a near-identical meeting
    /// word: the text half, which calibrates the path.
    static func textMatches(micro: [ForkParakeetWord], meeting: [ForkParakeetWord],
                            settings: Settings = Settings()) -> [Int] {
        let keys = meeting.map { normalized($0.text) }
        var matches: [Int] = []
        var low = 0
        for (index, word) in micro.enumerated() {
            let key = normalized(word.text)
            guard !key.isEmpty else { continue }
            while low < meeting.count && meeting[low].start + settings.maxDelay < word.start { low += 1 }
            var cursor = low
            while cursor < meeting.count && meeting[cursor].start - settings.lead <= word.start {
                if similar(key, keys[cursor], settings.similarity) {
                    matches.append(index)
                    break
                }
                cursor += 1
            }
        }
        return matches
    }

    /// Lower case, no accents, letters and digits only.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func similar(_ one: String, _ other: String, _ threshold: Double) -> Bool {
        if one == other { return true }
        guard one.count >= 4, other.count >= 4 else { return false }
        let distance = levenshtein(Array(one), Array(other))
        return 1 - Double(distance) / Double(max(one.count, other.count)) >= threshold
    }

    static func levenshtein(_ one: [Character], _ other: [Character]) -> Int {
        if one.isEmpty { return other.count }
        if other.isEmpty { return one.count }
        var previous = Array(0...other.count)
        var current = [Int](repeating: 0, count: other.count + 1)
        for i in 1...one.count {
            current[0] = i
            for j in 1...other.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (one[i - 1] == other[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[other.count]
    }

    /// The speaker-to-microphone delay: the lag (0…`maxLag`) where the
    /// microphone's log energy best follows the meeting's.
    static func delay(micro: ForkMeetingEnvelope, meeting: ForkMeetingEnvelope, maxLag: TimeInterval = 0.5) -> TimeInterval {
        let one = micro.meanSquares.map { log10($0 + 1e-9) }
        let other = meeting.meanSquares.map { log10($0 + 1e-9) }
        let count = min(one.count, other.count)
        guard count > 100 else { return 0 }
        let meanOne = one[0..<count].reduce(0, +) / Float(count)
        let meanOther = other[0..<count].reduce(0, +) / Float(count)
        var best = 0
        var bestScore = -Float.infinity
        for lag in 0...max(0, Int(maxLag / ForkMeetingEnvelope.hopSeconds)) {
            var score: Float = 0
            var index = lag
            while index < count {
                score += (one[index] - meanOne) * (other[index - lag] - meanOther)
                index += 1
            }
            if score > bestScore {
                bestScore = score
                best = lag
            }
        }
        return Double(best) * ForkMeetingEnvelope.hopSeconds
    }

    /// The echo's path in a slice: what the microphone hears of the meeting
    /// track, over the floor it hears anyway.
    struct Path: Equatable {
        /// Microphone energy over meeting energy, a power ratio.
        var gain: Float
        /// The microphone's own noise floor, a mean square.
        var floor: Float
    }

    struct Report: Equatable {
        var delay: TimeInterval
        var matches: Int
        /// Microphone energy over meeting energy on the matched words: the
        /// echo's path. `nil` without enough matches.
        var gain: Float?
        /// Each slice's path where it is proven, `nil` where it is not
        /// (headphones, a silent meeting, the person talking throughout).
        var slices: [Path?] = []
        /// Indexes of the microphone words judged echo.
        var echo: Set<Int>

        /// Whether the filter found an echo path and used it.
        var applied: Bool { !echo.isEmpty }
    }

    static func filter(micro: [ForkParakeetWord], meeting: [ForkParakeetWord],
                       microEnvelope: ForkMeetingEnvelope, meetingEnvelope: ForkMeetingEnvelope,
                       settings: Settings = Settings()) -> Report {
        let matched = textMatches(micro: micro, meeting: meeting, settings: settings)
        let lag = delay(micro: microEnvelope, meeting: meetingEnvelope, maxLag: settings.maxLag)
        func ratio(_ word: ForkParakeetWord) -> Float {
            let heard = microEnvelope.level(word.start, word.end)
            let source = meetingEnvelope.level(word.start, word.end, shift: lag)
            return heard / max(source, 1e-10)
        }
        let ratios = matched.map { ratio(micro[$0]) }.sorted()
        guard ratios.count >= settings.minimumMatches else {
            return Report(delay: lag, matches: ratios.count, gain: nil, echo: [])
        }
        let gain = ratios[ratios.count / 2]
        guard gain < settings.maximumGain else {
            return Report(delay: lag, matches: ratios.count, gain: gain, echo: [])
        }
        let twins = Set(matched)
        // Where the person may be talking: around the words with no twin.
        let hop = ForkMeetingEnvelope.hopSeconds
        var person = [Bool](repeating: false, count: microEnvelope.meanSquares.count)
        for (index, word) in micro.enumerated() where !twins.contains(index) {
            let from = max(0, Int(((word.start - 0.1) / hop).rounded(.down)))
            let to = min(person.count, Int(((word.end + 0.1) / hop).rounded(.up)))
            if from < to { for hop in from..<to { person[hop] = true } }
        }
        let slices = paths(micro: microEnvelope, meeting: meetingEnvelope, lag: lag, person: person,
                           gain: gain, settings: settings)
        var echo = Set<Int>()
        for (index, word) in micro.enumerated() {
            let slice = min(max(0, Int(word.start / settings.slice)), slices.count - 1)
            guard slice < slices.count, let path = slices[slice], ratio(word) < path.gain * settings.margin else {
                continue
            }
            if twins.contains(index)
                || (following(micro: microEnvelope, meeting: meetingEnvelope, word.start, word.end, shift: lag, path: path)
                        > settings.following
                    && rising(micro: microEnvelope, meeting: meetingEnvelope, word.start, word.end, shift: lag,
                              path: path, over: settings.burst) <= settings.burstShare) {
                echo.insert(index)
            }
        }
        return Report(delay: lag, matches: ratios.count, gain: gain, slices: slices, echo: echo)
    }

    /// Each slice's echo gain, where the microphone proves it hears the
    /// meeting: on the hops where the meeting speaks (within 20 dB of its
    /// loudest) and the person does not, the microphone over the meeting,
    /// their median; proven when it is an echo's (under `maximumGain`), the
    /// twin words' `gain` give or take `tolerance`, and the microphone hears
    /// it `tolerance` above its own floor. With headphones it hears its floor
    /// alone.
    static func paths(micro: ForkMeetingEnvelope, meeting: ForkMeetingEnvelope, lag: TimeInterval,
                      person: [Bool], gain: Float, settings: Settings = Settings()) -> [Path?] {
        let heard = micro.meanSquares, source = meeting.meanSquares
        let shift = Int((lag / ForkMeetingEnvelope.hopSeconds).rounded())
        let width = max(1, Int(settings.slice / ForkMeetingEnvelope.hopSeconds))
        let count = min(heard.count, source.count + shift)
        guard count > shift else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count {
            let end = min(count, start + width)
            ranges.append(start..<end)
            start = end
        }
        let shortest = Int(settings.shortestSlice / ForkMeetingEnvelope.hopSeconds)
        if ranges.count > 1, let last = ranges.last, last.count < shortest {
            ranges.removeLast()
            ranges[ranges.count - 1] = ranges[ranges.count - 1].lowerBound..<last.upperBound
        }
        return ranges.map {
            path(heard: heard, source: source, range: max($0.lowerBound, shift)..<$0.upperBound, shift: shift,
                 person: person, gain: gain, settings: settings)
        }
    }

    private static func path(heard: [Float], source: [Float], range: Range<Int>, shift: Int, person: [Bool],
                             gain: Float, settings: Settings) -> Path? {
        guard !range.isEmpty else { return nil }
        let loud = percentile(range.map { source[$0 - shift] }, 0.95)
        let floor = max(percentile(range.map { heard[$0] }, 0.10), 1e-9)
        var ratios: [Float] = []
        var levels: [Float] = []
        for index in range where source[index - shift] >= loud * 0.01 && !(index < person.count && person[index]) {
            ratios.append(heard[index] / max(source[index - shift], 1e-10))
            levels.append(heard[index])
        }
        guard ratios.count >= settings.minimumHops, loud > 0 else { return nil }
        let measured = percentile(ratios, 0.5)
        guard measured < settings.maximumGain, measured * settings.tolerance >= gain,
              measured <= gain * settings.tolerance,
              percentile(levels, 0.5) >= floor * settings.tolerance else { return nil }
        return Path(gain: measured, floor: floor)
    }

    private static func percentile(_ values: [Float], _ share: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * share))]
    }

    /// The share of a word's 10 ms where the microphone rises `over` (a power
    /// ratio) above the echo the path predicts from the meeting track: a
    /// voice of the person's own, over the echo.
    static func rising(micro: ForkMeetingEnvelope, meeting: ForkMeetingEnvelope,
                       _ start: TimeInterval, _ end: TimeInterval, shift: TimeInterval,
                       path: Path, over: Float) -> Float {
        let hop = ForkMeetingEnvelope.hopSeconds
        let lag = Int((shift / hop).rounded())
        let from = max(lag, Int((start / hop).rounded(.down)))
        let to = min(micro.meanSquares.count, meeting.meanSquares.count + lag, Int((end / hop).rounded(.up)))
        guard to > from else { return 1 }
        let above = (from..<to).filter {
            micro.meanSquares[$0] > over * (path.gain * meeting.meanSquares[$0 - lag] + path.floor)
        }.count
        return Float(above) / Float(to - from)
    }

    /// How closely the microphone's energy follows the meeting's over a word
    /// (and 50 ms each side), `shift` seconds later: Pearson's correlation of
    /// the log of each 10 ms, the meeting's seen through the path (its quiet
    /// hops sink under the microphone's floor, as an echo's do). 0 when
    /// either side is flat or too short.
    static func following(micro: ForkMeetingEnvelope, meeting: ForkMeetingEnvelope,
                          _ start: TimeInterval, _ end: TimeInterval, shift: TimeInterval,
                          path: Path = Path(gain: 1, floor: 0)) -> Float {
        let hop = ForkMeetingEnvelope.hopSeconds
        let lag = Int((shift / hop).rounded())
        let from = max(lag, Int(((start - 0.05) / hop).rounded(.down)))
        let to = min(micro.meanSquares.count, meeting.meanSquares.count + lag, Int(((end + 0.05) / hop).rounded(.up)))
        guard to - from >= 8 else { return 0 }
        let one = (from..<to).map { log10(micro.meanSquares[$0] + 1e-10) }
        let other = (from..<to).map { log10(path.gain * meeting.meanSquares[$0 - lag] + path.floor + 1e-10) }
        let count = Float(one.count)
        let meanOne = one.reduce(0, +) / count, meanOther = other.reduce(0, +) / count
        var product: Float = 0, varianceOne: Float = 0, varianceOther: Float = 0
        for index in one.indices {
            let x = one[index] - meanOne, y = other[index] - meanOther
            product += x * y
            varianceOne += x * x
            varianceOther += y * y
        }
        // Flatter than 0.1 dB: nothing to follow.
        guard varianceOne > 1e-4 * count, varianceOther > 1e-4 * count else { return 0 }
        return product / (varianceOne * varianceOther).squareRoot()
    }
}

// MARK: - The files

/// The transcript as the person reads it: `.txt` paragraphs by speaker and
/// `.srt` subtitles, both from the words of the two tracks, merged by time.
enum ForkMeetingTranscriptFormat {
    struct Segment: Equatable {
        var speaker: ForkMeetingSpeaker
        var words: [ForkParakeetWord]

        var start: TimeInterval { words.first?.start ?? 0 }
        var end: TimeInterval { words.last?.end ?? 0 }
        var text: String { words.map(\.text).joined(separator: " ") }
    }

    /// A subtitle at most this long, in seconds and in characters (its
    /// speaker included): two lines of a player.
    static let maxCueSeconds: TimeInterval = 6
    static let maxCueCharacters = 84

    /// A new segment after a pause of `pause`, after a sentence's end
    /// followed by `sentencePause`, or once a segment would pass
    /// `maxDuration`.
    static func segments(_ words: [ForkParakeetWord], speaker: ForkMeetingSpeaker,
                         pause: TimeInterval = 1.0, sentencePause: TimeInterval = 0.4,
                         maxDuration: TimeInterval = 30) -> [Segment] {
        var result: [Segment] = []
        var current: [ForkParakeetWord] = []
        for word in words {
            if let last = current.last, let first = current.first {
                let gap = word.start - last.end
                let endsSentence = last.text.last.map { ".?!…".contains($0) } ?? false
                if gap >= pause || (endsSentence && gap >= sentencePause) || word.end - first.start > maxDuration {
                    result.append(Segment(speaker: speaker, words: current))
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { result.append(Segment(speaker: speaker, words: current)) }
        return result
    }

    /// Both sides' segments by their start; at the same instant the person
    /// first. An interjection said in the middle of a participant's sentence
    /// comes right after that sentence's paragraph.
    static func merge(_ me: [Segment], _ participants: [Segment]) -> [Segment] {
        (me + participants).sorted { $0.start < $1.start || ($0.start == $1.start && $0.speaker == .me && $1.speaker != .me) }
    }

    /// `00:01:05,250`, or `00:01:05` without the milliseconds.
    static func timestamp(_ seconds: TimeInterval, milliseconds: Bool = true) -> String {
        let millis = max(0, Int((seconds * 1000).rounded()))
        let hours = millis / 3_600_000, minutes = millis / 60_000 % 60, secs = millis / 1000 % 60
        let clock = String(format: "%02d:%02d:%02d", hours, minutes, secs)
        return milliseconds ? clock + String(format: ",%03d", millis % 1000) : clock
    }

    /// Paragraphs "[00:01:05] Me: …", one per run of the same speaker.
    /// `label` gives what starts a paragraph after its time ("Me: ",
    /// "Moi : "); `rewrite` changes what was heard (the dictation's
    /// replacements), a paragraph at a time. Each moment marked while
    /// recording is a line of its own, "★ [00:12:03]", before the first
    /// paragraph that starts after it (`ForkMeetingMarkers`).
    static func text(_ merged: [Segment], label: (ForkMeetingSpeaker) -> String,
                     rewrite: (String) -> String = { $0 }, markers: [Double] = []) -> String {
        var paragraphs: [String] = []
        var speaker: ForkMeetingSpeaker?
        var start: TimeInterval = 0
        var parts: [String] = []
        var pending = markers.sorted()[...]
        func mark(before time: TimeInterval?) {
            while let next = pending.first, time.map({ next < $0 }) ?? true {
                paragraphs.append(ForkMeetingMarkers.transcriptLine(next))
                pending = pending.dropFirst()
            }
        }
        func flush() {
            guard let speaker, !parts.isEmpty else { return }
            mark(before: start)
            paragraphs.append("[\(timestamp(start, milliseconds: false))] \(label(speaker))\(rewrite(parts.joined(separator: " ")))")
        }
        for segment in merged where !segment.words.isEmpty {
            if segment.speaker != speaker {
                flush()
                speaker = segment.speaker
                start = segment.start
                parts = []
            }
            parts.append(segment.text)
        }
        flush()
        mark(before: nil)
        return paragraphs.isEmpty ? "" : paragraphs.joined(separator: "\n\n") + "\n"
    }

    struct Cue: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    /// SubRip cues of at most `maxCueSeconds` and `maxCueCharacters` (speaker
    /// and rewriting included), cut between words; a single word longer
    /// than that is a cue alone, shown `maxCueSeconds` at most (Parakeet
    /// sometimes stretches a word over a pause). Sorted by start: the two
    /// sides' cues may overlap, which SubRip allows.
    static func cues(_ merged: [Segment], label: (ForkMeetingSpeaker) -> String,
                     rewrite: (String) -> String = { $0 }) -> [Cue] {
        var cues: [Cue] = []
        for segment in merged {
            let prefix = label(segment.speaker)
            var current: [ForkParakeetWord] = []
            func line(_ words: [ForkParakeetWord]) -> String {
                prefix + rewrite(words.map(\.text).joined(separator: " "))
            }
            func flush() {
                guard let first = current.first, let last = current.last else { return }
                let end = min(max(last.end, first.start + 0.5), first.start + maxCueSeconds)
                cues.append(Cue(start: first.start, end: end, text: line(current)))
                current = []
            }
            for word in segment.words {
                if let first = current.first,
                   word.end - first.start > maxCueSeconds || line(current + [word]).count > maxCueCharacters {
                    flush()
                }
                current.append(word)
            }
            flush()
        }
        return cues.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    static func srt(_ cues: [Cue]) -> String {
        var out = ""
        for (index, cue) in cues.enumerated() {
            out += "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n\n"
        }
        return out
    }

    /// What a transcription writes.
    struct Document: Equatable {
        var text: String
        var srt: String
        /// Words kept, both sides, echo removed.
        var words: Int
        var echo: ForkMeetingEcho.Report?
        /// The microphone heard words and the meeting track none: without
        /// the meeting's words and energy, no echo can be told from the
        /// person, and the detail says so (the meeting's sound may have been
        /// lost while the speakers played it).
        var meetingSilent = false
    }

    /// The two sides' words to the two files. Without a microphone track,
    /// `me` is empty and there is no echo to judge.
    static func document(me: [ForkParakeetWord], participants: [ForkParakeetWord],
                         microEnvelope: ForkMeetingEnvelope?, meetingEnvelope: ForkMeetingEnvelope?,
                         label: (ForkMeetingSpeaker) -> String, rewrite: (String) -> String = { $0 },
                         echo settings: ForkMeetingEcho.Settings = ForkMeetingEcho.Settings(),
                         markers: [Double] = []) -> Document {
        var kept = me
        var report: ForkMeetingEcho.Report?
        if !me.isEmpty, !participants.isEmpty, let microEnvelope, let meetingEnvelope {
            let found = ForkMeetingEcho.filter(micro: me, meeting: participants, microEnvelope: microEnvelope,
                                               meetingEnvelope: meetingEnvelope, settings: settings)
            report = found
            kept = me.enumerated().filter { !found.echo.contains($0.offset) }.map(\.element)
        }
        let merged = merge(segments(kept, speaker: .me), segments(participants, speaker: .participants))
        return Document(text: text(merged, label: label, rewrite: rewrite, markers: markers),
                        srt: srt(cues(merged, label: label, rewrite: rewrite)),
                        words: kept.count + participants.count, echo: report,
                        meetingSilent: !me.isEmpty && participants.isEmpty)
    }
}
