// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import SwiftUI

/// The fork's features, each with its own switch on the Extras page.
///
/// Never a case of the official `AppFeature`: that would touch a dozen
/// official files. A feature added here appears on the Extras page alone.
enum ForkFeature: String, CaseIterable, Identifiable {
    case trackpadGestures
    case claudeUsage
    case dictation

    var id: String { rawValue }

    /// The setting that switches it on.
    var enabledKey: String {
        switch self {
        case .trackpadGestures: return ForkDefaultsKey.gesturesEnabled
        case .claudeUsage: return ForkDefaultsKey.claudeUsageEnabled
        case .dictation: return ForkDefaultsKey.dictationEnabled
        }
    }

    var symbol: String {
        switch self {
        case .trackpadGestures: return "hand.draw"
        case .claudeUsage: return "gauge.with.dots.needle.33percent"
        case .dictation: return "waveform"
        }
    }

    /// The tile behind the symbol in the Extras list.
    var tint: Color {
        switch self {
        case .trackpadGestures: return .blue
        case .claudeUsage: return .orange
        case .dictation: return .purple
        }
    }

    /// Whether it watches input or acts on other apps, which takes
    /// Accessibility.
    var needsAccessibility: Bool {
        switch self {
        case .trackpadGestures, .dictation: return true
        case .claudeUsage: return false
        }
    }

    func title(_ text: ForkExtrasStrings) -> String {
        switch self {
        case .trackpadGestures: return text.gesturesTitle
        case .claudeUsage: return text.claudeUsageTitle
        case .dictation: return text.dictationTitle
        }
    }

    func summary(_ text: ForkExtrasStrings) -> String {
        switch self {
        case .trackpadGestures: return text.gesturesSummary
        case .claudeUsage: return text.claudeUsageSummary
        case .dictation: return text.dictationSummary
        }
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Starts or stops what the switch governs, right away.
    func sync() {
        switch self {
        case .trackpadGestures: ForkGestures.sync()
        case .claudeUsage: if !isEnabled { ForkClaudeUsage.reset() }
        case .dictation: ForkDictationService.sync()
        }
    }
}
