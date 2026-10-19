// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Whether a meeting is being recorded, finished, transcribed or
/// summarized, for what must not get in its way: the fork's updater, which
/// quits the app to replace it.
///
/// Four sources, kept apart so none can clear another: the service says
/// when a recording runs, the finalizer counts the final passes it holds,
/// the transcriber says while a transcription runs or waits, the summarizer
/// while a summary does. A meeting is safe once all are done, and only then
/// `didBecomeIdle` is posted, on the main thread.
///
/// Static and under a lock rather than an object to observe: the updater
/// reads it from wherever it is, and must not depend on the meeting service
/// being built.
enum ForkMeetingActivity {
    /// Posted on the main thread when the last recording, final pass,
    /// transcription or summary ends.
    static let didBecomeIdle = Notification.Name("fork.meetings.activity.idle")
    /// Posted on the main thread after any change of the tally: the
    /// transcriber waits for the final passes to end.
    static let didChange = Notification.Name("fork.meetings.activity.change")

    struct Tally: Equatable {
        var recording = false
        var finalizing = 0
        var transcribing = false
        var summarizing = false

        var isBusy: Bool { recording || finalizing > 0 || transcribing || summarizing }
    }

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var tally = Tally()
    }

    private static let shared = Shared()

    static var isBusy: Bool { tally.isBusy }

    static var tally: Tally {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.tally
    }

    /// The service: a recording started (or is starting), or ended.
    static func setRecording(_ recording: Bool) {
        change { $0.recording = recording }
    }

    /// The transcriber: a transcription runs or waits, or none any more.
    static func setTranscribing(_ transcribing: Bool) {
        change { $0.transcribing = transcribing }
    }

    /// The summarizer: a summary runs or waits, or none any more. An
    /// update would quit the app in the middle of it.
    static func setSummarizing(_ summarizing: Bool) {
        change { $0.summarizing = summarizing }
    }

    /// The finalizer: one more final pass queued.
    static func beginFinalizing() {
        change { $0.finalizing += 1 }
    }

    /// The finalizer: a final pass ended, however it ended.
    static func endFinalizing() {
        change { $0.finalizing = max(0, $0.finalizing - 1) }
    }

    private static func change(_ body: (inout Tally) -> Void) {
        shared.lock.lock()
        let before = shared.tally
        body(&shared.tally)
        let after = shared.tally
        shared.lock.unlock()
        guard after != before else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: nil)
            if before.isBusy && !after.isBusy { NotificationCenter.default.post(name: didBecomeIdle, object: nil) }
        }
    }
}
