// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

/// The fork's preference keys, all under `fork.`: the official app never
/// writes there, so a merge of the official code can never collide with them.
enum ForkDefaultsKey {
    static let gesturesEnabled = "fork.gestures.enabled"
    static let linkedResizeEnabled = "fork.gestures.linkedResize"
    static let disabledGestures = "fork.gestures.disabled"
    static let centerSizeStep = "fork.gestures.centerSizeStep"
    static let swipeSensitivityStep = "fork.gestures.swipeSensitivityStep"
    static let pinchSensitivityStep = "fork.gestures.pinchSensitivityStep"
    static let stepPauseStep = "fork.gestures.stepPauseStep"
    static let cancelDelayStep = "fork.gestures.cancelDelayStep"
    /// Off: a still gesture is never given up, only Escape or the lift end it.
    static let cancelEnabled = "fork.gestures.cancelEnabled"
    /// On: a left or right half swiped again right after goes to two thirds,
    /// then a third, then back to the half. Off: it stays at the half.
    static let sizeCycleEnabled = "fork.gestures.sizeCycle"
    /// The keys held for the six-zone grid, and for the stronger gestures:
    /// `ForkTrackpadModifierKeys` raw values.
    static let gridModifierKeys = "fork.gestures.gridModifierKeys"
    static let strongerModifierKeys = "fork.gestures.strongerModifierKeys"
    static let titlebarBandStep = "fork.gestures.titlebarBandStep"
    static let previewEnabled = "fork.gestures.preview"
    static let hapticsEnabled = "fork.gestures.haptics"
    /// The preview stands in for the pointer instead of the screen's center.
    static let previewAtPointer = "fork.gestures.previewAtPointer"
    static let previewSizeStep = "fork.gestures.previewSizeStep"
    /// Dictation: the key held to speak (`ForkDictationTrigger`), the
    /// language (empty: the person's own) and the start and end sounds.
    static let dictationEnabled = "fork.dictation.enabled"
    static let dictationTrigger = "fork.dictation.trigger"
    static let dictationLocale = "fork.dictation.locale"
    static let dictationSounds = "fork.dictation.sounds"
    /// The person's words (one per line) and replacements (one per line,
    /// heard and written separated by a tab).
    static let dictationVocabulary = "fork.dictation.vocabulary"
    static let dictationReplacements = "fork.dictation.replacements"
    /// The shortcuts (`ForkDictationShortcuts` JSON). Empty: the one key of
    /// `dictationTrigger`, as stored before shortcuts could be several.
    static let dictationShortcuts = "fork.dictation.shortcuts"
    /// `ForkDictationEngineSetting`: auto, parakeet or apple.
    static let dictationEngine = "fork.dictation.engine"
    /// "builtin", "system" or a capture device's unique ID.
    static let dictationMicrophone = "fork.dictation.microphone"
    static let dictationAddsToHistory = "fork.dictation.addsToHistory"
    /// `ForkDictationFeedbackSetting`: auto, island or bubble.
    static let dictationFeedback = "fork.dictation.feedback"
    /// Hands-free ends after a minute without a voice.
    static let dictationStopsOnSilence = "fork.dictation.stopsOnSilence"
    /// Minutes before an unused Parakeet model leaves memory.
    static let dictationUnloadMinutes = "fork.dictation.unloadMinutes"
    /// Dictations are kept with their audio (a week) in the dictation
    /// history. The history itself is machine state, outside the backup.
    static let dictationKeepsHistory = "fork.dictation.keepsHistory"
    /// Meetings: recording a call's window, its sound and the microphone,
    /// one folder per meeting.
    static let meetingsEnabled = "fork.meetings.enabled"
    /// `ForkMeetingCaptureTarget`: window (the meeting's window) or display
    /// (the display it is on).
    static let meetingsCaptureTarget = "fork.meetings.captureTarget"
    /// `ForkMeetingSystemAudio`: app (the meeting app's sound), all (the
    /// whole Mac's) or off.
    static let meetingsSystemAudio = "fork.meetings.systemAudio"
    /// "meeting" (the input the meeting app uses), "system", "builtin", a
    /// capture device's unique ID, or "off". An ID missing on another Mac
    /// falls back to "meeting".
    static let meetingsMicrophone = "fork.meetings.microphone"
    /// `ForkMeetingQuality`: light, standard or high.
    static let meetingsQuality = "fork.meetings.quality"
    /// An M4A of the meeting's sound beside the video.
    static let meetingsExtractAudio = "fork.meetings.extractAudio"
    /// The line reminding to tell the other participants.
    static let meetingsConsentReminder = "fork.meetings.consentReminder"
    /// The text copied to announce a recording; empty: the default one, in
    /// the person's language.
    static let meetingsAnnouncement = "fork.meetings.announcement"
    /// The shortcut that starts and stops a recording, stored like the
    /// official shortcuts (`GlobalShortcut.storageValue`); empty: none.
    static let meetingsShortcut = "fork.meetings.shortcut"
    /// What a detected meeting does per provider (`ForkMeetingPolicies`
    /// JSON): ask, always (starts on its own) or never.
    static let meetingsApps = "fork.meetings.apps"
    /// A recording the detection started stops after a countdown once its
    /// meeting probably ended; off: it goes on until it is stopped.
    static let meetingsAutoStop = "fork.meetings.autoStop"
    /// That countdown, in seconds.
    static let meetingsAutoStopSeconds = "fork.meetings.autoStopSeconds"
    /// A detected Google Meet takes the name of the calendar event that
    /// links to it (EventKit, full access asked when it is turned on).
    static let meetingsCalendarNaming = "fork.meetings.calendarNaming"
    /// Meetings older than this many days go to the Trash
    /// (`ForkMeetingRetention`); 0: never.
    static let meetingsRetentionDays = "fork.meetings.retentionDays"
    /// The meetings folder's path; empty: a folder in Movies, named in the
    /// person's language and saved here at the first recording. Machine
    /// state, like the official recorder's folder: kept out of the backup.
    static let meetingsFolder = "fork.meetings.folder"
    /// Where the pill was dragged, per display (JSON). Machine state.
    static let meetingsPillPositions = "fork.meetings.pillPositions"
    /// The first-use sheet with the consent reminder was confirmed on this
    /// Mac. Machine state.
    static let meetingsConsentAcknowledged = "fork.meetings.consentAcknowledged"
    /// A recording's witness tap heard sound (true) or stayed deaf to what
    /// the screen stream heard (false): whether system audio recording is
    /// allowed on this Mac, which macOS gives no way to read. Machine state.
    static let meetingsSystemAudioVerified = "fork.meetings.systemAudioVerified"
    /// The exporters set up on the Meetings page (`ForkMeetingExporterList`,
    /// JSON, no secret: those are in the Keychain). Machine state: a folder's
    /// path and an address depend on this Mac, so they stay out of the
    /// settings backup.
    static let meetingsExporters = "fork.meetings.exporters"
    /// The build the person answered "Later" for. Machine state: kept out
    /// of the settings backup.
    static let updatePostponedBuild = "fork.update.postponedBuild"
    /// Whether Parakeet was already offered on this Mac at a launch with
    /// dictation on. Machine state: kept out of the settings backup.
    static let dictationParakeetOffered = "fork.dictation.parakeetOffered"
}

