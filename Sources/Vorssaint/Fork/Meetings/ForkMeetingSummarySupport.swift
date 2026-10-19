// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// `meeting.json`'s `summary`: what the last summary on this Mac did,
/// `{state, engine: "apple", at, language?, parts?, skipped?, reason?,
/// files}`. Kept as raw JSON like the transcript's record, so a key a later
/// version adds is written back untouched.
struct ForkMeetingSummaryRecord: Equatable {
    enum State: String, CaseIterable {
        case done
        case failed
    }

    static let engine = "apple"

    var state: State
    var engineName: String = Self.engine
    var at: Date?
    /// The language it was written in, as a base code ("fr").
    var language: String?
    /// How many parts of the transcript were read one at a time.
    var parts: Int?
    /// Parts Apple Intelligence would not summarize (its guardrails): the
    /// summary says it is partial.
    var skipped: Int?
    var reason: String?
    /// The name it wrote in the folder: the only file this app ever
    /// replaces as a summary.
    var files: [String] = []
    /// What the file held when written (`ForkMeetingSummary.digest`): one
    /// the person edited since is theirs, never written over.
    var digest: String?
    var preserved: [String: ForkMeetingJSON] = [:]

    private static let known: Set<String> = ["state", "engine", "at", "language", "parts", "skipped", "reason", "files",
                                             "digest"]

    init(state: State, at: Date? = nil, language: String? = nil, parts: Int? = nil, skipped: Int? = nil,
         reason: String? = nil, files: [String] = []) {
        self.state = state
        self.at = at
        self.language = language
        self.parts = parts
        self.skipped = skipped
        self.reason = reason
        self.files = files
    }

    /// `nil` for no summary, or one this version cannot read.
    init?(json: ForkMeetingJSON?) {
        guard case let .object(object)? = json, case let .string(raw)? = object["state"],
              let state = State(rawValue: raw) else { return nil }
        self.state = state
        if case let .string(value)? = object["engine"] { engineName = value }
        if case let .string(value)? = object["at"] { at = ISO8601DateFormatter().date(from: value) }
        if case let .string(value)? = object["language"], !value.isEmpty { language = value }
        if case let .number(value)? = object["parts"], value.isFinite, value >= 0, value < 1e6 { parts = Int(value) }
        if case let .number(value)? = object["skipped"], value.isFinite, value >= 0, value < 1e6 { skipped = Int(value) }
        if case let .string(value)? = object["reason"], !value.isEmpty { reason = value }
        if case let .string(value)? = object["digest"], !value.isEmpty { digest = value }
        if case let .array(values)? = object["files"] {
            // A bare `.md` name only: a corrupt list never reaches out of
            // the folder nor names the video.
            files = values.compactMap { value -> String? in
                guard case let .string(name) = value, ForkMeetingSummary.isSummaryName(name) else { return nil }
                return name
            }
        }
        preserved = object.filter { !Self.known.contains($0.key) }
    }

    var json: ForkMeetingJSON {
        var object = preserved
        object["state"] = .string(state.rawValue)
        object["engine"] = .string(engineName)
        if let at { object["at"] = .string(ForkMeetingTranscriptRecord.stamp(at)) }
        if let language { object["language"] = .string(language) }
        if let parts { object["parts"] = .number(Double(parts)) }
        if let skipped, skipped > 0 { object["skipped"] = .number(Double(skipped)) }
        if let reason { object["reason"] = .string(reason) }
        if !files.isEmpty { object["files"] = .array(files.map { .string($0) }) }
        if let digest { object["digest"] = .string(digest) }
        return .object(object)
    }

    func replacing(_ old: ForkMeetingJSON?) -> ForkMeetingJSON {
        var record = self
        if case let .object(object)? = old {
            record.preserved = object.filter { !Self.known.contains($0.key) }.merging(preserved) { _, new in new }
        }
        return record.json
    }
}

/// Why a summary did not end with its file.
enum ForkMeetingSummaryFailure: String, Error, Equatable, CaseIterable {
    /// Apple Intelligence is off, not ready, or this Mac cannot run it.
    case unavailable
    /// No transcript to summarize.
    case noTranscript
    /// The model does not write the meeting's language.
    case languageUnsupported
    /// It refused every part (its guardrails).
    case refused
    /// It failed while working.
    case engine
    case meetingInProgress
    case folderGone
    case notWritten
    case cancelled
}

