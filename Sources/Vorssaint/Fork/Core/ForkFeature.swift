// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

/// The fork's features, each with its own switch on the Extras page.
///
/// Never a case of the official `AppFeature`: that would touch a dozen
/// official files. A feature added here appears on the Extras page alone.
enum ForkFeature: String, CaseIterable, Identifiable {
    case trackpadGestures

    var id: String { rawValue }

    /// The setting that switches it on.
    var enabledKey: String {
        switch self {
        case .trackpadGestures: return ForkDefaultsKey.gesturesEnabled
        }
    }

    var symbol: String {
        switch self {
        case .trackpadGestures: return "hand.draw"
        }
    }

    func title(_ text: ForkExtrasStrings) -> String {
        switch self {
        case .trackpadGestures: return text.gesturesTitle
        }
    }

    func summary(_ text: ForkExtrasStrings) -> String {
        switch self {
        case .trackpadGestures: return text.gesturesSummary
        }
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Starts or stops what the switch governs, right away.
    func sync() {
        switch self {
        case .trackpadGestures: ForkGestures.sync()
        }
    }
}