enum ForkDefaults {
    static let registered: [String: Any] = [
        ForkDefaultsKey.gesturesEnabled: false,
        ForkDefaultsKey.linkedResizeEnabled: false,
        ForkDefaultsKey.disabledGestures: "",
        ForkDefaultsKey.centerSizeStep: ForkTrackpadTuning.centerSize.defaultStep,
        ForkDefaultsKey.swipeSensitivityStep: ForkTrackpadTuning.swipeSensitivity.defaultStep,
        ForkDefaultsKey.pinchSensitivityStep: ForkTrackpadTuning.pinchSensitivity.defaultStep,
        ForkDefaultsKey.stepPauseStep: ForkTrackpadTuning.stepPause.defaultStep,
        ForkDefaultsKey.cancelDelayStep: ForkTrackpadTuning.cancelDelay.defaultStep,
        ForkDefaultsKey.cancelEnabled: true,
        ForkDefaultsKey.sizeCycleEnabled: true,
        ForkDefaultsKey.gridModifierKeys: ForkTrackpadModifierKeys.gridDefault.rawValue,
        ForkDefaultsKey.strongerModifierKeys: ForkTrackpadModifierKeys.strongerDefault.rawValue,
        ForkDefaultsKey.titlebarBandStep: ForkTrackpadTuning.titlebarBand.defaultStep,
        ForkDefaultsKey.previewEnabled: true,
        ForkDefaultsKey.hapticsEnabled: true,
        ForkDefaultsKey.previewAtPointer: false,
        ForkDefaultsKey.previewSizeStep: ForkTrackpadTuning.previewSize.defaultStep,
        ForkDefaultsKey.dictationEnabled: false,
        ForkDefaultsKey.dictationTrigger: ForkDictationTrigger.fallback.rawValue,
        ForkDefaultsKey.dictationLocale: "",
        ForkDefaultsKey.dictationSounds: true,
        ForkDefaultsKey.dictationVocabulary: "",
        ForkDefaultsKey.dictationReplacements: "",
        ForkDefaultsKey.dictationShortcuts: "",
        ForkDefaultsKey.dictationEngine: "auto",
        ForkDefaultsKey.dictationMicrophone: "builtin",
        ForkDefaultsKey.dictationAddsToHistory: true,
        ForkDefaultsKey.dictationFeedback: "auto",
        ForkDefaultsKey.dictationStopsOnSilence: true,
        ForkDefaultsKey.dictationUnloadMinutes: 5,
        ForkDefaultsKey.dictationKeepsHistory: true,
        ForkDefaultsKey.meetingsEnabled: false,
        ForkDefaultsKey.meetingsCaptureTarget: ForkMeetingCaptureTarget.fallback.rawValue,
        ForkDefaultsKey.meetingsSystemAudio: ForkMeetingSystemAudio.fallback.rawValue,
        ForkDefaultsKey.meetingsMicrophone: "meeting",
        ForkDefaultsKey.meetingsQuality: ForkMeetingQuality.fallback.rawValue,
        ForkDefaultsKey.meetingsExtractAudio: true,
        ForkDefaultsKey.meetingsConsentReminder: true,
        ForkDefaultsKey.meetingsAnnouncement: "",
        ForkDefaultsKey.meetingsShortcut: "",
        ForkDefaultsKey.meetingsApps: ForkMeetingPolicies.defaultJSON,
        ForkDefaultsKey.meetingsAutoStop: true,
        ForkDefaultsKey.meetingsAutoStopSeconds: ForkMeetingAutoStop.defaultSeconds,
        ForkDefaultsKey.meetingsCalendarNaming: false,
        ForkDefaultsKey.meetingsRetentionDays: ForkMeetingRetention.fallback,
    ]