/// A summary, as the model writes each part and as the file says it: the
/// points, the decisions, the actions.
struct ForkMeetingSummaryNotes: Equatable {
    var points: [String] = []
    var decisions: [String] = []
    var actions: [String] = []

    var isEmpty: Bool { points.isEmpty && decisions.isEmpty && actions.isEmpty }

    /// The shape the model is asked to answer in, read back as a part for
    /// the final merge.
    var text: String {
        func section(_ name: String, _ items: [String]) -> String {
            ([name + ":"] + (items.isEmpty ? ["- none"] : items.map { "- " + $0 })).joined(separator: "\n")
        }
        return [section(ForkMeetingSummary.pointsHeader, points),
                section(ForkMeetingSummary.decisionsHeader, decisions),
                section(ForkMeetingSummary.actionsHeader, actions)].joined(separator: "\n")
    }
}

/// Summaries written on this Mac by Apple Intelligence (`FoundationModels`)
/// from the transcript's text: the pure part, the cutting, the prompts, the
/// reading of the answers and the file.
///
/// - **Parts**: the on-device model reads about 4 000 tokens at a time,
///   prompt and answer included. A transcript longer than `partCharacters`
///   is cut between paragraphs (between sentences, then words, for a longer
///   one); each part gives its notes, and the notes are merged, in groups
///   when they are many (`mergeGroups`).
/// - **The meeting's language**: the record's, which the transcription
///   found; the three headers the model answers with stay in English so
///   they read back the same in every language.
enum ForkMeetingSummary {
    static let pointsHeader = "SUMMARY"
    static let decisionsHeader = "DECISIONS"
    static let actionsHeader = "ACTIONS"
    static let fileExtension = "md"

    /// Characters of transcript per part: about 2 000 tokens of French,
    /// leaving the rest of the model's window to the instructions and the
    /// answer. A part refused for its length is cut in two and tried again.
    static let partCharacters = 6_000
    /// Never cut below this: a part this short that still fails is skipped.
    static let smallestPart = 800
    /// The notes merged at once, at most.
    static let mergeCharacters = 6_000

    // MARK: Cutting

