// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import Speech
import SwiftUI

/// Dictation's settings on the Extras page, shown while it is on.
struct ForkDictationSettingsSection: View {
    let title: String

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = ForkDictationService.shared
    @AppStorage(ForkDefaultsKey.dictationTrigger)
    private var triggerRaw = ForkDictationTrigger.fallback.rawValue
    @AppStorage(ForkDefaultsKey.dictationLocale) private var chosenLocale = ""
    @AppStorage(ForkDefaultsKey.dictationSounds) private var sounds = true
    @State private var trial = ""

    private var text: ForkDictationStrings { ForkDictationStrings.strings(l10n.language) }

    /// The languages the recognizer knows, by name in the app's language.
    private var languages: [(id: String, name: String)] {
        let display = Locale(identifier: l10n.language.rawValue)
        return SFSpeechRecognizer.supportedLocales()
            .map { ForkDictationSupport.normalized($0.identifier) }
            .map { ($0, display.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var automaticName: String {
        let automatic = ForkDictationSupport.localeIdentifier(
            chosen: "", supported: SFSpeechRecognizer.supportedLocales().map(\.identifier),
            preferred: Locale.preferredLanguages)
        let display = Locale(identifier: l10n.language.rawValue)
        return automatic.flatMap { display.localizedString(forIdentifier: $0) } ?? "?"
    }

    var body: some View {
        Section(title) {
            Text(text.howTo)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(text.triggerTitle, selection: $triggerRaw) {
                ForEach(ForkDictationTrigger.allCases) { trigger in
                    Text("\(trigger.symbol)  \(text.triggerName(trigger))").tag(trigger.rawValue)
                }
            }
            .onChange(of: triggerRaw) { _, _ in ForkDictationService.sync() }

            if triggerRaw == ForkDictationTrigger.fn.rawValue {
                HStack(alignment: .firstTextBaseline) {
                    Text(text.fnCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(text.openKeyboardSettings) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Picker(text.languageTitle, selection: $chosenLocale) {
                Text(text.languageAutomatic(automaticName)).tag("")
                Divider()
                ForEach(languages, id: \.id) { language in
                    Text(language.name).tag(language.id)
                }
            }
            if let localeID = ForkDictationService.localeID {
                let onDevice = ForkDictationRecorder.runsOnDevice(localeID: localeID)
                Label(onDevice ? text.onDevice : text.onServer,
                      systemImage: onDevice ? "lock.laptopcomputer" : "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(text.soundsTitle, isOn: $sounds)

            PermissionRow(kind: .microphone)
            speechPermission

            LabeledContent(text.tryTitle) {
                TextField("", text: $trial, prompt: Text(text.tryPlaceholder), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .onAppear { service.refreshAuthorization() }
    }

    @ViewBuilder
    private var speechPermission: some View {
        let granted = service.speechAuthorization == .authorized
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Text(text.speechPermissionName)
                Spacer()
                Text(granted ? l10n.s.permissionGranted : l10n.s.permissionMissing)
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .orange)
            }
            if !granted {
                if ForkDictationService.canAskForSpeechRecognition {
                    HStack(spacing: 8) {
                        if service.speechAuthorization == .notDetermined {
                            Button(l10n.s.permissionRequest) { service.requestSpeechRecognition() }
                        }
                        Button(l10n.s.permissionOpenSettings) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .controlSize(.small)
                } else {
                    Text(text.buildCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
