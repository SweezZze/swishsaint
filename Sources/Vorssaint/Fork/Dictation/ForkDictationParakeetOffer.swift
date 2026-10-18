// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// Whether to put Parakeet on this Mac when dictation is wanted without it.
/// A copy of an existing FluidAudio cache downloads nothing, so it needs no
/// question; a download of the model always does.
enum ForkDictationParakeetOffer {
    enum Reason: Equatable {
        /// The person just turned dictation on: asked again, even after "Later".
        case turnedOn
        /// A launch with dictation already on: asked once per Mac.
        case launch
    }

    enum Decision: Equatable {
        case none
        case installSilently
        case ask
    }

    /// `busy`: a dictation is under way, the model is being installed, or a
    /// window the app shows at startup is open. Nothing happens then, and a
    /// launch asks again at the next one.
    static func decide(reason: Reason, enabled: Bool, engine: ForkDictationEngineSetting,
                       installed: Bool, canClone: Bool, alreadyOffered: Bool,
                       busy: Bool) -> Decision {
        guard enabled, engine != .apple, !installed, !busy else { return .none }
        if canClone { return .installSilently }
        if reason == .launch, alreadyOffered { return .none }
        return .ask
    }
}
