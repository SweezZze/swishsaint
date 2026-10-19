// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import SwiftUI

/// The Dictations tab of the island's clipboard page, built as the
/// clipboard page is (`NotchClipboardView`): the same cards, sizes, fonts,
/// hover, search and keys, for what was said. Space listens to the
/// highlighted dictation. The floating window shows this same page when the
/// island cannot (`inWindow`).
struct ForkNotchDictationsView: View {
    @ObservedObject var service: NotchService
    let size: CGSize
    /// Shown in the floating window: Escape and ⌘1 to ⌘9 are its own, and
    /// the island's page layer is left alone.
    var inWindow = false
    @ObservedObject private var state = ForkNotchDictations.shared
    @ObservedObject private var player = ForkNotchDictations.shared.player
    @ObservedObject private var archive = ForkDictationArchive.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(ForkDefaultsKey.dictationKeepsHistory) private var keepsHistory = true
    @AppStorage(DefaultsKey.notchClipboardCardSize) private var cardSize = NotchClipboardCardSize.comfortable.rawValue
    @State private var query = ""
    @State private var copiedID: UUID?
    /// The card the arrow keys chose, the top result of a typed search, or
    /// the dictation opened from its bubble; Return uses it like a click.
    @State private var highlightedID: UUID?
    /// The dictation the bubble asked for, kept highlighted while the
    /// search and the filter clear to show it.
    @State private var pendingFocus: UUID?
    @FocusState private var searching: Bool
    @State private var searchOpen = false
    @State private var hoveredID: UUID?
    @State private var expandedID: UUID?
    @State private var dwell: (id: UUID, task: Task<Void, Never>)?
    @State private var closing: (id: UUID, task: Task<Void, Never>)?
    @State private var keyExpandedID: UUID?
    @State private var keysMoved = false
    @Environment(\.notchSettingsPreview) private var preview
    @Environment(\.notchGlassSurface) private var glassSurface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var text: ForkDictationStrings { ForkDictationStrings.strings(l10n.language) }
    private var clipboardText: ClipboardFeatureStrings { FeatureStrings.clipboard(l10n.language) }
    private static let listSpace = "fork.notch.dictations.list"

    /// The island and the window each keep their own filter.
    private var pinnedOnly: Bool { state.pinnedOnly(inWindow: inWindow) }

    private var entries: [ForkDictationRecord] {
        ForkNotchDictationsSupport.entries(archive.records, query: query, pinnedOnly: pinnedOnly)
    }

    private var searchTokens: [String] {
        ClipboardHistorySearch.searchTokens(for: query)
    }

    /// The island draws its text in white and never in the accent color, so a
    /// match stands out by weight alone.
    private func searchText(_ string: String, matching tokens: [String]) -> Text {
        SearchHighlightText.text(string, tokens: tokens, fontSize: 12, highlightColor: nil)
    }

    private var hasKeyboard: Bool { inWindow || service.panelIsKey }

    /// A dictation transcribed again: a small spinner in place of its actions.
    private var retranscribing: some View {
        ProgressView().controlSize(.small).frame(width: 28, height: 28)
            .help(text.historyRetranscribing)
            .accessibilityLabel(text.historyRetranscribing)
    }

    private var magnifier: some View {
        NotchIconButton(symbol: "magnifyingglass", title: text.historySearchPlaceholder, action: openSearch)
    }

