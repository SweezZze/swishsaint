// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// `meeting.json`'s `transcript`: what the last transcription on this Mac
/// did, `{state, words, language?, engine: "parakeet", at}`. Kept as the
/// sidecar's raw JSON (`ForkMeetingSidecar.transcript`), so a key a later
/// version adds is written back untouched.
struct ForkMeetingTranscriptRecord: Equatable {
    enum State: String, CaseIterable {
        case done
        case failed
    }

    static let engine = "parakeet"

    var state: State
    /// Words in the transcript, both sides, echo removed.
    var words: Int?
    /// The language most of the text is in, as a base code ("fr").
    var language: String?
    var engineName: String = Self.engine
    var at: Date?
    /// Why it failed, for the detail (`ForkMeetingTranscriptFailure`).
    var reason: String?
    /// What this version does not know, written back as is.
    var preserved: [String: ForkMeetingJSON] = [:]

    private static let known: Set<String> = ["state", "words", "language", "engine", "at", "reason"]

    init(state: State, words: Int? = nil, language: String? = nil, at: Date? = nil, reason: String? = nil) {
        self.state = state
        self.words = words
        self.language = language
        self.at = at
        self.reason = reason
    }

    /// `nil` for no transcript, or one this version cannot read (a state it
    /// does not know): the detail then offers to transcribe.
    init?(json: ForkMeetingJSON?) {
        guard case let .object(object)? = json, case let .string(raw)? = object["state"],
              let state = State(rawValue: raw) else { return nil }
        self.state = state
        if case let .number(value)? = object["words"], value.isFinite, value >= 0, value < 1e9 { words = Int(value) }
        if case let .string(value)? = object["language"], !value.isEmpty { language = value }
        if case let .string(value)? = object["engine"] { engineName = value }
        if case let .string(value)? = object["at"] { at = ISO8601DateFormatter().date(from: value) }
        if case let .string(value)? = object["reason"], !value.isEmpty { reason = value }
        preserved = object.filter { !Self.known.contains($0.key) }
    }

    /// The JSON written, over what was there: keys this version does not
    /// know are kept.
    var json: ForkMeetingJSON {
        var object = preserved
        object["state"] = .string(state.rawValue)
        object["engine"] = .string(engineName)
        if let words { object["words"] = .number(Double(words)) }
        if let language { object["language"] = .string(language) }
        if let at { object["at"] = .string(Self.stamp(at)) }
        if let reason { object["reason"] = .string(reason) }
        return .object(object)
    }

    /// A new record, keeping the old one's unknown keys.
    func replacing(_ old: ForkMeetingJSON?) -> ForkMeetingJSON {
        var record = self
        if case let .object(object)? = old {
            record.preserved = object.filter { !Self.known.contains($0.key) }.merging(preserved) { _, new in new }
        }
        return record.json
    }

    /// Whole seconds in UTC, like the rest of `meeting.json`.
    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
    }
}

/// Why a transcription did not end with its files.
enum ForkMeetingTranscriptFailure: String, Error, Equatable, CaseIterable {
    /// Parakeet is not on this Mac.
    case modelMissing
    /// The folder is being recorded or finished, here or by another copy.
    case meetingInProgress
    /// No video, or one without its meeting track.
    case noAudio
    /// The file would not open or read to its end.
    case unreadable
    /// The model refused to load, or failed while working.
    case engine
    /// The folder or its `meeting.json` went, or may not be rewritten.
    case folderGone
    /// The `.txt` or `.srt` could not be written.
    case notWritten
    /// Stopped by the person, or by the feature turned off.
    case cancelled
}

enum ForkMeetingTranscript {
    /// Parakeet v3 is trained on 25 European languages: the page says so
    /// (`ForkParakeetLanguages.supported`).
    static var languageCount: Int { ForkParakeetLanguages.supported.count }

    /// The meeting's tracks among a file's audio tracks, by their order
    /// (an `.mp4` keeps no track identifier, spike S1).
    ///
    /// - A master, or a final file that kept the master's tracks
    ///   (`skipped-disk`): the meeting, then the microphone.
    /// - A final file: its mix first, then the meeting, then the microphone
    ///   (`ForkMeetingFinalPass.layout`).
    struct Tracks: Equatable {
        /// The "Meeting" track: the participants.
        var meeting: Int
        /// The "Microphone" track: the person, when there is one.
        var microphone: Int?
    }

