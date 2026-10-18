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
    private var surface: Surface?
    private var hideWork: DispatchWorkItem?
    private var islandTimer: Timer?
    private var lastAnnouncement: String?
    private lazy var bubble = ForkDictationHUD(meter: meter)

    private init() {}

    private var text: ForkDictationStrings { ForkDictationStrings.strings(L10n.shared.language) }

    /// Main thread.
    func show(_ incoming: ForkDictationPresentation) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.show(incoming) }
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
        if surface == nil { surface = choosesIsland ? .island : .bubble }
        render()
        announce(incoming)
        if let hold = incoming.holdDuration {
            let work = DispatchWorkItem { [weak self] in self?.hideNow() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
        }
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
        islandTimer?.invalidate()
        islandTimer = nil
        if surface == .island { ForkDictationIsland.retract() }
        bubble.hide()
        surface = nil
        presentation = .hidden
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
            bubble.show(presentation)
            return
        }
        guard ForkDictationIsland.show(presentation, level: meter.level, now: Date(), text: text) else {
            // Turned away: the rest of this dictation goes to the bubble.
            islandTimer?.invalidate()
            islandTimer = nil
            surface = .bubble
            bubble.show(presentation)
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
                self.bubble.show(self.presentation)
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
