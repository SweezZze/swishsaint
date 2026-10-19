// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

/// Shows `ForkUpdateNotesView` the way the app shows its own update
/// windows (`AppDelegate.showUpdatePreview`): transparent title bar, sized
/// by its content, centred on the screen under the pointer, in front. One
/// window at a time; a newer offer replaces the content of the open one.
/// Closing it, with its button, Escape or the title bar, is "Later".
final class ForkUpdateNotesWindow: NSObject, NSWindowDelegate {
    static let shared = ForkUpdateNotesWindow()

    private var window: NSWindow?
    private var host: NSHostingController<ForkUpdateNotesView>?
    private var shown: (build: Int, mode: ForkUpdateNotesView.Mode)?
    private var onInstall: (() -> Void)?
    private var onDismiss: (() -> Void)?

    private override init() {}

    var isOpen: Bool { window != nil }

    /// The app's name as the Finder shows it.
    static var appName: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? "Swishsaint"
    }

    /// One of the official windows that open at launch is on screen: the
    /// onboarding, What's New or an update intro.
    static var officialIntroIsOpen: Bool {
        NSApp.windows.contains { window in
            guard window.isVisible, let content = window.contentViewController else { return false }
            return content is NSHostingController<OnboardingView>
                || content is NSHostingController<WhatsNewDigestView>
                || content is NSHostingController<UpdateHighlightsView>
                || content is NSHostingController<UpdateSupportIntroView>
                || content is NSHostingController<UpdateShowcaseIntroView>
        }
    }

    /// Main thread. `onInstall` runs after the window closes; `onDismiss`
    /// when it closes any other way, or when a newer offer takes its place.
    /// The same notes already on screen are only brought forward if
    /// `bringForward` (a check the person asked for).
    func show(_ summary: ForkUpdateNotes.Summary, mode: ForkUpdateNotesView.Mode, bringForward: Bool = true,
              onInstall: @escaping () -> Void = {}, onDismiss: @escaping () -> Void = {}) {
        if let window, let host {
            let same = shown?.build == summary.build && shown?.mode == mode
            if !same { self.onDismiss?() }
            self.onInstall = onInstall
            self.onDismiss = onDismiss
            shown = (summary.build, mode)
            host.rootView = view(summary, mode: mode)
            guard !same || bringForward else { return }
            center(window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.onInstall = onInstall
        self.onDismiss = onDismiss
        shown = (summary.build, mode)
        let host = NSHostingController(rootView: view(summary, mode: mode))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.title = mode == .available ? ForkUpdateStrings.current.notesAvailableTitle
                                          : ForkUpdateStrings.current.notesInstalledTitle
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isMovableByWindowBackground = true
        // It opens on its own, often while another app is in front: it
        // stays above until answered, like the official update intros.
        window.level = .floating
        window.hidesOnDeactivate = false
        window.delegate = self
        center(window)
        self.window = window
        self.host = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window === self.window else { return }
            self.center(window)
        }
    }

    private func view(_ summary: ForkUpdateNotes.Summary, mode: ForkUpdateNotesView.Mode) -> ForkUpdateNotesView {
        ForkUpdateNotesView(summary: summary, mode: mode, appName: Self.appName,
                            onInstall: { [weak self] in self?.install() },
                            onClose: { [weak self] in self?.window?.close() })
    }

    private func install() {
        let action = onInstall
        onInstall = nil
        onDismiss = nil
        window?.close()
        action?()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        let dismiss = onDismiss
        window = nil
        host = nil
        shown = nil
        onInstall = nil
        onDismiss = nil
        dismiss?()
    }

    /// As `AppDelegate.centerIntroWindow`: the size comes from the view
    /// itself, and the window stays inside the visible area.
    private func center(_ window: NSWindow) {
        let visible = window.screen?.visibleFrame ?? NSScreen.pointerVisibleFrame
        window.contentView?.layoutSubtreeIfNeeded()
        if let fitting = window.contentViewController?.view.fittingSize, fitting.width > 0, fitting.height > 0 {
            window.setContentSize(fitting)
        }
        let size = window.frame.size
        let x = min(max(visible.midX - size.width / 2, visible.minX), max(visible.minX, visible.maxX - size.width))
        let y = min(max(visible.midY - size.height / 2, visible.minY), max(visible.minY, visible.maxY - size.height))
        window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}
