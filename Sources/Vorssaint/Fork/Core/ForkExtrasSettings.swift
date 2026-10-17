// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import SwiftUI

/// The fork's page of the Settings (seams `settings`, `settings2`,
/// `settings3`): the list of fork features, each with its switch, the
/// fork's updates, and what this version is. Each feature's own settings
/// open on a page of their own, the way System Settings opens a row, so
/// the list stays short however many features join it.
struct ForkExtrasSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var openFeature: ForkFeature?

    private var text: ForkExtrasStrings { ForkExtrasStrings.strings(l10n.language) }

    var body: some View {
        Group {
            if let feature = openFeature {
                ForkFeaturePage(feature: feature, text: text) {
                    withAnimation(.easeInOut(duration: 0.18)) { openFeature = nil }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                overview
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: openFeature)
    }

    private var overview: some View {
        Form {
            Section {
                Text(text.intro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(text.featuresSection) {
                ForEach(ForkFeature.allCases) { feature in
                    ForkFeatureRow(feature: feature, text: text) {
                        withAnimation(.easeInOut(duration: 0.18)) { openFeature = feature }
                    }
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

/// A feature in the list: its switch, and a click anywhere else on the row
/// opens its page.
private struct ForkFeatureRow: View {
    let feature: ForkFeature
    let text: ForkExtrasStrings
    let open: () -> Void
    @AppStorage private var isOn: Bool

    init(feature: ForkFeature, text: ForkExtrasStrings, open: @escaping () -> Void) {
        self.feature = feature
        self.text = text
        self.open = open
        _isOn = AppStorage(wrappedValue: false, feature.enabledKey)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 10) {
                    ForkFeatureIcon(feature: feature)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title(text))
                        Text(feature.summary(text))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: isOn) { _, _ in feature.sync() }
            Button(action: open) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(feature.title(text))
        }
    }
}

/// The feature's symbol on a small tinted tile, like System Settings.
private struct ForkFeatureIcon: View {
    let feature: ForkFeature

    var body: some View {
        Image(systemName: feature.symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(feature.tint.gradient))
    }
}

/// One feature's own page: a way back to the list, then its settings.
private struct ForkFeaturePage: View {
    let feature: ForkFeature
    let text: ForkExtrasStrings
    let back: () -> Void

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(ForkDefaultsKey.claudeUsageEnabled) private var claudeUsageEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) {
                    Label(text.pageTitle, systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Form {
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
        case .claudeUsage:
            if claudeUsageEnabled {
                ForkClaudeUsageStatus(text: text)
            }
        case .dictation:
            ForkDictationSettingsSection(title: text.dictationTitle)
        }
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
