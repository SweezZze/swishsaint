// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

/// The left of the Meetings window: the search field, then the meetings by
/// day, newest first.
struct ForkMeetingLibraryList: View {
    @ObservedObject var model: ForkMeetingLibraryModel
    let text: ForkMeetingStrings
    let language: AppLanguage

    /// The exporters: a row's ✓ or ✗ is theirs, a failure of one not set
    /// up included.
    @ObservedObject private var exports = ForkMeetingExports.shared

    var body: some View {
        VStack(spacing: 0) {
            ForkMeetingSearchField(text: $model.query, placeholder: text.searchPlaceholder, focus: model.searchFocus)
                .frame(height: 28)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            let groups = model.groups
            if groups.isEmpty && !model.loaded {
                // Before the first scan: nothing to say yet.
                Spacer()
            } else if groups.isEmpty {
                Text(text.searchNoResults(model.query))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                let targets = exports.configs.map(\.id)
                List(selection: $model.selection) {
                    ForEach(groups, id: \.day) { group in
                        Section {
                            ForEach(group.entries, id: \.folderName) { entry in
                                ForkMeetingLibraryRow(entry: entry, text: text, language: language,
                                                      calendar: model.calendar,
                                                      selected: model.selection == entry.folderName,
                                                      exportMark: ForkMeetingExportHistory.mark(entry.exports, targets: targets))
                                    .tag(entry.folderName)
                            }
                        } header: {
                            Text(ForkMeetingLibrary.heading(group.day, strings: text, language: language,
                                                            calendar: model.calendar))
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

extension ForkMeetingLibrary.Day: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .today: hasher.combine(0)
        case .yesterday: hasher.combine(1)
        case let .weekday(date): hasher.combine(2); hasher.combine(date)
        case let .date(date, sameYear): hasher.combine(3); hasher.combine(date); hasher.combine(sameYear)
        case .undated: hasher.combine(4)
        }
    }
}

/// One meeting: its time, its title, its length, and below them its
/// service, its size and what went wrong, if anything. Read by VoiceOver in
/// one sentence.
struct ForkMeetingLibraryRow: View {
    let entry: ForkMeetingLibraryEntry
    let text: ForkMeetingStrings
    let language: AppLanguage
    let calendar: Calendar
    /// On the selection's accent colour, orange would read badly: the
    /// status takes the row's own colour there.
    var selected = false
    /// ✓ exported, ✗ an export failed, by the exporters set up.
    var exportMark: ForkMeetingExportHistory.Mark?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ForkMeetingStatusMark(status: entry.status)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let date = entry.date {
                        Text(ForkMeetingLibraryText.time(date, language: language, calendar: calendar))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.displayTitle(text))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let length = ForkMeetingLibraryText.duration(entry.seconds, language: language) {
                        Text(length)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                let caption = ForkMeetingLibraryText.caption(entry, strings: text, language: language)
                if !caption.isEmpty || exportMark != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(caption)
                            .foregroundStyle(entry.status.isFlagged && !selected ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        switch exportMark {
                        case .done?:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.green))
                                .help(text.exportDone)
                        case .failed?:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                                .help(text.exportFailedNotice)
                        case nil:
                            EmptyView()
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let label = ForkMeetingLibraryText.accessibilityLabel(entry, strings: text, language: language, calendar: calendar)
        switch exportMark {
        case .done?: return ForkMeetingLiveText.sentences(label, text.exportDone)
        case .failed?: return ForkMeetingLiveText.sentences(label, text.exportFailedNotice)
        case nil: return label
        }
    }
}

/// ⚠ for a meeting to look at, a red dot while it records, an hourglass
/// while it finishes; nothing for a meeting that ended well.
struct ForkMeetingStatusMark: View {
    let status: ForkMeetingLibraryEntry.Status

    var body: some View {
        Group {
            switch status {
            case .complete:
                Color.clear.frame(width: 10, height: 10)
            case .recovered, .interrupted, .unreadable:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .recording:
                Image(systemName: "record.circle").foregroundStyle(.red)
            case .finalizing:
                Image(systemName: "hourglass").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .accessibilityHidden(true)
    }
}

/// The system's search field: its look, its clear button, its Escape; and
/// the keyboard when ⌘F asks (`focus` changes).
struct ForkMeetingSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focus: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .default
        context.coordinator.focus = focus
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focus = 0

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
