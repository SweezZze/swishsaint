// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation
import EventKit
import SwiftUI

/// The Meetings page, below its switch: what a recording is doing, the
/// permissions, the shortcut, what is captured, where it goes, and the
/// consent reminder. The last lasting failure, when there is one, sits on
/// top with its fix. Off, everything that only matters while recording is
/// greyed out; the permissions can still be given beforehand.
struct ForkMeetingSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = ForkMeetingService.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(ForkDefaultsKey.meetingsEnabled) private var enabled = false

    private var text: ForkMeetingStrings { ForkMeetingStrings.strings(l10n.language) }

    /// The failure worth a banner: a lasting one, else the last start
    /// refused, which stays while the page is open. A missing Screen
    /// Recording or microphone is already asked for at the top of the page,
    /// and a local build has its own note.
    private var bannerFailure: ForkMeetingFailure? {
        guard let failure = service.lastFailure ?? service.lastRefusal else { return nil }
        switch failure {
        case .screenRecordingDenied where !permissions.screenRecording: return nil
        case .microphoneDenied where permissions.microphone != .granted: return nil
        case .localBuild: return nil
        default: return failure
        }
    }

    var body: some View {
        if !ForkMeetingService.hasForkPermissionTexts {
            ForkMeetingLocalBuildNote(text: text)
        }
        if let failure = bannerFailure {
            ForkMeetingFailureBanner(failure: failure, text: text)
        }

        ForkMeetingRecordSection(text: text)
        ForkMeetingPermissionsSection(text: text)
        ForkMeetingDetectionSection(text: text)
            .disabled(!enabled)
        ForkMeetingShortcutSection(text: text)
            .disabled(!enabled)
        ForkMeetingCaptureSection(text: text)
            .disabled(!enabled)
        ForkMeetingLibrarySection(text: text)
            .disabled(!enabled)
        ForkMeetingTranscriptSection(text: text)
        ForkMeetingExportsSection(text: text)
            .disabled(!enabled)
        ForkMeetingAdvancedSection(text: text)
            .disabled(!enabled)
    }
}

// MARK: - Banners

/// A local build asks for the microphone and the Mac's sound with the
/// official texts, which only speak of screen recordings.
private struct ForkMeetingLocalBuildNote: View {
    let text: ForkMeetingStrings

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text.failBuild)
                        .fontWeight(.semibold)
                    Text(text.failBuildRemedy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The last thing that went wrong, said in full, with the button that fixes
/// it when there is one.
private struct ForkMeetingFailureBanner: View {
    let failure: ForkMeetingFailure
    let text: ForkMeetingStrings

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.summary(text))
                        .fontWeight(.semibold)
                    Text(failure.remedy(text))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                if let action = failure.action, let label = label(for: action) {
                    Button(label) { ForkMeetingService.shared.perform(action) }
                        .controlSize(.small)
                }
                Button {
                    ForkMeetingService.shared.clearFailure()
                    ForkMeetingService.shared.clearRefusal()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(text.actionDismiss)
                .accessibilityLabel(text.actionDismiss)
            }
        }
    }

    private func label(for action: ForkMeetingFailureAction) -> String? {
        switch action {
        case .openScreenRecordingPrivacy, .openMicrophonePrivacy: return text.actionOpenSettings
        case .openStorageSettings: return text.actionOpenStorage
        case .openMeetingsFolder: return text.actionShowFolder
        // Already on the page.
        case .openMeetingsPage: return nil
        }
    }
}

// MARK: - Recording

/// What a recording is doing, and the buttons that start, pause and stop it.
private struct ForkMeetingRecordSection: View {
    let text: ForkMeetingStrings

    @ObservedObject private var service = ForkMeetingService.shared
    @AppStorage(ForkDefaultsKey.meetingsEnabled) private var enabled = false
    @AppStorage(ForkDefaultsKey.meetingsConsentAcknowledged) private var acknowledged = false
    @AppStorage(ForkDefaultsKey.meetingsShortcut) private var shortcutStorage = ""

