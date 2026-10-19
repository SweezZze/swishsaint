// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation
import Combine
import Speech

/// The dictation history in the island: the Dictations tab of its clipboard
/// page, and the one way to open it from anywhere (`show`). What the tab
/// shows and does lives here, so the island and the floating window that
/// stands in for it share it. Main thread.
final class ForkNotchDictations: ObservableObject {
    static let shared = ForkNotchDictations()

    /// A dictation to highlight and scroll to, once the page shows.
    struct Focus: Equatable {
        let id: UUID
        let serial: Int
    }

    /// The clipboard page's tab. Dictations only while an opening of the
    /// history put it there: the island closing, another page, and the
    /// clipboard's own routes bring the clipboard back.
    @Published var tab: ForkNotchDictationsTab = .clipboard
    /// The island's pinned filter, as the clipboard's: off again when the
    /// island closes.
    @Published var pinnedOnly = false
    /// The window's own filter, off again when the window hides.
    @Published var windowPinnedOnly = false
    @Published private(set) var focus: Focus?
    /// A transcription again that failed, said on its card.
    @Published private(set) var problems: [UUID: String] = [:]
    /// A dictation is listening: the island's Dictations button lights up.
    @Published private(set) var listening = false

    let player = ForkNotchDictationsPlayer()

    /// The app the island opened over, where Return pastes, remembered as
    /// the clipboard page remembers it.
    private var pasteTarget: NSRunningApplication?
    private var expandedObserver: AnyCancellable?
    private var selectedObserver: AnyCancellable?
    private var recordsObserver: AnyCancellable?

    private init() {}

    private static var text: ForkDictationStrings { ForkDictationStrings.current }

    // MARK: Launch

    /// At launch (`ForkBootstrap.start`): the island offers its Dictations
    /// button while dictation is on, and the tab follows the island.
    static func start() {
        NotchControlItem.dictationIsAvailable = { defaults in
            ForkNotchDictationsSupport.controlAvailable(
                dictationEnabled: defaults.bool(forKey: ForkFeature.dictation.enabledKey),
                clipboardPageShown: NotchSupport.modules(in: defaults).contains(.clipboard))
        }
        DispatchQueue.main.async { shared.follow() }
    }

