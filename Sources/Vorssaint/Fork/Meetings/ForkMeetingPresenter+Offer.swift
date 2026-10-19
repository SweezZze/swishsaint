// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation
import SwiftUI

/// What the presenter keeps of the detection's interface: the offer it
/// shows, where, and the cards "Cancel (5 s)" and "Meeting over?" that
/// hold the island meanwhile.
final class ForkMeetingOfferUI {
    /// Which of our cards the island holds.
    enum Card: Equatable {
        case offer
        case undo
        case endingSoon
    }

    /// The offer's own bubble, apart from the notices': a notice arriving
    /// meanwhile never replaces it, it goes under it.
    let bubble = ForkMeetingBubble()
    let reminder = ForkMeetingReminder()
    /// The offer the machine holds up, open or folded.
    var offer: ForkMeetingOffer?
    /// Shown open (island or bubble), not folded into its reminder.
    var open = false
    /// The island refused this offer, took it back or was collapsed over
    /// it: the bubble keeps it until it is opened again from its reminder.
    var islandTurnedAway = false
    var fold = ForkMeetingOfferFold.opened()
    var foldWork: DispatchWorkItem?
    var islandCard: (id: UUID, card: Card)?
    var bubbleCard: Card?
    var undoUntil: Date?

    var windowNumbers: [Int?] { [bubble.windowNumber, reminder.windowNumber] }
}

