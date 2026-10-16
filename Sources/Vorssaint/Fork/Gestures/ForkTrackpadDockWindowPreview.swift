// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import AppKit
import SwiftUI

/// The windows a swipe on a Dock icon is about to bring forward, as real
/// thumbnails on a glass card beside the icon, the way the Dock shows its
/// own previews: ← or → the one window that comes next, ↑ every window of
/// the app.
///
/// Thumbnails come from the window server through the official
/// `WindowPreviewProvider`, its cache first, so a window seen in the
/// switcher shows at once. Without Screen Recording permission, or while a
/// capture is under way, the app's icon stands in. The panel never takes
/// focus or the mouse, and the pointer stays: the icon shows what is acted on.
final class ForkTrackpadDockWindowPreview {
    static let shared = ForkTrackpadDockWindowPreview()

    struct Window: Identifiable, Equatable {
        let id: CGWindowID
        let title: String
    }

    /// At most this many thumbnails: a row that still fits above the Dock.
    static let maxWindows = 4
    static let gap: CGFloat = 10
    /// Room around the card for its shadow.
    static let margin: CGFloat = 16
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 8
    static let titleHeight: CGFloat = 19
    static let singleThumbnail = CGSize(width: 220, height: 138)
    static let rowThumbnail = CGSize(width: 136, height: 86)
    static let disappearDelay: TimeInterval = 0.18
    static let commitDelay: TimeInterval = 0.28

    private let model = ForkTrackpadDockWindowPreviewModel()
    private var panel: NSPanel?
    private var generation = 0
    private(set) var isShown = false
    private var captureTask: Task<Void, Never>?

    private init() {}

    /// - Parameters:
    ///   - itemFrame: the Dock icon, in Accessibility coordinates.
    func show(_ windows: [Window], appIcon: NSImage?, itemFrame: CGRect) {
        let windows = Array(windows.prefix(Self.maxWindows))
        guard !windows.isEmpty else {
            hide()
            return
        }
        if isShown, windows == model.windows { return }

        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.maxY else { return }
        let frames = screens.map { Self.axRect(fromAppKit: $0.frame, primaryHeight: primaryHeight) }
        let center = CGPoint(x: itemFrame.midX, y: itemFrame.midY)
        guard let screen = frames.first(where: { $0.contains(center) }) ?? frames.first else { return }

        let thumbnail = windows.count == 1 ? Self.singleThumbnail : Self.rowThumbnail
        let count = CGFloat(windows.count)
        let card = CGSize(width: count * thumbnail.width + (count - 1) * Self.spacing + 2 * Self.padding,
                          height: thumbnail.height + Self.titleHeight + 2 * Self.padding)
        let size = CGSize(width: card.width + 2 * Self.margin, height: card.height + 2 * Self.margin)
        let frameAX = ForkTrackpadPreviewPlacement.frame(size: size, beside: itemFrame,
                                                         within: screen, gap: Self.gap - Self.margin)
        let edge = ForkTrackpadPreviewPlacement.dockEdge(of: itemFrame, on: screen)

        let wasShown = isShown
        isShown = true
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel

        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            model.appIcon = appIcon
            model.thumbnailSize = thumbnail
            model.growAnchor = switch edge {
            case .bottom: .bottom
            case .left: .leading
            case .right: .trailing
            }
            model.images = model.images.filter { id, _ in windows.contains { $0.id == id } }
            for window in windows where model.images[window.id] == nil {
                if let cached = WindowPreviewProvider.shared.cachedPreview(for: window.id) {
                    model.images[window.id] = cached
                }
            }
            if !wasShown {
                model.exit = .cancel
                model.visible = false
            }
        }
        // An update, ← then →: the card springs to its new content.
        withAnimation(wasShown ? ForkTrackpadGesturePreview.change : nil) { model.windows = windows }
        panel.setFrame(Self.axRect(fromAppKit: frameAX, primaryHeight: primaryHeight), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        if !wasShown {
            withAnimation(Self.appear) { model.visible = true }
        }
        capture(windows)
    }

    func hide(committed: Bool = false) {
        captureTask?.cancel()
        captureTask = nil
        guard isShown, let panel else { return }
        isShown = false
        let hiding = generation
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { model.exit = committed ? .commit : .cancel }
        let delay = committed ? Self.commitDelay : Self.disappearDelay
        withAnimation(reduceMotion ? .easeOut(duration: 0.1)
                                   : committed ? .easeOut(duration: delay * 0.85) : .easeIn(duration: delay * 0.8)) {
            model.visible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak panel] in
            guard let self, let panel, self.generation == hiding, !self.isShown else { return }
            panel.orderOut(nil)
            self.model.windows = []
            self.model.images = [:]
        }
    }

    private static var appear: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.1)
            : .spring(response: 0.3, dampingFraction: 0.78)
    }

    /// One window after the other, the first shown first; each lands as it
    /// comes, and a later gesture's card drops what this one still waits for.
    private func capture(_ windows: [Window]) {
        captureTask?.cancel()
        let missing = windows.map(\.id).filter { model.images[$0] == nil }
        guard !missing.isEmpty, Permissions.shared.screenRecording else {
            captureTask = nil
            return
        }
        let capturing = generation
        captureTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for id in missing {
                guard !Task.isCancelled else { return }
                let image = await WindowPreviewProvider.captureViaWindowServer(id)
                guard !Task.isCancelled, let image else { continue }
                await MainActor.run {
                    guard self.generation == capturing, self.isShown else { return }
                    withAnimation(.easeOut(duration: 0.15)) { self.model.images[id] = image }
                }
            }
        }
    }

    private static func axRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private func makePanel() -> NSPanel {
        let panel = OverlayPanel(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Above the Dock, which it sits beside.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: ForkTrackpadDockWindowPreviewView(model: model))
        hosting.setAccessibilityElement(false)
        panel.contentView = hosting
        return panel
    }
}

// MARK: - Views

private final class ForkTrackpadDockWindowPreviewModel: ObservableObject {
    @Published var windows: [ForkTrackpadDockWindowPreview.Window] = []
    @Published var images: [CGWindowID: CGImage] = [:]
    @Published var appIcon: NSImage?
    @Published var thumbnailSize = ForkTrackpadDockWindowPreview.singleThumbnail
    /// The card grows out of the icon's side.
    @Published var growAnchor: UnitPoint = .bottom
    @Published var visible = false
    @Published var exit: ForkTrackpadPreviewExit = .cancel
}

private struct ForkTrackpadDockWindowPreviewView: View {
    @ObservedObject var model: ForkTrackpadDockWindowPreviewModel

    var body: some View {
        let size = model.thumbnailSize
        HStack(alignment: .top, spacing: ForkTrackpadDockWindowPreview.spacing) {
            ForEach(model.windows) { window in
                VStack(spacing: 5) {
                    thumbnail(window)
                        .frame(width: size.width, height: size.height)
                    Text(window.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                        .frame(width: size.width)
                }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .padding(ForkTrackpadDockWindowPreview.padding)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        // Grows out of the icon, shrinks back into it when nothing happens,
        // and opens out as the windows come forward.
        .scaleEffect(model.visible ? 1 : (model.exit == .commit ? 1.06 : 0.55), anchor: model.growAnchor)
        .opacity(model.visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func thumbnail(_ window: ForkTrackpadDockWindowPreview.Window) -> some View {
        if let image = model.images[window.id] {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .transition(.opacity)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay {
                    if let icon = model.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 40, height: 40)
                            .opacity(0.8)
                    }
                }
        }
    }
}
