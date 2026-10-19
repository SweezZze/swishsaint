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
/// at the start of the island's top row, before the page's own leading
/// control (the magnifier). The trailing side keeps the clipboard's actions
/// as they are: beside the camera, a side holds only about a hundred points.
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
            // on the row's leading side and puts the tabs before it.
            content.transformPreference(NotchBandKey.self) { items in
                items.leading = AnyView(ForkNotchDictationsLeading(page: items.leading))
            }
        }
    }
}

/// The row's leading side: Clipboard and Dictations as two of the island's
/// glyph buttons, the chosen one filled like the clipboard's pinned filter,
/// then the page's own control. The tabs lead, so they stay put when the
/// magnifier gives way to the search field. Where a side beside the camera
/// has no room for both tabs, one button switches between the two.
struct ForkNotchDictationsLeading: View {
    let page: AnyView?
    @ObservedObject private var state = ForkNotchDictations.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                NotchIconButton(symbol: "doc.on.clipboard", title: NotchModule.clipboard.title(l10n.language),
                                selected: state.tab == .clipboard) {
                    state.tab = .clipboard
                }
                NotchIconButton(symbol: NotchControlItem.dictation.symbol, title: ForkNotchDictations.title(l10n.language),
                                selected: state.tab == .dictations) {
                    state.tab = .dictations
                }
                if let page { page }
            }
            HStack(spacing: 6) {
                NotchIconButton(symbol: NotchControlItem.dictation.symbol, title: ForkNotchDictations.title(l10n.language),
                                selected: state.tab == .dictations) {
                    state.tab = state.tab == .dictations ? .clipboard : .dictations
                }
                if let page { page }
            }
        }
    }
}

/// The filter, the clearing of unpinned dictations and the Dictation
/// settings, at the trailing end of the island's top row: three buttons
/// where the clipboard page has its three, so nothing moves between tabs.
struct ForkNotchDictationsHeaderActions: View {
    /// The window's page keeps a filter of its own.
    let inWindow: Bool
    @ObservedObject private var state = ForkNotchDictations.shared
    @ObservedObject private var archive = ForkDictationArchive.shared
    @ObservedObject private var l10n = L10n.shared
    private var text: ForkDictationStrings { ForkDictationStrings.strings(l10n.language) }

    var body: some View {
        let pinnedOnly = state.pinnedOnly(inWindow: inWindow)
        // A filter's glyph: the row's pin keeps the island open.
        NotchIconButton(symbol: pinnedOnly ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle",
                        title: text.historyPinned, selected: pinnedOnly) {
            state.setPinnedOnly(!pinnedOnly, inWindow: inWindow)
        }
        NotchIconButton(symbol: "trash", title: text.historyClearUnpinned,
                        action: ForkNotchDictations.confirmClearUnpinned)
            .disabled(ForkNotchDictationsSupport.clearable(archive.records).isEmpty)
        NotchIconButton(symbol: "gearshape", title: text.historySettings, action: ForkNotchDictations.openSettings)
    }
}

/// What the window's top row leads with: the page it shows, drawn as the
/// island draws its chosen Dictations tab.
struct ForkNotchDictationsMark: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let title = ForkNotchDictations.title(l10n.language)
        Image(systemName: NotchControlItem.dictation.symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .help(title)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The island's Dictations button among its controls (seam
/// `notch-dictation3`): it goes to the Dictations tab without closing the
/// island, and lights up while a dictation listens.
struct ForkNotchDictationTile: View {
    @ObservedObject private var state = ForkNotchDictations.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        NotchActionTile(symbol: NotchControlItem.dictation.symbol, title: ForkNotchDictations.title(l10n.language),
                        active: state.listening, accent: .selection) {
            ForkNotchDictations.show()
        }
    }
}
