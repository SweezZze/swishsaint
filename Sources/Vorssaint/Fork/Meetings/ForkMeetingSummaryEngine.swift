// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence's on-device model (`FoundationModels`, macOS 26),
/// for the meetings' summaries. Nothing is sent anywhere: the model runs on
/// this Mac, and the Private Cloud Compute one is never asked.
///
/// Built with an SDK that has no `FoundationModels` (the official CI's
/// Swift 6.0.3, macOS 15.2), it compiles to "unavailable", and every button
/// of the summary stays hidden. On a Mac where Apple Intelligence is off,
/// not ready yet, or not possible, the same.
///
/// Each part of the transcript is read by a session of its own, so the
/// model's window (about 4 000 tokens) never fills with the parts before;
/// one that fails is cut in two and tried again, down to
/// `ForkMeetingSummary.smallestPart`, then left out and counted
/// (`skipped`): the summary then says it is partial.
enum ForkMeetingSummaryEngine {
    struct Outcome: Equatable {
        var notes: ForkMeetingSummaryNotes
        var parts: Int
        var skipped: Int
        /// Calls to the model, merges included.
        var calls: Int
        var seconds: TimeInterval
    }

    /// Whether a summary can be written on this Mac now.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return ForkMeetingAppleModel.isReady }
        #endif
        return false
    }

    /// Why not, in a word for the logs.
    static var availabilityDescription: String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return ForkMeetingAppleModel.availabilityDescription }
        return "macOS older than 26"
        #else
        return "built without FoundationModels"
        #endif
    }

    /// Whether the model writes this language (a base code, "fr"); an
    /// unknown language is tried.
    static func supports(language: String?) -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard let language else { return true }
            return ForkMeetingAppleModel.supports(language)
        }
        #endif
        return false
    }

    /// The notes of a whole transcript. Off the main thread; `isCancelled`
    /// is read between two calls, `progress` told after each (0…1).
    static func summarize(_ transcript: String, language: String?, me: String, others: String,
                          isCancelled: @escaping () -> Bool,
                          progress: @escaping (Double) -> Void) async -> Result<Outcome, ForkMeetingSummaryFailure> {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard ForkMeetingAppleModel.isReady else { return .failure(.unavailable) }
            guard supports(language: language) else { return .failure(.languageUnsupported) }
            let model = ForkMeetingAppleModel(instructions: ForkMeetingSummary.instructions(language: language, me: me,
                                                                                             others: others))
            return await model.summarize(transcript, isCancelled: isCancelled, progress: progress)
        }
        #endif
        return .failure(.unavailable)
    }
}

#if canImport(FoundationModels)
/// The model, its instructions, and the walk through the parts.
@available(macOS 26, *)
private final class ForkMeetingAppleModel {
    /// Permissive for transformations: a meeting may speak of anything, and
    /// a summary only says again what was said. Generation as text, which
    /// this setting needs.
    private static func model() -> SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    static var isReady: Bool { model().availability == .available }

    static var availabilityDescription: String {
        switch model().availability {
        case .available: return "available"
        case let .unavailable(reason): return String(describing: reason)
        }
    }

    static func supports(_ language: String) -> Bool {
        model().supportsLocale(Locale(identifier: language))
    }

    private let model = ForkMeetingAppleModel.model()
    private let instructions: String
    private var skipped = 0
    private var calls = 0

    init(instructions: String) {
        self.instructions = instructions
    }

    func summarize(_ transcript: String, isCancelled: @escaping () -> Bool,
                   progress: @escaping (Double) -> Void) async -> Result<ForkMeetingSummaryEngine.Outcome, ForkMeetingSummaryFailure> {
        let started = Date()
        let parts = ForkMeetingSummary.parts(transcript)
        guard !parts.isEmpty else { return .failure(.noTranscript) }
        var notes: [ForkMeetingSummaryNotes] = []
        for (index, part) in parts.enumerated() {
            guard !isCancelled() else { return .failure(.cancelled) }
            let read = await self.notes(of: part, index: index, count: parts.count, isCancelled: isCancelled)
            if case let .failure(failure) = read { return .failure(failure) }
            if case let .success(found) = read, let found { notes.append(found) }
            progress(ForkMeetingSummary.progress(done: index + 1, parts: parts.count))
        }
        guard !notes.isEmpty else { return .failure(.refused) }
        // The parts' notes, merged until one set is left.
        var texts = notes.map(\.text)
        var merged = notes.count == 1 ? notes[0] : nil
        while texts.count > 1 {
            guard !isCancelled() else { return .failure(.cancelled) }
            var next: [String] = []
            for group in ForkMeetingSummary.mergeGroups(texts) {
                let answer = try? await respond(ForkMeetingSummary.mergePrompt(group))
                var set = answer.map(ForkMeetingSummary.notes(from:)) ?? ForkMeetingSummaryNotes()
                // A merge refused keeps what the parts said, put together.
                if set.isEmpty || set.points.isEmpty { set = Self.union(group.map(ForkMeetingSummary.notes(from:))) }
                next.append(set.text)
                merged = set
            }
            texts = next
        }
        progress(1)
        guard let merged, !merged.isEmpty else { return .failure(.engine) }
        return .success(ForkMeetingSummaryEngine.Outcome(notes: merged, parts: parts.count, skipped: skipped,
                                                         calls: calls, seconds: Date().timeIntervalSince(started)))
    }

    /// One part's notes; `nil` when the model would not take it even cut
    /// small. A model that went away fails the whole summary.
    private func notes(of part: String, index: Int, count: Int,
                       isCancelled: @escaping () -> Bool) async -> Result<ForkMeetingSummaryNotes?, ForkMeetingSummaryFailure> {
        guard !isCancelled() else { return .failure(.cancelled) }
        do {
            let answer = try await respond(ForkMeetingSummary.partPrompt(part, index: index, count: count))
            let found = ForkMeetingSummary.notes(from: answer)
            return .success(found.isEmpty ? nil : found)
        } catch {
            guard Self.isReady else { return .failure(.unavailable) }
            // Too long for the window, or refused: two halves.
            let halves = ForkMeetingSummary.parts(part, limit: part.count / 2 + 1)
            guard halves.count > 1, part.count / 2 >= ForkMeetingSummary.smallestPart else {
                skipped += 1
                return .success(nil)
            }
            var found: [ForkMeetingSummaryNotes] = []
            for half in halves {
                let read = await notes(of: half, index: index, count: count, isCancelled: isCancelled)
                if case let .failure(failure) = read { return .failure(failure) }
                if case let .success(notes) = read, let notes { found.append(notes) }
            }
            return .success(found.isEmpty ? nil : Self.union(found))
        }
    }

    private func respond(_ prompt: String) async throws -> String {
        calls += 1
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 700)
        return try await session.respond(to: prompt, options: options).content
    }

    static func union(_ sets: [ForkMeetingSummaryNotes]) -> ForkMeetingSummaryNotes {
        var all = ForkMeetingSummaryNotes()
        for set in sets {
            all.points += set.points.filter { !all.points.contains($0) }
            all.decisions += set.decisions.filter { !all.decisions.contains($0) }
            all.actions += set.actions.filter { !all.actions.contains($0) }
        }
        return all
    }
}
#endif
