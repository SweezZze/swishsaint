// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import Combine
import Foundation
import os

/// Summarizes a meeting on this Mac with Apple Intelligence
/// (`ForkMeetingSummaryEngine`), from its transcript: the points, the
/// decisions and the actions, in the meeting's language, into
/// `<name> summary.md` beside the video, noted in `meeting.json`.
///
/// - **Invisible when it cannot run**: no `FoundationModels` in the build,
///   macOS before 26, Apple Intelligence off or not ready. Nothing on the
///   page or in the detail says a word of it then.
/// - **One summary at a time**; the others wait their turn. One started on
///   its own after a transcript (`fork.meetings.summarize`, off by default)
///   also waits while a meeting records.
/// - Cancelled between two calls to the model; nothing is written then, and
///   a summary already there stays.
/// - **The updater waits** while a job runs or waits (`ForkMeetingActivity`),
///   and the Mac stays awake for the one running, like a transcription.
///
/// State on the main thread only (hence `@unchecked Sendable`, like the
/// finalizer); the work in a detached task, which hands its answers back
/// to the main thread.
final class ForkMeetingSummarizer: ObservableObject, @unchecked Sendable {
    static let shared = ForkMeetingSummarizer()

    enum Phase: Equatable {
        case idle
        case waiting
        case running(Double)
    }

    enum Outcome: Equatable {
        case done
        case failed(ForkMeetingSummaryFailure)
    }

    struct Job: Equatable {
        let folder: URL
        var id: UUID?
        let automatic: Bool
        let asked: Date

        func isFor(id other: UUID?, folder path: URL) -> Bool {
            if let id, let other, id == other { return true }
            return folder.standardizedFileURL.path == path.standardizedFileURL.path
        }
    }

    struct Running: Equatable {
        var job: Job
        var fraction: Double
    }

    @Published private(set) var running: Running? { didSet { activityChanged() } }
    @Published private(set) var waiting: [Job] = [] { didSet { activityChanged() } }
    /// What the last job of each meeting did, while the app runs.
    @Published private(set) var outcomes: [(job: Job, outcome: Outcome)] = []

    /// What the recipe measures of the last job.
    struct Measure: Equatable {
        var characters = 0
        var parts = 0
        var skipped = 0
        var calls = 0
        var seconds: TimeInterval = 0
    }

    private(set) var lastMeasure = Measure()