    var body: some View {
        Section {
            HStack(alignment: .top) {
                Text(text.pageHowTo)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                // Like every part of the feature, off with it.
                Button(text.openLibrary) { ForkMeetingLibraryWindow.shared.show() }
                    .disabled(!enabled)
            }
            if enabled && !acknowledged {
                HStack(alignment: .firstTextBaseline) {
                    Label(text.setupPending, systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(text.setupContinue) { service.presentConsent() }
                }
            } else {
                HStack {
                    status
                    Spacer()
                    buttons
                }
            }
        }
        // A start refused is said while the page stays open.
        .onDisappear { service.clearRefusal() }
    }

    /// A meeting still finishing says so, the feature turned off or not.
    @ViewBuilder
    private var status: some View {
        if service.isRecording && service.isPaused {
            Label(text.statePaused, systemImage: "pause.circle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if service.isRecording {
            Label(text.stateRecording, systemImage: "record.circle")
                .font(.callout)
                .foregroundStyle(.red)
        } else if service.isStarting {
            Label(text.stateStarting, systemImage: "record.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if service.isBusy {
            Label(text.stateFinishing, systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !enabled {
            Label(text.stateOff, systemImage: "pause.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Label(ready, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        }
    }

    /// Ready, with the shortcut that starts a recording when there is one.
    private var ready: String {
        guard let shortcut = ForkMeetingShortcut.decode(shortcutStorage) else { return text.stateReady }
        return "\(text.stateReady) · \(shortcut.displayString)"
    }

    @ViewBuilder
    private var buttons: some View {
        if service.isRecording {
            Button(service.isPaused ? text.resumeRecording : text.pauseRecording) { service.togglePause() }
            Button(text.stopRecording) { service.stop() }
                .buttonStyle(.borderedProminent)
        } else if service.isStarting {
            Button(text.cancel) { service.cancelStart() }
        } else {
            // A meeting still being finalized does not stand in the way.
            Button {
                service.startManually()
            } label: {
                Label(text.recordNow, systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!enabled || !service.canStart)
        }
    }
}

// MARK: - Permissions

/// Screen Recording and the microphone once given (missing, the top of the
/// page asks for them), and the Mac's sound, which nothing can read.
private struct ForkMeetingPermissionsSection: View {
    let text: ForkMeetingStrings

    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        Section(text.permissionsTitle) {
            Text(text.permissionsCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if permissions.screenRecording {
                PermissionRow(kind: .screenRecording)
            }
            if permissions.microphone == .granted {
                PermissionRow(kind: .microphone)
            }
            ForkMeetingSystemAudioRow(text: text)
        }
    }
}

/// The permission to record other apps' sound. macOS has no call that reads
/// it: the row says what the last recording found (green once a tap heard
/// sound, orange once one found it silent, unknown before), and opens the
/// right pane.
struct ForkMeetingSystemAudioRow: View {
    let text: ForkMeetingStrings

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = ForkMeetingService.shared
    /// What the last recording found, absent until one judged.
    @AppStorage(ForkDefaultsKey.meetingsSystemAudioVerified) private var verified: Bool?

    private var permission: ForkMeetingServiceSupport.SystemAudioPermission {
        ForkMeetingServiceSupport.systemAudioPermission(verified: verified,
                                                        failing: service.lastFailure == .systemAudioUnavailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(text.systemAudioName)
                Spacer()
                Text(state)
                    .font(.caption)
                    .foregroundStyle(tint)
            }
            .accessibilityElement(children: .combine)
            Text(text.systemAudioCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(text.systemAudioFallback)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(text.systemAudioCheck) { Permissions.shared.openAudioCaptureSettings() }
                .controlSize(.small)
        }
    }

    private var symbol: String {
        switch permission {
        case .allowed: return "checkmark.circle.fill"
        case .missing: return "exclamationmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch permission {
        case .allowed: return .green
        case .missing: return .orange
        case .unknown: return .secondary
        }
    }

    private var state: String {
        switch permission {
        case .allowed: return l10n.s.permissionGranted
        case .missing: return l10n.s.permissionMissing
        case .unknown: return text.systemAudioUnknown
        }
    }
}

// MARK: - Detection

/// What a detected meeting does, provider by provider: offered, recorded on
/// its own, or never; named after the calendar event that links to it; and
/// its end, which stops the recording it started after a countdown. What
/// this Mac cannot read is said plainly: the microphones before macOS 14.4
/// (Google Meet and Zoom only, by their titles), the windows' titles
/// without Screen Recording. FaceTime records the whole Mac: said on its row.
private struct ForkMeetingDetectionSection: View {
    let text: ForkMeetingStrings

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = ForkMeetingService.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(ForkDefaultsKey.meetingsEnabled) private var enabled = false
    @AppStorage(ForkDefaultsKey.meetingsApps) private var apps = ForkMeetingPolicies.defaultJSON
    @AppStorage(ForkDefaultsKey.meetingsCalendarNaming) private var calendarNaming = false
    @AppStorage(ForkDefaultsKey.meetingsAutoStop) private var autoStop = true
    @AppStorage(ForkDefaultsKey.meetingsAutoStopSeconds) private var autoStopSeconds = ForkMeetingAutoStop.defaultSeconds

    /// The countdown's choices; a stored value outside them is shown too.
    private static let choices = [5, 10, 15, 30, 60]

    private static let rows = ForkMeetingProviderTable.current.policyRows

    var body: some View {
        Section(text.detectionTitle) {
            caption(text.detectionCaption)
            ForEach(Self.rows, id: \.id) { row in
                ForkMeetingProviderRow(row: row, text: text, apps: $apps,
                                       microphoneSignal: ForkMeetingMicWatcher.isSupported)
            }
            if ForkMeetingDetectionSupport.saysAlwaysDelay(ForkMeetingPolicies(json: apps),
                                                           microphoneSignal: ForkMeetingMicWatcher.isSupported) {
                caption(text.detectionAlwaysDelay)
            }
            ForEach(policyCaptions, id: \.self) { line in caption(line) }
            // A page that copies a Meet title and uses the microphone could
            // be offered: said once, plainly, while Meet is not "Never".
            if ForkMeetingDetectionSupport.warnsOfLookalikes(ForkMeetingPolicies(json: apps).policy(for: .googleMeet)) {
                caption(text.detectionLookalike)
            }
            if let limit {
                Label(limit + " " + text.detectionAlwaysUnavailable, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !permissions.screenRecording {
                Label(text.detectionNeedsScreenRecording, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if enabled, let meeting = service.detectedMeeting {
                Label(text.detected(meeting.name), systemImage: "video.fill")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Toggle(isOn: $calendarNaming) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.calendarNaming)
                    caption(text.calendarNamingCaption)
                }
            }
            .onChange(of: calendarNaming) { _, isOn in
                // Turned on, the calendar is asked for at once, as the
                // official calendar's switch does.
                if isOn, permissions.calendarAccess == .notDetermined { permissions.requestCalendar() }
                ForkMeetingService.sync()
            }
            if calendarNaming {
                ForkMeetingCalendarRow(text: text)
            }

            Toggle(isOn: $autoStop) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.autoStop)
                    caption(text.autoStopCaption)
                }
            }
            Picker(text.autoStopDelay, selection: delay) {
                ForEach(delays, id: \.self) { seconds in
                    Text(label(seconds)).tag(seconds)
                }
            }
            .disabled(!autoStop)
        }
    }

    /// What each choice in use does: "Offer" always, the others once a
    /// provider has them (Discord is "Never" from the start).
    private var policyCaptions: [String] {
        let policies = ForkMeetingPolicies(json: apps)
        let signal = ForkMeetingMicWatcher.isSupported
        let used = Set(Self.rows.compactMap { row in
            row.providers.first.map { row.shown(policies.policy(for: $0), microphoneSignal: signal) }
        })
        let lines: [(ForkMeetingPolicy, String, String)] = [
            (.ask, text.policyAsk, text.policyAskCaption), (.always, text.policyAlways, text.policyAlwaysCaption),
            (.never, text.policyNever, text.policyNeverCaption),
        ]
        return lines.filter { $0.0 == .ask || used.contains($0.0) }.map { $0.1 + " · " + $0.2 }
    }

    /// The microphones cannot be read on this Mac: the titles alone.
    private var limit: String? {
        guard !ForkMeetingMicWatcher.isSupported else { return nil }
        if #available(macOS 14.4, *) { return text.detectionMicrophoneUnreadable }
        return text.detectionTitlesOnly
    }

    /// The delay the countdown really gives: a stored one out of bounds
    /// (written by hand, or restored) reads as its bound, as it runs.
    private var delay: Binding<Int> {
        Binding(get: { ForkMeetingAutoStop.bounded(autoStopSeconds) }, set: { autoStopSeconds = $0 })
    }

    private var delays: [Int] {
        let shown = ForkMeetingAutoStop.bounded(autoStopSeconds)
        return Self.choices.contains(shown) ? Self.choices : (Self.choices + [shown]).sorted()
    }

    /// "15 s", in the app's language.
    private func label(_ seconds: Int) -> String {
        Measurement(value: Double(seconds), unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided)
                .locale(Locale(identifier: l10n.language.rawValue)))
    }

    private func caption(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Apps

/// One provider's choice, with its app's icon when it is installed. A row
/// this Mac cannot recognize (before macOS 14.4, an app found by its
/// microphone alone) is greyed out and says so.
private struct ForkMeetingProviderRow: View {
    let row: ForkMeetingPolicyRow
    let text: ForkMeetingStrings
    @Binding var apps: String
    let microphoneSignal: Bool

    @AppStorage(ForkDefaultsKey.meetingsSystemAudio) private var sound = ForkMeetingSystemAudio.fallback.rawValue
    @State private var icon: NSImage?

    private var policy: Binding<ForkMeetingPolicy> {
        Binding(get: {
                    row.shown(row.providers.first.map(ForkMeetingPolicies(json: apps).policy(for:)) ?? .ask,
                              microphoneSignal: microphoneSignal)
                },
                set: { policy in
                    var policies = ForkMeetingPolicies(json: apps)
                    policies.set(policy, for: row.id)
                    apps = policies.json
                })
    }

    var body: some View {
        let recognized = row.recognized(microphoneSignal: microphoneSignal)
        Picker(selection: policy) {
            Text(text.policyAsk).tag(ForkMeetingPolicy.ask)
            if row.showsAlways(microphoneSignal: microphoneSignal) {
                Text(text.policyAlways).tag(ForkMeetingPolicy.always)
            }
            Text(text.policyNever).tag(ForkMeetingPolicy.never)
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: row.appBundles.isEmpty ? "globe" : "video")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name ?? text.detectionOtherWebCalls)
                    if !recognized {
                        note(text.detectionUnavailable)
                    } else if row.name == nil {
                        note(text.detectionOtherWebCallsCaption)
                    }
                    if recognized, row.warnsWholeMac(policy.wrappedValue,
                                                     sound: ForkMeetingSystemAudio(rawValue: sound) ?? .fallback) {
                        Label(text.detectionFaceTimeWholeMac, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if recognized, row.notesRelayedCalls(policy.wrappedValue) {
                        note(text.detectionFaceTimeRelayed)
                    }
                }
            }
        }
        .disabled(!recognized)
        .onAppear { if icon == nil { icon = Self.icon(row.appBundles) } }
    }

    private func note(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The first of the row's apps installed on this Mac.
    private static func icon(_ bundles: [String]) -> NSImage? {
        for bundle in bundles {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }
}

/// The calendar's permission, asked for "Name with the calendar": given,
/// still to ask, or refused (its pane in System Settings).
private struct ForkMeetingCalendarRow: View {
    let text: ForkMeetingStrings

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared

    private var granted: Bool { permissions.calendarAccess == .fullAccess }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                    .accessibilityHidden(true)
                Text(text.calendarPermission)
                Spacer()
                Text(granted ? l10n.s.permissionGranted : l10n.s.permissionMissing)
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .orange)
            }
            .accessibilityElement(children: .combine)
            if !granted {
                HStack(spacing: 8) {
                    if permissions.calendarAccess == .notDetermined {
                        Button(l10n.s.permissionRequest) { permissions.requestCalendar() }
                            .disabled(permissions.requestingCalendar)
                    }
                    Button(l10n.s.permissionOpenSettings) { permissions.openCalendarSettings() }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Shortcut

/// One combination that starts a recording, or stops the one running, from
/// any app. Refused when it cannot work, with the reason.
private struct ForkMeetingShortcutSection: View {
    let text: ForkMeetingStrings

    @AppStorage(ForkDefaultsKey.meetingsShortcut) private var stored = ""
    @AppStorage(ForkDefaultsKey.meetingsEnabled) private var enabled = false
    @ObservedObject private var service = ForkMeetingService.shared
    /// The problem of the combination just typed, or of the stored one,
    /// read once per change: asking the window server on every redraw
    /// would make the page lag.
    @State private var problem: ForkMeetingShortcutProblem?

    /// Shown in the field when there is no shortcut: `emptyTitle` hides it.
    private static let placeholder = GlobalShortcut(keyCode: 15, modifiers: [.control, .option, .command])

    private var shortcut: GlobalShortcut? { ForkMeetingShortcut.decode(stored) }

    var body: some View {
        Section(text.shortcutTitle) {
            HStack(spacing: 8) {
                Text(text.shortcutLabel)
                Spacer()
                ShortcutRecorderButton(
                    shortcut: shortcut ?? Self.placeholder,
                    isEnabled: enabled,
                    waitingTitle: text.shortcutPrompt,
                    emptyTitle: shortcut == nil ? text.shortcutNone : nil,
                    clearAction: { save(nil) },
                    recordingChanged: { ForkMeetingService.shared.setShortcutRecording($0) },
                    invalidAction: { problem = .needsModifier },
                    captureAction: { save($0) })
                    .frame(width: 140)
                    .accessibilityLabel(text.shortcutLabel)
                if shortcut != nil {
                    Button {
                        save(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(text.shortcutRemove)
                    .accessibilityLabel(text.shortcutRemove)
                }
            }
            Text(text.shortcutCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { problem = shortcut.flatMap { ForkMeetingShortcut.problem(of: $0) } }
        // Leaving the page mid-recording must give the hotkey back.
        .onDisappear { ForkMeetingService.shared.setShortcutRecording(false) }
    }

    private var warning: String? {
        switch problem {
        case .reservedKey: return text.shortcutReserved
        case .needsModifier: return text.shortcutNeedsModifier
        case .conflict: return text.shortcutConflict
        case nil: return service.shortcutRefused && shortcut != nil ? text.shortcutRefused : nil
        }
    }

    /// A combination that cannot work is not saved: the previous one stays,
    /// and the reason is said under the field.
    private func save(_ captured: GlobalShortcut?) {
        if let captured, let refusal = ForkMeetingShortcut.problem(of: captured) {
            problem = refusal
            return
        }
        problem = nil
        ForkMeetingShortcut.save(captured)
        ForkMeetingService.sync()
    }
}

// MARK: - Capture

/// The meeting's window or its whole display, with what each means: the
/// detected meeting's window, else the window in front for a recording
/// started by hand. Or no picture at all, with what an hour of it weighs.
struct ForkMeetingPicturePicker: View {
    let text: ForkMeetingStrings
    @Binding var target: String

    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(text.pictureTitle, selection: $target) {
                Text(text.pictureMeetingWindow).tag(ForkMeetingCaptureTarget.window.rawValue)
                Text(text.pictureFrontDisplay).tag(ForkMeetingCaptureTarget.display.rawValue)
                Text(soundOnlyLabel).tag(ForkMeetingCaptureTarget.audioOnly.rawValue)
            }
            .pickerStyle(.radioGroup)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var caption: String {
        switch ForkMeetingCaptureTarget(stored: target) {
        case .window: return text.pictureMeetingWindowCaption
        case .display: return text.pictureDisplayCaption
        case .audioOnly:
            // No tap before macOS 14.4, and no stream to stand in for it.
            if #available(macOS 14.4, *) { return text.soundOnlyCaption }
            return text.soundOnlyCaption + "\n" + text.soundOnlyBefore144
        }
    }

    /// "Sound only · ~0.1 GB/h", the decimal in the app's language, as the
    /// quality presets say theirs.
    private var soundOnlyLabel: String {
        let size = ForkMeetingAudioOnly.estimatedGigabytesPerHour
            .formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: l10n.language.rawValue)))
        return "\(text.soundOnly) · \(text.perHour(size))"
    }
}

private struct ForkMeetingCaptureSection: View {
    let text: ForkMeetingStrings

    @ObservedObject private var l10n = L10n.shared
    @AppStorage(ForkDefaultsKey.meetingsCaptureTarget) private var target = ForkMeetingCaptureTarget.fallback.rawValue
    @AppStorage(ForkDefaultsKey.meetingsSystemAudio) private var sound = ForkMeetingSystemAudio.fallback.rawValue
    @AppStorage(ForkDefaultsKey.meetingsQuality) private var quality = ForkMeetingQuality.fallback.rawValue

    var body: some View {
        Section(text.captureTitle) {
            ForkMeetingPicturePicker(text: text, target: $target)

            Picker(text.soundTitle, selection: $sound) {
                Text(text.soundApp).tag(ForkMeetingSystemAudio.app.rawValue)
                Text(text.soundAll).tag(ForkMeetingSystemAudio.all.rawValue)
                Text(text.soundOff).tag(ForkMeetingSystemAudio.off.rawValue)
            }
            if let note = soundCaption {
                caption(note)
            }

            ForkMeetingMicrophonePicker(text: text)

            Picker(text.qualityTitle, selection: $quality) {
                ForEach(ForkMeetingQuality.allCases, id: \.self) { preset in
                    Text(label(preset)).tag(preset.rawValue)
                }
            }
            // The picture's quality: nothing to choose without one.
            .disabled(!ForkMeetingCaptureTarget(stored: target).filmsPicture)
            caption(qualityCaption)
        }
    }

    private var soundCaption: String? {
        switch ForkMeetingSystemAudio(stored: sound) {
        // With no app to hear, nothing stands in for it: said here.
        case .app: return text.soundAppCaption + "\n" + text.soundAppNoAppCaption
        case .all:
            // No tap before macOS 14.4: a filmed window gives its app alone.
            if #available(macOS 14.4, *) { return text.soundAllCaption }
            return text.soundAllCaption + "\n" + text.soundAllBefore144
        case .off: return nil
        }
    }

    private var qualityCaption: String {
        switch ForkMeetingQuality(stored: quality) {
        case .light: return text.qualityLightCaption
        case .standard: return text.qualityStandardCaption
        case .high: return text.qualityHighCaption
        }
    }

    /// "Standard · ~0.6 GB/h", the decimal in the app's language.
    private func label(_ preset: ForkMeetingQuality) -> String {
        let name: String
        switch preset {
        case .light: name = text.qualityLight
        case .standard: name = text.qualityStandard
        case .high: name = text.qualityHigh
        }
        let size = preset.estimatedGigabytesPerHour
            .formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: l10n.language.rawValue)))
        return "\(name) · \(text.perHour(size))"
    }

    private func caption(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The meeting's microphone by default, the system's, the built-in one, a
/// device by name, or none.
private struct ForkMeetingMicrophonePicker: View {
    let text: ForkMeetingStrings

    @AppStorage(ForkDefaultsKey.meetingsMicrophone) private var microphone = ForkMeetingMicrophoneChoice.fallback.storageValue
    @State private var devices: [ForkDictationAudioDevice] = []

    private var choice: ForkMeetingMicrophoneChoice { ForkMeetingMicrophoneChoice(stored: microphone) }

    var body: some View {
        Group {
            Picker(text.microphoneTitle, selection: $microphone) {
                Text(text.microphoneMeeting).tag(ForkMeetingMicrophoneChoice.meeting.storageValue)
                Text(text.microphoneSystem).tag(ForkMeetingMicrophoneChoice.system.storageValue)
                Text(text.microphoneBuiltIn).tag(ForkMeetingMicrophoneChoice.builtIn.storageValue)
                Divider()
                ForEach(devices.filter { !$0.isBuiltIn }) { device in
                    Text(device.name).tag(device.id)
                }
                if isMissing {
                    Text(text.microphoneMissing(ForkMeetingMicrophoneNames.known[microphone] ?? microphone))
                        .tag(microphone)
                }
                Divider()
                Text(text.microphoneOff).tag(ForkMeetingMicrophoneChoice.off.storageValue)
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in reload() }
    }

    /// A device chosen earlier and unplugged since, or chosen on another
    /// Mac: still shown, so the choice is not silently lost.
    private var isMissing: Bool {
        guard case .device = choice else { return false }
        return choice.effective(available: devices.filter { !$0.isBuiltIn }.map(\.id)) != choice
    }

    private var caption: String? {
        if isMissing { return text.microphoneMissingCaption }
        return choice == .meeting ? text.microphoneMeetingCaption : nil
    }

    private func reload() {
        devices = ForkDictationAudioDevices.inputs()
        for device in devices { ForkMeetingMicrophoneNames.known[device.id] = device.name }
    }
}

/// The names of the microphones seen since launch: one chosen and then
/// unplugged keeps its name in the menu rather than a raw identifier.
private enum ForkMeetingMicrophoneNames {
    static var known: [String: String] = [:]
}

// MARK: - Library

private struct ForkMeetingLibrarySection: View {
    let text: ForkMeetingStrings

    @ObservedObject private var l10n = L10n.shared
    @AppStorage(ForkDefaultsKey.meetingsFolder) private var folder = ""
    @AppStorage(ForkDefaultsKey.meetingsExtractAudio) private var extractAudio = true
    @AppStorage(ForkDefaultsKey.meetingsRetentionDays) private var retentionDays = ForkMeetingRetention.fallback
    /// A shorter delay waiting for its confirmation, with what it would take.
    @State private var retentionAsked: (days: Int, count: Int)?
    @ObservedObject private var sweep = ForkMeetingRetentionSweep.shared

    /// Read with the setting and the language: the default folder is named
    /// in the person's language until a first recording saves it.
    private var root: ForkMeetingFolder.Root {
        _ = folder
        _ = l10n.language
        return ForkMeetingService.root
    }

    var body: some View {
        Section(text.libraryTitle) {
            LabeledContent(text.folderTitle) {
                Text((root.url.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(root.url.path)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(text.folderChange, action: choose)
                Button(text.folderOpen) { ForkMeetingService.shared.openFolder() }
            }
            Toggle(isOn: $extractAudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.extractAudio)
                    Text(text.extractAudioCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker(selection: retention) {
                ForEach(ForkMeetingRetention.choices, id: \.self) { days in
                    Text(days == 0 ? text.retentionNever : text.retentionDays(days)).tag(days)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.retentionTitle)
                    Text(text.retentionCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let held = sweep.held, held.days == ForkMeetingRetention.sanitized(retentionDays) {
                // Too many at once for the automatic bin: nothing went, and
                // nothing goes without the person.
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(text.retentionHeld(count: held.count, days: held.days))
                            Text(text.retentionHeldCaption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(text.actionTrash, role: .destructive) { sweep.confirmHeld() }
                }
            }
        }
        .alert(text.retentionConfirmTitle, isPresented: retentionConfirming) {
            Button(text.actionTrash, role: .destructive) {
                guard let asked = retentionAsked else { return }
                retentionAsked = nil
                apply(asked.days, confirmed: asked.count)
            }
            Button(text.cancel, role: .cancel) { retentionAsked = nil }
        } message: {
            if let asked = retentionAsked {
                Text(text.retentionConfirm(count: asked.count, days: asked.days))
            }
        }
    }

    /// Turning the bin on or shortening it asks first when meetings would
    /// go now, with how many; anything else applies at once.
    private var retention: Binding<Int> {
        Binding(get: { ForkMeetingRetention.sanitized(retentionDays) }, set: { days in
            let old = ForkMeetingRetention.sanitized(retentionDays)
            guard days != old else { return }
            guard days > 0, old == 0 || days < old else {
                apply(days)
                return
            }
            ForkMeetingStore.shared.retentionDue(days: days, writing: ForkMeetingService.shared.writingFolders) { due, _ in
                if ForkMeetingRetention.needsConfirmation(from: old, to: days, due: due.count) {
                    retentionAsked = (days, due.count)
                } else {
                    apply(days)
                }
            }
        })
    }

    private var retentionConfirming: Binding<Bool> {
        Binding(get: { retentionAsked != nil }, set: { if !$0 { retentionAsked = nil } })
    }

    /// `confirmed`: the number the person just agreed to, which the sweep
    /// may take at once; without it, a sweep never takes many on its own.
    private func apply(_ days: Int, confirmed: Int? = nil) {
        retentionDays = days
        sweep.sync(enabled: false)
        sweep.sync(enabled: ForkMeetingService.shared.isWanted)
        if days > 0, ForkMeetingService.shared.isWanted { sweep.sweep(confirmed: confirmed) }
    }

    /// Stored with a tilde, like the official folder lists.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = text.folderPanelMessage
        panel.prompt = text.folderPanelPrompt
        let current = ForkMeetingService.root.url
        panel.directoryURL = FileManager.default.fileExists(atPath: current.path)
            ? current : current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = (url.path as NSString).abbreviatingWithTildeInPath
        ForkMeetingService.sync()
    }
}

// MARK: - Advanced

private struct ForkMeetingAdvancedSection: View {
    let text: ForkMeetingStrings

    @AppStorage(ForkDefaultsKey.meetingsConsentReminder) private var consentReminder = true
    @State private var isEditing = false

    var body: some View {
        Section(text.advancedTitle) {
            Toggle(isOn: $consentReminder) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.consentReminder)
                    Text(text.consentReminderCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(text.announcementEdit) { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            ForkMeetingAnnouncementEditor(text: text) { isEditing = false }
        }
    }
}

/// The announcement, edited as a draft: saved only with Done. Emptied, or
/// put back to the default, it follows the language again.
private struct ForkMeetingAnnouncementEditor: View {
    let text: ForkMeetingStrings
    let close: () -> Void

    @AppStorage(ForkDefaultsKey.meetingsAnnouncement) private var announcement = ""
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text.announcementTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(text.announcementCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel(text.announcementTitle)
            HStack {
                Button(text.announcementReset) { draft = text.announcementDefault }
                    .disabled(draft == text.announcementDefault)
                Spacer()
                Button(text.cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(text.done) {
                    announcement = ForkMeetingAnnouncementText.stored(edited: draft, strings: text)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { draft = ForkMeetingAnnouncementText.text(stored: announcement, strings: text) }
    }
}
