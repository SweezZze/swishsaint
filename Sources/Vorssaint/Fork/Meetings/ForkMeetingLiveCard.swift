// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

/// The recording's controls in the island, opened by a click on its strip:
/// the meeting's name, what is filmed, the time recorded live and the two
/// levels, then Pause or Resume, Mark and Stop, Stop drawn first in red.
/// The ⋯ in the island's top row films the screen or the window, copies
/// the announcement, and opens the meetings.
///
/// It never takes the keyboard from the call (`takeFocus: false`), and
/// gives it back after a button that leaves it up. It goes a few seconds
/// after the pointer leaves it, and at once when the recording stops, so
/// the island is free for "Meeting saved".
///
/// Main thread only.
final class ForkMeetingLiveCard {
    static let shared = ForkMeetingLiveCard()

    /// The smallest the card is: two rows of the island's controls.
    private static let minimumHeight: CGFloat = 96

    private var id: UUID?
    private var holdWork: DispatchWorkItem?

    private init() {}

    var isShowing: Bool { id.map(ForkMeetingIsland.isShowing(id:)) ?? false }

    /// A click on the strip. The island turns it away while it holds
    /// something else (a dictation, the capture controls): the pill, still
    /// there for those, has the same controls.
    func present() {
        let model = ForkMeetingIslandModel.shared
        guard model.phase?.acceptsControls == true else { return }
        if let id, ForkMeetingIsland.isShowing(id: id) { return }
        // The island holds one card: an offer or "Cancel" there moves to
        // its bubble first.
        ForkMeetingPresenter.shared.islandWillBeTaken()
        let id = UUID()
        self.id = id
        let shown = ForkMeetingIsland.present(
            AnyView(ForkMeetingLiveCardView()), actions: AnyView(ForkMeetingLiveCardMenu()), id: id,
            height: ForkMeetingIsland.height(of: ForkMeetingLiveCardView(), minimum: Self.minimumHeight),
            fallback: { [weak self] in self?.forget(id) },
            close: { [weak self] in self?.forget(id) },
            hover: { [weak self] inside in self?.hover(inside, id: id) })
        if !shown { forget(id) }
    }

    /// The recording changed step: once it stops, the controls have
    /// nothing left to do.
    func stateChanged() {
        guard id != nil, ForkMeetingIslandModel.shared.phase?.acceptsControls != true else { return }
        close()
    }

    /// Takes the card away, if it is up.
    func close() {
        guard let id else { return }
        forget(id)
        ForkMeetingIsland.remove(id: id)
    }

    /// After a button that leaves the card up: typing goes back to the call.
    func buttonUsed() {
        guard isShowing else { return }
        ForkMeetingIsland.giveKeyboardBack()
    }

    private func forget(_ id: UUID) {
        guard self.id == id else { return }
        holdWork?.cancel()
        holdWork = nil
        self.id = nil
    }

    /// The pointer on the card holds it; leaving it, it goes a few seconds
    /// later, unless the pointer comes back.
    private func hover(_ inside: Bool, id: UUID) {
        guard self.id == id else { return }
        holdWork?.cancel()
        holdWork = nil
        guard !inside else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.id == id else { return }
            self.close()
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ForkMeetingIslandRules.cardHold, execute: work)
    }
}

/// The card itself, in the island's look (`panelCard` in the island).
struct ForkMeetingLiveCardView: View {
    @ObservedObject private var model = ForkMeetingIslandModel.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: ForkMeetingStrings { ForkMeetingStrings.strings(l10n.language) }

    var body: some View {
        // Held as it leaves, so it never draws an empty card.
        NotchStripHold(model.snapshot, shows: model.state != .hidden) { snapshot in
            if let snapshot { card(snapshot) }
        }
    }