    var body: some View {
        VStack(spacing: searchOpen ? NotchLayout.rowSpacing : 0) {
            searchField
            if !keepsHistory, archive.records.isEmpty {
                // As the clipboard page says it is off, and turns it on from here.
                VStack(spacing: 10) {
                    NotchEmptyView(symbol: NotchControlItem.dictation.symbol, message: text.historyOff)
                    Button(text.historyTurnOn) { keepsHistory = true }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .frame(maxHeight: .infinity)
            } else if entries.isEmpty {
                NotchEmptyView(symbol: pinnedOnly ? "pin" : NotchControlItem.dictation.symbol,
                               message: query.isEmpty && !pinnedOnly ? text.historyEmpty : clipboardText.noResults)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: NotchLayout.clipboardCardSpacing) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, record in
                                row(record, place: index)
                                    .id(record.id)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .coordinateSpace(.named(Self.listSpace))
                    .onChange(of: highlightedID) { previous, id in
                        guard let id else { return }
                        follow(id, from: previous, in: proxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The magnifier, the tabs and the history's own actions sit in the
        // island's top row, so the cards start at the top of the page.
        .notchBand(leading: {
            if inWindow {
                // The window names its page where the island shows its tabs.
                ForkNotchDictationsMark()
                if !searchOpen { magnifier }
            } else {
                ForkNotchDictationsLeading(page: searchOpen ? nil : AnyView(magnifier))
            }
        }, trailing: {
            HStack(spacing: 6) { ForkNotchDictationsHeaderActions(inWindow: inWindow) }
        })
        .onChange(of: query) { _, query in queryChanged(query) }
        // Resting on a dictation with the arrow keys opens it, as resting the pointer does.
        .task(id: highlightedID) {
            keyExpandedID = nil
            guard !preview, !comfortable, keysMoved, let id = highlightedID else { return }
            try? await Task.sleep(for: .seconds(NotchClipboardCardSize.keyDwell))
            guard !Task.isCancelled else { return }
            setOpen(keyID: id)
        }
        .background {
            if !preview {
                ForkNotchDictationsKeyMonitor(handleKey: {
                    handleKey(keyCode: $0, characters: $1, modifiers: $2, composing: $3, editing: $4)
                }, composed: { searchOpen = true })
                    .frame(width: 0, height: 0)
            }
        }
        .onAppear(perform: appeared)
        .onChange(of: state.focus) { _, _ in if !preview, let id = state.takeFocus() { reveal(id) } }
        .onChange(of: service.clipboardSearchRequest) { _, _ in if !preview, !inWindow { openSearch() } }
        .onChange(of: pinnedOnly) { _, _ in highlightedID = searchHighlight(keeping: nil) }
        .onChange(of: searchOpen) { _, open in
            guard !preview, !inWindow else { return }
            // Escape closes the search before it closes the island.
            service.setPageLayer(.clipboard, close: open ? { closeSearch() } : nil)
        }
        .onChange(of: searching) { _, focused in
            // A field left empty has nothing to keep open.
            if !focused, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { searchOpen = false }
        }
        .onDisappear {
            dwell?.task.cancel()
            closing?.task.cancel()
            guard !preview else { return }
            player.stop()
            if !inWindow { service.setPageLayer(.clipboard, close: nil) }
        }
        // A card that leaves the list hands the highlight on, as a new search does.
        .onChange(of: entries.map(\.id)) { _, _ in highlightedID = searchHighlight(keeping: highlightedID) }
        .onChange(of: service.clipboardPastePress) { _, press in
            guard let press, !preview, !inWindow else { return }
            activate(place: press.index)
        }
        .task(id: copiedID) {
            // The tick confirms one copy, then goes.
            guard copiedID != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            copiedID = nil
        }
    }

    /// The page opens on the dictation the bubble named, or on the latest
    /// one, so Return pastes it and the arrows move from it. Typing filters
    /// from the first key: the field takes the focus while still hidden.
    private func appeared() {
        guard !preview else { return }
        if let id = state.takeFocus() { reveal(id) } else { highlightedID = searchHighlight(keeping: nil) }
        searching = true
    }

    /// Shows one dictation: the search and a filter that hides it clear.
    private func reveal(_ id: UUID) {
        let record = archive.records.first { $0.id == id }
        guard record != nil else { return }
        pendingFocus = id
        keysMoved = false
        if !query.isEmpty { query = "" }
        searchOpen = false
        state.setPinnedOnly(ForkNotchDictationsSupport.keepsPinnedFilter(pinnedOnly, revealing: record), inWindow: inWindow)
        highlightedID = id
    }

    /// As on the clipboard page: the list follows the highlight the least
    /// that shows it whole, and as the page opens it moves by whole cards.
    private func follow(_ id: UUID, from previous: UUID?, in proxy: ScrollViewProxy) {
        var target = id, anchor: UnitPoint?
        if previous == nil {
            let list = size.height - (searchOpen ? NotchLayout.clipboardSearchHeight + NotchLayout.rowSpacing : 0)
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            let rows = NotchSupport.clipboardOpeningScroll(index: index, rowHeight: rowHeight,
                                                           spacing: NotchLayout.clipboardCardSpacing,
                                                           shown: NotchLayout.clipboardCompactCardHeight / 2,
                                                           visibleHeight: list)
            guard rows > 0 else { return }
            target = entries[rows].id
            anchor = .top
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: anchor) }
    }

    /// A new search starts from its top result. Text that reaches the
    /// hidden field shows it.
    private func queryChanged(_ query: String) {
        keysMoved = false
        if !query.isEmpty {
            pendingFocus = nil
            searchOpen = true
        }
        highlightedID = searchHighlight(keeping: nil)
    }

    /// The size Settings chose for the clipboard's entries: the same here.
    private var comfortable: Bool {
        NotchClipboardCardSize(stored: cardSize) == .comfortable
    }

    private var openedID: UUID? { expandedID ?? keyExpandedID }

    private var rowHeight: CGFloat {
        comfortable ? NotchLayout.clipboardCardHeight : NotchLayout.clipboardCompactCardHeight
    }

    private func row(_ record: ForkDictationRecord, place: Int) -> some View {
        let open = !comfortable && openedID == record.id
        return card(record) {
            if comfortable { expandedCard(record, place: place) } else { compactCard(record, place: place) }
        }
        .frame(height: rowHeight)
        .accessibilityHidden(open)
        .overlay(alignment: .top) {
            if open { openCard(record, place: place) }
        }
        .onHover { hover(record, $0) }
        .zIndex(open ? 1 : 0)
    }

    /// The open dictation, drawn over the cards around it as the clipboard
    /// page draws an open entry.
    private func openCard(_ record: ForkDictationRecord, place: Int) -> some View {
        GeometryReader { proxy in
            let visible = proxy.bounds(of: .named(Self.listSpace))?.height ?? size.height
            let height = min(openHeight(record), visible)
            card(record, lifted: true) { expandedCard(record, place: place) }
                .frame(height: height)
                .background {
                    let backing = RoundedRectangle(cornerRadius: 14, style: .continuous).inset(by: -1)
                    Group {
                        if glassSurface { backing.fill(.ultraThickMaterial) } else { backing.fill(.black) }
                    }
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                }
                .offset(y: NotchSupport.clipboardOpenOffset(rowTop: proxy.frame(in: .named(Self.listSpace)).minY,
                                                            rowHeight: proxy.size.height,
                                                            height: height, visibleHeight: visible))
        }
    }

    private func openHeight(_ record: ForkDictationRecord) -> CGFloat {
        guard !ForkNotchDictationsSupport.isFailed(record) else { return NotchLayout.clipboardCardHeight }
        return max(NotchLayout.clipboardCompactCardHeight,
                   NotchClipboardCardSize.openHeight(text: openText(record), width: openTextWidth, id: record.id))
    }

    private var openTextWidth: CGFloat {
        let scroller = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return size.width - 2 * 10 - scroller
    }

    private func openText(_ record: ForkDictationRecord) -> String {
        String(record.text.prefix(NotchClipboardCardSize.maximumOpenLines * 120))
    }

    private func setOpen(keyID: UUID?) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { keyExpandedID = keyID }
    }

    /// A compact dictation opens once the pointer has rested on it and
    /// closes a moment after the pointer leaves, as on the clipboard page.
    private func hover(_ record: ForkDictationRecord, _ inside: Bool) {
        guard !preview else { return }
        if inside {
            hoveredID = record.id
        } else if hoveredID == record.id {
            hoveredID = nil
        }
        guard !comfortable else { return }
        if inside {
            if closing?.id == record.id {
                closing?.task.cancel()
                closing = nil
            }
            dwell?.task.cancel()
            dwell = nil
            guard expandedID != record.id else { return }
            dwell = (record.id, Task { @MainActor in
                try? await Task.sleep(for: .seconds(NotchClipboardCardSize.dwell))
                guard !Task.isCancelled, hoveredID == record.id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expandedID = record.id }
            })
        } else {
            if dwell?.id == record.id {
                dwell?.task.cancel()
                dwell = nil
            }
            guard expandedID == record.id else { return }
            closing?.task.cancel()
            closing = (record.id, Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, expandedID == record.id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expandedID = nil }
            })
        }
    }

    /// A failed dictation's warning, the only color on the page.
    private var failedMark: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.85))
    }

    /// The details row leads with the app the dictation went to, or the
    /// dictation's glyph, as the clipboard's names an entry's source; a
    /// failed one with its warning. One 14-point column, so the dates line up.
    @ViewBuilder private func sourceBadge(_ record: ForkDictationRecord) -> some View {
        Group {
            if ForkNotchDictationsSupport.isFailed(record) {
                failedMark
            } else if let app = ForkNotchDictationApps.app(for: record) {
                Image(nsImage: app.icon)
                    .resizable().interpolation(.high)
                    .help(app.name)
                    .accessibilityLabel(app.name)
            } else {
                Image(systemName: NotchControlItem.dictation.symbol)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 14, height: 14)
    }

    /// What a compact card leads with: the dictation's glyph, as the
    /// clipboard's rows lead with the kind of entry; a failed one with its
    /// warning. The app shows once the card opens.
    private func leadingIcon(_ record: ForkDictationRecord) -> some View {
        Group {
            if ForkNotchDictationsSupport.isFailed(record) {
                failedMark
            } else {
                Image(systemName: NotchControlItem.dictation.symbol).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 14)
    }

    /// The card's surface, menu and accessibility actions, as the clipboard
    /// page draws an entry: pinned ones a step lighter, the highlight edged.
    private func card<Content: View>(_ record: ForkDictationRecord, lifted: Bool = false,
                                     @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return content()
            .modifier(NotchControlSurface(cornerRadius: 14, selected: record.isPinned))
            .background {
                if lifted {
                    if glassSurface { shape.fill(.ultraThickMaterial) } else { shape.fill(Color(white: 0.09)) }
                }
            }
            .overlay {
                ZStack {
                    if lifted { shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
                    shape.strokeBorder(.white.opacity(highlightedID == record.id ? 0.34 : 0), lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .contextMenu { actions(record) }
            .accessibilityActions {
                // Paste only where the app may type, as the card's menu offers it.
                if !record.text.isEmpty {
                    if permissions.accessibility { Button(text.historyPaste) { paste(record) } }
                    Button(text.historyCopy) { copy(record) }
                }
                if record.hasAudio {
                    Button(player.isPlaying(record.id) ? text.historyPause : text.historyPlay) { listen(record) }
                }
                Button(record.isPinned ? text.historyUnpin : text.historyPin) { state.togglePin(record) }
                Button(text.historyDelete) { remove(record) }
            }
    }

    /// One or two lines, with the actions shown only for the dictation in use.
    private func compactCard(_ record: ForkDictationRecord, place: Int) -> some View {
        let active = hoveredID == record.id || highlightedID == record.id || player.playingID == record.id
        return HStack(spacing: 8) {
            Button { activate(record) } label: {
                HStack(spacing: 8) {
                    leadingIcon(record)
                    preview(record, compact: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .clipped()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(NotchButtonStyle(lifts: false))
            .help(activateHelp)
            if archive.retranscribing == record.id {
                retranscribing
            } else if active {
                // The clipboard's three actions: listening stays on Space, the
                // card's menu and the open card.
                HStack(spacing: 2) { buttons(record, listens: false) }
            } else {
                HStack(spacing: 6) {
                    if record.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    if let shortcut = ForkNotchDictationsSupport.shortcutLabel(place: place, hasKeyboard: hasKeyboard) {
                        Text(shortcut).font(.system(size: 9.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    Text(record.date, style: .time).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// The whole dictation, with when, how long, which engine and the
    /// actions in the bottom row.
    private func expandedCard(_ record: ForkDictationRecord, place: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { activate(record) } label: {
                preview(record, compact: false, open: !comfortable)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .contentShape(Rectangle())
            }
            .buttonStyle(NotchButtonStyle(lifts: false))
            .help(activateHelp)
            HStack(spacing: 5) {
                sourceBadge(record)
                details(record)
                Spacer(minLength: 0)
                if let shortcut = ForkNotchDictationsSupport.shortcutLabel(place: place, hasKeyboard: hasKeyboard) {
                    Text(shortcut)
                        .font(.system(size: 9.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if archive.retranscribing == record.id {
                    retranscribing
                } else {
                    buttons(record, listens: true)
                }
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
    }

    /// When, how long and with which engine. A failure says why in the
    /// engine's place: the card's text says that it failed.
    private func details(_ record: ForkDictationRecord) -> some View {
        let failed = ForkNotchDictationsSupport.isFailed(record)
        return HStack(spacing: 4) {
            Text(record.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                .environment(\.locale, l10n.language.formattingLocale())
            Text("·")
            Text(ForkDictationHistoryListing.duration(record.duration)).monospacedDigit()
            Text("·")
            if failed || state.problem(record.id) != nil {
                Text(failureText(record)).foregroundStyle(.orange.opacity(0.85))
            } else {
                Text(ForkNotchDictationsSupport.engineName(record.engine, text: text))
            }
        }
        .font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
    }

    /// Listen, copy, pin and delete, in the clipboard page's buttons. Each
    /// keeps its place: what a dictation cannot do is drawn disabled.
    @ViewBuilder private func buttons(_ record: ForkDictationRecord, listens: Bool) -> some View {
        if listens {
            let playing = player.isPlaying(record.id)
            NotchIconButton(symbol: playing ? "pause.fill" : "play.fill",
                            title: playing ? text.historyPause : text.historyPlay) { listen(record) }
                .disabled(!record.hasAudio)
        }
        NotchIconButton(symbol: copiedID == record.id ? "checkmark" : "doc.on.doc",
                        title: copiedID == record.id ? clipboardText.copied : text.historyCopy) { copy(record) }
            .disabled(record.text.isEmpty)
        NotchIconButton(symbol: record.isPinned ? "pin.fill" : "pin",
                        title: record.isPinned ? text.historyUnpin : text.historyPin) { state.togglePin(record) }
        NotchIconButton(symbol: "trash", title: text.historyDelete) { remove(record) }
    }

    /// The card's menu: paste when the app may type, copy, listen, transcribe
    /// again, pin, show the audio, delete.
    @ViewBuilder private func actions(_ record: ForkDictationRecord) -> some View {
        let hasText = !record.text.isEmpty
        if permissions.accessibility {
            Button(text.historyPaste) { paste(record) }.disabled(!hasText)
        }
        Button(text.historyCopy) { copy(record) }.disabled(!hasText)
        if record.hasAudio {
            Button(player.isPlaying(record.id) ? text.historyPause : text.historyPlay) { listen(record) }
        }
        let engines = state.retranscription(record)
        Menu(text.historyRetranscribe) {
            Button(text.parakeetTitle) { state.retranscribe(record, with: .parakeet) }.disabled(!engines.parakeet)
            Button(text.engineApple) { state.retranscribe(record, with: .apple) }.disabled(!engines.apple)
        }
        .disabled(!engines.any)
        Divider()
        Button(record.isPinned ? text.historyUnpin : text.historyPin) { state.togglePin(record) }
        if record.hasAudio {
            Button(text.historyShowInFinder) { state.showInFinder(record) }
        }
        Divider()
        Button(text.historyDelete, role: .destructive) { remove(record) }
    }

    /// As the clipboard page says it: a click pastes, or copies without Accessibility.
    private var activateHelp: String {
        permissions.accessibility ? clipboardText.clickRowShortcut : clipboardText.copy
    }

    private func searchHighlight(keeping current: UUID?) -> UUID? {
        let ids = entries.map(\.id)
        if let pendingFocus, ids.contains(pendingFocus) { return pendingFocus }
        return NotchSupport.searchHighlight(keeping: current, in: ids, query: query)
            ?? NotchSupport.restingClipboardHighlight(entries.map { ($0.id, $0.isPinned) })
    }

    /// The field stays mounted and focused while hidden, as on the clipboard page.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(text.historySearchPlaceholder, text: $query).textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searching)
                .accessibilityLabel(text.historySearchPlaceholder)
        }
        .padding(.horizontal, 12)
        .frame(height: NotchLayout.clipboardSearchHeight)
        .modifier(NotchControlSurface(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(searching ? 0.34 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.15), value: searching)
        .frame(height: searchOpen ? NotchLayout.clipboardSearchHeight : 0, alignment: .top)
        .opacity(searchOpen ? 1 : 0)
        .clipped()
        .allowsHitTesting(searchOpen)
        .accessibilityHidden(!searchOpen)
    }

    private func openSearch() {
        searchOpen = true
        searching = true
    }

    private func closeSearch() {
        query = ""
        searchOpen = false
        searching = true
    }

    /// The clipboard page's keys, Space to listen, and in the window the
    /// keys the island handles itself: Escape and ⌘1 to ⌘9.
    private func handleKey(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags,
                           composing: Bool, editing: Bool) -> Bool {
        if inWindow, !composing {
            let commandOnly = modifiers.intersection([.command, .control, .option, .shift]) == .command
            if keyCode == 53, modifiers.isDisjoint(with: [.command, .control, .option]) {
                if searchOpen { closeSearch() } else { ForkNotchDictationsWindow.shared.hide() }
                return true
            }
            if let index = NotchClipboardPastePress.index(keyCode: keyCode, commandOnly: commandOnly) {
                activate(place: index)
                return true
            }
        }
        guard let key = ForkNotchDictationsSupport.key(keyCode: keyCode, characters: characters, modifiers: modifiers,
                                                       composing: composing, query: query) else { return false }
        let ids = entries.map(\.id)
        switch key {
        case .clipboard(.move(let backwards)):
            guard !ids.isEmpty else { return false }
            keysMoved = true
            pendingFocus = nil
            highlightedID = NotchSupport.steppedItem(from: highlightedID, in: ids, backwards: backwards)
            return true
        case .clipboard(.paste):
            guard let id = NotchSupport.clipboardPasteTarget(highlighted: highlightedID, in: ids),
                  let record = entries.first(where: { $0.id == id }) else { return false }
            activate(record)
            return true
        case .clipboard(.reveal):
            searchOpen = true
            if !editing { searching = true }
            return false
        case .listen:
            // Space never reaches the empty field: a search does not start with it.
            if let id = NotchSupport.clipboardPasteTarget(highlighted: highlightedID, in: ids),
               let record = entries.first(where: { $0.id == id }), record.hasAudio {
                listen(record)
            } else {
                NSSound.beep()
            }
            return true
        }
    }

    private func activate(place: Int) {
        let shown = entries
        guard shown.indices.contains(place) else {
            NSSound.beep()
            return
        }
        activate(shown[place])
    }

    /// Return or a click: pastes where the person was, or copies without
    /// Accessibility, as the clipboard page does.
    private func activate(_ record: ForkDictationRecord) {
        guard !record.text.isEmpty else {
            NSSound.beep()
            return
        }
        if permissions.accessibility { paste(record) } else { copy(record) }
    }

    private func paste(_ record: ForkDictationRecord) {
        state.paste(record)
    }

    private func copy(_ record: ForkDictationRecord) {
        let id = record.id
        state.copy(record) { feedback in
            if feedback == .tick { copiedID = id }
        }
    }

    private func listen(_ record: ForkDictationRecord) {
        guard record.hasAudio else { return }
        player.toggle(record)
    }

    private func remove(_ record: ForkDictationRecord) {
        if copiedID == record.id { copiedID = nil }
        state.delete(record)
    }

    /// Why a dictation has no text: a transcription again that failed, or
    /// the failure kept with it.
    private func failureText(_ record: ForkDictationRecord) -> String {
        state.problem(record.id)
            ?? ForkNotchDictationsSupport.failure(stored: record.failure)?.summary(text)
            ?? text.historyFailed
    }

    @ViewBuilder private func preview(_ record: ForkDictationRecord, compact: Bool, open: Bool = false) -> some View {
        if ForkNotchDictationsSupport.isFailed(record) {
            // A closed compact card has no details row to say why.
            Text(compact ? failureText(record) : text.historyFailed)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            searchText(open ? openText(record) : ForkNotchDictationsSupport.preview(record.text), matching: searchTokens)
                .font(.system(size: 12))
                .lineLimit(compact ? 2 : open ? NotchClipboardCardSize.maximumOpenLines : 3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Reads the arrow keys, Return and Space before the search field's editor
/// does, as the clipboard page's monitor does, and shows the hidden field as
/// typing reaches it. It lives as long as the page does.
private struct ForkNotchDictationsKeyMonitor: NSViewRepresentable {
    var handleKey: (UInt16, String, NSEvent.ModifierFlags, Bool, Bool) -> Bool
    var composed: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handleKey = handleKey
        context.coordinator.composed = composed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(handleKey: handleKey, composed: composed)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var handleKey: (UInt16, String, NSEvent.ModifierFlags, Bool, Bool) -> Bool
        var composed: () -> Void
        private var monitor: Any?

        init(handleKey: @escaping (UInt16, String, NSEvent.ModifierFlags, Bool, Bool) -> Bool,
             composed: @escaping () -> Void) {
            self.handleKey = handleKey
            self.composed = composed
        }

        func install(for view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self, let window = view?.window, event.window === window,
                      window.attachedSheet == nil else { return event }
                let editor = (window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
                // Another text view, such as a dialog's, keeps its keys.
                if editor == nil, window.firstResponder is NSTextView { return event }
                let composing = editor?.hasMarkedText() == true
                if self.handleKey(event.keyCode, event.characters ?? "", event.modifierFlags, composing, editor != nil) {
                    return nil
                }
                if let editor, !composing {
                    DispatchQueue.main.async { [weak self, weak editor] in
                        if editor?.hasMarkedText() == true { self?.composed() }
                    }
                }
                return event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Name and icon of the apps dictations went to, looked up once each.
@MainActor
private enum ForkNotchDictationApps {
    struct App { let name: String; let icon: NSImage }
    private static var cache: [String: App] = [:]

    static func app(for record: ForkDictationRecord) -> App? {
        guard let bundleID = record.targetBundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = InstalledApps.url(for: bundleID) else { return nil }
        let app = App(name: InstalledApps.name(for: bundleID), icon: NSWorkspace.shared.icon(forFile: url.path))
        cache[bundleID] = app
        return app
    }
}
