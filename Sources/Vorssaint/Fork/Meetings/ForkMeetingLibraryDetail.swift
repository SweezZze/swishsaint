// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import AVKit
import SwiftUI

/// The right of the Meetings window: the selected meeting, its player, its
/// facts, its notes and its actions.
///
/// The title and the notes are drafts of this view: typed, they are saved
/// within half a second (`ForkMeetingEditCoalescer`); the folder takes the
/// title only with Return, or when the field is left. A meeting being
/// written, or whose `meeting.json` this version may not rewrite, shows its
/// fields read only. The view is kept by the meeting's id
/// (`ForkMeetingLibraryEntry.identity`): a rename changes its folder's name
/// under it, never its fields, its focus or its player.
struct ForkMeetingLibraryDetail: View {
    @ObservedObject var model: ForkMeetingLibraryModel
    let entry: ForkMeetingLibraryEntry
    let text: ForkMeetingStrings
    let language: AppLanguage

    @State private var title: String
    @State private var notes: String
    /// Typed since the last commit: only then is the folder renamed.
    @State private var titleTyped = false
    @FocusState private var titleFocused: Bool

    init(model: ForkMeetingLibraryModel, entry: ForkMeetingLibraryEntry, text: ForkMeetingStrings,
         language: AppLanguage) {
        self.model = model
        self.entry = entry
        self.text = text
        self.language = language
        _title = State(initialValue: entry.title ?? "")
        _notes = State(initialValue: entry.notes)
    }

