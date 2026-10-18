// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// One dictation kept in the history: what was heard, what was written, and
/// where it went. The audio lives next to it while it is kept.
struct ForkDictationRecord: Codable, Equatable, Identifiable {
    enum Outcome: String, Codable {
        case pasted
        case copied
        case keptInClipboard
        case inHistoryOnly
        /// The transcription failed: the audio is kept to try again.
        case failed
    }

    var id: UUID
    var date: Date
    var duration: TimeInterval
    /// "parakeet" or "apple".
    var engine: String
    /// The language asked for (BCP 47), nil when detected.
    var language: String?
    /// The text before replacements, empty after a failure.
    var rawText: String
    /// The text after replacements.
    var text: String
    var outcome: Outcome
    /// The `ForkDictationFailure` case, after a failure.
    var failure: String?
    var targetBundleID: String?
    var targetName: String?
    var isPinned: Bool
    /// False once the audio was dropped by the retention.
    var hasAudio: Bool
    /// The clipboard history entry holding the same text.
    var clipboardEntryID: UUID?

    init(id: UUID = UUID(), date: Date = Date(), duration: TimeInterval, engine: String,
         language: String?, rawText: String, text: String, outcome: Outcome,
         failure: String? = nil, targetBundleID: String? = nil, targetName: String? = nil,
         isPinned: Bool = false, hasAudio: Bool, clipboardEntryID: UUID? = nil) {
        self.id = id
        self.date = date
        self.duration = duration
        self.engine = engine
        self.language = language
        self.rawText = rawText
        self.text = text
        self.outcome = outcome
        self.failure = failure
        self.targetBundleID = targetBundleID
        self.targetName = targetName
        self.isPinned = isPinned
        self.hasAudio = hasAudio
        self.clipboardEntryID = clipboardEntryID
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, duration, engine, language, rawText, text, outcome, failure
        case targetBundleID, targetName, isPinned, hasAudio, clipboardEntryID
    }

    /// Tolerant: a field added by a later version, or one this version does
    /// not know, never costs the record. Only the id is required.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        date = (try? values.decodeIfPresent(Date.self, forKey: .date)) ?? Date(timeIntervalSince1970: 0)
        duration = (try? values.decodeIfPresent(TimeInterval.self, forKey: .duration)) ?? 0
        engine = (try? values.decodeIfPresent(String.self, forKey: .engine)) ?? ""
        language = try? values.decodeIfPresent(String.self, forKey: .language)
        rawText = (try? values.decodeIfPresent(String.self, forKey: .rawText)) ?? ""
        text = (try? values.decodeIfPresent(String.self, forKey: .text)) ?? ""
        outcome = (try? values.decodeIfPresent(Outcome.self, forKey: .outcome)) ?? .inHistoryOnly
        failure = try? values.decodeIfPresent(String.self, forKey: .failure)
        targetBundleID = try? values.decodeIfPresent(String.self, forKey: .targetBundleID)
        targetName = try? values.decodeIfPresent(String.self, forKey: .targetName)
        isPinned = (try? values.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
        hasAudio = (try? values.decodeIfPresent(Bool.self, forKey: .hasAudio)) ?? false
        clipboardEntryID = try? values.decodeIfPresent(UUID.self, forKey: .clipboardEntryID)
    }
}

/// How long the history keeps what: the audio a week, the text until the
/// list is full. Pinned dictations keep both.
enum ForkDictationRetention {
    static let audioDays = 7
    static let maximumRecords = 500

    /// The audio and the records to drop at `now`. Past the cap, the oldest
    /// records that are not pinned go first.
    static func plan(_ records: [ForkDictationRecord], now: Date)
        -> (dropAudio: [UUID], dropRecords: [UUID]) {
        let audioLimit = now.addingTimeInterval(-TimeInterval(audioDays) * 24 * 3600)
        let newestFirst = records.sorted { $0.date > $1.date }
        var dropRecords: [UUID] = []
        let excess = newestFirst.count - maximumRecords
        if excess > 0 {
            dropRecords = newestFirst.reversed().filter { !$0.isPinned }.prefix(excess).map(\.id)
        }
        let dropped = Set(dropRecords)
        let dropAudio = newestFirst
            .filter { $0.hasAudio && !$0.isPinned && $0.date < audioLimit && !dropped.contains($0.id) }
            .map(\.id)
        return (dropAudio, dropRecords)
    }
}

/// The history's index file: the records, newest first.
enum ForkDictationIndex {
    static func encode(_ records: [ForkDictationRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(records)
    }

    /// The records, record by record: one that cannot be read is skipped,
    /// the others stay. Nil when the file is not a list at all, so the
    /// caller can set it aside instead of writing over it.
    static func decode(_ data: Data) -> [ForkDictationRecord]? {
        guard let items = try? JSONDecoder().decode([Lenient].self, from: data) else { return nil }
        return items.compactMap(\.record).sorted { $0.date > $1.date }
    }

    private struct Lenient: Decodable {
        let record: ForkDictationRecord?
        init(from decoder: Decoder) throws {
            record = try? ForkDictationRecord(from: decoder)
        }
    }

    /// The audio files no record names any more (`<id>.m4a`), to remove.
    static func orphans(_ fileNames: [String], records: [ForkDictationRecord]) -> [String] {
        let kept = Set(records.map { "\($0.id.uuidString).m4a" })
        return fileNames.filter { $0.hasSuffix(".m4a") && !$0.hasPrefix(".") && !kept.contains($0) }
    }
}
