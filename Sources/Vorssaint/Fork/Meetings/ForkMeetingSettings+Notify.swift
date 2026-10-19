// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import SwiftUI

// MARK: - Status

/// "Recording · 12:03", counting each second like the pill, or "Paused ·
/// 12:03" still. VoiceOver reads the time in words.
struct ForkMeetingLiveStatus: View {
    let clock: ForkMeetingClock
    let paused: Bool
    let text: ForkMeetingStrings

    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        if paused {
            line(at: Date())
        } else {
            // Ticks on the recording's own seconds, so the time turns over
            // when the pill's does.
            TimelineView(.periodic(from: clock.runningSince ?? Date(), by: 1)) { context in
                line(at: context.date)
            }
        }
    }

    private func line(at date: Date) -> some View {
        let elapsed = clock.elapsed(at: date)
        let state = paused ? text.statePaused : text.stateRecording
        return Label {
            Text(state) + Text(" · ") + Text(ForkMeetingPillLayout.clock(elapsed)).monospacedDigit()
        } icon: {
            Image(systemName: paused ? "pause.circle.fill" : "record.circle")
        }
        .font(.callout)
        .foregroundStyle(paused ? Color.orange : Color.red)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state)
        .accessibilityValue(spoken(elapsed))
    }

    /// "12 minutes, 3 seconds", in the app's language.
    private func spoken(_ elapsed: TimeInterval) -> String {
        let seconds = elapsed.isFinite ? max(0, Int(elapsed)) : 0
        return Duration.seconds(seconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)
                .locale(Locale(identifier: l10n.language.rawValue)))
    }
}

/// The last meeting's final pass, with its share done.
struct ForkMeetingFinishingStatus: View {
    let fraction: Double
    let text: ForkMeetingStrings

    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let share = fraction.formatted(.percent.precision(.fractionLength(0))
            .locale(Locale(identifier: l10n.language.rawValue)))
        HStack(spacing: 8) {
            Label(text.stateFinishing, systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .frame(width: 72)
                .accessibilityHidden(true)
            Text(share)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.stateFinishing)
        .accessibilityValue(share)
    }
}

// MARK: - Permissions

/// The notifications, optional: a notice the island and the bubble could not
/// show goes there. Given, still to ask, or refused (their pane in System
/// Settings).
struct ForkMeetingNotificationsRow: View {
    let text: ForkMeetingStrings

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared

    private var state: Permissions.NotificationPermissionState { permissions.notifications }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(FeatureStrings.hub(l10n.language).permNotifications)
                Spacer()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(tint)
            }
            .accessibilityElement(children: .combine)
            Text(text.notificationsCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state != .granted {
                HStack(spacing: 8) {
                    if state == .undetermined {
                        Button(l10n.s.permissionRequest) {
                            Notifier.requestPermission()
                            // The answer comes from the system's alert.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Permissions.shared.refresh() }
                        }
                    }
                    Button(l10n.s.permissionOpenSettings) { permissions.openNotificationSettings() }
                }
                .controlSize(.small)
            }
        }
        // Read at launch and activation only: read again on the page.
        .onAppear { permissions.refresh() }
    }

    private var symbol: String {
        switch state {
        case .granted: return "checkmark.circle.fill"
        case .denied, .undetermined: return "exclamationmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Optional: missing is said without the orange of a permission the
    /// feature needs.
    private var tint: Color {
        state == .granted ? .green : .secondary
    }

    private var status: String {
        switch state {
        case .granted: return l10n.s.permissionGranted
        case .denied, .undetermined: return l10n.s.permissionMissing
        case .unknown: return text.systemAudioUnknown
        }
    }
}

// MARK: - Notifications and sounds

/// One switch per event, each covering its notice in the island or the
/// bubble and its system notification (`ForkMeetingNotifyEvent`); what they
/// never silence is said under them. Then the start and stop sounds.
struct ForkMeetingNotifySection: View {
    let text: ForkMeetingStrings

    @AppStorage(ForkDefaultsKey.meetingsSounds) private var sounds = false

    var body: some View {
        Section(text.notifyTitle) {
            caption(text.notifyCaption)
            ForkMeetingNotifyToggle(event: .offers, title: text.notifyOffers, caption: text.notifyOffersCaption)
            ForkMeetingNotifyToggle(event: .start, title: text.notifyStart, caption: text.notifyStartCaption)
            ForkMeetingNotifyToggle(event: .saved, title: text.notifySaved, caption: text.notifySavedCaption)
            ForkMeetingNotifyToggle(event: .warnings, title: text.notifyWarnings, caption: text.notifyWarningsCaption)
            ForkMeetingNotifyToggle(event: .results, title: text.notifyResults, caption: text.notifyResultsCaption)
            Label(text.notifyAlwaysShown, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $sounds) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.soundsToggle)
                    caption(text.soundsCaption)
                }
            }
        }
    }

    private func caption(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ForkMeetingNotifyToggle: View {
    let event: ForkMeetingNotifyEvent
    let title: String
    let caption: String

    @AppStorage private var isOn: Bool

    init(event: ForkMeetingNotifyEvent, title: String, caption: String) {
        self.event = event
        self.title = title
        self.caption = caption
        _isOn = AppStorage(wrappedValue: true, event.key)
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
