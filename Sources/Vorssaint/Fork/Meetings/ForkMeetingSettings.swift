// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation
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
        ForkMeetingShortcutSection(text: text)
            .disabled(!enabled)
        ForkMeetingCaptureSection(text: text)
            .disabled(!enabled)
        ForkMeetingLibrarySection(text: text)
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
            Text(text.pageHowTo)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
/// it: the row says so, opens the right pane, and turns orange once a
/// recording found that sound silent.
struct ForkMeetingSystemAudioRow: View {
    let text: ForkMeetingStrings

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = ForkMeetingService.shared

    private var failing: Bool { service.lastFailure == .systemAudioUnavailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: failing ? "exclamationmark.circle.fill" : "questionmark.circle")
                    .foregroundStyle(failing ? Color.orange : Color.secondary)
                    .accessibilityHidden(true)
                Text(text.systemAudioName)
                Spacer()
                Text(failing ? l10n.s.permissionMissing : text.systemAudioUnknown)
                    .font(.caption)
                    .foregroundStyle(failing ? Color.orange : Color.secondary)
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

/// The window in front or its whole display, with what each means for a
/// recording started by hand (no meeting is detected yet).
struct ForkMeetingPicturePicker: View {
    let text: ForkMeetingStrings
    @Binding var target: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(text.pictureTitle, selection: $target) {
                Text(text.pictureFrontWindow).tag(ForkMeetingCaptureTarget.window.rawValue)
                Text(text.pictureFrontDisplay).tag(ForkMeetingCaptureTarget.display.rawValue)
            }
            .pickerStyle(.radioGroup)
            Text(ForkMeetingCaptureTarget(stored: target) == .window ? text.pictureFrontWindowCaption
                    : text.pictureDisplayCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            caption(qualityCaption)
        }
    }

    private var soundCaption: String? {
        switch ForkMeetingSystemAudio(stored: sound) {
        case .app: return text.soundAppCaption
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
        }
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
