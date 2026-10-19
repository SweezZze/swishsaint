// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

/// The Meetings page's Exports: empty until the person adds an exporter,
/// then one block per exporter. Says what leaves the Mac, and where.
struct ForkMeetingExportsSection: View {
    let text: ForkMeetingStrings

    @ObservedObject private var exports = ForkMeetingExports.shared
    @State private var removing: ForkMeetingExporterConfig?

    var body: some View {
        Section {
            Text(text.exportsCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(exports.configs) { config in
                switch config.kind {
                case .dropFolder:
                    ForkMeetingDropFolderRow(config: config, text: text) { removing = config }
                case .webhook:
                    ForkMeetingWebhookRow(config: config, text: text) { removing = config }
                }
            }
            HStack {
                Spacer()
                Menu(text.exportsAdd) {
                    ForEach(ForkMeetingExportKind.allCases, id: \.self) { kind in
                        Button(kind.name(text)) { exports.add(kind) }
                    }
                }
                .fixedSize()
            }
        } header: {
            Text(text.exportsTitle)
        }
        .alert(text.exportRemoveTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(text.exportRemove, role: .destructive) {
                if let removing { exports.remove(removing.id) }
                removing = nil
            }
            Button(text.cancel, role: .cancel) { removing = nil }
        } message: {
            Text(text.exportRemoveMessage)
        }
    }
}

/// The settings every exporter has: when it sends, the Meet code, remove.
private struct ForkMeetingExporterCommon: View {
    let config: ForkMeetingExporterConfig
    let text: ForkMeetingStrings
    let remove: () -> Void

    @ObservedObject private var exports = ForkMeetingExports.shared

    var body: some View {
        Picker(selection: Binding(get: { config.mode }, set: { mode in
            var next = config
            next.mode = mode
            exports.update(next)
        })) {
            Text(text.exportModeManual).tag(ForkMeetingExportMode.manual)
            Text(text.exportModeAutomatic).tag(ForkMeetingExportMode.automatic)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(text.exportMode)
                Text(text.exportModeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Toggle(isOn: Binding(get: { config.includesMeetCode }, set: { on in
            var next = config
            next.includesMeetCode = on
            exports.update(next)
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text.exportIncludeMeetCode)
                Text(text.exportIncludeMeetCodeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack {
            Spacer()
            Button(text.exportRemove, role: .destructive, action: remove)
        }
    }
}

private struct ForkMeetingExporterHeader: View {
    let config: ForkMeetingExporterConfig
    let text: ForkMeetingStrings

    var body: some View {
        Label(config.kind.name(text), systemImage: config.kind == .dropFolder ? "folder" : "network")
            .font(.headline)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Drop folder

private struct ForkMeetingDropFolderRow: View {
    let config: ForkMeetingExporterConfig
    let text: ForkMeetingStrings
    let remove: () -> Void

    @ObservedObject private var exports = ForkMeetingExports.shared
    @State private var refused = false

    var body: some View {
        ForkMeetingExporterHeader(config: config, text: text)
        Text(text.dropFolderCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        LabeledContent(text.folderTitle) {
            HStack {
                Text(config.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? text.dropFolderNone)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(config.folder == nil ? .secondary : .primary)
                    .help(config.folder ?? "")
                    .textSelection(.enabled)
                Button(text.dropFolderChoose, action: choose)
            }
        }
        if refused {
            Text(text.dropFolderInsideLibrary)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForkMeetingExporterCommon(config: config, text: text, remove: remove)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = text.dropFolderPanelMessage
        panel.prompt = text.folderPanelPrompt
        if let folder = config.folder { panel.directoryURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !ForkDropFolderExporter.isInsideLibrary(url, libraryRoot: ForkMeetingStore.shared.root()) else {
            refused = true
            return
        }
        refused = false
        var next = config
        next.folder = (url.path as NSString).abbreviatingWithTildeInPath
        exports.update(next)
    }
}

// MARK: - Webhook

private struct ForkMeetingWebhookRow: View {
    let config: ForkMeetingExporterConfig
    let text: ForkMeetingStrings
    let remove: () -> Void

    @ObservedObject private var exports = ForkMeetingExports.shared
    @State private var address = ""
    /// Typed once, written to the Keychain at Save, then emptied: never
    /// read back, never shown.
    @State private var newSecret = ""
    @State private var problem: String?
    @State private var hostChange: String?
    @State private var helpShown = false

    private var saved: Bool { exports.hasSecret(config) }

    var body: some View {
        ForkMeetingExporterHeader(config: config, text: text)
        LabeledContent(text.webhookAddress) {
            TextField(text.webhookAddress, text: $address, prompt: Text(verbatim: "https://"))
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { save(confirmed: false) }
                .accessibilityLabel(text.webhookAddress)
        }
        LabeledContent(text.webhookSecret) {
            SecureField(text.webhookSecretNew, text: $newSecret, prompt: Text(text.webhookSecretNew))
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save(confirmed: false) }
                .accessibilityLabel(text.webhookSecretNew)
        }
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let origin = config.origin {
                    Text(text.webhookHost(origin))
                }
                Text(saved ? text.webhookSecretSaved : text.webhookSecretMissing)
                    .foregroundStyle(saved ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(text.webhookSave) { save(confirmed: false) }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let problem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .firstTextBaseline) {
            testResult
            Spacer()
            if exports.testing.contains(config.id) { ProgressView().controlSize(.small) }
            Button(text.webhookTest) { exports.sendTest(config.id) }
                .disabled(!exports.isConfigured(config) || exports.testing.contains(config.id))
        }
        DisclosureGroup(text.webhookHelpTitle, isExpanded: $helpShown) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text.webhookHelpCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ForkWebhookPayload.verificationExample)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                HStack {
                    Spacer()
                    Button(text.webhookHelpCopy) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ForkWebhookPayload.verificationExample, forType: .string)
                    }
                }
            }
        }
        ForkMeetingExporterCommon(config: config, text: text, remove: remove)
            .onAppear { address = config.address ?? "" }
            .alert(text.webhookHostChangeTitle, isPresented: Binding(get: { hostChange != nil }, set: { if !$0 { hostChange = nil } })) {
                Button(text.webhookHostChangeConfirm, role: .destructive) {
                    hostChange = nil
                    save(confirmed: true)
                }
                Button(text.cancel, role: .cancel) { hostChange = nil }
            } message: {
                if let hostChange { Text(text.webhookHostChange(hostChange)) }
            }
    }

    @ViewBuilder private var testResult: some View {
        switch exports.tests[config.id] {
        case let .success(status)?:
            Label(text.webhookTestDone(status), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failure(failure)?:
            Label(failure.message(text), systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    private func save(confirmed: Bool) {
        switch exports.saveWebhook(config.id, address: address, secret: newSecret, confirmed: confirmed) {
        case .saved:
            problem = nil
            newSecret = ""
            address = exports.config(config.id)?.address ?? address
        case let .confirmHostChange(old):
            hostChange = old
        case let .refused(refusal):
            problem = refusal.message(text)
        case .secretNotSaved:
            problem = text.webhookSecretMissing
            newSecret = ""
        }
    }
}
