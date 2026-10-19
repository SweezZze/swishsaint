// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit

/// The Meetings' rows in the Command Bar (seam `command-bar-meeting`), built
/// with the app's own actions on every open, so they follow the recording:
/// "Record a Meeting", which becomes "Stop the Meeting Recording" while one
/// records, like the screen recorder's row; "Pause" or "Resume" and "Mark
/// This Moment" only then; and "Open Meetings".
///
/// With the feature off, the start and the library still answer to their
/// names and say it needs turning on, as an official feature's rows do:
/// Return opens the Meetings page.
enum ForkMeetingCommandBar {
    /// Under the `action.` prefix's rule, with the app's own actions: no
    /// prefix of a source of their own.
    static let recordID = "action.forkMeetings.record"
    static let pauseID = "action.forkMeetings.pause"
    static let markerID = "action.forkMeetings.marker"
    static let libraryID = "action.forkMeetings.library"

    static func entries() -> [CommandBarEntry] {
        let language = L10n.shared.language
        let text = ForkMeetingStrings.strings(language)
        let area = ForkExtrasStrings.strings(language).meetingsTitle
        let keywords = [text.barKeywords, ForkMeetingStrings.enUS.barKeywords, area,
                        ForkExtrasStrings.strings(.enUS).meetingsTitle].joined(separator: ", ")
        let service = ForkMeetingService.shared
        let enabled = service.isWanted
        let setup: CommandBarEntry.Trouble? = enabled ? nil
            : .needsSetup(featureTitle: area, page: ForkFeature.meetings.settingsPage)
        let running = service.isRecording || service.isStarting

        var entries: [CommandBarEntry] = []
        entries.append(CommandBarEntry(
            id: recordID,
            title: running ? text.barStop : text.barStart,
            subtitle: area,
            keywords: keywords,
            icon: .symbol(running ? "stop.circle" : "record.circle"),
            shortcut: enabled ? shortcut(.toggle) : nil,
            isActive: running,
            // Return asks macOS for it, as the screen recorder's row does.
            // Sound only needs no Screen Recording, so asks for none.
            trouble: setup ?? (ForkMeetingAudioOnly.needsScreenRecording(
                filmsPicture: service.captureSettings().target.filmsPicture,
                allowed: Permissions.shared.screenRecording, running: running) ? .needsPermission : nil),
            run: { _ in afterBeat { ForkMeetingService.shared.toggleRecording() } }))
        if enabled, service.isRecording {
            entries.append(CommandBarEntry(
                id: pauseID,
                title: service.isPaused ? text.barResume : text.barPause,
                subtitle: area,
                keywords: keywords,
                icon: .symbol(service.isPaused ? "play.circle" : "pause.circle"),
                shortcut: shortcut(.pause),
                isActive: service.isPaused,
                run: { _ in ForkMeetingService.shared.togglePause() }))
        }
        // Nothing to mark while paused: the row comes back at the resume.
        if enabled, ForkMeetingMarkers.accepts(recording: service.isRecording, paused: service.isPaused) {
            entries.append(CommandBarEntry(
                id: markerID,
                title: text.barMarker,
                subtitle: area,
                keywords: keywords,
                icon: .symbol("star"),
                shortcut: shortcut(.marker),
                run: { _ in ForkMeetingService.shared.addMarker() }))
        }
        entries.append(CommandBarEntry(
            id: libraryID,
            title: text.openLibrary,
            subtitle: area,
            keywords: keywords,
            icon: .symbol("film.stack"),
            trouble: setup,
            run: { _ in afterBeat { ForkMeetingLibraryWindow.shared.show() } }))
        return entries
    }

    /// Shown only when it answers, so the bar never teaches a dead
    /// combination: one macOS refused stays out. What the page checks on
    /// saving is not asked again here, on every open of the bar.
    private static func shortcut(_ role: ForkMeetingShortcutRole) -> GlobalShortcut? {
        let service = ForkMeetingService.shared
        let refused = role == .toggle ? service.shortcutRefused : service.refusedShortcuts.contains(role)
        return refused ? nil : ForkMeetingShortcut.load(role: role)
    }

    /// The bar leaves first: a recording started by hand films the window
    /// in front, which must be the person's, not the bar.
    private static func afterBeat(_ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