    /// Where each setting lived in the test builds made before the fork
    /// ("Vorssaint (Developer)"): a backup exported from one of them still
    /// carries these names.
    static let legacyKeys: [String: String] = [
        "windowTrackpadGesturesEnabled": ForkDefaultsKey.gesturesEnabled,
        "windowLinkedResizeEnabled": ForkDefaultsKey.linkedResizeEnabled,
        "windowTrackpadDisabledGestures": ForkDefaultsKey.disabledGestures,
        "windowTrackpadCenterSizeStep": ForkDefaultsKey.centerSizeStep,
        "windowTrackpadSwipeSensitivityStep": ForkDefaultsKey.swipeSensitivityStep,
        "windowTrackpadPinchSensitivityStep": ForkDefaultsKey.pinchSensitivityStep,
        "windowTrackpadStepPauseStep": ForkDefaultsKey.stepPauseStep,
        "windowTrackpadCancelDelayStep": ForkDefaultsKey.cancelDelayStep,
        "windowTrackpadTitlebarBandStep": ForkDefaultsKey.titlebarBandStep,
        "windowTrackpadPreviewEnabled": ForkDefaultsKey.previewEnabled,
        "windowTrackpadHapticsEnabled": ForkDefaultsKey.hapticsEnabled,
        "windowTrackpadPreviewSizeStep": ForkDefaultsKey.previewSizeStep,
    ]

    /// What a settings backup may bring back for the fork (`ForkBackup`):
    /// every fork setting, and the old names so a backup from a pre-fork
    /// test build imports too (`register` then moves them to their new names).
    static var backupKeys: Set<String> {
        Set(registered.keys).union(legacyKeys.keys)
    }

    static func register(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: registered)
        migrateLegacyKeys(defaults)
    }

    /// Moves each old-named value to its new name and removes the old name.
    /// An old name only appears right after importing such a backup, so its
    /// value is the one just asked for.
    static func migrateLegacyKeys(_ defaults: UserDefaults) {
        for (old, new) in legacyKeys {
            guard let value = defaults.object(forKey: old) else { continue }
            defaults.set(value, forKey: new)
            defaults.removeObject(forKey: old)
        }
    }
}
