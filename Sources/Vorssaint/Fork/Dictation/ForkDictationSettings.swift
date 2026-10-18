// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze
// Copyright (C) 2026 Martial

import AppKit
import AVFoundation
import Speech
import SwiftUI

/// Dictation's settings on the Extras page: the shortcuts, the engine and its
/// model, the microphone, what happens after, the vocabulary, the
/// permissions. The last failure, when there is one, sits on top with its fix.
struct ForkDictationSettingsSection: View {
    let title: String

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = ForkDictationService.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var store = ForkParakeetModelStore.shared
    @AppStorage(ForkDefaultsKey.dictationEnabled) private var enabled = false
    @AppStorage(ForkDefaultsKey.dictationEngine) private var engineRaw = ForkDictationEngineSetting.fallback.rawValue
    @AppStorage(ForkDefaultsKey.dictationLocale) private var chosenLocale = ""
    @AppStorage(ForkDefaultsKey.dictationShortcuts) private var shortcutsStorage = ""
    @State private var trial = ""

    private var text: ForkDictationStrings { ForkDictationStrings.strings(l10n.language) }

    /// The failure worth a banner. A missing Accessibility is already asked
    /// for at the top of the page.
    private var bannerFailure: ForkDictationFailure? {
        guard let failure = service.lastFailure else { return nil }
        if failure == .accessibilityMissing && !permissions.accessibility { return nil }
        return failure
    }