    private func follow() {
        expandedObserver = NotchService.shared.$expanded
            .removeDuplicates()
            .sink { [weak self] expanded in self?.islandExpanded(expanded) }
        // Arriving on the clipboard page from another one shows the clipboard;
        // `show` picks the Dictations tab once the island is there.
        selectedObserver = NotchService.shared.$selected
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.showClipboardTab() }
        // A dictation deleted elsewhere (the settings page clears them all)
        // stops playing and loses what was said about it.
        recordsObserver = ForkDictationArchive.shared.$records
            .receive(on: DispatchQueue.main)
            .sink { [weak self] records in
                guard let self else { return }
                let ids = Set(records.map(\.id))
                if let playing = self.player.playingID, !ids.contains(playing) { self.player.stop() }
                if self.problems.keys.contains(where: { !ids.contains($0) }) {
                    self.problems = self.problems.filter { ids.contains($0.key) }
                }
            }
    }

    /// Published before the island changes: the app in front is still the
    /// one the person was in when it opens.
    private func islandExpanded(_ expanded: Bool) {
        let next = ForkNotchDictationsSupport.tab(tab, expanded: expanded)
        if tab != next { tab = next }
        if expanded {
            rememberPasteTarget()
        } else {
            if pinnedOnly { pinnedOnly = false }
            if !ForkNotchDictationsWindow.shared.isVisible {
                player.stop()
                pasteTarget = nil
            }
        }
    }

    func setListening(_ listening: Bool) {
        if self.listening != listening { self.listening = listening }
    }

    private func showClipboardTab() {
        if tab != .clipboard { tab = .clipboard }
    }

    /// The filter of the page shown in the island or in the window.
    func pinnedOnly(inWindow: Bool) -> Bool {
        inWindow ? windowPinnedOnly : pinnedOnly
    }

    func setPinnedOnly(_ value: Bool, inWindow: Bool) {
        if inWindow {
            if windowPinnedOnly != value { windowPinnedOnly = value }
        } else if pinnedOnly != value {
            pinnedOnly = value
        }
    }

    // MARK: Opening

    static var route: ForkNotchDictationsRoute {
        ForkNotchDictationsSupport.route(islandEnabled: NotchSupport.isEnabled(),
                                         clipboardPageShown: NotchSupport.modules().contains(.clipboard),
                                         dictationEnabled: ForkFeature.dictation.isEnabled,
                                         acceptsInteraction: NotchService.shared.acceptsUserInteraction)
    }

    /// Something the island shows over its page: a detail, Explore, the
    /// app panel, the Command Bar or the capture controls.
    private static var islandCovered: Bool {
        let island = NotchService.shared
        return island.showingAppPanel || island.showingSections || island.showingCommandBar
            || island.selectedMetric != nil || island.captureControls != nil
    }

    /// Opens the history: the Dictations tab of the island's clipboard page,
    /// or the window when the island or that page is off. `focus` highlights
    /// that dictation; `toggle` closes a history already shown.
    static func show(focus: UUID? = nil, toggle: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { show(focus: focus, toggle: toggle) }
            return
        }
        let state = shared
        let island = NotchService.shared
        let window = ForkNotchDictationsWindow.shared
        switch route {
        case .island:
            if window.isVisible { window.hide() }
            if toggle, focus == nil,
               ForkNotchDictationsSupport.togglesClosed(expanded: island.expanded, onClipboardPage: island.selected == .clipboard,
                                                        tab: state.tab, covered: islandCovered) {
                island.collapse()
                return
            }
            if let focus { state.request(focus) }
            island.open(.clipboard)
            // The island can stay shut (capture controls hold it): the
            // window shows the history then.
            guard ForkNotchDictationsSupport.showsClipboardPage(expanded: island.expanded,
                                                                onClipboardPage: island.selected == .clipboard,
                                                                covered: islandCovered) else {
                showWindow()
                return
            }
            if state.tab != .dictations { state.tab = .dictations }
        case .window:
            if toggle, focus == nil, window.isVisible {
                window.hide()
                return
            }
            if let focus { state.request(focus) }
            showWindow()
        }
    }

    private static func showWindow() {
        let island = NotchService.shared
        let window = ForkNotchDictationsWindow.shared
        if island.expanded { island.perform { window.show() } } else { window.show() }
    }

    /// The clipboard history's shortcut and menu (seam `notch-dictation6`):
    /// on the Dictations tab they show the clipboard. True when the
    /// shortcut's toggle is done here, in place; the menu's opening goes on
    /// through the official route, which gives the island the keyboard.
    static func showsClipboardTab(toggle: Bool) -> Bool {
        guard Thread.isMainThread, shared.tab == .dictations, ForkFeature.dictation.isEnabled else { return false }
        let island = NotchService.shared
        let route = ForkNotchDictationsSupport.clipboardRoute(
            tab: shared.tab, toggle: toggle,
            tabInView: ForkNotchDictationsSupport.showsClipboardPage(expanded: island.expanded,
                                                                     onClipboardPage: island.selected == .clipboard,
                                                                     covered: islandCovered),
            routesToIsland: island.acceptsUserInteraction && NotchSupport.routesClipboardWindow())
        if shared.tab != route.tab { shared.tab = route.tab }
        return route.handled
    }

    /// A page chosen in the island (Explore, its buttons; seam
    /// `notch-dictation7`): the clipboard page opens on the clipboard.
    static func pageChosen() {
        guard Thread.isMainThread else { return }
        shared.showClipboardTab()
    }

    /// A dictation starts: the history steps aside, so neither the window
    /// nor the island's search field can take what is said.
    static func stepAsideForDictation() {
        ForkNotchDictationsWindow.shared.hide()
        let island = NotchService.shared
        if island.expanded, island.selected == .clipboard, shared.tab == .dictations { island.collapse() }
    }

    private var focusSerial = 0

    private func request(_ id: UUID) {
        focusSerial += 1
        focus = Focus(id: id, serial: focusSerial)
    }

    /// The dictation to reveal, handed to the page once.
    func takeFocus() -> UUID? {
        guard let focus else { return nil }
        self.focus = nil
        return focus.id
    }

    func rememberPasteTarget() {
        pasteTarget = Self.frontmostPasteTarget()
    }

    /// The app in front when it can take a paste: never Swishsaint itself.
    private static func frontmostPasteTarget() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              ForkNotchDictationsSupport.isPasteTarget(bundleID: app.bundleIdentifier, ownBundleID: Bundle.main.bundleIdentifier,
                                                       regular: app.activationPolicy == .regular,
                                                       terminated: app.isTerminated)
        else { return nil }
        return app
    }

    // MARK: Island seams

    /// The island's Dictations button and tab.
    static func title(_ language: AppLanguage) -> String {
        ForkDictationStrings.strings(language).historyTitle
    }

    /// A floating quick button: opens the history from the closed island.
    static func activateQuickAction() {
        show()
    }

    /// Why the island's Dictations button is off while dictation is, as the
    /// official controls say it. Once dictation is on, nil: the official
    /// reason for the clipboard page it needs applies.
    static func controlReason(_ language: AppLanguage) -> String? {
        guard !ForkFeature.dictation.isEnabled else { return nil }
        return FeatureStrings.notchEditor(language).enableFeature(ForkExtrasStrings.strings(language).dictationTitle)
    }

    /// Where that reason leads: the Dictation page, already in Settings.
    /// Nil once dictation is on: the official link to the clipboard page.
    static func controlSetupAction() -> (() -> Void)? {
        guard !ForkFeature.dictation.isEnabled else { return nil }
        return { ForkSettingsPages.open(.dictation) }
    }

    // MARK: Actions

    /// The island closes, or the window hides, before anything goes elsewhere.
    private func dismiss(then action: (() -> Void)? = nil) {
        let island = NotchService.shared
        let window = ForkNotchDictationsWindow.shared
        if window.isVisible {
            window.hide()
            action.map { DispatchQueue.main.async(execute: $0) }
        } else if island.expanded {
            if let action { island.perform(action) } else { island.collapse() }
        } else {
            action?()
        }
    }

    /// Pastes into the app in front, or the one the island opened over when
    /// Swishsaint itself is in front. Not added to the clipboard history
    /// again: it is already there.
    func paste(_ record: ForkDictationRecord) {
        guard !record.text.isEmpty else {
            NSSound.beep()
            return
        }
        if let app = Self.frontmostPasteTarget() { pasteTarget = app }
        let target = pasteTarget
        let excerpt = ForkDictationPresentation.excerpt(record.text)
        dismiss()
        // Give the island's last key up time to reach the app before ⌘V does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            ForkDictationPaster.shared.deliver(record.text, action: .paste, target: target,
                                               addsToHistory: false) { outcome in
                switch outcome {
                case .pasted: ForkDictationPresenter.shared.show(.pasted(excerpt: excerpt))
                case .copied: ForkDictationPresenter.shared.show(.copied(excerpt: excerpt))
                case .keptInClipboard: ForkDictationPresenter.shared.show(.keptInClipboard)
                case .inHistoryOnly: ForkDictationPresenter.shared.show(.inHistoryOnly)
                case .superseded: break
                }
            }
        }
    }

    /// Copies the text, then says how it went: the tick, or the beep heard
    /// here when the clipboard did not take it.
    func copy(_ record: ForkDictationRecord, done: @escaping (ForkNotchDictationsCopyFeedback) -> Void = { _ in }) {
        guard !record.text.isEmpty else {
            NSSound.beep()
            return
        }
        ForkDictationPaster.shared.deliver(record.text, action: .copy, target: nil, addsToHistory: false) { outcome in
            let feedback = ForkNotchDictationsSupport.copyFeedback(outcome)
            if feedback == .beep { NSSound.beep() }
            done(feedback)
        }
    }

    func togglePin(_ record: ForkDictationRecord) {
        ForkDictationArchive.shared.setPinned(record.id, !record.isPinned)
    }

    func delete(_ record: ForkDictationRecord) {
        if player.playingID == record.id { player.stop() }
        ForkDictationArchive.shared.delete(record.id)
    }

    func showInFinder(_ record: ForkDictationRecord) {
        guard let url = ForkDictationArchive.shared.audioURL(for: record.id) else { return }
        dismiss { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func retranscription(_ record: ForkDictationRecord) -> ForkNotchDictationsRetranscription {
        ForkNotchDictationsSupport.retranscription(
            hasAudio: record.hasAudio, busy: ForkDictationArchive.shared.retranscribing != nil,
            parakeetInstalled: ForkDictationEngines.shared.isParakeetInstalled,
            appleUsable: ForkAppleSpeechEngine.canAskForSpeechRecognition
                && ForkAppleSpeechEngine.authorization != .denied && ForkAppleSpeechEngine.authorization != .restricted)
    }

    func retranscribe(_ record: ForkDictationRecord, with engine: ForkDictationEngineSetting) {
        let available = retranscription(record)
        guard engine == .parakeet ? available.parakeet : available.apple else { return }
        if player.playingID == record.id { player.stop() }
        problems[record.id] = nil
        let id = record.id
        ForkDictationArchive.shared.retranscribe(id, engine: engine, language: record.language) { [weak self] result in
            if case let .failure(failure) = result {
                self?.problems[id] = failure.summary(ForkDictationStrings.current)
            }
        }
    }

    func problem(_ id: UUID) -> String? { problems[id] }

    /// Deleting the dictations that are not pinned asks first, above the island.
    static func confirmClearUnpinned() {
        let ids = ForkNotchDictationsSupport.clearable(ForkDictationArchive.shared.records)
        guard !ids.isEmpty else { return }
        let text = Self.text
        let cancel = FeatureStrings.clipboard(L10n.shared.language).cancel
        let player = shared.player
        DispatchQueue.main.async {
            guard NSAlert.confirmAboveIsland(String(format: text.historyClearConfirmFormat, ids.count),
                                             message: text.historyClearConfirmMessage,
                                             action: text.historyClearUnpinned, destructive: true,
                                             cancel: cancel) else { return }
            if let playing = player.playingID, ids.contains(playing) { player.stop() }
            ForkDictationArchive.shared.delete(Set(ids))
        }
    }

    /// The Dictation page of Settings, from the top row of the history.
    static func openSettings() {
        shared.dismiss {
            ForkSettingsPages.open(.dictation)
            (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
        }
    }

    /// The island's Settings, on the controls where its Dictations button is placed.
    static func openIslandSettings() {
        NotchService.shared.openSettings(showing: .controls)
    }
}

/// Plays one dictation at a time, from its file in the archive. Stopped when
/// the island closes or the window hides.
final class ForkNotchDictationsPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?
    @Published private(set) var isPaused = false

    private var player: AVAudioPlayer?

    func isPlaying(_ id: UUID) -> Bool { playingID == id && !isPaused }

    func toggle(_ record: ForkDictationRecord) {
        if playingID == record.id, let player {
            if player.isPlaying {
                player.pause()
                isPaused = true
            } else {
                player.play()
                isPaused = false
            }
            return
        }
        stop()
        guard let url = ForkDictationArchive.shared.audioURL(for: record.id),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            NSSound.beep()
            return
        }
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            NSSound.beep()
            return
        }
        self.player = player
        playingID = record.id
        isPaused = false
    }

    func stop() {
        player?.stop()
        player = nil
        if playingID != nil { playingID = nil }
        if isPaused { isPaused = false }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            self.stop()
        }
    }
}
