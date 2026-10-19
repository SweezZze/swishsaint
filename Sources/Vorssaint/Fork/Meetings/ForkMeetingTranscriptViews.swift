// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

/// The Meetings page's TRANSCRIPTION section: the setting that transcribes
/// each meeting saved, what Parakeet does, and its model when it is missing,
/// installed by the dictation's own flow (`ForkParakeetModelStore`). Off,
/// the setting is greyed out; the model can still be installed beforehand.
struct ForkMeetingTranscriptSection: View {
    let text: ForkMeetingStrings

    @ObservedObject private var l10n = L10n.shared
    @AppStorage(ForkDefaultsKey.meetingsEnabled) private var enabled = false
    @AppStorage(ForkDefaultsKey.meetingsTranscribe) private var transcribe = false
    @ObservedObject private var store = ForkParakeetModelStore.shared

    var body: some View {
        Section(text.transcriptTitle) {
            Toggle(isOn: $transcribe) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.transcribeAutomatically)
                    Text(text.transcribeCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!enabled)
            Text(text.transcriptLanguages(ForkMeetingTranscript.languageCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !store.isInstalled {
                ForkMeetingParakeetInstall(text: text, language: l10n.language, store: store)
            }
        }
    }
}

/// Parakeet missing: what it is, and the dictation's own download, with its
/// progress, its failure and its retry. The model is shared: installed here,
/// the dictation has it too.
struct ForkMeetingParakeetInstall: View {
    let text: ForkMeetingStrings
    let language: AppLanguage
    @ObservedObject var store: ForkParakeetModelStore

    private var dictation: ForkDictationStrings { ForkDictationStrings.strings(language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(text.transcriptNeedsParakeet, systemImage: "cpu")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                control
            }
            detail
        }
    }

    @ViewBuilder
    private var control: some View {
        switch store.state {
        case .notInstalled, .failed:
            Button(text.transcriptInstall) { store.install() }
                .controlSize(.small)
                .disabled(store.isBusy)
                .help(store.canCloneFromFluidAudioCache ? dictation.parakeetCloneCaption
                      : dictation.parakeetDownload(Self.size(store.totalBytes - store.resumableBytes)))
        case .downloading:
            Button(dictation.parakeetCancel) { store.cancel() }
                .controlSize(.small)
        case .verifying, .installed:
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.state {
        case .notInstalled:
            Text(store.canCloneFromFluidAudioCache ? dictation.parakeetCloneCaption
                 : dictation.parakeetDownload(Self.size(store.totalBytes - store.resumableBytes)))
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .downloading(progress, _, _):
            ProgressView(value: progress)
            Text(dictation.parakeetDownloading(progress.formatted(.percent.precision(.fractionLength(0)))))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .verifying:
            Text(dictation.parakeetVerifying)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Label(dictation.storeNetworkError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .installed:
            EmptyView()
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

extension ForkParakeetModelStore {
    var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }
}

/// The detail's transcript: transcribe this meeting, follow the job, open
/// the text, transcribe it again, or install Parakeet first.
struct ForkMeetingTranscriptRow: View {
    @ObservedObject var model: ForkMeetingLibraryModel
    let entry: ForkMeetingLibraryEntry
    let text: ForkMeetingStrings

    @ObservedObject private var transcriber = ForkMeetingTranscriber.shared
    @ObservedObject private var store = ForkParakeetModelStore.shared

    private var folder: URL { model.folderURL(entry) }
    private var phase: ForkMeetingTranscriber.Phase { transcriber.phase(id: entry.id, folder: folder) }
    /// Something to transcribe, that this app may write beside.
    private var transcribable: Bool {
        !entry.isReadOnly && !model.isLive(entry) && entry.playable != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text.transcriptTitle)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                actions
            }
            status
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .running, .waiting:
            Button(text.cancel) { model.cancelTranscript(entry) }
                .controlSize(.small)
        case .idle:
            HStack(spacing: 8) {
                if entry.transcript != nil {
                    Button(text.actionOpenTranscript) { model.openTranscript(entry) }
                        .controlSize(.small)
                }
                if store.isInstalled {
                    Button(entry.transcript == nil ? text.actionTranscribe : text.actionRetranscribe) {
                        model.transcribe(entry)
                    }
                    .controlSize(.small)
                    .disabled(!transcribable)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case let .running(fraction):
            ProgressView(value: fraction)
            caption(text.transcriptProgress(fraction.formatted(.percent.precision(.fractionLength(0)))))
        case .waiting:
            caption(text.transcriptWaiting)
        case .idle:
            if let failure = failure, let line = Self.line(for: failure, text: text) {
                Label(line, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if entry.transcript != nil, let words = entry.transcriptRecord?.words {
                caption(text.transcriptWords(words))
            }
            if !store.isInstalled {
                ForkMeetingParakeetInstall(text: text, language: model.currentLanguage, store: store)
            } else if entry.transcript == nil {
                caption(text.transcriptLanguages(ForkMeetingTranscript.languageCount))
            }
        }
    }

    /// This session's last failure, else the one `meeting.json` keeps for a
    /// meeting without a transcript.
    private var failure: ForkMeetingTranscriptFailure? {
        if let outcome = transcriber.outcome(id: entry.id, folder: folder) {
            if case let .failed(failure) = outcome { return failure }
            return nil
        }
        guard entry.transcript == nil, let record = entry.transcriptRecord, record.state == .failed else { return nil }
        return record.reason.flatMap(ForkMeetingTranscriptFailure.init(rawValue:)) ?? .engine
    }

    static func line(for failure: ForkMeetingTranscriptFailure, text: ForkMeetingStrings) -> String? {
        switch failure {
        case .cancelled: return nil
        case .modelMissing: return text.transcriptNeedsParakeet
        case .meetingInProgress: return text.refusedWhileRecording
        case .noAudio: return text.transcriptNoAudio
        case .unreadable, .engine, .folderGone, .notWritten: return text.transcriptFailedGeneric
        }
    }

    private func caption(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