/// The detection's interface: the offer, open in the island (else the
/// bubble), folded after 20 s into a small grey reminder that stays while
/// the meeting lives; "Recording started · Cancel (5 s)" after a start that
/// "Always" made; and "Meeting over? Stopping in 12 s [Continue]" in the
/// pill, and in the island when it is free.
///
/// The machine decides; these only show what it said. VoiceOver hears each
/// step from the machine's own `announce` effects, once. Nothing here takes
/// the keyboard from the call: the island opens with `takeFocus: false`,
/// the bubble and the reminder never become key.
extension ForkMeetingPresenter {
    /// Opens the offer, or shows it again changed (greyed, ungreyed, a
    /// name read later) where it is: a change never opens again an offer
    /// folded, by the machine or by a click that collapsed the island.
    func showOffer(_ offer: ForkMeetingOffer) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.showOffer(offer) }
            return
        }
        let ui = offerUI
        if ui.offer?.candidate.identity != offer.candidate.identity {
            // A new meeting: the island gets its chance again.
            cancelFold()
            ui.islandTurnedAway = false
            ui.fold = .opened()
            ui.open = !offer.collapsed
        }
        ui.offer = offer
        renderOffer()
    }

    /// The machine's 20 s are over: the offer folds into its reminder, once
    /// the pointer has left it.
    func collapseOffer() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.collapseOffer() }
            return
        }
        let ui = offerUI
        guard ui.offer != nil else { return }
        ui.offer?.collapsed = true
        ui.fold.ask(at: Date())
        scheduleFold()
    }

    func hideOffer() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.hideOffer() }
            return
        }
        let ui = offerUI
        cancelFold()
        ui.offer = nil
        ui.open = false
        removeIslandCard(.offer)
        hideOfferBubble(.offer)
        ui.reminder.hide()
    }

    /// "Recording started · Cancel (5 s)", in the island when it is free,
    /// else the offer's bubble, until `until`.
    func showUndo(until: Date) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.showUndo(until: until) }
            return
        }
        offerUI.undoUntil = until
        let card = undoCard(until: until)
        if presentInIsland(card, as: .undo, minimum: 72) { return }
        showOfferBubble(card, as: .undo)
    }

    func hideUndo() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.hideUndo() }
            return
        }
        offerUI.undoUntil = nil
        removeIslandCard(.undo)
        hideOfferBubble(.undo)
    }

    /// "Meeting over? Stopping in 12 s [Continue]" in the pill, which always
    /// shows it, and in the island when it is free.
    func showEndingSoon(until: Date) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.showEndingSoon(until: until) }
            return
        }
        pill.setEndingSoon(until: until)
        let card = Self.endingSoonCard(until: until, text: text) { ForkMeetingService.shared.continueRecording() }
        _ = presentInIsland(card, as: .endingSoon, minimum: 64)
    }

    func hideEndingSoon() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.hideEndingSoon() }
            return
        }
        pill.setEndingSoon(until: nil)
        removeIslandCard(.endingSoon)
    }

    // MARK: - With the presenter

    /// Everything of the detection off the screen, the offer forgotten: the
    /// feature turned off, or `hideAll`.
    func hideOfferSurfaces() {
        let ui = offerUI
        cancelFold()
        ui.offer = nil
        ui.open = false
        ui.undoUntil = nil
        if let card = ui.islandCard { ForkMeetingIsland.remove(id: card.id) }
        ui.islandCard = nil
        ui.bubble.hide()
        ui.bubbleCard = nil
        ui.reminder.hide()
        pill.setEndingSoon(until: nil)
    }

    /// Another card is about to take the island: ours moves where it can
    /// still be answered. The offer and "Cancel" go to the offer's bubble;
    /// the countdown stays in the pill alone.
    func islandWillBeTaken() {
        let ui = offerUI
        guard let held = ui.islandCard else { return }
        ui.islandCard = nil
        switch held.card {
        case .offer:
            ui.islandTurnedAway = true
            renderOffer()
        case .undo:
            if let until = ui.undoUntil { showOfferBubble(undoCard(until: until), as: .undo) }
        case .endingSoon:
            break
        }
    }

    // MARK: - The offer

    private func renderOffer() {
        let ui = offerUI
        guard let offer = ui.offer else { return }
        guard ui.open else {
            showReminder(offer)
            return
        }
        ui.reminder.hide()
        let islandCard = offerCard(offer, inIsland: true)
        // Already in the island: changed in place.
        if let held = ui.islandCard, held.card == .offer, ForkMeetingIsland.isShowing(id: held.id) {
            present(islandCard, id: held.id)
            return
        }
        let surface = ForkMeetingOfferSurface.choose(folded: false, islandAvailable: ForkMeetingIsland.isAvailable,
                                                     islandTurnedAway: ui.islandTurnedAway)
        if surface == .island {
            if presentInIsland(islandCard, as: .offer, minimum: 96) {
                hideOfferBubble(.offer)
                return
            }
            ui.islandTurnedAway = true
        }
        removeIslandCard(.offer)
        showOfferBubble(offerCard(offer, inIsland: false), as: .offer)
    }

    private func showReminder(_ offer: ForkMeetingOffer) {
        let ui = offerUI
        removeIslandCard(.offer)
        hideOfferBubble(.offer)
        ui.reminder.show(title: ForkMeetingOfferText.reminderTitle(offer.candidate),
                         label: text.offerReminder(offer.candidate.name),
                         on: meetingScreen(offer.candidate)) { [weak self] in self?.reopenOffer() }
    }

    /// A click on the reminder: the offer opens again, in the island if it
    /// is free now, and folds back 20 s later if left unanswered.
    private func reopenOffer() {
        let ui = offerUI
        guard ui.offer != nil else { return }
        ui.open = true
        ui.islandTurnedAway = false
        ui.fold = .reopened(at: Date())
        renderOffer()
        scheduleFold()
    }

    private func offerHover(_ inside: Bool) {
        offerUI.fold.hover(inside, at: Date())
        scheduleFold()
    }

    private func scheduleFold() {
        let ui = offerUI
        ui.foldWork?.cancel()
        ui.foldWork = nil
        guard ui.open, let due = ui.fold.due else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.offerUI.fold.isDue(at: Date()) else { return }
            self.foldOffer()
        }
        ui.foldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due.timeIntervalSinceNow), execute: work)
    }

    private func cancelFold() {
        offerUI.foldWork?.cancel()
        offerUI.foldWork = nil
    }

    /// Into the reminder, silently: nothing was answered, nothing is lost.
    private func foldOffer() {
        let ui = offerUI
        cancelFold()
        ui.open = false
        ui.fold = .opened()
        renderOffer()
    }

    /// The island's card follows the official "Show in screenshots and
    /// videos": seen in shares, it does not name the meeting.
    private func offerCard(_ offer: ForkMeetingOffer, inIsland: Bool) -> ForkMeetingCard {
        let candidate = offer.candidate
        let service = ForkMeetingService.shared
        let settings = service.captureSettings()
        let facts = OfferFacts(
            icon: Self.icon(for: candidate), settings: settings,
            windowApp: Self.appName(pid: candidate.pid, bundle: candidate.windowBundle),
            soundApp: Self.appName(pid: nil, bundle: candidate.appBundle),
            microphone: Self.microphone(settings.microphone, meetingInput: service.meetingMicrophone(for: candidate)),
            consentReminder: UserDefaults.standard.bool(forKey: ForkDefaultsKey.meetingsConsentReminder),
            seenInShares: inIsland && ForkMeetingIsland.showsInCaptures)
        let actions = OfferActions(record: { service.acceptOffer() }, notNow: { service.dismissOffer(.thisTime) },
                                   always: { service.alwaysForOffer() }, never: { service.dismissOffer(.never) },
                                   copyAnnouncement: { service.copyAnnouncement() }, fix: failureAction)
        return Self.offerCard(offer, facts: facts, actions: actions, text: text)
    }

    /// What an offer's card says that comes from the Mac and the settings.
    struct OfferFacts {
        var icon: NSImage?
        var settings: ForkMeetingCaptureSettings
        var windowApp: String?
        var soundApp: String?
        var microphone: ForkMeetingOfferMicrophone
        var consentReminder: Bool
        /// Someone else's screen share would show the card.
        var seenInShares = false
    }

    /// What the offer's buttons and menu do. `fix` runs a refusal's way out
    /// and opens the Meetings page; without it neither is offered.
    struct OfferActions {
        var record: () -> Void = {}
        var notNow: () -> Void = {}
        var always: () -> Void = {}
        var never: () -> Void = {}
        var copyAnnouncement: () -> Void = {}
        var fix: ((ForkMeetingFailureAction) -> Void)?
    }

    /// The offer's card, the same in the island and the bubble, but for its
    /// name in an island seen in screen shares ("Google Meet", "Name hidden
    /// from shares"):
    /// ```
    /// [icon] Point hebdo                              (⋯ in the island's top row)
    ///        Google Meet · abc-defg-hij
    ///        Fenêtre : Chrome · son : Chrome · micro : AirPods
    ///        ⓘ Pensez à prévenir les participants.
    ///        ⚠ Un enregistrement d'écran est en cours.     (greyed)
    ///                             [Pas cette fois] [● Enregistrer]
    /// ```
    static func offerCard(_ offer: ForkMeetingOffer, facts: OfferFacts, actions: OfferActions,
                          text: ForkMeetingStrings) -> ForkMeetingCard {
        let candidate = offer.candidate
        let settings = facts.settings
        let heading = ForkMeetingOfferText.heading(candidate, seenInShares: facts.seenInShares, strings: text)
        var card = ForkMeetingCard(symbol: "video.fill", tint: .accentColor, title: heading.title)
        if heading.title != candidate.name { card.spokenTitle = candidate.name }
        card.icon = facts.icon
        card.lines = [heading.subtitle].compactMap { $0 }
        card.lines.append(ForkMeetingOfferText.capture(
            target: settings.target, windowApp: facts.windowApp, hasWindow: candidate.windowID != nil,
            sound: ForkMeetingOfferText.sound(setting: settings.systemAudio, providerDefault: candidate.defaultSound),
            soundApp: facts.soundApp, microphone: facts.microphone, strings: text))
        if facts.consentReminder { card.info = text.offerConsent }
        let notNow = ForkMeetingCard.Action(title: text.offerNotNow, perform: actions.notNow)
        var record = ForkMeetingCard.Action(title: text.offerRecord, prominent: true, recordDot: true,
                                            perform: actions.record)
        if let blocked = offer.blocked {
            card.dimmed = true
            card.warning = ForkMeetingOfferText.blocked(blocked, strings: text)
            if let action = blocked.action, let fix = actions.fix {
                // The way out instead of a Record that would only refuse.
                record = ForkMeetingCard.Action(title: title(for: action, text: text), prominent: true) {
                    fix(action)
                }
            } else {
                record.enabled = false
            }
        }
        card.actions = [notNow, record]
        let provider = ForkMeetingOfferText.reminderTitle(candidate)
        card.menu = [
            NotchMenuItem(title: text.offerAlways(provider), action: actions.always),
            NotchMenuItem(title: text.offerNever(provider), action: actions.never),
            .separator,
            NotchMenuItem(title: text.copyAnnouncement, action: actions.copyAnnouncement),
        ]
        if let fix = actions.fix {
            card.menu.append(NotchMenuItem(title: text.actionOpenMeetings) { fix(.openMeetingsPage) })
        }
        card.menuTitle = text.offerMore
        card.stacked = true
        card.closable = false
        return card
    }

    private func undoCard(until: Date) -> ForkMeetingCard {
        let filmed = ForkMeetingServiceSupport.filmed(target: context.target, appName: context.appName,
                                                      noWindowToFilm: context.noWindowToFilm, strings: text)
        let announcement = context.announcement
        return Self.undoCard(until: until, filmed: filmed, consent: announcement != nil, text: text,
                             cancel: { ForkMeetingService.shared.cancelAutoStart() },
                             copy: { [weak self] in if let announcement { self?.copy(announcement) } })
    }

    /// "Recording started · Chrome window · [Cancel (4 s)]", with the
    /// consent reminder and its copy button while that setting is on.
    static func undoCard(until: Date, filmed: String, consent: Bool, text: ForkMeetingStrings,
                         cancel: @escaping () -> Void, copy: @escaping () -> Void) -> ForkMeetingCard {
        var card = ForkMeetingCard(symbol: "record.circle", tint: Color(nsColor: .systemRed), title: text.noticeStarted,
                                   lines: [filmed])
        card.actions = [ForkMeetingCard.Action(title: text.undo(seconds: Int(ForkMeetingMachine.undoWindow)),
                                               countdown: ForkMeetingCard.Countdown(until: until) { now in
                                                   ForkMeetingOfferText.undo(until: until, now: now, strings: text)
                                               }, perform: cancel)]
        if consent {
            card.info = text.consentRemind
            card.actions.append(ForkMeetingCard.Action(title: text.copyAnnouncement, perform: copy))
            // Two buttons leave the words no room beside them in the island.
            card.stacked = true
        }
        return card
    }

    /// "Meeting over? · Stopping in 12 s · [Continue]".
    static func endingSoonCard(until: Date, text: ForkMeetingStrings,
                               continueRecording: @escaping () -> Void) -> ForkMeetingCard {
        var card = ForkMeetingCard(symbol: "clock.badge.questionmark", tint: .orange, title: text.endingSoonTitle)
        card.countdownLine = ForkMeetingCard.Countdown(until: until) { now in
            text.endingSoon(seconds: ForkMeetingOfferTiming.secondsLeft(until: until, now: now))
        }
        card.actions = [ForkMeetingCard.Action(title: text.endingSoonContinue, prominent: true,
                                               perform: continueRecording)]
        return card
    }

    // MARK: - Surfaces

    /// In the island when it is free, never taking the keyboard. A click
    /// that collapses the island folds an offer into its reminder; the
    /// island going away moves it to the bubble.
    private func presentInIsland(_ card: ForkMeetingCard, as kind: ForkMeetingOfferUI.Card, minimum: CGFloat) -> Bool {
        let ui = offerUI
        let ours = ui.islandCard.map { ForkMeetingIsland.isShowing(id: $0.id) } ?? false
        guard ForkMeetingIsland.isAvailable || ours else { return false }
        // The presenter's own card is replaced in place, not taken away
        // first, so the island does not close and open again.
        forgetCard()
        let id = ui.islandCard?.id ?? UUID()
        ui.islandCard = (id, kind)
        guard present(card, id: id, minimum: minimum) else {
            ui.islandCard = nil
            return false
        }
        if ui.bubbleCard == kind { hideOfferBubble(kind) }
        return true
    }

    @discardableResult
    private func present(_ card: ForkMeetingCard, id: UUID, minimum: CGFloat = 96) -> Bool {
        let shown = ForkMeetingIsland.present(
            card, id: id, height: ForkMeetingIsland.height(of: card, minimum: minimum),
            fallback: { [weak self] in
                // The island went away under it (turned off, its display
                // gone): the bubble takes the offer and "Cancel".
                guard let self, self.offerUI.islandCard?.id == id else { return }
                self.islandWillBeTaken()
            },
            close: { [weak self] in
                guard let self, let held = self.offerUI.islandCard, held.id == id else { return }
                self.offerUI.islandCard = nil
                guard held.card == .offer else { return }
                // Collapsed by a click, a lock, the capture controls: not a
                // "Not Now", only a fold. Later, so a quitting app folds
                // nothing.
                self.offerUI.islandTurnedAway = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.offerUI.open, self.offerUI.offer != nil else { return }
                    self.foldOffer()
                }
            },
            hover: { [weak self] inside in
                guard let self, self.offerUI.islandCard?.id == id, self.offerUI.islandCard?.card == .offer else { return }
                self.offerHover(inside)
            })
        return shown
    }

    private func removeIslandCard(_ kind: ForkMeetingOfferUI.Card) {
        let ui = offerUI
        guard let held = ui.islandCard, held.card == kind else { return }
        ui.islandCard = nil
        ForkMeetingIsland.remove(id: held.id)
    }

    private func showOfferBubble(_ card: ForkMeetingCard, as kind: ForkMeetingOfferUI.Card) {
        let ui = offerUI
        ui.bubbleCard = kind
        ui.bubble.onHover = { [weak self] inside in
            guard let self, self.offerUI.bubbleCard == .offer else { return }
            self.offerHover(inside)
        }
        let screen = kind == .offer ? offerUI.offer.map { meetingScreen($0.candidate) } ?? self.screen : self.screen
        ui.bubble.show(card, on: screen, hold: nil)
    }

    private func hideOfferBubble(_ kind: ForkMeetingOfferUI.Card) {
        let ui = offerUI
        guard ui.bubbleCard == kind else { return }
        ui.bubbleCard = nil
        ui.bubble.hide()
    }

    // MARK: - The Mac

    /// The display of the meeting's window, where the call is: not the one
    /// under the pointer.
    private func meetingScreen(_ candidate: ForkMeetingCandidate) -> NSScreen? {
        if let windowID = candidate.windowID,
           let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID))
                       as? [[String: Any]])?.first,
           let bounds = info[kCGWindowBounds as String] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: bounds),
           let primary = NSScreen.screens.first {
            // Window bounds count down from the top of the primary screen.
            let center = CGPoint(x: rect.midX, y: primary.frame.maxY - rect.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return screen }
        }
        return screen
    }

    /// The meeting's own icon: the web app's, else the app's.
    private static func icon(for candidate: ForkMeetingCandidate) -> NSImage? {
        if let icon = NSRunningApplication(processIdentifier: candidate.pid)?.icon { return icon }
        for bundle in [candidate.windowBundle, candidate.appBundle].compactMap({ $0 }) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }

    /// "Chrome", "Arc": the running app's name, else its bundle's.
    private static func appName(pid: Int32?, bundle: String?) -> String? {
        if let pid, let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        guard let bundle else { return nil }
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }

    /// The microphone a start would record, by name: for "Automatic", the
    /// input the meeting's app records from (`meetingInput`), else the
    /// system's.
    private static func microphone(_ stored: String, meetingInput: String?) -> ForkMeetingOfferMicrophone {
        let input = ForkMeetingOfferInput.of(ForkMeetingMicrophoneChoice(stored: stored), meetingInput: meetingInput)
        if input == .off { return .off }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return .denied
        default: break
        }
        let system = { ForkDictationAudioDevices.captureDevice(for: ForkDictationAudioDevices.systemChoice) }
        let device: AVCaptureDevice?
        switch input {
        case .system: device = system()
        case .builtIn: device = ForkDictationAudioDevices.captureDevice(for: ForkDictationAudioDevices.builtInChoice)
        case let .chosen(uid): device = ForkDictationAudioDevices.captureDevice(for: uid)
        case let .meetingApp(uid): device = AVCaptureDevice(uniqueID: uid) ?? system()
        case .off: device = nil
        }
        return device.map { .named($0.localizedName) } ?? .off
    }
}
