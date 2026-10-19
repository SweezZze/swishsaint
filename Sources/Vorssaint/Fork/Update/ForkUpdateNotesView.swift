// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import SwiftUI

/// The update window's content: what the builds skipped since the installed
/// one bring, as their authors wrote it. Laid out like the official
/// pre-install preview (`UpdatePreviewView`) and typeset like its release
/// notes (`ReleaseNotesContent`), so it reads as part of the same app.
///
/// Before the install it asks (Later, Download and install); once
/// installed it only tells, without the official section: the official
/// What's New window covers that version.
struct ForkUpdateNotesView: View {
    enum Mode: Equatable {
        case available
        case installed
    }

    let summary: ForkUpdateNotes.Summary
    let mode: Mode
    /// The app's name, as the Finder shows it ("Swishsaint").
    let appName: String
    var onInstall: () -> Void = {}
    var onClose: () -> Void = {}

    @ObservedObject private var l10n = L10n.shared

    private var text: ForkUpdateStrings { ForkUpdateStrings.strings(l10n.language) }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
            }
            // As tall as the notes, up to the official preview's height.
            .frame(minHeight: 120, maxHeight: 440)

            Divider()

            footer
        }
        .frame(width: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onClose)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode == .available ? text.notesAvailableTitle : text.notesInstalledTitle)
                    .font(.system(size: 22, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var subtitle: String {
        let build = String(format: text.notesBuildFormat, appName, String(summary.build))
        return summary.isPrerelease ? "\(build) · \(text.notesBeta)" : build
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            if mode == .available, let upstream = summary.upstream {
                section(text.notesOfficialSection) {
                    item(String(format: summary.upstreamChanged ? text.notesOfficialNewFormat
                                                                : text.notesOfficialSameFormat, upstream),
                         symbol: "arrow.down.circle.fill", prominent: summary.upstreamChanged)
                }
            }
            ForEach(summary.authors, id: \.name) { author in
                section(author.name) {
                    ForEach(author.items, id: \.self) { line in
                        item(line, symbol: "person.crop.circle.fill")
                    }
                }
            }
            if !summary.other.isEmpty {
                section(text.notesOtherSection) {
                    ForEach(summary.other, id: \.self) { line in
                        item(line, symbol: "circle.fill", small: true)
                    }
                }
            }
            if !summary.hasNotes {
                fallbackNote
            }
        }
    }

    /// What the official notes say of a version without notes, drawn as
    /// they draw it.
    private var fallbackNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, alignment: .center)
            Text(l10n.s.obWhatsNewFallback)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Items: View>(_ title: String, @ViewBuilder items: () -> Items) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(1.2)
            items()
        }
    }

    /// A bullet as `ReleaseNotesContent` draws it: the symbol in the accent
    /// colour in an 18 pt column, the text beside it. A line that only
    /// reminds (the official version unchanged) stays secondary.
    private func item(_ line: String, symbol: String, prominent: Bool = true, small: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: small ? 6 : 12, weight: .semibold))
                .foregroundStyle(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 18, height: small ? 16 : nil, alignment: .center)
            Text(line)
                .font(.system(size: 12.5))
                .foregroundStyle(prominent ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if summary.includedBuilds > 1 {
                Text(String(format: text.notesIncludesFormat, summary.includedBuilds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            switch mode {
            case .available:
                Button(text.later, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(l10n.s.updateInstallButton, action: onInstall)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .installed:
                Button(l10n.s.obContinue, action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}
