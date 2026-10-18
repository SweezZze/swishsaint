// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

/// Shows where a meeting recording is, from the machine's interface effects.
/// The pill carries the recording's state from start to finish; the notices
/// of each transition go to the island when it is free, else to the bubble;
/// the saved meeting opens a card with a button in the island, else in the
/// bubble. A system notification is added only when the app is not in front,
/// and VoiceOver hears each step once.
///
/// The service talks to it in four calls:
/// ```swift
/// presenter.configure(levels: { engine.levels }, onPause: …, onResume: …, onStop: …,
///                     onToggleTarget: …, onFailureAction: perform)   // once, when the feature starts
/// for effect in machine.handle(event, now: Date()) {
///     presenter.apply(effect, context: live)   // ignores the effects that are not its own
/// }
/// presenter.update(live)                       // a live fact changed (microphone silent, window minimized…)
/// presenter.showSaved(folder:, detail:)        // the final pass is done
/// presenter.reset()                            // the feature is turned off
/// ```
/// Every call may come from any thread: it runs on the main one.
final class ForkMeetingPresenter {
    static let shared = ForkMeetingPresenter()

    /// The island's card and the bubble hold a saved meeting this long, more
    /// while the pointer rests on them.
    private static let savedHold: TimeInterval = 8
    /// The island's card for a saved meeting: one row and its button.
    private static let savedCardHeight: CGFloat = 72

    private let pill = ForkMeetingPill()
    private let bubble = ForkMeetingBubble()
    private(set) var pillState: ForkMeetingPillState = .hidden
    private(set) var context = ForkMeetingLiveContext()
    private var failureAction: ((ForkMeetingFailureAction) -> Void)?
    private var cardID: UUID?
    private var cardWork: DispatchWorkItem?
    /// The pointer rests on the island's card: its time stands still.
    private var cardHovered = false
    private var lastAnnouncement: String?

    private init() {}

    private var text: ForkMeetingStrings { ForkMeetingStrings.current }

    /// The windows a capture filter that names windows leaves out. Ours
    /// leaves out the whole app instead, which covers them and any window
    /// made after the start; the pill's exists from `configure` on.
    var windowNumbers: [Int] { [pill.windowNumber, bubble.windowNumber].compactMap { $0 } }
    var pillWindow: NSWindow? { pill.window }

