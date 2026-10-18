// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

/// What a meeting says with words and buttons, in the island's Captures page
/// or in the bubble: the same card in both, which takes the island's look
/// there (`panelCard` reads `notchPresentation`).
///
/// A notice is a mark, a title and a line; an offer to record (next part of
/// the feature) is the same card with its subtitles and its buttons.
struct ForkMeetingCard {
    struct Action {
        let title: String
        /// The button the card is about, drawn filled.
        var prominent = false
        let perform: () -> Void
    }

    var symbol: String
    var tint: Color
    var title: String
    /// Under the title, each on its own lines, in secondary text.
    var lines: [String] = []
    var actions: [Action] = []
}

struct ForkMeetingCardView: View {
    let card: ForkMeetingCard
    /// The bubble's own close button; none in the island, which closes itself.
    var close: (() -> Void)?
    var closeLabel = ""
    @Environment(\.notchPresentation) private var inIsland

    /// The island is wide and short: one row, the buttons at its end. The
    /// bubble is narrow: the text wraps, the buttons go under it, at the
    /// right, where a click is expected.
    var body: some View {
        Group {
            if inIsland {
                HStack(alignment: .center, spacing: 10) {
                    mark
                    // Never cut: the island's card is as tall as its words
                    // (`ForkMeetingIsland.height(of:minimum:)`).
                    words(lineLimit: nil)
                    Spacer(minLength: 8)
                    buttons
                }
                .panelCard()
            } else {
                VStack(alignment: .trailing, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        mark
                        words(lineLimit: 6)
                        Spacer(minLength: 4)
                        closeButton
                    }
                    if !card.actions.isEmpty {
                        HStack(spacing: 8) { buttons }
                    }
                }
            }
        }
    }

    private var mark: some View {
        Image(systemName: card.symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(card.tint)
            .frame(width: 22, height: 20)
            .accessibilityHidden(true)
    }

    private func words(lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
        ForEach(Array(card.actions.enumerated()), id: \.offset) { _, action in
            actionButton(action)
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if let close {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(closeLabel)
            .accessibilityLabel(closeLabel)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: ForkMeetingCard.Action) -> some View {
        let button = Button(action: action.perform) {
            Text(action.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, inIsland ? 10 : 0)
                .frame(minHeight: inIsland ? 28 : 0)
        }
        .accessibilityLabel(action.title)
        if inIsland {
            button
                .buttonStyle(NotchButtonStyle(cornerRadius: 8))
                .background(Color.white.opacity(action.prominent ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 8))
        } else if action.prominent {
            button.buttonStyle(.borderedProminent).controlSize(.small)
        } else {
            button.buttonStyle(.bordered).controlSize(.small)
        }
    }
}

/// The bubble: the meetings' surface when the island cannot take them
/// (turned off, open on something else, hidden in full screen, Screen
/// Capture uninstalled). A glass card in the top right corner of the
/// meeting's display, under the menu bar, where the system's own
/// notifications arrive.
///
/// It takes clicks without taking the keyboard: the call keeps its caret.
/// It is left out of every screen share (`sharingType = .none`), since it
/// names the meeting; our own recording leaves out all of this app's
/// windows anyway.
///
/// It holds one card at a time, the newest. A card stays its `hold`, longer
/// while the pointer rests on it, then `expire` runs: the bubble hides,
/// unless the caller decides otherwise (the offer will fold into a small
/// reminder there).
final class ForkMeetingBubble {
    /// Wide enough for a title, two lines of remedy and two buttons.
    static let maximumWidth: CGFloat = 360
    private static let cornerRadius: CGFloat = 16

    private let model = ForkMeetingBubbleModel()
    private var panel: NSPanel?
    private var holdWork: DispatchWorkItem?
    private var hold: TimeInterval?
    private var expire: (() -> Void)?
    private var pointerInside = false
    /// Bumped by each show: a fade-out overtaken by a newer card must not
    /// order the panel out from its completion handler.
    private var generation = 0

    var windowNumber: Int? { panel.map(\.windowNumber).flatMap { $0 > 0 ? $0 : nil } }

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `hold` nil keeps the card until it is replaced or hidden. False when
    /// there is no display to show it on: the caller says it otherwise.
    @discardableResult
    func show(_ card: ForkMeetingCard, on screen: NSScreen?, hold: TimeInterval?, expire: (() -> Void)? = nil) -> Bool {
        guard let screen = screen ?? ForkDictationHUD.activeScreen() ?? NSScreen.main else { return false }
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let appearing = !panel.isVisible || panel.alphaValue < 1
        model.closeLabel = ForkMeetingStrings.current.bubbleClose
        if appearing || reducesMotion {
            model.card = card
        } else {
            withAnimation(.smooth(duration: 0.25)) { model.card = card }
        }
        self.hold = hold
        self.expire = expire
        place(panel, on: screen)
        scheduleHold()
        guard appearing else { return true }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        return true
    }

    func hide() {
        holdWork?.cancel()
        holdWork = nil
        expire = nil
        pointerInside = false
        guard let panel, panel.isVisible else {
            model.card = nil
            return
        }
        generation += 1
        let hiding = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == hiding else { return }
            panel.orderOut(nil)
            self.model.card = nil
        })
    }

    // MARK: - Hold

    private func scheduleHold() {
        holdWork?.cancel()
        holdWork = nil
        guard let hold, !pointerInside else { return }
        let showing = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == showing else { return }
            if let expire = self.expire {
                self.expire = nil
                expire()
            } else {
                self.hide()
            }
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    /// Reading a card is never cut short: the pointer on it stops its clock,
    /// which starts again in full when the pointer leaves.
    private func hoverChanged(_ inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        if inside {
            holdWork?.cancel()
            holdWork = nil
        } else {
            scheduleHold()
        }
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = OverlayPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 64),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // It names the meeting: never in someone else's screen share.
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = ForkMeetingBubbleView(model: model, cornerRadius: Self.cornerRadius) { [weak self] in
            self?.hide()
        }
        let host = ForkMeetingHostingView(rootView: view)
        host.sizingOptions = []
        host.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        host.frame = panel.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// The top right corner of the display, under the menu bar. A short card
    /// is as wide as its words; a long one takes the bubble's width and wraps,
    /// and its height is asked at that width. Measured on hosts of their own,
    /// so the answer is about the new card.
    private func place(_ panel: NSPanel, on screen: NSScreen) {
        let view = ForkMeetingBubbleView(model: model, cornerRadius: Self.cornerRadius) {}
        let ideal = NSHostingView(rootView: view).fittingSize
        var size = CGSize(width: max(240, ideal.width.rounded(.up)), height: ideal.height)
        if ideal.width >= Self.maximumWidth - 0.5 {
            size.width = Self.maximumWidth
            size.height = NSHostingController(rootView: view)
                .sizeThatFits(in: CGSize(width: Self.maximumWidth, height: 2000)).height
        }
        size.height = max(48, size.height.rounded(.up))
        let area = screen.visibleFrame
        let frame = CGRect(x: (area.maxX - size.width - 12).rounded(), y: (area.maxY - size.height - 8).rounded(),
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }
}

final class ForkMeetingBubbleModel: ObservableObject {
    @Published var card: ForkMeetingCard?
    var closeLabel = ""
}

struct ForkMeetingBubbleView: View {
    @ObservedObject var model: ForkMeetingBubbleModel
    let cornerRadius: CGFloat
    let close: () -> Void

    var body: some View {
        ZStack {
            if let card = model.card {
                ForkMeetingCardView(card: card, close: close, closeLabel: model.closeLabel)
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .padding(.vertical, 12)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: ForkMeetingBubble.maximumWidth, alignment: .leading)
        .background(HUDBackdrop(cornerRadius: cornerRadius, contrast: .high))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// The pill's and the bubble's host: it answers the first click, so a
/// button works without a click to wake the panel first, and reports the
/// pointer through a tracking area that works while another app is active.
final class ForkMeetingHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["forkMeetingHover"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: ["forkMeetingHover": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}