    private let store: ForkMeetingStore
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "fork.meetings", category: "summary")
    private var enabled = true
    private var cancelled: ForkMeetingSummaryStop?
    private var recordingWatch: AnyCancellable?

    init(store: ForkMeetingStore = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    /// Apple Intelligence can write a summary on this Mac: the buttons and
    /// the settings show only then. Read again when a page that shows them
    /// appears (`refreshAvailability`): the model may finish downloading, or
    /// Apple Intelligence be turned off, while the app runs.
    @Published private(set) var available = ForkMeetingSummaryEngine.isAvailable

    var isAvailable: Bool { available }

    func refreshAvailability() {
        let now = ForkMeetingSummaryEngine.isAvailable
        if now != available { available = now }
    }

    // MARK: - Asking

    /// "Summarize on This Mac", "Summarize Again". Main thread.
    @discardableResult
    func summarize(_ folder: URL, id: UUID?, automatic: Bool = false) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        // Apple Intelligence may have come (or gone) since a page last looked.
        refreshAvailability()
        guard enabled, isAvailable, phase(id: id, folder: folder) == .idle else { return false }
        outcomes.removeAll { $0.job.isFor(id: id, folder: folder) }
        waiting.append(Job(folder: folder, id: id, automatic: automatic, asked: Date()))
        startNext()
        return true
    }

    /// A transcript was just written: summarized when the setting asks.
    func transcriptWritten(_ folder: URL, id: UUID?, words: Int) {
        refreshAvailability()
        guard ForkMeetingSummary.summarizesAutomatically(
            featureOn: ForkMeetingService.shared.isWanted,
            settingOn: defaults.bool(forKey: ForkDefaultsKey.meetingsSummarize), available: isAvailable,
            words: words) else { return }
        summarize(folder, id: id, automatic: true)
    }

    func cancel(id: UUID?, folder: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        waiting.removeAll { $0.isFor(id: id, folder: folder) }
        if running?.job.isFor(id: id, folder: folder) == true { cancelled?.cancel() }
    }

    func phase(id: UUID?, folder: URL) -> Phase {
        if let running, running.job.isFor(id: id, folder: folder) { return .running(running.fraction) }
        return waiting.contains { $0.isFor(id: id, folder: folder) } ? .waiting : .idle
    }

    func outcome(id: UUID?, folder: URL) -> Outcome? {
        outcomes.last { $0.job.isFor(id: id, folder: folder) }?.outcome
    }

    /// The feature turned off: the job stops, the queue empties.
    func sync(enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.enabled = enabled
        guard enabled else {
            recordingWatch = nil
            waiting.removeAll()
            cancelled?.cancel()
            return
        }
        guard recordingWatch == nil else { return }
        recordingWatch = ForkMeetingService.shared.$isRecording.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.startNext() }
    }

    /// Main thread: the updater holds while a job runs or waits.
    private func activityChanged() {
        ForkMeetingActivity.setSummarizing(running != nil || !waiting.isEmpty)
    }

    // MARK: - Running

    private func startNext() {
        guard running == nil, enabled else { return }
        let recording = ForkMeetingService.shared.isRecording
        guard let index = waiting.firstIndex(where: { !$0.automatic || !recording }) else { return }
        let job = waiting.remove(at: index)
        let stop = ForkMeetingSummaryStop()
        cancelled = stop
        running = Running(job: job, fraction: 0)
        let text = ForkMeetingStrings.current
        let me = text.transcriptMeLabel, others = text.transcriptOthersLabel
        let app = L10n.shared.language
        let store = self.store
        Task.detached(priority: .utility) { [weak self] in
            // Like a transcription: the Mac must not doze off in the middle
            // of a long meeting's summary.
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated],
                                                                 reason: "Summarizing a meeting")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let result = await Self.work(job, store: store, me: me, others: others, app: app, stop: stop) { fraction in
                DispatchQueue.main.async { self?.progressed(fraction, of: job) }
            }
            DispatchQueue.main.async { self?.finished(job, result) }
        }
    }

    private func progressed(_ fraction: Double, of job: Job) {
        guard var running, running.job == job, fraction > running.fraction else { return }
        running.fraction = fraction
        self.running = running
    }

    private func finished(_ job: Job, _ result: (Result<URL, ForkMeetingSummaryFailure>, Measure)) {
        running = nil
        cancelled = nil
        lastMeasure = result.1
        let outcome: Outcome
        switch result.0 {
        case .success: outcome = .done
        case let .failure(failure): outcome = .failed(failure)
        }
        outcomes.removeAll { $0.job.isFor(id: job.id, folder: job.folder) }
        outcomes.append((job, outcome))
        log.notice("summary of \(job.folder.lastPathComponent, privacy: .private): \(String(describing: outcome), privacy: .public), \(result.1.parts) parts, \(result.1.calls) calls, \(result.1.seconds, format: .fixed(precision: 1)) s")
        if job.automatic, enabled, outcome != .failed(.cancelled), outcome != .failed(.folderGone) {
            ForkMeetingPresenter.shared.showSummary(folder: (try? result.0.get()) ?? job.folder, outcome: outcome)
        }
        startNext()
    }

    // MARK: - The work

    /// Off the main thread: the transcript read, summarized, the file
    /// written.
    private static func work(_ job: Job, store: ForkMeetingStore, me: String, others: String, app: AppLanguage,
                             stop: ForkMeetingSummaryStop,
                             progress: @escaping (Double) -> Void) async -> (Result<URL, ForkMeetingSummaryFailure>, Measure) {
        var measure = Measure()
        let source: ForkMeetingStore.SummarySource
        switch store.summarySource(job.folder, id: job.id) {
        case let .failure(failure):
            record(failure, job: job, store: store)
            return (.failure(failure), measure)
        case let .success(found):
            source = found
        }
        measure.characters = source.transcript.count
        let language = source.language
        let result = await ForkMeetingSummaryEngine.summarize(source.transcript, language: language, me: me, others: others,
                                                             isCancelled: { stop.isCancelled }, progress: progress)
        let outcome: ForkMeetingSummaryEngine.Outcome
        switch result {
        case let .failure(failure):
            record(failure, job: job, store: store)
            return (.failure(failure), measure)
        case let .success(done):
            outcome = done
        }
        measure.parts = outcome.parts
        measure.skipped = outcome.skipped
        measure.calls = outcome.calls
        measure.seconds = outcome.seconds
        guard !stop.isCancelled else { return (.failure(.cancelled), measure) }
        let headingLanguage = ForkMeetingSummary.headingLanguage(language, app: app)
        let text = ForkMeetingStrings.strings(headingLanguage)
        let title = source.title.flatMap { $0.isEmpty ? nil : $0 } ?? text.untitledMeeting
        let date = source.startedAt.map { ForkMeetingLibraryText.longDate($0, language: headingLanguage) }
        let markdown = ForkMeetingSummary.markdown(outcome.notes, title: title, date: date,
                                                   headings: text.summaryHeadings, partial: outcome.skipped > 0)
        let summaryRecord = ForkMeetingSummaryRecord(state: .done, at: Date(), language: language, parts: outcome.parts,
                                                     skipped: outcome.skipped)
        let written = store.writeSummary(markdown, record: summaryRecord, word: text.summaryFileWord,
                                         in: source.folder, id: source.id)
        if case let .failure(failure) = written { record(failure, job: job, store: store) }
        return (written, measure)
    }

    private static func record(_ failure: ForkMeetingSummaryFailure, job: Job, store: ForkMeetingStore) {
        guard failure != .cancelled, failure != .meetingInProgress, failure != .folderGone else { return }
        store.recordSummaryFailure(failure, at: Date(), in: job.folder, id: job.id)
    }
}

/// A job's stop, asked on the main thread, read between two calls.
final class ForkMeetingSummaryStop: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