    private func card(_ snapshot: ForkMeetingIslandSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    ForkMeetingLiveCardMark(phase: snapshot.phase)
                        .id(snapshot.phase.mark)
                        .transition(.blurReplace)
                }
                .frame(width: 22, height: 22)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: snapshot.phase.mark)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(snapshot))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle(snapshot))
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleIsAlert(snapshot) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                ForkMeetingLiveCardClock(snapshot: snapshot, label: text.pillElapsed)
            }
            HStack(alignment: .center, spacing: 8) {
                levels(snapshot)
                Spacer(minLength: 8)
                buttons(snapshot)
            }
        }
        .panelCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text.pillRecording)
    }

    // MARK: Words

    /// In someone else's screen share, the service rather than the
    /// meeting's name, as the pill does.
    private func title(_ snapshot: ForkMeetingIslandSnapshot) -> String {
        ForkMeetingSharedText.pillName(title: snapshot.context.title, providerName: snapshot.context.providerName,
                                       seenInShares: ForkMeetingIsland.showsInCaptures, strings: text)
    }

    /// What is filmed, or why the recording needs an eye: the pill's words.
    private func subtitle(_ snapshot: ForkMeetingIslandSnapshot) -> String {
        let filmed = ForkMeetingServiceSupport.filmed(target: snapshot.context.target, appName: snapshot.context.appName,
                                                      noWindowToFilm: snapshot.context.noWindowToFilm, strings: text)
        switch snapshot.phase {
        case .paused: return text.pillPaused + " · " + filmed
        case .recording:
            if let minutes = diskMinutes { return text.diskMinutes(minutes) }
            if snapshot.context.sourceGone { return text.noticeSourceGone }
            if snapshot.context.pictureFrozen { return text.pillPictureFrozen }
            return filmed
        case .stopping: return text.pillStopping
        case .finalizing: return text.pillFinalizing
        }
    }

    private func subtitleIsAlert(_ snapshot: ForkMeetingIslandSnapshot) -> Bool {
        if snapshot.phase.isPaused || diskMinutes != nil { return true }
        return snapshot.phase.clockRuns && (snapshot.context.sourceGone || snapshot.context.pictureFrozen)
    }

    private var diskMinutes: Int? {
        switch model.state {
        case let .recording(_, minutes), let .paused(_, _, minutes): return minutes
        case .hidden, .stopping, .finalizing: return nil
        }
    }

    // MARK: Levels

    private func levels(_ snapshot: ForkMeetingIslandSnapshot) -> some View {
        HStack(spacing: 14) {
            // A microphone left out by choice is greyed; one that sends
            // nothing, or a meeting not heard, is orange, as on the pill.
            source(snapshot, microphone: true,
                   symbol: snapshot.context.recordsMicrophone ? "mic.fill" : "mic.slash.fill",
                   warns: snapshot.context.recordsMicrophone && snapshot.context.microphoneSilent,
                   label: microphoneLabel(snapshot))
            source(snapshot, microphone: false,
                   symbol: snapshot.hearsMeeting ? "speaker.wave.2.fill" : "speaker.slash.fill",
                   warns: !snapshot.hearsMeeting, label: meetingLabel(snapshot))
        }
    }

    /// A source's mark and its bars; why a source is not heard is its
    /// tooltip and what VoiceOver says.
    private func source(_ snapshot: ForkMeetingIslandSnapshot, microphone: Bool, symbol: String, warns: Bool,
                        label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warns ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .frame(width: 16)
            ForkMeetingLiveCardMeter(snapshot: snapshot, microphone: microphone)
        }
        .help(label)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private func microphoneLabel(_ snapshot: ForkMeetingIslandSnapshot) -> String {
        if !snapshot.context.recordsMicrophone { return text.pillMicrophoneOff }
        if snapshot.context.microphoneSilent { return text.noticeMicrophoneSilent }
        return text.pillMicrophoneLevel
    }

    private func meetingLabel(_ snapshot: ForkMeetingIslandSnapshot) -> String {
        ForkMeetingPillView.soundNote(snapshot.context.trackSound, text: text) ?? text.pillMeetingLevel
    }

    // MARK: Buttons

    @ViewBuilder
    private func buttons(_ snapshot: ForkMeetingIslandSnapshot) -> some View {
        let enabled = snapshot.phase.acceptsControls
        HStack(spacing: 8) {
            if snapshot.phase.isPaused {
                button(symbol: "play.fill", title: text.resumeRecording, label: text.pillResume, enabled: enabled) {
                    model.actions.resume()
                    ForkMeetingLiveCard.shared.buttonUsed()
                }
            } else {
                button(symbol: "pause.fill", title: text.pauseRecording, label: text.pillPause, enabled: enabled) {
                    model.actions.pause()
                    ForkMeetingLiveCard.shared.buttonUsed()
                }
            }
            markButton(snapshot)
            button(symbol: "stop.fill", title: text.stopRecording, label: text.pillStop, enabled: enabled,
                   prominent: true) {
                model.actions.stop()
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: snapshot.phase.isPaused)
    }

    private func markButton(_ snapshot: ForkMeetingIslandSnapshot) -> some View {
        let marked = model.markedUntil != nil
        return button(symbol: marked ? "checkmark" : "bookmark.fill", title: marked ? text.cardMarked : text.cardMark,
                      label: text.cardMarkHelp, enabled: snapshot.phase.canMark && !marked) {
            ForkMeetingService.shared.addMarker()
            model.marked()
            ForkMeetingPresenter.shared.say(text.voiceMarked)
            ForkMeetingLiveCard.shared.buttonUsed()
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: marked)
    }

    private func button(symbol: String, title: String, label: String, enabled: Bool, prominent: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(prominent ? AnyShapeStyle(Color(nsColor: .systemRed))
                            : AnyShapeStyle(Color.white.opacity(0.1)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 8))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The mark at the card's start, the strip's at the card's size.
private struct ForkMeetingLiveCardMark: View {
    let phase: ForkMeetingIslandPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch phase.mark {
        case .dot:
            ForkMeetingRecordingDot(pulses: !reduceMotion, diameter: 12)
                .frame(width: 22, height: 22)
        case .pause:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.orange)
        case .disk:
            Image(systemName: "externaldrive.fill.badge.exclamationmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
        case .gauge:
            ForkMeetingIslandGauge(progress: phase.progress, side: 18)
        }
    }
}

/// The time recorded, large, its digits rolling each second; still and
/// orange while paused. Only this view wakes once a second.
private struct ForkMeetingLiveCardClock: View {
    let snapshot: ForkMeetingIslandSnapshot
    let label: String
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        if snapshot.phase.clockRuns {
            TimelineView(.periodic(from: ForkMeetingIslandStrip.tickStart(snapshot, now: Date()), by: 1)) { context in
                reading(at: context.date)
            }
        } else {
            reading(at: Date())
        }
    }

    private func reading(at now: Date) -> some View {
        let elapsed = snapshot.elapsed(at: now)
        let text = ForkMeetingIslandRules.clock(elapsed)
        return Text(text)
            .font(.system(size: 20, weight: .semibold)).monospacedDigit()
            .foregroundStyle(ForkMeetingIslandStrip.readingColor(snapshot.phase))
            .lineLimit(1)
            .fixedSize()
            .modifier(NotchRollingDigits(value: text, countsDown: false))
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(ForkMeetingIslandRules.spokenDuration(elapsed, language: l10n.language))
    }
}

