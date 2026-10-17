// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import SwiftUI

/// The fork's page of the Settings (seams `settings`, `settings2`,
/// `settings3`): one switch per fork feature, each feature's own settings,
/// the fork's updates, and what this version is.
struct ForkExtrasSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(ForkDefaultsKey.claudeUsageEnabled) private var claudeUsageEnabled = false
    @AppStorage(ForkDefaultsKey.dictationEnabled) private var dictationEnabled = false

    private var text: ForkExtrasStrings { ForkExtrasStrings.strings(l10n.language) }

    var body: some View {
        Form {
            Section {
                Text(text.intro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(text.featuresSection) {
                ForEach(ForkFeature.allCases) { feature in
                    ForkFeatureToggle(feature: feature, text: text)
                }
            }

            if !permissions.accessibility {
                Section(l10n.s.permissionRequired) {
                    PermissionRow(kind: .accessibility)
                }
            }

            if claudeUsageEnabled {
                ForkClaudeUsageStatus(text: text)
            }

            if dictationEnabled {
                ForkDictationSettingsSection(title: text.dictationTitle)
            }

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

            ForkUpdatesSection()

            Section(text.aboutSection) {
                Text(text.aboutBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Link(text.sourceCode, destination: ForkInfo.repositoryURL)
                    Link(text.officialProject, destination: ForkInfo.officialRepositoryURL)
                    Spacer()
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    /// The page as the sidebar and the search list it (seam `settings3`).
    static func directoryItem(language: AppLanguage) -> SettingsDirectoryItem {
        let text = ForkExtrasStrings.strings(language)
        return SettingsDirectoryItem(page: .extras, title: text.pageTitle, icon: "puzzlepiece.extension",
                                     keywords: ForkFeature.allCases.map { $0.title(text) }
                                        + [FeatureStrings.forkTrackpadGestures(language).enable])
    }
}

private struct ForkFeatureToggle: View {
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

/// The fork's updates: see `ForkUpdateService`.
private struct ForkUpdatesSection: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var updates = ForkUpdateService.shared

    private var text: ForkUpdateStrings { ForkUpdateStrings.strings(l10n.language) }

    var body: some View {
        Section(text.section) {
            Text(text.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(text.currentBuild,
                           value: updates.currentBuild.map { "\($0)" } ?? text.unknownBuild)
            if let upstream = updates.upstreamVersion {
                LabeledContent(text.basedOn, value: upstream)
            }
            status
            HStack {
                Button(text.check) { updates.check() }
                    .disabled(isBusy || updates.repository == nil)
                if case let .available(candidate) = updates.state {
                    Button("\(text.install) (\(candidate.build))") { updates.install(candidate) }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                if let page = updates.releasesPageURL {
                    Button(text.openReleasesPage) { NSWorkspace.shared.open(page) }
                        .buttonStyle(.link)
                }
            }
            if updates.repository == nil {
                Text(text.localBuild)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .checking:
            row(text.checking, system: "arrow.triangle.2.circlepath", tint: .secondary)
        case .upToDate:
            row(text.upToDate, system: "checkmark.circle.fill", tint: .green)
        case let .available(candidate):
            VStack(alignment: .leading, spacing: 4) {
                row("\(text.availableTitle) (\(candidate.build))", system: "arrow.down.circle.fill",
                    tint: .accentColor)
                if !candidate.notes.isEmpty {
                    Text(candidate.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .downloading:
            row(text.downloading, system: "arrow.down.circle", tint: .secondary)
        case .installing:
            row(text.installing, system: "gearshape.2.fill", tint: .secondary)
        case let .failed(message):
            row(message, system: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private func row(_ string: String, system: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system).foregroundStyle(tint)
            Text(string).font(.callout)
            Spacer()
        }
    }

    private var isBusy: Bool {
        switch updates.state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }
}

/// Where the Claude limits read by Claude Code stand.
private struct ForkClaudeUsageStatus: View {
    let text: ForkExtrasStrings
    @ObservedObject private var usage = ForkClaudeUsage.shared
    @Environment(\.locale) private var locale

    var body: some View {
        Section(text.claudeUsageTitle) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(alignment: .top, spacing: 8) {
                    if let reading = usage.lastReading {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(text.claudeUsageStatus(min(reading, context.date)
                            .formatted(.relative(presentation: .named).locale(locale))))
                    } else {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        Text(text.claudeUsageWaiting)
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
