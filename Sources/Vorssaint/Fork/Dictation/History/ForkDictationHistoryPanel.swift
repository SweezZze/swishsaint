// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import SwiftUI

/// The dictations window: the clipboard history's quick panel, for what was
/// said. It floats without activating Swishsaint, so the app the person was
/// in stays in front and a dictation pasted again lands there.
final class ForkDictationHistoryPanel {
    static let shared = ForkDictationHistoryPanel()

    let model = ForkDictationHistoryModel()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    private static let defaultSize = NSSize(width: 470, height: 560)
    private static let minimumSize = NSSize(width: 380, height: 340)

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    /// Main thread. `focus` selects that dictation and scrolls to it, as a
    /// click on the bubble asks.
    func show(focus: UUID? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.show(focus: focus) }
            return
        }
        let panel = ensurePanel()
        let opening = !panel.isVisible
        if opening {
            model.query = ""
            model.presentationID = UUID()
            place(panel)
        }
        model.select(focus ?? (opening ? model.ordered.first?.id : model.selectedID), reveal: true)
        installKeyMonitor(for: panel)
        installDismissMonitors(for: panel)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func toggle() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.toggle() }
            return
        }
        isVisible ? hide() : show()
    }

    func hide() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.hide() }
            return
        }
        removeMonitors()
        model.player.stop()
        panel?.orderOut(nil)
    }

    // MARK: - Actions

    /// Pastes into the app in front, which is the one the person was in:
    /// the panel never took it over. Not added to the clipboard history
    /// again, it is already there.
    func paste(_ record: ForkDictationRecord) {
        guard !record.text.isEmpty else { return }
        hide()
        let target = NSWorkspace.shared.frontmostApplication
        let excerpt = ForkDictationPresentation.excerpt(record.text)
        // Give the panel's last key up time to reach the app before ⌘V does.
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

    func copy(_ record: ForkDictationRecord) {
        guard !record.text.isEmpty else { return }
        ForkDictationPaster.shared.deliver(record.text, action: .copy, target: nil,
                                           addsToHistory: false) { _ in }
        model.flash(record.id)
    }

    func togglePin(_ record: ForkDictationRecord) {
        ForkDictationArchive.shared.setPinned(record.id, !record.isPinned)
    }

    func delete(_ record: ForkDictationRecord) {
        if model.player.playingID == record.id { model.player.stop() }
        let ordered = model.ordered
        if model.selectedID == record.id, let index = ordered.firstIndex(where: { $0.id == record.id }) {
            let next = ordered.indices.contains(index + 1) ? ordered[index + 1].id
                : (index > 0 ? ordered[index - 1].id : nil)
            model.select(next, reveal: false)
        }
        ForkDictationArchive.shared.delete(record.id)
    }

    func showInFinder(_ record: ForkDictationRecord) {
        guard let url = ForkDictationArchive.shared.audioURL(for: record.id) else { return }
        hide()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func retranscribe(_ record: ForkDictationRecord, with engine: ForkDictationEngineSetting) {
        // One at a time: the archive says which, and the rows grey the
        // others meanwhile.
        guard record.hasAudio, model.archive.retranscribing == nil else { return }
        if model.player.playingID == record.id { model.player.stop() }
        model.problems[record.id] = nil
        let id = record.id
        ForkDictationArchive.shared.retranscribe(id, engine: engine, language: record.language) { [weak self] result in
            guard let self else { return }
            if case let .failure(failure) = result {
                self.model.problems[id] = failure.summary(ForkDictationStrings.current)
            }
        }
    }

    // MARK: - Window

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                                 styleMask: [.titled, .closable, .resizable,
                                             .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.title = ForkDictationStrings.current.historyTitle
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        // As in the clipboard history: dragging by the background would
        // swallow the clicks on the rows. The title bar strip still drags.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentMinSize = Self.minimumSize
        let host = NSHostingController(rootView: ForkDictationHistoryView(model: model))
        // AppKit owns the window's size; SwiftUI fills it.
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(Self.defaultSize)
        self.panel = panel
        return panel
    }

    /// Placed again on every opening, so a changed display never strands it:
    /// centered toward the top of the screen being worked on, like the
    /// clipboard history.
    private func place(_ panel: NSPanel) {
        let area = (ForkDictationHUD.activeScreen() ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var size = panel.frame.size
        size.width = min(size.width, area.width - 32)
        size.height = min(size.height, area.height - 32)
        let x = area.midX - size.width / 2
        let y = min(area.maxY - size.height - 54, area.midY - size.height / 2)
        panel.setFrame(NSRect(x: max(area.minX + 16, min(x, area.maxX - size.width - 16)),
                              y: max(area.minY + 16, y),
                              width: size.width, height: size.height),
                       display: true, animate: false)
    }

    // MARK: - Keys

    private func installKeyMonitor(for panel: NSPanel) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel, panel.attachedSheet == nil else { return event }
            // A field still composing (Japanese, Chinese…) owns every key.
            if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// The keys of the clipboard history, plus Space to listen. Typed keys
    /// go to the search field.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let selected = model.selectedRecord
        switch Int(event.keyCode) {
        case kVK_Escape:
            if !model.query.isEmpty {
                model.query = ""
            } else {
                hide()
            }
            return true
        case kVK_DownArrow where modifiers.isEmpty:
            model.moveSelection(by: 1)
            return true
        case kVK_UpArrow where modifiers.isEmpty:
            model.moveSelection(by: -1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard let selected else { return false }
            if modifiers.isEmpty {
                paste(selected)
            } else if modifiers == [.shift] {
                copy(selected)
            } else {
                return false
            }
            return true
        case kVK_Space where modifiers.isEmpty && model.query.isEmpty:
            // Space types into a search, and listens otherwise.
            guard let selected, selected.hasAudio else { return false }
            model.player.toggle(selected)
            return true
        case kVK_Delete, kVK_ForwardDelete:
            guard let selected, modifiers == [.command] || modifiers == [.option] else { return false }
            delete(selected)
            return true
        default:
            break
        }
        if modifiers == [.command], key == "c", let selected, !hasTextSelection {
            copy(selected)
            return true
        }
        if modifiers == [.option], event.keyCode == UInt16(kVK_ANSI_P), let selected {
            togglePin(selected)
            return true
        }
        if modifiers == [.command], let index = Self.digitIndex(event.keyCode) {
            let ordered = model.ordered
            guard ordered.indices.contains(index) else { return true }
            paste(ordered[index])
            return true
        }
        return false
    }

    /// ⌘C copies the selected dictation unless some text is selected in the
    /// search field.
    private var hasTextSelection: Bool {
        guard let editor = panel?.firstResponder as? NSTextView else { return false }
        return editor.selectedRange().length > 0
    }

    private static func digitIndex(_ keyCode: UInt16) -> Int? {
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        return digits.firstIndex(of: Int(keyCode))
    }

    // MARK: - Dismissal

    /// Closes on a click elsewhere or when another app comes forward, like
    /// the clipboard history.
    private func installDismissMonitors(for panel: NSPanel) {
        removeDismissMonitors()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouse) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            // A menu of a row lives in its own window, over the panel.
            if event.window !== panel, !Self.pointerIsInside(panel), !(event.window is NSPanel) {
                self.hide()
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouse) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return }
            if event.windowNumber != panel.windowNumber, !Self.pointerIsInside(panel),
               // Every key of the Accessibility Keyboard is a click elsewhere.
               !AssistiveKeyboard.ownsCocoaPoint(NSEvent.mouseLocation) {
                self.hide()
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  app.bundleIdentifier != AssistiveKeyboard.bundleID
            else { return }
            self?.hide()
        }
    }

    private static func pointerIsInside(_ panel: NSPanel) -> Bool {
        panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        removeDismissMonitors()
    }

    private func removeDismissMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }
}

