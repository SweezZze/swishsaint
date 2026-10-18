// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The detection's surfaces: the offer (in the island, else the bubble),
/// its folded reminder, "Recording started · Cancel (5 s)" and "Meeting
/// over? Stopping in 15 s [Continue]".
///
/// The service calls these on the main thread, once per effect of the
/// machine, in its order (`ForkMeetingService+Detection`). The person's
/// answers go back through `ForkMeetingService.shared`: `acceptOffer()`,
/// `dismissOffer(.thisTime / .never)`, `alwaysForOffer()`,
/// `copyAnnouncement()`, `cancelAutoStart()` and `continueRecording()`.
/// What the offer records ("Chrome window · Chrome sound · AirPods mic") is
/// `ForkMeetingService.shared.offerCapture(for:)`.
extension ForkMeetingPresenter {
    /// Opens the offer, or shows it again changed: greyed with its reason
    /// (`offer.blocked`), folded (`offer.collapsed`), or with a better name.
    func showOffer(_ offer: ForkMeetingOffer) {
        // Drawn by the offer work.
    }

    /// Folds the offer into its small reminder, unanswered.
    func collapseOffer() {
        // Drawn by the offer work.
    }

    /// Takes the offer and its reminder away.
    func hideOffer() {
        // Drawn by the offer work.
    }

    /// "Recording started · Cancel (5 s)", until `until`.
    func showUndo(until: Date) {
        // Drawn by the offer work.
    }

    func hideUndo() {
        // Drawn by the offer work.
    }

    /// "Meeting over? Stopping in 15 s [Continue]", counting down to `until`.
    func showEndingSoon(until: Date) {
        // Drawn by the offer work.
    }

    func hideEndingSoon() {
        // Drawn by the offer work.
    }
}