    private var editable: Bool { model.isEditable(entry) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let banner { banner }
                // As wide as the detail, low enough to leave the facts, the
                // notes and the buttons in sight in a window of the default
                // size; the player fits the picture inside.
                ForkMeetingLibraryPlayer(url: model.playableURL(entry), placeholder: text.playerNoVideo)
                    .frame(maxWidth: .infinity)
                    .frame(height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                facts
                ForkMeetingExportStatus(folder: model.folderURL(entry), live: model.isLive(entry), text: text, language: language)
                notesField
                ForkMeetingTranscriptRow(model: model, entry: entry, text: text)
                actions
            }
            .padding(20)
        }
        .onDisappear { commitTitle() }
        .onChange(of: model.titleFocus) { _, _ in titleFocused = true }
        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
    }

    // MARK: - Title

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField(text.untitledMeeting, text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($titleFocused)
                    .disabled(!editable)
                    .onSubmit { commitTitle() }
                    .onChange(of: title) { _, value in
                        guard editable else { return }
                        titleTyped = true
                        model.typedTitle(value, in: entry.folderName)
                    }
                    .accessibilityLabel(text.columnTitle)
                menu
            }
            if let date = entry.date {
                Text(ForkMeetingLibraryText.longDate(date, language: language, calendar: model.calendar))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Also with nothing typed when the folder lags behind the title
    /// already saved.
    private func commitTitle() {
        guard editable, titleTyped || model.catchUpFolder(entry) else { return }
        titleTyped = false
        model.commitTitle(title, of: entry)
    }

    private var menu: some View {
        Menu {
            Button(text.actionRename) { model.focusTitle() }
                .disabled(!editable)
            Button(text.actionExportAudio) { model.exportAudio(entry, from: NSApp.keyWindow) }
                .disabled(model.isLive(entry) || (entry.audio == nil && entry.playable == nil))
            ForkMeetingExportMenu(folder: model.folderURL(entry), live: model.isLive(entry), text: text)
            Button(text.actionCopyPath) { model.copyPath(entry) }
            Divider()
            Button(text.actionTrash) { model.askTrash(entry) }
                .disabled(model.isLive(entry))
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(text.actionMore)
        .accessibilityLabel(text.actionMore)
    }

    // MARK: - Status

    /// What a flagged, unfinished or read-only meeting is, in full.
    private var banner: AnyView? {
        let lines: (String, String)?
        switch entry.status {
        case .complete:
            lines = entry.isReadOnly ? (entry.isForeign ? text.statusForeign : text.statusLaterVersion, "") : nil
        case .recovered:
            lines = (text.statusRecovered, text.statusRecoveredHelp)
        case let .interrupted(cause):
            lines = (text.statusInterrupted(ForkMeetingLibrary.causeText(cause, strings: text)), text.statusInterruptedHelp)
        case .unreadable:
            lines = (text.statusUnreadable, text.statusUnreadableHelp)
        case .recording:
            lines = (text.stateRecording, text.refusedWhileRecording)
        case .finalizing:
            lines = (text.pillFinalizing, text.refusedWhileRecording)
        }
        guard let lines else { return nil }
        let flagged = entry.status.isFlagged
        return AnyView(
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: flagged ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(flagged ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(lines.0).fontWeight(.semibold)
                    if !lines.1.isEmpty {
                        Text(lines.1)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .accessibilityElement(children: .combine)
        )
    }

    // MARK: - Facts

    private var facts: some View {
        let items: [(String, String)] = [
            (text.columnDuration, ForkMeetingLibraryText.duration(entry.seconds, language: language)),
            (text.columnSize, entry.bytes.flatMap { $0 > 0 ? ForkMeetingLiveText.size($0, language: language) : nil }),
            (text.columnApp, ForkMeetingLibraryText.providerName(entry.provider)),
            (text.columnMeetCode, entry.meetCode),
        ].compactMap { label, value in value.map { (label, $0) } }
        return HStack(spacing: 8) {
            ForEach(items, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(value)
                        .font(.body.monospacedDigit())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Notes

    private var notesField: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .disabled(!editable)
                .onChange(of: notes) { _, value in
                    guard editable else { return }
                    model.typedNotes(value, in: entry.folderName)
                }
                .accessibilityLabel(text.notesPlaceholder)
            if notes.isEmpty {
                Text(text.notesPlaceholder)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 90)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(text.actionShow) { model.showInFinder(entry) }
                Button(text.actionTrim) { model.trim(entry) }
                    .disabled(model.isLive(entry) || entry.playable == nil)
                    .help(text.trimCaption)
                Spacer()
                if model.working.contains(entry.folderName) {
                    ProgressView().controlSize(.small)
                }
            }
            if let note = model.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The system's player, on the meeting's file. Paused when the meeting
/// changes or the window goes; a file that does not open shows what the
/// player would be.
struct ForkMeetingLibraryPlayer: NSViewRepresentable {
    let url: URL?
    let placeholder: String

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let player = AVPlayerView()
        player.controlsStyle = .inline
        player.showsFullScreenToggleButton = true
        player.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(player)
        let label = NSTextField(labelWithString: placeholder)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            player.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            player.topAnchor.constraint(equalTo: container.topAnchor),
            player.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        context.coordinator.player = player
        context.coordinator.label = label
        load(context.coordinator)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.label?.stringValue = placeholder
        guard context.coordinator.url != url else { return }
        // The same file under a new name (the meeting renamed): the player
        // goes on where it was.
        if let url, let playing = context.coordinator.file, !playing.isEmpty, Self.fileID(url) == playing {
            context.coordinator.url = url
            return
        }
        load(context.coordinator)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.player?.player?.pause()
        coordinator.player?.player = nil
    }

    private func load(_ coordinator: Coordinator) {
        coordinator.url = url
        coordinator.file = url.map(Self.fileID)
        coordinator.player?.player?.pause()
        let playable = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        coordinator.player?.player = playable ? url.map { AVPlayer(url: $0) } : nil
        coordinator.player?.isHidden = !playable
        coordinator.label?.isHidden = playable
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A file's volume and number: what a rename keeps.
    static func fileID(_ url: URL) -> [Int] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let file = attributes[.systemFileNumber] as? NSNumber,
              let volume = attributes[.systemNumber] as? NSNumber else { return [] }
        return [volume.intValue, file.intValue]
    }

    final class Coordinator {
        var url: URL?
        /// `fileID` of what plays; empty when it could not be read.
        var file: [Int]?
        weak var player: AVPlayerView?
        weak var label: NSTextField?
    }
}
