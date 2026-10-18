// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import SwiftUI

/// The dictations window's content, laid out like the clipboard history's
/// list: search on top, pinned dictations, then each day, newest first.
struct ForkDictationHistoryView: View {
    @ObservedObject var model: ForkDictationHistoryModel
    @ObservedObject private var archive = ForkDictationArchive.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var player: ForkDictationHistoryPlayer
    @FocusState private var searchFocused: Bool

    init(model: ForkDictationHistoryModel) {
        self.model = model
        _player = ObservedObject(wrappedValue: model.player)
    }

    private var text: ForkDictationStrings { ForkDictationStrings.strings(l10n.language) }

    /// A plain stack for an ordinary history, as the clipboard history does:
    /// scrolling only moves it. A very long one goes lazy.
    private static let eagerRowLimit = 300
    private static let topAnchorID = "dictation-history-top"

    var body: some View {
        let sections = model.sections()
        let ordered = ForkDictationHistoryListing.ordered(sections)
        VStack(spacing: 0) {
            toolbar
            Divider()
            if sections.isEmpty {
                emptyState(searching: !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                list(sections, ordered: ordered)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .onChange(of: model.presentationID) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
        // A record deleted or purged under the selection.
        .onChange(of: archive.records) { _, records in
            if let id = model.selectedID, !records.contains(where: { $0.id == id }) {
                model.select(ordered.first?.id, reveal: false)
            }
        }
        .onChange(of: model.query) { _, _ in
            model.select(model.ordered.first?.id, reveal: true)
        }
    }

    // MARK: - Toolbar and footer

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField(text.historySearchPlaceholder, text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            Button {
                ForkDictationHistoryPanel.shared.hide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(l10n.s.menuClose)
            .accessibilityLabel(l10n.s.menuClose)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                Text("\(archive.records.count)")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                ForkDictationHistoryPanel.shared.hide()
                ForkSettingsPages.open(.dictation)
                (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(l10n.s.menuSettings)
            .accessibilityLabel(l10n.s.menuSettings)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func emptyState(searching: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: searching ? "magnifyingglass" : "waveform")
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text.historyEmpty)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if !searching {
                Text(text.historyEmptyCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 270)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private func list(_ sections: [ForkDictationHistoryListing.Section],
                      ordered: [ForkDictationRecord]) -> some View {
        let shortcuts = Dictionary(uniqueKeysWithValues: ordered.prefix(9).enumerated().map { ($1.id, $0) })
        let tokens = ForkDictationHistoryListing.searchTokens(model.query)
        return ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if ordered.count <= Self.eagerRowLimit {
                        VStack(alignment: .leading, spacing: 0) {
                            rows(sections, shortcuts: shortcuts, tokens: tokens)
                        }
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            rows(sections, shortcuts: shortcuts, tokens: tokens)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.revealID) { _, _ in
                guard let id = model.selectedID else { return }
                proxy.scrollTo(id)
            }
            .onChange(of: model.presentationID) { _, _ in
                proxy.scrollTo(Self.topAnchorID, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func rows(_ sections: [ForkDictationHistoryListing.Section],
                      shortcuts: [UUID: Int], tokens: [String]) -> some View {
        Color.clear.frame(height: 6).id(Self.topAnchorID)
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            if index > 0, section.kind != .results {
                Divider()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
            }
            if let title = title(of: section.kind) {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(section.records.enumerated()), id: \.element.id) { rowIndex, record in
                ForkDictationHistoryRowView(
                    record: record,
                    tokens: tokens,
                    shortcutIndex: shortcuts[record.id],
                    isSelected: model.selectedID == record.id,
                    playback: player.playingID == record.id ? (player.isPaused ? .paused : .playing) : .stopped,
                    clock: player.clock,
                    isRetranscribing: model.retranscribing.contains(record.id),
                    problem: model.problems[record.id],
                    justCopied: model.flashed.contains(record.id),
                    showsDay: section.kind == .pinned || section.kind == .results,
                    text: text,
                    onSelect: { model.select(record.id, reveal: false) })
                    .id(record.id)
                if rowIndex < section.records.count - 1 {
                    Divider()
                        .padding(.leading, 43)
                        .padding(.trailing, 8)
                }
            }
        }
    }

    private func title(of kind: ForkDictationHistoryListing.Section.Kind) -> String? {
        switch kind {
        case .pinned:
            return text.historyPinned
        case .results:
            return nil
        case let .day(day):
            let calendar = Calendar.current
            if calendar.isDateInToday(day) { return text.historyToday }
            if calendar.isDateInYesterday(day) { return text.historyYesterday }
            let locale = l10n.language.formattingLocale()
            if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
                return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))
            }
            return day.formatted(.dateTime.day().month(.wide).year().locale(locale))
        }
    }
}
