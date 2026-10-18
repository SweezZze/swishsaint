// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import SwiftUI

/// Each fork feature as a page of its own in the Settings sidebar, beside
/// the official pages (seams `settings`, `settings2`, `settings4`). The
/// official `SettingsPage` only learns `.fork(id)`: the ids, the rows and the
/// views live here, so a new feature takes one more row in
/// `SettingsDirectory` and nothing else.
enum ForkSettingsPages {
    /// The page's row in the sidebar and in the Settings and command bar
    /// search (seam `settings4`). Where the row sits in `SettingsDirectory`
    /// picks its sidebar group: a row of no `AppFeature` in the window and
    /// control pages lands under Mouse & Keyboard, one in the utilities stays
    /// under Utilities.
    static func item(_ feature: ForkFeature, language: AppLanguage) -> SettingsDirectoryItem {
        let text = ForkExtrasStrings.strings(language)
        return SettingsDirectoryItem(page: feature.settingsPage, title: feature.title(text),
                                     icon: feature.symbol, keywords: feature.searchKeywords(language))
    }

    /// The page's content (seam `settings2`). An unknown id, from a newer or
    /// an older build, shows nothing rather than a wrong page.
    @ViewBuilder
    static func page(_ id: String) -> some View {
        if let feature = ForkFeature(pageID: id) {
            ForkFeatureSettingsPage(feature: feature)
                .id(feature)
        }
    }

    /// Shows the feature's page in the Settings window.
    static func open(_ feature: ForkFeature) {
        SettingsRouter.shared.request(FeatureSettingsDestination(feature.settingsPage))
    }
}

extension ForkFeature {
    /// Names the page in `SettingsPage.fork`. Stable: never rename one.
    var pageID: String {
        switch self {
        case .trackpadGestures: return "gestures"
        case .dictation: return "dictation"
        }
    }

    init?(pageID: String) {
        guard let feature = Self.allCases.first(where: { $0.pageID == pageID }) else { return nil }
        self = feature
    }

    var settingsPage: SettingsPage { .fork(pageID) }

    /// What a search for the feature may type, in the person's language.
    func searchKeywords(_ language: AppLanguage) -> [String] {
        let text = ForkExtrasStrings.strings(language)
        switch self {
        case .trackpadGestures:
            let gestures = FeatureStrings.forkTrackpadGestures(language)
            return [text.gesturesSummary, gestures.enable, gestures.caption, "trackpad"]
        case .dictation:
            let dictation = ForkDictationStrings.strings(language)
            return [text.dictationSummary, dictation.languageTitle, dictation.vocabularyTitle,
                    dictation.replacementsTitle, dictation.soundsTitle]
        }
    }
}

/// One feature's page: its switch at the top, as on the official pages,
/// Accessibility when it is missing, then the feature's settings.
struct ForkFeatureSettingsPage: View {
    let feature: ForkFeature

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared

    private var text: ForkExtrasStrings { ForkExtrasStrings.strings(l10n.language) }

    var body: some View {
        Form {
            // The gestures' own card already carries their switch.
            if feature != .trackpadGestures {
                Section {
                    ForkFeatureToggle(feature: feature, text: text)
                }
            }

            if feature.needsAccessibility && !permissions.accessibility {
                Section(l10n.s.permissionRequired) {
                    PermissionRow(kind: .accessibility)
                }
            }

            content
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var content: some View {
        switch feature {
        case .trackpadGestures:
            ForkTrackpadSettingsSections(text: FeatureStrings.forkTrackpadGestures(l10n.language),
                                         layoutText: FeatureStrings.windowLayout(l10n.language))
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(text.sharedSettings)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(FeatureStrings.windowLayout(l10n.language).title) {
                        SettingsRouter.shared.request(FeatureSettingsDestination(.windowLayout))
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        case .dictation:
            ForkDictationSettingsSection(title: text.dictationTitle)
        }
    }
}

/// The switch at the top of a feature's page.
struct ForkFeatureToggle: View {
    let feature: ForkFeature
    let text: ForkExtrasStrings
    @AppStorage private var isOn: Bool

    init(feature: ForkFeature, text: ForkExtrasStrings) {
        self.feature = feature
        self.text = text
        _isOn = AppStorage(wrappedValue: false, feature.enabledKey)
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title(text))
                    Text(feature.summary(text))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: feature.symbol)
            }
        }
        .onChange(of: isOn) { _, _ in feature.sync() }
    }
}