    var body: some View {
        if let failure = bannerFailure {
            ForkDictationFailureBanner(failure: failure, text: text)
        }

        Section(title) {
            Text(text.howTo)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            status
            LabeledContent(text.tryTitle) {
                TextField("", text: $trial, prompt: Text(text.tryPlaceholder), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            .disabled(!enabled)
        }

        // Until Parakeet is installed, its card comes first: it is what
        // dictation needs next, and its download shows its progress here.
        if ForkParakeetCard.isWanted(store: store, engine: engineRaw) {
            Section {
                ForkParakeetCard(text: text, store: store, isProminent: true)
            }
        }

        // Off, what only matters while dictating is greyed out, like the
        // other Extras pages. The model can still be downloaded beforehand.
        ForkDictationShortcutsSection(text: text)
            .disabled(!enabled)
        ForkDictationRecognitionSection(text: text)
        ForkDictationMicrophoneSection(text: text)
            .disabled(!enabled)
        ForkDictationAfterSection(text: text)
            .disabled(!enabled)
        ForkDictationVocabularySection(text: text)
        ForkDictationPermissionsSection(text: text)
        ForkDictationAdvancedSection(text: text)
    }

    /// At a glance: off, ready with the first shortcut and the engine it
    /// will use, or what keeps that engine from working. A lasting problem
    /// has its own banner above.
    @ViewBuilder
    private var status: some View {
        if !enabled {
            Label(text.stateOff, systemImage: "pause.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if bannerFailure == nil, permissions.accessibility {
            switch readiness {
            case let .success(summary)?:
                Label(text.ready(summary), systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            case let .failure(failure)?:
                Label(failure.summary(text), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
        }
    }

    private var readiness: Result<String, ForkDictationFailure>? {
        _ = store.state
        _ = shortcutsStorage
        let shortcuts = ForkDictationShortcuts.load()
        let problems = ForkDictationShortcutProblems.of(shortcuts)
        guard let first = shortcuts.first(where: { $0.action != .pasteLast && problems[$0.id] == nil }) else { return nil }
        let setting = ForkDictationEngineSetting(rawValue: engineRaw) ?? .fallback
        let language = ForkDictationLanguages.effective(first.language ?? chosenLocale)
        return ForkDictationEngines.shared.kind(for: setting, language: language).map { kind in
            let engine = kind == .parakeet ? text.parakeetTitle : text.engineApple
            return "\(ForkDictationKeyName.name(of: first.key, text: text)) · \(engine)"
        }
    }
}

/// `ForkDictationShortcuts.problems`, kept until the shortcuts change: it
/// asks the window server for the system's shortcuts, and the page redraws
/// many times a second while the model downloads.
private enum ForkDictationShortcutProblems {
    private static var cache: (key: String, problems: [UUID: ForkDictationShortcutProblem])?

    static func of(_ shortcuts: [ForkDictationShortcut]) -> [UUID: ForkDictationShortcutProblem] {
        let key = ForkDictationShortcuts.encode(shortcuts)
        if let cache, cache.key == key { return cache.problems }
        let problems = ForkDictationShortcuts.problems(shortcuts)
        cache = (key, problems)
        return problems
    }

    static func forget() {
        cache = nil
    }
}

/// How a shortcut's key reads on the page.
enum ForkDictationKeyName {
    static func name(of key: ForkDictationShortcut.Key, text: ForkDictationStrings) -> String {
        switch key {
        case let .modifier(trigger):
            return "\(trigger.symbol) \(text.triggerName(trigger))"
        case let .combo(keyCode, modifiers):
            return GlobalShortcut(keyCode: keyCode, modifiers: GlobalShortcutModifiers(rawValue: modifiers)).displayString
        }
    }
}

// MARK: - Failure

/// The last thing that went wrong, said in full, with the button that fixes
/// it when there is one.
private struct ForkDictationFailureBanner: View {
    let failure: ForkDictationFailure
    let text: ForkDictationStrings

    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.summary(text))
                        .fontWeight(.semibold)
                    Text(failure.remedy(text))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let action = failure.action, let label = label(for: action) {
                    Button(label) { ForkDictationService.shared.perform(action) }
                        .controlSize(.small)
                }
                Button {
                    ForkDictationService.shared.clearFailure()
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

    private func label(for action: ForkDictationFailureAction) -> String? {
        switch action {
        case .openAccessibility, .openMicrophonePrivacy, .openSpeechPrivacy: return text.actionOpenSettings
        case .unmuteMicrophone: return l10n.s.micUnmuteName
        case .downloadModel: return text.actionDownload
        case .redownloadModel: return text.actionRedownload
        // Already on the page.
        case .openSettingsPage: return nil
        }
    }
}

// MARK: - Shortcuts

/// Up to six shortcuts, each with its key, gesture, action and language.
/// Every change is saved at once and the key tap reads the new table.
private struct ForkDictationShortcutsSection: View {
    let text: ForkDictationStrings

    @ObservedObject private var superKey = SuperKeyService.shared
    @State private var shortcuts: [ForkDictationShortcut] = ForkDictationShortcuts.load()
    /// Shortcuts switched to a combination that has not been typed yet.
    @State private var pendingCombination: Set<UUID> = []

    private var problems: [UUID: ForkDictationShortcutProblem] { ForkDictationShortcutProblems.of(shortcuts) }

    var body: some View {
        Section(text.shortcutsTitle) {
            Text(text.shortcutsCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(shortcuts) { shortcut in
                ForkDictationShortcutRow(
                    shortcut: binding(for: shortcut.id),
                    text: text,
                    problem: problems[shortcut.id],
                    conflictsWithSuperKey: conflictsWithSuperKey(shortcut),
                    isPendingCombination: pendingCombination.contains(shortcut.id),
                    canRemove: shortcuts.count > 1,
                    chooseCombination: { pendingCombination.insert(shortcut.id) },
                    abandonCombination: { pendingCombination.remove(shortcut.id) },
                    remove: { remove(shortcut.id) })
            }

            if usesFn {
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

            Button {
                add()
            } label: {
                Label(text.shortcutAdd, systemImage: "plus")
            }
            .disabled(shortcuts.count >= ForkDictationShortcut.maximumCount)
        }
        .onAppear {
            // macOS's or Vorssaint's own shortcuts may have changed since.
            ForkDictationShortcutProblems.forget()
            shortcuts = ForkDictationShortcuts.load()
        }
        // A restored backup changes them behind the page's back: show those,
        // and never save the old ones over them.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let stored = ForkDictationShortcuts.load()
            if ForkDictationShortcuts.encode(stored) != ForkDictationShortcuts.encode(shortcuts) {
                shortcuts = stored
                pendingCombination.removeAll()
            }
        }
    }

    private var usesFn: Bool {
        shortcuts.contains { $0.key == .modifier(.fn) }
    }

    private func binding(for id: UUID) -> Binding<ForkDictationShortcut> {
        Binding(
            get: { shortcuts.first { $0.id == id } ?? .default },
            set: { updated in
                guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
                if case .combo = updated.key { pendingCombination.remove(id) }
                if case .modifier = updated.key { pendingCombination.remove(id) }
                shortcuts[index] = updated
                save()
            })
    }

    /// The Super Key remaps its source key in hardware: it stops being a
    /// modifier, so dictation never sees it pressed.
    private func conflictsWithSuperKey(_ shortcut: ForkDictationShortcut) -> Bool {
        guard superKey.isRunning, case let .modifier(trigger) = shortcut.key else { return false }
        return SuperKeySource(rawValue: trigger.rawValue) == superKey.source
    }

    private func add() {
        guard shortcuts.count < ForkDictationShortcut.maximumCount else { return }
        let used = Set(shortcuts.map(\.key))
        let free = ForkDictationTrigger.allCases.first { !used.contains(.modifier($0)) } ?? .rightOption
        shortcuts.append(ForkDictationShortcut(key: .modifier(free)))
        save()
    }

    private func remove(_ id: UUID) {
        guard shortcuts.count > 1 else { return }
        shortcuts.removeAll { $0.id == id }
        pendingCombination.remove(id)
        save()
    }

    private func save() {
        ForkDictationShortcuts.save(shortcuts)
        ForkDictationService.sync()
    }
}

private struct ForkDictationShortcutRow: View {
    @Binding var shortcut: ForkDictationShortcut
    let text: ForkDictationStrings
    let problem: ForkDictationShortcutProblem?
    let conflictsWithSuperKey: Bool
    let isPendingCombination: Bool
    let canRemove: Bool
    let chooseCombination: () -> Void
    let abandonCombination: () -> Void
    let remove: () -> Void

    @ObservedObject private var l10n = L10n.shared

    /// A combination to show in the recorder before one is typed: the
    /// recorder needs one, and `emptyTitle` hides it.
    private static let placeholder = GlobalShortcut(keyCode: 49, modifiers: [.control, .option])

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(text.shortcutKeyTitle)
                Spacer()
                keyMenu
                if let combination {
                    ForkDictationComboRecorder(
                        shortcut: combination,
                        waitingTitle: text.shortcutRecordPrompt,
                        emptyTitle: isPendingCombination ? text.shortcutRecordPrompt : nil,
                        recordsAtOnce: isPendingCombination,
                        recordingEnded: { if isPendingCombination { abandonCombination() } },
                        captureAction: { captured in
                            shortcut.key = .combo(keyCode: captured.keyCode, modifiers: captured.modifiers.rawValue)
                        })
                    .frame(width: 140)
                }
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canRemove)
                .help(text.shortcutRemove)
                .accessibilityLabel(text.shortcutRemove)
            }

            if shortcut.action != .pasteLast {
                Picker(text.shortcutModeTitle, selection: $shortcut.mode) {
                    Text(text.shortcutModeHybrid).tag(ForkDictationShortcut.Mode.hybrid)
                    Text(text.shortcutModeHold).tag(ForkDictationShortcut.Mode.hold)
                    Text(text.shortcutModeToggle).tag(ForkDictationShortcut.Mode.toggle)
                }
                caption(modeCaption)
            }

            Picker(text.shortcutActionTitle, selection: $shortcut.action) {
                Text(text.shortcutActionPaste).tag(ForkDictationShortcut.Action.paste)
                Text(text.shortcutActionCopy).tag(ForkDictationShortcut.Action.copy)
                Text(text.shortcutActionPasteLast).tag(ForkDictationShortcut.Action.pasteLast)
            }

            if shortcut.action != .pasteLast {
                Picker(text.languageTitle, selection: language) {
                    Text(text.shortcutLanguageDefault).tag("")
                    Divider()
                    ForEach(ForkDictationLanguages.names(in: l10n.language), id: \.id) { language in
                        Text(language.name).tag(language.id)
                    }
                }
            }

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var keyMenu: some View {
        Menu {
            ForEach(ForkDictationTrigger.allCases) { trigger in
                Toggle(isOn: Binding(
                    get: { !isPendingCombination && shortcut.key == .modifier(trigger) },
                    set: { _ in shortcut.key = .modifier(trigger) })) {
                    Text(verbatim: "\(trigger.symbol)  \(text.triggerName(trigger))")
                }
            }
            Divider()
            Toggle(text.shortcutCombination, isOn: Binding(
                get: { isPendingCombination || isCombination },
                set: { _ in chooseCombination() }))
        } label: {
            Text(keyTitle)
        }
        .fixedSize()
    }

    private var isCombination: Bool {
        if case .combo = shortcut.key { return true }
        return false
    }

    private var keyTitle: String {
        if isPendingCombination { return text.shortcutCombination }
        switch shortcut.key {
        case let .modifier(trigger): return "\(trigger.symbol)  \(text.triggerName(trigger))"
        case .combo: return text.shortcutCombination
        }
    }

    private var combination: GlobalShortcut? {
        if isPendingCombination { return Self.placeholder }
        guard case let .combo(keyCode, modifiers) = shortcut.key else { return nil }
        return GlobalShortcut(keyCode: keyCode, modifiers: GlobalShortcutModifiers(rawValue: modifiers))
    }

    private var language: Binding<String> {
        Binding(get: { shortcut.language ?? "" },
                set: { shortcut.language = $0.isEmpty ? nil : $0 })
    }

    private var modeCaption: String {
        switch shortcut.mode {
        case .hybrid: return text.shortcutModeHybridCaption
        case .hold: return text.shortcutModeHoldCaption
        case .toggle: return text.shortcutModeToggleCaption
        }
    }

    private var warning: String? {
        switch problem {
        case .duplicate: return text.shortcutProblemDuplicate
        case .needsModifier: return text.shortcutProblemNeedsModifier
        case .reservedKey: return text.shortcutProblemReserved
        case .conflict: return text.shortcutProblemConflict
        case nil: return conflictsWithSuperKey ? text.shortcutConflictSuperKey : nil
        }
    }

    private func caption(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The app's shortcut field, able to start listening as soon as it appears:
/// choosing "Combination…" should not take a second click. Ending without a
/// combination gives the row back its previous key.
private struct ForkDictationComboRecorder: NSViewRepresentable {
    let shortcut: GlobalShortcut
    let waitingTitle: String
    let emptyTitle: String?
    let recordsAtOnce: Bool
    let recordingEnded: () -> Void
    let captureAction: (GlobalShortcut) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.cell?.lineBreakMode = .byTruncatingTail
        button.target = button
        button.action = #selector(RecorderButton.beginRecording)
        apply(to: button)
        if recordsAtOnce {
            // Once the button is in its window: it must become first responder.
            DispatchQueue.main.async { [weak button] in button?.beginRecording() }
        }
        return button
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        apply(to: nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecorderButton, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width, height: intrinsic.height)
    }

    static func dismantleNSView(_ nsView: RecorderButton, coordinator: ()) {
        nsView.recordingChanged = nil
        nsView.stopRecording()
        ForkDictationService.shared.setShortcutRecording(false)
    }

    private func apply(to button: RecorderButton) {
        button.requiresModifier = true
        button.shortcut = shortcut
        button.waitingTitle = waitingTitle
        button.emptyTitle = emptyTitle
        button.recordingChanged = { isRecording in
            // The key tap steps aside at once, so a combination already
            // bound to dictation reaches the recorder.
            ForkDictationService.shared.setShortcutRecording(isRecording)
            if !isRecording { recordingEnded() }
        }
        button.invalidAction = {}
        button.captureAction = captureAction
        button.isEnabled = true
        button.refreshTitle()
    }
}

/// The languages Apple recognizes, named in the app's language. Built once
/// per app language: the list is long and sorting it on every redraw made
/// the page lag.
private enum ForkDictationLanguages {
    private static var cache: (language: AppLanguage, names: [(id: String, name: String)])?

    static func names(in language: AppLanguage) -> [(id: String, name: String)] {
        if let cache, cache.language == language { return cache.names }
        let display = Locale(identifier: language.rawValue)
        let names = ForkAppleSpeechEngine.supportedLanguages
            .map { ($0, display.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
            .map { (id: $0.0, name: $0.1) }
        cache = (language, names)
        return names
    }

    static func name(of identifier: String, in language: AppLanguage) -> String {
        Locale(identifier: language.rawValue).localizedString(forIdentifier: identifier) ?? identifier
    }

    /// The language that picks the engine: the one chosen, else the
    /// person's first language. Parakeet still detects it by itself.
    static func effective(_ chosen: String) -> String {
        chosen.isEmpty ? (Locale.preferredLanguages.first ?? "") : chosen
    }
}

// MARK: - Recognition

/// The engine, Parakeet's model and the language.
private struct ForkDictationRecognitionSection: View {
    let text: ForkDictationStrings

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var store = ForkParakeetModelStore.shared
    @AppStorage(ForkDefaultsKey.dictationEngine) private var engineRaw = ForkDictationEngineSetting.fallback.rawValue
    @AppStorage(ForkDefaultsKey.dictationLocale) private var chosenLocale = ""

    private var setting: ForkDictationEngineSetting {
        ForkDictationEngineSetting(rawValue: engineRaw) ?? .fallback
    }

    /// Re-read on every redraw: the store's state drives it.
    private var engineInUse: Result<ForkDictationEngineKind, ForkDictationFailure> {
        _ = store.state
        return ForkDictationEngines.shared.kind(for: setting, language: ForkDictationLanguages.effective(chosenLocale))
    }

    var body: some View {
        Section(text.recognitionTitle) {
            Picker(text.engineTitle, selection: $engineRaw) {
                Text(text.engineAuto).tag(ForkDictationEngineSetting.auto.rawValue)
                Text(text.engineParakeet).tag(ForkDictationEngineSetting.parakeet.rawValue)
                Text(text.engineApple).tag(ForkDictationEngineSetting.apple.rawValue)
            }
            .onChange(of: engineRaw) { _, _ in ForkDictationService.sync() }
            if setting == .auto {
                caption(text.engineAutoCaption)
            }
            inUse

            if setting != .apple, !ForkParakeetCard.isWanted(store: store, engine: engineRaw) {
                ForkParakeetCard(text: text, store: store)
            }

            Picker(text.languageTitle, selection: $chosenLocale) {
                Text(automaticTitle).tag("")
                Divider()
                ForEach(ForkDictationLanguages.names(in: l10n.language), id: \.id) { language in
                    Text(language.name).tag(language.id)
                }
            }
        }
    }

    @ViewBuilder
    private var inUse: some View {
        switch engineInUse {
        case .success(.parakeet):
            badge(text.engineInUse(text.parakeetTitle), detail: text.onDevice, symbol: "lock.laptopcomputer")
        case .success(.apple):
            let onDevice = ForkAppleSpeechEngine.supportsOnDevice(language: ForkDictationLanguages.effective(chosenLocale))
            badge(text.engineInUse(text.engineApple), detail: onDevice ? text.onDevice : text.onServer,
                  symbol: onDevice ? "lock.laptopcomputer" : "network")
        case let .failure(failure):
            VStack(alignment: .leading, spacing: 2) {
                Label(failure.summary(text), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                caption(failure.remedy(text))
            }
        }
    }

    /// Parakeet finds the language by itself: the automatic choice says so
    /// rather than naming one.
    private var automaticTitle: String {
        if case .success(.parakeet) = engineInUse { return text.languageParakeetAuto }
        let automatic = ForkAppleSpeechEngine.resolvedLanguage("")
            .map { ForkDictationLanguages.name(of: $0, in: l10n.language) } ?? "?"
        return text.languageAutomatic(automatic)
    }

    private func badge(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.callout)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caption(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Parakeet's model: download it (never without a click), follow it, delete it.
private struct ForkParakeetCard: View {
    let text: ForkDictationStrings
    @ObservedObject var store: ForkParakeetModelStore
    /// At the top of the page, while the model is missing: its main button
    /// stands out.
    var isProminent = false

    /// Whether the model is still to install for the engine chosen.
    static func isWanted(store: ForkParakeetModelStore, engine: String) -> Bool {
        guard (ForkDictationEngineSetting(rawValue: engine) ?? .fallback) != .apple else { return false }
        if case .installed = store.state { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(.purple)
                Text(text.parakeetTitle)
                    .fontWeight(.medium)
                Spacer()
                stateControl
            }
            caption(text.parakeetCaption)
            stateDetail
            caption(text.parakeetLanguagesCaption)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                caption(text.parakeetAttribution)
                Spacer(minLength: 0)
                Link(text.licenseLink, destination: Self.modelLicense)
                    .font(.caption)
                Link(text.modelPageLink, destination: Self.modelPage)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var stateControl: some View {
        switch store.state {
        case .notInstalled:
            // A copy already on this Mac installs without downloading anything.
            Button(store.canCloneFromFluidAudioCache
                   ? text.actionInstall
                   : text.parakeetDownload(Self.size(store.totalBytes - store.resumableBytes))) { store.install() }
                .controlSize(isProminent ? .regular : .small)
                .buttonStyle(ProminenceButtonStyle(isProminent: isProminent))
        case .downloading:
            Button(text.parakeetCancel) { store.cancel() }
                .controlSize(.small)
        case .verifying:
            ProgressView()
                .controlSize(.small)
        case let .installed(size):
            HStack(spacing: 8) {
                Label(text.parakeetInstalled(Self.size(size)), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button(text.parakeetDelete, role: .destructive) { store.delete() }
                    .controlSize(.small)
            }
        case .failed:
            Button(text.parakeetRetry) { store.install() }
                .controlSize(isProminent ? .regular : .small)
                .buttonStyle(ProminenceButtonStyle(isProminent: isProminent))
        }
    }

    @ViewBuilder
    private var stateDetail: some View {
        switch store.state {
        case .notInstalled:
            if store.canCloneFromFluidAudioCache {
                caption(text.parakeetCloneCaption)
            }
        case let .downloading(progress, _, _):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                caption(text.parakeetDownloading(progress.formatted(.percent.precision(.fractionLength(0)))))
            }
        case .verifying:
            caption(text.parakeetVerifying)
        case .installed:
            EmptyView()
        case let .failed(error):
            Label(message(for: error), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func message(for error: ForkParakeetStoreError) -> String {
        switch error {
        case .network, .cancelled: return text.storeNetworkError
        case let .diskFull(needed): return text.storeDiskFull(Self.size(needed))
        case .checksum: return text.storeChecksumError
        case .io: return text.storeIOError
        }
    }

    private static let modelLicense = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    private static let modelPage = URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func caption(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Microphone

private struct ForkDictationMicrophoneSection: View {
    let text: ForkDictationStrings

    @AppStorage(ForkDefaultsKey.dictationMicrophone)
    private var microphone = ForkDictationAudioDevices.builtInChoice
    @State private var devices: [ForkDictationAudioDevice] = []

    var body: some View {
        Section(text.microphoneTitle) {
            Picker(text.microphoneTitle, selection: $microphone) {
                Text(text.microphoneBuiltIn).tag(ForkDictationAudioDevices.builtInChoice)
                Text(text.microphoneSystem).tag(ForkDictationAudioDevices.systemChoice)
                Divider()
                ForEach(devices.filter { !$0.isBuiltIn }) { device in
                    Text(device.name).tag(device.id)
                }
                if isMissing {
                    Text(text.microphoneMissing(ForkDictationMicrophoneNames.known[microphone] ?? microphone))
                        .tag(microphone)
                }
            }
            Text(text.microphoneCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in reload() }
    }

    /// A microphone chosen earlier and unplugged since: still shown, so the
    /// choice is not silently lost.
    private var isMissing: Bool {
        microphone != ForkDictationAudioDevices.builtInChoice
            && microphone != ForkDictationAudioDevices.systemChoice
            && !devices.contains { $0.id == microphone && !$0.isBuiltIn }
    }

    private func reload() {
        devices = ForkDictationAudioDevices.inputs()
        for device in devices { ForkDictationMicrophoneNames.known[device.id] = device.name }
    }
}

/// The names of the microphones seen since launch: one chosen and then
/// unplugged keeps its name in the menu rather than a raw identifier.
private enum ForkDictationMicrophoneNames {
    static var known: [String: String] = [:]
}

// MARK: - After dictation

private struct ForkDictationAfterSection: View {
    let text: ForkDictationStrings

    @AppStorage(ForkDefaultsKey.dictationAddsToHistory) private var addsToHistory = true
    @AppStorage(ForkDefaultsKey.dictationSounds) private var sounds = true
    @AppStorage(ForkDefaultsKey.dictationFeedback) private var feedback = ForkDictationFeedbackSetting.auto.rawValue
    @AppStorage(ForkDefaultsKey.dictationStopsOnSilence) private var stopsOnSilence = true
    @AppStorage(DefaultsKey.clipboardHistoryEnabled) private var clipboardHistoryEnabled = false

    private var historyIsOn: Bool {
        clipboardHistoryEnabled && AppFeature.clipboardHistory.isAvailable
    }

    var body: some View {
        Section(text.afterTitle) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(text.addsToHistoryTitle, isOn: $addsToHistory)
                    .disabled(!historyIsOn)
                if historyIsOn {
                    caption(text.addsToHistoryCaption)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        caption(text.historyOffCaption)
                        Spacer()
                        Button(text.actionOpenSettings) {
                            SettingsRouter.shared.request(AppFeature.clipboardHistory.settingsDestination)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }

            Toggle(text.soundsTitle, isOn: $sounds)

            Picker(text.feedbackTitle, selection: $feedback) {
                Text(text.feedbackAuto).tag(ForkDictationFeedbackSetting.auto.rawValue)
                Text(text.feedbackIsland).tag(ForkDictationFeedbackSetting.island.rawValue)
                Text(text.feedbackBubble).tag(ForkDictationFeedbackSetting.bubble.rawValue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(text.stopsOnSilenceTitle, isOn: $stopsOnSilence)
                caption(text.stopsOnSilenceCaption)
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

// MARK: - Vocabulary

/// The person's words and replacements, like a dictation app's dictionary:
/// words favored by Apple's recognizer, and fixes for what either engine
/// keeps mishearing.
private struct ForkDictationVocabularySection: View {
    let text: ForkDictationStrings

    @AppStorage(ForkDefaultsKey.dictationVocabulary) private var vocabularyStorage = ""
    @AppStorage(ForkDefaultsKey.dictationReplacements) private var replacementsStorage = ""
    @AppStorage(ForkDefaultsKey.dictationEngine) private var engineRaw = ForkDictationEngineSetting.fallback.rawValue
    @State private var newWord = ""
    @State private var newHeard = ""
    @State private var newWritten = ""

    private var words: [String] { ForkDictationSupport.vocabulary(from: vocabularyStorage) }
    private var replacements: [ForkDictationSupport.Replacement] {
        ForkDictationSupport.replacements(from: replacementsStorage)
    }

    private var wordIsDuplicate: Bool {
        let word = newWord.trimmingCharacters(in: .whitespaces).lowercased()
        return !word.isEmpty && words.contains { $0.lowercased() == word }
    }

    private var heardIsDuplicate: Bool {
        let heard = newHeard.trimmingCharacters(in: .whitespaces).lowercased()
        return !heard.isEmpty && replacements.contains { $0.heard.lowercased() == heard }
    }

    var body: some View {
        Section(text.vocabularyTitle) {
            caption(text.vocabularyCaption)
            if engineRaw != ForkDictationEngineSetting.apple.rawValue {
                caption(text.vocabularyAppleOnlyCaption)
            }
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
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty || wordIsDuplicate
                              || words.count >= ForkDictationSupport.vocabularyLimit)
            }
            if wordIsDuplicate {
                caption(text.duplicateCaption)
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
            // Adding it again replaces what it was written as.
            if heardIsDuplicate {
                caption(text.duplicateCaption)
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
        guard !word.isEmpty, !wordIsDuplicate else { return }
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

// MARK: - Permissions

private struct ForkDictationPermissionsSection: View {
    let text: ForkDictationStrings

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var secureInput = SecureInputMonitor.shared
    @ObservedObject private var store = ForkParakeetModelStore.shared
    @AppStorage(ForkDefaultsKey.dictationEngine) private var engineRaw = ForkDictationEngineSetting.fallback.rawValue
    @AppStorage(ForkDefaultsKey.dictationLocale) private var chosenLocale = ""
    @AppStorage(ForkDefaultsKey.dictationShortcuts) private var shortcutsStorage = ""
    @State private var speechAuthorization = ForkAppleSpeechEngine.authorization
    @State private var secureInputDemand = UUID()

    /// Apple's permission matters only when Apple will really transcribe:
    /// chosen, or taking over for a language Parakeet does not know, for
    /// the dictation's language or any shortcut's own.
    private var appleMayServe: Bool {
        _ = store.state
        _ = shortcutsStorage
        let setting = ForkDictationEngineSetting(rawValue: engineRaw) ?? .fallback
        if setting == .apple { return true }
        let languages = [chosenLocale] + ForkDictationShortcuts.load().compactMap(\.language)
        return languages.contains { language in
            let kind = ForkDictationEngines.shared.kind(for: setting, language: ForkDictationLanguages.effective(language))
            return (try? kind.get()) == .apple
        }
    }

    var body: some View {
        Section(text.permissionsTitle) {
            PermissionRow(kind: .microphone)
            // When it is missing, the page asks for it at the top already.
            if permissions.accessibility {
                PermissionRow(kind: .accessibility)
            }
            if appleMayServe {
                speechPermission
            }
            if secureInput.holder != .off {
                Text(text.secureInputTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureInputRow()
            }
        }
        .onAppear {
            speechAuthorization = ForkAppleSpeechEngine.authorization
            SecureInputMonitor.shared.setObservingSurface(secureInputDemand, visible: true)
        }
        .onDisappear { SecureInputMonitor.shared.setObservingSurface(secureInputDemand, visible: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            speechAuthorization = ForkAppleSpeechEngine.authorization
        }
    }

    @ViewBuilder
    private var speechPermission: some View {
        let granted = speechAuthorization == .authorized
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
                if ForkAppleSpeechEngine.canAskForSpeechRecognition {
                    HStack(spacing: 8) {
                        if speechAuthorization == .notDetermined {
                            Button(l10n.s.permissionRequest) {
                                ForkAppleSpeechEngine.requestAuthorization { speechAuthorization = $0 }
                            }
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

// MARK: - Advanced

private struct ForkDictationAdvancedSection: View {
    let text: ForkDictationStrings

    @AppStorage(ForkDefaultsKey.dictationUnloadMinutes) private var unloadMinutes = 5
    @State private var isExpanded = false

    private static let fluidAudioLicense = URL(string: "https://github.com/FluidInference/FluidAudio/blob/main/LICENSE")!

    var body: some View {
        Section {
            DisclosureGroup(text.advancedTitle, isExpanded: $isExpanded) {
                Stepper(value: $unloadMinutes, in: 1...30) {
                    Text(text.unloadMinutes(unloadMinutes))
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(text.fluidAudioAttribution)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Link(text.licenseLink, destination: Self.fluidAudioLicense)
                        .font(.caption)
                }
            }
        }
    }
}

/// `.borderedProminent` when it stands out, the default style otherwise.
private struct ProminenceButtonStyle: PrimitiveButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        if isProminent {
            Button(configuration).buttonStyle(.borderedProminent)
        } else {
            Button(configuration).buttonStyle(.automatic)
        }
    }
}
