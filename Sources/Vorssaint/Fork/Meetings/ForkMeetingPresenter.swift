// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

/// Shows where a meeting recording is, from the machine's interface effects.
/// The pill carries the recording's state from start to finish; the notices
/// of each transition go to the island when it is free, else to the bubble;
/// what asks for a gesture (the saved meeting, a failure with its fix, the
/// start's consent reminder) opens a card with buttons in the island, else
/// in the bubble. A system notification is added only when neither could
/// show the notice, and VoiceOver hears each step once.
///
/// The service talks to it in four calls:
/// ```swift
/// presenter.configure(levels: { engine.levels }, onPause: …, onResume: …, onStop: …,
///                     onToggleTarget: …, onFailureAction: perform)   // once, when the feature starts
/// for effect in machine.handle(event, now: Date()) {
///     presenter.apply(effect, context: live)   // ignores the effects that are not its own
/// }
/// presenter.update(live)                       // a live fact changed (microphone silent, window minimized…)
/// presenter.showStart(notice, context: live)   // the start's notice, with what is filmed
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
    /// A failure, or the start's reminder, holds its card this long.
    private static let cardHold: TimeInterval = 12

    let pill = ForkMeetingPill()
    private let bubble = ForkMeetingBubble()
    /// The offer, its reminder, "Cancel (5 s)" and the countdown
    /// (`+Offer`).
    let offerUI = ForkMeetingOfferUI()
    private(set) var pillState: ForkMeetingPillState = .hidden
    private(set) var context = ForkMeetingLiveContext()
    private(set) var failureAction: ((ForkMeetingFailureAction) -> Void)?
    private var cardID: UUID?
    private var cardWork: DispatchWorkItem?
    /// The pointer rests on the island's card: its time stands still.
    private var cardHovered = false
    /// How long the island's card stays once the pointer leaves it.
    private var cardHold = ForkMeetingPresenter.savedHold
    private var spoken = ForkMeetingSpoken()
    /// Where the last notice could be shown, for its notification.
    private var lastShown: (notice: ForkMeetingNotice, shown: Shown)?

    private init() {}

    var text: ForkMeetingStrings { ForkMeetingStrings.current }

    /// The windows a capture filter that names windows leaves out. Ours
    /// leaves out the whole app instead, which covers them and any window
    /// made after the start; the pill's exists from `configure` on.
    var windowNumbers: [Int] { ([pill.windowNumber, bubble.windowNumber] + offerUI.windowNumbers).compactMap { $0 } }
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
                                                                       toggleTarget: onToggleTarget,
                                                                       continueRecording: {
                                                                           ForkMeetingService.shared.continueRecording()
                                                                       }))
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
            lastShown = (notice, show(notice, detail: nil))
        case let .announce(announcement):
            announce(announcement.text(text))
        case let .notify(notice):
            notify(notice, detail: nil)
        case .startCapture, .pauseCapture, .resumeCapture, .restartStream, .switchTarget, .stopCapture,
             .writeSidecar, .beginFinalize, .silence, .setPolicy, .discard:
            break
        case let .showOffer(offer):
            showOffer(offer)
        case .collapseOffer:
            collapseOffer()
        case .hideOffer:
            hideOffer()
        case let .showUndo(until):
            showUndo(until: until)
        case .hideUndo:
            hideUndo()
        case let .showEndingSoon(until):
            showEndingSoon(until: until)
        case .hideEndingSoon:
            hideEndingSoon()
        }
        // What was said of a card gone is said again for the next one.
        if ForkMeetingSpoken.forgets(after: effect) { spoken.forget() }
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
        lastShown = (notice, show(notice, detail: detail))
    }

    /// The start's notice ("Recording started", or the microphone refused):
    /// what is filmed on its second line ("Chrome window", "Whole screen").
    /// With the consent reminder on, the card also reminds to tell the
    /// participants, with the button that copies the announcement.
    func showStart(_ notice: ForkMeetingNotice, context: ForkMeetingLiveContext) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.showStart(notice, context: context) }
            return
        }
        update(context)
        let text = self.text
        let filmed = ForkMeetingServiceSupport.filmed(target: context.target, appName: context.appName,
                                                      noWindowToFilm: context.noWindowToFilm, strings: text)
        let announcement = context.announcement
        // No app to hear: said on the card, never left for the person to find
        // out from a silent track.
        let noApp = context.trackSound == .noApp
        let make = { [weak self] (dismiss: @escaping () -> Void) -> ForkMeetingCard in
            var card = self?.card(for: notice, detail: filmed, text: text, dismiss: dismiss)
                ?? ForkMeetingCard(symbol: ForkMeetingIsland.symbol(for: notice), tint: .accentColor,
                                   title: notice.title(text))
            if noApp { card.lines.append(text.soundNoAppDetail) }
            if let announcement {
                card.lines.append(text.consentRemind)
                card.actions.append(ForkMeetingCard.Action(title: text.copyAnnouncement, prominent: notice == .started) {
                    [weak self] in
                    self?.copy(announcement)
                    dismiss()
                })
            }
            return card
        }
        guard announcement != nil || hasButton(notice) || noApp else {
            lastShown = (notice, show(notice, detail: filmed))
            return
        }
        lastShown = (notice, present(make, height: ForkMeetingIsland.height(of: make({}), minimum: Self.savedCardHeight),
                                     hold: Self.cardHold))
    }

    /// "Meeting saved · 52 min · 410 MB [Show in Finder]": a card in the
    /// island when it is free, else the bubble, for a few seconds. Said to
    /// VoiceOver, and in a notification when neither could show it.
    /// `detail` comes from `ForkMeetingLiveText.savedDetail`.
    func showSaved(folder: URL, detail: String, recovered: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.showSaved(folder: folder, detail: detail, recovered: recovered) }
            return
        }
        let notice: ForkMeetingNotice = recovered ? .recovered : .saved
        let text = self.text
        announce(ForkMeetingLiveText.sentences(notice.title(text), detail))
        let shown = present({ dismiss in
            ForkMeetingCard(symbol: ForkMeetingIsland.symbol(for: notice), tint: .green, title: notice.title(text),
                            lines: [detail],
                            actions: [ForkMeetingCard.Action(title: text.actionShow, prominent: true) {
                                NSWorkspace.shared.open(folder)
                                dismiss()
                            }])
        }, height: Self.savedCardHeight, hold: Self.savedHold)
        lastShown = (notice, shown)
        if ForkMeetingServiceSupport.notifies(shownInIsland: shown.island, shownInBubble: shown.bubble,
                                              canNotify: Self.canNotify) {
            Notifier.post(title: notice.title(text), body: detail)
        }
    }

    /// Said to VoiceOver only: what the pill shows without a word VoiceOver
    /// would hear change (the picture frozen).
    func say(_ message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.say(message) }
            return
        }
        announce(message)
    }

    /// A new try at starting says every step again, even one said just
    /// before (a refusal, then the same refusal).
    func resetAnnouncements() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.resetAnnouncements() }
            return
        }
        spoken.forget()
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
        hideOfferSurfaces()
        spoken.forget()
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

    /// Where a notice reached the screen.
    struct Shown: Equatable {
        var island = false
        var bubble = false
    }

    var screen: NSScreen? {
        guard let id = context.displayID else { return nil }
        return NSScreen.screens.first { $0.displayID == id }
    }

    private func showPill(_ state: ForkMeetingPillState) {
        pillState = state
        guard state != .hidden else {
            // The next meeting says its steps again from the start
            // (`ForkMeetingSpoken.forgets`).
            pill.hide()
            return
        }
        pill.show(state, context: context)
    }

    /// A failure with a fix opens a card with its button, like the saved
    /// meeting; any other notice is a notice of the island, else the bubble.
    @discardableResult
    private func show(_ notice: ForkMeetingNotice, detail: String?) -> Shown {
        let text = self.text
        if hasButton(notice) {
            let make = { [weak self] (dismiss: @escaping () -> Void) -> ForkMeetingCard in
                self?.card(for: notice, detail: detail, text: text, dismiss: dismiss)
                    ?? ForkMeetingCard(symbol: ForkMeetingIsland.symbol(for: notice), tint: .orange,
                                       title: notice.title(text))
            }
            return present(make, height: ForkMeetingIsland.height(of: make({}), minimum: Self.savedCardHeight),
                           hold: Self.hold(for: notice))
        }
        if ForkMeetingIsland.show(notice, detail: detail, text: text) {
            // The island has the newest word: an older one in the bubble
            // would contradict it.
            bubble.hide()
            return Shown(island: true)
        }
        let card = card(for: notice, detail: detail, text: text) { [weak self] in self?.bubble.hide() }
        return Shown(bubble: showInBubble(card, hold: Self.hold(for: notice)))
    }

    /// A failure whose button can be pressed.
    private func hasButton(_ notice: ForkMeetingNotice) -> Bool {
        guard case let .failure(failure) = notice else { return false }
        return failure.action != nil && failureAction != nil
    }

    /// A card with buttons: in the island when it is free, for `hold`
    /// seconds (more while the pointer rests on it), else in the bubble.
    /// `make` builds the card for either place, with how it is dismissed.
    private func present(_ make: (@escaping () -> Void) -> ForkMeetingCard, height: CGFloat,
                         hold: TimeInterval) -> Shown {
        // The island holds one card: an offer, "Cancel" or the countdown
        // there moves first.
        islandWillBeTaken()
        removeCard()
        let id = UUID()
        let inBubble = make { [weak self] in self?.bubble.hide() }
        // Known before the island answers: it reports the pointer at once.
        cardID = id
        cardHold = hold
        let shown = ForkMeetingIsland.present(
            make { [weak self] in self?.removeCard() }, id: id, height: height,
            fallback: { [weak self] in
                // The island went away under the card: the bubble takes it.
                guard let self, self.cardID == id else { return }
                self.forgetCard()
                _ = self.showInBubble(inBubble, hold: hold)
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
            return Shown(bubble: showInBubble(inBubble, hold: hold))
        }
        bubble.hide()
        if !cardHovered { scheduleCardRemoval(id) }
        return Shown(island: true)
    }

    /// The bubble, unless nothing can be seen on the screen: the session
    /// locked, or the displays asleep.
    private func showInBubble(_ card: ForkMeetingCard, hold: TimeInterval) -> Bool {
        guard !ForkMeetingSystemEvents.screenIsLockedNow(), CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
            return false
        }
        // Under an offer's bubble, never over it.
        bubble.topInset = offerUI.bubble.visibleFrame.map { $0.height + 8 } ?? 0
        return bubble.show(card, on: screen, hold: hold)
    }

    /// A transition passes quickly; a failure stays as long as the island
    /// would keep it, so its remedy can be read.
    private static func hold(for notice: ForkMeetingNotice) -> TimeInterval {
        if case .failure = notice { return 12 }
        if case .diskLow = notice { return 12 }
        return 5
    }

    private func card(for notice: ForkMeetingNotice, detail: String?, text: ForkMeetingStrings,
                      dismiss: @escaping () -> Void) -> ForkMeetingCard {
        var lines = [detail ?? notice.detail(text)].compactMap { $0 }.filter { !$0.isEmpty }
        var actions: [ForkMeetingCard.Action] = []
        let tint: Color
        switch notice {
        case .started:
            tint = Color(nsColor: .systemRed)
        case .saved, .recovered:
            tint = .green
        case .microphoneSilent, .diskLow, .sourceGone, .soundLost:
            tint = .orange
        case let .failure(failure):
            tint = .orange
            lines.append(failure.remedy(text))
            if let action = failure.action, let perform = failureAction {
                actions.append(ForkMeetingCard.Action(title: Self.title(for: action, text: text), prominent: true) {
                    perform(action)
                    dismiss()
                })
            }
        case .resumed, .microphone, .displayChanged, .neverOffered:
            tint = .accentColor
        }
        return ForkMeetingCard(symbol: ForkMeetingIsland.symbol(for: notice), tint: tint, title: notice.title(text),
                               lines: lines, actions: actions)
    }

    static func title(for action: ForkMeetingFailureAction, text: ForkMeetingStrings) -> String {
        switch action {
        case .openScreenRecordingPrivacy, .openMicrophonePrivacy: return text.actionOpenSettings
        case .openStorageSettings: return text.actionOpenStorage
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
        DispatchQueue.main.asyncAfter(deadline: .now() + cardHold, execute: work)
    }

    private func removeCard() {
        guard let id = cardID else { return }
        forgetCard()
        ForkMeetingIsland.remove(id: id)
    }

    /// Forgets the island's card without taking it away: one about to be
    /// replaced in place.
    func forgetCard() {
        cardWork?.cancel()
        cardWork = nil
        cardID = nil
        cardHovered = false
    }

    // MARK: - Words

    /// A system notification, plain and without an action, only when the
    /// notice could be shown neither in the island nor in the bubble (the
    /// official watch's rule): otherwise it is said twice.
    private func notify(_ notice: ForkMeetingNotice, detail: String?) {
        let shown = lastShown.flatMap { $0.notice == notice ? $0.shown : nil } ?? Shown()
        guard ForkMeetingServiceSupport.notifies(shownInIsland: shown.island, shownInBubble: shown.bubble,
                                                 canNotify: Self.canNotify) else { return }
        let text = self.text
        var body = detail ?? notice.detail(text) ?? ""
        if case let .failure(failure) = notice { body = failure.remedy(text) }
        Notifier.post(title: notice.title(text), body: body)
    }

    /// The notification centre ends a process it cannot tie to a bundle (a
    /// bare build of the sources, as `Permissions` notes); the app always is
    /// one.
    private static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    /// The announcement, in the pasteboard for the meeting's chat.
    func copy(_ announcement: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(announcement, forType: .string)
        announce(text.voiceAnnouncementCopied)
    }

    /// High priority, so it is not lost behind what VoiceOver is reading;
    /// the same sentence twice in a row is said once.
    private func announce(_ message: String) {
        guard spoken.says(message) else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
