// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import SwiftUI

extension View {
    /// The island's clipboard page with its Dictations tab (seam
    /// `notch-dictations`). Without dictation, the page is untouched.
    func forkDictationsTab(service: NotchService, size: CGSize) -> some View {
        modifier(ForkNotchDictationsTabs(service: service, size: size))
    }
}

/// The clipboard page, or the dictations in its place, with the two tabs
/// after the page's own leading control (the magnifier) in the island's top
/// row. The trailing side keeps the clipboard's actions as they are: beside
/// the camera, a side holds only about a hundred points.
private struct ForkNotchDictationsTabs: ViewModifier {
    @ObservedObject var service: NotchService
    let size: CGSize
    @ObservedObject private var state = ForkNotchDictations.shared
    @AppStorage(ForkDefaultsKey.dictationEnabled) private var dictationEnabled = false
    @Environment(\.notchSettingsPreview) private var preview

    func body(content: Content) -> some View {
        if !dictationEnabled || preview {
            content
        } else if state.tab == .dictations {
            ForkNotchDictationsView(service: service, size: size)
        } else {
            // Applied outside the page, the transform sees what the page set
            // on the row's leading side and adds the tabs after it.
            content.transformPreference(NotchBandKey.self) { items in
                items.leading = AnyView(ForkNotchDictationsLeading(page: items.leading))
            }
        }
    }
}

/// The row's leading side: the page's own control, then Clipboard and
/// Dictations as two of the island's glyph buttons, the chosen one filled
/// like the clipboard's pinned filter. Where a side beside the camera has
/// no room for both, one button switches between the two.
struct ForkNotchDictationsLeading: View {
    let page: AnyView?
    @ObservedObject private var state = ForkNotchDictations.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                if let page { page }
                NotchIconButton(symbol: "doc.on.clipboard", title: NotchModule.clipboard.title(l10n.language),
                                selected: state.tab == .clipboard) {
                    state.tab = .clipboard
                }
                NotchIconButton(symbol: "waveform", title: ForkNotchDictations.title(l10n.language),
                                selected: state.tab == .dictations) {
                    state.tab = .dictations
                }
            }
            HStack(spacing: 6) {
                if let page { page }
                NotchIconButton(symbol: "waveform", title: ForkNotchDictations.title(l10n.language),
                                selected: state.tab == .dictations) {
                    state.tab = state.tab == .dictations ? .clipboard : .dictations
                }
            }
        }
    }
}

/// The pinned filter and the history's menu, at the trailing end of the
/// island's top row, where the clipboard page has its own.
struct ForkNotchDictationsHeaderActions: View {
    @ObservedObject private var state = ForkNotchDictations.shared
    @ObservedObject private var archive = ForkDictationArchive.shared
    @ObservedObject private var l10n = L10n.shared
    private var text: ForkDictationStrings { ForkDictationStrings.strings(l10n.language) }

    var body: some View {
        NotchIconButton(symbol: state.pinnedOnly ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle",
                        title: text.historyPinned, selected: state.pinnedOnly) {
            state.pinnedOnly.toggle()
        }
        NotchMenuButton(title: text.historyMore, items: [
            NotchMenuItem(title: FeatureStrings.clipboard(l10n.language).clearRecent, symbol: "trash",
                          enabled: !ForkNotchDictationsSupport.clearable(archive.records).isEmpty,
                          action: ForkNotchDictations.confirmClearUnpinned),
            .separator,
            NotchMenuItem(title: text.historySettings, symbol: "gearshape", action: ForkNotchDictations.openSettings),
        ], cornerRadius: 9) {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .help(text.historyMore)
    }
}

/// The island's Dictations button among its controls (seam
/// `notch-dictation3`): it goes to the Dictations tab without closing the
/// island, and lights up while a dictation listens.
struct ForkNotchDictationTile: View {
    @ObservedObject private var state = ForkNotchDictations.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        NotchActionTile(symbol: "waveform", title: ForkNotchDictations.title(l10n.language),
                        active: state.listening, accent: .selection) {
            ForkNotchDictations.show()
        }
    }
}
