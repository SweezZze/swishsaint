// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit

/// The voice's latest levels, written by the microphone's queue and read by
/// whichever surface draws them. A lock rather than a published property:
/// twenty updates a second must not rebuild the interface each time.
final class ForkDictationLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var waveform = ForkDictationWaveform()
    private var latest: Float = 0

    func push(_ level: Float) {
        lock.lock()
        waveform.push(level)
        latest = level
        lock.unlock()
    }

    func reset() {
        lock.lock()
        waveform = ForkDictationWaveform()
        latest = 0
        lock.unlock()
    }

    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func samples(at time: TimeInterval) -> [CGFloat] {
        lock.lock()
        defer { lock.unlock() }
        return waveform.samples(at: time)
    }
}

/// Shows where a dictation is: in the island when it can take the
/// microphone notice, else in the bubble under the menu bar. One surface per
/// dictation, so the feedback does not jump from one to the other halfway,
/// unless the island turns it away (opened by a hover, for instance).
///
/// It also says each step to VoiceOver. The sounds belong to the service.
final class ForkDictationPresenter {
    static let shared = ForkDictationPresenter()

    private enum Surface { case island, bubble }

    let meter = ForkDictationLevelMeter()

    private(set) var presentation: ForkDictationPresentation = .hidden
    /// The history record of the dictation shown: the bubble opens it in
    /// the island's Dictations tab when clicked.
    private(set) var recordID: UUID?
    private var surface: Surface?
    /// The pointer rests on the bubble: it stays until the pointer leaves.
    private var isHovered = false
    private var hideDeadline: Date?
    private var hideWork: DispatchWorkItem?
    private var islandTimer: Timer?
    private var lastAnnouncement: String?
    private lazy var bubble: ForkDictationHUD = {
        let hud = ForkDictationHUD(meter: meter)
        hud.onHover = { [weak self] hovering in self?.bubbleHovered(hovering) }
        return hud
    }()

    private init() {}

    private var text: ForkDictationStrings { ForkDictationStrings.strings(L10n.shared.language) }

