// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

/// A system setting one of the trackpad gestures depends on, read from its
/// own preference domain: the built-in trackpad's and the Bluetooth one's
/// alike, since either can be the one actually in the person's hands. A
/// gesture whose event never reaches this app does not look broken on its
/// own; this is what says why.
enum ForkTrackpadDiagnosticCheck: CaseIterable {
    /// Trackpad › Point & Click › "Smart zoom": off, no `smartMagnify` event
    /// ever reaches the double-tap gesture.
    case smartZoom
    /// Trackpad › Scroll & Zoom › "Pinch to zoom": off, no `magnify` event
    /// ever reaches the pinch gestures.
    case pinchToZoom
    /// Trackpad › Point & Click › "Force Click and haptic feedback": off,
    /// every haptic click this app asks for is silent.
    case forceClickHaptics

    var preferenceKey: String {
        switch self {
        case .smartZoom: return "TrackpadTwoFingerDoubleTapGesture"
        case .pinchToZoom: return "TrackpadPinch"
        case .forceClickHaptics: return "ActuateDetents"
        }
    }

    /// The built-in trackpad's domain, then the Bluetooth one's: a person
    /// using a Magic Trackpad over Bluetooth has their real setting in the
    /// second, not the first.
    static let preferenceDomains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
    ]

    /// `true` once some trackpad answers that it is on, `false` once every
    /// trackpad that answered says it is off, `nil` when no domain answers
    /// at all (no trackpad known to the system yet, so nothing to warn
    /// about).
    func isEnabled(reading: (_ key: String, _ domain: String) -> Bool?) -> Bool? {
        let answers = Self.preferenceDomains.compactMap { reading(preferenceKey, $0) }
        guard !answers.isEmpty else { return nil }
        return answers.contains(true)
    }
}
