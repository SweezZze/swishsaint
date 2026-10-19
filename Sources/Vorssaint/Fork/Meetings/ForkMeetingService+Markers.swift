// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

extension ForkMeetingService {
    /// Marks this moment of the meeting being recorded: the shortcut "Mark
    /// this moment" and the Command Bar's row call it.
    ///
    /// Implemented by the markers lot (Lot E: the marker in `meeting.json`,
    /// at the meeting's time without its pauses). Until the orchestrator
    /// reconciles the two, this entry point does nothing.
    func addMarker() {}
}