    /// Main thread. `recordID` names the dictation in the history, so a
    /// click on its final step opens it there.
    func show(_ incoming: ForkDictationPresentation, recordID: UUID? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.show(incoming, recordID: recordID) }
            return
        }
        // Pressed while busy: the bubble shakes, the step it shows stays.
        if incoming == .busy, presentation != .hidden {
            if surface == .bubble { bubble.shake() }
            return
        }
        guard incoming != .hidden else {
            hideNow()
            return
        }
        hideWork?.cancel()
        hideWork = nil
        if case .listening = incoming, !isListening(presentation) { meter.reset() }
        presentation = incoming
        self.recordID = recordID
        ForkNotchDictations.shared.setListening(isListening(incoming))
        if surface == nil { surface = choosesIsland ? .island : .bubble }
        render()
        announce(incoming)
        if let hold = incoming.holdDuration { scheduleHide(after: hold) }
    }

    /// Records attached late, once the delivery says where the text went:
    /// the step on screen becomes clickable without being shown again.
    func attach(recordID: UUID) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.attach(recordID: recordID) }
            return
        }
        guard presentation != .hidden, self.recordID == nil else { return }
        self.recordID = recordID
        if surface == .bubble { bubble.show(presentation, onClick: clickAction) }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        hideDeadline = Date().addingTimeInterval(delay)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Read while the pointer is on it: it goes once the pointer leaves.
            if self.isHovered { return }
            self.hideNow()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The final steps of a dictation kept in the history open it there.
    private var clickAction: (() -> Void)? {
        guard let recordID, presentation.opensHistory else { return nil }
        return { [weak self] in
            self?.hideNow()
            ForkNotchDictations.show(focus: recordID)
        }
    }

    /// A click on the island's notice of a dictation kept in the history
    /// opens it there, as a click on the bubble does. False otherwise.
    func openHistoryFromIsland() -> Bool {
        guard surface == .island, let action = clickAction else { return false }
        action()
        return true
    }

    private func bubbleHovered(_ hovering: Bool) {
        isHovered = hovering
        guard !hovering, presentation != .hidden, presentation.holdDuration != nil else { return }
        // Left after resting on it: what remained of its time, at least a
        // short moment, then gone.
        let remaining = hideDeadline.map { $0.timeIntervalSinceNow } ?? 0
        scheduleHide(after: max(0.8, remaining))
    }

    /// Any thread: the microphone's queue calls it about twenty times a second.
    func push(level: Float) {
        meter.push(level)
    }

    func hideNow() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.hideNow() }
            return
        }
        hideWork?.cancel()
        hideWork = nil
        hideDeadline = nil
        islandTimer?.invalidate()
        islandTimer = nil
        if surface == .island { ForkDictationIsland.retract() }
        bubble.hide()
        surface = nil
        presentation = .hidden
        recordID = nil
        ForkNotchDictations.shared.setListening(false)
        isHovered = false
        lastAnnouncement = nil
    }

    /// "m:ss", for the bubble and the island alike.
    static func clock(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var choosesIsland: Bool {
        let stored = UserDefaults.standard.string(forKey: ForkDefaultsKey.dictationFeedback) ?? ""
        let setting = ForkDictationFeedbackSetting(rawValue: stored) ?? .auto
        return setting != .bubble && ForkDictationIsland.isAvailable
    }

    private func render() {
        guard surface == .island else {
            bubble.show(presentation, onClick: clickAction)
            return
        }
        guard ForkDictationIsland.show(presentation, level: meter.level, now: Date(), text: text) else {
            // Turned away: the rest of this dictation goes to the bubble.
            islandTimer?.invalidate()
            islandTimer = nil
            surface = .bubble
            bubble.show(presentation, onClick: clickAction)
            return
        }
        scheduleIslandRefresh()
    }

    /// The notice leaves on its own 1.6 s after its last update. Listening,
    /// it is refreshed about fifteen times a second for the time and level;
    /// a final step is sent again until its own duration is over.
    private func scheduleIslandRefresh() {
        islandTimer?.invalidate()
        let interval: TimeInterval = isListening(presentation) ? 1.0 / 15 : 1.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.surface == .island, self.presentation != .hidden else { return }
            if !ForkDictationIsland.show(self.presentation, level: self.meter.level, now: Date(), text: self.text) {
                self.islandTimer?.invalidate()
                self.islandTimer = nil
                self.surface = .bubble
                self.bubble.show(self.presentation, onClick: self.clickAction)
            }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        islandTimer = timer
    }

    private func isListening(_ presentation: ForkDictationPresentation) -> Bool {
        if case .listening = presentation { return true }
        return false
    }

    private func announce(_ presentation: ForkDictationPresentation) {
        let text = self.text
        let message: String?
        switch presentation {
        case .hidden, .busy:
            message = nil
        case let .listening(handsFree, _, _):
            message = handsFree ? text.voiceHandsFree : text.voiceListening
        case .transcribing:
            message = text.voiceTranscribing
        case let .pasted(excerpt):
            message = text.voicePasted(excerpt)
        case let .copied(excerpt):
            message = text.voiceCopied(excerpt)
        case .keptInClipboard:
            message = text.voiceKeptInClipboard
        case .inHistoryOnly:
            message = text.voiceInHistoryOnly
        case .nothingHeard:
            message = text.voiceNothingHeard
        case .cancelled:
            message = text.voiceCancelled
        case let .failure(failure):
            message = failure.summary(text) + ". " + failure.remedy(text)
        }
        // A deadline drawing near reshows the same step: said once only.
        guard let message, message != lastAnnouncement else { return }
        lastAnnouncement = message
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

private extension ForkDictationPresentation {
    /// The steps that end a dictation the history keeps.
    var opensHistory: Bool {
        switch self {
        case .pasted, .copied, .keptInClipboard, .inHistoryOnly, .failure: return true
        case .hidden, .listening, .transcribing, .nothingHeard, .cancelled, .busy: return false
        }
    }
}
