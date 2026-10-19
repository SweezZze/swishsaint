// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import SwiftUI

/// The Meetings page's recording indicator (`fork.meetings.indicator`):
/// the recording in the closed island, like the official live activities,
/// and, while it is there, whether the floating indicator (the pill)
/// steps aside or stays. Off, the pill alone says that a meeting records.
struct ForkMeetingIndicatorSection: View {
    let text: ForkMeetingStrings

    @AppStorage(ForkDefaultsKey.meetingsIndicator) private var stored = ForkMeetingIndicator.fallback.rawValue

    private var indicator: ForkMeetingIndicator { ForkMeetingIndicator(stored: stored) }

    var body: some View {
        Section(text.indicatorTitle) {
            Toggle(isOn: islandBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.islandActivity)
                    Text(text.islandActivityCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if indicator.showsStrip {
                VStack(alignment: .leading, spacing: 6) {
                    Picker(text.indicatorPill, selection: pillBinding) {
                        Text(text.indicatorAuto).tag(ForkMeetingIndicator.auto)
                        Text(text.indicatorBoth).tag(ForkMeetingIndicator.both)
                    }
                    Text(indicator == .both ? text.indicatorBothCaption : text.indicatorAutoCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: stored) { _, _ in
            // The strip comes or goes at once, and the pill with it.
            ForkMeetingIslandStrip.refreshIsland()
        }
    }

    /// On brings back the automatic pill; off leaves the pill alone.
    private var islandBinding: Binding<Bool> {
        Binding(get: { indicator.showsStrip },
                set: { stored = ($0 ? ForkMeetingIndicator.auto : .pill).rawValue })
    }

    private var pillBinding: Binding<ForkMeetingIndicator> {
        Binding(get: { indicator == .both ? .both : .auto }, set: { stored = $0.rawValue })
    }
}