    static func tracks(audioTrackCount count: Int, isMaster: Bool) -> Tracks? {
        let first = isMaster ? 0 : 1
        guard count > 0 else { return nil }
        // A final file with its mix alone: the mix is all there is.
        guard count > first else { return Tracks(meeting: 0, microphone: nil) }
        return Tracks(meeting: first, microphone: count > first + 1 ? first + 1 : nil)
    }

    /// The file a meeting is transcribed from: its video, else (interrupted)
    /// its master, readable up to its last fragment.
    static func source(video: String?, hasMaster: Bool) -> String? {
        video ?? (hasMaster ? ForkMeetingFolder.masterName : nil)
    }

    static let textExtension = "txt"
    static let subtitlesExtension = "srt"

    /// `<name>.txt` and `<name>.srt`, named after the video (after the
    /// folder for a master): a rename moves them with it.
    static func fileNames(source: String, folderName: String) -> (text: String, subtitles: String) {
        let stem = source == ForkMeetingFolder.masterName ? folderName : (source as NSString).deletingPathExtension
        return ("\(stem).\(textExtension)", "\(stem).\(subtitlesExtension)")
    }

    /// Hidden while written, then put in place in one move: a reader never
    /// sees half a transcript.
    static func draftName(_ name: String) -> String { ".\(name).draft" }

    /// The share done, 0…1: each track weighs its length, read in order.
    static func progress(trackIndex: Int, tracks: Int, seconds: TimeInterval, duration: TimeInterval) -> Double {
        guard tracks > 0 else { return 0 }
        let share = duration > 0 ? min(max(seconds / duration, 0), 1) : 0
        return min(1, (Double(min(max(trackIndex, 0), tracks)) + share) / Double(tracks))
    }

    /// Whether a meeting just saved is transcribed on its own: the feature
    /// and the setting on, and a meeting that ended normally (a recovered
    /// one waits for a click). Without Parakeet the job fails at once and
    /// its notice says so: the setting never does nothing without a word.
    static func transcribesAutomatically(featureOn: Bool, settingOn: Bool, recovered: Bool) -> Bool {
        featureOn && settingOn && !recovered
    }

    /// An automatic transcription waits while a meeting records: the Neural
    /// Engine and a core are the recorder's first. One asked for by a click
    /// starts at once.
    static func mayStart(automatic: Bool, recording: Bool) -> Bool {
        !automatic || !recording
    }

    /// "fr-CA" → "fr"; `nil` for an empty one.
    static func baseLanguage(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty, identifier != "und" else { return nil }
        return ForkParakeetLanguages.baseCode(identifier)
    }
}

/// The transcripts a search reads, in memory, folded once: the library's
/// search finds a meeting by what was said in it.
struct ForkMeetingTranscriptIndex: Equatable {
    /// What a file was when it was read: a new size or date reads it again.
    struct Stamp: Equatable, Hashable {
        var size: Int64
        var modified: Date?
    }

    struct Item: Equatable {
        var stamp: Stamp
        var folded: String
    }

    /// By folder name, then file name.
    private(set) var items: [String: Item] = [:]

    static func key(folder: String, file: String) -> String { folder + "/" + file }

    /// The files to read again: new, changed, or not read yet.
    func stale(_ files: [String: Stamp]) -> [String] {
        files.filter { items[$0.key]?.stamp != $0.value }.map(\.key).sorted()
    }

    /// Keeps only `files` (a meeting gone, or its transcript), and takes in
    /// what was just read.
    mutating func update(keeping files: Set<String>, read: [String: Item]) {
        items = items.filter { files.contains($0.key) }
        items.merge(read) { _, new in new }
    }

    func text(folder: String, file: String?) -> String? {
        guard let file else { return nil }
        return items[Self.key(folder: folder, file: file)]?.folded
    }

    /// The transcript as the search compares it: speakers' labels and times
    /// out, folded like the rest of the row.
    static func folded(_ transcript: String) -> String {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true).map { line -> Substring in
            // "[00:01:05] Me: text": what follows the time stays, labels too
            // (a search for "Participants" is no use, but harmless).
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") { return line[line.index(after: close)...] }
            return line
        }
        return ForkMeetingLibrary.folded(lines.joined(separator: "\n"))
    }
}