/// One source's bars on the card, read with the strip's meters.
private struct ForkMeetingLiveCardMeter: View {
    let snapshot: ForkMeetingIslandSnapshot
    let microphone: Bool
    @ObservedObject private var model = ForkMeetingIslandModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let live = snapshot.phase.showsLevels
        let heard = microphone ? snapshot.hearsMicrophone : snapshot.hearsMeeting
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : 1.0 / 15, paused: !live || !heard)) { _ in
            let levels = live ? model.levels() : .silent
            let level = microphone ? levels.microphone : levels.meeting
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    let value = CGFloat(min(1, max(0, level.isFinite ? level : 0)))
                    let lit = heard && live ? min(1, max(0, (value - CGFloat(index) / 5) * 5)) : 0
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(heard ? 0.3 + 0.7 * lit : 0.18))
                        .frame(width: 2.5, height: max(3, 14 * (0.3 + 0.7 * lit)))
                }
            }
            .frame(height: 14)
            .animation(reduceMotion ? nil : .linear(duration: 1.0 / 15), value: level)
        }
        .accessibilityHidden(true)
    }
}

/// The card's ⋯, in the island's top row: the picture's other target, the
/// announcement, the meetings and their settings.
struct ForkMeetingLiveCardMenu: View {
    @ObservedObject private var model = ForkMeetingIslandModel.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let text = ForkMeetingStrings.strings(l10n.language)
        NotchMenuButton(title: text.offerMore, items: items(text), cornerRadius: 9) {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .help(text.offerMore)
    }

    private func items(_ text: ForkMeetingStrings) -> [NotchMenuItem] {
        let context = model.context
        var items: [NotchMenuItem] = []
        if context.canSwitchTarget {
            let window = context.target == .window
            items.append(NotchMenuItem(title: window ? text.pillFilmDisplay : text.pillFilmTheWindow,
                                       symbol: window ? "display" : "macwindow",
                                       enabled: model.phase?.acceptsControls == true) {
                model.actions.toggleTarget()
            })
        }
        if let announcement = context.announcement {
            items.append(NotchMenuItem(title: text.copyAnnouncement, symbol: "doc.on.doc") {
                ForkMeetingPresenter.shared.copy(announcement)
            })
        }
        if !items.isEmpty { items.append(.separator) }
        items.append(NotchMenuItem(title: text.openLibrary, symbol: "film.stack") {
            ForkMeetingLiveCard.shared.close()
            ForkMeetingLibraryWindow.shared.show()
        })
        items.append(NotchMenuItem(title: text.actionOpenMeetings, symbol: "gearshape") {
            ForkMeetingLiveCard.shared.close()
            ForkMeetingService.shared.perform(.openMeetingsPage)
        })
        return items
    }
}
