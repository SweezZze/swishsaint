// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import SwiftUI

/// An Immich exporter on the Meetings page: the server's address, its API
/// key (typed once, kept in the Keychain, never shown again), the album,
/// and a test of the key.
struct ForkMeetingImmichRow: View {
    let config: ForkMeetingExporterConfig
    let text: ForkMeetingStrings
    let remove: () -> Void

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var exports = ForkMeetingExports.shared
    @State private var address = ""
    @State private var newKey = ""
    @State private var album = ""
    @State private var problem: String?
    @State private var hostChange: String?

    private var immich: ForkImmichStrings { ForkImmichStrings.strings(l10n.language) }
    private var saved: Bool { exports.hasSecret(config) }

    var body: some View {
        ForkMeetingExporterHeader(config: config, text: text)
        Text(immich.caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        LabeledContent(immich.address) {
            TextField(immich.address, text: $address, prompt: Text(verbatim: "https://photos.example.org"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { save(confirmed: false) }
        }
        LabeledContent(immich.key) {
            SecureField(immich.keyNew, text: $newKey, prompt: Text(immich.keyNew))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { save(confirmed: false) }
        }
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let origin = config.origin {
                    Text(text.webhookHost(origin))
                }
                Text(saved ? immich.keySaved : immich.keyMissing)
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
        LabeledContent(immich.album) {
            TextField(immich.album, text: $album, prompt: Text(immich.albumDefault))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveAlbum)
                .onChange(of: album) { _, _ in saveAlbum() }
        }
        Text(immich.albumCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .firstTextBaseline) {
            testResult
            Spacer()
            if exports.testing.contains(config.id) { ProgressView().controlSize(.small) }
            Button(immich.test) { exports.sendTest(config.id) }
                .disabled(!exports.isConfigured(config) || exports.testing.contains(config.id))
        }
        ForkMeetingExporterCommon(config: config, text: text, remove: remove)
            .onAppear {
                address = config.address ?? ""
                // A new exporter starts with the default album; emptied
                // afterwards, it stays empty.
                if config.album == nil {
                    album = immich.albumDefault
                    saveAlbum()
                } else {
                    album = config.album ?? ""
                }
            }
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
            Label(immich.testDone(status), systemImage: "checkmark.circle.fill")
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

    private func saveAlbum() {
        guard let current = exports.config(config.id), current.album != album else { return }
        var next = current
        next.album = album
        exports.update(next)
    }

    private func save(confirmed: Bool) {
        let id = config.id
        exports.saveWebhook(id, address: address, secret: newKey, confirmed: confirmed) { change in
            switch change {
            case .saved:
                problem = nil
                newKey = ""
                address = exports.config(id)?.address ?? address
            case let .confirmHostChange(old):
                hostChange = old
            case let .refused(refusal):
                problem = refusal.message(text)
            case .secretNotSaved:
                problem = text.webhookSecretRefused
                newKey = ""
            case .listUnconfirmed:
                problem = text.exportFailListUnconfirmed
            }
        }
    }
}
