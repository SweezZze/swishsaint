// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import AppKit
import Combine

/// Where System Settings keeps the trackpad pane, on macOS 13 and later.
enum ForkTrackpadDiagnosticsSettings {
    static let trackpadSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
    )!

    static func openTrackpadSettings() {
        NSWorkspace.shared.open(trackpadSettingsURL)
    }
}

/// Watches the system settings the trackpad gestures depend on.
///
/// There is no notification for a preference domain changing underneath this
/// app, so the state has to be sampled, and it is sampled only while a
/// surface that shows it registers a demand, the same discipline as
/// `SecureInputMonitor`.
final class ForkTrackpadDiagnosticsMonitor: ObservableObject {
    static let shared = ForkTrackpadDiagnosticsMonitor()

    @Published private(set) var results: [ForkTrackpadDiagnosticCheck: Bool?] = [:]

    private var observingSurfaces: Set<UUID> = []
    private var timer: Timer?

    private static let pollInterval: TimeInterval = 2

    private init() {}

    /// Visible UI owns a stable identifier so repeated SwiftUI appearances
    /// cannot leave an unbalanced timer, matching `Permissions` and
    /// `SecureInputMonitor`.
    func setObservingSurface(_ id: UUID, visible: Bool) {
        if visible {
            observingSurfaces.insert(id)
            refresh()
        } else {
            observingSurfaces.remove(id)
        }
        schedulePolling()
    }

    private func schedulePolling() {
        let shouldPoll = !observingSurfaces.isEmpty
        guard shouldPoll != (timer != nil) else { return }
        guard shouldPoll else {
            timer?.invalidate()
            timer = nil
            return
        }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = Self.pollInterval * 0.4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        var next: [ForkTrackpadDiagnosticCheck: Bool?] = [:]
        for check in ForkTrackpadDiagnosticCheck.allCases {
            next[check] = check.isEnabled(reading: Self.readPreference)
        }
        DispatchQueue.main.async { [weak self] in self?.results = next }
    }

    private static func readPreference(_ key: String, _ domain: String) -> Bool? {
        guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