    /// The transcript in parts of at most `limit` characters, cut between
    /// paragraphs; a paragraph longer than that between sentences, then
    /// between words. The `★` lines of the markers go with the next part.
    static func parts(_ transcript: String, limit: Int = partCharacters) -> [String] {
        let limit = max(200, limit)
        let paragraphs = transcript.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var pieces: [String] = []
        for paragraph in paragraphs {
            if paragraph.count <= limit {
                pieces.append(paragraph)
            } else {
                pieces += split(paragraph, limit: limit)
            }
        }
        var parts: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
            } else if current.count + 2 + piece.count <= limit {
                current += "\n\n" + piece
            } else {
                parts.append(current)
                current = piece
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// A paragraph longer than `limit`: by sentences, then by words.
    static func split(_ text: String, limit: Int) -> [String] {
        var sentences: [String] = []
        var sentence = ""
        for character in text {
            sentence.append(character)
            if ".?!…".contains(character) {
                sentences.append(sentence)
                sentence = ""
            }
        }
        if !sentence.isEmpty { sentences.append(sentence) }
        var units: [String] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count <= limit {
                units.append(trimmed)
            } else {
                units += trimmed.split(separator: " ").map(String.init)
            }
        }
        var out: [String] = []
        var current = ""
        for unit in units {
            if current.isEmpty {
                current = String(unit.prefix(limit))
            } else if current.count + 1 + unit.count <= limit {
                current += " " + unit
            } else {
                out.append(current)
                current = String(unit.prefix(limit))
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The parts' notes, in groups to merge one at a time: each at most
    /// `limit` characters, two at least when there are two.
    static func mergeGroups(_ notes: [String], limit: Int = mergeCharacters) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var size = 0
        for note in notes {
            if !current.isEmpty, size + note.count > limit, current.count >= 2 {
                groups.append(current)
                current = []
                size = 0
            }
            current.append(note)
            size += note.count + 2
        }
        if !current.isEmpty {
            // A last group of one joins the one before: merging it alone
            // would only copy it.
            if current.count == 1, !groups.isEmpty {
                groups[groups.count - 1] += current
            } else {
                groups.append(current)
            }
        }
        return groups
    }

    // MARK: Prompts

    /// "French", the language the summary is written in, as the model's
    /// instructions name it; `nil` when the code is unknown.
    static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let name = Locale(identifier: "en_US").localizedString(forLanguageCode: code)
        return name.flatMap { $0.isEmpty || $0 == code ? nil : $0 }
    }

    /// The session's instructions: what the text is, what to write, how.
    static func instructions(language: String?, me: String, others: String) -> String {
        let written = languageName(language).map { "Write every point in \($0)." }
            ?? "Write every point in the language of the transcript."
        return """
        You take notes of meetings from their transcript. Lines start with a time in brackets, then who speaks: \
        "\(speaker(me))" is the person who recorded the meeting, "\(speaker(others))" is everyone else. Lines with a star are moments the person \
        marked as important. Use only what the transcript says: never invent a name, a number or a date. \
        Answer with exactly these three headers, in English, each followed by short bullet points starting with "- ": \
        \(pointsHeader):, \(decisionsHeader):, \(actionsHeader):. Under \(actionsHeader), say who does what, and by \
        when if it was said. Write "- none" under a header with nothing to say. \(written)
        """
    }

    /// "Moi : " → "Moi": a speaker's label without its separator.
    static func speaker(_ label: String) -> String {
        label.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":：")))
    }

    /// One part of the transcript to take notes of.
    static func partPrompt(_ part: String, index: Int, count: Int) -> String {
        let which = count > 1 ? "Part \(index + 1) of \(count) of a meeting's transcript." : "A meeting's transcript."
        return "\(which) At most 6 points.\n\n\(part)"
    }

    /// Notes of several parts to merge into one set.
    static func mergePrompt(_ notes: [String]) -> String {
        let joined = notes.enumerated().map { "Notes \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
        return """
        These are notes taken on consecutive parts of one meeting. Merge them into one set of notes, in the same \
        three headers: at most 8 points in the order of the meeting, every decision and every action once.

        \(joined)
        """
    }

    // MARK: Reading the answers

    /// The model's answer as notes. Its headers are found whatever their
    /// dress ("**SUMMARY:**", "## Summary"); without any, the whole answer
    /// is points. "none", and empty bullets, are left out.
    static func notes(from answer: String) -> ForkMeetingSummaryNotes {
        var notes = ForkMeetingSummaryNotes()
        var section: WritableKeyPath<ForkMeetingSummaryNotes, [String]>?
        for raw in answer.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let header = header(line) {
                section = header.path
                if let rest = header.rest { append(rest, to: &notes, in: header.path) }
                continue
            }
            append(line, to: &notes, in: section ?? \.points)
        }
        return notes
    }

    private static func header(_ line: String) -> (path: WritableKeyPath<ForkMeetingSummaryNotes, [String]>, rest: String?)? {
        let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_ "))
        let upper = bare.uppercased()
        let headers: [(String, WritableKeyPath<ForkMeetingSummaryNotes, [String]>)] = [
            (pointsHeader, \.points), (decisionsHeader, \.decisions), (actionsHeader, \.actions),
        ]
        for (name, path) in headers where upper.hasPrefix(name) {
            let after = String(bare.dropFirst(name.count)).drop { "*_".contains($0) }
            // "SUMMARY of the meeting" is a sentence, not a header.
            guard after.isEmpty || after.hasPrefix(":") else { continue }
            let rest = after.trimmingCharacters(in: CharacterSet(charactersIn: ":*_ "))
            return (path, rest.isEmpty ? nil : rest)
        }
        return nil
    }

    private static func append(_ line: String, to notes: inout ForkMeetingSummaryNotes,
                               in path: WritableKeyPath<ForkMeetingSummaryNotes, [String]>) {
        var item = line
        for prefix in ["- ", "• ", "* ", "– ", "— "] where item.hasPrefix(prefix) {
            item = String(item.dropFirst(prefix.count))
            break
        }
        if let range = item.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) { item.removeSubrange(range) }
        item = item.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty, !isNothing(item) else { return }
        if !notes[keyPath: path].contains(item) { notes[keyPath: path].append(item) }
    }

    /// "none", "aucune", "N/A", "-": what the model writes for nothing.
    static func isNothing(_ item: String) -> Bool {
        let folded = item.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!-–—()[]* "))
        return ["", "none", "nothing", "n/a", "na", "aucune", "aucun", "rien", "neant", "keine", "nada", "ninguna",
                "ninguno", "nessuna", "nessuno", "nenhuma", "nenhum"].contains(folded)
    }

    // MARK: The file

    struct Headings: Equatable {
        var title: String
        var points: String
        var decisions: String
        var actions: String
        var none: String
        var partial: String
        var footer: String
    }

    /// The Markdown written beside the video: the meeting's title, its date
    /// as the person reads dates, the three sections, and a last line that
    /// says where it comes from.
    static func markdown(_ notes: ForkMeetingSummaryNotes, title: String, date: String?, headings: Headings,
                         partial: Bool) -> String {
        var lines = ["# \(title) — \(headings.title)"]
        if let date, !date.isEmpty { lines += ["", date] }
        if partial { lines += ["", "> \(headings.partial)"] }
        for (heading, items) in [(headings.points, notes.points), (headings.decisions, notes.decisions),
                                 (headings.actions, notes.actions)] {
            lines += ["", "## \(heading)", ""]
            lines += items.isEmpty ? ["_\(headings.none)_"] : items.map { "- \($0)" }
        }
        lines += ["", "---", "", "_\(headings.footer)_"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// `<video's name> summary.md`, the word in the summary's language.
    static func fileName(source: String, folderName: String, word: String) -> String {
        let names = ForkMeetingTranscript.fileNames(source: source, folderName: folderName)
        let stem = (names.text as NSString).deletingPathExtension
        return "\(stem) \(word).\(fileExtension)"
    }

    /// The name to write: `fileName`, unless a file of the person's already
    /// has it, then `… 2.md`, `… 3.md`. Only `ours` may be replaced.
    static func placement(_ base: String, names: [String], ours: [String]) -> String {
        let mine = Set(ours.map { $0.lowercased() })
        let present = Set(names.map { $0.lowercased() }.filter { !mine.contains($0) })
        let stem = (base as NSString).deletingPathExtension
        var name = base
        var number = 2
        while present.contains(name.lowercased()) && number < 1_000 {
            name = "\(stem) \(number).\(fileExtension)"
            number += 1
        }
        return name
    }

    /// A short fingerprint of a summary's bytes (FNV-1a, 64 bits, in hex):
    /// enough to tell a file edited since it was written.
    static func digest(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// Of this app's summaries (`ours`), the ones the person edited since
    /// they were written: theirs from then on, kept, and the new summary
    /// goes beside them (`… summary 2.md`). Without a fingerprint, or a file
    /// gone, nothing is judged edited.
    static func edited(_ ours: [String], digest: String?, read: (String) -> Data?) -> [String] {
        guard let digest else { return [] }
        return ours.filter { name in read(name).map { Self.digest($0) != digest } ?? false }
    }

    static func isSummaryName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".")
            && (name as NSString).pathExtension.lowercased() == fileExtension
    }

    /// The share done, 0…1: each part, then the merges.
    static func progress(done: Int, parts: Int) -> Double {
        let steps = parts > 1 ? parts + 1 : 1
        return min(1, max(0, Double(done) / Double(steps)))
    }

    /// Whether a transcript just written is summarized on its own: not one
    /// without a word (`words` 0), which has nothing to summarize.
    static func summarizesAutomatically(featureOn: Bool, settingOn: Bool, available: Bool, words: Int? = nil) -> Bool {
        featureOn && settingOn && available && words.map { $0 > 0 } ?? true
    }

    /// The headings' language: the meeting's when the app speaks it, else
    /// the app's.
    static func headingLanguage(_ code: String?, app: AppLanguage) -> AppLanguage {
        guard let code else { return app }
        switch code {
        case "en": return app == .enUS ? app : .enUS
        case "pt": return .ptBR
        case "tr": return .tr
        case "ru": return .ru
        case "es": return .es
        case "sk": return .sk
        case "de": return .de
        case "fr": return .fr
        case "it": return .it
        case "ja": return .ja
        case "ko": return .ko
        case "uk": return .uk
        case "zh": return [.zhHans, .zhTW, .zhHK].contains(app) ? app : .zhHans
        default: return app
        }
    }
}

extension ForkMeetingSidecar {
    /// The summary's names this app wrote (`ForkMeetingSummaryRecord.files`).
    var summaryFiles: [String] { ForkMeetingSummaryRecord(json: summary)?.files ?? [] }
}