    /// `levels` is read on the main thread fifteen times a second while
    /// recording: the engine's latest levels, from under its lock, between 0
    /// and 1. `onFailureAction` runs a failure's button in the bubble; without
    /// it the bubble shows no button.
    func configure(levels: @escaping () -> ForkMeetingLevels,
                   onPause: @escaping () -> Void,
                   onResume: @escaping () -> Void,
                   onStop: @escaping () -> Void,
                   onToggleTarget: @escaping () -> Void,
                   onFailureAction: ((ForkMeetingFailureAction) -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.configure(levels: levels, onPause: onPause, onResume: onResume, onStop: onStop,
                               onToggleTarget: onToggleTarget, onFailureAction: onFailureAction)
            }
            return
        }
        pill.configure(levels: levels, actions: ForkMeetingPill.Actions(pause: onPause, resume: onResume, stop: onStop,
                                                                       toggleTarget: onToggleTarget))
        pill.prepare()
        failureAction = onFailureAction
    }

    /// Runs one of the machine's interface effects (`showPill`, `notice`,
    /// `announce`, `notify`); the others are the service's and do nothing
    /// here. `context`, when given, replaces the live facts first.
    func apply(_ effect: ForkMeetingMachine.Effect, context: ForkMeetingLiveContext? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.apply(effect, context: context) }
            return
        }
        if let context { update(context) }
        switch effect {
        case let .showPill(state):
            showPill(state)
        case let .notice(notice):
            show(notice, detail: nil)
        case let .announce(announcement):
            announce(announcement.text(text))
        case let .notify(notice):
            notify(notice, detail: nil)
        case .startCapture, .pauseCapture, .resumeCapture, .restartStream, .switchTarget, .stopCapture,
             .writeSidecar, .beginFinalize, .silence, .setPolicy, .discard:
            break
        case .showOffer, .collapseOffer, .hideOffer, .showUndo, .hideUndo, .showEndingSoon, .hideEndingSoon:
            // The offer and the countdown come with the detection's interface.
            break
        }
    }

    /// The live facts changed: the pill shows them at once.
    func update(_ context: ForkMeetingLiveContext) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.update(context) }
            return
        }
        guard context != self.context else { return }
        self.context = context
        if pillState != .hidden { pill.update(context) }
    }

    /// The final pass's share done, between 0 and 1, while the pill shows
    /// `finalizing`; `nil` draws an indeterminate gauge.
    func setFinalizing(progress: Double?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setFinalizing(progress: progress) }
            return
        }
        pill.setFinalizing(progress: progress)
    }

    /// A notice with a second line of its own (the finalizer's length and
    /// size, for instance), else the notice's.
    func notice(_ notice: ForkMeetingNotice, detail: String? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.notice(notice, detail: detail) }
            return
        }
        show(notice, detail: detail)
    }

    /// "Meeting saved · 52 min · 410 MB [Show in Finder]": a card in the
    /// island when it is free, else the bubble, for a few seconds. Said to
    /// VoiceOver, and in a notification when the app is not in front.
    /// `detail` comes from `ForkMeetingLiveText.savedDetail`.
    func showSaved(folder: URL, detail: String, recovered: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.showSaved(folder: folder, detail: detail, recovered: recovered) }
            return
        }
        let notice: ForkMeetingNotice = recovered ? .recovered : .saved
        let text = self.text
        announce(notice.title(text) + ". " + detail)
        if !NSApp.isActive { Notifier.post(title: notice.title(text), body: detail) }
        removeCard()
        func card(dismiss: @escaping () -> Void) -> ForkMeetingCard {
            ForkMeetingCard(symbol: ForkMeetingIsland.symbol(for: notice), tint: .green, title: notice.title(text),
                            lines: [detail],
                            actions: [ForkMeetingCard.Action(title: text.actionShow, prominent: true) {
                                NSWorkspace.shared.open(folder)
                                dismiss()
                            }])
        }
        let id = UUID()
        let inBubble = card { [weak self] in self?.bubble.hide() }
        // Known before the island answers: it reports the pointer at once.
        cardID = id
        let shown = ForkMeetingIsland.present(
            card { [weak self] in self?.removeCard() }, id: id, height: Self.savedCardHeight,
            fallback: { [weak self] in
                // The island went away under the card: the bubble takes it.
                guard let self, self.cardID == id else { return }
                self.forgetCard()
                self.bubble.show(inBubble, on: self.screen, hold: Self.savedHold)
            },
            close: { [weak self] in
                guard let self, self.cardID == id else { return }
                self.forgetCard()
            },
            hover: { [weak self] inside in
                guard let self, self.cardID == id else { return }
                self.cardHovered = inside
                if inside {
                    self.cardWork?.cancel()
                    self.cardWork = nil
                } else {
                    self.scheduleCardRemoval(id)
                }
            })
        guard shown else {
            forgetCard()
            bubble.show(inBubble, on: screen, hold: Self.savedHold)
            return
        }
        bubble.hide()
        if !cardHovered { scheduleCardRemoval(id) }
    }

    /// Takes everything off the screen; the configuration stays.
    func hideAll() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.hideAll() }
            return
        }
        pillState = .hidden
        pill.hide()
        bubble.hide()
        removeCard()
        lastAnnouncement = nil
    }

    /// The feature is off: nothing shows, nothing is held, nothing listens.
    func reset() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.reset() }
            return
        }
        hideAll()
        context = ForkMeetingLiveContext()
        failureAction = nil
        pill.configure(levels: { ForkMeetingLevels() }, actions: ForkMeetingPill.Actions())
    }

    // MARK: - Surfaces

    private var screen: NSScreen? {
        guard let id = context.displayID else { return nil }
        return NSScreen.screens.first { $0.displayID == id }
    }

    private func showPill(_ state: ForkMeetingPillState) {
        pillState = state
        guard state != .hidden else {
            pill.hide()
            // The next meeting says its steps again from the start.
            lastAnnouncement = nil
            return
        }
        pill.show(state, context: context)
    }

    private func show(_ notice: ForkMeetingNotice, detail: String?) {
        let text = self.text
        if ForkMeetingIsland.show(notice, detail: detail, text: text) {
            // The island has the newest word: an older one in the bubble
            // would contradict it.
            bubble.hide()
            return
        }
        bubble.show(card(for: notice, detail: detail, text: text), on: screen, hold: Self.hold(for: notice))
    }

    /// A transition passes quickly; a failure stays as long as the island
    /// would keep it, so its remedy can be read.
    private static func hold(for notice: ForkMeetingNotice) -> TimeInterval {
        if case .failure = notice { return 12 }
        if case .diskLow = notice { return 12 }
        return 5
    }

    private func card(for notice: ForkMeetingNotice, detail: String?, text: ForkMeetingStrings) -> ForkMeetingCard {
        var lines = [detail ?? notice.detail(text)].compactMap { $0 }.filter { !$0.isEmpty }
        var actions: [ForkMeetingCard.Action] = []
        let tint: Color
        switch notice {
        case .started:
            tint = Color(nsColor: .systemRed)
        case .saved, .recovered:
            tint = .green
        case .microphoneSilent, .diskLow:
            tint = .orange
        case let .failure(failure):
            tint = .orange
            lines.append(failure.remedy(text))
            if let action = failure.action, let perform = failureAction {
                actions.append(ForkMeetingCard.Action(title: Self.title(for: action, text: text), prominent: true) {
                    [weak self] in
                    perform(action)
                    self?.bubble.hide()
                })
            }
        case .resumed, .microphone, .displayChanged, .neverOffered:
            tint = .accentColor
        }
        return ForkMeetingCard(symbol: ForkMeetingIsland.symbol(for: notice), tint: tint, title: notice.title(text),
                               lines: lines, actions: actions)
    }

    private static func title(for action: ForkMeetingFailureAction, text: ForkMeetingStrings) -> String {
        switch action {
        case .openScreenRecordingPrivacy, .openMicrophonePrivacy, .openStorageSettings: return text.actionOpenSettings
        case .openMeetingsPage: return text.actionOpenMeetings
        case .openMeetingsFolder: return text.actionShow
        }
    }

    private func scheduleCardRemoval(_ id: UUID) {
        cardWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.cardID == id else { return }
            self.removeCard()
        }
        cardWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.savedHold, execute: work)
    }

    private func removeCard() {
        guard let id = cardID else { return }
        forgetCard()
        ForkMeetingIsland.remove(id: id)
    }

    private func forgetCard() {
        cardWork?.cancel()
        cardWork = nil
        cardID = nil
        cardHovered = false
    }

    // MARK: - Words

    /// A system notification, plain and without an action, only when the
    /// app is behind: in front, the island or the bubble already said it.
    private func notify(_ notice: ForkMeetingNotice, detail: String?) {
        guard !NSApp.isActive else { return }
        let text = self.text
        var body = detail ?? notice.detail(text) ?? ""
        if case let .failure(failure) = notice { body = failure.remedy(text) }
        Notifier.post(title: notice.title(text), body: body)
    }

    /// High priority, so it is not lost behind what VoiceOver is reading;
    /// the same sentence twice in a row is said once.
    private func announce(_ message: String) {
        guard !message.isEmpty, message != lastAnnouncement else { return }
        lastAnnouncement = message
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
