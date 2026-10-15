// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import AppKit

/// Starts and stops the trackpad gestures: the title bar and Dock gestures
/// (`ForkTrackpadGestureService`) and the linked edges between two halves
/// (`ForkLinkedResizeService`).
///
/// Runs on the same conditions as the official Window Layout inputs:
/// Accessibility granted, the session active, the frontmost app not in
/// Window Layout's ignored list. The official service calls `sync` at the
/// end of each of its own syncs (seam `window-layout`), which already
/// follows permission and session changes; the Extras page calls it too.
enum ForkGestures {
    static var isWanted: Bool {
        UserDefaults.standard.bool(forKey: ForkDefaultsKey.gesturesEnabled)
    }

    private static var activationObserver: NSObjectProtocol?

    static func sync() {
        let wanted = isWanted
        let canRun = SessionActivitySupport.tapShouldRun(featureWanted: wanted,
                                                         accessibilityGranted: AXIsProcessTrusted(),
                                                         sessionIsActive: SessionActivity.shared.isActive)
        syncActivationObserver(canRun && !WindowLayoutIgnoredApps.shared.apps.isEmpty)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let allowed = !WindowLayoutIgnoredApps.shared.contains(bundleID: frontmost?.bundleIdentifier,
                                                              executablePath: frontmost?.executableURL?.path)
        if canRun && allowed {
            ForkTrackpadGestureService.shared.start()
            // Only gesture halves are remembered, so the linked edges go with them.
            ForkLinkedResizeService.shared.setEnabled(
                UserDefaults.standard.bool(forKey: ForkDefaultsKey.linkedResizeEnabled))
        } else {
            ForkTrackpadGestureService.shared.stop()
            ForkLinkedResizeService.shared.setEnabled(false)
            // Switched off: nothing of it stays, not even the halves it remembered.
            if !wanted { ForkTrackpadWindowPlacer.shared.reset() }
        }
    }

    /// Before Accessibility is revoked or the app quits.
    static func suspend() {
        syncActivationObserver(false)
        ForkTrackpadGestureService.shared.stop()
        ForkLinkedResizeService.shared.setEnabled(false)
        ForkTrackpadWindowPlacer.shared.reset()
    }

    /// The official service only watches app switches while one of its own
    /// inputs is on: the gestures pause for an ignored app on their own.
    private static func syncActivationObserver(_ observe: Bool) {
        if observe {
            guard activationObserver == nil else { return }
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { _ in sync() }
        } else if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }
}
