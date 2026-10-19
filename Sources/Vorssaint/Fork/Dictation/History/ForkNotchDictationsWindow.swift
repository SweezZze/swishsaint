// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

/// The dictation history while the island cannot show it (island off, or
/// its clipboard page hidden): the island's Dictations page in a small
/// floating window of the island's black. It never activates Swishsaint, so
/// the app the person was in stays in front and a dictation pasted lands there.
final class ForkNotchDictationsWindow {
    static let shared = ForkNotchDictationsWindow()

    private var panel: NSPanel?
    private var host: NSHostingController<ForkNotchDictationsWindowContent>?
    private var localClickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    private static let size = NSSize(width: 520, height: 440)

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    /// Main thread.
    func show() {
        let panel = ensurePanel()
        if !panel.isVisible {
            ForkNotchDictations.shared.rememberPasteTarget()
            // A fresh page on each opening, as the island's: no search left
            // over, the latest dictation highlighted, the field focused.
            host?.rootView = ForkNotchDictationsWindowContent(size: Self.size, opening: UUID())
            place(panel)
        }
        installDismissMonitors(for: panel)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.hide() }
            return
        }
        removeDismissMonitors()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        // The page goes with the window, so a hidden one takes no dictation
        // the bubble asks the island to show, and keeps no key monitor.
        host?.rootView = ForkNotchDictationsWindowContent(size: Self.size, opening: nil)
        ForkNotchDictations.shared.player.stop()
        ForkNotchDictations.shared.setPinnedOnly(false, inWindow: true)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = ForkNotchDictationsPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                             styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false)
        panel.title = ForkDictationStrings.current.historyTitle
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let host = NSHostingController(rootView: ForkNotchDictationsWindowContent(size: Self.size, opening: nil))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(Self.size)
        self.panel = panel
        self.host = host
        return panel
    }

    /// Below the menu bar, centered on the screen being worked on, where the
    /// island would open.
    private func place(_ panel: NSPanel) {
        let screen = ForkDictationHUD.activeScreen() ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(Self.size.width, area.width - 32), height: min(Self.size.height, area.height - 32))
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 8,
                              width: size.width, height: size.height),
                       display: true, animate: false)
    }

    /// Closes on a click elsewhere or when another app comes forward, like
    /// the clipboard history's window.
    private func installDismissMonitors(for panel: NSPanel) {
        removeDismissMonitors()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouse) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            // A card's menu and the confirmation live in windows of their own.
            if event.window !== panel, !Self.pointerIsInside(panel), !(event.window is NSPanel),
               NSApp.modalWindow == nil {
                self.hide()
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouse) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible, NSApp.modalWindow == nil else { return }
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

/// Borderless, it still takes the keyboard for the search, without
/// activating the app.
private final class ForkNotchDictationsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The page on the island's black, with its top row laid out as the open
/// island lays out a row across its top. Empty while the window is hidden.
private struct ForkNotchDictationsWindowContent: View {
    let size: CGSize
    /// Each showing of the window, nil while it is hidden.
    let opening: UUID?

    private var pageSize: CGSize {
        CGSize(width: size.width - 2 * NotchLayout.horizontalInset,
               height: size.height - NotchLayout.chromeHeight - 10)
    }

    var body: some View {
        if let opening { page(opening) } else { Color.clear }
    }

    private func page(_ opening: UUID) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(spacing: NotchLayout.spacing) {
            Color.clear.frame(height: NotchLayout.headerHeight)
            ForkNotchDictationsView(service: .shared, size: pageSize, inWindow: true)
                .frame(width: pageSize.width, height: pageSize.height, alignment: .top)
                .id(opening)
        }
        .overlayPreferenceValue(NotchBandKey.self, alignment: .top) { items in
            NotchBandRow(band: NotchBand()) { items.leading } trailing: { items.trailing }
        }
        .padding(.horizontal, NotchLayout.horizontalInset)
        .padding(.top, 10)
        .padding(.bottom, NotchLayout.bottomInset)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(.black, in: shape)
        .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
    }
}
