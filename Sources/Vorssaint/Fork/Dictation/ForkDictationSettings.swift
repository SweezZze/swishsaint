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

        ForkDictationVocabularySection(text: text)
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

/// The person's words and replacements, like a dictation app's dictionary:
/// words favored by the recognizer, and fixes for what it keeps mishearing.
private struct ForkDictationVocabularySection: View {
    let text: ForkDictationStrings

    @AppStorage(ForkDefaultsKey.dictationVocabulary) private var vocabularyStorage = ""
    @AppStorage(ForkDefaultsKey.dictationReplacements) private var replacementsStorage = ""
    @State private var newWord = ""
    @State private var newHeard = ""
    @State private var newWritten = ""

    private var words: [String] { ForkDictationSupport.vocabulary(from: vocabularyStorage) }
    private var replacements: [ForkDictationSupport.Replacement] {
        ForkDictationSupport.replacements(from: replacementsStorage)
    }

    var body: some View {
        Section(text.vocabularyTitle) {
            caption(text.vocabularyCaption)
            ForEach(words, id: \.self) { word in
                HStack {
                    Text(word)
                    Spacer()
                    removeButton { remove(word: word) }
                }
            }
            HStack {
                TextField("", text: $newWord, prompt: Text(text.vocabularyPlaceholder))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWord)
                Button(text.addButton, action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty
                              || words.count >= ForkDictationSupport.vocabularyLimit)
            }
        }

        Section(text.replacementsTitle) {
            caption(text.replacementsCaption)
            ForEach(replacements, id: \.self) { replacement in
                HStack(spacing: 8) {
                    Text(replacement.heard)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(replacement.written)
                    Spacer()
                    removeButton { remove(replacement) }
                }
            }
            HStack(spacing: 8) {
                TextField("", text: $newHeard, prompt: Text(text.heardPlaceholder))
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("", text: $newWritten, prompt: Text(text.writtenPlaceholder))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addReplacement)
                Button(text.addButton, action: addReplacement)
                    .disabled(newHeard.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func caption(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        vocabularyStorage = ForkDictationSupport.storedVocabulary(words + [word])
        newWord = ""
    }

    private func remove(word: String) {
        vocabularyStorage = ForkDictationSupport.storedVocabulary(words.filter { $0 != word })
    }

    private func addReplacement() {
        let heard = newHeard.trimmingCharacters(in: .whitespaces)
        guard !heard.isEmpty else { return }
        let others = replacements.filter { $0.heard.lowercased() != heard.lowercased() }
        let added = ForkDictationSupport.Replacement(heard: heard,
                                                     written: newWritten.trimmingCharacters(in: .whitespaces))
        replacementsStorage = ForkDictationSupport.storedReplacements(others + [added])
        newHeard = ""
        newWritten = ""
    }

    private func remove(_ replacement: ForkDictationSupport.Replacement) {
        replacementsStorage = ForkDictationSupport.storedReplacements(replacements.filter { $0 != replacement })
    }
}
