// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import SwiftUI

/// One dictation of the history, as a row of the clipboard history's list:
/// play on the left, the words, a line of facts under them, the actions on
/// hover. A click selects and unfolds it, a double click pastes it.
struct ForkDictationHistoryRowView: View {
    enum Playback: Equatable { case stopped, playing, paused }

    let record: ForkDictationRecord
    let tokens: [String]
    let shortcutIndex: Int?
    let isSelected: Bool
    let playback: Playback
    let clock: ForkDictationHistoryPlaybackClock
    let isRetranscribing: Bool
    let problem: String?
    let justCopied: Bool
    /// Pinned dictations and search results sit under no day: their own
    /// date says which, unless it is today.
    let showsDay: Bool
    let text: ForkDictationStrings
    let onSelect: () -> Void

    @State private var isHovered = false

    private var panel: ForkDictationHistoryPanel { .shared }
    private var hasText: Bool { !record.text.isEmpty }
    private var isFailed: Bool { record.outcome == .failed && !hasText }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            playButton
            VStack(alignment: .leading, spacing: 4) {
                words
                facts
                // A failed dictation says what went wrong in its title.
                if let problem, !isFailed {
                    Text(problem)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                }
                if playback != .stopped {
                    ForkDictationHistoryProgress(clock: clock)
                        .transition(.opacity)
                }
                if isFailed, record.hasAudio, !isRetranscribing {
                    Button(text.historyRetranscribe) {
                        panel.retranscribe(record, with: ForkDictationEngines.setting)
                    }
                    .controlSize(.small)
                    .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 48)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.24) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) { isHovered = hovering }
        }
        .onTapGesture(count: 2) { if hasText { panel.paste(record) } }
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .contextMenu { actions }
        .animation(.easeOut(duration: 0.15), value: playback)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: text.historyPaste) { panel.paste(record) }
        .accessibilityAction(named: playback == .playing ? text.historyPause : text.historyPlay) {
            if record.hasAudio { panel.model.player.toggle(record) }
        }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(isHovered ? 0.13 : 0.09) }
        if isHovered { return Color.primary.opacity(0.055) }
        return .clear
    }

    // MARK: - Parts

    /// Listening is the reason this history exists, so it is always one
    /// click away. Without audio the mark says what the row is.
    @ViewBuilder
    private var playButton: some View {
        if record.hasAudio {
            Button {
                panel.model.player.toggle(record)
            } label: {
                Image(systemName: playback == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(playback == .stopped ? Color.primary.opacity(0.75) : Color.white)
                    .offset(x: playback == .playing ? 0 : 0.5)
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(playback == .stopped ? Color.primary.opacity(0.08) : Color.accentColor))
            }
            .buttonStyle(.plain)
            .help(playback == .playing ? text.historyPause : text.historyPlay)
            .accessibilityLabel(playback == .playing ? text.historyPause : text.historyPlay)
        } else {
            Image(systemName: isFailed ? "exclamationmark.triangle" : "text.alignleft")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFailed ? Color.orange : Color.secondary)
                .frame(width: 25, height: 25)
        }
    }

    @ViewBuilder
    private var words: some View {
        if isRetranscribing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(text.historyRetranscribing)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else if isFailed {
            Text(problem ?? text.historyFailed)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
        } else {
            SearchHighlightText.text(record.text, tokens: tokens, fontSize: 12)
                .font(.system(size: 12))
                .lineLimit(isSelected ? nil : 2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// When, how long, which engine, and where it went.
    private var facts: some View {
        HStack(spacing: 4) {
            if record.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(Color.accentColor)
            }
            if showsDay, !Calendar.current.isDateInToday(record.date) {
                Text(record.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()
                    .locale(L10n.shared.language.formattingLocale())))
            } else {
                Text(record.date, style: .time)
            }
            separator
            Text(ForkDictationHistoryListing.duration(record.duration))
                .monospacedDigit()
            separator
            Text(record.engine == "apple" ? text.engineApple : text.parakeetTitle)
            if let app = ForkDictationHistoryTarget.lookup(record) {
                separator
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                Text(app.name)
                    .lineLimit(1)
            }
            if !record.hasAudio, !isFailed {
                separator
                Text(text.historyAudioExpired)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var trailing: some View {
        if isHovered {
            HStack(spacing: 4) {
                if hasText {
                    hoverButton(justCopied ? "checkmark" : "doc.on.doc", help: text.historyCopy) {
                        panel.copy(record)
                    }
                }
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        } else if justCopied {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
        } else if let shortcutIndex {
            Text("⌘\(shortcutIndex + 1)")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private func hoverButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var actions: some View {
        Button(text.historyPaste) { panel.paste(record) }
            .disabled(!hasText)
        Button(text.historyCopy) { panel.copy(record) }
            .disabled(!hasText)
        Divider()
        if record.hasAudio {
            Button(playback == .playing ? text.historyPause : text.historyPlay) {
                panel.model.player.toggle(record)
            }
            Menu(text.historyRetranscribe) {
                Button(String(format: text.historyRetranscribeWithFormat, text.parakeetTitle)) {
                    panel.retranscribe(record, with: .parakeet)
                }
                Button(String(format: text.historyRetranscribeWithFormat, text.engineApple)) {
                    panel.retranscribe(record, with: .apple)
                }
            }
            .disabled(isRetranscribing)
        }
        Button(record.isPinned ? text.historyUnpin : text.historyPin) { panel.togglePin(record) }
        if record.hasAudio {
            Button(text.historyShowInFinder) { panel.showInFinder(record) }
        }
        Divider()
        Button(text.historyDelete, role: .destructive) { panel.delete(record) }
    }
}

/// The thin bar under a dictation being played. It alone follows the
/// player's clock.
private struct ForkDictationHistoryProgress: View {
    @ObservedObject var clock: ForkDictationHistoryPlaybackClock

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Color.accentColor)
                    .frame(width: max(3, proxy.size.width * clock.progress))
            }
        }
        .frame(height: 3)
        .frame(maxWidth: 220)
        .accessibilityHidden(true)
    }
}

/// The app a dictation went to, looked up once per app, as the clipboard
/// history does for where a copy came from.
enum ForkDictationHistoryTarget {
    private static var cache: [String: (name: String, icon: NSImage?)] = [:]

    static func lookup(_ record: ForkDictationRecord) -> (name: String, icon: NSImage?)? {
        guard let bundleID = record.targetBundleID else {
            return record.targetName.map { ($0, nil) }
        }
        if let cached = cache[bundleID] { return cached }
        guard let url = InstalledApps.url(for: bundleID) else {
            return record.targetName.map { ($0, nil) }
        }
        let app = (name: InstalledApps.name(for: bundleID), icon: Optional(NSWorkspace.shared.icon(forFile: url.path)))
        cache[bundleID] = app
        return app
    }
}
