// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

// MARK: - Speed and marked moments

/// Under the player: its speed, and the moments marked while recording, on
/// a strip as long as the video and in a row of buttons; a click plays from
/// a little before the moment (`ForkMeetingMarkers.lead`).
struct ForkMeetingReviewBar: View {
    @ObservedObject var playback: ForkMeetingPlaybackController
    let markers: [Double]
    /// The recorded length, until the player knows the file's.
    let fallbackDuration: Double?
    let text: ForkMeetingStrings
    let language: AppLanguage

    private var duration: Double? { playback.duration ?? fallbackDuration }

    var body: some View {
        if playback.player != nil || !markers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    speedButton
                    if !markers.isEmpty, duration != nil {
                        strip
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                if !markers.isEmpty { list }
            }
        }
    }

    private var speedButton: some View {
        let locale = language.formattingLocale()
        return Menu {
            ForEach(ForkMeetingPlayback.speeds, id: \.self) { speed in
                Button {
                    playback.setSpeed(speed)
                } label: {
                    if abs(speed - playback.speed) < 0.01 {
                        Label(ForkMeetingPlayback.speedLabel(speed, locale: locale), systemImage: "checkmark")
                    } else {
                        Text(ForkMeetingPlayback.speedLabel(speed, locale: locale))
                    }
                }
            }
        } label: {
            Text(ForkMeetingPlayback.speedLabel(playback.speed, locale: locale))
                .font(.callout.monospacedDigit())
        } primaryAction: {
            playback.setSpeed(ForkMeetingPlayback.nextSpeed(after: playback.speed))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(playback.player == nil)
        .help(text.playbackSpeed)
        .accessibilityLabel(text.playbackSpeed)
        .accessibilityValue(ForkMeetingPlayback.speedLabel(playback.speed, locale: locale))
    }

    /// The video's length, its playhead, and a ★ at each moment marked.
    private var strip: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08)).frame(height: 4)
                if let progress = ForkMeetingMarkers.fraction(playback.time, duration: duration) {
                    Capsule().fill(Color.accentColor.opacity(0.6)).frame(width: max(4, width * progress), height: 4)
                }
                ForEach(markers, id: \.self) { time in
                    if let place = ForkMeetingMarkers.fraction(time, duration: duration) {
                        Button {
                            playback.play(from: ForkMeetingMarkers.playFrom(time))
                        } label: {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow)
                                .shadow(color: .black.opacity(0.25), radius: 1)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: min(max(0, width * place - 9), max(0, width - 18)))
                        .help(text.markerLabel(ForkMeetingMarkers.clock(time)))
                        .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 18)
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }

    private var list: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text(text.markersTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(markers, id: \.self) { time in
                    Button {
                        playback.play(from: ForkMeetingMarkers.playFrom(time))
                    } label: {
                        Label(ForkMeetingMarkers.clock(time), systemImage: "star.fill")
                            .font(.caption.monospacedDigit())
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.yellow.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .disabled(playback.player == nil)
                    .help(text.markerPlayHelp)
                    .accessibilityLabel(text.markerLabel(ForkMeetingMarkers.clock(time)))
                    .accessibilityHint(text.markerPlayHelp)
                }
            }
        }
    }
}

// MARK: - The transcript that follows the video

/// The `.srt`'s lines beside the player: the line said now lit and kept in
/// sight while the video plays (unless "Follow" is off, to read elsewhere),
/// a click on a line plays from it, the marked moments among them, and
/// "Copy Transcript". Read off the main thread when the meeting or its
/// transcript changes.
struct ForkMeetingReviewTranscript: View {
    @ObservedObject var model: ForkMeetingLibraryModel
    let entry: ForkMeetingLibraryEntry
    @ObservedObject var playback: ForkMeetingPlaybackController
    let text: ForkMeetingStrings

    @State private var rows: [ForkMeetingPlayback.Row] = []
    @State private var loadedFrom: String?
    @State private var follows = true

    private var source: URL? { model.subtitlesURL(entry) }
    private var current: Int? { ForkMeetingPlayback.current(rows, at: playback.time) }

