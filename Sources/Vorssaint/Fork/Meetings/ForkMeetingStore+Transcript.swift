// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation
import os

/// Where a transcript lands: the meeting's folder, found again when the
/// library renamed it during the minute the transcription took, then its
/// `.txt`, its `.srt` and `meeting.json`'s `transcript`, all on the store's
/// queue, after any rename asked before, so the files never land beside a
/// folder that moved.
extension ForkMeetingStore {
    private static let transcriptLog = Logger(subsystem: "fork.meetings", category: "transcript")

    /// What the transcription reads before it starts: the file, and whether
    /// the meeting may be transcribed now.
    struct TranscriptSource: Equatable {
        let folder: URL
        let id: UUID?
        /// The file read, in the folder.
        let file: String
        /// A master's tracks (or a final file that kept them): no mix first.
        let isMaster: Bool
    }

    /// Off the store's queue. `folder` as the caller knew it; `id` finds it
    /// again after a rename.
    func transcriptSource(_ folder: URL, id: UUID?) -> Result<TranscriptSource, ForkMeetingTranscriptFailure> {
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
            guard let file = ForkMeetingTranscript.source(video: contents.video, hasMaster: contents.hasMaster) else {
                return .failure(.noAudio)
            }
            let isMaster = file == ForkMeetingFolder.masterName || meeting.finalPass == .skippedDisk
            return .success(TranscriptSource(folder: found, id: meeting.id, file: file, isMaster: isMaster))
        }
    }

    /// Writes the transcript's two files beside the meeting's video, each
    /// through a hidden draft then one move, and its record in
    /// `meeting.json`. Off the store's queue; the folder where the files
    /// went, or why not.
    func writeTranscript(_ document: ForkMeetingTranscriptFormat.Document, record: ForkMeetingTranscriptRecord,
                         in folder: URL, id: UUID?) -> Result<URL, ForkMeetingTranscriptFailure> {
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
            guard let source = ForkMeetingTranscript.source(video: contents.video, hasMaster: contents.hasMaster) else {
                return .failure(.noAudio)
            }
            let files = ForkMeetingTranscript.fileNames(source: source, folderName: found.lastPathComponent)
            // A transcript already there under another name (the video renamed
            // in the Finder since) is replaced, not left beside the new one.
            let stale = [contents.transcript, contents.subtitles].compactMap { $0 }
                .filter { $0 != files.text && $0 != files.subtitles }
            for (name, text) in [(files.text, document.text), (files.subtitles, document.srt)] {
                guard Self.writeAtomically(text, named: name, in: found) else { return .failure(.notWritten) }
            }
            for name in stale { try? FileManager.default.removeItem(at: found.appendingPathComponent(name)) }
            var next = meeting
            next.transcript = record.replacing(meeting.transcript)
            if writeSidecar(next, in: found) != nil {
                Self.transcriptLog.error("transcript written, its record not: \(found.lastPathComponent, privacy: .private)")
            }
            return .success(found)
        }
    }

    /// A failed transcription, said in `meeting.json`. A transcript already
    /// on the disk keeps its own record: a retry that failed takes nothing
    /// away. Off the store's queue.
    func recordTranscriptFailure(_ failure: ForkMeetingTranscriptFailure, at date: Date, in folder: URL, id: UUID?) {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            guard let found = locate(folder, id: id) else { return }
            let read = ForkMeetingSidecar.read(at: found.appendingPathComponent(ForkMeetingFolder.sidecarName))
            guard case let .success(meeting) = read, meeting.isWrittenByMeetings, meeting.isRewritable else { return }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: found.path)) ?? []
            let contents = ForkMeetingFolder.contents(of: names, folderName: found.lastPathComponent,
                                                      alsoNamed: meeting.recordedName())
            guard contents.transcript == nil, !isWritten(found, sidecar: read, contents: contents) else { return }
            var next = meeting
            next.transcript = ForkMeetingTranscriptRecord(state: .failed, at: date, reason: failure.rawValue)
                .replacing(meeting.transcript)
            _ = writeSidecar(next, in: found)
        }
    }

    // MARK: - Store queue

    /// The folder now: where it was, else where the library's rename moved
    /// it, else, by its meeting's id, wherever the Finder put it in the
    /// meetings folder.
    private func locate(_ folder: URL, id: UUID?) -> URL? {
        let manager = FileManager.default
        func holds(_ candidate: URL) -> Bool {
            guard manager.fileExists(atPath: candidate.appendingPathComponent(ForkMeetingFolder.sidecarName).path) else {
                return false
            }
            guard let id else { return true }
            let read = ForkMeetingSidecar.read(at: candidate.appendingPathComponent(ForkMeetingFolder.sidecarName))
            return (try? read.get())?.id == id
        }
        if holds(folder) { return folder }
        let path = Self.tablePath(folder)
        let moved = renameTable.resolve(path, fileAt: Self.fileNumber)
        if moved != path, holds(URL(fileURLWithPath: moved, isDirectory: true)) {
            return URL(fileURLWithPath: moved, isDirectory: true)
        }
        guard id != nil else { return nil }
        let parent = folder.deletingLastPathComponent()
        let names = (try? manager.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.lazy.filter { !$0.hasPrefix(".") }
            .map { parent.appendingPathComponent($0, isDirectory: true) }
            .first(where: holds)
    }

    /// Recorded or finished now, here or by another copy of the app.
    private func isWritten(_ folder: URL, sidecar: Result<ForkMeetingSidecar, ForkMeetingSidecarFault>,
                           contents: ForkMeetingFolder.Contents) -> Bool {
        if isClaimedHere(folder) { return true }
        guard ForkMeetingLibraryLock.mayBeHeldElsewhere(sidecar, contents: contents) else { return false }
        return Self.isLockedElsewhere(folder)
    }

    /// Through a hidden draft, then `replaceItemAt`: a reader (the library,
    /// an export) sees the old file or the new one, never half of one.
    static func writeAtomically(_ text: String, named name: String, in folder: URL) -> Bool {
        let manager = FileManager.default
        let draft = folder.appendingPathComponent(ForkMeetingTranscript.draftName(name))
        do {
            try? manager.removeItem(at: draft)
            try Data(text.utf8).write(to: draft)
            try replace(folder.appendingPathComponent(name), with: draft)
            return true
        } catch {
            try? manager.removeItem(at: draft)
            transcriptLog.error("\(name, privacy: .private) not written: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
