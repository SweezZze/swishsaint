// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation
import os

/// Where a summary reads and lands, like the transcript (`+Transcript`): the
/// meeting's folder found again after a rename, its transcript read, then
/// `<name> summary.md` beside the video and `meeting.json`'s `summary`, all
/// on the store's queue.
extension ForkMeetingStore {
    private static let summaryLog = Logger(subsystem: "fork.meetings", category: "summary")

    /// What a summary is written from.
    struct SummarySource: Equatable {
        let folder: URL
        let id: UUID?
        let transcript: String
        /// The transcript's language, as the transcription found it.
        let language: String?
        let title: String?
        let startedAt: Date?
    }

    /// Off the store's queue.
    func summarySource(_ folder: URL, id: UUID?) -> Result<SummarySource, ForkMeetingSummaryFailure> {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            guard let found = locate(folder, id: id) else { return .failure(.folderGone) }
            let read = ForkMeetingSidecar.read(at: found.appendingPathComponent(ForkMeetingFolder.sidecarName))
            guard case let .success(meeting) = read, meeting.isWrittenByMeetings, meeting.isRewritable else {
                return .failure(.folderGone)
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: found.path)) ?? []
            let contents = ForkMeetingFolder.contents(of: names, folderName: found.lastPathComponent,
                                                      alsoNamed: meeting.recordedName(),
                                                      transcriptFiles: meeting.transcriptFiles)
            if isWritten(found, sidecar: read, contents: contents) { return .failure(.meetingInProgress) }
            guard let file = contents.transcript,
                  let data = try? Data(contentsOf: found.appendingPathComponent(file)),
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.noTranscript)
            }
            let record = ForkMeetingTranscriptRecord(json: meeting.transcript)
            return .success(SummarySource(folder: found, id: meeting.id, transcript: text, language: record?.language,
                                          title: meeting.title, startedAt: meeting.startedAt))
        }
    }

    /// Writes the summary beside the video, through a hidden draft, and its
    /// record in `meeting.json`. `word` names the file ("summary",
    /// "résumé"). Off the store's queue; the folder where it went.
    func writeSummary(_ markdown: String, record: ForkMeetingSummaryRecord, word: String,
                      in folder: URL, id: UUID?) -> Result<URL, ForkMeetingSummaryFailure> {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            guard let found = locate(folder, id: id) else { return .failure(.folderGone) }
            let read = ForkMeetingSidecar.read(at: found.appendingPathComponent(ForkMeetingFolder.sidecarName))
            guard case let .success(meeting) = read, meeting.isWrittenByMeetings, meeting.isRewritable else {
                return .failure(.folderGone)
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: found.path)) ?? []
            let contents = ForkMeetingFolder.contents(of: names, folderName: found.lastPathComponent,
                                                      alsoNamed: meeting.recordedName())
            if isWritten(found, sidecar: read, contents: contents) { return .failure(.meetingInProgress) }
            let source = ForkMeetingTranscript.source(video: contents.video, hasMaster: contents.hasMaster)
                ?? ForkMeetingFolder.masterName
            let ours = ForkMeetingSummaryRecord(json: meeting.summary)?.files ?? []
            let base = ForkMeetingSummary.fileName(source: source, folderName: found.lastPathComponent, word: word)
            let name = ForkMeetingSummary.placement(base, names: names, ours: ours)
            guard Self.writeTogether([(name, markdown)], in: found) else { return .failure(.notWritten) }
            // A former summary under another name (another language) is
            // replaced, not left beside the new one.
            for old in ours where old.lowercased() != name.lowercased() {
                try? FileManager.default.removeItem(at: found.appendingPathComponent(old))
            }
            var next = meeting
            var written = record
            written.files = [name]
            next.summary = written.replacing(meeting.summary)
            if writeSidecar(next, in: found) != nil {
                Self.summaryLog.error("summary written, its record not: \(found.lastPathComponent, privacy: .private)")
            }
            return .success(found)
        }
    }

    /// A failed summary, said in `meeting.json`; a summary already there
    /// keeps its record. Off the store's queue.
    func recordSummaryFailure(_ failure: ForkMeetingSummaryFailure, at date: Date, in folder: URL, id: UUID?) {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            guard let found = locate(folder, id: id) else { return }
            let read = ForkMeetingSidecar.read(at: found.appendingPathComponent(ForkMeetingFolder.sidecarName))
            guard case let .success(meeting) = read, meeting.isWrittenByMeetings, meeting.isRewritable else { return }
            let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: found.path)) ?? []).map { $0.lowercased() })
            let ours = ForkMeetingSummaryRecord(json: meeting.summary)?.files ?? []
            guard !ours.contains(where: { names.contains($0.lowercased()) }) else { return }
            var next = meeting
            next.summary = ForkMeetingSummaryRecord(state: .failed, at: date, reason: failure.rawValue)
                .replacing(meeting.summary)
            _ = writeSidecar(next, in: found)
        }
    }

    /// The summary's text, for "Copy Summary" and an export. Any thread
    /// but the store's.
    static func summaryText(in folder: URL, files: [String]) -> String? {
        for name in files where ForkMeetingSummary.isSummaryName(name) {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return nil
    }
}
