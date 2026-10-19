// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import SwiftUI

/// The island's Meeting button among its controls (seams
/// `notch-meeting-tile*`), as the official recorder's: it starts a
/// recording, or stops the one running, and stays red with the time
/// recorded while one runs. The island closes first, so the recording
/// films the window the person was in, not the island.
struct ForkMeetingIslandTile: View {
    let service: NotchService
    @ObservedObject private var model = ForkMeetingIslandModel.shared
    @ObservedObject private var meetings = ForkMeetingService.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        if let snapshot = model.snapshot, snapshot.phase.clockRuns {
            TimelineView(.periodic(from: ForkMeetingIslandStrip.tickStart(snapshot, now: Date()), by: 1)) { context in
                tile(snapshot, now: context.date)
            }
        } else {
            tile(model.snapshot, now: Date())
        }
    }

    private func tile(_ snapshot: ForkMeetingIslandSnapshot?, now: Date) -> some View {
        let text = ForkMeetingStrings.strings(l10n.language)
        let phase = snapshot?.phase
        let active = phase?.acceptsControls == true || meetings.isStarting
        return NotchActionTile(
            symbol: active ? "stop.fill" : NotchControlItem.meeting.symbol,
            title: active && phase?.isPaused == true ? text.pillPaused : Self.title(l10n.language),
            reading: snapshot.flatMap { $0.phase.acceptsControls ? ForkMeetingIslandRules.clock($0.elapsed(at: now)) : nil },
            compactTitle: active ? Self.title(l10n.language) : nil,
            active: active, accent: .alert) {
            Self.activate(from: service)
        }
        .disabled(!active && !meetings.canStart)
    }

    /// "Meeting", in the controls and in the island's picker.
    static func title(_ language: AppLanguage) -> String {
        ForkMeetingStrings.strings(language).untitledMeeting
    }

    /// A floating quick button (seam `notch-meeting-tile4`), and the tile:
    /// starts, stops, or cancels the start under way.
    static func activate(from service: NotchService = .shared) {
        guard ForkFeature.meetings.isEnabled else { return }
        service.perform { ForkMeetingService.shared.toggleRecording() }
    }

    /// Why the island's Meeting button is off while the feature is, as the
    /// official controls say it (seam `notch-meeting-tile5`).
    static func controlReason(_ language: AppLanguage) -> String? {
        guard !ForkFeature.meetings.isEnabled else { return nil }
        return FeatureStrings.notchEditor(language).enableFeature(ForkExtrasStrings.strings(language).meetingsTitle)
    }

    /// Where that reason leads: the Meetings page, already in Settings.
    static func controlSetupAction() -> (() -> Void)? {
        guard !ForkFeature.meetings.isEnabled else { return nil }
        return { ForkSettingsPages.open(.meetings) }
    }
}
