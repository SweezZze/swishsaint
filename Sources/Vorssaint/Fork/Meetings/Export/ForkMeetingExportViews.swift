// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import SwiftUI

/// The ⋯ menu's "Export To": one item per exporter set up, and nothing at
/// all without one (only "Export Audio (M4A)…" stays).
struct ForkMeetingExportMenu: View {
    let folder: URL
    let live: Bool
    let text: ForkMeetingStrings

    @ObservedObject private var exports = ForkMeetingExports.shared

    var body: some View {
        if exports.hasExporters {
            Menu(text.actionExportTo) {
                ForEach(exports.configs) { config in
                    Button(config.title(text)) { exports.export(folder, to: config.id) }
                        .disabled(live || !exports.isConfigured(config)
                                    || exports.pending.contains(ForkMeetingExports.key(folder, config.id)))
                }
            }
        }
    }
}

/// The detail's line: each exporter, and what became of this meeting there
/// (✓ and when, ✗ with why and Retry, sending, or nothing yet). Absent
/// without an exporter.
struct ForkMeetingExportStatus: View {
    let folder: URL
    let live: Bool
    let text: ForkMeetingStrings
    let language: AppLanguage

    @ObservedObject private var exports = ForkMeetingExports.shared

    var body: some View {
        if exports.hasExporters {
            VStack(alignment: .leading, spacing: 6) {
                Text(text.exportsTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(exports.configs) { config in
                    row(config)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .task(id: folder.standardizedFileURL.path) { exports.refreshResults(folder) }
        }
    }

    /// What failed last here, refused before it began or written.
    private func failure(_ config: ForkMeetingExporterConfig) -> ForkMeetingExportFailure? {
        let key = ForkMeetingExports.key(folder, config.id)
        guard !exports.pending.contains(key) else { return nil }
        if let refusal = exports.refusals[key] { return refusal }
        guard let result = exports.result(folder, config.id), result.status == .failed else { return nil }
        return result.failure ?? .network
    }

    @ViewBuilder private func row(_ config: ForkMeetingExporterConfig) -> some View {
        let key = ForkMeetingExports.key(folder, config.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(config.title(text))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if exports.pending.contains(key) {
                    ProgressView().controlSize(.small)
                    Text(text.exportSending).foregroundStyle(.secondary)
                } else if let failure = failure(config) {
                    failed(failure, config: config)
                } else if let result = exports.result(folder, config.id), result.status == .done {
                    Label(result.at.map { ForkMeetingLibraryText.time($0, language: language) } ?? text.exportDone,
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help(text.exportDone)
                        .accessibilityLabel(text.exportDone)
                } else {
                    Text(text.exportNotYet).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if let failure = failure(config) {
                Text(failure.message(text))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func failed(_ failure: ForkMeetingExportFailure, config: ForkMeetingExporterConfig) -> some View {
        Label(text.exportFailedShort, systemImage: "xmark.circle.fill")
            .foregroundStyle(.red)
        Button(text.exportRetry) { exports.export(folder, to: config.id) }
            .controlSize(.small)
            .disabled(live || !exports.isConfigured(config))
            .help(failure.message(text))
    }
}
