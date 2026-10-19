// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

/// An offer left unanswered, folded: a small grey pill, "○ Meet", where the
/// recording's pill would appear, kept while the meeting lives. A click
/// opens the offer again. It never sounds, never moves and never takes the
/// keyboard: it is there for when the person wants it.
///
/// It names the service, so like the bubble it stays out of every screen
/// share (`sharingType = .none`); our own recording leaves out all of this
/// app's windows anyway.
final class ForkMeetingReminder {
    static let height: CGFloat = 32

    private let model = ForkMeetingReminderModel()
    private var panel: NSPanel?
    private var open: () -> Void = {}
    /// Bumped by each show: a fade-out overtaken by a newer show must not
    /// order the panel out from its completion handler.
    private var generation = 0

    var windowNumber: Int? { panel.map(\.windowNumber).flatMap { $0 > 0 ? $0 : nil } }
    var isVisible: Bool { panel?.isVisible == true && model.title != nil }

    /// `title` is the service's short name ("Meet"), `label` what VoiceOver
    /// and the tooltip say ("Offer to record Weekly sync").
    func show(title: String, label: String, on screen: NSScreen?, open: @escaping () -> Void) {
        guard let screen = screen ?? ForkDictationHUD.activeScreen() ?? NSScreen.main else { return }
        generation += 1
        self.open = open
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let appearing = !panel.isVisible || panel.alphaValue < 1
        model.title = title
        model.label = label
        place(panel, on: screen)
        guard appearing else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        open = {}
        guard let panel, panel.isVisible else {
            model.title = nil
            return
        }
        generation += 1
        let hiding = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == hiding else { return }
            panel.orderOut(nil)
            self.model.title = nil
        })
    }

    private func makePanel() -> NSPanel {
        let panel = OverlayPanel(contentRect: CGRect(x: 0, y: 0, width: 80, height: Self.height),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // It names the service: never in someone else's screen share.
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = ForkMeetingHostingView(rootView: ForkMeetingReminderView(model: model) { [weak self] in
            self?.open()
        })
        host.sizingOptions = []
        host.frame = panel.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// Where the recording's pill appears: the place the person dragged it
    /// to on that display, else right of the island or the camera.
    private func place(_ panel: NSPanel, on screen: NSScreen) {
        let ideal = NSHostingView(rootView: ForkMeetingReminderView(model: model) {}).fittingSize
        let size = CGSize(width: max(Self.height, ideal.width.rounded(.up)), height: Self.height)
        let positions = ForkMeetingPillPositions(
            json: UserDefaults.standard.string(forKey: ForkDefaultsKey.meetingsPillPositions))
        let origin = positions.origin(on: ForkMeetingPill.key(screen), size: size, screenFrame: screen.frame,
                                      visibleFrame: screen.visibleFrame)
            ?? ForkMeetingPillLayout.defaultOrigin(
                size: size, visibleFrame: screen.visibleFrame,
                cameraRightEdge: screen.auxiliaryTopRightArea.flatMap { area in
                    area.isEmpty ? nil : ForkMeetingPillLayout.cameraRightEdge(auxiliaryMinX: area.minX,
                                                                                screenFrame: screen.frame)
                },
                islandFrame: ForkMeetingIsland.restingFrame(on: screen))
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }
}

final class ForkMeetingReminderModel: ObservableObject {
    @Published var title: String?
    @Published var label = ""
}

/// Grey through and through, its dot an empty ring: anything red near the
/// menu bar reads as a recording running, and nothing records yet.
struct ForkMeetingReminderView: View {
    @ObservedObject var model: ForkMeetingReminderModel
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                Text(model.title ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(minWidth: ForkMeetingReminder.height, minHeight: ForkMeetingReminder.height)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(white: 0.3).opacity(0.94))
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: ForkMeetingReminder.height / 2, lifts: false))
        .environment(\.colorScheme, .dark)
        .help(model.label)
        .accessibilityLabel(model.label)
    }
}