/// What the panel shows: the archive's records, the search, the selection,
/// and the work going on per dictation. Main thread.
final class ForkDictationHistoryModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var selectedID: UUID?
    /// Bumped when the selection should scroll into view.
    @Published private(set) var revealID = UUID()
    /// Bumped on every opening, so the list starts from the top.
    @Published var presentationID = UUID()
    /// A retranscription that failed, said on its row.
    @Published var problems: [UUID: String] = [:]
    /// Rows that just copied, for a short confirmation.
    @Published private(set) var flashed: Set<UUID> = []

    let player = ForkDictationHistoryPlayer()

    var archive: ForkDictationArchive { .shared }

    private var recordsObserver: AnyCancellable?

    init() {
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
                if let selected = self.selectedID, !ids.contains(selected) { self.selectedID = nil }
            }
    }

    func sections(calendar: Calendar = .current) -> [ForkDictationHistoryListing.Section] {
        ForkDictationHistoryListing.sections(archive.records, query: query, calendar: calendar)
    }

    var ordered: [ForkDictationRecord] {
        ForkDictationHistoryListing.ordered(sections())
    }

    var selectedRecord: ForkDictationRecord? {
        guard let selectedID else { return nil }
        return archive.records.first { $0.id == selectedID }
    }

    func select(_ id: UUID?, reveal: Bool) {
        if selectedID != id { selectedID = id }
        if reveal { revealID = UUID() }
    }

    func moveSelection(by step: Int) {
        let ordered = self.ordered
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == selectedID }
        let next = current.map { min(max($0 + step, 0), ordered.count - 1) } ?? (step > 0 ? 0 : ordered.count - 1)
        select(ordered[next].id, reveal: true)
    }

    func flash(_ id: UUID) {
        flashed.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.flashed.remove(id)
        }
    }
}

/// How far the dictation being played is, apart from the player so only
/// the progress bar redraws twenty times a second, not the whole list.
final class ForkDictationHistoryPlaybackClock: ObservableObject {
    /// 0…1.
    @Published var progress: Double = 0
}

/// Plays one dictation at a time, from its file in the archive.
final class ForkDictationHistoryPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?
    @Published private(set) var isPaused = false
    let clock = ForkDictationHistoryPlaybackClock()

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    func isPlaying(_ id: UUID) -> Bool { playingID == id && !isPaused }

    func toggle(_ record: ForkDictationRecord) {
        if playingID == record.id, let player {
            if player.isPlaying {
                player.pause()
                isPaused = true
                stopTicker()
            } else {
                player.play()
                isPaused = false
                startTicker()
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
        clock.progress = 0
        startTicker()
    }

    func stop() {
        stopTicker()
        player?.stop()
        player = nil
        if playingID != nil { playingID = nil }
        if isPaused { isPaused = false }
        if clock.progress != 0 { clock.progress = 0 }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            self.stop()
        }
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, let player = self.player, player.duration > 0 else { return }
            self.clock.progress = min(1, player.currentTime / player.duration)
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
