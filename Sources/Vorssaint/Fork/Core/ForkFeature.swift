// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import SwiftUI

/// The fork's features, each with its own switch on the Extras page and a
/// page of its own in the Settings sidebar (`ForkSettingsPages`).
///
/// Never a case of the official `AppFeature`: that would touch a dozen
/// official files. A feature added here appears on the Extras page alone,
/// and in the sidebar with one more row in `SettingsDirectory`.
enum ForkFeature: String, CaseIterable, Identifiable {
    case trackpadGestures
    case dictation
    case meetings

    var id: String { rawValue }

    /// The setting that switches it on.
    var enabledKey: String {
        switch self {
        case .trackpadGestures: return ForkDefaultsKey.gesturesEnabled
        case .dictation: return ForkDefaultsKey.dictationEnabled
        case .meetings: return ForkDefaultsKey.meetingsEnabled
        }
    }

    var symbol: String {
        switch self {
        case .trackpadGestures: return "hand.draw"
        case .dictation: return "waveform"
        case .meetings: return "record.circle"
        }
    }

    /// The tile behind the symbol in the Extras list.
    var tint: Color {
        switch self {
        case .trackpadGestures: return .blue
        case .dictation: return .purple
        case .meetings: return .red
        }
    }

    /// Whether it watches input or acts on other apps, which takes
    /// Accessibility.
    var needsAccessibility: Bool {
        switch self {
        case .trackpadGestures, .dictation: return true
        case .meetings: return false
        }
    }

    /// Whether its page asks for Screen Recording at the top while it is
    /// missing: nothing can be filmed without it.
    var needsScreenRecording: Bool {
        switch self {
        case .meetings: return true
        case .trackpadGestures, .dictation: return false
        }
    }

    /// Whether its page asks for the microphone at the top while it is
    /// missing. Dictation asks on its own page, among its permissions.
    var needsMicrophone: Bool {
        switch self {
        case .meetings: return true
        case .trackpadGestures, .dictation: return false
        }
    }

    func title(_ text: ForkExtrasStrings) -> String {
        switch self {
        case .trackpadGestures: return text.gesturesTitle
        case .dictation: return text.dictationTitle
        case .meetings: return text.meetingsTitle
        }
    }

    func summary(_ text: ForkExtrasStrings) -> String {
        switch self {
        case .trackpadGestures: return text.gesturesSummary
        case .dictation: return text.dictationSummary
        case .meetings: return text.meetingsSummary
        }
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Starts or stops what the switch governs, right away.
    func sync() {
        switch self {
        case .trackpadGestures: ForkGestures.sync()
        case .dictation: ForkDictationService.sync()
        case .meetings: ForkMeetingService.sync()
        }
    }
}