    var body: some View {
        Group {
            if source != nil, !rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(text.transcriptTitle)
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 8)
                        Toggle(text.transcriptFollow, isOn: $follows)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                        Button(text.actionCopyTranscript) { model.copyTranscript(entry) }
                            .controlSize(.small)
                    }
                    lines
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
        }
        .onAppear { load() }
        .onChange(of: source) { _, _ in load() }
        .onChange(of: entry.markers) { _, _ in load(force: true) }
    }

    private var lines: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        line(row, lit: index == current)
                            .id(index)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 190)
            .onChange(of: current) { _, now in
                guard follows, playback.isPlaying, let now else { return }
                withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    reader.scrollTo(now, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func line(_ row: ForkMeetingPlayback.Row, lit: Bool) -> some View {
        switch row {
        case let .cue(cue):
            Button {
                playback.play(from: cue.start)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ForkMeetingMarkers.clock(cue.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(cue.text)
                        .font(.callout)
                        .foregroundStyle(lit ? Color.primary : Color.primary.opacity(0.8))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(lit ? Color.accentColor.opacity(0.18) : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(playback.player == nil)
            .accessibilityLabel(cue.text)
            .accessibilityValue(ForkMeetingMarkers.clock(cue.start))
            .accessibilityHint(text.transcriptLineHelp)
            .accessibilityAddTraits(lit ? .isSelected : [])
        case let .marker(time):
            Button {
                playback.play(from: ForkMeetingMarkers.playFrom(time))
            } label: {
                Label(text.markerLabel(ForkMeetingMarkers.clock(time)), systemImage: "star.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(playback.player == nil)
            .accessibilityHint(text.markerPlayHelp)
        }
    }

    private func load(force: Bool = false) {
        guard let url = source else {
            rows = []
            loadedFrom = nil
            return
        }
        let stamp = url.path
        guard force || loadedFrom != stamp else { return }
        loadedFrom = stamp
        let markers = entry.markers
        DispatchQueue.global(qos: .userInitiated).async {
            let srt = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let read = ForkMeetingPlayback.rows(cues: ForkMeetingPlayback.cues(srt: srt), markers: markers)
            DispatchQueue.main.async {
                guard loadedFrom == stamp else { return }
                rows = read
            }
        }
    }
}

// MARK: - The summary

/// The detail's summary: written on this Mac by Apple Intelligence from the
/// transcript, then copied or opened. Invisible where Apple Intelligence
/// cannot run, unless a summary is already there (written on another Mac):
/// it can still be copied and opened.
struct ForkMeetingSummaryRow: View {
    @ObservedObject var model: ForkMeetingLibraryModel
    let entry: ForkMeetingLibraryEntry
    let text: ForkMeetingStrings

    @ObservedObject private var summarizer = ForkMeetingSummarizer.shared

    private var folder: URL { model.folderURL(entry) }
    private var phase: ForkMeetingSummarizer.Phase { summarizer.phase(id: entry.id, folder: folder) }
    private var summaryURL: URL? { model.summaryURL(entry) }
    private var summarizable: Bool {
        !entry.isReadOnly && !model.isLive(entry) && entry.transcript != nil
    }

    var body: some View {
        Group {
            if summarizer.available || summaryURL != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(text.summaryTitle)
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 8)
                        actions
                    }
                    status
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
        }
        .onAppear { summarizer.refreshAvailability() }
    }

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .running, .waiting:
            Button(text.cancel) { model.cancelSummary(entry) }
                .controlSize(.small)
        case .idle:
            HStack(spacing: 8) {
                if summaryURL != nil {
                    Button(text.actionCopySummary) { model.copySummary(entry) }
                        .controlSize(.small)
                    Button(text.actionOpenSummary) { model.openSummary(entry) }
                        .controlSize(.small)
                }
                if summarizer.available {
                    Button(summaryURL == nil ? text.actionSummarize : text.actionResummarize) { model.summarize(entry) }
                        .controlSize(.small)
                        .disabled(!summarizable)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case let .running(fraction):
            ProgressView(value: fraction)
            caption(text.summaryProgress(fraction.formatted(.percent.precision(.fractionLength(0)))))
        case .waiting:
            caption(text.transcriptWaiting)
        case .idle:
            if let failure, let line = Self.line(for: failure, text: text) {
                Label(line, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if entry.transcript == nil, summarizer.available {
                caption(text.summaryNeedsTranscript)
            } else if summaryURL == nil, summarizer.available {
                caption(text.summaryCaption)
            } else if (entry.summaryRecord?.skipped ?? 0) > 0 {
                caption(text.summaryPartial)
            }
        }
    }

    private var failure: ForkMeetingSummaryFailure? {
        if let outcome = summarizer.outcome(id: entry.id, folder: folder) {
            if case let .failed(failure) = outcome { return failure }
            return nil
        }
        guard summaryURL == nil, let record = entry.summaryRecord, record.state == .failed else { return nil }
        return record.reason.flatMap(ForkMeetingSummaryFailure.init(rawValue:)) ?? .engine
    }

    static func line(for failure: ForkMeetingSummaryFailure, text: ForkMeetingStrings) -> String? {
        switch failure {
        case .cancelled: return nil
        case .meetingInProgress: return text.refusedWhileRecording
        case .noTranscript: return text.summaryNeedsTranscript
        case .unavailable: return text.summaryUnavailable
        case .languageUnsupported: return text.summaryLanguageUnsupported
        case .refused: return text.summaryRefused
        case .engine, .folderGone, .notWritten: return text.summaryFailedGeneric
        }
    }

    private func caption(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - The model's part

extension ForkMeetingLibraryModel {
    func subtitlesURL(_ entry: ForkMeetingLibraryEntry) -> URL? {
        entry.subtitles.map { folderURL(entry).appendingPathComponent($0) }
    }

    /// The `.txt` as it is, in the pasteboard.
    func copyTranscript(_ entry: ForkMeetingLibraryEntry) {
        guard let url = transcriptURL(entry), let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        Self.copy(ForkMeetingPlayback.copiedText(text))
        say(strings.transcriptCopied)
    }

    func summaryURL(_ entry: ForkMeetingLibraryEntry) -> URL? {
        let folder = folderURL(entry)
        return (entry.summaryRecord?.files ?? []).lazy.map { folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func summarize(_ entry: ForkMeetingLibraryEntry) {
        guard !isLive(entry) else {
            say(strings.refusedWhileRecording)
            return
        }
        ForkMeetingSummarizer.shared.summarize(folderURL(entry), id: entry.id)
    }

    func cancelSummary(_ entry: ForkMeetingLibraryEntry) {
        ForkMeetingSummarizer.shared.cancel(id: entry.id, folder: folderURL(entry))
    }

    func openSummary(_ entry: ForkMeetingLibraryEntry) {
        guard let url = summaryURL(entry) else { return }
        NSWorkspace.shared.open(url)
    }

    func copySummary(_ entry: ForkMeetingLibraryEntry) {
        guard let text = ForkMeetingStore.summaryText(in: folderURL(entry), files: entry.summaryRecord?.files ?? []) else {
            return
        }
        Self.copy(text)
        say(strings.summaryCopied)
    }

    /// Signed as Vorssaint's, like the announcement: the clipboard history
    /// does not credit another app with it.
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareVorssaintSource()
        pasteboard.setString(string, forType: .string)
    }
}
